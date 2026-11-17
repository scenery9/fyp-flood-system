"""One logging run: read all 9 Selangor districts and store what is new.

    python -m jps_logger.collect            (needs SUPABASE_URL and SUPABASE_SECRET_KEY)
    python -m jps_logger.collect --dry-run  (reads JPS, stores nothing)

A district that fails is reported and skipped; the run fails (exit 1) only if
nothing at all could be read, so one slow district does not lose the rest.
"""
import argparse
import sys
from datetime import datetime, timezone

import requests

from . import jps


def run(fetch, store, now, out=print):
    wl_payloads, rf_payloads, problems = [], [], []
    for d in jps.DISTRICT_IDS:
        for kind, path, bucket in (("river level", f"StationRiverLevels/GetWLAllStationData/{d}", wl_payloads),
                                   ("rainfall", f"StationRainfalls/GetRFAllStationData/{d}", rf_payloads)):
            try:
                bucket.append(fetch(path))
            except Exception as e:  # noqa: BLE001 - report and carry on with other districts
                problems.append(f"district {d} {kind}: {type(e).__name__}")
    lists = {}
    for name, path in (("wl", "StationRiverLevels"), ("rf", "StationRainfalls")):
        try:
            lists[name] = fetch(path)
        except Exception as e:  # noqa: BLE001
            lists[name] = []
            problems.append(f"station positions ({name}): {type(e).__name__}")

    # one row per station and time, even if JPS lists a station in two districts
    levels = list({(r["station_code"], r["observed_at"]): r
                   for p in wl_payloads for r in jps.river_level_rows(p, now)}.values())
    rain = list({(r["station_code"], r["observed_at"]): r
                 for p in rf_payloads for r in jps.rainfall_rows(p, now)}.values())
    stations = jps.station_rows(wl_payloads, rf_payloads, lists["wl"], lists["rf"], now)
    for p in problems:
        out(f"::warning::Could not read {p}")
    if not wl_payloads and not rf_payloads:
        out("::error::No JPS data could be read in this run")
        return 1
    if store is not None:
        store.insert("jps_stations", stations, ["station_code"], update_existing=True)
        store.insert("jps_river_levels", levels, ["station_code", "observed_at"])
        store.insert("jps_rainfall", rain, ["station_code", "observed_at"])
    out(f"Read {len(stations)} stations: {len(levels)} river levels, {len(rain)} rainfall readings "
        f"({len(problems)} problems){' - dry run, nothing stored' if store is None else ''}")
    return 0


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--dry-run", action="store_true")
    a = p.parse_args()
    session = requests.Session()
    store = None
    if not a.dry_run:
        from .store import Store
        store = Store()
    code = run(lambda path: jps.get_json(path, session), store, datetime.now(timezone.utc))
    sys.exit(code)


if __name__ == "__main__":
    main()
