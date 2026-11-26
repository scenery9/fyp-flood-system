"""ML12 model comparison: every method on the same data, inputs, split and metrics."""
import json
import sys

import pytest

from flood_ml.compare import OURS, compare, main
from flood_ml.features import build_features


@pytest.fixture(scope="module")
def result(clean, stations):
    return compare(build_features(clean, stations), stations, fast=True)


def test_at_least_ten_methods_are_scored(result):
    scored = [m for m in result["models"] if "skipped" not in m]
    assert len(scored) >= 10
    kinds = {m["kind"] for m in scored}
    assert {"baseline", "classical", "ensemble", "neural", "ensemble member", "ours"} <= kinds
    assert len(scored) >= 14  # 2 baselines + 7 others + 4 members + ours (LSTM/GRU optional)


def test_same_test_set_and_metrics_for_every_method(result):
    for m in result["models"]:
        if "skipped" in m:
            continue
        c = m["alert_or_above"]["confusion"]
        assert c["tn"] + c["fp"] + c["fn"] + c["tp"] == result["test_rows"]
        for key in ("mae_m", "rmse_m", "band_m"):
            assert m[key] >= 0
        for key in ("accuracy", "precision", "recall", "f1", "auc"):
            assert key in m["alert_or_above"]
        assert len(m["risk_level"]["confusion_matrix"]) == 4


def test_deep_models_are_scored_or_marked_skipped(result):
    deep = {m["name"]: m for m in result["models"] if m["name"] in ("LSTM", "GRU")}
    assert set(deep) == {"LSTM", "GRU"}
    for m in deep.values():
        assert "skipped" in m or m["mae_m"] >= 0


def test_ours_beats_the_baselines_on_practice_data(result):
    by_name = {m["name"]: m for m in result["models"]}
    ours = by_name[OURS]
    assert sum(ours["weights"].values()) == pytest.approx(1.0, abs=1e-3)  # each shown to 4 decimals
    assert ours["mae_m"] < by_name["No change (persistence)"]["mae_m"]
    assert ours["mae_m"] < by_name["Straight-line trend (FloodWatch)"]["mae_m"]


def test_baseline_rows_match_train_metrics(result, trained):
    """The comparison's baselines use the same split, so they match evaluate()."""
    by_name = {m["name"]: m for m in result["models"]}
    m = trained["metrics"]
    assert result["test_rows"] == m["test_rows"]
    assert by_name["No change (persistence)"]["mae_m"] == pytest.approx(m["baseline_mae_m"])
    assert by_name["Straight-line trend (FloodWatch)"]["mae_m"] == pytest.approx(m["linear_trend"]["mae_m"])


def test_too_little_data_is_refused(clean, stations):
    with pytest.raises(SystemExit):
        compare(build_features(clean.head(100), stations), stations, fast=True)


def test_command_writes_comparison_json(tmp_path, monkeypatch, capsys):
    monkeypatch.setattr(sys, "argv", ["compare", "--practice", "--fast", "--out", str(tmp_path)])
    main()
    data = json.loads((tmp_path / "comparison.json").read_text())
    assert data["is_practice_data"] is True
    assert len(data["models"]) >= 16
    assert "PRACTICE DATA" in capsys.readouterr().out
