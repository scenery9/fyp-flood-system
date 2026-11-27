"""JKR disaster portal (bencana.jkr.gov.my): incidents, privacy, nearby gauges, forecast points.
Fixture: two real records (Nov 2026) with the personal fields replaced by fake values."""
from datetime import datetime, timezone

import pandas as pd
import pytest

from conftest import load
from jps_logger import jkr

NOW = datetime(2026, 11, 27, 10, tzinfo=timezone.utc)
SEEN = NOW.strftime(jkr.FMT)


@pytest.fixture
def raw():
    return load("jkr_disasters.json")["data"]


def test_clean_keeps_the_incident_and_drops_personal_details(raw):
    rows = [jkr.clean(r, SEEN) for r in raw]
    flood = next(r for r in rows if r["incident_id"] == 10637)
    assert flood["type"] == "Flood" and flood["type_ms"] == "Banjir"
    assert flood["occurred_at"] == "2026-11-25T01:00:00Z"        # 09:00 Malaysia time
    assert (flood["lat"], flood["lon"]) == (2.814308, 101.65328)
    assert (flood["district"], flood["state"]) == ("Kuala Langat", "Selangor")
    assert flood["depth_m"] == 0.1 and flood["situation"] == "Water Rising"
    assert flood["road_status_code"] == "B3" and flood["remarks"] == "Ban Sungai Langat Pecah"
    for r in rows:
        assert set(r) == set(jkr.INCIDENT_COLUMNS)
        text = repr(r)
        assert "TEST REPORTER" not in text and "000-0000000" not in text


def test_fetch_reads_every_page():
    pages = {1: {"data": [{"id": 1}], "next_page_url": "x", "last_page": 2},
             2: {"data": [{"id": 2}], "next_page_url": None, "last_page": 2}}

    class Reply:
        def __init__(self, body):
            self.body = body

        def raise_for_status(self):
            pass

        def json(self):
            return self.body

    class Session:
        def get(self, url, params, headers, timeout):
            assert "fyp-flood-logger" in headers["User-Agent"]
            return Reply(pages[params["page"]])

    assert [r["id"] for r in jkr.fetch(Session())] == [1, 2]


def test_distance_and_nearest():
    assert jkr.distance_km(3.0, 101.0, 3.0, 101.0) == 0
    assert jkr.distance_km(3.0, 101.0, 3.1, 101.0) == pytest.approx(11.12, abs=0.05)
    inc = {"incident_id": 1, "seen_at": SEEN, "lat": 2.8143, "lon": 101.6533}
    gauges = [
        {"kind": "river", "code": "FAR", "lat": 3.5, "lon": 101.6},
        {"kind": "river", "code": "NEAR", "lat": 2.825, "lon": 101.655, "level_m": 3.92, "alert": 3.3},
        {"kind": "rain", "code": "R1", "lat": 2.82, "lon": 101.66, "today_mm": 4.5},
        {"kind": "river", "code": "NOPOS", "lat": None, "lon": None},
    ]
    assert [g["code"] for _, g in jkr.nearest(inc, gauges, "river")] == ["NEAR"]
    rows = jkr.gauge_rows([inc], gauges)
    assert [(r["kind"], r["station_code"], r["rank"]) for r in rows] == [("river", "NEAR", 1), ("rain", "R1", 1)]
    assert rows[0]["level_m"] == 3.92 and rows[0]["distance_km"] < 2


def test_incident_points_for_the_weather_forecast(raw):
    pts = jkr.incident_points([jkr.clean(r, SEEN) for r in raw])
    assert {p["id"] for p in pts} == {"JKR-10637", "JKR-10620"}
    assert all(p["lat"] and p["lon"] and p["state"] for p in pts)
    one = jkr.incident_points([{"incident_id": 5, "lat": 1.0, "lon": 2.0, "district": "Daerah Barat Daya",
                                "state": "Pulau Pinang", "type": "Flood"}])
    assert one[0]["district"] == "Barat Daya"


def test_collect_writes_incidents_and_gauges(raw, tmp_path, monkeypatch):
    monkeypatch.setattr(jkr, "fetch", lambda session=None: raw)
    monkeypatch.setattr(jkr, "live_gauges", lambda now, problems=None: [
        {"kind": "river", "code": "BKLT0001L", "name": "BUKIT CHANGGANG", "lat": 2.825, "lon": 101.655,
         "level_m": 3.92, "alert": 3.3, "warning": 3.8, "danger": 4.2}])
    msgs = []
    code, incidents = jkr.collect(NOW, files_root=tmp_path, out=msgs.append)
    assert code == 0 and len(incidents) == 2
    assert any("BKLT0001L" in m for m in msgs)
    inc = pd.concat(pd.read_csv(p) for p in (tmp_path / "jkr").rglob("*.csv.gz"))
    near = pd.concat(pd.read_csv(p) for p in (tmp_path / "jkr_gauges").rglob("*.csv.gz"))
    assert sorted(inc["incident_id"]) == [10620, 10637]
    assert near.iloc[0]["station_code"] == "BKLT0001L"
    assert "report_by" not in inc.columns and "phone_no" not in inc.columns


def test_collect_reports_a_portal_failure(monkeypatch):
    def down(session=None):
        raise TimeoutError("slow")
    monkeypatch.setattr(jkr, "fetch", down)
    msgs = []
    assert jkr.collect(NOW, out=msgs.append) == (1, [])
    assert msgs[0].startswith("::error::")


class FakeStore:
    """Supabase stand-in holding what one collect run would have stored."""
    def __init__(self, incidents, near):
        self.tables = {
            "jkr_incident": [{k: v for k, v in i.items() if k != "seen_at"} for i in incidents],
            "jkr_incident_seen": [{"incident_id": i["incident_id"], "seen_at": i["seen_at"],
                                   **{c: i[c] for c in jkr.SEEN_COLUMNS}} for i in incidents],
            "jkr_incident_gauges": near}

    def select(self, table, params):
        return sorted(self.tables[table], key=lambda r: r.get("seen_at") or "")[:1]

    def select_all(self, table, columns, filters, order=None):
        rows = self.tables[table]
        for col, cond in filters:
            op, val = cond.split(".", 1)
            rows = [r for r in rows if (r[col] >= val if op == "gte" else r[col] < val)]
        return rows


def test_archive_rebuilds_the_day_files_from_supabase(raw, tmp_path):
    incidents = [jkr.clean(r, SEEN) for r in raw]
    near = jkr.gauge_rows(incidents, [{"kind": "river", "code": "BKLT0001L", "lat": 2.825, "lon": 101.655}])
    today = datetime(2026, 11, 28).date()      # 27 Nov (Malaysia) is finished
    msgs = []
    assert jkr.run_archive(FakeStore(incidents, near), tmp_path, today, out=msgs.append) == 0
    day = tmp_path / "jkr" / "2026" / "11" / "2026-11-27.csv.gz"
    inc = pd.read_csv(day)
    assert sorted(inc["incident_id"]) == [10620, 10637]
    flood = inc[inc["incident_id"] == 10637].iloc[0]
    assert flood["district"] == "Kuala Langat" and flood["situation"] == "Water Rising"
    assert (tmp_path / "jkr_gauges" / "2026" / "11" / "2026-11-27.csv.gz").exists()
    assert msgs and "2 sightings" in msgs[0]
