"""Generated PRACTICE readings, so the pipeline can be built and tested before
real data exists. The river responds to its own rain about 2 hours later and,
for stations with "upstream" stations, to upstream rain about 4 hours later,
through a simple "leaky bucket".
Nothing here is real: never report results from this data as findings."""
import numpy as np
import pandas as pd


def make_practice_readings(stations, end, days=120, seed=7):
    """Hourly readings per station, ending at `end` (UTC). Includes a few
    sensor fault codes (-9999) and missing hours, like a real feed."""
    rng = np.random.default_rng(seed)
    end = pd.Timestamp(end).tz_convert("UTC").floor("h")
    times = pd.date_range(end=end, periods=days * 24, freq="h")
    n = len(times)
    rains = {}
    for st in stations:
        rain = np.zeros(n)
        t = 0
        while t < n:
            if rng.random() < 0.02:  # a storm starts
                length = int(rng.integers(2, 9))
                rain[t:t + length] = rng.gamma(2.0, 6.0, size=min(length, n - t))
                t += length
            else:
                t += 1
        rains[st["id"]] = rain
    frames = []
    for st in stations:
        rain = rains[st["id"]]
        ups = [rains[u] for u in st.get("upstream", []) if u in rains]
        up_rain = np.mean(ups, axis=0) if ups else np.zeros(n)
        span = st["danger"] - st["normal"]
        gain = span / 110.0  # about 110 mm of effective rain reaches danger
        storage = np.zeros(n)
        for i in range(1, n):
            delayed = rain[i - 2] if i >= 2 else 0.0  # river reacts about 2 h later
            from_up = 0.7 * up_rain[i - 4] if i >= 4 else 0.0  # upstream water arrives about 4 h later
            storage[i] = 0.93 * storage[i - 1] + gain * (delayed + from_up)
        level = st["normal"] - 0.3 * span * 0.2 + storage + rng.normal(0, 0.01, n)
        df = pd.DataFrame({
            "station_id": st["id"],
            "time": times,
            "rainfall_mm": np.round(rain, 1),
            "river_level_m": np.round(level, 2),
        })
        fault = rng.random(n) < 0.01
        fault[-6:] = False  # keep the latest hours clean so a forecast is possible
        df.loc[fault, "river_level_m"] = -9999.0
        keep = rng.random(n) >= 0.005
        keep[-24:] = True  # full last day, so every input of the latest forecast has a value
        frames.append(df[keep])
    return pd.concat(frames, ignore_index=True)


def make_practice_weather(raw, every_h=6, noise=0.3, seed=7):
    """PRACTICE Open-Meteo forecasts in the logged format (load_weather()["openmeteo"]):
    every `every_h` hours a 72-hour forecast for each station, made from the station's
    own practice rain in those hours with multiplicative noise (so it is informative
    but not perfect). Nothing here is real."""
    rng = np.random.default_rng(seed)
    df = raw[["station_id", "time", "rainfall_mm"]].copy()
    df["time"] = pd.to_datetime(df["time"], utc=True)
    rows = []
    for sid, g in df.groupby("station_id"):
        rain = g.set_index("time")["rainfall_mm"].clip(lower=0).resample("1h").sum()
        # the practice future after the last reading: dry, so the latest hour has a full forecast too
        rain = rain.reindex(pd.date_range(rain.index[0], rain.index[-1] + pd.Timedelta(hours=72), freq="h"),
                            fill_value=0.0)
        issues = rain.index[:-72][::every_h].append(rain.index[-73:-72])
        for t in issues:
            ahead = rain[(rain.index > t) & (rain.index <= t + pd.Timedelta(hours=72))]
            fc = ahead.to_numpy() * rng.lognormal(0, noise, len(ahead))
            rows.append(pd.DataFrame({
                "station_code": sid, "issued_at": t, "valid_at": ahead.index,
                "precip_mm": np.round(fc, 2), "prob_pct": np.where(fc >= 0.1, 88.0, 12.0),
                "n_models": 8, "om_prob_pct": np.nan}))
    om = pd.concat(rows, ignore_index=True) if rows else pd.DataFrame()
    return {"openmeteo": om, "met": pd.DataFrame(), "met_warning": pd.DataFrame()}
