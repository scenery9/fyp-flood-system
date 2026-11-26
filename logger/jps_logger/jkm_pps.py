"""Adds the relief centres (PPS) that JKM has opened to places/centres.csv.

    python -m jps_logger.jkm_pps            # read JKM InfoBencana and update places/centres.csv
    python -m jps_logger.jkm_pps --dry-run  # only show what would change

Source: the public map of JKM's InfoBencana portal (infobencanajkmv2.jkm.gov.my),
which lists every PPS that is open now, with JKM's name, position, number of
evacuees and how full it is. JKM's full register (about 1,170 PPS in Selangor) is
only in its staff system, so this reads the open ones each time it runs and keeps
them: a PPS that has opened once stays in the file after it closes. Run it during
the monsoon and the list grows with every centre JKM opens.

  * code: PPS-JKM-<JKM's id>, so a centre keeps one row however often it opens.
  * capacity: JKM gives "kapasiti" as a percentage full (its map colours it at
    40 and 80), so capacity = evacuees x 100 / kapasiti. When that cannot be worked
    out (no evacuees yet), DEFAULT_CAPACITY is used and marked as an estimate.
  * location_checked: yes when JKM's position is given to at least 4 decimals
    (about 10 m); JKM positions with fewer decimals get no in-app pin or route.
  * Rows without a JKM code (e.g. the FloodWatch centres) are never changed, and a
    JKM centre whose name is already in the file is skipped and reported.
After running, check with `python -m jps_logger.places check`, then commit and
push: the places workflow uploads the file to Supabase.
"""
import argparse
import csv
import io
import re

import requests

from .jps import HEADERS, TIMEOUT_S
from .places import BOXES, CENTRE_COLS, DISTRICTS, PLACES_DIR

URL = "https://infobencanajkmv2.jkm.gov.my/api/pusat-buka.php"
STATE_IDS = {"Selangor": 10, "Melaka": 4}  # InfoBencana's state numbers
DEFAULT_CAPACITY = 100
CODE_PREFIX = "PPS-JKM-"
# Kept in capitals when a JKM name is written in title case.
ABBREVIATIONS = {"SK", "SMK", "SRA", "SRK", "SJK", "SJKC", "SJKT", "SA", "SAR", "SRAI", "KAFA", "RTB", "PPR",
                 "MPAJ", "MPS", "MBSA", "MBPJ", "MBSJ", "MPK", "MDKS", "MDHS", "MDSB", "JKKK", "UKM", "UPM",
                 "UITM", "KRT", "PDRM", "JPS", "JKM", "II", "III", "IV"}
# Short forms of ordinary words: written like words ("Kg", not "KG").
SHORT_WORDS = {"KG", "SG", "TMN", "JLN", "BT", "BDR", "LRG", "PT", "SBK"}


def fetch_points(state, get=None):
    """JKM's open PPS in a state (a list of dicts from the public map)."""
    get = get or (lambda url, params: requests.get(url, params=params, headers=HEADERS, timeout=TIMEOUT_S))
    r = get(URL, {"a": STATE_IDS[state], "b": 0})
    r.raise_for_status()
    body = r.json() if r.content.strip() else None
    return (body or {}).get("points") or [] if isinstance(body, dict) else []


def tidy_name(name):
    """'SEKOLAH KEBANGSAAN DATO\\' MAHARAJA LELA' -> "Sekolah Kebangsaan Dato' Maharaja Lela"."""
    name = " ".join(name.replace("\\", "").split())
    words = []
    for w in name.split(" "):
        letters = re.sub(r"[^A-Za-z]", "", w).upper()
        keep = letters in ABBREVIATIONS or (letters not in SHORT_WORDS and letters
                                            and not re.search(r"[AEIOU]", letters) and len(letters) <= 4)
        words.append(w.upper() if keep else w[:1].upper() + w[1:].lower())
    return " ".join(words)


def capacity_of(point):
    """(capacity, is_estimate). kapasiti is the percentage full."""
    try:
        pct, people = float(point.get("kapasiti") or 0), float(point.get("mangsa") or 0)
    except (TypeError, ValueError):
        return DEFAULT_CAPACITY, True
    if pct > 0 and people > 0:
        cap = round(people * 100 / pct)
        if cap > 0:
            return cap, False
    return DEFAULT_CAPACITY, True


def _precise(value):
    text = repr(float(value))
    return "." in text and len(text.split(".")[1]) >= 4


def to_row(point, state):
    """A centres.csv row, or None when the point cannot be used (reason given in the second value)."""
    try:
        lat, lon = float(point["latti"]), float(point["longi"])
    except (KeyError, TypeError, ValueError):
        return None, "no position"
    box = BOXES[state]
    if not (box[0] <= lat <= box[1] and box[2] <= lon <= box[3]):
        return None, f"position {lat}, {lon} is outside {state}"
    district = " ".join(str(point.get("daerah") or "").upper().split())
    if district not in DISTRICTS[state]:
        return None, f"district '{point.get('daerah')}' is not a {state} district"
    cap, estimate = capacity_of(point)
    raw = " ".join(str(point.get("name") or "").replace("\\", "").split())
    if not raw:
        return None, "no name"
    checked = _precise(lat) and _precise(lon)
    return {
        "code": f"{CODE_PREFIX}{int(point['id'])}",
        "name": tidy_name(raw),
        "state": state,
        "district": district,
        "lat": f"{lat:.6f}".rstrip("0").rstrip("."),
        "lon": f"{lon:.6f}".rstrip("0").rstrip("."),
        "capacity": str(cap),
        "capacity_is_estimate": "yes" if estimate else "no",
        "location_checked": "yes" if checked else "no",
        "resource_point_code": "",
        "notes": f"JKM InfoBencana PPS id {int(point['id'])} ({raw}; mukim {point.get('mukim') or '-'})",
    }, None


def _with_flags(row):
    """Adds the reminders that depend on the final values to a JKM row's notes."""
    base = row["notes"].split(";  ")[0]
    flags = []
    if row["capacity_is_estimate"] == "yes":
        flags.append("capacity not given by JKM yet")
    if row["location_checked"] == "no":
        flags.append("JKM position is rough, check it on a map")
    return ";  ".join([base] + flags)


def merge(rows, points_by_state):
    """New list of rows and a list of messages. Existing JKM rows are updated
    (name, position, district); a capacity worked out from JKM replaces an estimate
    but is never replaced by one. Other rows are left exactly as they are."""
    rows = [dict(r) for r in rows]
    by_code = {r["code"]: r for r in rows}
    names = {r["name"].lower(): r["code"] for r in rows}
    messages = []
    for state, points in points_by_state.items():
        for p in points:
            try:
                new, why = to_row(p, state)
            except (KeyError, TypeError, ValueError):
                new, why = None, "no JKM id"
            if new is None:
                messages.append(f"skipped JKM PPS {p.get('id')} {p.get('name')!r}: {why}")
                continue
            old = by_code.get(new["code"])
            owner = names.get(new["name"].lower())
            if owner and owner != new["code"]:
                messages.append(f"skipped {new['code']} '{new['name']}': the name is already used by {owner}")
                continue
            if old is None:
                new["notes"] = _with_flags(new)
                rows.append(new)
                by_code[new["code"]] = new
                names[new["name"].lower()] = new["code"]
                messages.append(f"added {new['code']} {new['name']} ({new['district']}, capacity {new['capacity']})")
                continue
            before = dict(old)
            names.pop(old["name"].lower(), None)
            for k in ("name", "state", "district", "lat", "lon", "location_checked", "notes"):
                old[k] = new[k]
            if new["capacity_is_estimate"] == "no" or old["capacity_is_estimate"] == "yes":
                old["capacity"], old["capacity_is_estimate"] = new["capacity"], new["capacity_is_estimate"]
            old["notes"] = _with_flags(old)
            names[old["name"].lower()] = old["code"]
            if old != before:
                messages.append(f"updated {old['code']} {old['name']}")
    return rows, messages


def read_rows(path):
    with open(path, newline="", encoding="utf-8-sig") as f:
        return [{c: (r.get(c) or "") for c in CENTRE_COLS} for r in csv.DictReader(f)]


def write_rows(path, rows):
    buf = io.StringIO()
    w = csv.DictWriter(buf, fieldnames=CENTRE_COLS, lineterminator="\n")
    w.writeheader()
    w.writerows(rows)
    with open(path, "w", newline="", encoding="utf-8") as f:
        f.write(buf.getvalue())


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--file", default=str(PLACES_DIR / "centres.csv"))
    p.add_argument("--dry-run", action="store_true")
    a = p.parse_args()
    points = {state: fetch_points(state) for state in STATE_IDS}
    rows, messages = merge(read_rows(a.file), points)
    for m in messages:
        print(m)
    print(f"JKM lists {sum(len(v) for v in points.values())} open PPS "
          f"({', '.join(f'{s} {len(v)}' for s, v in points.items())}); centres.csv would have {len(rows)} rows")
    if not a.dry_run:
        write_rows(a.file, rows)
        print(f"Wrote {a.file}. Check it with: python -m jps_logger.places check")


if __name__ == "__main__":
    main()
