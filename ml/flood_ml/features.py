"""Cleaning and feature building. Every feature at time t uses only readings
at or before t, so the model can never "see the future" (no data leakage)."""
import numpy as np
import pandas as pd

HORIZON_H = 3
OWN_FEATURES = [
    "level_above_normal",
    "level_change_1h",
    "level_change_3h",
    "same_time_12h_ago",
    "same_time_25h_ago",
    "rain_sum_1h",
    "rain_sum_3h",
    "rain_sum_6h",
    "rain_sum_24h",
]
# Average over the stations listed as "upstream" of a station in stations.json.
# Left empty (NaN) for a station with no upstream stations or no upstream readings.
UPSTREAM_FEATURES = [
    "up_level_change_1h",
    "up_level_change_3h",
    "up_rain_sum_3h",
    "up_rain_sum_6h",
]
FEATURES = OWN_FEATURES + UPSTREAM_FEATURES
# "What the river did next, one cycle ago": the change over the 3 hours that
# followed the same moment 12 h earlier (about one tide, 12.42 h) and 25 h earlier
# (about one lunar day, 24.84 h, which also covers the daily rhythm). Near the coast
# the tide drives most 3-hour changes (Taman Sri Muda: about 1.6 m a day), and each
# station's own history carries its own tide timing, so no tide table is needed.
CYCLE_INPUTS = {"same_time_12h_ago": 12, "same_time_25h_ago": 25}
TARGET = "target_change_m"
LINEAR_TREND = "linear_trend_change_m"  # baseline only, never a model input
FAULT_BELOW = -8888  # JPS codes: -9999 offline, -8888 estimated
# A level of exactly 0.00 that jumps away from the readings around it is a feed glitch
# (42.86 -> 0.00 -> 42.86). Levels below 0 are real (tide gates, river mouths), and so
# is a 0.00 the river passes through (-0.03 -> 0.00 -> 0.04), so only isolated jumps go.
# The logger applies the same rule as readings arrive (logger/jps_logger/collect.py).
ZERO_JUMP_M = 0.3
ZERO_NEIGHBOUR_H = 2
# Also a glitch: a V-shaped spike to 0.00 with the readings within 30 minutes on BOTH
# sides on the same side of 0 and at least 0.1 m from it (0.21 -> 0.00 -> 0.20). A tide
# crossing 0 goes from one side to the other, and a real low tide flattens out near 0.
ZERO_SPIKE_M = 0.1
ZERO_SPIKE_WINDOW = pd.Timedelta(minutes=30)

# Straight-line baseline, after the existing FloodWatch app (forecast.py):
# least-squares line through recent levels, extended HORIZON_H hours ahead.
# Slower changes than this are treated as "no change", as in that app.
TREND_MIN_RATE_M_PER_H = 0.02
TREND_POINTS = 4  # levels at t-3h, t-2h, t-1h and t


def validate_stations(stations):
    """Stops with a clear message if stations.json is inconsistent."""
    ids = [s["id"] for s in stations]
    if len(ids) != len(set(ids)):
        raise ValueError("stations.json: a station id is listed twice")
    for s in stations:
        if not s["normal"] <= s["alert"] <= s["warning"] <= s["danger"]:
            raise ValueError(f"stations.json: thresholds of {s['id']} are not in order")
        up = s.get("upstream", [])
        if s["id"] in up:
            raise ValueError(f"stations.json: {s['id']} lists itself as upstream")
        unknown = [u for u in up if u not in ids]
        if unknown:
            raise ValueError(f"stations.json: upstream of {s['id']} not in the file: {unknown}")


def drop_zero_glitches(level):
    """level: one station's readings, indexed by time, sorted. A 0.00 becomes missing when
    - every reading within ZERO_NEIGHBOUR_H hours before and after it (the nearest on
      each side) is more than ZERO_JUMP_M away, or
    - it is a spike: the nearest readings on both sides, within ZERO_SPIKE_WINDOW, are on
      the same side of 0 and at least ZERO_SPIKE_M from it.
    A 0.00 with no reading near it stays."""
    level = level.copy()
    valid = level.dropna()
    if not (valid == 0).any():
        return level
    near = pd.Timedelta(hours=ZERO_NEIGHBOUR_H)
    times, values = valid.index, valid.to_numpy()
    for i in np.flatnonzero(values == 0):
        sides = []
        if i > 0 and times[i] - times[i - 1] <= near:
            sides.append(values[i - 1])
        if i + 1 < len(values) and times[i + 1] - times[i] <= near:
            sides.append(values[i + 1])
        jump = bool(sides) and all(abs(v) > ZERO_JUMP_M for v in sides)
        spike = (0 < i < len(values) - 1
                 and times[i] - times[i - 1] <= ZERO_SPIKE_WINDOW and times[i + 1] - times[i] <= ZERO_SPIKE_WINDOW
                 and np.sign(values[i - 1]) == np.sign(values[i + 1])
                 and min(abs(values[i - 1]), abs(values[i + 1])) >= ZERO_SPIKE_M)
        if jump or spike:
            level.loc[times[i]] = np.nan
    return level


def clean_readings(raw):
    """Columns needed: station_id, time, rainfall_mm, river_level_m.
    Returns one row per station per hour, with fault codes removed and
    river gaps of up to 2 hours filled in."""
    df = raw.copy()
    df["time"] = pd.to_datetime(df["time"], utc=True)
    for col in ("rainfall_mm", "river_level_m"):
        df[col] = pd.to_numeric(df[col], errors="coerce")
        df.loc[df[col] <= FAULT_BELOW, col] = np.nan
    df.loc[df["rainfall_mm"] < 0, "rainfall_mm"] = np.nan
    out = []
    for sid, g in df.groupby("station_id"):
        g = g.drop_duplicates("time", keep="last").set_index("time").sort_index()
        g["river_level_m"] = drop_zero_glitches(g["river_level_m"])
        hourly = pd.DataFrame({
            "rainfall_mm": g["rainfall_mm"].resample("1h").sum(min_count=1),
            "river_level_m": g["river_level_m"].resample("1h").last(),
        })
        hourly["river_level_m"] = hourly["river_level_m"].interpolate(limit=2, limit_area="inside")
        hourly["station_id"] = sid
        out.append(hourly.reset_index())
    cols = ["station_id", "time", "rainfall_mm", "river_level_m"]
    if not out:
        return pd.DataFrame(columns=cols)
    return pd.concat(out, ignore_index=True)[cols]


def _own_series(g):
    """Per-station series used both for the station itself and as upstream input."""
    level, rain = g["river_level_m"], g["rainfall_mm"]
    s = pd.DataFrame({"time": g["time"]})
    s["level_change_1h"] = level - level.shift(1)
    s["level_change_3h"] = level - level.shift(3)
    s["rain_sum_1h"] = rain
    for h in (3, 6, 24):
        s[f"rain_sum_{h}h"] = rain.rolling(h, min_periods=h).sum()
    return s


def _linear_trend(level):
    """Change over the next HORIZON_H hours if the recent straight line continues.
    Slope of the least-squares line through 4 hourly points (x = -3..0):
    (-1.5*y[t-3] - 0.5*y[t-2] + 0.5*y[t-1] + 1.5*y[t]) / 5."""
    slope = (-1.5 * level.shift(3) - 0.5 * level.shift(2) + 0.5 * level.shift(1) + 1.5 * level) / 5.0
    change = slope * HORIZON_H
    return change.where(slope.abs() >= TREND_MIN_RATE_M_PER_H, 0.0).where(slope.notna())


def build_features(clean, stations, with_target=True):
    """Adds FEATURES (and the training target) to cleaned hourly readings."""
    by_id = {s["id"]: s for s in stations}
    series = {}
    for sid, g in clean.groupby("station_id"):
        series[sid] = _own_series(g.sort_values("time")).set_index("time")
    out = []
    for sid, g in clean.groupby("station_id"):
        if sid not in by_id:
            continue
        g = g.sort_values("time").copy()
        level = g["river_level_m"]
        g["level_above_normal"] = level - by_id[sid]["normal"]
        own = series[sid]
        for col in own.columns:
            g[col] = own[col].to_numpy()
        for col, h in CYCLE_INPUTS.items():
            g[col] = level.shift(h - HORIZON_H) - level.shift(h)  # only readings h-3 and h hours old
        ups = [series[u] for u in by_id[sid].get("upstream", []) if u in series]
        pairs = (("up_level_change_1h", "level_change_1h"), ("up_level_change_3h", "level_change_3h"),
                 ("up_rain_sum_3h", "rain_sum_3h"), ("up_rain_sum_6h", "rain_sum_6h"))
        for up_col, src in pairs:
            if ups:
                # mean over upstream stations that have a value at that hour
                avg = pd.concat([u[src] for u in ups], axis=1).mean(axis=1, skipna=True)
                g[up_col] = avg.reindex(g["time"]).to_numpy()
            else:
                g[up_col] = np.nan
        g[LINEAR_TREND] = _linear_trend(level)
        if with_target:
            g[TARGET] = level.shift(-HORIZON_H) - level  # change over the next 3 hours
        out.append(g)
    if not out:
        extra = [LINEAR_TREND] + ([TARGET] if with_target else [])
        return pd.DataFrame(columns=list(clean.columns) + FEATURES + extra)
    return pd.concat(out, ignore_index=True)


def risk_level(level, st):
    """0 Normal, 1 Alert (Waspada), 2 Warning (Amaran), 3 Danger (Bahaya)."""
    if level >= st["danger"]:
        return 3
    if level >= st["warning"]:
        return 2
    if level >= st["alert"]:
        return 1
    return 0
