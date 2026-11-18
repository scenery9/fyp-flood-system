from jps_logger import collect, melaka

from conftest import FIX, NOW, load


def page(name):
    return (FIX / name).read_text()


class FakeStore:
    def __init__(self):
        self.calls = []

    def insert(self, table, rows, conflict_cols, update_existing=False):
        self.calls.append((table, rows, conflict_cols, update_existing))
        return len(rows)


def selangor(path):
    if path.startswith("StationRiverLevels/GetWLAllStationData/"):
        return load("wl_district_6.json") if path.endswith("/6") else {"stations": []}
    if path.startswith("StationRainfalls/GetRFAllStationData/"):
        return load("rf_district_6.json") if path.endswith("/6") else {"stations": []}
    if path == "StationRiverLevels":
        return load("wl_station_list.json")
    if path == "StationRainfalls":
        return load("rf_station_list.json")
    raise AssertionError(path)


def melaka_pages(path):
    return page("melaka_wl.html") if path == melaka.RIVER_PAGE else page("melaka_rf.html")


# LG5 Melaka pages
def test_river_page_gives_names_districts_positions_and_thresholds():
    rows = {s["code"]: s for s in melaka.river_stations(page("melaka_wl.html"))}
    assert set(rows) == {"0290211WL", "0310271WL", "0290341WL", "0290999WL"}  # second table ignored
    pindah = rows["0290211WL"]
    assert pindah["name"] == "Sg. Melaka di Melaka Pindah"
    assert pindah["district"] == "ALOR GAJAH"  # same spelling style as Selangor
    assert (pindah["lat"], pindah["lon"]) == (2.37349, 102.22111)
    assert pindah["time"] == "17/11/2026 15:00:00"
    assert (pindah["level"], pindah["normal"], pindah["alert"], pindah["warning"], pindah["danger"]) == \
        (12.24, 10.0, 11.3, 11.48, 11.9)
    assert rows["0310271WL"]["level"] == -0.14  # below zero is a real reading at a barrage
    # a position of 0,0 is a page error, not a place in Melaka
    assert rows["0290999WL"]["lat"] is None and rows["0290999WL"]["level"] is None


def test_rain_page_gives_since_midnight_and_last_hour():
    rows = {s["code"]: s for s in melaka.rain_stations(page("melaka_rf.html"))}
    assert rows["0290211RF"]["today"] == 12.5 and rows["0290211RF"]["hourly"] == 3.0
    assert rows["0290211RF"]["district"] == "ALOR GAJAH"
    assert (rows["0310291RF"]["lat"], rows["0310291RF"]["lon"]) == (2.44136, 102.369)


def test_readings_use_the_same_checks_as_selangor():
    river = melaka.river_stations(page("melaka_wl.html"))
    levels = {r["station_code"]: r for r in melaka.river_level_rows(river, NOW)}
    # stale (15 Nov) and empty readings are not stored
    assert set(levels) == {"0290211WL", "0310271WL"}
    assert levels["0290211WL"] == {"station_code": "0290211WL", "observed_at": "2026-11-17T07:00:00Z", "level_m": 12.24}
    rain = {r["station_code"]: r for r in melaka.rainfall_rows(melaka.rain_stations(page("melaka_rf.html")), NOW)}
    assert rain["0290211RF"]["hourly_mm"] == 3.0 and rain["0290211RF"]["today_mm"] == 12.5


def test_station_rows_are_marked_melaka():
    river = melaka.river_stations(page("melaka_wl.html"))
    rain = melaka.rain_stations(page("melaka_rf.html"))
    rows = {r["station_code"]: r for r in melaka.station_rows(river, rain, NOW)}
    assert all(r["state"] == "Melaka" for r in rows.values())
    assert rows["0290211WL"]["has_river_level"] and not rows["0290211WL"]["has_rainfall"]
    assert rows["0290211RF"]["has_rainfall"] and rows["0290211RF"]["wl_danger"] is None
    assert rows["0290211WL"]["wl_danger"] == 11.9


def test_empty_or_strange_page_gives_no_rows():
    assert melaka.river_stations("") == []
    assert melaka.river_stations("<html><body>Access denied</body></html>") == []
    assert melaka.rain_stations("<table><tr><td>1</td></tr></table>") == []


def test_run_stores_selangor_and_melaka_together():
    store, msgs = FakeStore(), []
    assert collect.run(selangor, store, NOW, msgs.append, fetch_page=melaka_pages) == 0
    tables = {c[0]: c[1] for c in store.calls}
    states = {r["state"] for r in tables["jps_stations"]}
    assert states == {"Selangor", "Melaka"}
    # every station row has the same keys, as one Supabase request needs
    assert len({tuple(sorted(r)) for r in tables["jps_stations"]}) == 1
    assert {"0290211WL", "BKLG0002L"} <= {r["station_code"] for r in tables["jps_river_levels"]}
    assert "0 problems" in msgs[-1]


def test_blocked_melaka_site_warns_and_selangor_is_still_stored():
    def blocked(path):
        raise ConnectionError("403 Forbidden")
    store, msgs = FakeStore(), []
    assert collect.run(selangor, store, NOW, msgs.append, fetch_page=blocked) == 0
    assert any(m.startswith("::warning::") and "Melaka river level" in m for m in msgs)
    assert len({c[0]: c for c in store.calls}["jps_river_levels"][1]) == 2  # Selangor's two


def test_changed_melaka_layout_is_a_warning_not_a_failure():
    store, msgs = FakeStore(), []
    assert collect.run(selangor, store, NOW, msgs.append, fetch_page=lambda p: "<p>new design</p>") == 0
    assert any("no stations found" in m for m in msgs)


def test_melaka_alone_is_enough_for_a_run():
    def down(path):
        raise TimeoutError("slow")
    msgs = []
    assert collect.run(down, FakeStore(), NOW, msgs.append, fetch_page=melaka_pages) == 0
