"""Real floods from JKR's incident reports, and whether the flood chance warned in time.

    python -m flood_ml.incidents --readings readings.csv --stations stations_training.json \
        --incidents ../data/incidents --weather ../data/forecast --out output

data/incidents/ is written by the logger (logger/jps_logger/jkr.py, daily archive job).
Supabase has the same flood spots as a view (supabase/flood_events.sql).

Flood spots. Every JKR flood report counts as its own spot: nearby reports on different
roads stay separate (25 Nov 2026, Banting: Jalan TM 3, Jalan 2 RTB, Jalan 3 RTB, all at
01:00 UTC, 0.4-0.9 km apart = 3 spots). Two reports are merged only when they look like
one spot posted twice: same road name, reported within SAME_SPOT_H hours, under
SAME_SPOT_KM apart. Each spot is tied to the nearest river station in the station list
(within NEAR_KM).

Warned in time? For each spot, a FloodChance model is fitted only on rows whose 24 hours
ended before the review window (LOOKBACK_H before the report), so nothing from the flood
itself is seen. That model then states the chance for every hour of the window, as the
app would have shown it. The spot was warned in time if the headline chance (Warning)
reached WARN_CHANCE at least LEAD_H hours before the reported time; a river already at
Warning counts as warned from that hour. Spots on the same station and day share one
forecast, so the summary also counts station-days.

Limits: the report time is when JKR logged the flood, which can be after the water
rose; JKR only reports floods on roads; a nearest station up to 15 km away may be on
another river.
"""
import argparse
import json
import math
from pathlib import Path

import numpy as np
import pandas as pd

from .features import LEVEL_SPANS, build_features, clean_readings, validate_stations
from .probability import HEADLINE, LEVELS, MYT, ChanceModel, add_label, with_fill
from .weather import load_weather

SAME_SPOT_KM = 0.3
SAME_SPOT_H = 3.0
NEAR_KM = 15.0
LEAD_H = 24
WARN_CHANCE = 0.8
LOOKBACK_H = 72
MIN_PAST_ROWS = 400


def distance_km(lat1, lon1, lat2, lon2):
    p1, p2 = math.radians(lat1), math.radians(lat2)
    dp, dl = p2 - p1, math.radians(lon2 - lon1)
    a = math.sin(dp / 2) ** 2 + math.cos(p1) * math.cos(p2) * math.sin(dl / 2) ** 2
    return 6371.0 * 2 * math.asin(math.sqrt(a))


def load_reports(root):
    """Flood reports from data/incidents/jkr/: one row per incident (its latest details),
    with first/last sighting and the deepest depth seen."""
    files = sorted(Path(root, "jkr").rglob("*.csv.gz"))
    if not files:
        return pd.DataFrame()
    d = pd.concat([pd.read_csv(f) for f in files], ignore_index=True)
    d = d[(d["type"] == "Flood") | (d["type_ms"] == "Banjir")].copy()
    if d.empty:
        return d
    for c in ("seen_at", "occurred_at"):
        d[c] = pd.to_datetime(d[c], utc=True, errors="coerce")
    d = d.sort_values(["incident_id", "seen_at"])
    agg = d.groupby("incident_id").agg(first_seen_at=("seen_at", "min"), last_seen_at=("seen_at", "max"),
                                       max_depth_m=("depth_m", "max"), sightings=("seen_at", "nunique"))
    return d.groupby("incident_id").tail(1).set_index("incident_id").join(agg).reset_index()


def _road(v):
    return "" if pd.isna(v) else str(v).strip().upper()


def flood_spots(reports):
    """One row per flood spot (see module doc). spot_id = lowest incident id of the spot."""
    if reports.empty:
        return pd.DataFrame(columns=["spot_id", "incident_ids", "reports", "occurred_at", "lat", "lon"])
    r = reports.sort_values("incident_id").reset_index(drop=True)
    spot = {}
    for i, a in r.iterrows():
        sid = a["incident_id"]
        for _, b in r.iloc[:i].iterrows():
            if (_road(a["route_name"]) == _road(b["route_name"])
                    and pd.notna(a["occurred_at"]) and pd.notna(b["occurred_at"])
                    and abs((a["occurred_at"] - b["occurred_at"]).total_seconds()) <= SAME_SPOT_H * 3600
                    and not pd.isna(a["lat"]) and not pd.isna(b["lat"])
                    and distance_km(a["lat"], a["lon"], b["lat"], b["lon"]) < SAME_SPOT_KM):
                sid = spot[b["incident_id"]]
                break
        spot[a["incident_id"]] = sid
    r["spot_id"] = r["incident_id"].map(spot)
    out = []
    for sid, g in r.groupby("spot_id", sort=True):
        first = g.iloc[0]
        out.append({"spot_id": int(sid), "incident_ids": [int(x) for x in g["incident_id"]], "reports": len(g),
                    "occurred_at": g["occurred_at"].min(), "lat": first["lat"], "lon": first["lon"],
                    "state": first.get("state"), "district": first.get("district"),
                    "route_name": first.get("route_name"), "location_name": first.get("location_name"),
                    "max_depth_m": g[["depth_m", "max_depth_m"]].max().max(),
                    "first_seen_at": g["first_seen_at"].min(), "last_seen_at": g["last_seen_at"].max()})
    return pd.DataFrame(out)


def nearest_station(spots, stations, max_km=NEAR_KM):
    """spots with station_id and station_km: the nearest river station in the list (or None)."""
    s = spots.copy()
    ids, kms = [], []
    for _, sp in s.iterrows():
        best = None
        if not pd.isna(sp["lat"]):
            for st in stations:
                if st.get("lat") is None or st.get("lon") is None:
                    continue
                d = distance_km(sp["lat"], sp["lon"], st["lat"], st["lon"])
                if d <= max_km and (best is None or d < best[0]):
                    best = (d, st["id"])
        ids.append(best[1] if best else None)
        kms.append(round(best[0], 2) if best else None)
    s["station_id"], s["station_km"] = ids, kms
    return s


def _fit_before(feats, start, cache):
    """{level: ChanceModel or None} fitted only on rows whose 24 h ended before `start`."""
    if start not in cache:
        past = feats[feats["time"] + pd.Timedelta(hours=24) < start]
        models = {}
        for lv in LEVELS:
            lab = add_label(past, lv)
            models[lv] = ChanceModel.fit(lab, level=lv) if len(lab) >= MIN_PAST_ROWS else None
        cache[start] = models
    return cache[start]


def _hours(a, b):
    return round((b - a).total_seconds() / 3600, 1)


def check_spot(feats, spot, cache, level=HEADLINE, lead_h=LEAD_H, threshold=WARN_CHANCE, lookback_h=LOOKBACK_H):
    """Hour-by-hour chance before one flood spot, and when it first warned."""
    base = {"spot_id": spot["spot_id"], "incident_ids": spot["incident_ids"], "reports": spot["reports"],
            "occurred_at": None if pd.isna(spot["occurred_at"]) else spot["occurred_at"].strftime("%Y-%m-%dT%H:%MZ"),
            "district": spot.get("district"), "route_name": spot.get("route_name"),
            "station_id": spot.get("station_id"), "station_km": spot.get("station_km"), "level": level}
    if pd.isna(spot["occurred_at"]):
        return base | {"result": "no report time"}
    if not spot.get("station_id"):
        return base | {"result": f"no river station within {NEAR_KM:g} km"}
    t0 = spot["occurred_at"].floor("h")
    start = t0 - pd.Timedelta(hours=lookback_h)
    rows = feats[(feats["station_id"] == spot["station_id"]) & (feats["time"] >= start) & (feats["time"] <= t0)]
    rows = rows.sort_values("time")
    if rows.empty:
        return base | {"result": "no readings at this station before the flood"}
    span = rows[LEVEL_SPANS[level]]
    already = rows["level_above_normal"] >= span
    model = _fit_before(feats, start, cache).get(level)
    chance = pd.Series(np.nan, index=rows.index)
    below = ~already & rows["level_above_normal"].notna()
    if model is not None and below.any():
        chance[below] = model.predict(with_fill(rows[below], level))
    warned = already | (chance >= threshold)
    first = rows.loc[warned, "time"].min() if warned.any() else None
    at_lead = rows[rows["time"] <= t0 - pd.Timedelta(hours=lead_h)].tail(1)
    near = feats[(feats["station_id"] == spot["station_id"])
                 & (feats["time"].between(t0 - pd.Timedelta(hours=24), t0 + pd.Timedelta(hours=24)))]
    lead = _hours(first, t0) if first is not None else None
    if model is None and not already.any():
        result = "no model: too little history before this flood"
    else:
        result = "warned in time" if lead is not None and lead >= lead_h else (
            "warned late" if lead is not None else "missed")
    return base | {
        "result": result,
        "first_warning_at": None if first is None else first.strftime("%Y-%m-%dT%H:%MZ"),
        "lead_hours": lead,
        "chance_at_lead": (None if at_lead.empty or pd.isna(chance[at_lead.index[0]])
                           else round(float(chance[at_lead.index[0]]), 3)),
        "already_at_level_at_lead": bool(not at_lead.empty and already[at_lead.index[0]]),
        "max_chance_before": None if chance.isna().all() else round(float(chance.max()), 3),
        "river_reached_level_within_24h": bool((near["level_above_normal"] >= near[LEVEL_SPANS[level]]).any()),
        "model_calibration_day": None if model is None else model.calibration["day"],
        "series": [{"time": t.strftime("%Y-%m-%dT%H:%MZ"),
                    "level_above_normal_m": None if pd.isna(l) else round(float(l), 3),
                    "chance": None if pd.isna(c) else round(float(c), 3), "already": bool(a)}
                   for t, l, c, a in zip(rows["time"], rows["level_above_normal"], chance, already)],
    }


def warned_in_time(feats, spots, **kw):
    cache = {}
    checks = [check_spot(feats, sp, cache, **kw) for sp in spots.to_dict("records")]
    judged = [c for c in checks if c["result"] in ("warned in time", "warned late", "missed")]
    days = {}
    for c in judged:
        key = (c["station_id"], pd.Timestamp(c["occurred_at"]).tz_convert(MYT).date().isoformat())
        days[key] = days.get(key, False) or c["result"] == "warned in time"
    summary = {"flood_spots": len(checks), "judged": len(judged),
               "warned_in_time": sum(c["result"] == "warned in time" for c in judged),
               "warned_late": sum(c["result"] == "warned late" for c in judged),
               "missed": sum(c["result"] == "missed" for c in judged),
               "station_days": len(days), "station_days_warned_in_time": sum(days.values()),
               "rule": f"{kw.get('level', HEADLINE)} chance >= {kw.get('threshold', WARN_CHANCE):.0%} "
                       f"(or river already there) at least {kw.get('lead_h', LEAD_H)} h before the JKR report"}
    return {"summary": summary, "spots": checks}


def run(readings, stations, incidents_root, weather=None, **kw):
    validate_stations(stations)
    spots = nearest_station(flood_spots(load_reports(incidents_root)), stations)
    if spots.empty:
        return {"summary": {"flood_spots": 0}, "spots": []}
    feats = build_features(clean_readings(readings), stations, weather=weather)
    return warned_in_time(feats, spots, **kw)


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--readings", required=True)
    p.add_argument("--stations", required=True)
    p.add_argument("--incidents", default="../data/incidents")
    p.add_argument("--weather", help="logged weather forecasts (data/forecast folder)")
    p.add_argument("--out", default="output")
    p.add_argument("--level", default=HEADLINE, choices=LEVELS)
    p.add_argument("--threshold", type=float, default=WARN_CHANCE)
    p.add_argument("--lead", type=int, default=LEAD_H)
    a = p.parse_args()
    stations = json.loads(Path(a.stations).read_text(encoding="utf-8"))
    weather = load_weather(a.weather) if a.weather else None
    res = run(pd.read_csv(a.readings), stations, a.incidents, weather,
              level=a.level, threshold=a.threshold, lead_h=a.lead)
    Path(a.out).mkdir(parents=True, exist_ok=True)
    (Path(a.out) / "flood_check.json").write_text(json.dumps(res, indent=2, default=str), encoding="utf-8")
    s = res["summary"]
    print(f"JKR flood spots: {s['flood_spots']}")
    if s["flood_spots"]:
        print(f"Rule: {s['rule']}")
        print(f"Judged {s['judged']}: {s['warned_in_time']} warned in time, {s['warned_late']} late, "
              f"{s['missed']} missed; station-days {s['station_days_warned_in_time']}/{s['station_days']} in time")
    for c in res["spots"]:
        print(f"  spot {c['spot_id']} ({c['reports']} report(s)) {c['occurred_at']} {c['district']}, "
              f"{c['route_name']} -> {c['station_id']} ({c['station_km']} km): {c['result']}"
              + (f", lead {c['lead_hours']} h, chance {LEAD_H} h before {c['chance_at_lead']}, "
                 f"peak {c['max_chance_before']}" if "lead_hours" in c else ""))
    print(f"Written to {Path(a.out) / 'flood_check.json'}")


if __name__ == "__main__":
    main()
