"""Chance of flood within 24 hours at each JPS level (probability.py)."""
import math

import numpy as np
import pandas as pd
import pytest

from flood_ml.features import FILL, LEVEL_SPANS, PEAK_TARGETS, SPAN, build_features
from flood_ml.probability import (FILL_TARGET, HEADLINE, LABEL, LEVELS, ChanceModel, FloodChance, _sigmoid,
                                  add_label, brier, chance_entries, platt, reliability)
from flood_ml.run import run

NOW = pd.Timestamp("2026-11-17T03:00:00Z")


def _rows():
    # Normal 0, Alert 2, Warning 3, Danger 4 (as distances above Normal)
    return pd.DataFrame({FILL: [0.5, 0.9, 1.2, 0.2, 1.6], SPAN: [2.0] * 5,
                         LEVEL_SPANS["warning"]: [3.0] * 5, LEVEL_SPANS["danger"]: [4.0] * 5,
                         "level_above_normal": [1.0, 1.8, 2.4, 0.4, 3.2],
                         PEAK_TARGETS[24]: [0.5, 0.3, 0.7, np.nan, 0.9]})


def test_label_is_reaching_alert_from_below():
    rows = add_label(_rows())
    assert rows[LABEL].tolist() == [0, 1]   # 1.0+0.5 < 2; 1.8+0.3 >= 2; above Alert and unknown left out
    assert rows[FILL_TARGET].tolist() == [0.5, 0.9]


def test_label_for_warning_and_danger():
    w = add_label(_rows(), "warning")
    assert w[LABEL].tolist() == [0, 0, 1]   # 1.5, 2.1 < 3; 2.4+0.7 = 3.1 >= 3; 3.2 already above
    assert w[FILL_TARGET].round(3).tolist() == [0.333, 0.6, 0.8]
    d = add_label(_rows(), "danger")
    assert d[LABEL].tolist() == [0, 0, 0, 1]  # 3.2+0.9 = 4.1 >= 4


def test_platt_recovers_a_known_scale():
    rng = np.random.default_rng(0)
    z = rng.normal(0, 2, 20000)
    y = rng.random(20000) < _sigmoid(0.5 * z - 1.0)
    a, b = platt(z, y)
    assert a == pytest.approx(0.5, abs=0.05) and b == pytest.approx(-1.0, abs=0.08)


def test_brier_and_reliability():
    assert brier([0.0, 1.0], [0, 1]) == 0.0
    r = reliability([0.05, 0.05, 0.5, 0.9], [0, 1, 1, 1])
    assert r[0]["rows"] == 2 and r[0]["happened"] == 0.5
    assert sum(b["rows"] for b in r) == 4


@pytest.fixture(scope="module")
def chance(clean, stations):
    feats = build_features(clean, stations)
    return feats, ChanceModel.fit(add_label(feats))


@pytest.fixture(scope="module")
def flood(clean, stations):
    feats = build_features(clean, stations)
    return feats, FloodChance.fit(feats)


def test_chance_model_fits_and_is_calibrated_on_a_later_day(chance):
    feats, m = chance
    assert m is not None
    cal = m.calibration
    assert cal["rows"] > 0 and 0 <= cal["brier"] <= 1
    newest_labelled = add_label(feats)["time"].dt.tz_convert("Asia/Kuala_Lumpur").max().date()
    assert cal["day"] == str(newest_labelled)  # the newest day with a known 24 h outcome
    assert FILL_TARGET in m.features


def test_reasons_add_up_to_the_chance_in_log_odds(chance):
    feats, m = chance
    rows = add_label(feats).tail(200)
    p = m.predict(rows)
    c = m.contributions(rows)
    assert np.allclose(c.sum(axis=1), np.log(p / (1 - p)), atol=1e-3)


def test_more_rain_never_lowers_the_chance(chance):
    feats, m = chance
    rows = add_label(feats).tail(200).copy()
    before = m.predict(rows)
    for col in ("rain_sum_3h", "rain_sum_24h"):
        if col in m.features:
            rows[col] = rows[col] + 50.0
    assert np.all(m.predict(rows) >= before - 1e-9)


def test_one_model_per_level_with_warning_as_headline(flood):
    _, fc = flood
    assert set(fc.models) == set(LEVELS)
    assert fc.models["alert"] is not None
    assert fc.headline == (HEADLINE if fc.models[HEADLINE] is not None else "alert")
    d = fc.describe()
    assert d["headline_level"] == fc.headline and set(d["levels"]) == set(LEVELS)


def test_entries_per_station(flood, stations):
    feats, fc = flood
    now = feats[feats["time"] == feats["time"].max()]
    out = chance_entries(fc, now, {s["id"]: s for s in stations})
    assert out
    for sid, e in out.items():
        assert e["horizon_hours"] == 24 and e["headline_level"] == fc.headline
        lv = e["levels"]
        # ordered: a higher level never has a higher chance than a lower one
        chances = [1.0 if lv[k]["already"] else lv[k]["chance"] for k in LEVELS if k in lv]
        known = [c for c in chances if c is not None]
        assert known == sorted(known, reverse=True)
        for k in LEVELS:
            if k in lv and lv[k]["already"]:
                assert lv[k]["chance"] is None
        if e["already"]:
            assert e["chance"] is None and e["factors"] == []
        elif e["chance"] is not None:
            assert 0 <= e["chance"] <= 1
            if not e["capped"]:
                total = e["base_logodds"] + sum(f["impact_logodds"] for f in e["factors"])
                assert math.isclose(total, math.log(e["chance"] / (1 - e["chance"])), abs_tol=0.01)
        assert "consecutive_wet_hours" in e["inputs_now"]


def test_pipeline_publishes_the_flood_chance(raw, stations, tmp_path):
    metrics, forecast = run(raw, stations, NOW, tmp_path, is_practice_data=True)
    assert metrics["chance_24h"]["headline_level"] in LEVELS
    cm = forecast["chance_model"]
    assert cm["calibration"]["rows"] > 0 and set(cm["levels"]) == set(LEVELS)
    assert any(e["flood_chance"] is not None and e["flood_chance"]["levels"] for e in forecast["stations"])
