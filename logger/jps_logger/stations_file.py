"""Writes a stations file for ml/ with every Selangor and Melaka river station that
can be used for training: its JPS thresholds, and (optionally) only stations whose
logged readings look sound.

    python -m jps_logger.stations_file --base ../ml/stations_klang.json --out ../ml/stations_training.json
    python -m jps_logger.stations_file --base ../ml/stations_klang.json --data ../data \
        --out ../ml/stations_training.json

Thresholds come from the public JPS sites the logger reads (no key needed): the
Selangor feed, then the Melaka site and publicinfobanjir for Melaka, with the same
station codes the logger stores readings under. A station is
left out when a threshold is missing, is 0 (JPS gives 0 for a level it has not
set, e.g. normal 9.26, alert 0, warning 12), or the thresholds are not in order.
Entries in --base (e.g. the Klang stations with their upstream links) are kept as
they are, so their upstream inputs still work; other stations get no upstream.

With --data, the archive files are read too, and a station is also left out when:
  * it has fewer than --min-readings level readings (offline most of the time),
  * its level never moves by MIN_RANGE_M (a stuck sensor), or
  * its usual (median) level is at or above Alert (the thresholds do not fit
    the readings, so every hour would count as a flood).
"""
import argparse
import json
from datetime import datetime, timezone
from pathlib import Path

import pandas as pd

from . import jps
from .archive import read_archive

THRESHOLDS = (("normal", "wl_normal"), ("alert", "wl_alert"), ("warning", "wl_warning"), ("danger", "wl_danger"))
MIN_RANGE_M = 0.05


def thresholds_ok(row):
    """All four thresholds given, alert/warning/danger not 0, and normal < alert <= warning <= danger."""
    normal, alert, warning, danger = (row.get(src) for _, src in THRESHOLDS)
    if None in (normal, alert, warning, danger) or 0 in (alert, warning, danger):
        return False
    return normal < alert <= warning <= danger


def readings_ok(stats, alert, min_readings):
    """stats: {"n", "min", "max", "median"} of a station's logged levels."""
    if stats is None or stats["n"] < min_readings:
        return False
    return stats["max"] - stats["min"] >= MIN_RANGE_M and stats["median"] < alert


def to_entry(row):
    entry = {"id": row["station_code"], "name": row["name"], "state": row.get("state") or "Selangor"}
    if row.get("river_basin"):
        entry["river"] = row["river_basin"]
    if row.get("district"):
        entry["district"] = row["district"]
    for dst, src in THRESHOLDS:
        entry[dst] = row[src]
    return entry


def build(station_rows, base=(), reading_stats=None, min_readings=0):
    """Stations file entries: base entries unchanged, then the other usable river
    stations by code. station_rows: jps_stations rows (jps.station_rows).
    reading_stats: {station_code: stats} from level_stats, or None to skip that check."""
    base = list(base)
    taken = {s["id"] for s in base}
    out = []
    for row in sorted(station_rows, key=lambda r: r["station_code"]):
        code = row["station_code"]
        if code in taken or not row.get("has_river_level") or not thresholds_ok(row):
            continue
        if reading_stats is not None and not readings_ok(reading_stats.get(code), row["wl_alert"], min_readings):
            continue
        taken.add(code)
        out.append(to_entry(row))
    return base + out


def fetch_station_rows(fetch, now):
    """jps_stations rows of the Selangor river stations, with the river basin from the station list."""
    payloads = [fetch(f"StationRiverLevels/GetWLAllStationData/{d}") for d in jps.DISTRICT_IDS]
    return jps.station_rows(payloads, [], fetch("StationRiverLevels"), [], now)


def fetch_melaka_rows(fetch_page, now, problems=None):
    """jps_stations rows of the Melaka river stations, read the same way as the logger:
    the Melaka site first, then the stations only publicinfobanjir lists. Stations that
    publicinfobanjir lists under another code keep the Melaka site's code."""
    from .collect import _Run  # the logger's own readers, so codes match the stored readings
    problems = [] if problems is None else problems
    run = _Run(None, fetch_page, None, now, problems)
    site = run.read("Melaka", "river", "melaka-site")
    pib = run.read("Melaka", "river", "publicinfobanjir")
    rows = {r["station_code"]: r for r in site.stations}
    for r in pib.plain:
        rows.setdefault(r["station_code"], r)
    return list(rows.values())


def level_stats(levels):
    """{station_code: {"n", "min", "max", "median"}} from level rows."""
    if not levels:
        return {}
    df = pd.DataFrame(levels).drop_duplicates(["station_code", "observed_at"])
    g = df.groupby("station_code")["level_m"].agg(["size", "min", "max", "median"])
    return {code: {"n": int(r["size"]), "min": float(r["min"]), "max": float(r["max"]),
                   "median": float(r["median"])} for code, r in g.iterrows()}


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--out", required=True)
    p.add_argument("--base", help="stations file whose entries are kept as they are (e.g. stations_klang.json)")
    p.add_argument("--data", help="archive folder; also checks each station's logged readings")
    p.add_argument("--since", default="2026-11-20", help="first archive day checked (default 2026-11-20)")
    p.add_argument("--min-readings", type=int, default=300)
    p.add_argument("--selangor-only", action="store_true", help="leave out the Melaka stations")
    a = p.parse_args()
    base = json.loads(Path(a.base).read_text()) if a.base else []
    now = datetime.now(timezone.utc)
    rows = fetch_station_rows(jps.get_json, now)
    if not a.selangor_only:
        from .collect import get_page
        problems = []
        rows += fetch_melaka_rows(get_page, now, problems)
        for p in problems:
            print(f"::warning::Could not read {p}")
    stats = level_stats(read_archive(a.data, pd.Timestamp(a.since).date())[0]) if a.data else None
    stations = build(rows, base, stats, a.min_readings)
    text = "[\n" + ",\n".join("  " + json.dumps(s, ensure_ascii=False) for s in stations) + "\n]\n"
    Path(a.out).write_text(text, encoding="utf-8")
    kept = {s["id"] for s in stations}
    left_out = sum(1 for r in rows if r.get("has_river_level") and r["station_code"] not in kept)
    print(f"Wrote {len(stations)} stations to {a.out} ({len(base)} from --base); {left_out} river "
          f"stations left out ({'thresholds or readings' if stats is not None else 'thresholds'} not usable)")


if __name__ == "__main__":
    main()
