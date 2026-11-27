"""MET Malaysia (Jabatan Meteorologi Malaysia) forecasts and warnings, from the
official open-data API at api.data.gov.my (no key needed).

  GET https://api.data.gov.my/weather/forecast   7-day forecast per state / district / town
  GET https://api.data.gov.my/weather/warning    current MET warnings

The forecast is text in Malay for the morning, afternoon and night of each day
(e.g. "Ribut petir di beberapa tempat"). It has no mm and no %, so it is turned
into two numbers per day:

  rain_class   how much of the area is expected to get rain (RAIN_EXTENT):
               0 none / cloudy, 1 "di beberapa tempat" (in some places),
               2 no extent given ("Hujan", "Ribut petir"), 3 "di kebanyakan tempat"
               (in most places), 4 "menyeluruh" (widespread). The highest of
               the day's morning, afternoon and night forecasts.
  thunder      1 if a thunderstorm (ribut petir) is forecast that day

Class 2 is an assumption: MET does not publish an order for its phrases.
docs/rain-forecast-evidence.md checks the classes against JPS gauge rain.
A phrase not in the table gives None (and is reported) instead of a guess.

Warnings used (others, e.g. strong winds at sea, are skipped):
  "Amaran Hujan Berterusan (WASPADA / BURUK / BAHAYA)"  continuous rain, level 1 / 2 / 3
  "Amaran Ribut Petir"                                   thunderstorm, level 1 (lasts a few hours)
  "Amaran Hujan Lebat"                                   heavy rain, level from the heading, else 1
The area is read from the text: "... di negeri Kedah (Baling, Sik dan Kulim) •
Selangor (Petaling dan Sepang) • W.P. Kuala Lumpur sehingga ...". A state with
no districts in brackets means the whole state. Times are Malaysia time, stored in UTC.
"""
import re
import unicodedata
from datetime import datetime, timedelta, timezone

import requests

BASE = "https://api.data.gov.my/weather"
MYT = timezone(timedelta(hours=8))
HEADERS = {"User-Agent": "fyp-flood-logger (student project; reads public forecasts every 6 h)"}
TIMEOUT_S = 60
DAYS_AHEAD = 4  # today + 3 days (Malaysia dates)
FMT = "%Y-%m-%dT%H:%M:%SZ"

FORECAST_COLUMNS = ["station_code", "issued_at", "valid_date", "location_id", "morning", "afternoon",
                    "night", "summary", "rain_class", "thunder"]
WARNING_COLUMNS = ["station_code", "issued_at", "valid_from", "valid_to", "kind", "level", "title"]

# Phrase start -> class; the extent words decide, so "Hujan" and "Ribut petir" share a scale.
NO_RAIN = ("tiada hujan", "mendung", "cerah")
RAIN_WORDS = ("hujan", "ribut petir")
RAIN_EXTENT = (("menyeluruh", 4), ("di kebanyakan tempat", 3), ("di beberapa tempat", 1))
LEVELS = {"WASPADA": 1, "BURUK": 2, "BAHAYA": 3}
WARNING_KINDS = (("HUJAN BERTERUSAN", "continuous_rain"), ("HUJAN LEBAT", "heavy_rain"),
                 ("RIBUT PETIR", "thunderstorm"))
# MET's state names for the states the logger covers, as they appear in warnings.
STATE_NAMES = {"SELANGOR": ("SELANGOR",), "MELAKA": ("MELAKA",)}
WP = {"KUALA LUMPUR": "W.P. KUALA LUMPUR", "PUTRAJAYA": "W.P. PUTRAJAYA"}


def get_json(path, session=None):
    s = session or requests
    r = s.get(f"{BASE}/{path}", headers=HEADERS, timeout=TIMEOUT_S, allow_redirects=True)
    r.raise_for_status()
    return r.json()


def norm(text):
    """Upper case, no accents, single spaces, "&" as "DAN"; for matching place names."""
    t = unicodedata.normalize("NFKD", str(text or "")).encode("ascii", "ignore").decode()
    t = t.upper().replace("&", " DAN ")
    return " ".join(re.sub(r"[^A-Z0-9. ]", " ", t).split())


def rain_class(text):
    """0-4 (see module docstring), or None for an unknown phrase."""
    t = " ".join(str(text or "").lower().split())
    if not t:
        return None
    if t.startswith(NO_RAIN):
        return 0
    if not t.startswith(RAIN_WORDS):
        return None
    for words, cls in RAIN_EXTENT:
        if words in t:
            return cls
    return 2 if t in RAIN_WORDS else None


def is_thunder(text):
    return "ribut petir" in str(text or "").lower()


def _location_index(forecast):
    """{(type, normalised name): location_id} for districts (Ds) and states (St)."""
    out = {}
    for r in forecast:
        loc = r.get("location") or {}
        lid, name = loc.get("location_id") or "", loc.get("location_name") or ""
        if lid[:2] in ("Ds", "St"):
            out[(lid[:2], norm(name))] = lid
    return out


def location_for(station, index):
    """The MET location id for a station: its district, else its state (None if neither)."""
    district, state = norm(station.get("district")), norm(station.get("state"))
    if district in WP:  # Kuala Lumpur / Putrajaya are districts in JPS Selangor, states at MET
        return index.get(("St", norm("WP " + district))) or index.get(("Ds", district))
    return index.get(("Ds", district)) or index.get(("St", state))


def forecast_rows(forecast, stations, issued_at, unknown=None):
    """Rows (FORECAST_COLUMNS) for each station's MET location, today and DAYS_AHEAD-1 days on.
    unknown: optional set that collects phrases not in the table."""
    index = _location_index(forecast)
    by_loc = {}
    for r in forecast:
        by_loc.setdefault((r.get("location") or {}).get("location_id"), []).append(r)
    first = issued_at.astimezone(MYT).date()
    last = first + timedelta(days=DAYS_AHEAD - 1)
    issued = issued_at.strftime(FMT)
    out = []
    for st in stations:
        lid = location_for(st, index)
        for r in by_loc.get(lid, []):
            d = datetime.strptime(r["date"], "%Y-%m-%d").date()
            if not first <= d <= last:
                continue
            parts = [r.get("morning_forecast"), r.get("afternoon_forecast"), r.get("night_forecast")]
            classes = [rain_class(p) for p in parts + [r.get("summary_forecast")] if p]
            if unknown is not None:
                unknown.update(p for p in parts + [r.get("summary_forecast")] if p and rain_class(p) is None)
            known = [c for c in classes if c is not None]
            out.append({
                "station_code": st["id"], "issued_at": issued, "valid_date": r["date"], "location_id": lid,
                "morning": parts[0], "afternoon": parts[1], "night": parts[2],
                "summary": r.get("summary_forecast"),
                "rain_class": max(known) if known else None,
                "thunder": int(any(is_thunder(p) for p in parts + [r.get("summary_forecast")])),
            })
    return out


def _myt_to_utc(text):
    if not text:
        return None
    t = datetime.fromisoformat(text)
    if t.tzinfo is None:
        t = t.replace(tzinfo=MYT)
    return t.astimezone(timezone.utc).strftime(FMT)


def warning_kind(w):
    """(kind, level) for a rain warning, or None for any other warning."""
    title = norm((w.get("warning_issue") or {}).get("title_bm"))
    heading = norm(w.get("heading_bm"))
    for words, kind in WARNING_KINDS:
        if words in title or words in heading:
            level = next((v for k, v in LEVELS.items() if k in heading or k in title), 1)
            return kind, level
    return None


def warning_areas(text_bm):
    """{normalised state: set of normalised districts (empty = whole state)} from a warning text."""
    text = str(text_bm or "")
    m = re.search(r"\bdi (?:negeri|kawasan)\s+(.*?)(?:\s+sehingga\b|$)", text, flags=re.S | re.I)
    body = m.group(1) if m else text
    out = {}
    for part in re.split(r"\s*[•�]\s*", body):
        part = part.strip(" .;")
        if not part:
            continue
        m = re.match(r"^(.*?)\s*\((.*)\)\s*$", part, flags=re.S)
        state, districts = (m.group(1), m.group(2)) if m else (part, "")
        state = norm(state.split(":")[0])
        names = {norm(d) for d in re.split(r",|\bdan\b", districts) if norm(d)}
        out.setdefault(state, set()).update(names)
    return out


def _covers(areas, station):
    state, district = norm(station.get("state")), norm(station.get("district"))
    if district in WP:
        return WP[district] in areas or ("W.P. " + district) in areas
    for name in STATE_NAMES.get(state, (state,)):
        if name in areas:
            ds = areas[name]
            return not ds or district in ds
    return False


def warning_rows(warnings, stations):
    """Rows (WARNING_COLUMNS): one per rain warning and station it covers."""
    out = []
    for w in warnings:
        kl = warning_kind(w)
        if kl is None:
            continue
        areas = warning_areas(w.get("text_bm"))
        issue = w.get("warning_issue") or {}
        for st in stations:
            if _covers(areas, st):
                out.append({"station_code": st["id"], "issued_at": _myt_to_utc(issue.get("issued")),
                            "valid_from": _myt_to_utc(w.get("valid_from")),
                            "valid_to": _myt_to_utc(w.get("valid_to")),
                            "kind": kl[0], "level": kl[1], "title": issue.get("title_bm")})
    return out
