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
    files = {"XGBoost": "model/xgboost.json", "LightGBM": "model/lightgbm.txt",
             "CatBoost": "model/catboost.cbm", "Random forest": "model/random_forest.json"}
    for name in ("metrics.json", "forecast.json", "model/ensemble.json"):
        assert (tmp_path / name).exists()
    for member, name in files.items():  # one file per chosen model, none for the others
        assert (tmp_path / name).exists() == (member in metrics["model"]["members"])
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
    t = trained["test"]
    rows = t[t["station_id"] == "JHR-AWAT"]
    contrib = trained["model"].contributions(rows)
    i = FEATURES.index("up_rain_sum_3h")
    assert np.abs(contrib[:, i]).mean() > 0.005


# ML16 results for each state on its own
def test_results_by_state_cover_every_test_row(trained, stations):
    from flood_ml.train import by_state
    m = trained["metrics"]["by_state"]
    assert sum(s["test_rows"] for s in m.values()) == trained["metrics"]["test_rows"]
    # sample stations give no state: all counted as Selangor
    assert set(m) == {"Selangor"}
    test = trained["test"]
    melaka = [dict(s, state="Melaka") if s["id"].startswith("MLK") else s for s in stations]
    split = by_state(np.zeros(len(test)), test, melaka)
    assert set(split) == {"Melaka", "Selangor"}
    assert split["Melaka"]["stations"] == test[test.station_id.str.startswith("MLK")].station_id.nunique()
    assert split["Melaka"]["mae_m"] == pytest.approx(split["Melaka"]["baseline_mae_m"])  # no change predicted


# ML13 weighted tree ensemble with exact explanations
def test_all_four_tree_models_are_scored_and_weights_sum_to_one(trained):
    m = trained["model"]
    assert set(m.validation_mae) == {"xgboost", "lightgbm", "catboost", "random_forest"}  # from validation, not test
    assert sum(m.weights.values()) == pytest.approx(1.0)
    assert all(v > 0 for v in m.weights.values())
    assert set(m.members) == set(m.weights)  # only the chosen models are kept


def test_the_choice_follows_the_decision_rule(trained):
    from flood_ml.ensemble import ENSEMBLE
    m = trained["model"]
    best = min(m.validation_mae, key=m.validation_mae.get)
    if m.chosen == ENSEMBLE:
        assert m.ensemble_validation_mae < m.validation_mae[best]
        assert set(m.weights) == set(m.validation_mae)
    else:
        assert m.chosen == best and m.validation_mae[best] <= m.ensemble_validation_mae
        assert m.weights == {best: 1.0}


class _Biased:
    """Stand-in tree model: the true answer (level_above_normal) plus a fixed error."""
    def __init__(self, bias):
        self.bias = bias

    def fit(self, x, y):
        return self

    def predict(self, x):
        return x["level_above_normal"].to_numpy(dtype=float) + self.bias


def _rule_data():
    from flood_ml.features import TARGET
    rng = np.random.default_rng(0)
    df = pd.DataFrame(rng.normal(size=(400, len(FEATURES))), columns=FEATURES)
    df["time"] = pd.date_range("2026-01-01", periods=400, freq="h", tz="UTC")
    df[TARGET] = df["level_above_normal"]
    return df


def test_ensemble_is_kept_when_it_beats_every_single_model(monkeypatch):
    from flood_ml import ensemble
    biases = {"high": 0.1, "low": -0.1}  # errors cancel out when averaged
    monkeypatch.setattr(ensemble, "make_member", lambda name, fast=False: _Biased(biases[name]))
    m = ensemble.TreeEnsemble.fit(_rule_data(), members=tuple(biases))
    assert m.chosen == ensemble.ENSEMBLE
    assert m.weights == pytest.approx({"high": 0.5, "low": 0.5})


def test_best_single_model_is_used_when_the_ensemble_does_not_beat_it(monkeypatch):
    from flood_ml import ensemble
    biases = {"good": 0.05, "worse": 0.2}  # same direction: averaging only adds error
    monkeypatch.setattr(ensemble, "make_member", lambda name, fast=False: _Biased(biases[name]))
    m = ensemble.TreeEnsemble.fit(_rule_data(), members=tuple(biases))
    assert m.chosen == "good"
    assert m.weights == {"good": 1.0} and set(m.members) == {"good"}
    assert m.describe()["chosen"] == "good"


def test_ensemble_explanation_adds_up_exactly(trained):
    rows = trained["test"].head(50)
    contrib = trained["model"].contributions(rows)
    assert contrib.shape == (len(rows), len(FEATURES) + 1)
    np.testing.assert_allclose(contrib.sum(axis=1), trained["model"].predict(rows), atol=1e-4)


def test_ensemble_is_the_weighted_average_of_its_members(trained):
    m, rows = trained["model"], trained["test"].head(20)
    by_hand = sum(w * m.members[n].predict(rows[FEATURES]) for n, w in m.weights.items())
    np.testing.assert_allclose(m.predict(rows), by_hand, atol=1e-9)


def test_metrics_describe_the_ensemble(trained):
    d = trained["metrics"]["model"]
    assert set(d["validation_mae_m"]) == {"XGBoost", "LightGBM", "CatBoost", "Random forest"}
    assert d["chosen"] == "Weighted ensemble" or d["members"] == [d["chosen"]]
    assert d["ensemble_validation_mae_m"] is not None


# ML11 classification metrics (confusion matrix, accuracy, precision, recall, F1, AUC)
def test_auc_on_known_cases():
    from flood_ml.train import auc
    assert auc([0.1, 0.2, 0.8, 0.9], [0, 0, 1, 1]) == 1.0
    assert auc([0.9, 0.8, 0.2, 0.1], [0, 0, 1, 1]) == 0.0
    assert auc([0.5, 0.5, 0.5, 0.5], [0, 1, 0, 1]) == 0.5
    assert auc([0.1, 0.4, 0.35, 0.8], [0, 0, 1, 1]) == 0.75
    assert auc([0.1, 0.2], [1, 1]) is None


def test_binary_confusion_matrix_is_consistent(trained):
    m = trained["metrics"]
    for who in ("model", "baseline", "linear_trend"):
        b = m["classification"][who]["alert_or_above"]
        c = b["confusion"]
        assert c["tn"] + c["fp"] + c["fn"] + c["tp"] == m["test_rows"]
        assert c["tp"] + c["fn"] == m["alert_or_above"]["events"]
        assert b["accuracy"] == pytest.approx((c["tp"] + c["tn"]) / m["test_rows"])
        assert b["recall"] == pytest.approx(m["alert_or_above"][who]["recall"])
        assert b["precision"] == pytest.approx(m["alert_or_above"][who]["precision"])
        p, r = b["precision"], b["recall"]
        assert b["f1"] == pytest.approx(2 * p * r / (p + r))
        assert 0 <= b["auc"] <= 1


def test_four_level_confusion_matrix(trained):
    m = trained["metrics"]
    rl = m["classification"]["model"]["risk_level"]
    cm = np.array(rl["confusion_matrix"])
    assert cm.shape == (4, 4) and cm.sum() == m["test_rows"]
    assert rl["accuracy"] == pytest.approx(np.trace(cm) / m["test_rows"])
    assert 0 <= rl["macro_f1"] <= 1
    # Alert-or-above counts agree with the 4-level matrix
    assert cm[1:, 1:].sum() == m["classification"]["model"]["alert_or_above"]["confusion"]["tp"]


def test_model_ranks_rises_better_than_no_change(trained):
    c = trained["metrics"]["classification"]
    assert c["model"]["alert_or_above"]["auc"] > 0.5
    assert c["model"]["alert_or_above"]["f1"] >= c["baseline"]["alert_or_above"]["f1"]


def test_klang_stations_run_end_to_end(tmp_path):
    from pathlib import Path
    from flood_ml.practice_data import make_practice_readings
    klang = json.loads((Path(__file__).resolve().parent.parent / "stations_klang.json").read_text())
    metrics, forecast = run(make_practice_readings(klang, end=NOW), klang, NOW, tmp_path, is_practice_data=True)
    sri_muda = next(e for e in forecast["stations"] if e["station_id"] == "BKLG0002L")
    assert any(f["feature"].startswith("up_") and f["value"] is not None for f in sri_muda["factors"])
    assert "linear_trend" in metrics
