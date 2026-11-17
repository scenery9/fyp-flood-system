"""Training and honest evaluation: time-based split, compared against two
baselines: "no change" (river stays where it is) and the straight-line trend
used by the existing FloodWatch app."""
import json
from pathlib import Path

import numpy as np
import pandas as pd
import xgboost as xgb

from .features import FEATURES, HORIZON_H, LINEAR_TREND, TARGET, risk_level

PARAMS = {
    "objective": "reg:squarederror",
    "max_depth": 4,
    "eta": 0.05,
    "subsample": 0.8,
    "colsample_bytree": 0.9,
    "seed": 7,
}
ROUNDS = 300


def time_split(feats, test_fraction=0.2):
    """Oldest data trains, newest data tests. Training rows whose 3-hour
    target reaches into the test period are dropped."""
    rows = feats.dropna(subset=[TARGET, "level_above_normal"])
    cutoff = rows["time"].quantile(1 - test_fraction)
    train = rows[rows["time"] + pd.Timedelta(hours=HORIZON_H) < cutoff]
    test = rows[rows["time"] >= cutoff]
    return train, test, cutoff


def train_model(train):
    return xgb.train(PARAMS, xgb.DMatrix(train[FEATURES], label=train[TARGET]), ROUNDS)


def evaluate(model, test, stations):
    by_id = {s["id"]: s for s in stations}
    pred = model.predict(xgb.DMatrix(test[FEATURES]))
    actual = test[TARGET].to_numpy()
    err = pred - actual
    mae, mae_base = float(np.mean(np.abs(err))), float(np.mean(np.abs(actual)))
    # Straight-line baseline. Where it has too few recent readings it gives no
    # forecast; it is then scored as "no change" and counted in fallback_rows.
    trend = test[LINEAR_TREND].to_numpy(dtype=float)
    fallback = np.isnan(trend)
    trend = np.where(fallback, 0.0, trend)
    err_lin = trend - actual
    mae_lin = float(np.mean(np.abs(err_lin)))
    now = test["river_level_m"].to_numpy()
    sts = [by_id[s] for s in test["station_id"]]
    true_hi = np.array([risk_level(l + a, s) >= 1 for l, a, s in zip(now, actual, sts)])
    pred_hi = np.array([risk_level(l + p, s) >= 1 for l, p, s in zip(now, pred, sts)])
    base_hi = np.array([risk_level(l, s) >= 1 for l, s in zip(now, sts)])
    lin_hi = np.array([risk_level(l + c, s) >= 1 for l, c, s in zip(now, trend, sts)])

    def pr(guess):
        tp = int(np.sum(guess & true_hi))
        return {
            "recall": tp / int(true_hi.sum()) if true_hi.any() else None,
            "precision": tp / int(guess.sum()) if guess.any() else None,
            "missed": int(np.sum(~guess & true_hi)),
            "false_alarms": int(np.sum(guess & ~true_hi)),
        }

    return {
        "horizon_hours": HORIZON_H,
        "test_rows": int(len(test)),
        "mae_m": mae,
        "rmse_m": float(np.sqrt(np.mean(err ** 2))),
        "baseline_mae_m": mae_base,
        "baseline_rmse_m": float(np.sqrt(np.mean(actual ** 2))),
        "skill_vs_baseline": 1 - mae / mae_base if mae_base > 0 else None,
        "linear_trend": {
            "mae_m": mae_lin,
            "rmse_m": float(np.sqrt(np.mean(err_lin ** 2))),
            "fallback_rows": int(fallback.sum()),
        },
        "skill_vs_linear_trend": 1 - mae / mae_lin if mae_lin > 0 else None,
        "alert_or_above": {"events": int(true_hi.sum()), "model": pr(pred_hi), "baseline": pr(base_hi),
                           "linear_trend": pr(lin_hi)},
        "band_m": float(np.quantile(np.abs(err), 0.8)),  # 80% of test errors are within this
    }


def save(model, metrics, out_dir):
    out = Path(out_dir)
    out.mkdir(parents=True, exist_ok=True)
    model.save_model(str(out / "model.json"))
    (out / "metrics.json").write_text(json.dumps(metrics, indent=2))
