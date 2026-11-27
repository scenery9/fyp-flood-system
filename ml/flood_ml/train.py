"""Training and honest evaluation: time-based split, compared against two
baselines: "no change" (river stays where it is) and the straight-line trend
used by the existing FloodWatch app. The model is the weighted tree ensemble
in ensemble.py."""
import json
from pathlib import Path

import numpy as np
import pandas as pd

from .ensemble import TreeEnsemble, validation_split
from .features import BASE_FEATURES, FEATURES, HISTORY_FEATURES, HORIZON_H, LINEAR_TREND, TARGET
from .residual import ResidualModel
from .metrics import forecast_metrics
from .scoring import choose, flood_scores, high_water
from .weather import NEXT_DAY_FEATURES

# Which weather-forecast inputs the model gets is decided on validation, like the
# ensemble weights: the forecast has to earn its place. On the first 8 logged days the
# 3-day inputs made the test error worse (test days were wetter than every training
# day, and trees cannot extrapolate; docs/rain-forecast-evidence.md), so this choice
# is made again on every run as more days are logged.
INPUT_SETS = {
    "observed only": BASE_FEATURES,
    "observed + rain history": BASE_FEATURES + HISTORY_FEATURES,
    "observed + next-day forecast": BASE_FEATURES + HISTORY_FEATURES + NEXT_DAY_FEATURES,
    "observed + 3-day forecast": FEATURES,
}


def time_split(feats, test_fraction=0.2, target=TARGET, horizon_h=HORIZON_H):
    """Oldest data trains, newest data tests. Training rows whose target
    (horizon_h hours ahead) reaches into the test period are dropped."""
    rows = feats.dropna(subset=[target, "level_above_normal"])
    cutoff = rows["time"].quantile(1 - test_fraction)
    train = rows[rows["time"] + pd.Timedelta(hours=horizon_h) < cutoff]
    test = rows[rows["time"] >= cutoff]
    return train, test, cutoff


RESIDUAL = "observed + residual correction (rain history, forecast)"


def candidate_sets(train):
    """{name: columns} of INPUT_SETS, without inputs that have no value in `train`;
    a set that then equals an earlier one is skipped. RESIDUAL is added when it has
    something to correct with (its columns are those of its base model)."""
    sets, seen = {}, set()
    for name, cols in INPUT_SETS.items():
        cols = [c for c in cols if train[c].notna().any()]
        if tuple(cols) not in seen:
            seen.add(tuple(cols))
            sets[name] = cols
    if len(sets) > 1:
        sets[RESIDUAL] = sets["observed only"]
    return sets


def fit_candidate(name, cols, rows, fast=False, target=TARGET, horizon_h=HORIZON_H):
    if name == RESIDUAL:
        return ResidualModel.fit(rows, fast=fast, base_features=cols, target=target, horizon_h=horizon_h)
    return TreeEnsemble.fit(rows, fast=fast, features=cols, target=target, horizon_h=horizon_h)


VALIDATION_DAYS = 3  # newest training days used, one at a time, to choose the inputs


def validation_folds(train, horizon_h=HORIZON_H, days=VALIDATION_DAYS):
    """[(fit rows, check rows)]: for each of the newest `days` Malaysia days of `train`, the
    rows whose target ends before that day, and that day's rows (rolling origin). Falls back
    to one validation_split when there are too few days."""
    day = train["time"].dt.tz_convert("Asia/Kuala_Lumpur").dt.normalize()
    folds = []
    for d in sorted(day.unique())[-days:]:
        fit_rows = train[train["time"] + pd.Timedelta(hours=horizon_h) < d.tz_convert("UTC")]
        check = train[day == d]
        if len(fit_rows) >= 100 and len(check) >= 30 and fit_rows["time"].dt.date.nunique() >= 2:
            folds.append((fit_rows, check))
    if not folds:
        inner, val = validation_split(train, horizon_h=horizon_h)
        if len(inner) >= 100 and len(val) >= 30:
            folds = [(inner, val)]
    return folds


def choose_inputs(train, target=TARGET, horizon_h=HORIZON_H, fast=True):
    """(name, columns, {name: validation flood scores}): the candidate that does best on
    the newest training days (never the test set), each day predicted by a model trained
    only on earlier rows, pooled, and judged by the flood-first rule in scoring.choose
    (high-water error, with a guard on overall error)."""
    sets = candidate_sets(train)
    folds = validation_folds(train, horizon_h)
    if len(sets) == 1 or not folds:
        return "observed only", sets["observed only"], {}
    check = pd.concat([c for _, c in folds])
    scores = {}
    for name, cols in sets.items():
        pred = np.concatenate([fit_candidate(name, cols, f, fast, target, horizon_h).predict(c) for f, c in folds])
        scores[name] = flood_scores(pred, check, target)
    best = choose(scores)
    return best, sets[best], scores


def train_model(train, fast=False, features=None, input_set=None):
    """The weighted tree ensemble (XGBoost, LightGBM, CatBoost, random forest), or the
    residual-corrected one when input_set is RESIDUAL."""
    if input_set == RESIDUAL:
        return ResidualModel.fit(train, fast=fast, base_features=features)
    return TreeEnsemble.fit(train, fast=fast, features=features)


def auc(score, label):
    """Area under the ROC curve: the chance that a random positive row scores
    higher than a random negative row (ties count half). None if only one
    class is present, because AUC is then undefined."""
    score = np.asarray(score, dtype=float)
    label = np.asarray(label, dtype=bool)
    pos, neg = int(label.sum()), int((~label).sum())
    if pos == 0 or neg == 0:
        return None
    ranks = pd.Series(score).rank(method="average").to_numpy()  # ties get the mean rank
    return float((ranks[label].sum() - pos * (pos + 1) / 2) / (pos * neg))


def regression_metrics(pred_change, test, target=TARGET):
    """All prediction metrics (metrics.py) plus skill vs "no change" on MAE and the
    band that holds 80% of errors."""
    actual = test[target].to_numpy(dtype=float)
    err = np.asarray(pred_change, dtype=float) - actual
    mae_base = float(np.mean(np.abs(actual)))
    m = forecast_metrics(pred_change, test, target)
    return m | {
        "skill_vs_baseline": 1 - m["mae_m"] / mae_base if mae_base > 0 else None,
        "band_m": float(np.quantile(np.abs(err), 0.8)),
    }


def linear_trend_prediction(test):
    """FloodWatch straight-line forecast; rows with too few readings count as
    "no change". Returns (prediction, fallback mask)."""
    trend = test[LINEAR_TREND].to_numpy(dtype=float)
    fallback = np.isnan(trend)
    return np.where(fallback, 0.0, trend), fallback


def evaluate(model, test, stations):
    """Scores the level forecast with prediction metrics only (metrics.py), against
    two baselines: "no change" and the FloodWatch straight-line trend."""
    pred = model.predict(test)
    trend, fallback = linear_trend_prediction(test)
    m = regression_metrics(pred, test)
    base = forecast_metrics(np.zeros(len(test)), test, TARGET)
    lin = forecast_metrics(trend, test, TARGET)
    return {
        "horizon_hours": HORIZON_H,
        "model": model.describe(),
        "test_rows": int(len(test)),
        **{k: v for k, v in m.items() if k != "rows"},
        "baseline_mae_m": base["mae_m"],
        "baseline_rmse_m": base["rmse_m"],
        "baseline": base,
        # Straight-line baseline. Where it has too few recent readings it gives no
        # forecast; it is then scored as "no change" and counted in fallback_rows.
        "linear_trend": lin | {"fallback_rows": int(fallback.sum())},
        "skill_vs_linear_trend": 1 - m["mae_m"] / lin["mae_m"] if lin["mae_m"] > 0 else None,
        "high_water": high_water_metrics(pred, test),
        "by_state": by_state(pred, test, stations),
    }


def high_water_metrics(pred_change, test, target=TARGET):
    """The same metrics on high-water hours only (scoring.high_water: the river at least
    half-way from Normal to Alert, or reaching Alert), where a flood forecast matters."""
    hw = high_water(test, test[target].to_numpy(float))
    if not hw.any():
        return {"rows": 0}
    return forecast_metrics(np.asarray(pred_change, float)[hw], test[hw], target)


def by_state(pred, test, stations):
    """The model's metrics for each state's stations on their own, so a good overall
    score cannot hide a state the model does badly in ("state" in the stations file;
    Selangor when not given)."""
    state = {s["id"]: s.get("state", "Selangor") for s in stations}
    states = test["station_id"].map(state).to_numpy()
    out = {}
    for name in sorted(set(states)):
        mask = states == name
        part = test[mask]
        p = np.asarray(pred, dtype=float)[mask]
        reg = forecast_metrics(p, part, TARGET)
        out[name] = {
            "stations": int(part["station_id"].nunique()),
            "test_rows": int(mask.sum()),
            **{k: v for k, v in reg.items() if k != "rows"},
            "baseline_mae_m": float(np.mean(np.abs(part[TARGET].to_numpy(dtype=float)))),
        }
    return out


def save(model, metrics, out_dir):
    out = Path(out_dir)
    out.mkdir(parents=True, exist_ok=True)
    model.save(out)  # out/model/: one file per tree model + ensemble.json (weights)
    (out / "metrics.json").write_text(json.dumps(metrics, indent=2))
