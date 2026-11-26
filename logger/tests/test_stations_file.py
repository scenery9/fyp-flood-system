from datetime import datetime, timezone

from jps_logger import stations_file

from conftest import load

NOW = datetime(2026, 11, 17, 7, 0, tzinfo=timezone.utc)


def row(code, normal, alert, warning, danger, river=True):
    return {"station_code": code, "name": code, "district": "KLANG", "river_basin": "Sg. Klang",
            "has_river_level": river, "wl_normal": normal, "wl_alert": alert,
            "wl_warning": warning, "wl_danger": danger}


def stats(n=400, low=1.0, high=1.8, median=1.3):
    return {"n": n, "min": low, "max": high, "median": median}


# LG8 stations file for training on many stations
def test_keeps_only_stations_with_thresholds_in_order():
    rows = [row("A", 1.0, 2.0, 2.5, 3.0), row("ZERO", 9.26, 0, 12, 13), row("ZERO2", -2.1, 0, 0, 0),
            row("MISSING", 1.0, None, 2, 3), row("SWAPPED", 1.0, 2.0, 3.5, 3.0), row("RAIN", 1, 2, 3, 4, river=False)]
    out = stations_file.build(rows)
    assert [s["id"] for s in out] == ["A"]
    assert out[0] == {"id": "A", "name": "A", "state": "Selangor", "river": "Sg. Klang", "district": "KLANG",
                      "normal": 1.0, "alert": 2.0, "warning": 2.5, "danger": 3.0}


def test_base_entries_kept_unchanged_and_first():
    base = [{"id": "B", "normal": 5, "alert": 6, "warning": 7, "danger": 8, "upstream": ["A"]},
            {"id": "A", "normal": 1, "alert": 2, "warning": 3, "danger": 4}]
    rows = [row("A", 1.1, 2.2, 2.5, 3.0), row("B", 0, 1, 2, 3), row("C", 1, 2, 3, 4)]
    out = stations_file.build(rows, base, reading_stats={})  # base is kept even without readings
    assert out == base
    assert [s["id"] for s in stations_file.build(rows, base)] == ["B", "A", "C"]


def test_stations_with_unsound_readings_left_out():
    rows = [row(c, 1, 2, 3, 4) for c in ("OK", "FEW", "STUCK", "ALWAYS_ALERT", "NONE")]
    st = {"OK": stats(), "FEW": stats(n=10), "STUCK": stats(low=2.80, high=2.80, median=2.80),
          "ALWAYS_ALERT": stats(low=1.9, high=2.6, median=2.2)}
    out = stations_file.build(rows, reading_stats=st, min_readings=300)
    assert [s["id"] for s in out] == ["OK"]


def test_level_stats_counts_each_reading_once():
    levels = [{"station_code": "A", "observed_at": t, "level_m": v}
              for t, v in (("2026-11-20T00:00:00Z", 1.0), ("2026-11-20T00:15:00Z", 2.0),
                           ("2026-11-20T00:15:00Z", 2.0), ("2026-11-20T00:30:00Z", 4.0))]
    assert stations_file.level_stats(levels) == {"A": {"n": 3, "min": 1.0, "max": 4.0, "median": 2.0}}
    assert stations_file.level_stats([]) == {}


def test_melaka_stations_from_both_melaka_sources_with_logger_codes():
    from conftest import FIX
    from jps_logger import melaka, publicinfobanjir as pib

    pages = {melaka.RIVER_URL: "melaka_wl.html", pib.river_url("Melaka"): "pib_mlk_wl.html"}

    def fetch_page(url):
        return (FIX / pages[url]).read_text(encoding="utf-8")
    rows = stations_file.fetch_melaka_rows(fetch_page, NOW)
    codes = [r["station_code"] for r in rows]
    assert len(codes) == len(set(codes)) and rows
    assert all(r["state"] == "Melaka" for r in rows)
    assert not set(codes) & set(__import__("jps_logger.collect", fromlist=["x"]).MELAKA_CODES)  # renamed: site code
    out = stations_file.build(rows)
    assert out and all(s["state"] == "Melaka" and s["normal"] < s["alert"] for s in out)
    # the site down: publicinfobanjir alone still gives stations, and the problem is reported
    problems = []
    rows = stations_file.fetch_melaka_rows(
        lambda url: fetch_page(url) if "publicinfobanjir" in url else (_ for _ in ()).throw(ConnectionError()),
        NOW, problems)
    assert rows and problems


def test_from_feed_and_valid_for_ml():
    def fetch(path):
        if path == "StationRiverLevels":
            return load("wl_station_list.json")
        return load("wl_district_6.json") if path.endswith("/6") else {"stations": []}
    rows = stations_file.fetch_station_rows(fetch, NOW)
    out = {s["id"]: s for s in stations_file.build(rows)}
    assert out["BKLG0002L"]["normal"] == 2.8
    assert any("river" in s for s in out.values())  # basins from the station list
    for s in out.values():
        assert s["normal"] < s["alert"] <= s["warning"] <= s["danger"]
        assert "upstream" not in s
