"""Run the whole pipeline.

Practice data (no real readings needed):
    python -m flood_ml.run --practice
Real readings (CSV with station_id,time,rainfall_mm,river_level_m):
    python -m flood_ml.run --readings path/to/readings.csv
Klang river stations (real JPS codes and thresholds):
    python -m flood_ml.run --stations stations_klang.json --readings readings.csv
With the logged weather forecasts (Open-Meteo and MET Malaysia, data/forecast/):
    python -m flood_ml.run --stations stations_training.json --readings readings.csv --weather ../data/forecast
Which forecast inputs the model gets (none, next day, or 3 days) is chosen on
validation data (train.choose_inputs) and written to metrics.json and forecast.json.
With FORECAST_SIGNING_KEY and FORECAST_KEY_ID set, forecast.json.sig is written
next to forecast.json (see sign.py). Upload both; the app ignores an unsigned file.
"""
import argparse
import json
import os
from pathlib import Path

import pandas as pd

from .features import build_features, clean_readings, validate_stations
from .practice_data import make_practice_readings
from .predict import make_forecast, write_forecast
from .sign import sign_file
from .probability import FloodChance
from .train import choose_inputs, evaluate, save, time_split, train_model
from .weather import load_weather

HERE = Path(__file__).resolve().parent.parent


def run(raw, stations, now, out_dir, is_practice_data, weather=None):
    validate_stations(stations)
    clean = clean_readings(raw)
    feats = build_features(clean, stations, weather=weather)
    train, test, _ = time_split(feats)
    if len(train) < 200 or len(test) < 50:
        raise SystemExit(f"Not enough data to train (train={len(train)}, test={len(test)} rows)")
    input_set, cols, val_scores = choose_inputs(train)
    model = train_model(train, features=cols, input_set=input_set)
    metrics = evaluate(model, test, stations)
    metrics["is_practice_data"] = bool(is_practice_data)
    metrics["inputs"] = {"set": input_set, "validation_scores": val_scores, "columns": list(model.features),
                         "correction_alpha": getattr(model, "alpha", None)}
    chance = FloodChance.fit(feats[feats["time"] <= now])
    metrics["chance_24h"] = chance.describe() if chance else None
    chance = chance or None
    save(model, metrics, out_dir)
    forecast = make_forecast(model, clean, stations, now, metrics["band_m"], is_practice_data,
                             weather=weather, input_set=input_set, chance_model=chance)
    write_forecast(forecast, Path(out_dir) / "forecast.json")
    return metrics, forecast


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--practice", action="store_true")
    p.add_argument("--readings")
    p.add_argument("--stations", default=str(HERE / "stations.json"))
    p.add_argument("--out", default=str(HERE / "output"))
    p.add_argument("--now", help="UTC time to forecast from (default: current time)")
    p.add_argument("--weather", help="logged weather forecasts (data/forecast folder)")
    a = p.parse_args()
    if a.practice == bool(a.readings):
        raise SystemExit("Choose one: --practice or --readings FILE")
    stations = json.loads(Path(a.stations).read_text(encoding="utf-8"))
    now = pd.Timestamp(a.now, tz="UTC") if a.now else pd.Timestamp.now(tz="UTC")
    raw = make_practice_readings(stations, end=now) if a.practice else pd.read_csv(a.readings)
    weather = load_weather(a.weather) if a.weather else None
    metrics, forecast = run(raw, stations, now, a.out, is_practice_data=a.practice, weather=weather)
    vs = metrics['inputs']['validation_scores']
    print(f"Inputs chosen on validation: {metrics['inputs']['set']} (alpha {metrics['inputs']['correction_alpha']})")
    for name, sc in vs.items():
        hw = sc['high_water_mae_m']
        print(f"  {name}: MAE {sc['mae_m']:.4f} m, high-water MAE {'-' if hw is None else f'{hw:.4f}'} m")
    seed = os.environ.get("FORECAST_SIGNING_KEY")
    if seed:
        key_id = os.environ.get("FORECAST_KEY_ID")
        if not key_id:
            raise SystemExit("FORECAST_SIGNING_KEY is set but FORECAST_KEY_ID is not")
        print(f"Signed with key {key_id}: {sign_file(Path(a.out) / 'forecast.json', seed, key_id)}")
    tag = "PRACTICE DATA - not a real result. " if a.practice else ""
    print(f"{tag}MAE {metrics['mae_m']:.3f} m vs no-change {metrics['baseline_mae_m']:.3f} m "
          f"and straight-line trend {metrics['linear_trend']['mae_m']:.3f} m; "
          f"{len(forecast['stations'])} station forecasts written to {a.out}")
    print(f"  NSE {_fmt(metrics['nse'])}, Willmott d {_fmt(metrics['willmott_d'])}, persistence index "
          f"{_fmt(metrics['persistence_index'])}, bias {_fmt(metrics['bias_m'])} m, "
          f"peak error {_fmt(metrics['peak_error_m'])} m")
    for state, m in metrics["by_state"].items():
        print(f"  {state}: {m['stations']} stations, {m['test_rows']} test rows, MAE {m['mae_m']:.3f} m, "
              f"RMSE {m['rmse_m']:.3f} m, NSE {_fmt(m['nse'])}, PI {_fmt(m['persistence_index'])} "
              f"(no change MAE {m['baseline_mae_m']:.3f} m)")


def _fmt(v):
    return "-" if v is None else f"{v:.3f}"

if __name__ == "__main__":
    main()
