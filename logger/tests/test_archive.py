import gzip
from datetime import date, datetime, timezone

import pandas as pd
import pytest

from jps_logger import archive
from jps_logger.archive import archive_path, day_bounds, read_archive, write_day


class FakeStore:
    """Holds readings like Supabase: per table, a list of dicts with observed_at (UTC ISO)."""

    def __init__(self, levels=(), rain=(), mb=50.0):
        self.tables = {"jps_river_levels": list(levels), "jps_rainfall": list(rain)}
        self.deleted, self.mb = [], mb

    def first_time(self, table):
        times = sorted(r["observed_at"] for r in self.tables[table])
        return times[0] if times else None

    def select_all(self, table, columns, filters):
        start = next(v[4:] for k, v in filters if v.startswith("gte."))
        end = next(v[3:] for k, v in filters if v.startswith("lt."))
        return [r for r in self.tables[table] if start <= r["observed_at"] < end]

    def delete_between(self, table, start, end):
        self.deleted.append((table, start, end))
        self.tables[table] = [r for r in self.tables[table] if not start <= r["observed_at"] < end]

    def storage_mb(self):
        return self.mb


def lvl(code, t, v):
    return {"station_code": code, "observed_at": t, "level_m": v}


def rn(code, t, today):
    return {"station_code": code, "observed_at": t, "hourly_mm": 1.0, "today_mm": today}


TODAY = date(2026, 11, 20)  # Malaysia date


# AR1 days and files
def test_a_day_is_a_malaysia_day_in_utc():
    assert day_bounds(date(2026, 11, 17)) == ("2026-11-16T16:00:00Z", "2026-11-17T16:00:00Z")
    assert archive.today_myt(datetime(2026, 11, 17, 16, 30, tzinfo=timezone.utc)) == date(2026, 11, 18)


def test_file_path(tmp_path):
    assert archive_path(tmp_path, date(2026, 11, 7)) == tmp_path / "2026" / "11" / "2026-11-07.csv.gz"


def test_written_day_reads_back_and_is_identical_every_time(tmp_path):
    p = archive_path(tmp_path, date(2026, 11, 17))
    levels = [lvl("B", "2026-11-17T01:00:00+00:00", 2.5), lvl("A", "2026-11-17T01:00:00Z", 1.5)]
    rain = [rn("A", "2026-11-17T01:00:00Z", 3.0)]
    assert write_day(p, levels, rain) == 3
    first = p.read_bytes()
    write_day(p, list(reversed(levels)), rain)
    assert p.read_bytes() == first  # same content, same bytes: no pointless git changes
    df = pd.read_csv(gzip.open(p))
    assert list(df.columns) == archive.COLUMNS
    assert list(df["station_code"]) == ["A", "B", "A"] and df["observed_at"].iloc[1] == "2026-11-17T01:00:00Z"


def test_empty_day_still_gets_a_file(tmp_path):
    p = archive_path(tmp_path, date(2026, 11, 17))
    assert write_day(p, [], []) == 0
    assert p.exists() and read_archive(tmp_path, date(2026, 11, 1)) == ([], [])


# AR2 archiving
def test_archives_finished_days_only_and_catches_up(tmp_path):
    store = FakeStore(
        levels=[lvl("A", "2026-11-16T17:00:00Z", 1.0),   # 17 Nov MYT
                lvl("A", "2026-11-17T17:00:00Z", 1.1),   # 18 Nov MYT
                lvl("A", "2026-11-18T17:00:00Z", 1.2),   # 19 Nov MYT: not two days old yet
                lvl("A", "2026-11-19T17:00:00Z", 1.3)],  # 20 Nov MYT: today
        rain=[rn("A", "2026-11-16T17:00:00Z", 5.0)])
    msgs = []
    archive.run_archive(store, tmp_path, TODAY, msgs.append)
    files = sorted(p.name for p in tmp_path.rglob("*.csv.gz"))
    assert files == ["2026-11-17.csv.gz", "2026-11-18.csv.gz"]
    assert "2 day(s) archived" in msgs[-1]
    archive.run_archive(store, tmp_path, TODAY, msgs.append)
    assert "0 day(s) archived" in msgs[-1]  # already done: nothing rewritten


def test_day_boundaries_put_each_reading_in_its_malaysia_day(tmp_path):
    store = FakeStore(levels=[lvl("A", "2026-11-16T15:59:00Z", 1.0),   # 16 Nov 23:59 MYT
                              lvl("A", "2026-11-16T16:00:00Z", 2.0)])  # 17 Nov 00:00 MYT
    archive.run_archive(store, tmp_path, TODAY, lambda m: None)
    d16 = pd.read_csv(gzip.open(archive_path(tmp_path, date(2026, 11, 16))))
    d17 = pd.read_csv(gzip.open(archive_path(tmp_path, date(2026, 11, 17))))
    assert list(d16["level_m"]) == [1.0] and list(d17["level_m"]) == [2.0]


def test_nothing_stored_yet(tmp_path):
    msgs = []
    archive.run_archive(FakeStore(), tmp_path, TODAY, msgs.append)
    archive.run_cleanup(FakeStore(), tmp_path, TODAY, msgs.append)
    assert "0 day(s) archived" in msgs[0] and "Nothing stored yet" in msgs[1]


# AR3 cleanup
def test_cleanup_deletes_only_archived_days_older_than_30_days(tmp_path):
    old_archived, old_missing = date(2026, 10, 1), date(2026, 10, 2)
    recent = date(2026, 11, 1)  # 19 days ago: kept
    store = FakeStore(levels=[lvl("A", day_bounds(d)[0], 1.0) for d in (old_archived, old_missing, recent)])
    for d in (old_archived, recent):
        write_day(archive_path(tmp_path, d), [], [])
    msgs = []
    archive.run_cleanup(store, tmp_path, TODAY, msgs.append)
    assert {(t, s) for t, s, _ in store.deleted} == {("jps_river_levels", day_bounds(old_archived)[0]),
                                                     ("jps_rainfall", day_bounds(old_archived)[0])}
    assert any("2026-10-02" in m and m.startswith("::warning::") for m in msgs)
    left = {r["observed_at"] for r in store.tables["jps_river_levels"]}
    assert left == {day_bounds(old_missing)[0], day_bounds(recent)[0]}


def test_exactly_30_days_are_kept(tmp_path):
    keep_from = date(2026, 10, 21)  # TODAY minus 30 days
    days = [date(2026, 10, 20), keep_from]
    store = FakeStore(levels=[lvl("A", day_bounds(d)[0], 1.0) for d in days])
    for d in days:
        write_day(archive_path(tmp_path, d), [], [])
    archive.run_cleanup(store, tmp_path, TODAY, lambda m: None)
    assert [s for _, s, _ in store.deleted] == [day_bounds(date(2026, 10, 20))[0]] * 2


# AR4 size check
@pytest.mark.parametrize("mb,code,start", [(120, 0, "Supabase"), (320, 0, "::warning::"), (410, 1, "::error::")])
def test_size_check(mb, code, start):
    msgs = []
    assert archive.check_size(FakeStore(mb=mb), msgs.append) == code
    assert msgs[0].startswith(start)


# AR5 export combines archive and database
def test_read_archive_from_a_date(tmp_path):
    write_day(archive_path(tmp_path, date(2026, 11, 16)), [lvl("A", "2026-11-16T01:00:00Z", 1.0)], [])
    write_day(archive_path(tmp_path, date(2026, 11, 17)), [lvl("A", "2026-11-17T01:00:00Z", 2.0)],
              [rn("A", "2026-11-17T01:00:00Z", 4.0)])
    levels, rain = read_archive(tmp_path, date(2026, 11, 17))
    assert [r["level_m"] for r in levels] == [2.0] and [r["today_mm"] for r in rain] == [4.0]


def test_same_reading_in_archive_and_database_is_counted_once():
    from jps_logger.export import to_model_csv
    a = lvl("A", "2026-11-17T01:00:00Z", 2.0)
    b = lvl("A", "2026-11-17T01:00:00+00:00", 2.0)
    r1, r2 = rn("A", "2026-11-17T00:45:00Z", 1.0), rn("A", "2026-11-17T01:00:00Z", 3.0)
    df = to_model_csv([a, b], [r1, r2, dict(r2)])
    assert len(df) == 2 and df["rainfall_mm"].iloc[1] == 2.0


def test_export_from_archive_only_needs_no_key(tmp_path, monkeypatch):
    import sys
    from jps_logger import export
    for v in ("SUPABASE_URL", "SUPABASE_SECRET_KEY", "SUPABASE_PUBLISHABLE_KEY"):
        monkeypatch.delenv(v, raising=False)
    data = tmp_path / "data"
    write_day(archive_path(data, date(2026, 11, 17)),
              [lvl("BKLG0002L", "2026-11-17T01:00:00Z", 1.5), lvl("OTHER", "2026-11-17T01:00:00Z", 9.0)], [])
    write_day(archive_path(data, date(2026, 11, 10)), [lvl("BKLG0002L", "2026-11-10T01:00:00Z", 1.0)], [])
    klang = tmp_path / "s.json"
    klang.write_text('[{"id": "BKLG0002L", "normal": 1, "alert": 2, "warning": 3, "danger": 4}]')
    out = tmp_path / "r.csv"
    monkeypatch.setattr(sys, "argv", ["export", "--since", "2026-11-17", "--no-database", "--data", str(data),
                                      "--stations", str(klang), "--out", str(out)])
    export.main()
    df = pd.read_csv(out)
    assert list(df["station_id"]) == ["BKLG0002L"] and list(df["river_level_m"]) == [1.5]


# AR6 Supabase calls used by the archive
class Resp:
    def __init__(self, status=200, body=None):
        self.status_code, self._b, self.text = status, body, ""

    def json(self):
        return self._b


class Http:
    def __init__(self, body=None, status=200):
        self.calls, self.body, self.status = [], body, status

    def get(self, url, params, headers, timeout):
        self.calls.append(("get", url, params, headers))
        return Resp(self.status, self.body)

    def delete(self, url, params, headers, timeout):
        self.calls.append(("delete", url, params, headers))
        return Resp(204 if self.status == 200 else self.status)

    def post(self, url, headers, json, timeout):
        self.calls.append(("post", url, None, headers))
        return Resp(self.status, self.body)


def test_store_delete_first_time_and_size():
    from jps_logger.store import Store
    h = Http(body=[])
    s = Store("https://x.supabase.co", "sb_secret_k", session=h)
    assert s.first_time("jps_rainfall") is None
    s.delete_between("jps_rainfall", "2026-10-01T16:00:00Z", "2026-10-02T16:00:00Z")
    kind, url, params, headers = h.calls[-1]
    assert kind == "delete" and url.endswith("/rest/v1/jps_rainfall")
    assert params == [("observed_at", "gte.2026-10-01T16:00:00Z"), ("observed_at", "lt.2026-10-02T16:00:00Z")]
    assert "Authorization" not in headers
    h.body = 123.4
    assert s.storage_mb() == 123.4 and h.calls[-1][1].endswith("/rest/v1/rpc/jps_storage_mb")
    with pytest.raises(RuntimeError):
        Store("https://x.supabase.co", "k", session=Http(status=500)).delete_between("t", "a", "b")
