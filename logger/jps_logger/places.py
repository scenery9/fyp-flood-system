"""Relief centres and resource points: places/*.csv -> Supabase.

    python -m jps_logger.places check    (reads the files only; no keys needed)
    python -m jps_logger.places upload   (needs SUPABASE_URL and SUPABASE_SECRET_KEY)

One row per place. To add a place, add a row; to remove one, delete its row; to
change one, edit its row. "upload" then makes Supabase match the files:
  * rows are matched by "code" (keep a place's code the same when editing it);
  * a code no longer in the file is removed from Supabase, except when staff
    still have people recorded there (that is reported, nothing else changes);
  * occupancy and open/closed are never touched (staff set those);
  * places added by staff in the app (no code) are never touched.
GitHub Actions runs "upload" whenever places/ changes (.github/workflows/places.yml).
"""
import argparse
import csv
import re
import sys
from pathlib import Path

PLACES_DIR = Path(__file__).resolve().parents[2] / "places"
CODE = re.compile(r"^[A-Z0-9][A-Z0-9-]{1,39}$")
DISTRICTS = {
    "Selangor": {"GOMBAK", "HULU LANGAT", "HULU SELANGOR", "KLANG", "KUALA LANGAT",
                 "KUALA SELANGOR", "PETALING", "SABAK BERNAM", "SEPANG"},
    "Melaka": {"ALOR GAJAH", "JASIN", "MELAKA TENGAH"},
}
# Rough box around each state: a position outside it is a typo (or a geocoder's guess).
BOXES = {"Selangor": (2.55, 3.95, 100.75, 102.0), "Melaka": (1.95, 2.65, 101.95, 102.65)}
YES, NO = {"yes", "y", "true", "1"}, {"no", "n", "false", "0", ""}
CENTRE_COLS = ["code", "name", "state", "district", "lat", "lon", "capacity", "capacity_is_estimate",
               "location_checked", "resource_point_code", "notes"]
POINT_COLS = ["code", "name", "state", "district", "lat", "lon", "notes"]


class PlacesError(ValueError):
    """Every problem found in the files, one per line."""


def _read(path, columns):
    with open(path, newline="", encoding="utf-8-sig") as f:
        reader = csv.DictReader(f)
        missing = [c for c in columns if c not in (reader.fieldnames or [])]
        if missing:
            raise PlacesError(f"{path.name}: missing column(s) {', '.join(missing)}")
        return [(i, {k: (v or "").strip() for k, v in row.items() if k}) for i, row in enumerate(reader, start=2)]


def _common(name, line, row, problems, codes, names):
    where = f"{name} line {line}"
    code, title = row["code"], row["name"]
    if not CODE.match(code):
        problems.append(f"{where}: code '{code}' must be 2-40 capital letters, digits or '-'")
    elif code in codes:
        problems.append(f"{where}: code {code} is used twice")
    codes.add(code)
    if not title:
        problems.append(f"{where}: name is empty")
    elif title.lower() in names:
        problems.append(f"{where}: name '{title}' is used twice")
    names.add(title.lower())
    state = row["state"]
    district = " ".join(row["district"].upper().split())
    if state not in DISTRICTS:
        problems.append(f"{where}: state must be Selangor or Melaka, not '{state}'")
    elif district not in DISTRICTS[state]:
        problems.append(f"{where}: '{row['district']}' is not a {state} district "
                        f"({', '.join(sorted(DISTRICTS[state]))})")
    try:
        lat, lon = float(row["lat"]), float(row["lon"])
    except ValueError:
        problems.append(f"{where}: lat and lon must be numbers")
        lat = lon = None
    else:
        box = BOXES.get(state)
        if box and not (box[0] <= lat <= box[1] and box[2] <= lon <= box[3]):
            problems.append(f"{where}: {lat}, {lon} is not in {state} (lat and lon swapped?)")
    return {"code": code, "name": title, "district": district, "lat": lat, "lon": lon}


def _yes(where, column, value, problems):
    v = value.lower()
    if v in YES:
        return True
    if v in NO:
        return False
    problems.append(f"{where}: {column} must be yes or no, not '{value}'")
    return False


def load(folder=PLACES_DIR):
    """Checked rows: (resource points, centres). Raises PlacesError listing every problem."""
    folder = Path(folder)
    problems, points, centres = [], [], []
    point_rows = _read(folder / "resource_points.csv", POINT_COLS)
    centre_rows = _read(folder / "centres.csv", CENTRE_COLS)
    codes, names = set(), set()
    for line, row in point_rows:
        points.append(_common("resource_points.csv", line, row, problems, codes, names))
    point_codes = {p["code"] for p in points}
    codes, names = set(), set()
    for line, row in centre_rows:
        where = f"centres.csv line {line}"
        c = _common("centres.csv", line, row, problems, codes, names)
        try:
            c["capacity"] = int(row["capacity"])
            if c["capacity"] <= 0:
                raise ValueError
        except ValueError:
            problems.append(f"{where}: capacity must be a whole number above 0 (a guess is fine: "
                            "then put yes under capacity_is_estimate)")
        c["capacity_estimated"] = _yes(where, "capacity_is_estimate", row["capacity_is_estimate"], problems)
        c["location_checked"] = _yes(where, "location_checked", row["location_checked"], problems)
        rp = row["resource_point_code"]
        if rp and rp not in point_codes:
            problems.append(f"{where}: resource_point_code {rp} is not in resource_points.csv")
        c["resource_point_code"] = rp or None
        centres.append(c)
    if problems:
        raise PlacesError("\n".join(problems))
    return points, centres


def upload(store, points, centres, out=print):
    """Makes Supabase match the files. Returns the number of problems (0 = all done)."""
    store.insert("resource_points", points, ["code"], update_existing=True)
    ids = {r["code"]: r["id"] for r in store.select("resource_points", [("select", "id,code"), ("code", "not.is.null")])}
    rows = []
    for c in centres:
        row = {k: v for k, v in c.items() if k != "resource_point_code"}
        row["resource_point_id"] = ids.get(c["resource_point_code"]) if c["resource_point_code"] else None
        rows.append(row)
    store.insert("evacuation_points", rows, ["code"], update_existing=True)
    problems = 0
    for table, keep in (("evacuation_points", {c["code"] for c in centres}),
                        ("resource_points", {p["code"] for p in points})):
        stored = {r["code"] for r in store.select(table, [("select", "code"), ("code", "not.is.null")])}
        for code in sorted(stored - keep):
            try:
                store.delete(table, [("code", f"eq.{code}")])
                out(f"Removed {code} from {table}")
            except RuntimeError as e:
                problems += 1
                out(f"::warning::Could not remove {code} from {table} (still in use?): {e}")
    out(f"Places in Supabase now match the files: {len(centres)} centres, {len(points)} resource points"
        f"{f' ({problems} could not be removed)' if problems else ''}")
    return problems


def main():
    p = argparse.ArgumentParser()
    p.add_argument("action", choices=["check", "upload"])
    p.add_argument("--folder", default=str(PLACES_DIR))
    a = p.parse_args()
    try:
        points, centres = load(a.folder)
    except PlacesError as e:
        for line in str(e).splitlines():
            print(f"::error::{line}")
        sys.exit(1)
    print(f"Files are fine: {len(centres)} centres, {len(points)} resource points")
    if a.action == "upload":
        from .store import Store
        sys.exit(1 if upload(Store(), points, centres) else 0)


if __name__ == "__main__":
    main()
