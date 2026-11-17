import json
import math

import numpy as np

import pandas as pd
import pytest

from flood_ml.features import FEATURES, HORIZON_H, clean_readings
from flood_ml.predict import make_forecast, write_forecast
from flood_ml.run import run
from flood_ml.train import time_split

from conftest import NOW


# ML4 split and evaluation
def test_split_is_by_time_with_a_gap(trained):
    train, test, cutoff = trained["train"], trained["test"], trained["cutoff"]
    assert train["time"].max() + pd.Timedelta(hours=HORIZON_H) < cutoff <= test["time"].min()
    assert len(train) > len(test) > 0


def test_split_drops_rows_without_a_target(clean, stations):
    from flood_ml.features import TARGET, build_features
    train, test, _ = time_split(build_features(clean, stations))
    assert train[TARGET].notna().all() and test[TARGET].notna().all()


def test_model_beats_the_no_change_baseline(trained):
    m = trained["metrics"]
    assert m["mae_m"] < m["baseline_mae_m"]
    assert m["rmse_m"] < m["baseline_rmse_m"]
    assert 0 < m["skill_vs_baseline"] <= 1
    assert m["band_m"] > 0


def test_event_metrics_are_reported(trained):
    e = trained["metrics"]["alert_or_above"]
    assert e["events"] > 0
    for who in ("model", "baseline"):
        assert 0 <= e[who]["recall"] <= 1
        assert e[who]["missed"] + round(e[who]["recall"] * e["events"]) == e["events"]


# ML5 forecast file
@pytest.fixture(scope="module")
def forecast(trained, clean, stations):
    return make_forecast(trained["model"], clean, stations, NOW, trained["metrics"]["band_m"], True)


def test_forecast_header(forecast):
    assert forecast["schema"] == 1
    assert forecast["horizon_hours"] == 3
    assert forecast["generated_at"] == "2026-11-17T03:00:00Z"
    assert forecast["is_practice_data"] is True


def test_one_entry_per_station_with_sane_values(forecast, stations):
    assert {e["station_id"] for e in forecast["stations"]} == {s["id"] for s in stations}
    for e in forecast["stations"]:
        assert e["low_m"] < e["predicted_level_m"] < e["high_m"]
        assert abs(e["predicted_level_m"] - e["current_level_m"]) < 5
        assert [f["feature"] for f in e["factors"]] != [] and {f["feature"] for f in e["factors"]} == set(FEATURES)


def test_explanation_adds_up_to_the_prediction(forecast):
    """SHAP property: base value + all impacts = predicted change."""
    for e in forecast["stations"]:
        total = e["base_change_m"] + sum(f["impact_m"] for f in e["factors"])
        assert math.isclose(total, e["predicted_level_m"] - e["current_level_m"], abs_tol=0.005)


def test_factors_sorted_by_size_of_impact(forecast):
    for e in forecast["stations"]:
        sizes = [abs(f["impact_m"]) for f in e["factors"]]
        assert sizes == sorted(sizes, reverse=True)


def test_station_with_old_readings_gets_no_forecast(trained, clean, stations):
    old = clean[~((clean["station_id"] == "JHR-AWAT") & (clean["time"] > NOW - pd.Timedelta(hours=5)))]
    f = make_forecast(trained["model"], old, stations, NOW, 0.1, True)
    assert "JHR-AWAT" not in {e["station_id"] for e in f["stations"]}
    assert len(f["stations"]) == len(stations) - 1


def test_forecast_never_uses_readings_after_now(trained, clean, stations):
    earlier = NOW - pd.Timedelta(hours=10)
    f = make_forecast(trained["model"], clean, stations, earlier, 0.1, True)
    assert all(pd.Timestamp(e["based_on"]) <= earlier for e in f["stations"])


def test_no_data_gives_an_empty_but_valid_file(trained, stations, tmp_path):
    empty = clean_readings(pd.DataFrame(columns=["station_id", "time", "rainfall_mm", "river_level_m"]))
    f = make_forecast(trained["model"], empty, stations, NOW, 0.1, True)
    assert f["stations"] == []
    write_forecast(f, tmp_path / "f.json")
    assert json.loads((tmp_path / "f.json").read_text())["schema"] == 1


# ML6 whole pipeline
def test_pipeline_writes_all_outputs(raw, stations, tmp_path):
    metrics, forecast = run(raw, stations, NOW, tmp_path, is_practice_data=True)
    for name in ("model.json", "metrics.json", "forecast.json"):
        assert (tmp_path / name).exists()
    assert json.loads((tmp_path / "metrics.json").read_text())["is_practice_data"] is True
    assert json.loads((tmp_path / "forecast.json").read_text()) == forecast


def test_pipeline_refuses_too_little_data(raw, stations, tmp_path):
    with pytest.raises(SystemExit):
        run(raw.head(100), stations, NOW, tmp_path, is_practice_data=True)


# ML9 comparison with the straight-line method
def test_straight_line_baseline_is_reported(trained):
    m = trained["metrics"]
    lin = m["linear_trend"]
    assert lin["mae_m"] > 0 and lin["rmse_m"] > 0
    assert 0 <= lin["fallback_rows"] < m["test_rows"]
    assert m["skill_vs_linear_trend"] == pytest.approx(1 - m["mae_m"] / lin["mae_m"])
    assert set(m["alert_or_above"]) == {"events", "model", "baseline", "linear_trend"}


def test_model_beats_the_straight_line_on_practice_data(trained):
    m = trained["metrics"]
    assert m["mae_m"] < m["linear_trend"]["mae_m"]


# ML10 upstream inputs reach the forecast and its explanation
def test_upstream_inputs_explain_the_forecast(forecast):
    awat = next(e for e in forecast["stations"] if e["station_id"] == "JHR-AWAT")
    up = {f["feature"]: f for f in awat["factors"] if f["feature"].startswith("up_")}
    assert set(up) == {"up_level_change_1h", "up_level_change_3h", "up_rain_sum_3h", "up_rain_sum_6h"}
    assert all(f["value"] is not None for f in up.values())
    other = next(e for e in forecast["stations"] if e["station_id"] == "JHR-CHAAH")
    assert all(f["value"] is None for f in other["factors"] if f["feature"].startswith("up_"))


def test_upstream_rain_matters_where_upstream_water_arrives(trained):
    """In the practice data upstream rain reaches JHR-AWAT about 4 hours later,
    so the model should rely on it there."""
    import xgboost as xgb
    t = trained["test"]
    rows = t[t["station_id"] == "JHR-AWAT"]
    contrib = trained["model"].predict(xgb.DMatrix(rows[FEATURES]), pred_contribs=True)
    i = FEATURES.index("up_rain_sum_3h")
    assert np.abs(contrib[:, i]).mean() > 0.005


def test_klang_stations_run_end_to_end(tmp_path):
    from pathlib import Path
    from flood_ml.practice_data import make_practice_readings
    klang = json.loads((Path(__file__).resolve().parent.parent / "stations_klang.json").read_text())
    metrics, forecast = run(make_practice_readings(klang, end=NOW), klang, NOW, tmp_path, is_practice_data=True)
    sri_muda = next(e for e in forecast["stations"] if e["station_id"] == "BKLG0002L")
    assert any(f["feature"].startswith("up_") and f["value"] is not None for f in sri_muda["factors"])
    assert "linear_trend" in metrics
