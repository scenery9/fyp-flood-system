"""Exports logged readings as the CSV that ml/ trains on:
station_id,time,rainfall_mm,river_level_m

    python -m jps_logger.export --since 2026-11-17 --out readings.csv
    python -m jps_logger.export --since 2026-11-17 --stations ../ml/stations_klang.json --out readings.csv
    python -m jps_logger.export --since 2026-11-17 --no-database --out readings.csv

Older days come from the archive files in data/ (run `git pull` first to get the
newest ones); the last 30 days come from Supabase. Overlapping readings are counted once.
--stations limits the export to the stations in a stations file and their upstream stations.
--no-database uses the archive files only (no key needed).
Reading Supabase needs SUPABASE_URL and a key (the publishable key is enough: readings are public).
"""
import argparse
import json
from pathlib import Path

import pandas as pd

from .archive import DATA_DIR, read_archive
from .rain import increments

COLUMNS = ["station_id", "time", "rainfall_mm", "river_level_m"]


def codes_from_stations_file(path):
    stations = json.loads(Path(path).read_text())
    codes = {s["id"] for s in stations}
    for s in stations:
        codes.update(s.get("upstream", []))
    return sorted(codes)


def to_model_csv(levels, rain):
    """levels: station_code, observed_at, level_m. rain: station_code, observed_at, today_mm.
    The same reading given twice (archive and database) is counted once."""
    lv = pd.DataFrame(levels, columns=["station_code", "observed_at", "level_m"])
    rn = pd.DataFrame(rain, columns=["station_code", "observed_at", "today_mm"])
    lv["observed_at"] = pd.to_datetime(lv["observed_at"], utc=True)
    rn["observed_at"] = pd.to_datetime(rn["observed_at"], utc=True)
    lv = lv.drop_duplicates(["station_code", "observed_at"], keep="last")
    rn = rn.drop_duplicates(["station_code", "observed_at"], keep="last")
    rn = increments(rn) if len(rn) else rn.assign(rainfall_mm=pd.Series(dtype=float))
    rn["observed_at"] = pd.to_datetime(rn["observed_at"], utc=True)
    both = pd.merge(lv, rn[["station_code", "observed_at", "rainfall_mm"]],
                    on=["station_code", "observed_at"], how="outer")
    both = both.sort_values(["station_code", "observed_at"])
    out = pd.DataFrame({
        "station_id": both["station_code"],
        "time": both["observed_at"].dt.strftime("%Y-%m-%dT%H:%M:%SZ"),
        "rainfall_mm": both["rainfall_mm"],
        "river_level_m": both["level_m"],
    })
    return out[COLUMNS].reset_index(drop=True)


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--since", required=True, help="first date or time to export (UTC), e.g. 2026-11-17")
    p.add_argument("--stations", help="only these stations (a stations JSON file) and their upstream stations")
    p.add_argument("--data", default=str(DATA_DIR), help="archive folder (default: data/ in the repository)")
    p.add_argument("--no-database", action="store_true", help="use the archive files only")
    p.add_argument("--out", default="readings.csv")
    a = p.parse_args()
    since_ts = pd.Timestamp(a.since, tz="UTC")
    since = since_ts.strftime("%Y-%m-%dT%H:%M:%SZ")
    codes = codes_from_stations_file(a.stations) if a.stations else None

    levels, rain = read_archive(a.data, (since_ts - pd.Timedelta(days=1)).date())
    keep = lambda r: (codes is None or r["station_code"] in codes) and pd.Timestamp(r["observed_at"]) >= since_ts
    levels, rain = [r for r in levels if keep(r)], [r for r in rain if keep(r)]
    if not a.no_database:
        from .store import Store
        store = Store()
        filters = [("observed_at", f"gte.{since}")]
        if codes:
            filters.append(("station_code", "in.(" + ",".join(codes) + ")"))
        levels += store.select_all("jps_river_levels", "station_code,observed_at,level_m", filters)
        rain += store.select_all("jps_rainfall", "station_code,observed_at,today_mm", filters)
    df = to_model_csv(levels, rain)
    df.to_csv(a.out, index=False)
    print(f"Wrote {len(df)} rows for {df['station_id'].nunique()} stations to {a.out}")


if __name__ == "__main__":
    main()
