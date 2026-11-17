"""Rain per interval, worked out from JPS "todayRainfall" (total since midnight,
Malaysia time). JPS "hourlyRainfall" is a rolling 60-minute total: adding up
four 15-minute snapshots of it would count the same rain about four times.
"""
import numpy as np
import pandas as pd

MAX_GAP = pd.Timedelta(minutes=75)


def increments(rain):
    """rain: rows of one or more stations with station_code, observed_at (UTC), today_mm.
    Returns the same rows with rainfall_mm = rain since that station's previous reading.
    Left empty (NaN) for the first reading, after a gap over 75 minutes (the rain
    cannot be placed in time), or when the day total goes down (a JPS correction)."""
    df = rain.copy()
    df["observed_at"] = pd.to_datetime(df["observed_at"], utc=True)
    df = df.sort_values(["station_code", "observed_at"])
    local_day = df["observed_at"].dt.tz_convert("Asia/Kuala_Lumpur").dt.date
    g = df.groupby("station_code", sort=False)
    prev_total = g["today_mm"].shift(1)
    prev_time = g["observed_at"].shift(1)
    prev_day = local_day.groupby(df["station_code"], sort=False).shift(1)
    same_day = local_day == prev_day
    inc = np.where(same_day, df["today_mm"] - prev_total, df["today_mm"])  # new day: since midnight
    ok = (df["observed_at"] - prev_time <= MAX_GAP) & df["today_mm"].notna() & (inc >= 0)
    df["rainfall_mm"] = np.where(ok, inc, np.nan)
    return df
