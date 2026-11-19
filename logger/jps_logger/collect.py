"""One logging run: read Selangor and Melaka river levels and rainfall, and store what is new.

    python -m jps_logger.collect            (needs SUPABASE_URL and SUPABASE_SECRET_KEY)
    python -m jps_logger.collect --dry-run  (reads JPS, stores nothing)

Each state has two interchangeable sources (SOURCES). For each state and each
kind (river levels, rainfall) the first source is read; if it fails, finds
nothing, or (Selangor) a district fails, the second source is read too and
fills in what is missing. Swap the order in SOURCES to change which comes first.

  - "selangor-api"     the Selangor JSON feed (jps.py): all stations, with positions
  - "melaka-site"      the Melaka web pages (melaka.py): with positions
  - "publicinfobanjir" the national pages (publicinfobanjir.py): both states,
                       no positions; Selangor stations are matched by their
                       national id (jps_stations.jps_wl_id / jps_rf_id)

Anything that fails is reported as a warning and skipped; the run fails
(exit 1) only if nothing at all could be read.
"""
import argparse
import sys
from dataclasses import dataclass, field
from datetime import datetime, timezone

import requests

from . import jps, melaka, publicinfobanjir as pib

SOURCES = {
    "Selangor": ("selangor-api", "publicinfobanjir"),
    "Melaka": ("publicinfobanjir", "melaka-site"),
}
KINDS = {"river": "river level", "rain": "rainfall"}
ID_COLUMNS = {"river": "jps_wl_id", "rain": "jps_rf_id"}
_NO_POSITION = ("lat", "lon", "jps_wl_id", "jps_rf_id")


@dataclass
class Part:
    """What one source gave for one state and kind."""
    readings: list = field(default_factory=list)  # rows for jps_river_levels / jps_rainfall
    stations: list = field(default_factory=list)  # jps_stations rows, all columns
    plain: list = field(default_factory=list)     # jps_stations rows without position columns
    read: bool = False                            # some data arrived
    complete: bool = False                        # nothing failed and there are readings
    note: str = ""


class _Run:
    def __init__(self, fetch, fetch_page, store, now, problems):
        self.fetch, self.fetch_page, self.store, self.now, self.problems = fetch, fetch_page, store, now, problems
        self._lists = None
        self._ids = {"river": {}, "rain": {}}  # national id -> Selangor code, from this run's feed
        self._stored_ids = None

    # ---------- Selangor JSON feed ----------
    def _station_lists(self):
        if self._lists is None:
            self._lists = {}
            for name, path in (("wl", "StationRiverLevels"), ("rf", "StationRainfalls")):
                try:
                    self._lists[name] = self.fetch(path)
                except Exception as e:  # noqa: BLE001
                    self._lists[name] = []
                    self.problems.append(f"station positions ({name}): {type(e).__name__}")
        return self._lists

    def selangor_api(self, state, kind):
        prefix = ("StationRiverLevels/GetWLAllStationData" if kind == "river"
                  else "StationRainfalls/GetRFAllStationData")
        payloads, failed = [], 0
        for d in jps.DISTRICT_IDS:
            try:
                payloads.append(self.fetch(f"{prefix}/{d}"))
            except Exception as e:  # noqa: BLE001 - report and carry on with other districts
                failed += 1
                self.problems.append(f"district {d} {KINDS[kind]}: {type(e).__name__}")
        if not payloads:
            return Part()
        to_rows = jps.river_level_rows if kind == "river" else jps.rainfall_rows
        readings = [r for p in payloads for r in to_rows(p, self.now)]
        lists = self._station_lists()
        wl, rf = (payloads, []) if kind == "river" else ([], payloads)
        self._ids[kind].update(jps.id_map(payloads))
        return Part(readings=readings, stations=jps.station_rows(wl, rf, lists["wl"], lists["rf"], self.now),
                    read=True, complete=failed == 0 and bool(readings))

    # ---------- web pages ----------
    def _page(self, state, kind, source, url, parse):
        """Parsed rows of one page, or None (with a problem noted) when it fails."""
        if self.fetch_page is None:
            return None
        try:
            found = parse(self.fetch_page(url))
        except Exception as e:  # noqa: BLE001 - report and carry on
            self.problems.append(f"{state} {KINDS[kind]} page ({source}): {type(e).__name__}")
            return None
        if not found:
            self.problems.append(f"{state} {KINDS[kind]} page ({source}): no stations found "
                                 f"(page layout may have changed)")
        return found

    @staticmethod
    def _readings(kind, rows, now):
        return (melaka.river_level_rows if kind == "river" else melaka.rainfall_rows)(rows, now)

    def melaka_site(self, state, kind):
        url, parse = ((melaka.RIVER_URL, melaka.river_stations) if kind == "river"
                      else (melaka.RAIN_URL, melaka.rain_stations))
        found = self._page(state, kind, "melaka-site", url, parse)
        if found is None:
            return Part()
        river, rain = (found, []) if kind == "river" else ([], found)
        readings = self._readings(kind, found, self.now)
        return Part(readings=readings, stations=melaka.station_rows(river, rain, self.now),
                    read=bool(found), complete=bool(readings))

    def publicinfobanjir(self, state, kind):
        url, parse = ((pib.river_url(state), pib.river_stations) if kind == "river"
                      else (pib.rain_url(state), pib.rain_stations))
        found = self._page(state, kind, "publicinfobanjir", url, parse)
        if found is None:
            return Part()
        note = ""
        if state == "Selangor":
            # The national id -> the Selangor code the database uses. Station
            # details are not written: the Selangor feed's names and positions stay.
            ids = self._selangor_ids(kind)
            mapped = [dict(s, code=ids[s["code"]]) for s in found if s["code"] in ids]
            if len(mapped) < len(found):
                note = f"{len(found) - len(mapped)} unmatched stations skipped"
            readings = self._readings(kind, mapped, self.now)
            return Part(readings=readings, read=bool(found), complete=bool(readings), note=note)
        river, rain = (found, []) if kind == "river" else ([], found)
        plain = [{k: v for k, v in r.items() if k not in _NO_POSITION}
                 for r in melaka.station_rows(river, rain, self.now, state=state)]
        readings = self._readings(kind, found, self.now)
        return Part(readings=readings, plain=plain, read=bool(found), complete=bool(readings))

    def _selangor_ids(self, kind):
        """National id -> Selangor code: this run's feed first, then what is stored."""
        if self._stored_ids is None:
            self._stored_ids = {"river": {}, "rain": {}}
            select = getattr(self.store, "select", None)
            if select is not None:
                try:
                    rows = select("jps_stations", [("select", "station_code,jps_wl_id,jps_rf_id"),
                                                   ("state", "eq.Selangor")])
                    for r in rows:
                        for k, col in ID_COLUMNS.items():
                            if r.get(col):
                                self._stored_ids[k][str(r[col]).strip()] = r["station_code"]
                except Exception as e:  # noqa: BLE001
                    self.problems.append(f"stored Selangor station ids: {type(e).__name__}")
        return {**self._stored_ids[kind], **self._ids[kind]}

    def read(self, state, kind, source):
        return getattr(self, source.replace("-", "_"))(state, kind)


def _unique_readings(rows):
    """One row per station and time; the first source wins."""
    out = {}
    for r in rows:
        out.setdefault((r["station_code"], r["observed_at"]), r)
    return list(out.values())


def _merge_stations(rows):
    """One row per station code: flags are combined and empty values filled in,
    so rain and river rows of one station do not undo each other."""
    out = {}
    for r in rows:
        old = out.get(r["station_code"])
        if old is None:
            out[r["station_code"]] = dict(r)
            continue
        for k, v in r.items():
            if k.startswith("has_"):
                old[k] = bool(old.get(k)) or bool(v)
            elif old.get(k) is None and v is not None:
                old[k] = v
    return list(out.values())


def _insert_stations(store, rows, out):
    """Upserts station rows. Before supabase/sources.sql adds the national id
    columns, Supabase refuses them: the rows are then sent without them."""
    if not rows:
        return
    try:
        store.insert("jps_stations", rows, ["station_code"], update_existing=True)
    except RuntimeError as e:
        if not any(c in str(e) for c in ID_COLUMNS.values()):
            raise
        out("::warning::jps_stations has no national id columns yet; run supabase/sources.sql")
        store.insert("jps_stations", [{k: v for k, v in r.items() if k not in ID_COLUMNS.values()} for r in rows],
                     ["station_code"], update_existing=True)


def run(fetch, store, now, out=print, fetch_page=None, sources=None):
    sources = sources or SOURCES
    problems, used = [], []
    r = _Run(fetch, fetch_page, store, now, problems)
    levels, rain, stations, plain, anything = [], [], [], [], False
    for state, order in sources.items():
        for kind in KINDS:
            parts = []
            for source in order:
                part = r.read(state, kind, source)
                parts.append((source, part))
                if part.complete:
                    break
            anything = anything or any(p.read for _, p in parts)
            rows = _unique_readings([row for _, p in parts for row in p.readings])
            (levels if kind == "river" else rain).extend(rows)
            for _, p in parts:
                stations += p.stations
                plain += p.plain
            used.append(f"{state} {KINDS[kind]}: " + " + ".join(
                f"{s} ({len(p.readings)}{', ' + p.note if p.note else ''})" for s, p in parts if p.read or p.readings)
                        if any(p.read for _, p in parts) else f"{state} {KINDS[kind]}: nothing read")

    stations = _merge_stations(stations)
    have = {s["station_code"] for s in stations}
    plain = [s for s in _merge_stations(plain) if s["station_code"] not in have]
    levels, rain = _unique_readings(levels), _unique_readings(rain)

    for p in problems:
        out(f"::warning::Could not read {p}")
    for u in used:
        out(u)
    if not anything:
        out("::error::No JPS data could be read in this run")
        return 1
    if store is not None:
        _insert_stations(store, stations, out)
        if plain:
            store.insert("jps_stations", plain, ["station_code"], update_existing=True)
        store.insert("jps_river_levels", levels, ["station_code", "observed_at"])
        store.insert("jps_rainfall", rain, ["station_code", "observed_at"])
    n_melaka = sum(1 for s in stations + plain if s.get("state") == "Melaka")
    out(f"Read {len(stations) + len(plain)} stations ({n_melaka} in Melaka): {len(levels)} river levels, "
        f"{len(rain)} rainfall readings ({len(problems)} problems)"
        f"{' - dry run, nothing stored' if store is None else ''}")
    return 0


def get_page(url, session=None):
    """One web page as text."""
    s = session or requests
    r = s.get(url, headers=jps.HEADERS, timeout=jps.TIMEOUT_S)
    r.raise_for_status()
    return r.text


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--dry-run", action="store_true")
    a = p.parse_args()
    session = requests.Session()
    store = None
    if not a.dry_run:
        from .store import Store
        store = Store()
    code = run(lambda path: jps.get_json(path, session), store, datetime.now(timezone.utc),
               fetch_page=lambda url: get_page(url, session))
    sys.exit(code)


if __name__ == "__main__":
    main()
