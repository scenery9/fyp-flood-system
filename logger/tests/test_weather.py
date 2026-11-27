"""Weather forecast logger: Open-Meteo, MET Malaysia and the combined outlook.
Fixtures are real responses captured 27 Nov 2026 (see fixtures/README.md)."""
from datetime import datetime, timedelta, timezone

import pandas as pd
import pytest

from conftest import load
from jps_logger import metmalaysia as met
from jps_logger import openmeteo as om
from jps_logger import weather
from jps_logger.outlook import band, outlooks, station_outlook, window_date
from jps_logger.stations_file import add_positions

UTC = timezone.utc
STATIONS = [
    {"id": "BKLG0002L", "district": "KLANG", "state": "Selangor", "lat": 3.03798, "lon": 101.53449},
    {"id": "BPTL0004L", "district": "PETALING", "state": "Selangor", "lat": 3.01945, "lon": 101.59743},
    {"id": "0290241WL", "district": "MELAKA TENGAH", "state": "Melaka", "lat": 2.2, "lon": 102.25},
    {"id": "WPKL0001", "district": "KUALA LUMPUR", "state": "Selangor", "lat": 3.15, "lon": 101.7},
]


# ---------- Open-Meteo ----------

def test_cells_share_one_request_for_nearby_stations():
    c = om.cells(STATIONS[:2] + [{"id": "X", "lat": None, "lon": None}])
    assert c == {(3.0, 101.5): ["BKLG0002L"], (3.0, 101.6): ["BPTL0004L"]}


def test_summarise_hour_mean_and_share_of_wet_models():
    assert om.summarise_hour([0.0, 0.1, 0.5, None, 1.4]) == (0.5, 75, 4)
    assert om.summarise_hour([None, None]) is None


def test_live_rows_from_real_response():
    models, prob = load("openmeteo_live_models.json"), load("openmeteo_live_prob.json")
    cell_map = {(3.0, 101.6): ["BPTL0004L"], (2.2, 102.3): ["0290241WL"]}
    first = datetime.fromisoformat(models[0]["hourly"]["time"][0]).replace(tzinfo=UTC)
    issued = first + timedelta(hours=5)
    rows = om.live_rows(models, prob, cell_map, issued)
    one = [r for r in rows if r["station_code"] == "BPTL0004L"]
    assert len(one) == om.HOURS_AHEAD
    assert one[0]["valid_at"] == (issued + timedelta(hours=1)).strftime(om.FMT)
    assert all(r["n_models"] >= 6 and 0 <= r["prob_pct"] <= 100 and r["precip_mm"] >= 0 for r in one)
    assert any(r["om_prob_pct"] is not None for r in one)


def test_backfill_rows_are_issued_n_days_before_the_hour():
    payload = [load("openmeteo_previous_runs.json")]
    start = datetime(2026, 11, 20, tzinfo=UTC)
    rows = om.backfill_rows(payload, {(3.0, 101.6): ["BPTL0004L"]}, start, start + timedelta(days=1))
    assert len(rows) == 24 * len(om.LEAD_DAYS)
    for r in rows:
        lead = pd.Timestamp(r["valid_at"]) - pd.Timestamp(r["issued_at"])
        assert lead in (pd.Timedelta(days=1), pd.Timedelta(days=2), pd.Timedelta(days=3))
        assert r["om_prob_pct"] is None


# ---------- MET Malaysia ----------

@pytest.mark.parametrize("text,cls", [
    ("Tiada Hujan", 0), ("Mendung", 0), ("Hujan di beberapa tempat", 1),
    ("Ribut petir di beberapa tempat di kawasan pedalaman", 1), ("Hujan", 2), ("Ribut petir", 2),
    ("Ribut petir di kebanyakan tempat", 3), ("Hujan menyeluruh", 4), ("Ribut petir menyeluruh", 4),
    ("Jerebu", None), ("", None),
])
def test_rain_class(text, cls):
    assert met.rain_class(text) == cls


def test_every_phrase_in_the_real_forecast_is_known():
    for r in load("met_forecast.json"):
        for k in ("morning_forecast", "afternoon_forecast", "night_forecast", "summary_forecast"):
            assert met.rain_class(r[k]) is not None, r[k]


def test_forecast_rows_match_district_then_state():
    issued = datetime(2026, 11, 27, 6, tzinfo=UTC)
    rows = met.forecast_rows(load("met_forecast.json"), STATIONS, issued)
    loc = {r["station_code"]: r["location_id"] for r in rows}
    assert loc["BKLG0002L"] == "Ds054"      # Klang
    assert loc["BPTL0004L"] == "Ds057"      # Petaling
    assert loc["0290241WL"] == "Ds078"      # Melaka Tengah
    days = sorted({r["valid_date"] for r in rows if r["station_code"] == "BKLG0002L"})
    assert days[0] == "2026-11-27" and len(days) == met.DAYS_AHEAD


def test_warning_kinds_and_levels():
    w = load("met_warning.json")
    kinds = [met.warning_kind(x) for x in w]
    assert ("thunderstorm", 1) in kinds and ("continuous_rain", 1) in kinds
    assert kinds.count(None) == 3  # strong winds at sea (2) and "no advisory"
    assert met.warning_kind({"warning_issue": {"title_bm": "Amaran Hujan Berterusan"},
                             "heading_bm": "AMARAN HUJAN BERTERUSAN (BAHAYA)"}) == ("continuous_rain", 3)


def test_warning_areas_and_stations_covered():
    w = load("met_warning.json")
    storm = next(x for x in w if met.warning_kind(x) == ("thunderstorm", 1))
    areas = met.warning_areas(storm["text_bm"])
    assert areas["SELANGOR"] >= {"PETALING", "SEPANG"} and "KLANG" not in areas["SELANGOR"]
    assert areas["W.P. KUALA LUMPUR"] == set()
    covered = {r["station_code"] for r in met.warning_rows([storm], STATIONS)}
    # Petaling, Kuala Lumpur and Melaka (Alor Gajah, Jasin) are named; Klang and Melaka Tengah are not.
    assert covered == {"BPTL0004L", "WPKL0001"}
    r = met.warning_rows([storm], STATIONS)[0]
    assert r["valid_from"] == "2026-11-27T05:00:00Z" and r["valid_to"] == "2026-11-27T08:00:00Z"


# ---------- outlook (the two sources together) ----------

def _om(code, issued, hours_mm, prob=90):
    return [{"station_code": code, "issued_at": issued.strftime(om.FMT),
             "valid_at": (issued + timedelta(hours=h)).strftime(om.FMT),
             "precip_mm": mm, "prob_pct": prob, "n_models": 8, "om_prob_pct": None}
            for h, mm in hours_mm.items()]


def test_band_thresholds():
    assert [band(x) for x in (None, 0.5, 1, 9.9, 10, 19.9, 20)] == [None, 0, 1, 1, 2, 2, 3]


def test_outlook_windows_and_agreement():
    now = datetime(2026, 11, 27, 4, tzinfo=UTC)  # 12:00 Malaysia time
    rows = _om("S", now, {1: 2.0, 3: 1.0, 4: 5.0, 20: 13.0, 30: 0.5, 60: 2.0})
    met_rows = [{"station_code": "S", "issued_at": now.strftime(om.FMT), "valid_date": window_date(now, d),
                 "summary": "x", "rain_class": c, "thunder": 0} for d, c in ((1, 3), (2, 2), (3, 0))]
    o = station_outlook("S", rows, met_rows, [], now + timedelta(minutes=5))
    assert o["next_3h_mm"] == 3.0
    assert (o["day1_mm"], o["day2_mm"], o["day3_mm"]) == (21.0, 0.5, 2.0)
    assert (o["day1_band"], o["day2_band"], o["day3_band"]) == (3, 0, 1)
    # day 2: Open-Meteo dry but MET rain; day 3: Open-Meteo rain but MET dry
    assert (o["day1_agree"], o["day2_agree"], o["day3_agree"]) == (1, 0, 0)
    assert o["rain_days_3d"] == 2 and o["total_3d_mm"] == 23.5
    assert o["warning_level"] == 0


def test_outlook_never_uses_a_forecast_issued_after_now():
    now = datetime(2026, 11, 27, 4, tzinfo=UTC)
    rows = _om("S", now - timedelta(hours=6), {7: 1.0}) + _om("S", now + timedelta(hours=1), {2: 50.0})
    o = station_outlook("S", rows, [], [], now)
    assert o["om_issued_at"] == (now - timedelta(hours=6)).strftime(om.FMT)
    assert o["day1_mm"] == 1.0


def test_outlook_takes_the_highest_active_warning():
    now = datetime(2026, 11, 27, 4, tzinfo=UTC)
    f = lambda h: (now + timedelta(hours=h)).strftime(om.FMT)
    warn = [
        {"station_code": "S", "issued_at": f(-2), "valid_from": f(-1), "valid_to": f(2), "kind": "thunderstorm",
         "level": 1, "title": "Amaran Ribut Petir"},
        {"station_code": "S", "issued_at": f(-5), "valid_from": f(10), "valid_to": f(80), "kind": "continuous_rain",
         "level": 2, "title": "Amaran Hujan Berterusan"},
        {"station_code": "S", "issued_at": f(-30), "valid_from": f(-29), "valid_to": f(-1), "kind": "continuous_rain",
         "level": 3, "title": "ended"},
        {"station_code": "S", "issued_at": f(1), "valid_from": f(1), "valid_to": f(5), "kind": "continuous_rain",
         "level": 3, "title": "not issued yet"},
    ]
    o = station_outlook("S", [], [], warn, now)
    assert (o["warning_level"], o["warning_kind"]) == (2, "continuous_rain")


def test_outlooks_for_many_stations():
    now = datetime(2026, 11, 27, 4, tzinfo=UTC)
    o = outlooks(["A", "B"], _om("A", now, {1: 1.0}), [], [], now)
    assert [x["station_code"] for x in o] == ["A", "B"]
    assert o[0]["next_3h_mm"] == 1.0 and o[1]["next_3h_mm"] is None


# ---------- files and positions ----------

def test_write_rows_by_issue_day_and_without_duplicates(tmp_path):
    now = datetime(2026, 11, 27, 4, tzinfo=UTC)
    rows = _om("S", now, {1: 1.0, 2: 2.0})
    assert weather.write_rows(tmp_path, "openmeteo", rows) == 1
    assert weather.write_rows(tmp_path, "openmeteo", rows) == 0  # same rows: file unchanged
    df = weather.read_kind(tmp_path, "openmeteo")
    assert len(df) == 2 and list(df.columns) == om.COLUMNS
    assert (tmp_path / "openmeteo" / "2026" / "11" / "2026-11-27.csv.gz").exists()


def test_add_positions_uses_district_average_when_missing():
    st = [{"id": "A", "district": "KLANG", "state": "Selangor"},
          {"id": "B", "district": "KLANG", "state": "Selangor"},
          {"id": "C", "district": "GOMBAK", "state": "Selangor"}]
    rows = [{"station_code": "A", "lat": 3.0, "lon": 101.4}, {"station_code": "B", "lat": None, "lon": None}]
    out, missing = add_positions(st, rows)
    assert out[0]["lat"] == 3.0 and "position" not in out[0]
    assert out[1]["position"] == "district" and out[1]["lat"] == 3.0
    assert out[2]["position"] == "state" and missing == []


def test_collect_keeps_going_when_one_source_fails(monkeypatch):
    def boom(*a, **k):
        raise RuntimeError("down")
    monkeypatch.setattr(om, "fetch_live", boom)
    monkeypatch.setattr(met, "get_json", lambda path, s=None: load(f"met_{path}.json"))
    msgs = []
    code = weather.collect(STATIONS, datetime(2026, 11, 27, 6, tzinfo=UTC), out=msgs.append)
    assert code == 0
    assert any("Open-Meteo could not be read" in m for m in msgs)
    assert any(m.startswith("met: ") for m in msgs)
