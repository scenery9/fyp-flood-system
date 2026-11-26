"""Training and honest evaluation: time-based split, compared against two
baselines: "no change" (river stays where it is) and the straight-line trend
used by the existing FloodWatch app. The model is the weighted tree ensemble
in ensemble.py."""
import json
from pathlib import Path

import numpy as np
import pandas as pd

from .ensemble import TreeEnsemble
from .features import HORIZON_H, LINEAR_TREND, TARGET, risk_level


def time_split(feats, test_fraction=0.2):
    """Oldest data trains, newest data tests. Training rows whose 3-hour
    target reaches into the test period are dropped."""
    rows = feats.dropna(subset=[TARGET, "level_above_normal"])
    cutoff = rows["time"].quantile(1 - test_fraction)
    train = rows[rows["time"] + pd.Timedelta(hours=HORIZON_H) < cutoff]
    test = rows[rows["time"] >= cutoff]
    return train, test, cutoff


def train_model(train, fast=False):
    """The weighted tree ensemble (XGBoost, LightGBM, CatBoost, random forest)."""
    return TreeEnsemble.fit(train, fast=fast)


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


def _ratio(a, b):
    return a / b if b else None


def _f1(p, r):
    if p is None or r is None:
        return None
    return 2 * p * r / (p + r) if p + r > 0 else 0.0


def classification_metrics(pred_change, test, stations):
    """Scores a 3-hour level forecast as a classification of the risk level it
    leads to, against the risk level the river really reached.

    - "alert_or_above": binary (Alert or higher vs Normal). Confusion counts,
      accuracy, precision, recall, F1 and AUC. The AUC score is how far the
      forecast level is above the station's Alert line, in metres.
    - "risk_level": the 4 levels (0 Normal .. 3 Danger). 4x4 confusion matrix
      (rows = actual, columns = forecast), accuracy and macro F1."""
    by_id = {s["id"]: s for s in stations}
    sts = [by_id[s] for s in test["station_id"]]
    now = test["river_level_m"].to_numpy(dtype=float)
    actual = test[TARGET].to_numpy(dtype=float)
    pred = np.asarray(pred_change, dtype=float)
    true_lv = np.array([risk_level(l + a, s) for l, a, s in zip(now, actual, sts)])
    pred_lv = np.array([risk_level(l + p, s) for l, p, s in zip(now, pred, sts)])
    true_hi, pred_hi = true_lv >= 1, pred_lv >= 1
    tp = int(np.sum(pred_hi & true_hi))
    fp = int(np.sum(pred_hi & ~true_hi))
    fn = int(np.sum(~pred_hi & true_hi))
    tn = int(np.sum(~pred_hi & ~true_hi))
    n = len(test)
    precision, recall = _ratio(tp, tp + fp), _ratio(tp, tp + fn)
    margin = now + pred - np.array([s["alert"] for s in sts])

    cm = np.zeros((4, 4), dtype=int)
    for t, p in zip(true_lv, pred_lv):
        cm[t, p] += 1
    f1s = []
    for k in range(4):
        if cm[k, :].sum() == 0 and cm[:, k].sum() == 0:
            continue  # level never seen nor forecast: left out of the macro average
        pk, rk = _ratio(int(cm[k, k]), int(cm[:, k].sum())), _ratio(int(cm[k, k]), int(cm[k, :].sum()))
        f1s.append(_f1(pk or 0.0, rk or 0.0))
    return {
        "alert_or_above": {
            "confusion": {"tn": tn, "fp": fp, "fn": fn, "tp": tp},
            "accuracy": _ratio(tp + tn, n),
            "precision": precision,
            "recall": recall,
            "f1": _f1(precision, recall),
            "auc": auc(margin, true_hi),
        },
        "risk_level": {
            "labels": ["Normal", "Alert", "Warning", "Danger"],
            "confusion_matrix": cm.tolist(),
            "accuracy": _ratio(int(np.trace(cm)), n),
            "macro_f1": float(np.mean(f1s)) if f1s else None,
        },
    }


def regression_metrics(pred_change, test):
    actual = test[TARGET].to_numpy(dtype=float)
    err = np.asarray(pred_change, dtype=float) - actual
    mae_base = float(np.mean(np.abs(actual)))
    mae = float(np.mean(np.abs(err)))
    return {
        "mae_m": mae,
        "rmse_m": float(np.sqrt(np.mean(err ** 2))),
        "skill_vs_baseline": 1 - mae / mae_base if mae_base > 0 else None,
        "band_m": float(np.quantile(np.abs(err), 0.8)),
    }


def linear_trend_prediction(test):
    """FloodWatch straight-line forecast; rows with too few readings count as
    "no change". Returns (prediction, fallback mask)."""
    trend = test[LINEAR_TREND].to_numpy(dtype=float)
    fallback = np.isnan(trend)
    return np.where(fallback, 0.0, trend), fallback


def evaluate(model, test, stations):
    by_id = {s["id"]: s for s in stations}
    pred = model.predict(test)
    actual = test[TARGET].to_numpy()
    err = pred - actual
    mae, mae_base = float(np.mean(np.abs(err))), float(np.mean(np.abs(actual)))
    # Straight-line baseline. Where it has too few recent readings it gives no
    # forecast; it is then scored as "no change" and counted in fallback_rows.
    trend, fallback = linear_trend_prediction(test)
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
        "model": model.describe(),
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
        # Supervisor's classification view of the same forecasts (confusion
        # matrix, accuracy, precision, recall, F1, AUC).
        "classification": {
            "model": classification_metrics(pred, test, stations),
            "baseline": classification_metrics(np.zeros(len(test)), test, stations),
            "linear_trend": classification_metrics(trend, test, stations),
        },
        "by_state": by_state(pred, test, stations),
    }


def by_state(pred, test, stations):
    """The model's main measures for each state's stations on their own, so a good
    overall score cannot hide a state the model does badly in ("state" in the
    stations file; Selangor when not given)."""
    state = {s["id"]: s.get("state", "Selangor") for s in stations}
    states = test["station_id"].map(state).to_numpy()
    out = {}
    for name in sorted(set(states)):
        mask = states == name
        part = test[mask]
        p = np.asarray(pred, dtype=float)[mask]
        reg = regression_metrics(p, part)
        cls = classification_metrics(p, part, stations)["alert_or_above"]
        out[name] = {
            "stations": int(part["station_id"].nunique()),
            "test_rows": int(mask.sum()),
            "mae_m": reg["mae_m"],
            "baseline_mae_m": float(np.mean(np.abs(part[TARGET].to_numpy(dtype=float)))),
            "alert_or_above_events": int(cls["confusion"]["tp"] + cls["confusion"]["fn"]),
            "recall": cls["recall"],
            "precision": cls["precision"],
            "f1": cls["f1"],
            "auc": cls["auc"],
        }
    return out


def save(model, metrics, out_dir):
    out = Path(out_dir)
    out.mkdir(parents=True, exist_ok=True)
    model.save(out)  # out/model/: one file per tree model + ensemble.json (weights)
    (out / "metrics.json").write_text(json.dumps(metrics, indent=2))
