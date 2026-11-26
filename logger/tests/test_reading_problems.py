from jps_logger import collect, jps

from conftest import NOW  # 2026-11-17 07:20 UTC = 15:20 Malaysia time


def st(code, level, when="17/11/2026 15:15:00"):
    return {"stationCode": code, "stationName": code, "districtName": "KLANG", "lastUpdate": when, "waterLevel": level,
            "wlth_normal": 1, "wlth_alert": 2, "wlth_warning": 3, "wlth_danger": 4}


# LG11 why a river station has no usable reading
def test_each_kind_of_bad_reading_is_named():
    payload = {"stations": [st("OK", 1.2), st("OFF", -9999), st("EST", -8888), st("EMPTY", None),
                            st("OLD", 1.0, "10/11/2026 08:00:00"), st("FUTURE", 1.0, "18/11/2026 15:15:00"),
                            st("NOTIME", 1.0, "not a time"), st("NEG", -1.77)]}
    assert jps.river_level_problems(payload, NOW) == {
        "OFF": "offline", "EST": "estimated", "EMPTY": "no_value", "OLD": "old_time",
        "FUTURE": "bad_time", "NOTIME": "bad_time"}
    # every station either gives a reading or a named problem, never both
    good = {r["station_code"] for r in jps.river_level_rows(payload, NOW)}
    assert good == {"OK", "NEG"} and not good & set(jps.river_level_problems(payload, NOW))


class Store:
    def __init__(self, refuse=False, latest=None):
        self.refuse, self.latest, self.calls = refuse, latest or [], []

    def insert(self, table, rows, conflict_cols, update_existing=False):
        if self.refuse and table == "jps_stations" and any("wl_problem" in r for r in rows):
            raise RuntimeError("Supabase refused jps_stations rows: HTTP 400 Could not find the 'wl_problem' column")
        self.calls.append((table, [dict(r) for r in rows]))
        return len(rows)

    def select(self, table, params):
        return self.latest

    def stations(self):
        return {r["station_code"]: r for t, rows in self.calls if t == "jps_stations" for r in rows}


def feed(*stations):
    def fetch(path):
        if path.startswith("StationRiverLevels/GetWLAllStationData/"):
            return {"stations": list(stations)} if path.endswith("/1") else {"stations": []}
        if path in ("StationRiverLevels", "StationRainfalls"):
            return []
        return {"stations": []}
    return fetch


def test_run_records_the_problem_on_the_station_and_clears_it_when_fine():
    store, msgs = Store(), []
    collect.run(feed(st("A", -9999), st("B", 2.5)), store, NOW, msgs.append, sources={"Selangor": ("selangor-api",)})
    rows = store.stations()
    assert rows["A"]["wl_problem"] == "offline" and rows["A"]["wl_problem_at"] == "2026-11-17T07:20:00Z"
    assert rows["B"]["wl_problem"] is None and rows["B"]["wl_problem_at"] is None
    assert any("offline 1" in m for m in msgs)


def test_glitch_zero_is_recorded_as_a_problem():
    store = Store(latest=[{"station_code": "A", "level_m": 42.86, "level_at": "2026-11-17T07:00:00+00:00"}])
    collect.run(feed(st("A", 0)), store, NOW, lambda m: None, sources={"Selangor": ("selangor-api",)})
    assert store.stations()["A"]["wl_problem"] == "glitch"


def test_before_the_sql_file_is_run_rows_are_sent_without_the_new_columns():
    store, msgs = Store(refuse=True), []
    assert collect.run(feed(st("A", -9999)), store, NOW, msgs.append, sources={"Selangor": ("selangor-api",)}) == 0
    assert "wl_problem" not in store.stations()["A"]
    assert any("reading_problems.sql" in m for m in msgs)
