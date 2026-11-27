"""Prediction metrics for the water-level forecast.

The model predicts a water LEVEL (in metres), so it is judged as a forecast of a
continuous value, not as a yes/no detector (no accuracy, precision, recall, F1, AUC).
Each metric compares the predicted level with the level the river really reached.

  MAE    mean absolute error, metres. The typical size of a miss.
  RMSE   root mean square error, metres. Like MAE but big misses count more.
  NSE    Nash-Sutcliffe efficiency (Nash & Sutcliffe 1970). 1 = perfect;
         0 = no better than guessing each station's average level; below 0 = worse.
  d      Willmott's index of agreement (Willmott 1981). 0 to 1; 1 = predicted and
         actual curves agree exactly. Sensitive to misses in timing and size.
  PI     persistence index (Kitanidis & Bras 1980). 1 = perfect; 0 = no better than
         "the river stays where it is now"; below 0 = worse. The hard test for a
         short-term river forecast, where "no change" is already a good guess.
  bias   mean error, metres. Above 0 = the model predicts too high on average.
  peak   peak error, metres: at each station's highest actual level in the period,
         |predicted - actual|, averaged over stations. A flood forecast must get the
         peaks right, which the averages above can hide.

Why NSE and d are worked out within each station: a river level is measured from a
local datum (one station reads 2 m at normal, another 20 m), so pooling stations
around one overall average would give NSE near 1 for any model. Each station's
actual levels are compared with that station's own average over the period instead.
Legates & McCabe (1999) recommend reporting a relative measure (NSE or d) together
with absolute errors (MAE, RMSE), which is the set used here.
"""
import numpy as np
import pandas as pd

NAMES = {
    "mae_m": "MAE (m)",
    "rmse_m": "RMSE (m)",
    "nse": "NSE",
    "willmott_d": "Willmott d",
    "persistence_index": "Persistence index",
    "bias_m": "Bias (m)",
    "peak_error_m": "Peak error (m)",
}


def _f(v):
    return None if v is None or not np.isfinite(v) else float(v)


def forecast_metrics(pred_change, rows, target):
    """pred_change: predicted change in level by the target time, one per row.
    rows: feature rows with station_id, time, river_level_m and the target column
    (the real change). Returns the metrics above (None where undefined)."""
    now = rows["river_level_m"].to_numpy(float)
    actual = now + rows[target].to_numpy(float)
    pred = now + np.asarray(pred_change, float)
    n = len(actual)
    if n == 0:
        return {k: None for k in NAMES} | {"rows": 0}
    err = pred - actual
    sse = float(np.sum(err ** 2))
    station = rows["station_id"].to_numpy()
    mean_obs = pd.Series(actual).groupby(station).transform("mean").to_numpy()
    dev_obs = actual - mean_obs
    sst = float(np.sum(dev_obs ** 2))
    agree = float(np.sum((np.abs(pred - mean_obs) + np.abs(dev_obs)) ** 2))
    ssp = float(np.sum((actual - now) ** 2))  # error of "no change"

    peaks = []
    frame = pd.DataFrame({"s": station, "a": actual, "e": np.abs(err)})
    for _, g in frame.groupby("s"):
        peaks.append(g["e"].to_numpy()[int(np.argmax(g["a"].to_numpy()))])

    return {
        "rows": int(n),
        "mae_m": float(np.mean(np.abs(err))),
        "rmse_m": float(np.sqrt(sse / n)),
        "nse": _f(1 - sse / sst) if sst > 0 else None,
        "willmott_d": _f(1 - sse / agree) if agree > 0 else None,
        "persistence_index": _f(1 - sse / ssp) if ssp > 0 else None,
        "bias_m": float(np.mean(err)),
        "peak_error_m": float(np.mean(peaks)),
    }
