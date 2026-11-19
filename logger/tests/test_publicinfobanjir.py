from jps_logger import collect, jps, melaka, publicinfobanjir as pib

from conftest import FIX, NOW, load


def page(name):
    return (FIX / name).read_text()


PAGES = {
    pib.river_url("Selangor"): "pib_sel_wl.html",
    pib.rain_url("Selangor"): "pib_sel_rf.html",
    pib.river_url("Melaka"): "pib_mlk_wl.html",
    pib.rain_url("Melaka"): "pib_mlk_rf.html",
    melaka.RIVER_URL: "melaka_wl.html",
    melaka.RAIN_URL: "melaka_rf.html",
}


def pages(down=()):
    """Serves the fixture pages; any URL containing a text in `down` fails."""
    asked = []

    def fetch_page(url):
        asked.append(url)
        if any(d in url for d in down):
            raise ConnectionError("down")
        return page(PAGES[url])
    fetch_page.asked = asked
    return fetch_page


def selangor(fail=()):
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


class FakeStore:
    def __init__(self, stored_ids=None, refuse_id_columns=False):
        self.calls, self.stored_ids, self.refuse = [], stored_ids, refuse_id_columns

    def insert(self, table, rows, conflict_cols, update_existing=False):
        if self.refuse and table == "jps_stations" and any("jps_wl_id" in r for r in rows):
            raise RuntimeError("Supabase refused jps_stations rows: HTTP 400 Could not find the 'jps_rf_id' column")
        self.calls.append((table, rows, conflict_cols, update_existing))
        return len(rows)

    def select(self, table, params):
        if self.stored_ids is None:
            raise RuntimeError("HTTP 400")
        return self.stored_ids

    def rows(self, table):
        return [r for t, rows, *_ in self.calls if t == table for r in rows]


# LG6 national pages
def test_river_page_reads_columns_by_label_and_times_without_seconds():
    rows = {s["code"]: s for s in pib.river_stations(page("pib_sel_wl.html"))}
    assert set(rows) == {"3516423", "3014495", "3015432"}
    tsm = rows["3015432"]
    assert tsm["name"] == "Sg. Klang di Taman Sri Muda" and tsm["district"] == "KLANG"
    assert (tsm["level"], tsm["normal"], tsm["alert"], tsm["warning"], tsm["danger"]) == (1.21, 2.8, 4.4, 4.7, 5.0)
    assert (tsm["lat"], tsm["lon"]) == (None, None)
    assert jps.parse_time(tsm["time"]) == "2026-11-17T07:00:00Z"


def test_melaka_river_page_names_dashes_and_bad_times():
    rows = {s["code"]: s for s in pib.river_stations(page("pib_mlk_wl.html"))}
    assert set(rows) == {"0290211WL", "0300061WL"}  # the barrage row has no time: skipped
    assert rows["0290211WL"]["name"] == "Sg. Melaka di Melaka Pindah"  # same name as the Melaka site
    assert rows["0290211WL"]["district"] == "ALOR GAJAH" and rows["0290211WL"]["basin"] == "Sungai Melaka"
    katil = rows["0300061WL"]
    assert katil["name"] == "Sg. Duyong di Bukit Katil" and katil["level"] == 1.54
    assert katil["normal"] is None and katil["danger"] is None  # "-" is no threshold


def test_rain_page_rows_without_opening_tr():
    rows = {s["code"]: s for s in pib.rain_stations(page("pib_mlk_rf.html"))}
    assert set(rows) == {"0290211RF", "0270601RF"}
    assert rows["0290211RF"]["today"] == 15.0 and rows["0290211RF"]["hourly"] == 4.5
    assert rows["0270601RF"]["hourly"] is None and rows["0270601RF"]["today"] == 0.0
    sel = {s["code"]: s for s in pib.rain_stations(page("pib_sel_rf.html"))}
    assert sel["3015084"]["today"] == 34.0 and sel["3015084"]["district"] == "KLANG"


def test_empty_or_strange_page_gives_no_rows():
    for parse in (pib.river_stations, pib.rain_stations):
        assert parse("") == []
        assert parse("<html><body>Access denied</body></html>") == []
        assert parse("<table><tr><td>1</td></tr></table>") == []


def test_parse_time_with_and_without_seconds():
    assert jps.parse_time("17/11/2026 15:00") == jps.parse_time("17/11/2026 15:00:00") == "2026-11-17T07:00:00Z"
    assert jps.parse_time("-") is None


def test_selangor_station_rows_keep_the_national_ids():
    rows = {r["station_code"]: r for r in jps.station_rows(
        [load("wl_district_6.json")], [load("rf_district_6.json")],
        load("wl_station_list.json"), load("rf_station_list.json"), NOW)}
    assert (rows["BKLG0002L"]["jps_wl_id"], rows["BKLG0002L"]["jps_rf_id"]) == ("3015432", "3015084")
    assert rows["BKLG0016L"]["jps_wl_id"] is None and rows["BKLG0016L"]["jps_rf_id"] == "2915117"


# LG7 switching sources
def test_melaka_reads_the_site_first_and_publicinfobanjir_adds_its_extra_stations():
    store, msgs, fp = FakeStore(), [], pages()
    assert collect.run(selangor(), store, NOW, msgs.append, fetch_page=fp) == 0
    assert fp.asked.index(melaka.RIVER_URL) < fp.asked.index(pib.river_url("Melaka"))  # both, site first
    assert pib.river_url("Selangor") not in fp.asked  # Selangor feed was complete
    rows = {r["station_code"]: r for r in store.rows("jps_stations") if r["state"] == "Melaka"}
    assert rows["0290211WL"]["lat"] == 2.37349  # the site's station, with its position
    assert "lat" not in rows["0300061WL"]  # only on publicinfobanjir: added, stored position kept
    levels = {(r["station_code"], r["observed_at"]): r["level_m"] for r in store.rows("jps_river_levels")}
    assert levels[("0290211WL", "2026-11-17T07:00:00Z")] == 12.24  # same station and time: the site wins
    assert levels[("0300061WL", "2026-11-17T07:00:00Z")] == 1.54
    assert "Melaka river level: melaka-site (2) + publicinfobanjir (2)" in msgs
    assert "0 problems" in msgs[-1]


def test_a_renamed_melaka_station_keeps_the_melaka_site_code():
    renamed = page("pib_mlk_wl.html").replace("0300061WL", "0290161WL")  # = 2322415 on the Melaka site

    def fp(url):
        return renamed if url == pib.river_url("Melaka") else pages()(url)
    store = FakeStore()
    collect.run(selangor(), store, NOW, lambda m: None, fetch_page=fp)
    codes = {r["station_code"] for r in store.rows("jps_river_levels")}
    assert "2322415" in codes and "0290161WL" not in codes
    # no duplicate station row is made for it
    assert not [r for r in store.rows("jps_stations") if r["station_code"] in ("0290161WL", "2322415")]


def test_renamed_codes_point_at_melaka_codes():
    assert set(collect.MELAKA_CODES) == {"0270231WL", "0290161WL", "0290221WL", "0290301RF"}
    assert len(set(collect.MELAKA_CODES.values())) == 4


def test_melaka_site_fills_in_when_publicinfobanjir_fails():
    store, msgs = FakeStore(), []
    assert collect.run(selangor(), store, NOW, msgs.append, fetch_page=pages(down=("publicinfobanjir",))) == 0
    melaka_rows = [r for r in store.rows("jps_stations") if r["state"] == "Melaka"]
    assert melaka_rows and all("lat" in r for r in melaka_rows)  # positions from the Melaka site
    assert any(m.startswith("::warning::") and "Melaka river level page (publicinfobanjir)" in m for m in msgs)
    assert "Melaka river level: melaka-site (2)" in msgs


def test_selangor_feed_down_uses_publicinfobanjir_with_stored_ids():
    stored = [{"station_code": "BKLG0002L", "jps_wl_id": "3015432", "jps_rf_id": "3015084"},
              {"station_code": "BKLG0028L", "jps_wl_id": "3014495", "jps_rf_id": None}]
    store, msgs = FakeStore(stored_ids=stored), []
    assert collect.run(selangor(fail=("Station",)), store, NOW, msgs.append, fetch_page=pages()) == 0
    levels = {r["station_code"]: r["level_m"] for r in store.rows("jps_river_levels")}
    assert levels["BKLG0002L"] == 1.21 and levels["BKLG0028L"] == 3.10
    assert "3516423" not in levels  # no matching Selangor code: skipped, not guessed
    assert {r["station_code"] for r in store.rows("jps_rainfall")} >= {"BKLG0002L"}
    # Selangor station details (names, positions) are not replaced by the national page's
    assert not [r for r in store.rows("jps_stations") if r["state"] == "Selangor"]
    assert any(m.startswith("Selangor river level: publicinfobanjir (2, 1 unmatched") for m in msgs)


def test_one_failing_district_is_filled_from_publicinfobanjir_using_this_runs_ids():
    store, msgs = FakeStore(stored_ids=[]), []
    assert collect.run(selangor(fail=("GetWLAllStationData/3",)), store, NOW, msgs.append, fetch_page=pages()) == 0
    levels = {(r["station_code"], r["observed_at"]): r["level_m"] for r in store.rows("jps_river_levels")}
    assert levels[("BKLG0002L", "2026-11-17T06:45:00Z")] == 1.55  # from the Selangor feed
    assert levels[("BKLG0002L", "2026-11-17T07:00:00Z")] == 1.21  # newer one from publicinfobanjir
    assert levels[("BKLG0028L", "2026-11-17T07:00:00Z")] == 3.10  # offline in the feed, read nationally
    assert any(m.startswith("Selangor river level: selangor-api (2) + publicinfobanjir") for m in msgs)


def test_every_source_down_still_fails_the_run():
    msgs = []
    assert collect.run(selangor(fail=("Station",)), FakeStore(), NOW, msgs.append,
                       fetch_page=pages(down=("http",))) == 1
    assert msgs[-1].startswith("::error::")


def test_unreadable_stored_ids_is_a_warning():
    store, msgs = FakeStore(stored_ids=None), []
    assert collect.run(selangor(fail=("Station",)), store, NOW, msgs.append, fetch_page=pages()) == 0
    assert any("stored Selangor station ids" in m for m in msgs)


def test_sources_can_be_swapped():
    fp = pages()
    collect.run(selangor(), FakeStore(), NOW, lambda m: None, fetch_page=fp,
                sources={"Selangor": ("publicinfobanjir", "selangor-api")})
    assert fp.asked[0] == pib.river_url("Selangor")


def test_station_rows_sent_without_id_columns_before_the_sql_is_run():
    store, msgs = FakeStore(refuse_id_columns=True), []
    assert collect.run(selangor(), store, NOW, msgs.append, fetch_page=pages()) == 0
    sel = [r for r in store.rows("jps_stations") if r["state"] == "Selangor"]
    assert sel and all("jps_wl_id" not in r for r in sel)
    assert any("supabase/sources.sql" in m for m in msgs)


def test_rain_and_river_rows_of_one_station_are_merged():
    store = FakeStore()
    collect.run(selangor(), store, NOW, lambda m: None)
    rows = [r for r in store.rows("jps_stations") if r["station_code"] == "BKLG0002L"]
    assert len(rows) == 1 and rows[0]["has_river_level"] and rows[0]["has_rainfall"]
    assert rows[0]["wl_alert"] == 4.4 and rows[0]["jps_rf_id"] == "3015084"
