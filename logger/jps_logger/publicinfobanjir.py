"""Reading the national JPS pages (publicinfobanjir.water.gov.my).

They list every state's river levels and rainfall, so they are a second source
for Selangor and Melaka: collect.py uses them when the state's own source
fails (or first, for Melaka, see collect.SOURCES).

The parsed rows are the same dicts as melaka.py makes, so the same checks and
row builders apply. Differences:
  - no map positions (lat/lon are None; stored positions are kept);
  - river times have no seconds ("19/11/2026 18:00");
  - Selangor stations use the national station id (3015432), not the Selangor
    station code (BKLG0002L); collect.py maps one to the other.

The pages are loose HTML: rainfall rows have no opening <tr> and there are many
stray </tr>. A row that does not look right is skipped, never guessed.
"""
from html.parser import HTMLParser

from . import jps

BASE = "https://publicinfobanjir.water.gov.my"
STATE_CODES = {"Selangor": "SEL", "Melaka": "MLK"}


def river_url(state):
    return (f"{BASE}/index.php/aras-air/data-paras-air/aras-air-data/"
            f"?state={STATE_CODES[state]}&district=ALL&station=ALL&lang=en")


def rain_url(state):
    return (f"{BASE}/wp-content/themes/shapely/agency/searchresultrainfall.php"
            f"?state={STATE_CODES[state]}&district=ALL&station=ALL&language=1&loginStatus=0")


class _Rows(HTMLParser):
    """Data rows of the page's table: lists of (cell text, data-th label or None).
    A row starts at <tr> or at the first <td> after a row ended; it ends at </tr>.
    Rows holding <th> (the headings) are dropped."""

    def __init__(self):
        super().__init__(convert_charrefs=True)
        self.rows, self._row, self._cell, self._th = [], None, None, False

    def handle_starttag(self, tag, attrs):
        if tag == "tr":
            self._close_row()
            self._row, self._th = [], False
        elif tag in ("td", "th"):
            if self._row is None:
                self._row, self._th = [], False
            self._close_cell()
            self._th = self._th or tag == "th"
            self._cell = {"text": [], "label": (dict(attrs).get("data-th") or "").strip().lower() or None}
        elif tag == "br" and self._cell is not None:
            self._cell["text"].append(" ")

    def handle_endtag(self, tag):
        if tag in ("td", "th"):
            self._close_cell()
        elif tag in ("tr", "table", "tbody"):
            self._close_row()

    def handle_data(self, data):
        if self._cell is not None:
            self._cell["text"].append(data)

    def _close_cell(self):
        if self._cell is not None and self._row is not None:
            self._row.append((" ".join("".join(self._cell["text"]).split()), self._cell["label"]))
        self._cell = None

    def _close_row(self):
        self._close_cell()
        if self._row and not self._th:
            self.rows.append(self._row)
        self._row, self._th = None, False


def _rows(html):
    p = _Rows()
    p.feed(html or "")
    p.close()
    p._close_row()
    return p.rows


def _name(text):
    """'Sg. Melaka di Melaka Pindah (F2)' -> 'Sg. Melaka di Melaka Pindah' (the
    equipment tag is not part of the name the Melaka site shows)."""
    t = " ".join((text or "").split())
    if t.endswith(")") and "(" in t:
        head, tag = t.rsplit("(", 1)
        if len(tag) <= 6 and tag[:-1].replace(" ", "").isalnum() and tag[:-1].upper() == tag[:-1]:
            t = head.strip()
    return t


def _district(text):
    t = " ".join((text or "").split()).upper()
    return t or None


def _time_ok(text):
    return jps.parse_time(text) is not None


def river_stations(html):
    """One dict per river-level row (same keys as melaka.river_stations).
    Columns are found by their data-th label, so a moved column is not misread."""
    out = []
    for cells in _rows(html):
        by = {label: text for text, label in cells if label}
        code, name, at = by.get("station id", "").strip(), by.get("station name", "").strip(), by.get("last update", "")
        if not code or not name or not _time_ok(at) or "wl" not in by:
            continue
        out.append({
            "code": code, "name": _name(name), "district": _district(by.get("district")),
            "basin": (by.get("main basin (mm)") or "").strip() or None, "lat": None, "lon": None,
            "time": at, "level": jps._number(by.get("wl")), "normal": jps._number(by.get("normal")),
            "alert": jps._number(by.get("alert")), "warning": jps._number(by.get("warning")),
            "danger": jps._number(by.get("danger")),
        })
    return out


def rain_stations(html):
    """One dict per rainfall row (same keys as melaka.rain_stations).
    No | ID | Station | District | Last updated | six past days | Since midnight | Total 1 hour."""
    out = []
    for cells in _rows(html):
        if len(cells) < 8:
            continue
        code, name, at = cells[1][0].strip(), cells[2][0].strip(), cells[4][0]
        if not code or not name or not _time_ok(at):
            continue
        out.append({
            "code": code, "name": _name(name), "district": _district(cells[3][0]),
            "lat": None, "lon": None, "time": at,
            "today": jps._number(cells[-2][0]), "hourly": jps._number(cells[-1][0]),
        })
    return out
