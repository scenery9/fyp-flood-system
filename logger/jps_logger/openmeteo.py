"""Rain forecast from Open-Meteo (open-meteo.com: free, no key), 72 hours ahead.

Two readers, giving rows of the same shape, so the model is trained on exactly
the kind of value it later gets live:

  live      api.open-meteo.com/v1/forecast, read every 6 hours (weather.py)
  backfill  previous-runs-api.open-meteo.com: what the models forecast 1, 2 and
            3 days BEFORE each hour, for days the logger had not yet saved forecasts

Row: station_code, issued_at, valid_at (UTC, whole hours), precip_mm, prob_pct,
n_models, om_prob_pct.

  precip_mm    mean of the MODELS' forecasts for that hour (a multi-model mean)
  prob_pct     share of those models forecasting a wet hour (>= WET_HOUR_MM).
               This is a multi-model "chance of rain", worked out the same way
               live and in the backfill. (Open-Meteo's own precipitation_probability
               comes from the ECMWF/GFS ensembles and is not kept for past days,
               so it cannot be used to train on.)
  om_prob_pct  Open-Meteo's own precipitation_probability: live only, shown in
               the app next to prob_pct; empty in backfilled rows.

Backfilled rows say what was known BEFORE the hour: the value from
"precipitation_previous_dayN" comes from the model run about N days before the
hour, so issued_at = valid_at - N days. A feature at time t only uses rows with
issued_at <= t (ml/flood_ml/forecast.py), so nothing from after t is used.
"""
import math
from datetime import datetime, timedelta, timezone

import requests

FORECAST_URL = "https://api.open-meteo.com/v1/forecast"
PREVIOUS_RUNS_URL = "https://previous-runs-api.open-meteo.com/v1/forecast"
# Global models available both live and in the Previous Runs API (checked 27 Nov 2026:
# every one had all 216 hours for 16-24 Nov at Klang).
MODELS = ("ecmwf_ifs025", "gfs_seamless", "icon_seamless", "jma_seamless",
          "gem_seamless", "cma_grapes_global", "ukmo_seamless", "meteofrance_seamless")
WET_HOUR_MM = 0.1      # a "wet hour", the threshold ECMWF uses for its probability of precipitation
HOURS_AHEAD = 72       # 3 days
LEAD_DAYS = (1, 2, 3)  # backfill: forecasts made 1, 2 and 3 days earlier
CELL_DEG = 0.1         # stations closer than this share one request (the models' grids are 9-25 km)
CHUNK = 40             # locations per request
HEADERS = {"User-Agent": "fyp-flood-logger (student project; reads public forecasts every 6 h)"}
TIMEOUT_S = 60
COLUMNS = ["station_code", "issued_at", "valid_at", "precip_mm", "prob_pct", "n_models", "om_prob_pct"]
FMT = "%Y-%m-%dT%H:%M:%SZ"


def cells(stations):
    """{(lat, lon) rounded to CELL_DEG: [station ids]} for stations with a position."""
    out = {}
    for s in stations:
        if s.get("lat") is None or s.get("lon") is None:
            continue
        key = (round(round(s["lat"] / CELL_DEG) * CELL_DEG, 2), round(round(s["lon"] / CELL_DEG) * CELL_DEG, 2))
        out.setdefault(key, []).append(s["id"])
    return out


def _get(url, params, session):
    s = session or requests
    r = s.get(url, params=params, headers=HEADERS, timeout=TIMEOUT_S)
    if r.status_code >= 300:
        raise RuntimeError(f"Open-Meteo refused the request: HTTP {r.status_code} {r.text[:300]}")
    data = r.json()
    return data if isinstance(data, list) else [data]


def _chunks(keys):
    keys = list(keys)
    for i in range(0, len(keys), CHUNK):
        yield keys[i:i + CHUNK]


def _where(keys):
    return {"latitude": ",".join(f"{k[0]:.2f}" for k in keys),
            "longitude": ",".join(f"{k[1]:.2f}" for k in keys)}


def summarise_hour(values):
    """(mean mm, % of models wet, number of models) from one hour's model values; None if none."""
    vals = [v for v in values if v is not None and not (isinstance(v, float) and math.isnan(v)) and v >= 0]
    if not vals:
        return None
    wet = sum(1 for v in vals if v >= WET_HOUR_MM)
    return round(sum(vals) / len(vals), 2), round(100.0 * wet / len(vals)), len(vals)


def _utc(text):
    return datetime.strptime(text, "%Y-%m-%dT%H:%M").replace(tzinfo=timezone.utc)


def live_rows(models_payload, prob_payload, cell_map, issued_at):
    """Rows for the next HOURS_AHEAD hours after issued_at (UTC datetime).
    models_payload: one response per cell (same order as cell_map) with hourly
    precipitation_<model>; prob_payload: the same cells with hourly precipitation_probability."""
    out = []
    issued = issued_at.strftime(FMT)
    for (key, ids), mp, pp in zip(cell_map.items(), models_payload, prob_payload or [None] * len(cell_map)):
        h = mp["hourly"]
        om = {}
        if pp is not None:
            om = dict(zip(pp["hourly"]["time"], pp["hourly"].get("precipitation_probability") or []))
        for i, t in enumerate(h["time"]):
            valid = _utc(t)
            if not issued_at < valid <= issued_at + timedelta(hours=HOURS_AHEAD):
                continue
            s = summarise_hour([h.get(f"precipitation_{m}", [None] * len(h["time"]))[i] for m in MODELS])
            if s is None:
                continue
            for sid in ids:
                out.append({"station_code": sid, "issued_at": issued, "valid_at": valid.strftime(FMT),
                            "precip_mm": s[0], "prob_pct": s[1], "n_models": s[2], "om_prob_pct": om.get(t)})
    return out


def fetch_live(stations, now=None, session=None):
    """Live forecast rows for every station with a position. issued_at = the hour of the request."""
    now = (now or datetime.now(timezone.utc)).replace(minute=0, second=0, microsecond=0)
    cell_map = cells(stations)
    rows = []
    for keys in _chunks(cell_map):
        part = {k: cell_map[k] for k in keys}
        base = {**_where(keys), "forecast_days": 4, "timezone": "GMT"}
        mp = _get(FORECAST_URL, {**base, "hourly": "precipitation", "models": ",".join(MODELS)}, session)
        pp = _get(FORECAST_URL, {**base, "hourly": "precipitation_probability"}, session)
        rows += live_rows(mp, pp, part, now)
    return rows


def backfill_rows(payload, cell_map, start, end):
    """Rows from the Previous Runs API: for each hour and each lead day N, the
    models' forecast made N days before (issued_at = valid_at - N days)."""
    out = []
    for (key, ids), p in zip(cell_map.items(), payload):
        h = p["hourly"]
        for i, t in enumerate(h["time"]):
            valid = _utc(t)
            if not start <= valid < end:
                continue
            for n in LEAD_DAYS:
                s = summarise_hour([h.get(f"precipitation_previous_day{n}_{m}", [None] * len(h["time"]))[i]
                                    for m in MODELS])
                if s is None:
                    continue
                issued = (valid - timedelta(days=n)).strftime(FMT)
                for sid in ids:
                    out.append({"station_code": sid, "issued_at": issued, "valid_at": valid.strftime(FMT),
                                "precip_mm": s[0], "prob_pct": s[1], "n_models": s[2], "om_prob_pct": None})
    return out


def fetch_backfill(stations, start, end, session=None):
    """Backfilled rows for valid hours start <= t < end (UTC datetimes)."""
    cell_map = cells(stations)
    rows = []
    hourly = ",".join(f"precipitation_previous_day{n}" for n in LEAD_DAYS)
    for keys in _chunks(cell_map):
        part = {k: cell_map[k] for k in keys}
        params = {**_where(keys), "hourly": hourly, "models": ",".join(MODELS), "timezone": "GMT",
                  "start_date": start.strftime("%Y-%m-%d"),
                  "end_date": (end - timedelta(seconds=1)).strftime("%Y-%m-%d")}
        rows += backfill_rows(_get(PREVIOUS_RUNS_URL, params, session), part, start, end)
    return rows
