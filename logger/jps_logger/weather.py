"""Weather forecast logger: Open-Meteo (mm, % chance) and MET Malaysia (official
forecast text and warnings), 3 days ahead, for every river station.

    python -m jps_logger.weather collect               # read both, store in Supabase, update weather_outlook
    python -m jps_logger.weather collect --dry-run     # read both, store nothing, print a summary
    python -m jps_logger.weather collect --to-files    # also write data/forecast/ files (no Supabase needed with --dry-run)
    python -m jps_logger.weather backfill --start 2026-11-16 --end 2026-11-28
                                                       # Open-Meteo forecasts as they were made 1-3 days earlier
    python -m jps_logger.weather archive               # finished days from Supabase to data/forecast/
    python -m jps_logger.weather cleanup               # delete archived days older than 30 days from Supabase

Files (one per Malaysia day of issue, written the same way every time):
    data/forecast/openmeteo/YYYY/MM/YYYY-MM-DD.csv.gz   openmeteo.COLUMNS
    data/forecast/met/YYYY/MM/YYYY-MM-DD.csv.gz         metmalaysia.FORECAST_COLUMNS
    data/forecast/met_warning/YYYY/MM/YYYY-MM-DD.csv.gz metmalaysia.WARNING_COLUMNS

Stations: the river stations in jps_stations (Supabase), or --stations FILE
(e.g. ../ml/stations_training.json, which has positions). Stations with no
position get their district's average (stations_file.add_positions).
MET Malaysia and Open-Meteo are read separately: if one fails the other is still stored.
"""
import argparse
import gzip
import io
import json
import sys
from datetime import datetime, timedelta, timezone
from pathlib import Path

import pandas as pd
import requests

from . import metmalaysia as met
from . import openmeteo as om
from .archive import DATA_DIR, KEEP_DAYS, day_bounds, today_myt
from .outlook import outlooks

FORECAST_DIR = DATA_DIR / "forecast"
# name: (table, columns, time column used for days, key columns)
KINDS = {
    "openmeteo": ("weather_forecast", om.COLUMNS, "issued_at", ["station_code", "issued_at", "valid_at"]),
    "met": ("met_forecast", met.FORECAST_COLUMNS, "issued_at", ["station_code", "issued_at", "valid_date"]),
    "met_warning": ("met_warning", met.WARNING_COLUMNS, "issued_at", ["station_code", "issued_at", "kind"]),
}


def path_for(root, kind, d):
    return Path(root) / kind / f"{d:%Y}" / f"{d:%m}" / f"{d:%Y-%m-%d}.csv.gz"


def _day(iso):
    return pd.Timestamp(iso).tz_convert("Asia/Kuala_Lumpur").date()


def read_kind(root, kind):
    """Every row of one kind from the files under root (a DataFrame, possibly empty)."""
    cols = KINDS[kind][1]
    frames = [pd.read_csv(p, compression="gzip", dtype={"station_code": str})
              for p in sorted((Path(root) / kind).glob("*/*/*.csv.gz"))]
    return pd.concat(frames, ignore_index=True) if frames else pd.DataFrame(columns=cols)


def write_rows(root, kind, rows):
    """Adds rows to the day files (by Malaysia day of issue), keeping rows already
    there; the same row twice is kept once. Returns the number of files written."""
    _, cols, tcol, key = KINDS[kind]
    return write_table(Path(root) / kind, rows, cols, tcol, key)


def write_table(folder, rows, cols, tcol, key):
    """Adds rows to folder/YYYY/MM/YYYY-MM-DD.csv.gz by the Malaysia day of column tcol,
    keeping rows already there (same key: the new row wins). Written the same way every
    time, so re-running never changes a file. Returns the number of files written."""
    if not rows:
        return 0
    new = pd.DataFrame(rows, columns=cols)
    new = new[new[tcol].notna()]
    written = 0
    for d, part in new.groupby(new[tcol].map(_day)):
        path = Path(folder) / f"{d:%Y}" / f"{d:%m}" / f"{d:%Y-%m-%d}.csv.gz"
        old = pd.read_csv(path, compression="gzip", dtype={"station_code": str}) if path.exists() else None
        df = pd.concat([old, part], ignore_index=True) if old is not None else part
        df = df.drop_duplicates(key, keep="last").sort_values(key)[cols]
        text = df.to_csv(index=False, lineterminator="\n")
        path.parent.mkdir(parents=True, exist_ok=True)
        buf = io.BytesIO()
        with gzip.GzipFile(filename="", mode="wb", fileobj=buf, mtime=0) as gz:
            gz.write(text.encode("utf-8"))
        if not path.exists() or path.read_bytes() != buf.getvalue():
            path.write_bytes(buf.getvalue())
            written += 1
    return written


def incident_points(store, now):
    """Forecast points at the places of current JKR incidents (jkr.py), so the forecast also
    covers the areas where floods and landslides are being reported, not only river stations.
    From Supabase (jkr_incident seen in the last day) or, without it, read live from the portal."""
    from . import jkr
    try:
        if store is not None:
            since = (now - timedelta(days=1)).strftime(jkr.FMT)
            rows = store.select("jkr_incident", [("select", "incident_id,lat,lon,district,state,type"),
                                                 ("last_seen_at", f"gte.{since}")])
        else:
            rows = [jkr.clean(r, now.strftime(jkr.FMT)) for r in jkr.fetch()]
    except Exception as e:  # noqa: BLE001 - the river stations still get their forecast
        print(f"::warning::JKR incident locations could not be read: {e}")
        return []
    return jkr.incident_points(rows)


def load_stations(path=None, store=None):
    """[{id, district, state, lat, lon}] for the river stations."""
    if path:
        return json.loads(Path(path).read_text(encoding="utf-8"))
    from .stations_file import add_positions
    rows = store.select("jps_stations", [("select", "station_code,name,district,state,lat,lon"),
                                         ("has_river_level", "eq.true")])
    entries = [{"id": r["station_code"], "name": r["name"], "district": r.get("district"),
                "state": r.get("state") or "Selangor"} for r in rows]
    stations, _ = add_positions(entries, rows)
    return stations


def collect(stations, now, store=None, files_root=None, out=print, session=None):
    """One run: both sources, stored separately. Returns 0, or 1 if nothing at all was read."""
    session = session or requests.Session()
    got = {}
    try:
        got["openmeteo"] = om.fetch_live(stations, now, session)
    except Exception as e:  # noqa: BLE001 - one source failing must not stop the other
        out(f"::warning::Open-Meteo could not be read: {e}")
    unknown = set()
    try:
        got["met"] = met.forecast_rows(met.get_json("forecast", session), stations, now, unknown)
    except Exception as e:  # noqa: BLE001
        out(f"::warning::MET Malaysia forecast could not be read: {e}")
    try:
        got["met_warning"] = met.warning_rows(met.get_json("warning", session), stations)
    except Exception as e:  # noqa: BLE001
        out(f"::warning::MET Malaysia warnings could not be read: {e}")
    for phrase in sorted(unknown):
        out(f"::warning::MET Malaysia phrase not in metmalaysia.py's table (left empty): {phrase!r}")
    if not got:
        out("::error::No weather source could be read")
        return 1
    codes = [s["id"] for s in stations]
    ol = outlooks(codes, got.get("openmeteo", []), got.get("met", []), got.get("met_warning", []), now)
    for kind, rows in got.items():
        out(f"{kind}: {len(rows)} rows")
    if store is not None:
        for kind, rows in got.items():
            table, _, _, key = KINDS[kind]
            store.insert(table, rows, key, update_existing=True)
        store.insert("weather_outlook", ol, ["station_code"], update_existing=True)
        out(f"weather_outlook: {len(ol)} stations updated")
    if files_root is not None:
        for kind, rows in got.items():
            write_rows(files_root, kind, rows)
    return 0


def run_archive(store, root, today, out=print):
    """Finished Malaysia days (yesterday and the day before, plus any day with no file) to files."""
    for kind, (table, cols, tcol, key) in KINDS.items():
        first = store.select(table, [("select", tcol), ("order", f"{tcol}.asc"), ("limit", 1)])
        if not first:
            continue
        d = _day(first[0][tcol])
        while d <= today - timedelta(days=1):
            if d >= today - timedelta(days=2) or not path_for(root, kind, d).exists():
                start, end = day_bounds(d)
                rows = store.select_all(table, ",".join(cols), [(tcol, f"gte.{start}"), (tcol, f"lt.{end}")],
                                        order=f"{tcol}.asc,station_code.asc")
                if rows:
                    write_rows(root, kind, rows)
                    out(f"{kind} {d}: {len(rows)} rows")
            d += timedelta(days=1)
    return 0


def run_cleanup(store, root, today, out=print):
    keep_from = today - timedelta(days=KEEP_DAYS)
    for kind, (table, _, tcol, _) in KINDS.items():
        first = store.select(table, [("select", tcol), ("order", f"{tcol}.asc"), ("limit", 1)])
        if not first:
            continue
        d = _day(first[0][tcol])
        while d < keep_from:
            if path_for(root, kind, d).exists():
                start, end = day_bounds(d)
                store.delete(table, [(tcol, f"gte.{start}"), (tcol, f"lt.{end}")])
            else:
                out(f"::warning::{kind} {d} has no archive file; kept in Supabase")
            d += timedelta(days=1)
    return 0


def main():
    p = argparse.ArgumentParser()
    p.add_argument("step", choices=["collect", "backfill", "archive", "cleanup"])
    p.add_argument("--stations", help="stations JSON file with lat/lon (default: jps_stations in Supabase)")
    p.add_argument("--data", default=str(FORECAST_DIR), help="forecast archive folder (default: data/forecast)")
    p.add_argument("--dry-run", action="store_true", help="collect: store nothing in Supabase")
    p.add_argument("--to-files", action="store_true", help="collect: also write the archive files")
    p.add_argument("--start", help="backfill: first day (UTC), e.g. 2026-11-16")
    p.add_argument("--end", help="backfill: day after the last (UTC); default today")
    p.add_argument("--no-incidents", action="store_true",
                   help="collect: skip the forecast for current JKR incident locations")
    a = p.parse_args()
    now = datetime.now(timezone.utc)
    store = None
    needs_store = (a.step in ("archive", "cleanup") or not a.stations
                   or (a.step == "collect" and not a.dry_run))
    if needs_store:
        from .store import Store
        store = Store()
    if a.step == "collect":
        stations = load_stations(a.stations, store)
        if not a.no_incidents:
            points = incident_points(store, now)
            stations = stations + points
            print(f"Forecast also for {len(points)} JKR incident location(s)")
        code = collect(stations, now, None if a.dry_run else store, a.data if a.to_files else None)
    elif a.step == "backfill":
        if not a.start:
            p.error("backfill needs --start")
        stations = load_stations(a.stations, store)
        start = datetime.fromisoformat(a.start).replace(tzinfo=timezone.utc)
        end = (datetime.fromisoformat(a.end).replace(tzinfo=timezone.utc) if a.end
               else now.replace(minute=0, second=0, microsecond=0))
        rows = om.fetch_backfill(stations, start, end)
        n = write_rows(a.data, "openmeteo", rows)
        print(f"Backfilled {len(rows)} Open-Meteo rows ({len({r['station_code'] for r in rows})} stations) "
              f"into {n} file(s) under {a.data}/openmeteo")
        code = 0
    elif a.step == "archive":
        code = run_archive(store, a.data, today_myt())
    else:
        code = run_cleanup(store, a.data, today_myt())
    sys.exit(code)


if __name__ == "__main__":
    main()
