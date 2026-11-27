"""Flood-focused scores, used to choose between models and inputs.

Overall MAE is dominated by quiet hours, when the river barely moves. A flood
forecast is judged first on the hours that matter:

  high-water hours   the river is at least HIGH_WATER_FILL of the way from Normal to
                     Alert now, or the target takes it to Alert or above

Every candidate also gets the full prediction metrics (metrics.py: MAE, RMSE, NSE,
Willmott's d, persistence index, bias, peak error), overall and on high-water hours.

Choice rule (choose): among candidates whose overall MAE is within MAE_GUARD of
the best overall MAE, take the lowest high-water MAE (ties: the earlier, simpler one).
So a model may not buy a better flood score with a much worse everyday forecast.
"""
import numpy as np

from .features import FILL, SPAN
from .metrics import forecast_metrics

HIGH_WATER_FILL = 0.5
MAE_GUARD = 1.05


def high_water(rows, y):
    fill = rows[FILL].to_numpy(float)
    span = rows[SPAN].to_numpy(float)
    after = fill + np.asarray(y, float) / np.where(span > 0, span, np.nan)
    return (fill >= HIGH_WATER_FILL) | (after >= 1.0)


def flood_scores(pred, rows, target):
    y = rows[target].to_numpy(float)
    pred = np.asarray(pred, float)
    err = np.abs(pred - y)
    hw = high_water(rows, y)
    return {
        "mae_m": float(err.mean()) if len(err) else None,
        "high_water_mae_m": float(err[hw].mean()) if hw.any() else None,
        "high_water_rows": int(hw.sum()),
        "rows": int(len(y)),
        "metrics": forecast_metrics(pred, rows, target),
        "high_water_metrics": (forecast_metrics(pred[hw], rows[hw], target) if hw.any() else {"rows": 0}),
    }


def choose(scores):
    """Name of the best candidate. scores: {name: flood_scores(...)} in order of preference."""
    names = [n for n, s in scores.items() if s.get("mae_m") is not None]
    if not names:
        return None
    best = min(scores[n]["mae_m"] for n in names)
    ok = [n for n in names if scores[n]["mae_m"] <= best * MAE_GUARD + 1e-12]
    if all(scores[n]["high_water_mae_m"] is None for n in ok):
        return min(ok, key=lambda n: (scores[n]["mae_m"], names.index(n)))
    return min(ok, key=lambda n: (scores[n]["high_water_mae_m"] if scores[n]["high_water_mae_m"] is not None
                                  else np.inf, names.index(n)))
