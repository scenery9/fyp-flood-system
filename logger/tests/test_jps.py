from datetime import timedelta

from jps_logger import jps

from conftest import NOW


# LG1 reading the JPS feed
def test_malaysia_time_is_stored_as_utc():
    assert jps.parse_time("17/11/2026 14:45:00") == "2026-11-17T06:45:00Z"
    assert jps.parse_time("01/01/2027 03:00:00") == "2026-12-31T19:00:00Z"  # crosses midnight
    assert jps.parse_time("not a date") is None
    assert jps.parse_time(None) is None


def test_river_levels_skip_offline_and_empty_readings(wl):
    rows = jps.river_level_rows(wl, NOW)
    codes = {r["station_code"] for r in rows}
    assert codes == {"BKLG0002L", "BKLG0004"}  # -9999 (offline) and null are skipped
    sri_muda = next(r for r in rows if r["station_code"] == "BKLG0002L")
    assert sri_muda == {"station_code": "BKLG0002L", "observed_at": "2026-11-17T06:45:00Z", "level_m": 1.55}


def test_rainfall_keeps_both_jps_totals(rf):
    rows = {r["station_code"]: r for r in jps.rainfall_rows(rf, NOW)}
    assert rows["BKLG0002L"]["hourly_mm"] == 24.5
    assert rows["BKLG0002L"]["today_mm"] == 33.5
    # A station stuck since 2025 (Kg. Jawa) is not stored: readings over 24 hours old are skipped.
    assert "BKLG0007L" not in rows


def test_stale_readings_are_skipped_but_recent_ones_kept(wl):
    wl["stations"][0]["lastUpdate"] = "16/11/2026 15:30:00"  # 23 h 50 min before NOW
    assert "BKLG0002L" in {r["station_code"] for r in jps.river_level_rows(wl, NOW)}
    wl["stations"][0]["lastUpdate"] = "16/11/2026 15:10:00"  # 24 h 10 min before NOW
    assert "BKLG0002L" not in {r["station_code"] for r in jps.river_level_rows(wl, NOW)}


def test_future_dated_readings_are_refused(wl):
    wl["stations"][0]["lastUpdate"] = "17/11/2026 23:00:00"  # 15:00 UTC, hours ahead of NOW
    assert "BKLG0002L" not in {r["station_code"] for r in jps.river_level_rows(wl, NOW)}
    assert jps.river_level_rows(wl, NOW + timedelta(hours=9))  # fine once that time has come


def test_bad_values_do_not_crash():
    payload = {"stations": [
        {"stationCode": "A", "lastUpdate": "17/11/2026 14:45:00", "waterLevel": "abc"},
        {"stationCode": "B", "lastUpdate": "17/11/2026 14:45:00", "waterLevel": True},
        {"stationCode": None, "lastUpdate": "17/11/2026 14:45:00", "waterLevel": 1.0},
        {"stationCode": "C", "lastUpdate": "", "waterLevel": 1.0},
        {"stationCode": "D", "lastUpdate": "17/11/2026 14:45:00", "hourlyRainfall": -1, "todayRainfall": None},
    ]}
    assert jps.river_level_rows(payload, NOW) == []
    assert jps.rainfall_rows(payload, NOW) == []
    assert jps.river_level_rows({}, NOW) == [] and jps.rainfall_rows({"stations": None}, NOW) == []


# LG2 station list
def test_stations_combine_both_feeds_with_positions(wl, rf, lists):
    rows = {r["station_code"]: r for r in jps.station_rows([wl], [rf], *lists, NOW)}
    s = rows["BKLG0002L"]
    assert s["has_river_level"] and s["has_rainfall"]
    assert (s["lat"], s["lon"], s["river_basin"]) == (3.037984, 101.534493, "SG. KLANG")
    assert (s["wl_normal"], s["wl_alert"], s["wl_warning"], s["wl_danger"]) == (2.8, 4.4, 4.7, 5.0)
    kebun = rows["BKLG0016L"]  # rainfall only
    assert kebun["has_rainfall"] and not kebun["has_river_level"] and kebun["wl_normal"] is None
    assert kebun["river_basin"] is None  # "N/A" is not a basin
    assert rows["BKLG0028L"]["lat"] == 3.0247718  # position found in the rainfall list only
    assert len(rows) == len({s["stationCode"] for p in (wl, rf) for s in p["stations"]})
    assert rows["BKLG0007L"]["has_rainfall"]  # a stuck station is still listed, just without new readings


def test_every_station_row_has_the_same_columns(wl, rf, lists):
    rows = jps.station_rows([wl], [rf], *lists, NOW)
    assert len({tuple(sorted(r)) for r in rows}) == 1  # needed for one bulk insert
