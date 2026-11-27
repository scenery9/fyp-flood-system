"""Disaster incidents from JKR's public portal (bencana.jkr.gov.my, Sistem eBencana JKR):
floods, landslides, road collapses on public roads, with their position and status.

    python -m jps_logger.jkr collect            # read the portal, store in Supabase (jkr_incident ...)
    python -m jps_logger.jkr collect --dry-run --to-files
                                                # no Supabase: print them and write data/incidents/
    python -m jps_logger.jkr archive            # finished days from Supabase to data/incidents/

Why: a JKR flood report is an observed flood at a known place and time, which JPS river
levels alone do not show (e.g. 25 Nov 2026, "Ban Sungai Langat pecah", a river bund breach in
Kuala Langat). Each incident is stored with the nearest JPS river stations and rain gauges
and what they read at that moment, so a flood can later be matched to the readings before it.

The portal lists only CURRENT incidents (GET /portal/disasters?page=N, 5 per page), so
each run stores a snapshot; the history builds up from the runs.

Privacy: the portal's records also hold the reporting officer's name, phone numbers and
user ids. Those are never kept (only KEEP below is read).
"""
import argparse
import math
import sys
from datetime import datetime, timedelta, timezone
from pathlib import Path

import requests

from .archive import DATA_DIR

BASE = "https://bencana.jkr.gov.my/portal/disasters"
HEADERS = {"User-Agent": "fyp-flood-logger (student project; reads public incident list hourly)",
           "Accept": "application/json"}
TIMEOUT_S = 180  # the portal can take close to a minute to answer
MAX_PAGES = 50
MYT = timezone(timedelta(hours=8))
FMT = "%Y-%m-%dT%H:%M:%SZ"
NEAR_KM = 15.0
NEAREST = 3
INCIDENT_DIR = DATA_DIR / "incidents"

INCIDENT_COLUMNS = ["incident_id", "seen_at", "type", "type_ms", "occurred_at", "lat", "lon", "state", "district",
                    "location_name", "route_name", "route_type", "depth_m", "length_m", "status", "situation",
                    "road_status", "road_status_code", "is_verified", "remarks", "updated_at", "url"]
GAUGE_COLUMNS = ["incident_id", "seen_at", "kind", "rank", "station_code", "station_name", "distance_km",
                 "observed_at", "level_m", "alert_m", "warning_m", "danger_m", "hourly_mm", "today_mm"]


def _label(obj, key="label_en"):
    return (obj or {}).get(key)


def _num(v):
    try:
        x = float(v)
        return x if math.isfinite(x) else None
    except (TypeError, ValueError):
        return None


def _utc(text):
    if not text:
        return None
    t = datetime.fromisoformat(str(text).replace("Z", "+00:00"))
    if t.tzinfo is None:
        t = t.replace(tzinfo=MYT)
    return t.astimezone(timezone.utc).strftime(FMT)


def clean(r, seen_at):
    """One incident without any personal details. depth_m is JKR's 'water_level_depth':
    the flood depth for a flood; for slope or road failures JKR uses the same field for
    the size of the failure, so only read it as water depth when type is Flood."""
    occurred = None
    if r.get("date"):
        occurred = _utc(f"{r['date']}T{r.get('time') or '00:00:00'}")
    return {
        "incident_id": r["id"], "seen_at": seen_at,
        "type": _label(r.get("disaster_type")), "type_ms": _label(r.get("disaster_type"), "label_ms"),
        "occurred_at": occurred, "lat": _num(r.get("latitude")), "lon": _num(r.get("longitude")),
        "state": r.get("state_name"), "district": r.get("district_name"),
        "location_name": r.get("location_name"), "route_name": r.get("route_name"), "route_type": r.get("route_type"),
        "depth_m": _num(r.get("water_level_depth")), "length_m": _num(r.get("length_area")),
        "status": _label(r.get("disaster_status")), "situation": _label(r.get("disaster_situation_status")),
        "road_status": _label(r.get("disaster_route_status")),
        "road_status_code": (r.get("disaster_route_status") or {}).get("code"),
        "is_verified": int(bool(r.get("is_verified"))), "remarks": (r.get("remarks") or "").strip() or None,
        "updated_at": _utc(r.get("updated_at")), "url": r.get("disaster_url"),
    }


def fetch(session=None, state_id=""):
    """Every current incident (raw portal records)."""
    s = session or requests
    out, page = [], 1
    while page <= MAX_PAGES:
        r = s.get(BASE, params={"page": page, "state_id": state_id, "disaster": ""}, headers=HEADERS, timeout=TIMEOUT_S)
        r.raise_for_status()
        j = r.json()
        out += j.get("data") or []
        if not j.get("next_page_url") or page >= int(j.get("last_page") or page):
            break
        page += 1
    return out


def distance_km(lat1, lon1, lat2, lon2):
    p1, p2 = math.radians(lat1), math.radians(lat2)
    dp, dl = p2 - p1, math.radians(lon2 - lon1)
    a = math.sin(dp / 2) ** 2 + math.cos(p1) * math.cos(p2) * math.sin(dl / 2) ** 2
    return 6371.0 * 2 * math.asin(math.sqrt(a))


def nearest(incident, gauges, kind, n=NEAREST, max_km=NEAR_KM):
    """The n closest gauges of one kind ("river" / "rain") within max_km, nearest first."""
    if incident["lat"] is None or incident["lon"] is None:
        return []
    found = []
    for g in gauges:
        if g["kind"] != kind or g.get("lat") is None or g.get("lon") is None:
            continue
        d = distance_km(incident["lat"], incident["lon"], g["lat"], g["lon"])
        if d <= max_km:
            found.append((d, g))
    found.sort(key=lambda x: x[0])
    return [(round(d, 2), g) for d, g in found[:n]]


def gauge_rows(incidents, gauges):
    out = []
    for inc in incidents:
        for kind in ("river", "rain"):
            for rank, (d, g) in enumerate(nearest(inc, gauges, kind), start=1):
                out.append({"incident_id": inc["incident_id"], "seen_at": inc["seen_at"], "kind": kind, "rank": rank,
                            "station_code": g["code"], "station_name": g.get("name"), "distance_km": d,
                            "observed_at": g.get("observed_at"), "level_m": g.get("level_m"),
                            "alert_m": g.get("alert"), "warning_m": g.get("warning"), "danger_m": g.get("danger"),
                            "hourly_mm": g.get("hourly_mm"), "today_mm": g.get("today_mm")})
    return out


def live_gauges(now, problems=None):
    """JPS river stations and rain gauges (Selangor and Melaka) with position and latest
    reading, read the same way as the 15-minute logger (collect.py)."""
    from . import jps
    from .collect import SOURCES, _Run, get_page
    problems = [] if problems is None else problems
    run = _Run(jps.get_json, get_page, None, now, problems)
    gauges = {}
    for state, sources in SOURCES.items():
        for kind in ("river", "rain"):
            for source in sources:
                part = run.read(state, kind, source)
                flag = "has_river_level" if kind == "river" else "has_rainfall"
                pos = {s["station_code"]: s for s in part.stations if s.get(flag, True)}
                latest = {}
                for r in part.readings:
                    latest[r["station_code"]] = r
                for code, s in pos.items():
                    if (kind, code) in gauges or s.get("lat") is None:
                        continue
                    r = latest.get(code, {})
                    gauges[(kind, code)] = {
                        "kind": kind, "code": code, "name": s.get("name"), "lat": s["lat"], "lon": s["lon"],
                        "observed_at": r.get("observed_at"), "level_m": r.get("level_m"),
                        "alert": s.get("wl_alert"), "warning": s.get("wl_warning"), "danger": s.get("wl_danger"),
                        "hourly_mm": r.get("hourly_mm"), "today_mm": r.get("today_mm")}
    return list(gauges.values())


def incident_points(incidents):
    """Weather-forecast points for incidents (weather.py): one per incident with a position.
    Ids are "JKR-<incident id>"; district and state let MET Malaysia match the area."""
    out = []
    for i in incidents:
        if i.get("lat") is None or i.get("lon") is None:
            continue
        district = (i.get("district") or "")
        if district.upper().startswith("DAERAH "):
            district = district[7:]
        out.append({"id": f"JKR-{i['incident_id']}", "lat": i["lat"], "lon": i["lon"],
                    "district": district, "state": i.get("state"), "incident_type": i.get("type")})
    return out


def collect(now, store=None, files_root=None, session=None, out=print):
    seen_at = now.strftime(FMT)
    try:
        raw = fetch(session)
    except Exception as e:  # noqa: BLE001
        out(f"::error::JKR portal could not be read: {type(e).__name__}: {e}")
        return 1, []
    incidents = [clean(r, seen_at) for r in raw]
    problems = []
    try:
        gauges = live_gauges(now, problems)
    except Exception as e:  # noqa: BLE001 - incidents are still worth storing
        gauges = []
        out(f"::warning::JPS gauges could not be read: {e}")
    for p in problems:
        out(f"::warning::Could not read {p}")
    near = gauge_rows(incidents, gauges)
    out(f"JKR incidents: {len(incidents)} ({sum(i['type'] == 'Flood' for i in incidents)} floods); "
        f"{len(near)} nearby gauge rows from {len(gauges)} JPS gauges")
    for i in incidents:
        g = [n for n in near if n["incident_id"] == i["incident_id"]]
        out(f"  {i['incident_id']} {i['type']} {i['occurred_at']} {i['district']}, {i['state']} "
            f"({i['lat']}, {i['lon']}): {i['situation']}; {i['road_status']}; nearby: "
            + (", ".join(f"{n['kind']} {n['station_code']} {n['distance_km']} km" for n in g) or "none within 15 km"))
    if store is not None:
        latest = [{k: v for k, v in i.items() if k != "seen_at"} | {"last_seen_at": seen_at} for i in incidents]
        store.insert("jkr_incident", latest, ["incident_id"], update_existing=True)
        store.insert("jkr_incident_seen", [{"incident_id": i["incident_id"], "seen_at": seen_at,
                                            "situation": i["situation"], "road_status": i["road_status"],
                                            "depth_m": i["depth_m"]} for i in incidents],
                     ["incident_id", "seen_at"])
        store.insert("jkr_incident_gauges", near, ["incident_id", "seen_at", "kind", "rank"])
    if files_root is not None:
        from .weather import write_table
        write_table(Path(files_root) / "jkr", incidents, INCIDENT_COLUMNS, "seen_at", ["incident_id", "seen_at"])
        write_table(Path(files_root) / "jkr_gauges", near, GAUGE_COLUMNS, "seen_at",
                    ["incident_id", "seen_at", "kind", "rank"])
    return 0, incidents


SEEN_COLUMNS = ["situation", "road_status", "depth_m"]  # what jkr_incident_seen keeps per hour


def run_archive(store, root, today, out=print):
    """Finished Malaysia days (the last two again, plus any day with no file) to
    data/incidents/jkr/ and jkr_gauges/. Each hourly sighting (jkr_incident_seen) becomes
    one row: the incident's fixed details from jkr_incident with that hour's status."""
    from .archive import day_bounds
    from .weather import _day, write_table
    root = Path(root)
    first = store.select("jkr_incident_seen", [("select", "seen_at"), ("order", "seen_at.asc"), ("limit", 1)])
    if not first:
        return 0
    details = {r["incident_id"]: r for r in store.select_all(
        "jkr_incident", ",".join(c for c in INCIDENT_COLUMNS if c != "seen_at"), [], order="incident_id.asc")}
    d = _day(first[0]["seen_at"])
    while d <= today - timedelta(days=1):
        path = root / "jkr" / f"{d:%Y}" / f"{d:%m}" / f"{d:%Y-%m-%d}.csv.gz"
        if d >= today - timedelta(days=2) or not path.exists():
            start, end = day_bounds(d)
            when = [("seen_at", f"gte.{start}"), ("seen_at", f"lt.{end}")]
            seen = store.select_all("jkr_incident_seen", "incident_id,seen_at," + ",".join(SEEN_COLUMNS), when,
                                    order="seen_at.asc,incident_id.asc")
            rows = [details.get(r["incident_id"], {"incident_id": r["incident_id"]}) | r for r in seen]
            near = store.select_all("jkr_incident_gauges", ",".join(GAUGE_COLUMNS), when,
                                    order="seen_at.asc,incident_id.asc")
            write_table(root / "jkr", rows, INCIDENT_COLUMNS, "seen_at", ["incident_id", "seen_at"])
            write_table(root / "jkr_gauges", near, GAUGE_COLUMNS, "seen_at", ["incident_id", "seen_at", "kind", "rank"])
            if rows:
                out(f"jkr {d}: {len(rows)} sightings, {len(near)} nearby gauge rows")
        d += timedelta(days=1)
    return 0


def main():
    p = argparse.ArgumentParser()
    p.add_argument("step", choices=["collect", "archive"])
    p.add_argument("--dry-run", action="store_true", help="store nothing in Supabase")
    p.add_argument("--to-files", action="store_true", help="also write data/incidents/ files")
    p.add_argument("--data", default=str(INCIDENT_DIR))
    a = p.parse_args()
    store = None
    if a.step == "archive" or not a.dry_run:
        from .store import Store
        store = Store()
    if a.step == "archive":
        from .archive import today_myt
        sys.exit(run_archive(store, a.data, today_myt()))
    code, _ = collect(datetime.now(timezone.utc).replace(microsecond=0), store, a.data if a.to_files else None)
    sys.exit(code)


if __name__ == "__main__":
    main()
