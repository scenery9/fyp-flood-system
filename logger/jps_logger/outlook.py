"""Per-station rain outlook for the next 3 days, combining Open-Meteo and MET Malaysia.
This is what the app reads (Supabase table weather_outlook) and what it explains.

The windows are counted from "now", not by calendar date: next 3 h, day 1 = the
next 24 h, day 2 = 24-48 h, day 3 = 48-72 h. ml/flood_ml/forecast.py builds the
model's inputs the same way, with the same thresholds, so the app and the model
describe the same numbers.

Thresholds (sources in docs/references.md):
  RAIN_DAY_MM = 1     a "rain day" / wet day: at least 1 mm in the day (the ETCCDI
                      climate-index definition, used for R1mm, CWD and CDD)
  HEAVY_DAY_MM = 10   ETCCDI R10mm, "heavy precipitation day"
  VERY_HEAVY_DAY_MM = 20  ETCCDI R20mm, "very heavy precipitation day"
MET Malaysia gives classes and warnings, not mm (metmalaysia.py).
"""
from datetime import datetime, timedelta, timezone

from .metmalaysia import MYT

RAIN_DAY_MM = 1.0
HEAVY_DAY_MM = 10.0
VERY_HEAVY_DAY_MM = 20.0
DAYS = (1, 2, 3)
FMT = "%Y-%m-%dT%H:%M:%SZ"


def _t(text):
    return datetime.strptime(text, FMT).replace(tzinfo=timezone.utc) if isinstance(text, str) else text


def band(mm):
    """0 dry (< 1 mm), 1 rain day (1-10), 2 heavy (10-20), 3 very heavy (>= 20); None if unknown."""
    if mm is None:
        return None
    if mm >= VERY_HEAVY_DAY_MM:
        return 3
    if mm >= HEAVY_DAY_MM:
        return 2
    if mm >= RAIN_DAY_MM:
        return 1
    return 0


def window_date(now, day):
    """The Malaysia date most of window `day` falls on (its middle)."""
    return (now + timedelta(hours=24 * (day - 1) + 12)).astimezone(MYT).date().isoformat()


def _latest(rows, now, key="issued_at"):
    """Rows of the most recent issue made at or before now."""
    issued = [r[key] for r in rows if r.get(key) and _t(r[key]) <= now]
    if not issued:
        return []
    last = max(issued, key=_t)
    return [r for r in rows if r.get(key) == last]


def station_outlook(code, om_rows, met_rows, warn_rows, now):
    """One weather_outlook row for one station. Rows are that station's only."""
    out = {"station_code": code, "updated_at": now.strftime(FMT)}
    om = _latest(om_rows, now)
    out["om_issued_at"] = om[0]["issued_at"] if om else None

    def window(h0, h1):
        hrs = [r for r in om if now + timedelta(hours=h0) < _t(r["valid_at"]) <= now + timedelta(hours=h1)]
        if not hrs:
            return None, None, None
        mm = round(sum(r["precip_mm"] for r in hrs), 1)
        prob = max(r["prob_pct"] for r in hrs)
        oms = [r["om_prob_pct"] for r in hrs if r.get("om_prob_pct") is not None]
        return mm, prob, (max(oms) if oms else None)

    out["next_3h_mm"], out["next_3h_prob"], _ = window(0, 3)
    met = _latest(met_rows, now)
    out["met_issued_at"] = met[0]["issued_at"] if met else None
    met_by_date = {r["valid_date"]: r for r in met}
    rain_days, total = 0, 0.0
    for d in DAYS:
        mm, prob, om_prob = window(24 * (d - 1), 24 * d)
        out[f"day{d}_mm"], out[f"day{d}_prob"], out[f"day{d}_om_prob"] = mm, prob, om_prob
        out[f"day{d}_band"] = band(mm)
        m = met_by_date.get(window_date(now, d))
        out[f"day{d}_met_class"] = m["rain_class"] if m else None
        out[f"day{d}_met_text"] = m["summary"] if m else None
        out[f"day{d}_met_thunder"] = m["thunder"] if m else None
        out[f"day{d}_agree"] = (None if mm is None or not m or m["rain_class"] is None
                                else int((mm >= RAIN_DAY_MM) == (m["rain_class"] >= 1)))
        if mm is not None:
            total += mm
            rain_days += mm >= RAIN_DAY_MM
    out["rain_days_3d"] = rain_days if out["day1_mm"] is not None else None
    out["total_3d_mm"] = round(total, 1) if out["day1_mm"] is not None else None
    # Warnings issued by now and in force at some point in the next 24 h.
    active = [w for w in warn_rows
              if w.get("issued_at") and _t(w["issued_at"]) <= now
              and (not w.get("valid_to") or _t(w["valid_to"]) >= now)
              and (not w.get("valid_from") or _t(w["valid_from"]) <= now + timedelta(hours=24))]
    top = max(active, key=lambda w: (w["level"], w["kind"] != "thunderstorm"), default=None)
    out["warning_level"] = top["level"] if top else 0
    out["warning_kind"] = top["kind"] if top else None
    out["warning_title"] = top["title"] if top else None
    out["warning_valid_to"] = top["valid_to"] if top else None
    return out


def outlooks(codes, om_rows, met_rows, warn_rows, now):
    def by(rows):
        out = {}
        for r in rows:
            out.setdefault(r["station_code"], []).append(r)
        return out
    om, met, warn = by(om_rows), by(met_rows), by(warn_rows)
    return [station_outlook(c, om.get(c, []), met.get(c, []), warn.get(c, []), now) for c in codes]
