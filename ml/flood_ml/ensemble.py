"""FloodReady's forecaster: a weighted tree ensemble with exact TreeSHAP reasons.

Four tree models each predict the change in river level over the next 3 hours:
  XGBoost (gradient boosting), LightGBM (gradient boosting),
  CatBoost (gradient boosting), Random forest (XGBoost's random-forest mode).
The ensemble forecast is their weighted average.

Why the explanation stays exact: each model's TreeSHAP values add up to that
model's prediction (base value + contributions = prediction). SHAP values are
additive, so the same weighted average of the four models' SHAP values adds
up exactly to the ensemble's prediction. This is why the models are averaged
as level forecasts (regression), not as flood probabilities: averaging
probabilities would break this property for the boosted models, whose exact
TreeSHAP values are on the log-odds scale.

Weights: each model is first trained on the older part of the training data
and scored (MAE) on the newest part ("validation", never the test set).
Weight = (1 / validation MAE), normalised to sum to 1.

Monotone inputs: more forecast rain may only raise the forecast, never lower it
(weather.RAISES_ONLY, enforced inside every tree model). With few days of data a
forecast input is otherwise used as a "which day was it" label (on one day every
station gets nearly the same forecast), which fits the training days but not new ones.
The constraint also keeps the TreeSHAP reasons physically sensible.

Decision rule: the weighted ensemble is kept only if its validation MAE is lower
than that of the best single model; otherwise that model is used on its own
(weight 1). On practice data the best single model often matches the ensemble,
so the ensemble has to earn its place on each data set. Either way the forecast
is a weighted average of tree models, so the TreeSHAP reasons stay exact.
The chosen model(s) are then retrained on the whole training set.
"""
import json
from pathlib import Path

import numpy as np
import pandas as pd
import xgboost as xgb

from .features import FEATURES, HORIZON_H, TARGET
from .weather import RAISES_ONLY

SEED = 7
XGB_PARAMS = {
    "objective": "reg:squarederror",
    "max_depth": 4,
    "eta": 0.05,
    "subsample": 0.8,
    "colsample_bytree": 0.9,
    "seed": SEED,
}
RF_PARAMS = {  # XGBoost random-forest mode: one round of many bagged, full-strength trees
    "objective": "reg:squarederror",
    "max_depth": 8,
    "eta": 1.0,
    "subsample": 0.7,
    "colsample_bynode": 0.7,
    "num_parallel_tree": 200,
    "min_child_weight": 3,
    "seed": SEED,
}
MEMBERS = ("xgboost", "lightgbm", "catboost", "random_forest")
ENSEMBLE = "ensemble"  # TreeEnsemble.chosen when the weighted ensemble wins on validation
MEMBER_NAMES = {
    "xgboost": "XGBoost",
    "lightgbm": "LightGBM",
    "catboost": "CatBoost",
    "random_forest": "Random forest",
}


def monotone(columns):
    """+1 for inputs in RAISES_ONLY, else 0, in column order."""
    return [1 if c in RAISES_ONLY else 0 for c in columns]


class _Xgb:
    def __init__(self, params, rounds):
        self.params, self.rounds, self.booster = params, rounds, None

    def fit(self, x, y):
        mono = monotone(x.columns)
        params = self.params | ({"monotone_constraints": "(" + ",".join(map(str, mono)) + ")"} if any(mono) else {})
        self.booster = xgb.train(params, xgb.DMatrix(x, label=y), self.rounds)
        return self

    def predict(self, x):
        return self.booster.predict(xgb.DMatrix(x))

    def contributions(self, x):  # columns: FEATURES..., base value
        return self.booster.predict(xgb.DMatrix(x), pred_contribs=True)

    def save(self, path):
        self.booster.save_model(str(path) + ".json")


class _Lgbm:
    def __init__(self, rounds):
        self.rounds, self.booster = rounds, None

    def fit(self, x, y):
        import lightgbm as lgb
        params = {"objective": "regression", "learning_rate": 0.05, "num_leaves": 15,
                  "min_data_in_leaf": 20, "bagging_fraction": 0.8, "bagging_freq": 1,
                  "feature_fraction": 0.9, "seed": SEED, "deterministic": True, "verbose": -1}
        mono = monotone(x.columns)
        if any(mono):
            params["monotone_constraints"] = mono
        self.booster = lgb.train(params, lgb.Dataset(x, label=y), self.rounds)
        return self

    def predict(self, x):
        return self.booster.predict(x)

    def contributions(self, x):
        return self.booster.predict(x, pred_contrib=True)

    def save(self, path):
        self.booster.save_model(str(path) + ".txt")


class _Cat:
    def __init__(self, rounds):
        self.rounds, self.model = rounds, None

    def fit(self, x, y):
        from catboost import CatBoostRegressor
        self.model = CatBoostRegressor(iterations=self.rounds, depth=6, learning_rate=0.05,
                                       random_seed=SEED, verbose=False, allow_writing_files=False,
                                       thread_count=-1,
                                       monotone_constraints=monotone(x.columns) if any(monotone(x.columns)) else None)
        self.model.fit(x, y)
        return self

    def predict(self, x):
        return self.model.predict(x)

    def contributions(self, x):
        from catboost import Pool
        return self.model.get_feature_importance(Pool(x), type="ShapValues")

    def save(self, path):
        self.model.save_model(str(path) + ".cbm")


def make_member(name, fast=False):
    rounds = 100 if fast else 300
    if name == "xgboost":
        return _Xgb(XGB_PARAMS, rounds)
    if name == "random_forest":
        return _Xgb(RF_PARAMS | {"num_parallel_tree": 50 if fast else 200}, 1)
    if name == "lightgbm":
        return _Lgbm(rounds)
    if name == "catboost":
        return _Cat(rounds)
    raise ValueError(name)


def validation_split(train, fraction=0.2, horizon_h=HORIZON_H):
    """Newest `fraction` of the training hours become validation rows; older
    rows whose target (horizon_h hours ahead) reaches into validation are dropped."""
    cutoff = train["time"].quantile(1 - fraction)
    inner = train[train["time"] + pd.Timedelta(hours=horizon_h) < cutoff]
    val = train[train["time"] >= cutoff]
    return inner, val


class TreeEnsemble:
    """Weighted average of tree models; predict() and contributions() take a
    DataFrame with the model's `features` columns (FEATURES unless chosen otherwise:
    rain_evidence.py also trains one without the weather forecast, and one per
    longer horizon with a peak-rise target)."""

    def __init__(self, members, weights, validation_mae=None, ensemble_validation_mae=None, chosen=ENSEMBLE,
                 features=None, target=TARGET, horizon_h=HORIZON_H):
        self.members = members  # {name: fitted member}, only the chosen ones
        self.weights = weights  # {name: weight}, sums to 1
        self.validation_mae = validation_mae or {}  # {member name: MAE on validation}
        self.ensemble_validation_mae = ensemble_validation_mae
        self.chosen = chosen  # ENSEMBLE or the name of the single member used
        self.features = list(features or FEATURES)
        self.target, self.horizon_h = target, horizon_h

    @classmethod
    def fit(cls, train, fast=False, members=MEMBERS, features=None, target=TARGET, horizon_h=HORIZON_H):
        features = list(features or FEATURES)
        TARGET_, FEATURES_ = target, features  # noqa: N806 - names as in the rest of the file
        inner, val = validation_split(train, horizon_h=horizon_h)
        val_mae, ens_mae, chosen = {}, None, ENSEMBLE
        if len(inner) >= 100 and len(val) >= 30:
            y = val[TARGET_].to_numpy(dtype=float)
            val_pred = {}
            for name in members:
                m = make_member(name, fast).fit(inner[FEATURES_], inner[TARGET_])
                val_pred[name] = np.asarray(m.predict(val[FEATURES_]), dtype=float)
                val_mae[name] = float(np.mean(np.abs(val_pred[name] - y)))
            inv = {n: 1.0 / max(e, 1e-6) for n, e in val_mae.items()}
            weights = {n: v / sum(inv.values()) for n, v in inv.items()}
            ens_mae = float(np.mean(np.abs(sum(w * val_pred[n] for n, w in weights.items()) - y)))
            best = min(members, key=val_mae.get)
            if val_mae[best] <= ens_mae:  # decision rule: the ensemble must beat the best single model
                weights, chosen = {best: 1.0}, best
        else:  # too little data to judge: equal weights
            weights = {n: 1.0 / len(members) for n in members}
        fitted = {n: make_member(n, fast).fit(train[FEATURES_], train[TARGET_]) for n in weights}
        return cls(fitted, weights, val_mae, ens_mae, chosen, features, target, horizon_h)

    def predict(self, x):
        x = x[self.features]
        return sum(w * np.asarray(self.members[n].predict(x), dtype=float) for n, w in self.weights.items())

    def contributions(self, x):
        """(rows, len(self.features) + 1): per-input impact in metres, last column the
        base value. Each row adds up exactly to predict()."""
        x = x[self.features]
        return sum(w * np.asarray(self.members[n].contributions(x), dtype=float)
                   for n, w in self.weights.items())

    def describe(self):
        name = lambda n: MEMBER_NAMES.get(n, n)  # noqa: E731
        single = self.chosen != ENSEMBLE
        return {
            "type": ("single tree model, chosen on validation (regression, exact TreeSHAP)" if single
                     else "weighted tree ensemble (regression, exact TreeSHAP)"),
            "chosen": name(self.chosen) if single else "Weighted ensemble",
            "members": [name(n) for n in self.weights],
            "weights": {name(n): round(w, 4) for n, w in self.weights.items()},
            "validation_mae_m": {name(n): round(e, 4) for n, e in self.validation_mae.items()},
            "ensemble_validation_mae_m": (None if self.ensemble_validation_mae is None
                                          else round(self.ensemble_validation_mae, 4)),
            "target": self.target,
            "horizon_hours": self.horizon_h,
            "inputs": len(self.features),
        }

    def save(self, out_dir):
        out = Path(out_dir) / "model"
        out.mkdir(parents=True, exist_ok=True)
        for n, m in self.members.items():
            m.save(out / n)
        (out / "ensemble.json").write_text(json.dumps(self.describe(), indent=2))
