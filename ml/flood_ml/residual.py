"""Residual correction: the observed-only model, plus a small, cautious adjustment
from rain history and the weather forecast.

    prediction = base(observed readings) + alpha * correction(rain history, forecast)

base        the usual TreeEnsemble on BASE_FEATURES (river levels, past rain, upstream)
correction  a small XGBoost model (depth 2, strongly regularised, more rain may only
            raise it) trained on the base model's OUT-OF-FOLD errors: for each of the
            last OOF_DAYS training days, a base model trained only on earlier days
            predicts that day, and the correction learns what it got wrong. (Errors on
            the base model's own training rows would be too small to learn from.)
alpha       0, 0.25, 0.5, 0.75 or 1, chosen on the newest out-of-fold days with the
            flood-first rule in scoring.choose. alpha = 0 gives exactly the base model,
            so on those days the corrected model is never worse than the base.

The explanation stays exact: both parts are tree models, so their TreeSHAP values add
up; contributions() returns base + alpha * correction for every input, plus the base value.
"""
import json
from pathlib import Path

import numpy as np
import pandas as pd
import xgboost as xgb

from .ensemble import SEED, TreeEnsemble
from .features import BASE_FEATURES, HISTORY_FEATURES, HORIZON_H, TARGET
from .scoring import choose, flood_scores
from .weather import FILL_INTERACTION, NEXT_DAY_FEATURES, RAISES_ONLY

MYT = "Asia/Kuala_Lumpur"
ALPHAS = (0.0, 0.25, 0.5, 0.75, 1.0)
OOF_DAYS = 6
MIN_ROWS = 200
CORRECTION_FEATURES = (HISTORY_FEATURES + NEXT_DAY_FEATURES
                       + ["fc_rain_day2_mm", "fc_rain_day3_mm", "fc_rain_total_3d", "fc_rain_days_3d",
                          FILL_INTERACTION])
CORRECTION_PARAMS = {"objective": "reg:squarederror", "max_depth": 2, "eta": 0.05, "lambda": 10.0,
                     "min_child_weight": 50, "subsample": 0.8, "seed": SEED}
CORRECTION_ROUNDS = 80
RAISES = set(RAISES_ONLY) | set(HISTORY_FEATURES)


def _days(rows):
    return rows["time"].dt.tz_convert(MYT).dt.normalize()


class _Correction:
    def __init__(self, features):
        self.features = list(features)
        self.booster = None

    def fit(self, x, y):
        mono = "(" + ",".join("1" if f in RAISES else "0" for f in self.features) + ")"
        self.booster = xgb.train(CORRECTION_PARAMS | {"monotone_constraints": mono},
                                 xgb.DMatrix(x[self.features], label=y), CORRECTION_ROUNDS)
        return self

    def predict(self, x):
        return self.booster.predict(xgb.DMatrix(x[self.features]))

    def contributions(self, x):
        return self.booster.predict(xgb.DMatrix(x[self.features]), pred_contribs=True)


def out_of_fold(train, base_features, target, horizon_h, days=OOF_DAYS):
    """Rows of the last `days` training days with "oof_pred": the prediction of a base model
    trained only on rows whose target ends before that day starts (a quick one-member model)."""
    day = _days(train)
    parts = []
    for d in sorted(day.unique())[-days:]:
        start = d.tz_convert("UTC")
        fit_rows = train[train["time"] + pd.Timedelta(hours=horizon_h) < start]
        test_rows = train[day == d]
        if len(fit_rows) < MIN_ROWS or test_rows.empty:
            continue
        m = TreeEnsemble.fit(fit_rows, fast=True, members=("xgboost",), features=base_features,
                             target=target, horizon_h=horizon_h)
        parts.append(test_rows.assign(oof_pred=m.predict(test_rows)))
    return pd.concat(parts) if parts else train.iloc[0:0].assign(oof_pred=np.nan)


class ResidualModel:
    def __init__(self, base, correction, alpha, target=TARGET, horizon_h=HORIZON_H, alpha_scores=None):
        self.base, self.correction, self.alpha = base, correction, float(alpha)
        self.target, self.horizon_h = target, horizon_h
        self.alpha_scores = alpha_scores or {}
        extra = [f for f in (correction.features if correction else []) if f not in base.features]
        self.features = list(base.features) + extra

    @classmethod
    def fit(cls, train, fast=False, base_features=None, correction_features=None, target=TARGET,
            horizon_h=HORIZON_H):
        base_features = list(base_features or BASE_FEATURES)
        corr_features = [f for f in (correction_features or CORRECTION_FEATURES) if train[f].notna().any()]
        base = TreeEnsemble.fit(train, fast=fast, features=base_features, target=target, horizon_h=horizon_h)
        oof = out_of_fold(train, base_features, target, horizon_h)
        oof = oof[oof[target].notna()]
        oof_days = sorted(_days(oof).unique())
        if not corr_features or len(oof) < MIN_ROWS or len(oof_days) < 2:
            return cls(base, None, 0.0, target, horizon_h)
        n_val = max(1, len(oof_days) // 3)
        is_val = _days(oof).isin(oof_days[-n_val:])
        resid = oof[target] - oof["oof_pred"]
        corr = _Correction(corr_features).fit(oof[~is_val], resid[~is_val])
        val = oof[is_val]
        scores = {a: flood_scores(val["oof_pred"].to_numpy() + a * corr.predict(val), val, target) for a in ALPHAS}
        alpha = choose({f"{a}": s for a, s in scores.items()})
        alpha = float(alpha) if alpha is not None else 0.0
        corr = _Correction(corr_features).fit(oof, resid) if alpha > 0 else None
        return cls(base, corr, alpha if corr else 0.0, target, horizon_h, {str(a): s for a, s in scores.items()})

    def predict(self, x):
        p = np.asarray(self.base.predict(x), dtype=float)
        if self.correction is not None and self.alpha > 0:
            p = p + self.alpha * np.asarray(self.correction.predict(x), dtype=float)
        return p

    def contributions(self, x):
        """(rows, len(self.features) + 1); each row adds up exactly to predict()."""
        out = np.zeros((len(x), len(self.features) + 1))
        b = np.asarray(self.base.contributions(x), dtype=float)
        idx = {f: i for i, f in enumerate(self.features)}
        for j, f in enumerate(self.base.features):
            out[:, idx[f]] += b[:, j]
        out[:, -1] += b[:, -1]
        if self.correction is not None and self.alpha > 0:
            c = np.asarray(self.correction.contributions(x), dtype=float)
            for j, f in enumerate(self.correction.features):
                out[:, idx[f]] += self.alpha * c[:, j]
            out[:, -1] += self.alpha * c[:, -1]
        return out

    def describe(self):
        d = self.base.describe()
        d.update({"type": "observed-only tree ensemble + residual correction (rain history, forecast)",
                  "correction_alpha": self.alpha,
                  "correction_inputs": self.correction.features if self.correction else [],
                  "inputs": len(self.features)})
        return d

    def save(self, out_dir):
        self.base.save(out_dir)
        out = Path(out_dir) / "model"
        if self.correction is not None:
            self.correction.booster.save_model(str(out / "correction.json"))
        (out / "residual.json").write_text(json.dumps({"alpha": self.alpha, "describe": self.describe()},
                                                      indent=2, default=str))
