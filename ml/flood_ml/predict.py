"""Makes forecast.json: a 3-hour river level forecast per station, with the
contribution of each input (exact TreeSHAP values of the tree ensemble)."""
import json
import math

import pandas as pd

from .features import FEATURES, HORIZON_H, build_features

MAX_READING_AGE_H = 2


def make_forecast(model, clean, stations, now, band_m, is_practice_data, model_version="1"):
    now = pd.Timestamp(now).tz_convert("UTC")
    feats = build_features(clean, stations, with_target=False)
    entries = []
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
            for f, c in zip(FEATURES, contrib[:-1])
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
        })
    return {
        "schema": 1,
        "generated_at": now.strftime("%Y-%m-%dT%H:%M:%SZ"),
        "horizon_hours": HORIZON_H,
        "model": {"name": "tree-ensemble", "version": model_version,
                  "members": getattr(model, "describe", lambda: {})().get("weights", {})},
        "is_practice_data": bool(is_practice_data),
        "stations": entries,
    }


def write_forecast(forecast, path):
    with open(path, "w") as f:
        json.dump(forecast, f, indent=2, allow_nan=False)
