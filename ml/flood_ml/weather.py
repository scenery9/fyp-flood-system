"""Weather forecast inputs for the model: Open-Meteo rain (mm, % chance) for the
next 3 hours and each of the next 3 days, MET Malaysia's official forecast class
and warnings, and whether the two sources agree.

Files (written by logger/jps_logger/weather.py, one per day under data/forecast/):
  openmeteo/    station_code, issued_at, valid_at, precip_mm, prob_pct, n_models, om_prob_pct
  met/          station_code, issued_at, valid_date, ..., rain_class, thunder
  met_warning/  station_code, issued_at, valid_from, valid_to, kind, level, title

No data leakage: an input at hour t only uses forecasts with issued_at <= t (the
latest such forecast for each future hour). Backfilled Open-Meteo rows are dated
1-3 days before the hour they are for (see logger/jps_logger/openmeteo.py), so
older hours in the archive get forecasts as they really were 1-3 days ahead.

Windows are counted from t (same as logger/jps_logger/outlook.py, which the app reads):
next 3 h = (t, t+3h], day 1 = (t, t+24h], day 2 = (t+24h, t+48h], day 3 = (t+48h, t+72h].
"""
from pathlib import Path

import numpy as np
import pandas as pd

RAIN_DAY_MM = 1.0           # ETCCDI wet day (docs/references.md)
MIN_HOURS_PER_DAY = 18      # a day window with fewer forecast hours is left empty
DAYS = (1, 2, 3)

FORECAST_FEATURES = [
    "fc_rain_next_3h",        # Open-Meteo, mm in the next 3 hours (8-model mean)
    "fc_rain_prob_next_3h",   # % of models forecasting a wet hour, highest hour in the next 3 h
    "fc_rain_day1_mm", "fc_rain_day2_mm", "fc_rain_day3_mm",
    "fc_rain_prob_day1", "fc_rain_prob_day2", "fc_rain_prob_day3",
    "fc_rain_days_3d",        # how many of the next 3 days are forecast rain days (>= 1 mm)
    "fc_rain_total_3d",       # mm over the next 72 hours
    "met_rain_class_day1", "met_rain_class_day2", "met_rain_class_day3",  # MET Malaysia 0-4
    "met_thunder_days_3d",    # days with ribut petir in the MET forecast
    "met_warning_level",      # MET warning in force in the next 24 h: 0 none, 1 Waspada, 2 Buruk, 3 Bahaya
    "sources_agree_days_3d",  # days on which Open-Meteo and MET agree on rain / no rain
]

# More forecast rain, a higher chance, a wetter MET class or a higher warning may only
# RAISE the river forecast (enforced by ensemble.py). "Sources agree" has no direction.
FILL_INTERACTION = "fc_rain_day1_x_fill"  # built in features.py (needs the river level)
RAISES_ONLY = frozenset([f for f in FORECAST_FEATURES if f != "sources_agree_days_3d"] + [FILL_INTERACTION])

# The forecast inputs that only look one day ahead (the rest add days 2 and 3).
NEXT_DAY_FEATURES = ["fc_rain_next_3h", "fc_rain_prob_next_3h", "fc_rain_day1_mm", "fc_rain_prob_day1",
                     "met_rain_class_day1", "met_warning_level"]


def _read(root, kind):
    paths = sorted((Path(root) / kind).glob("*/*/*.csv.gz"))
    if not paths:
        return pd.DataFrame()
    return pd.concat([pd.read_csv(p, compression="gzip", dtype={"station_code": str}) for p in paths],
                     ignore_index=True)


def load_weather(root):
    """{"openmeteo", "met", "met_warning"} DataFrames from a data/forecast folder (empty if missing)."""
    out = {}
    for kind in ("openmeteo", "met", "met_warning"):
        df = _read(root, kind)
        for col in ("issued_at", "valid_at", "valid_from", "valid_to"):
            if col in df:
                df[col] = pd.to_datetime(df[col], utc=True)
        out[kind] = df
    return out


def _open_meteo(q, om):
    """Open-Meteo inputs for query rows q (station_id, time)."""
    out = pd.DataFrame(index=q.index, columns=FORECAST_FEATURES[:10], dtype=float)
    if om is None or om.empty:
        return out
    om = om.rename(columns={"station_code": "station_id"})
    om = om[om["station_id"].isin(q["station_id"].unique())]
    if om.empty:
        return out
    ks = np.arange(1, 73)
    big = pd.DataFrame({
        "row": np.repeat(q.index.to_numpy(), len(ks)),
        "station_id": np.repeat(q["station_id"].to_numpy(), len(ks)),
        "time": np.repeat(q["time"].to_numpy(), len(ks)),
        "k": np.tile(ks, len(q)),
    })
    big["time"] = pd.to_datetime(big["time"], utc=True)
    big["valid_at"] = big["time"] + pd.to_timedelta(big["k"], unit="h")
    big = big.sort_values("time")
    right = om[["station_id", "valid_at", "issued_at", "precip_mm", "prob_pct"]].sort_values("issued_at")
    # Latest forecast for that hour issued at or before t: never a forecast made after t.
    m = pd.merge_asof(big, right, left_on="time", right_on="issued_at", by=["station_id", "valid_at"],
                      direction="backward")
    m["win"] = np.where(m["k"] <= 24, 1, np.where(m["k"] <= 48, 2, 3))
    g3 = m[m["k"] <= 3].groupby("row")
    out["fc_rain_next_3h"] = g3["precip_mm"].sum(min_count=3)
    out["fc_rain_prob_next_3h"] = g3["prob_pct"].max()
    for d in DAYS:
        g = m[m["win"] == d].groupby("row")
        mm = g["precip_mm"].sum(min_count=MIN_HOURS_PER_DAY)
        out[f"fc_rain_day{d}_mm"] = mm
        out[f"fc_rain_prob_day{d}"] = g["prob_pct"].max().where(mm.notna())
    days = out[[f"fc_rain_day{d}_mm" for d in DAYS]].astype(float)
    complete = days.notna().all(axis=1)
    out["fc_rain_days_3d"] = (days >= RAIN_DAY_MM).sum(axis=1).where(complete)
    out["fc_rain_total_3d"] = days.sum(axis=1).where(complete)
    return out.astype(float)


def _window_dates(times, d):
    """Malaysia date of the middle of window d for each time."""
    mid = pd.to_datetime(times, utc=True) + pd.Timedelta(hours=24 * (d - 1) + 12)
    return mid.dt.tz_convert("Asia/Kuala_Lumpur").dt.strftime("%Y-%m-%d")


def _met(q, met):
    cols = ["met_rain_class_day1", "met_rain_class_day2", "met_rain_class_day3", "met_thunder_days_3d"]
    out = pd.DataFrame(index=q.index, columns=cols, dtype=float)
    if met is None or met.empty:
        return out
    met = met.rename(columns={"station_code": "station_id"})
    issues = met[["station_id", "issued_at"]].drop_duplicates().sort_values("issued_at")
    left = q[["station_id", "time"]].copy()
    left["row"] = q.index
    left["time"] = pd.to_datetime(left["time"], utc=True)
    left = left.sort_values("time")
    used = pd.merge_asof(left, issues, left_on="time", right_on="issued_at", by="station_id",
                         direction="backward").set_index("row")
    look = met.set_index(["station_id", "issued_at", "valid_date"])[["rain_class", "thunder"]]
    look = look[~look.index.duplicated(keep="last")]
    thunder = pd.Series(0.0, index=q.index)
    seen = pd.Series(True, index=q.index)
    for d in DAYS:
        keys = pd.MultiIndex.from_arrays([used.loc[q.index, "station_id"], used.loc[q.index, "issued_at"],
                                          _window_dates(used.loc[q.index, "time"], d).to_numpy()])
        vals = look.reindex(keys)
        out[f"met_rain_class_day{d}"] = vals["rain_class"].to_numpy(dtype=float)
        thunder += vals["thunder"].fillna(0).to_numpy(dtype=float)
        seen &= vals["thunder"].notna().to_numpy()
    out["met_thunder_days_3d"] = thunder.where(seen)
    return out.astype(float)


def _warnings(q, warn):
    level = pd.Series(np.nan, index=q.index)
    if warn is None or warn.empty:
        return level
    times = pd.to_datetime(q["time"], utc=True)
    level[:] = 0.0  # warnings were being logged: "no warning" is a real 0
    first_issue = warn["issued_at"].min()
    level[times < first_issue] = np.nan  # before the first logged warning: unknown
    for _, w in warn.iterrows():
        mask = ((q["station_id"] == w["station_code"]) & (times >= w["issued_at"])
                & (pd.isna(w["valid_to"]) | (times <= w["valid_to"]))
                & (pd.isna(w["valid_from"]) | (times + pd.Timedelta(hours=24) >= w["valid_from"])))
        level[mask] = np.maximum(level[mask].fillna(0), float(w["level"]))
    return level


def weather_features(q, weather):
    """FORECAST_FEATURES for rows q (columns station_id, time), same index as q.
    weather: load_weather() result, or None (every input then empty)."""
    weather = weather or {}
    if q.empty:
        return pd.DataFrame(index=q.index, columns=FORECAST_FEATURES, dtype=float)
    out = pd.concat([_open_meteo(q, weather.get("openmeteo")), _met(q, weather.get("met"))], axis=1)
    out["met_warning_level"] = _warnings(q, weather.get("met_warning"))
    agree = []
    for d in DAYS:
        om_wet, met_wet = out[f"fc_rain_day{d}_mm"] >= RAIN_DAY_MM, out[f"met_rain_class_day{d}"] >= 1
        both = out[f"fc_rain_day{d}_mm"].notna() & out[f"met_rain_class_day{d}"].notna()
        agree.append((om_wet == met_wet).astype(float).where(both))
    a = pd.concat(agree, axis=1)
    out["sources_agree_days_3d"] = a.sum(axis=1).where(a.notna().all(axis=1))
    return out[FORECAST_FEATURES].astype(float)
