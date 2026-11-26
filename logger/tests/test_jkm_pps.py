import shutil
from pathlib import Path

from jps_logger import jkm_pps, places

from conftest import FIX, load

PLACES = Path(__file__).resolve().parents[2] / "places"


def point(**kw):
    p = {"id": 1, "name": "DEWAN ORANG RAMAI X", "latti": 2.8588841, "longi": 101.6782621, "negeri": "Selangor",
         "daerah": "Sepang", "mukim": "Dengkil", "bencana": "Banjir", "mangsa": 51, "keluarga": 16, "kapasiti": 25.5}
    p.update(kw)
    return p


class Resp:
    def __init__(self, body):
        self.content = body.encode()

    def raise_for_status(self):
        pass

    def json(self):
        import json
        return json.loads(self.content)


# LG9 JKM relief centres (PPS)
def test_capacity_from_percentage_full():
    assert jkm_pps.capacity_of(point(mangsa=166, kapasiti=207.50000000000003)) == (80, False)
    assert jkm_pps.capacity_of(point(mangsa=781, kapasiti=97.625)) == (800, False)
    assert jkm_pps.capacity_of(point(mangsa=0, kapasiti=0)) == (jkm_pps.DEFAULT_CAPACITY, True)
    assert jkm_pps.capacity_of(point(mangsa=None, kapasiti="x")) == (jkm_pps.DEFAULT_CAPACITY, True)


def test_names_tidied_and_abbreviations_kept():
    assert jkm_pps.tidy_name("SEKOLAH KEBANGSAAN DATO\\' MAHARAJA LELA") == "Sekolah Kebangsaan Dato' Maharaja Lela"
    assert jkm_pps.tidy_name("SK RTB BUKIT CHANGGANG") == "SK RTB Bukit Changgang"
    assert jkm_pps.tidy_name("BALAI RAYA KG  SUNGAI KELAMBU") == "Balai Raya Kg Sungai Kelambu"


def test_row_from_point():
    row, why = jkm_pps.to_row(point(), "Selangor")
    assert why is None
    assert row["code"] == "PPS-JKM-1" and row["district"] == "SEPANG"
    assert (row["capacity"], row["capacity_is_estimate"], row["location_checked"]) == ("200", "no", "yes")
    rough, _ = jkm_pps.to_row(point(latti=3.31, longi=101.40156), "Selangor")
    assert rough["location_checked"] == "no"  # 2 decimals is about 1 km
    assert jkm_pps.to_row(point(latti=5.9, longi=116.0), "Selangor")[0] is None  # outside the state
    assert jkm_pps.to_row(point(daerah="Kuantan"), "Selangor")[0] is None
    assert jkm_pps.to_row(point(name="  "), "Selangor")[0] is None


def test_merge_adds_keeps_and_never_touches_other_rows():
    other = {c: "" for c in places.CENTRE_COLS}
    other.update(code="PPS-SGR-SMK-P-KAPAR", name="SMK (P) Kapar", state="Selangor", district="KLANG",
                 lat="3.135347", lon="101.380869", capacity="250", capacity_is_estimate="yes", location_checked="yes")
    rows, msgs = jkm_pps.merge([other], {"Selangor": [point(), point(id=2, name="SMK (P) KAPAR")], "Melaka": []})
    assert rows[0] == other
    assert [r["code"] for r in rows] == ["PPS-SGR-SMK-P-KAPAR", "PPS-JKM-1"]
    assert any("already used by PPS-SGR-SMK-P-KAPAR" in m for m in msgs)
    # closed later (not listed any more): kept; opened again with no evacuees: known capacity kept
    rows2, _ = jkm_pps.merge(rows, {"Selangor": [], "Melaka": []})
    assert rows2 == rows
    rows3, _ = jkm_pps.merge(rows, {"Selangor": [point(mangsa=0, kapasiti=0, name="DEWAN ORANG RAMAI X BARU")]})
    jkm = rows3[1]
    assert (jkm["capacity"], jkm["capacity_is_estimate"], jkm["name"]) == ("200", "no", "Dewan Orang Ramai X Baru")
    assert "capacity not given" not in jkm["notes"]


def test_real_jkm_response_gives_valid_places_file(tmp_path):
    for name in ("centres.csv", "resource_points.csv"):
        shutil.copy(PLACES / name, tmp_path / name)
    pts = load("jkm_pusat_buka_selangor.json")["points"]
    rows, msgs = jkm_pps.merge(jkm_pps.read_rows(tmp_path / "centres.csv"), {"Selangor": pts, "Melaka": []})
    jkm_pps.write_rows(tmp_path / "centres.csv", rows)
    _, centres = places.load(tmp_path)  # passes the same checks as the upload
    jkm = [c for c in centres if c["code"].startswith("PPS-JKM-")]
    assert len(jkm) == len(pts) == 8
    assert {c["capacity"] for c in jkm} == {80, 200, 50, 100, 250, 800}


def test_fetch_reads_points_and_empty_answers():
    body = (FIX / "jkm_pusat_buka_selangor.json").read_text()
    seen = {}

    def get(url, params):
        seen.update(params)
        return Resp(body)
    assert len(jkm_pps.fetch_points("Selangor", get)) == 8
    assert seen == {"a": 10, "b": 0}
    assert jkm_pps.fetch_points("Melaka", lambda u, p: Resp("[]")) == []
    assert jkm_pps.fetch_points("Melaka", lambda u, p: Resp("")) == []
