import shutil

import pytest

from jps_logger import places
from jps_logger.store import Store


# PL7 the real files in places/ are always valid (this runs on every push)
def test_the_files_in_the_repository_are_valid():
    points, centres = places.load()
    assert centres and points
    assert all(c["location_checked"] for c in centres)  # the five from the FloodWatch app
    assert {c["district"] for c in centres} >= {"KLANG", "MELAKA TENGAH"}


@pytest.fixture
def folder(tmp_path):
    shutil.copy(places.PLACES_DIR / "centres.csv", tmp_path)
    shutil.copy(places.PLACES_DIR / "resource_points.csv", tmp_path)
    return tmp_path


def write(folder, name, text):
    (folder / name).write_text(text, encoding="utf-8")


HEAD = "code,name,state,district,lat,lon,capacity,capacity_is_estimate,location_checked,resource_point_code,notes\n"


# PL8 mistakes in the files are found before anything is uploaded
def test_adding_a_row_is_all_it_takes(folder):
    with open(folder / "centres.csv", "a", encoding="utf-8") as f:
        f.write("PPS-SGR-NEW,Dewan Baru,Selangor,petaling,3.07,101.52,120,no,no,DEMO-SGR-KLANG-DEPOT,\n")
    _, centres = places.load(folder)
    new = centres[-1]
    assert new["district"] == "PETALING"  # any letter case is fine
    assert new["capacity_estimated"] is False and new["location_checked"] is False
    assert new["resource_point_code"] == "DEMO-SGR-KLANG-DEPOT"


def test_every_problem_is_listed_with_its_line(folder):
    write(folder, "centres.csv", HEAD +
          "PPS-A,Hall,Selangor,KLANG,3.1,101.4,100,yes,yes,,\n"
          "PPS-A,Hall,Selangor,SEGAMAT,101.4,3.1,0,maybe,yes,NOPE,\n"
          "bad code,,Johor,X,abc,1,10,no,no,,\n")
    with pytest.raises(places.PlacesError) as e:
        places.load(folder)
    msg = str(e.value)
    for expected in ("line 3: code PPS-A is used twice", "line 3: name 'Hall' is used twice",
                     "'SEGAMAT' is not a Selangor district", "line 3: capacity", "capacity_is_estimate must be yes or no",
                     "resource_point_code NOPE", "line 4: code 'bad code'", "line 4: name is empty",
                     "state must be Selangor or Melaka", "lat and lon must be numbers"):
        assert expected in msg


def test_swapped_or_far_away_positions_are_caught(folder):
    # the FloodWatch seed list had schools placed in Sabah by a geocoder
    write(folder, "centres.csv", HEAD + "PPS-B,SK Sungai Binjai,Selangor,KLANG,5.983671,116.18025,250,yes,no,,\n")
    with pytest.raises(places.PlacesError, match="not in Selangor"):
        places.load(folder)


def test_a_missing_column_is_named(folder):
    write(folder, "resource_points.csv", "code,name,state,district,lat\nX1,Y,Selangor,KLANG,3\n")
    with pytest.raises(places.PlacesError, match="missing column"):
        places.load(folder)


# PL9 upload makes Supabase match the files
class FakeStore:
    def __init__(self, stored_centres=(), stored_points=(), undeletable=()):
        self.inserts, self.deleted = [], []
        self.stored = {"evacuation_points": list(stored_centres), "resource_points": list(stored_points)}
        self.undeletable = set(undeletable)

    def insert(self, table, rows, conflict_cols, update_existing=False):
        self.inserts.append((table, rows, conflict_cols, update_existing))
        for r in rows:
            if r["code"] not in self.stored[table]:
                self.stored[table].append(r["code"])
        return len(rows)

    def select(self, table, params):
        if table == "resource_points" and ("select", "id,code") in params:
            return [{"id": f"id-{c}", "code": c} for c in self.stored[table]]
        return [{"code": c} for c in self.stored[table]]

    def delete(self, table, filters):
        code = dict(filters)["code"].removeprefix("eq.")
        if code in self.undeletable:
            raise RuntimeError("HTTP 400 Centre still has people recorded")
        self.deleted.append((table, code))


def test_upload_adds_updates_and_links_by_code():
    points, centres = places.load()
    centres[0]["resource_point_code"] = "DEMO-SGR-KLANG-DEPOT"
    store, msgs = FakeStore(), []
    assert places.upload(store, points, centres, msgs.append) == 0
    tables = [t[0] for t in store.inserts]
    assert tables == ["resource_points", "evacuation_points"]  # points first, so centres can link to them
    assert all(t[2] == ["code"] and t[3] is True for t in store.inserts)
    rows = store.inserts[1][1]
    assert rows[0]["resource_point_id"] == "id-DEMO-SGR-KLANG-DEPOT"
    assert "occupancy" not in rows[0] and "is_open" not in rows[0]  # staff own these
    assert len({tuple(sorted(r)) for r in rows}) == 1  # same keys in every row


def test_rows_removed_from_the_files_are_removed_from_supabase():
    points, centres = places.load()
    store = FakeStore(stored_centres=["PPS-OLD"], stored_points=["RP-OLD"])
    msgs = []
    assert places.upload(store, points, centres, msgs.append) == 0
    assert store.deleted == [("evacuation_points", "PPS-OLD"), ("resource_points", "RP-OLD")]


def test_a_centre_still_in_use_is_reported_not_forced():
    points, centres = places.load()
    store, msgs = FakeStore(stored_centres=["PPS-BUSY"], undeletable=["PPS-BUSY"]), []
    assert places.upload(store, points, centres, msgs.append) == 1
    assert any(m.startswith("::warning::Could not remove PPS-BUSY") for m in msgs)


def test_store_delete_needs_a_filter():
    with pytest.raises(ValueError):
        Store("https://x.supabase.co", "k", session=object()).delete("evacuation_points", [])
