"""Flood spots from JKR reports and the warned-in-time check (incidents.py)."""
import gzip

import pandas as pd

from flood_ml.features import build_features
from flood_ml.incidents import check_spot, flood_spots, load_reports, nearest_station, warned_in_time

COLS = "incident_id,seen_at,type,type_ms,occurred_at,lat,lon,state,district,location_name,route_name,depth_m"


def _write(root, rows):
    p = root / "jkr" / "2026" / "11" / "2026-11-27.csv.gz"
    p.parent.mkdir(parents=True, exist_ok=True)
    with gzip.open(p, "wt", encoding="utf-8") as f:
        f.write(COLS + "\n" + "\n".join(rows) + "\n")


def _reports(tmp_path):
    _write(tmp_path, [
        # Banting, 25 Nov 2026: three roads at the same hour, 0.4-0.9 km apart
        "10636,2026-11-27T09:00:00Z,Flood,Banjir,2026-11-25T01:00:00Z,2.815525,101.661452,Selangor,Kuala Langat,a,JALAN TM 3,0.1",
        "10637,2026-11-27T09:00:00Z,Flood,Banjir,2026-11-25T01:00:00Z,2.814308,101.65328,Selangor,Kuala Langat,b,JALAN 2 RTB,0.1",
        "10638,2026-11-27T09:00:00Z,Flood,Banjir,2026-11-25T01:00:00Z,2.81463,101.658478,Selangor,Kuala Langat,c,JALAN 3 RTB,0.1",
        # a re-post of 10636 (same road, 1.5 h later, ~10 m away), seen twice
        "10700,2026-11-27T09:00:00Z,Flood,Banjir,2026-11-25T02:30:00Z,2.8156,101.6615,Selangor,Kuala Langat,d,Jalan TM 3 ,0.4",
        "10700,2026-11-27T10:00:00Z,Flood,Banjir,2026-11-25T02:30:00Z,2.8156,101.6615,Selangor,Kuala Langat,d,Jalan TM 3 ,0.6",
        # same road a day later: a new flood
        "10701,2026-11-27T09:00:00Z,Flood,Banjir,2026-11-26T09:00:00Z,2.815525,101.661452,Selangor,Kuala Langat,a,JALAN TM 3,0.2",
        "10702,2026-11-27T09:00:00Z,Landslide,Tanah Runtuh,2026-11-25T01:00:00Z,2.8,101.6,Selangor,Kuala Langat,e,JALAN X,4",
    ])
    return load_reports(tmp_path)


def test_reports_keep_floods_only_one_row_per_incident(tmp_path):
    r = _reports(tmp_path)
    assert sorted(r["incident_id"]) == [10636, 10637, 10638, 10700, 10701]
    re_post = r[r["incident_id"] == 10700].iloc[0]
    assert re_post["sightings"] == 2 and re_post["max_depth_m"] == 0.6


def test_every_report_counts_except_a_re_post_of_the_same_spot(tmp_path):
    s = flood_spots(_reports(tmp_path)).set_index("spot_id")
    assert sorted(s.index) == [10636, 10637, 10638, 10701]
    assert s.loc[10636, "incident_ids"] == [10636, 10700] and s.loc[10636, "reports"] == 2
    assert s.loc[10636, "max_depth_m"] == 0.6
    assert s.loc[10701, "reports"] == 1


def test_nearest_station_within_15_km(tmp_path):
    stations = [{"id": "NEAR", "lat": 2.81344, "lon": 101.64188}, {"id": "FAR", "lat": 3.5, "lon": 101.0},
                {"id": "NOPOS"}]
    s = nearest_station(flood_spots(_reports(tmp_path)), stations).set_index("spot_id")
    assert s.loc[10637, "station_id"] == "NEAR" and 1.0 < s.loc[10637, "station_km"] < 1.5
    far = nearest_station(flood_spots(_reports(tmp_path)), [stations[1]])
    assert far["station_id"].isna().all()


def test_check_uses_only_data_before_the_window(clean, stations):
    feats = build_features(clean, stations)
    sid = stations[0]["id"]
    t0 = feats["time"].max() - pd.Timedelta(hours=6)
    spot = {"spot_id": 1, "incident_ids": [1], "reports": 1, "occurred_at": t0, "district": "X",
            "route_name": "R", "station_id": sid, "station_km": 1.0}
    cache = {}
    c = check_spot(feats, spot, cache, lookback_h=72)
    start = t0.floor("h") - pd.Timedelta(hours=72)
    assert list(cache) == [start]                       # one model, fitted before the window
    assert c["result"] in ("warned in time", "warned late", "missed",
                           "no model: too little history before this flood")
    times = pd.to_datetime([s["time"] for s in c["series"]], utc=True)
    assert times.min() >= start and times.max() <= t0   # nothing after the report
    assert all(s["chance"] is None or 0 <= s["chance"] <= 1 for s in c["series"])


def test_spot_without_station_is_not_judged(clean, stations):
    feats = build_features(clean, stations)
    spots = pd.DataFrame([{"spot_id": 2, "incident_ids": [2], "reports": 1,
                           "occurred_at": feats["time"].max(), "district": "X", "route_name": "R",
                           "station_id": None, "station_km": None}])
    res = warned_in_time(feats, spots)
    assert res["spots"][0]["result"].startswith("no river station")
    assert res["summary"]["flood_spots"] == 1 and res["summary"]["judged"] == 0
