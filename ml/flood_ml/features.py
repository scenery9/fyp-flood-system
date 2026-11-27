"""Cleaning and feature building. Every feature at time t uses only readings
at or before t, so the model can never "see the future" (no data leakage)."""
import numpy as np
import pandas as pd

from .weather import FILL_INTERACTION, FORECAST_FEATURES, weather_features

HORIZON_H = 3
OWN_FEATURES = [
    "level_above_normal",
    "level_change_1h",
    "level_change_2h",
    "level_change_3h",
    "same_time_12h_ago",
    "same_time_25h_ago",
    "rain_sum_1h",
    "rain_sum_3h",
    "rain_sum_6h",
    "rain_sum_24h",
    "rain_sum_72h",  # rain over the last 3 days: how wet the ground already is
]
# Average over the stations listed as "upstream" of a station in stations.json.
# Left empty (NaN) for a station with no upstream stations or no upstream readings.
UPSTREAM_FEATURES = [
    "up_level_change_1h",
    "up_level_change_3h",
    "up_rain_sum_3h",
    "up_rain_sum_6h",
]
# Observed readings only (the model before weather forecasts were added; kept for the
# with/without comparison in rain_evidence.py).
BASE_FEATURES = OWN_FEATURES + UPSTREAM_FEATURES
# Rain history at the station: how long it has been raining, and how wet the ground is.
# All observed (no forecast). docs/literature.md explains why each one.
API_DECAY_PER_DAY = 0.85  # antecedent precipitation index: yesterday's rain counts 0.85, etc.
API_DAYS = 7
HISTORY_FEATURES = [
    "wet_hours_24h",          # hours with rain in the last 24 h
    "consecutive_wet_hours",  # length of the current unbroken run of rainy hours
    "wet_days_3d",            # of the last three 24 h windows, how many had >= 1 mm (ETCCDI wet day)
    "api_7d",                 # antecedent precipitation index over 7 days (older rain counts less)
]
# Plus the 3-day weather forecast: Open-Meteo mm and % chance, MET Malaysia class and
# warnings (weather.py), and forecast rain x how full the river already is. Empty (NaN)
# when no forecast was logged; tree models handle that.
FEATURES = BASE_FEATURES + HISTORY_FEATURES + FORECAST_FEATURES + [FILL_INTERACTION]
# Not model inputs: (level - normal) / (alert - normal), and alert - normal. Used for
# the interaction input and to pick out the "high-water" hours that flood scores use.
FILL, SPAN = "fill_to_alert", "alert_span_m"
# Also not inputs: the distance from Normal to each JPS level (probability.py, flood chance).
LEVEL_SPANS = {"alert": SPAN, "warning": "warning_span_m", "danger": "danger_span_m"}
# "What the river did next, one cycle ago": the change over the 3 hours that
# followed the same moment 12 h earlier (about one tide, 12.42 h) and 25 h earlier
# (about one lunar day, 24.84 h, which also covers the daily rhythm). Near the coast
# the tide drives most 3-hour changes (Taman Sri Muda: about 1.6 m a day), and each
# station's own history carries its own tide timing, so no tide table is needed.
CYCLE_INPUTS = {"same_time_12h_ago": 12, "same_time_25h_ago": 25}
TARGET = "target_change_m"
# Longer horizons, where day 1-3 rain forecasts can matter: the highest level in the
# next 24 / 72 hours minus the level now ("how far will it rise at most").
PEAK_HORIZONS_H = (24, 72)
PEAK_TARGETS = {h: f"target_peak_rise_{h}h" for h in PEAK_HORIZONS_H}
PEAK_MIN_COVERAGE = 0.75  # at least 75% of the hours ahead must have a reading
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
# Isolated spikes (any value, not just 0.00): one reading that jumps away from the reading
# before it and straight back to the reading after it, while those two agree
# (32.77 -> 15.97 -> 32.74). Two thresholds, as in the NOAA/IOOS QARTOD spike test:
# - SPIKE_FAIL_M: removed from the cleaned copy used for training and testing;
# - SPIKE_SUSPECT_M: kept, only counted (small blips may be waves or a gate moving).
# A jump that stays, of any size, is always kept: heavy rain (Kajang, 26 Nov 2026: up to
# 2.5 m in one hour), tides and gates all do that. The raw readings are never changed.
# Thresholds chosen on the logged data: see docs/dev-roadmap.md.
SPIKE_FAIL_M = 0.5
SPIKE_SUSPECT_M = 0.3
SPIKE_RETURN = 0.2       # the readings either side differ by at most 20% of the jump
SPIKE_WINDOW = pd.Timedelta(minutes=30)

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


def spike_size(level):
    """level: one station's readings, indexed by time, sorted. For each reading, the size of
    its isolated spike in metres (0 when it is not one): the smaller of the jump in and the
    jump out, when they go in opposite directions, the neighbours are within SPIKE_WINDOW and
    the neighbours agree to within SPIKE_RETURN of that size."""
    size = pd.Series(0.0, index=level.index)
    valid = level.dropna()
    if len(valid) < 3:
        return size
    t, x = valid.index, valid.to_numpy(float)
    jump_in, jump_out = x[1:-1] - x[:-2], x[2:] - x[1:-1]
    smaller = np.minimum(np.abs(jump_in), np.abs(jump_out))
    is_spike = ((np.sign(jump_in) * np.sign(jump_out) < 0)
                & (np.abs(x[2:] - x[:-2]) <= SPIKE_RETURN * smaller)
                & (t[1:-1] - t[:-2] <= SPIKE_WINDOW) & (t[2:] - t[1:-1] <= SPIKE_WINDOW))
    size.loc[t[1:-1]] = np.where(is_spike, smaller, 0.0)
    return size


def drop_spikes(level):
    """Returns (level with spikes >= SPIKE_FAIL_M made missing, number removed,
    number of suspect spikes kept). Works on a copy."""
    size = spike_size(level)
    fail = size >= SPIKE_FAIL_M
    suspect = (size >= SPIKE_SUSPECT_M) & ~fail
    return level.mask(fail), int(fail.sum()), int(suspect.sum())


def clean_readings(raw):
    """Columns needed: station_id, time, rainfall_mm, river_level_m.
    Returns one row per station per hour, with fault codes, 0.00 glitches and isolated
    spikes removed and river gaps of up to 2 hours filled in. `raw` is not changed.
    The counts of removed and suspect spikes are in the result's .attrs["spikes"]."""
    df = raw.copy()
    df["time"] = pd.to_datetime(df["time"], utc=True)
    for col in ("rainfall_mm", "river_level_m"):
        df[col] = pd.to_numeric(df[col], errors="coerce")
        df.loc[df[col] <= FAULT_BELOW, col] = np.nan
    df.loc[df["rainfall_mm"] < 0, "rainfall_mm"] = np.nan
    out, removed, suspect = [], {}, {}
    for sid, g in df.groupby("station_id"):
        g = g.drop_duplicates("time", keep="last").set_index("time").sort_index()
        g["river_level_m"] = drop_zero_glitches(g["river_level_m"])
        g["river_level_m"], n_fail, n_suspect = drop_spikes(g["river_level_m"])
        if n_fail:
            removed[sid] = n_fail
        if n_suspect:
            suspect[sid] = n_suspect
        hourly = pd.DataFrame({
            "rainfall_mm": g["rainfall_mm"].resample("1h").sum(min_count=1),
            "river_level_m": g["river_level_m"].resample("1h").last(),
        })
        hourly["river_level_m"] = hourly["river_level_m"].interpolate(limit=2, limit_area="inside")
        hourly["station_id"] = sid
        out.append(hourly.reset_index())
    cols = ["station_id", "time", "rainfall_mm", "river_level_m"]
    clean = pd.concat(out, ignore_index=True)[cols] if out else pd.DataFrame(columns=cols)
    clean.attrs["spikes"] = {"removed": sum(removed.values()), "suspect_kept": sum(suspect.values()),
                             "removed_by_station": removed, "suspect_by_station": suspect,
                             "fail_m": SPIKE_FAIL_M, "suspect_m": SPIKE_SUSPECT_M}
    return clean


def _own_series(g):
    """Per-station series used both for the station itself and as upstream input."""
    level, rain = g["river_level_m"], g["rainfall_mm"]
    s = pd.DataFrame({"time": g["time"]})
    s["level_change_1h"] = level - level.shift(1)
    s["level_change_2h"] = level - level.shift(2)
    s["level_change_3h"] = level - level.shift(3)
    s["rain_sum_1h"] = rain
    for h in (3, 6, 24, 72):
        s[f"rain_sum_{h}h"] = rain.rolling(h, min_periods=h).sum()
    for col, values in rain_history(rain).items():
        s[col] = values
    return s


def rain_history(rain):
    """HISTORY_FEATURES from one station's hourly rain (index in time order, NaN = no reading).
    Only rain at or before each hour is used."""
    rain = rain.astype(float)
    known = rain.notna()
    wet = (rain > 0).astype(float).where(known)
    out = {"wet_hours_24h": wet.rolling(24, min_periods=24).sum()}
    # current run of wet hours: counts back to the last dry (or unknown) hour
    run = (rain > 0).astype(int).to_numpy()
    length = np.zeros(len(run))
    for i, w in enumerate(run):
        length[i] = length[i - 1] + 1 if w and i > 0 else float(w)
    out["consecutive_wet_hours"] = pd.Series(length, index=rain.index).where(known)
    day = rain.rolling(24, min_periods=24).sum()
    windows = pd.concat([day, day.shift(24), day.shift(48)], axis=1)
    out["wet_days_3d"] = (windows >= 1.0).sum(axis=1).where(windows.notna().all(axis=1))
    # API: sum over the last 7 days of rain x decay^(age in days), hour by hour
    hours = API_DAYS * 24
    weights = API_DECAY_PER_DAY ** (np.arange(hours) / 24.0)  # weight of rain i hours ago
    filled = rain.fillna(0.0).to_numpy()
    api = np.convolve(filled, weights)[:len(filled)]
    seen = known.astype(float).rolling(hours, min_periods=1).sum().to_numpy()
    out["api_7d"] = pd.Series(np.where(seen >= 0.75 * hours, api, np.nan), index=rain.index)
    return out


def _linear_trend(level):
    """Change over the next HORIZON_H hours if the recent straight line continues.
    Slope of the least-squares line through 4 hourly points (x = -3..0):
    (-1.5*y[t-3] - 0.5*y[t-2] + 0.5*y[t-1] + 1.5*y[t]) / 5."""
    slope = (-1.5 * level.shift(3) - 0.5 * level.shift(2) + 0.5 * level.shift(1) + 1.5 * level) / 5.0
    change = slope * HORIZON_H
    return change.where(slope.abs() >= TREND_MIN_RATE_M_PER_H, 0.0).where(slope.notna())


def peak_rise(level, hours):
    """Highest level in the next `hours` hours (t+1 .. t+hours) minus the level at t.
    Rows are hourly, so this is a window of `hours` rows; empty when fewer than
    PEAK_MIN_COVERAGE of them have a reading."""
    ahead = level[::-1].rolling(hours, min_periods=int(np.ceil(hours * PEAK_MIN_COVERAGE))).max()[::-1].shift(-1)
    return ahead - level


def build_features(clean, stations, with_target=True, weather=None):
    """Adds FEATURES (and the training targets) to cleaned hourly readings.
    weather: flood_ml.weather.load_weather() result; without it the forecast inputs are empty."""
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
        g[SPAN] = by_id[sid]["alert"] - by_id[sid]["normal"]
        g[FILL] = g["level_above_normal"] / g[SPAN] if g[SPAN].iloc[0] > 0 else np.nan
        for name in ("warning", "danger"):
            g[LEVEL_SPANS[name]] = by_id[sid][name] - by_id[sid]["normal"]
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
            for h, col in PEAK_TARGETS.items():
                g[col] = peak_rise(level, h)
        out.append(g)
    if not out:
        extra = [LINEAR_TREND, FILL, *LEVEL_SPANS.values()] + ([TARGET, *PEAK_TARGETS.values()] if with_target else [])
        return pd.DataFrame(columns=list(clean.columns) + FEATURES + extra)
    feats = pd.concat(out, ignore_index=True)
    wf = weather_features(feats[["station_id", "time"]], weather)
    for col in FORECAST_FEATURES:
        feats[col] = wf[col].to_numpy()
    # forecast rain for the next 24 h, weighted by how full this river already is (0 at
    # Normal, 1 at Alert): the same rain means more for a river near Alert, and it is
    # different per station, so it cannot work as a "which day" label
    feats[FILL_INTERACTION] = feats["fc_rain_day1_mm"] * feats[FILL].clip(lower=0, upper=1.5)
    return feats


def risk_level(level, st):
    """0 Normal, 1 Alert (Waspada), 2 Warning (Amaran), 3 Danger (Bahaya)."""
    if level >= st["danger"]:
        return 3
    if level >= st["warning"]:
        return 2
    if level >= st["alert"]:
        return 1
    return 0
