"""Reading the public JPS Selangor API (the same feed as infobanjirjps.selangor.gov.my).
Melaka is read from its web pages in melaka.py, and both states can also be read
from the national pages in publicinfobanjir.py; all are stored the same way.

Every response only holds each station's LATEST value, so anything not logged
when it is shown is lost. Times are Malaysia time (UTC+8) and are stored in UTC.
"""
from datetime import datetime, timedelta, timezone

import requests

BASE = "https://infobanjirjps.selangor.gov.my/JPSAPI/api"
DISTRICT_IDS = range(1, 10)  # Selangor's 9 districts
MYT = timezone(timedelta(hours=8))
FAULT_BELOW = -8888  # JPS codes: -9999 offline, -8888 estimated
HEADERS = {"User-Agent": "fyp-flood-logger (student project; reads public data every 15 min)"}
TIMEOUT_S = 30
MAX_CLOCK_AHEAD = timedelta(minutes=10)
# Readings older than this are not stored. Stuck stations keep showing a reading
# from months ago; and the daily archive can then safely close a day once it is
# more than a day old (see archive.py).
MAX_READING_AGE = timedelta(hours=24)


def get_json(path, session=None):
    s = session or requests
    r = s.get(f"{BASE}/{path}", headers=HEADERS, timeout=TIMEOUT_S)
    r.raise_for_status()
    return r.json()


def parse_time(text):
    """'17/11/2026 14:45:00' or '17/11/2026 14:45' (Malaysia time) -> '2026-11-17T06:45:00Z'.
    None if unreadable."""
    if not isinstance(text, str):
        return None
    text = " ".join(text.split())
    for fmt in ("%d/%m/%Y %H:%M:%S", "%d/%m/%Y %H:%M"):
        try:
            t = datetime.strptime(text, fmt).replace(tzinfo=MYT)
        except ValueError:
            continue
        return t.astimezone(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    return None


def _number(v):
    if isinstance(v, bool) or v is None:
        return None
    try:
        v = float(v)
    except (TypeError, ValueError):
        return None
    return v if v == v and abs(v) != float("inf") else None


def _recent(iso, now):
    """Not in the future and not older than MAX_READING_AGE."""
    t = datetime.strptime(iso, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=timezone.utc)
    return now - MAX_READING_AGE <= t <= now + MAX_CLOCK_AHEAD


def river_level_rows(payload, now):
    """Rows for jps_river_levels. Offline (-9999), empty, future-dated and stale
    (over 24 h old) readings are skipped."""
    rows = []
    for s in payload.get("stations") or []:
        code, at, level = s.get("stationCode"), parse_time(s.get("lastUpdate")), _number(s.get("waterLevel"))
        if not code or at is None or level is None or level <= FAULT_BELOW or not _recent(at, now):
            continue
        rows.append({"station_code": code.strip(), "observed_at": at, "level_m": level})
    return rows


def rainfall_rows(payload, now):
    """Rows for jps_rainfall. hourlyRainfall is a rolling 60-minute total and
    todayRainfall is the total since midnight; both are stored as given."""
    rows = []
    for s in payload.get("stations") or []:
        code, at = s.get("stationCode"), parse_time(s.get("lastUpdate"))
        hourly, today = _number(s.get("hourlyRainfall")), _number(s.get("todayRainfall"))
        hourly = hourly if hourly is not None and hourly >= 0 else None
        today = today if today is not None and today >= 0 else None
        if not code or at is None or (hourly is None and today is None) or not _recent(at, now):
            continue
        rows.append({"station_code": code.strip(), "observed_at": at, "hourly_mm": hourly, "today_mm": today})
    return rows


def station_rows(wl_payloads, rf_payloads, wl_list, rf_list, now):
    """One row per station code for jps_stations. Positions and river basin come
    from the map lists, which use the same numeric id as the district data."""
    place = {}
    for item in list(wl_list or []) + list(rf_list or []):
        sid = item.get("stationId")
        lat, lon = _number(item.get("latitude")), _number(item.get("longitude"))
        basin = item.get("mainRiverBasin")
        basin = basin.strip() if isinstance(basin, str) and basin.strip() not in ("", "N/A") else None
        old = place.get(sid, {})
        place[sid] = {
            "lat": old.get("lat") if old.get("lat") is not None else (lat if lat is not None and -90 <= lat <= 90 else None),
            "lon": old.get("lon") if old.get("lon") is not None else (lon if lon is not None and -180 <= lon <= 180 else None),
            "river_basin": old.get("river_basin") or basin,
        }
    stations = {}

    def base(s):
        code = s["stationCode"].strip()
        row = stations.setdefault(code, {
            "station_code": code, "name": (s.get("stationName") or code).strip(),
            "district": s.get("districtName"), "river_basin": None, "lat": None, "lon": None,
            "has_river_level": False, "has_rainfall": False, "wl_normal": None, "wl_alert": None,
            "wl_warning": None, "wl_danger": None, "updated_at": now.strftime("%Y-%m-%dT%H:%M:%SZ"),
            "state": "Selangor", "jps_wl_id": None, "jps_rf_id": None,
        })
        p = place.get(s.get("id"), {})
        for k in ("lat", "lon", "river_basin"):
            if row[k] is None and p.get(k) is not None:
                row[k] = p[k]
        return row

    for payload in wl_payloads:
        for s in payload.get("stations") or []:
            if not s.get("stationCode"):
                continue
            row = base(s)
            row["has_river_level"] = True
            row["jps_wl_id"] = _national_id(s)
            for src, dst in (("wlth_normal", "wl_normal"), ("wlth_alert", "wl_alert"),
                             ("wlth_warning", "wl_warning"), ("wlth_danger", "wl_danger")):
                row[dst] = _number(s.get(src))
    for payload in rf_payloads:
        for s in payload.get("stations") or []:
            if s.get("stationCode"):
                row = base(s)
                row["has_rainfall"] = True
                row["jps_rf_id"] = _national_id(s)
    return list(stations.values())


def _national_id(s):
    """The station id that publicinfobanjir.water.gov.my uses (e.g. "3015432"),
    which the Selangor feed gives as stationId. None when missing."""
    v = s.get("stationId")
    v = str(v).strip() if v is not None else ""
    return v or None


def id_map(payloads):
    """{national station id: Selangor station code} from district payloads."""
    out = {}
    for payload in payloads:
        for s in payload.get("stations") or []:
            nid, code = _national_id(s), (s.get("stationCode") or "").strip()
            if nid and code:
                out[nid] = code
    return out
