import math

import pandas as pd
import pytest

from jps_logger import collect
from jps_logger.export import codes_from_stations_file, to_model_csv
from jps_logger.rain import increments
from jps_logger.store import Store

from conftest import NOW, load


class FakeStore:
    def __init__(self):
        self.calls = []

    def insert(self, table, rows, conflict_cols, update_existing=False):
        self.calls.append((table, rows, conflict_cols, update_existing))
        return len(rows)


def fake_fetch(fail=()):
    def fetch(path):
        if any(f in path for f in fail):
            raise TimeoutError("slow")
        if path.startswith("StationRiverLevels/GetWLAllStationData/"):
            return load("wl_district_6.json") if path.endswith("/6") else {"stations": []}
        if path.startswith("StationRainfalls/GetRFAllStationData/"):
            return load("rf_district_6.json") if path.endswith("/6") else {"stations": []}
        if path == "StationRiverLevels":
            return load("wl_station_list.json")
        if path == "StationRainfalls":
            return load("rf_station_list.json")
        raise AssertionError(path)
    return fetch


# LG3 one logging run
def test_run_stores_stations_levels_and_rain():
    store, msgs = FakeStore(), []
    assert collect.run(fake_fetch(), store, NOW, msgs.append) == 0
    tables = {c[0]: c for c in store.calls}
    assert set(tables) == {"jps_stations", "jps_river_levels", "jps_rainfall"}
    assert tables["jps_stations"][3] is True  # station details are refreshed
    assert tables["jps_river_levels"][3] is False  # readings are never overwritten
    assert tables["jps_river_levels"][2] == ["station_code", "observed_at"]
    assert len(tables["jps_river_levels"][1]) == 2 and len(tables["jps_rainfall"][1]) == 2
    assert "0 problems" in msgs[-1]


def test_one_failing_district_does_not_lose_the_others():
    store, msgs = FakeStore(), []
    assert collect.run(fake_fetch(fail=("GetWLAllStationData/3",)), store, NOW, msgs.append) == 0
    assert any("district 3 river level" in m and m.startswith("::warning::") for m in msgs)
    assert len(dict((c[0], c) for c in store.calls)["jps_river_levels"][1]) == 2


def test_run_fails_only_when_nothing_could_be_read():
    msgs = []
    assert collect.run(fake_fetch(fail=("Station",)), FakeStore(), NOW, msgs.append) == 1
    assert msgs[-1].startswith("::error::")


def test_dry_run_stores_nothing():
    msgs = []
    assert collect.run(fake_fetch(), None, NOW, msgs.append) == 0
    assert "dry run" in msgs[-1]


def test_same_reading_in_two_districts_is_sent_once():
    def fetch(path):
        if "GetWLAllStationData" in path:
            return load("wl_district_6.json")  # every district returns the same stations
        return fake_fetch()(path)
    store = FakeStore()
    collect.run(fetch, store, NOW, lambda m: None)
    rows = dict((c[0], c) for c in store.calls)["jps_river_levels"][1]
    assert len(rows) == len({(r["station_code"], r["observed_at"]) for r in rows}) == 2


# LG4 Supabase connection
class FakeResponse:
    def __init__(self, status=201, body=None):
        self.status_code, self._body, self.text = status, body or [], ""

    def json(self):
        return self._body


class FakeHttp:
    def __init__(self, pages=None, status=201):
        self.posts, self.gets, self.pages, self.status = [], [], list(pages or []), status

    def post(self, url, params, headers, json, timeout):
        self.posts.append((url, params, headers, json))
        return FakeResponse(self.status)

    def get(self, url, params, headers, timeout):
        self.gets.append(params)
        return FakeResponse(200, self.pages.pop(0))


def test_key_only_in_apikey_header_and_duplicates_ignored():
    http = FakeHttp()
    s = Store("https://x.supabase.co/", "sb_secret_abc", session=http)
    s.insert("jps_river_levels", [{"a": i} for i in range(1200)], ["station_code", "observed_at"])
    assert len(http.posts) == 3  # sent in chunks of 500
    url, params, headers, _ = http.posts[0]
    assert url == "https://x.supabase.co/rest/v1/jps_river_levels"
    assert params == {"on_conflict": "station_code,observed_at"}
    assert headers["apikey"] == "sb_secret_abc" and "Authorization" not in headers
    assert headers["Prefer"].startswith("resolution=ignore-duplicates")


def test_refused_insert_raises_without_showing_the_key():
    s = Store("https://x.supabase.co", "sb_secret_abc", session=FakeHttp(status=401))
    with pytest.raises(RuntimeError) as e:
        s.insert("jps_rainfall", [{"a": 1}], ["station_code", "observed_at"])
    assert "401" in str(e.value) and "sb_secret_abc" not in str(e.value)


def test_missing_settings_stop_with_a_message(monkeypatch):
    for v in ("SUPABASE_URL", "SUPABASE_SECRET_KEY", "SUPABASE_PUBLISHABLE_KEY"):
        monkeypatch.delenv(v, raising=False)
    with pytest.raises(SystemExit):
        Store()
    with pytest.raises(SystemExit):
        Store("http://not-https.example", "k")


def test_reading_goes_page_by_page():
    http = FakeHttp(pages=[[{"n": i} for i in range(1000)], [{"n": 1}]])
    rows = Store("https://x.supabase.co", "k", session=http).select_all(
        "jps_rainfall", "*", [("observed_at", "gte.a"), ("observed_at", "lt.b")])
    assert len(rows) == 1001
    assert [dict(g)["offset"] for g in http.gets] == [0, 1000]
    assert ("observed_at", "gte.a") in http.gets[0] and ("observed_at", "lt.b") in http.gets[0]


# LG5 rain per interval
def rain(rows):
    return pd.DataFrame(rows, columns=["station_code", "observed_at", "today_mm"])


def test_rain_comes_from_the_day_total_not_the_rolling_hour():
    r = increments(rain([
        ("A", "2026-11-17T06:30:00Z", 33.0),
        ("A", "2026-11-17T06:45:00Z", 33.5),
        ("A", "2026-11-17T07:00:00Z", 40.0),
    ]))
    assert math.isnan(r["rainfall_mm"].iloc[0])
    assert list(r["rainfall_mm"].iloc[1:]) == [0.5, 6.5]


def test_new_day_starts_from_midnight_malaysia_time():
    r = increments(rain([
        ("A", "2026-11-17T15:45:00Z", 50.0),  # 23:45 MYT
        ("A", "2026-11-17T16:15:00Z", 2.0),   # 00:15 MYT next day
    ]))
    assert r["rainfall_mm"].iloc[1] == 2.0


def test_gaps_and_corrections_are_left_empty():
    r = increments(rain([
        ("A", "2026-11-17T01:00:00Z", 10.0),
        ("A", "2026-11-17T03:00:00Z", 20.0),  # 2-hour gap: cannot place the rain in time
        ("A", "2026-11-17T03:15:00Z", 18.0),  # total went down
        ("A", "2026-11-17T03:30:00Z", 19.0),
    ]))
    assert math.isnan(r["rainfall_mm"].iloc[1]) and math.isnan(r["rainfall_mm"].iloc[2])
    assert r["rainfall_mm"].iloc[3] == 1.0


def test_stations_are_worked_out_separately():
    r = increments(rain([
        ("A", "2026-11-17T06:30:00Z", 5.0), ("B", "2026-11-17T06:30:00Z", 50.0),
        ("A", "2026-11-17T06:45:00Z", 6.0), ("B", "2026-11-17T06:45:00Z", 51.0),
    ]))
    assert r.set_index(["station_code", "observed_at"])["rainfall_mm"].dropna().tolist() == [1.0, 1.0]


# LG6 export for ml/
def test_export_matches_what_the_model_reads():
    levels = [{"station_code": "A", "observed_at": "2026-11-17T06:30:00+00:00", "level_m": 2.0},
              {"station_code": "A", "observed_at": "2026-11-17T06:45:00+00:00", "level_m": 2.1}]
    rainfall = [{"station_code": "A", "observed_at": "2026-11-17T06:30:00+00:00", "today_mm": 1.0},
                {"station_code": "A", "observed_at": "2026-11-17T06:45:00+00:00", "today_mm": 3.0},
                {"station_code": "R", "observed_at": "2026-11-17T06:45:00+00:00", "today_mm": 9.0}]
    df = to_model_csv(levels, rainfall)
    assert list(df.columns) == ["station_id", "time", "rainfall_mm", "river_level_m"]
    a = df[df["station_id"] == "A"]
    assert list(a["time"]) == ["2026-11-17T06:30:00Z", "2026-11-17T06:45:00Z"]
    assert list(a["river_level_m"]) == [2.0, 2.1] and a["rainfall_mm"].iloc[1] == 2.0
    assert math.isnan(df[df["station_id"] == "R"]["river_level_m"].iloc[0])  # rainfall-only station


def test_export_output_feeds_the_model_cleaning_step():
    import sys
    from pathlib import Path
    sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "ml"))
    from flood_ml.features import clean_readings
    levels = [{"station_code": "A", "observed_at": f"2026-11-17T06:{m:02d}:00+00:00", "level_m": 2.0 + m / 100}
              for m in (0, 15, 30, 45)]
    rainfall = [{"station_code": "A", "observed_at": f"2026-11-17T06:{m:02d}:00+00:00", "today_mm": float(m)}
                for m in (0, 15, 30, 45)]
    c = clean_readings(to_model_csv(levels, rainfall))
    assert len(c) == 1 and c["rainfall_mm"].iloc[0] == 45.0 and c["river_level_m"].iloc[0] == 2.45


def test_export_can_be_limited_to_a_river(tmp_path):
    from pathlib import Path
    klang = Path(__file__).resolve().parents[2] / "ml" / "stations_klang.json"
    assert codes_from_stations_file(klang) == ["BKLG0002L", "BPTL0004L", "BPTL0061L"]
    assert to_model_csv([], []).empty
