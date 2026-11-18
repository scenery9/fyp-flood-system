"""Reading the public JPS Melaka pages (infobanjirjpsmelaka.water.gov.my).

Melaka has no JSON feed like Selangor, so the two "latest data" tables are read
from the web pages. Each station's map position is inside the page itself, in
the station name's link: loadMapPage(lat, lon, ...). Times are Malaysia time,
like Selangor, and become the same rows as jps.py makes, so the database, the
app and the archive treat both states the same way.

The page layout can change without notice. A row that does not look right is
skipped (never guessed); if no rows can be read at all, collect.py reports it
as a warning and Selangor is still logged.
"""
import re
from html.parser import HTMLParser

from . import jps

BASE = "https://infobanjirjpsmelaka.water.gov.my"
RIVER_PAGE = "WaterLevel/LatestData/All"
RAIN_PAGE = "Rainfall/LatestData/All"
STATE = "Melaka"
_MAP = re.compile(r"loadMapPage\(\s*(-?[0-9.]+)\s*,\s*(-?[0-9.]+)")


class _Table(HTMLParser):
    """The cells of the first table's body rows: (text, map position or None)."""

    def __init__(self):
        super().__init__(convert_charrefs=True)
        self.rows, self._row, self._cell, self._depth, self._done = [], None, None, 0, False

    def handle_starttag(self, tag, attrs):
        if self._done:
            return
        if tag == "table":
            self._depth += 1
        elif tag == "tr" and self._depth == 1:
            self._row = []
        elif tag in ("td", "th") and self._row is not None:
            self._cell = {"text": [], "th": tag == "th", "at": None}
        elif tag == "br" and self._cell is not None:
            self._cell["text"].append(" ")
        if self._cell is not None:
            m = _MAP.search(dict(attrs).get("onclick") or "")
            if m:
                self._cell["at"] = (float(m.group(1)), float(m.group(2)))

    def handle_endtag(self, tag):
        if self._done:
            return
        if tag in ("td", "th") and self._cell is not None and self._row is not None:
            self._row.append(self._cell)
            self._cell = None
        elif tag == "tr" and self._row is not None:
            if self._row and not any(c["th"] for c in self._row):
                self.rows.append([(" ".join("".join(c["text"]).split()), c["at"]) for c in self._row])
            self._row = None
        elif tag == "table":
            self._depth -= 1
            if self._depth == 0:
                self._done = True  # only the first table

    def handle_data(self, data):
        if self._cell is not None:
            self._cell["text"].append(data)


def _rows(html):
    p = _Table()
    p.feed(html or "")
    return p.rows


def _position(at):
    if at is None:
        return None, None
    lat, lon = at
    # Melaka is around 2.0-2.6 N, 101.9-102.6 E; anything far off is a page error.
    if not (1.5 <= lat <= 3.0 and 101.5 <= lon <= 103.0):
        return None, None
    return lat, lon


def _district(text):
    t = " ".join((text or "").split()).upper()
    return t or None


def river_stations(html):
    """One dict per river-level row: code, name, district, basin, position,
    time (as on the page), level and the four thresholds."""
    out = []
    for cells in _rows(html):
        # Num | ID | Status | Name | District | Main basin | Sub basin | Last update | Level | Normal | Alert | Warning | Danger | Trend
        if len(cells) < 13:
            continue
        code, name = cells[1][0].strip(), cells[3][0].strip()
        if not code or not name:
            continue
        lat, lon = _position(cells[3][1])
        num = [jps._number(cells[i][0]) for i in range(8, 13)]
        out.append({
            "code": code, "name": name, "district": _district(cells[4][0]),
            "basin": cells[5][0].strip() or None, "lat": lat, "lon": lon,
            "time": cells[7][0], "level": num[0], "normal": num[1], "alert": num[2],
            "warning": num[3], "danger": num[4],
        })
    return out


def rain_stations(html):
    """One dict per rainfall row: code, name, district, position, time,
    rain since midnight (today) and in the last hour."""
    out = []
    for cells in _rows(html):
        # Num | ID | Status | Name | District | Last update | six past days ... | Since midnight | Total 1 hour
        if len(cells) < 8:
            continue
        code, name = cells[1][0].strip(), cells[3][0].strip()
        if not code or not name:
            continue
        lat, lon = _position(cells[3][1])
        out.append({
            "code": code, "name": name, "district": _district(cells[4][0]),
            "lat": lat, "lon": lon, "time": cells[5][0],
            "today": jps._number(cells[-2][0]), "hourly": jps._number(cells[-1][0]),
        })
    return out


def river_level_rows(stations, now):
    """Rows for jps_river_levels, with the same checks as Selangor."""
    payload = {"stations": [{"stationCode": s["code"], "lastUpdate": s["time"], "waterLevel": s["level"]}
                            for s in stations]}
    return jps.river_level_rows(payload, now)


def rainfall_rows(stations, now):
    payload = {"stations": [{"stationCode": s["code"], "lastUpdate": s["time"],
                             "hourlyRainfall": s["hourly"], "todayRainfall": s["today"]} for s in stations]}
    return jps.rainfall_rows(payload, now)


def station_rows(river, rain, now):
    """Rows for jps_stations (same columns as jps.station_rows, state Melaka)."""
    rows = {}
    stamp = now.strftime("%Y-%m-%dT%H:%M:%SZ")
    for s in list(river) + list(rain):
        row = rows.setdefault(s["code"], {
            "station_code": s["code"], "name": s["name"], "district": s["district"],
            "river_basin": s.get("basin"), "lat": s["lat"], "lon": s["lon"],
            "has_river_level": False, "has_rainfall": False, "wl_normal": None, "wl_alert": None,
            "wl_warning": None, "wl_danger": None, "updated_at": stamp, "state": STATE,
        })
        if "level" in s:
            row["has_river_level"] = True
            row.update(wl_normal=s["normal"], wl_alert=s["alert"], wl_warning=s["warning"], wl_danger=s["danger"])
        else:
            row["has_rainfall"] = True
    return list(rows.values())
