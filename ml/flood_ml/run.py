"""Run the whole pipeline.

Practice data (no real readings needed):
    python -m flood_ml.run --practice
Real readings (CSV with station_id,time,rainfall_mm,river_level_m):
    python -m flood_ml.run --readings path/to/readings.csv
Klang river stations (real JPS codes and thresholds):
    python -m flood_ml.run --stations stations_klang.json --readings readings.csv
"""
import argparse
import json
from pathlib import Path

import pandas as pd

from .features import build_features, clean_readings, validate_stations
from .practice_data import make_practice_readings
from .predict import make_forecast, write_forecast
from .train import evaluate, save, time_split, train_model

HERE = Path(__file__).resolve().parent.parent


def run(raw, stations, now, out_dir, is_practice_data):
    validate_stations(stations)
    clean = clean_readings(raw)
    train, test, _ = time_split(build_features(clean, stations))
    if len(train) < 200 or len(test) < 50:
        raise SystemExit(f"Not enough data to train (train={len(train)}, test={len(test)} rows)")
    model = train_model(train)
    metrics = evaluate(model, test, stations)
    metrics["is_practice_data"] = bool(is_practice_data)
    save(model, metrics, out_dir)
    forecast = make_forecast(model, clean, stations, now, metrics["band_m"], is_practice_data)
    write_forecast(forecast, Path(out_dir) / "forecast.json")
    return metrics, forecast


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--practice", action="store_true")
    p.add_argument("--readings")
    p.add_argument("--stations", default=str(HERE / "stations.json"))
    p.add_argument("--out", default=str(HERE / "output"))
    p.add_argument("--now", help="UTC time to forecast from (default: current time)")
    a = p.parse_args()
    if a.practice == bool(a.readings):
        raise SystemExit("Choose one: --practice or --readings FILE")
    stations = json.loads(Path(a.stations).read_text())
    now = pd.Timestamp(a.now, tz="UTC") if a.now else pd.Timestamp.now(tz="UTC")
    raw = make_practice_readings(stations, end=now) if a.practice else pd.read_csv(a.readings)
    metrics, forecast = run(raw, stations, now, a.out, is_practice_data=a.practice)
    tag = "PRACTICE DATA - not a real result. " if a.practice else ""
    print(f"{tag}MAE {metrics['mae_m']:.3f} m vs no-change {metrics['baseline_mae_m']:.3f} m "
          f"and straight-line trend {metrics['linear_trend']['mae_m']:.3f} m; "
          f"{len(forecast['stations'])} station forecasts written to {a.out}")


if __name__ == "__main__":
    main()
