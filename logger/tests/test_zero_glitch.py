from jps_logger import collect


def lv(code, at, level):
    return {"station_code": code, "observed_at": at, "level_m": level}


# LG10 0.00 m glitches
def test_zero_far_from_the_previous_reading_is_dropped():
    kept, dropped = collect.drop_zero_glitches(
        [lv("A", "2026-11-19T22:30:00Z", 0.0)], {"A": (42.86, "2026-11-19T22:15:00+00:00")})
    assert kept == [] and dropped == [lv("A", "2026-11-19T22:30:00Z", 0.0)]


def test_zero_passing_through_with_the_tide_is_kept():
    kept, dropped = collect.drop_zero_glitches(
        [lv("A", "2026-11-20T02:15:00Z", 0.0)], {"A": (0.02, "2026-11-20T02:00:00Z")})
    assert len(kept) == 1 and dropped == []


def test_negative_levels_and_non_zero_jumps_are_never_touched():
    rows = [lv("A", "2026-11-20T02:15:00Z", -1.77), lv("B", "2026-11-20T02:15:00Z", 5.0)]
    kept, dropped = collect.drop_zero_glitches(rows, {"A": (0.5, "2026-11-20T02:00:00Z"),
                                                      "B": (42.0, "2026-11-20T02:00:00Z")})
    assert len(kept) == 2 and dropped == []


def test_zero_kept_when_there_is_nothing_recent_to_compare_with():
    old = {"A": (42.86, "2026-11-19T12:00:00Z")}  # over 2 hours before
    assert collect.drop_zero_glitches([lv("A", "2026-11-19T22:30:00Z", 0.0)], old)[1] == []
    assert collect.drop_zero_glitches([lv("A", "2026-11-19T22:30:00Z", 0.0)], {})[1] == []


def test_readings_of_one_run_are_checked_in_time_order():
    rows = [lv("A", "2026-11-19T22:30:00Z", 0.0), lv("A", "2026-11-19T22:15:00Z", 3.2)]
    kept, dropped = collect.drop_zero_glitches(rows, {})
    assert [r["level_m"] for r in kept] == [3.2] and len(dropped) == 1


class Store:
    def __init__(self, latest=None, fail=False):
        self.latest, self.fail, self.inserted, self.asked = latest or [], fail, {}, None

    def insert(self, table, rows, conflict_cols, update_existing=False):
        self.inserted.setdefault(table, []).extend(rows)
        return len(rows)

    def select(self, table, params):
        assert table == "jps_latest"
        self.asked = dict(params)
        if self.fail:
            raise RuntimeError("HTTP 500")
        return self.latest


def one_station_feed(level):
    payload = {"stations": [{"stationCode": "A", "stationName": "A", "districtName": "KLANG",
                             "lastUpdate": "17/11/2026 15:15:00", "waterLevel": level,
                             "wlth_normal": 40, "wlth_alert": 44, "wlth_warning": 45, "wlth_danger": 46}]}

    def fetch(path):
        if path.startswith("StationRiverLevels/GetWLAllStationData/"):
            return payload if path.endswith("/1") else {"stations": []}
        if path in ("StationRiverLevels", "StationRainfalls"):
            return []  # station position lists
        return {"stations": []}
    return fetch


def test_run_skips_a_glitch_and_says_so():
    from conftest import NOW
    store, msgs = Store(latest=[{"station_code": "A", "level_m": 42.86, "level_at": "2026-11-17T07:00:00+00:00"}]), []
    collect.run(one_station_feed(0), store, NOW, msgs.append, sources={"Selangor": ("selangor-api",)})
    assert store.inserted.get("jps_river_levels", []) == []
    assert store.asked["station_code"] == "in.(A)"
    assert any("0.00 m glitch at A" in m for m in msgs)


def test_run_keeps_zero_when_the_check_fails_and_never_asks_without_a_zero():
    from conftest import NOW
    store, msgs = Store(fail=True), []
    collect.run(one_station_feed(0), store, NOW, msgs.append, sources={"Selangor": ("selangor-api",)})
    assert [r["level_m"] for r in store.inserted["jps_river_levels"]] == [0.0]
    assert any("Could not check 0.00 m" in m for m in msgs)
    store = Store()
    collect.run(one_station_feed(41.2), store, NOW, lambda m: None, sources={"Selangor": ("selangor-api",)})
    assert store.asked is None and [r["level_m"] for r in store.inserted["jps_river_levels"]] == [41.2]
