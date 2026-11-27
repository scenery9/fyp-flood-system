"""Makes forecast.json: a 3-hour river level forecast per station, with the
contribution of each input (exact TreeSHAP values of the tree ensemble), and the
station's 3-day rain outlook (Open-Meteo and MET Malaysia, as the model saw it).

Schema 2 = schema 1 plus "rain_outlook" per station (null when no forecast was logged)
and "inputs" (which input set the model was trained with, chosen on validation)."""
import json
import math

import pandas as pd

from .features import HORIZON_H, build_features
from .probability import chance_entries
from .weather import FORECAST_FEATURES

MAX_READING_AGE_H = 2


OUTLOOK = {  # forecast.json name: model input
    "next_3h_mm": "fc_rain_next_3h", "next_3h_prob": "fc_rain_prob_next_3h",
    "day1_mm": "fc_rain_day1_mm", "day2_mm": "fc_rain_day2_mm", "day3_mm": "fc_rain_day3_mm",
    "day1_prob": "fc_rain_prob_day1", "day2_prob": "fc_rain_prob_day2", "day3_prob": "fc_rain_prob_day3",
    "rain_days_3d": "fc_rain_days_3d", "total_3d_mm": "fc_rain_total_3d",
    "day1_met_class": "met_rain_class_day1", "day2_met_class": "met_rain_class_day2",
    "day3_met_class": "met_rain_class_day3", "met_thunder_days_3d": "met_thunder_days_3d",
    "warning_level": "met_warning_level", "sources_agree_days_3d": "sources_agree_days_3d",
}


def _num(v):
    v = float(v)
    return None if math.isnan(v) else round(v, 3)


def rain_outlook(row):
    """The station's weather-forecast inputs at the forecast time, or None if there were none."""
    vals = {k: _num(row[c].iloc[0]) for k, c in OUTLOOK.items()}
    return vals if any(v is not None for v in vals.values()) else None


def _chance_summary(d):
    """What the app needs about the chance model: the headline question and how each level's
    model did on its calibration day (not the Platt constants)."""
    if "levels" not in d:  # a single ChanceModel
        d = d | {"headline_level": d.get("level"), "levels": {d.get("level"): d}}
    return {"question": d["question"], "type": d["type"], "input_set": d["input_set"],
            "headline_level": d["headline_level"], "calibration": d["calibration"],
            "levels": {lv: (None if m is None else {"input_set": m["input_set"], "calibration": m["calibration"]})
                       for lv, m in d["levels"].items()}}


def make_forecast(model, clean, stations, now, band_m, is_practice_data, model_version="1", weather=None,
                  input_set=None, chance_model=None):
    now = pd.Timestamp(now).tz_convert("UTC")
    feats = build_features(clean, stations, with_target=False, weather=weather)
    features = list(getattr(model, "features", None) or [])
    entries = []
    chances = {}
    if chance_model is not None:
        fresh = feats[(feats["time"] <= now) & (feats["time"] >= now - pd.Timedelta(hours=MAX_READING_AGE_H))]
        chances = chance_entries(chance_model, fresh.sort_values("time"), {s["id"]: s for s in stations})
    for st in stations:
        g = feats[(feats["station_id"] == st["id"]) & (feats["time"] <= now)]
        g = g.dropna(subset=["river_level_m", "level_change_1h", "level_change_3h"])
        if g.empty:
            continue
        row = g.sort_values("time").iloc[[-1]]
        based_on = row["time"].iloc[0]
        if now - based_on > pd.Timedelta(hours=MAX_READING_AGE_H):
            continue  # reading too old: better no forecast than a wrong one
        contrib = model.contributions(row)[0]
        change = float(contrib.sum())  # feature contributions + base value = prediction (exact TreeSHAP)
        level = float(row["river_level_m"].iloc[0])
        factors = [
            {
                "feature": f,
                "value": None if math.isnan(float(row[f].iloc[0])) else round(float(row[f].iloc[0]), 3),
                "impact_m": round(float(c), 4),
            }
            for f, c in zip(features, contrib[:-1])
        ]
        factors.sort(key=lambda x: -abs(x["impact_m"]))
        entries.append({
            "station_id": st["id"],
            "based_on": based_on.strftime("%Y-%m-%dT%H:%M:%SZ"),
            "current_level_m": round(level, 3),
            "predicted_level_m": round(level + change, 3),
            "low_m": round(level + change - band_m, 3),
            "high_m": round(level + change + band_m, 3),
            "base_change_m": round(float(contrib[-1]), 4),
            "factors": factors,
            "rain_outlook": rain_outlook(row),
            "flood_chance": chances.get(st["id"]),
        })
    return {
        "schema": 2,
        "generated_at": now.strftime("%Y-%m-%dT%H:%M:%SZ"),
        "horizon_hours": HORIZON_H,
        "model": {"name": "tree-ensemble", "version": model_version,
                  "members": getattr(model, "describe", lambda: {})().get("weights", {})},
        "is_practice_data": bool(is_practice_data),
        "inputs": {"set": input_set, "weather_forecast_used": any(f in FORECAST_FEATURES for f in features),
                   "correction_alpha": getattr(model, "alpha", None)},
        "chance_model": None if chance_model is None else _chance_summary(chance_model.describe()),
        "stations": entries,
    }


def write_forecast(forecast, path):
    with open(path, "w") as f:
        json.dump(forecast, f, indent=2, allow_nan=False)
