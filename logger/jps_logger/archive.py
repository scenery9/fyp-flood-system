"""Daily archive: keeps Supabase small enough for the free plan for as long as needed.

    python -m jps_logger.archive archive      # write finished days to data/YYYY/MM/YYYY-MM-DD.csv.gz
    python -m jps_logger.archive cleanup      # delete archived days older than 30 days from Supabase
    python -m jps_logger.archive check-size   # warn at 300 MB, fail at 400 MB (free limit 500 MB)

Days are Malaysia days (00:00-24:00, UTC+8). A day is archived once it is at least
two days old: the logger never stores readings more than 24 hours old, so nothing
can arrive for it later. A day is only deleted from Supabase if its archive file
exists, so a failed archive never loses data. Run in this order, committing the
files in between (the GitHub workflow does this).
"""
import argparse
import gzip
import io
import sys
from datetime import date, datetime, time, timedelta, timezone
from pathlib import Path

import pandas as pd

from .jps import MYT

DATA_DIR = Path(__file__).resolve().parents[2] / "data"
KEEP_DAYS = 30
CLOSE_AFTER_DAYS = 2
WARN_MB, FAIL_MB = 300.0, 400.0
COLUMNS = ["kind", "station_code", "observed_at", "level_m", "hourly_mm", "today_mm"]
TABLES = {"level": ("jps_river_levels", "station_code,observed_at,level_m"),
          "rain": ("jps_rainfall", "station_code,observed_at,hourly_mm,today_mm")}


def today_myt(now=None):
    return (now or datetime.now(timezone.utc)).astimezone(MYT).date()


def day_bounds(d):
    """UTC start and end (ISO) of a Malaysia day."""
    start = datetime.combine(d, time(0), tzinfo=MYT).astimezone(timezone.utc)
    fmt = "%Y-%m-%dT%H:%M:%SZ"
    return start.strftime(fmt), (start + timedelta(days=1)).strftime(fmt)


def day_of(iso):
    return pd.Timestamp(iso).tz_convert("Asia/Kuala_Lumpur").date()


def archive_path(root, d):
    return Path(root) / f"{d:%Y}" / f"{d:%m}" / f"{d:%Y-%m-%d}.csv.gz"


def write_day(path, levels, rain):
    """One file per day with both kinds of reading. Written the same way every time
    (sorted, no timestamp inside the gzip), so re-running never changes the file."""
    rows = [{"kind": "level", **r} for r in levels] + [{"kind": "rain", **r} for r in rain]
    df = pd.DataFrame(rows, columns=COLUMNS)
    if len(df):
        df["observed_at"] = pd.to_datetime(df["observed_at"], utc=True).dt.strftime("%Y-%m-%dT%H:%M:%SZ")
        df = df.sort_values(["kind", "station_code", "observed_at"])
    text = df.to_csv(index=False, lineterminator="\n")
    path.parent.mkdir(parents=True, exist_ok=True)
    buf = io.BytesIO()
    with gzip.GzipFile(filename="", mode="wb", fileobj=buf, mtime=0) as gz:
        gz.write(text.encode("utf-8"))
    path.write_bytes(buf.getvalue())
    return len(df)


def read_day(path):
    return pd.read_csv(path, compression="gzip", dtype={"station_code": str})


def read_archive(root, since_day):
    """(levels, rain) row lists from every archive file on or after since_day."""
    frames = [read_day(p) for p in sorted(Path(root).glob("*/*/*.csv.gz"))
              if date.fromisoformat(p.name[:10]) >= since_day]
    if not frames:
        return [], []
    df = pd.concat(frames, ignore_index=True)
    levels = df[df["kind"] == "level"][["station_code", "observed_at", "level_m"]]
    rain = df[df["kind"] == "rain"][["station_code", "observed_at", "hourly_mm", "today_mm"]]
    return levels.to_dict("records"), rain.to_dict("records")


def _first_day(store):
    times = [t for t in (store.first_time(t) for t, _ in TABLES.values()) if t]
    return min(day_of(t) for t in times) if times else None


def days_to_archive(first_day, today, root):
    if first_day is None:
        return []
    last = today - timedelta(days=CLOSE_AFTER_DAYS)
    days, d = [], first_day
    while d <= last:
        if not archive_path(root, d).exists():
            days.append(d)
        d += timedelta(days=1)
    return days


def run_archive(store, root, today, out=print):
    written = 0
    for d in days_to_archive(_first_day(store), today, root):
        start, end = day_bounds(d)
        span = [("observed_at", f"gte.{start}"), ("observed_at", f"lt.{end}")]
        levels = store.select_all(*TABLES["level"], span)
        rain = store.select_all(*TABLES["rain"], span)
        n = write_day(archive_path(root, d), levels, rain)
        out(f"Archived {d}: {n} readings")
        written += 1
    out(f"{written} day(s) archived")
    return 0


def run_cleanup(store, root, today, out=print):
    first = _first_day(store)
    if first is None:
        out("Nothing stored yet")
        return 0
    keep_from = today - timedelta(days=KEEP_DAYS)
    deleted, d = 0, first
    while d < keep_from:
        if archive_path(root, d).exists():
            start, end = day_bounds(d)
            for table, _ in TABLES.values():
                store.delete_between(table, start, end)
            deleted += 1
        else:
            out(f"::warning::{d} is older than {KEEP_DAYS} days but has no archive file; kept in Supabase")
        d += timedelta(days=1)
    out(f"{deleted} archived day(s) removed from Supabase; keeping {keep_from} onwards")
    return 0


def check_size(store, out=print):
    mb = store.storage_mb()
    if mb >= FAIL_MB:
        out(f"::error::Supabase database is {mb:.0f} MB (free limit 500 MB). Lower KEEP_DAYS in archive.py.")
        return 1
    if mb >= WARN_MB:
        out(f"::warning::Supabase database is {mb:.0f} MB (free limit 500 MB)")
    else:
        out(f"Supabase database is {mb:.0f} MB (free limit 500 MB)")
    return 0


def main():
    p = argparse.ArgumentParser()
    p.add_argument("step", choices=["archive", "cleanup", "check-size"])
    p.add_argument("--data", default=str(DATA_DIR), help="archive folder (default: data/ in the repository)")
    a = p.parse_args()
    from .store import Store
    store = Store()
    if a.step == "archive":
        code = run_archive(store, a.data, today_myt())
    elif a.step == "cleanup":
        code = run_cleanup(store, a.data, today_myt())
    else:
        code = check_size(store)
    sys.exit(code)


if __name__ == "__main__":
    main()
