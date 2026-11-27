"""Rain-history inputs, flood-focused scoring and the residual correction model."""
import math

import numpy as np
import pandas as pd
import pytest

from flood_ml.features import FILL, SPAN, build_features, rain_history
from flood_ml.practice_data import make_practice_weather
from flood_ml.residual import ResidualModel
from flood_ml.scoring import choose, flood_scores, high_water
from flood_ml.train import RESIDUAL, candidate_sets, time_split
from flood_ml.weather import FILL_INTERACTION, RAISES_ONLY


def test_rain_history_values():
    rain = pd.Series([0.0] * 30 + [2.0, 3.0, 0.0, 5.0, 5.0, 5.0], dtype=float)
    h = rain_history(rain)
    assert h["consecutive_wet_hours"].iloc[-1] == 3
    assert h["consecutive_wet_hours"].iloc[-4] == 0
    assert h["wet_hours_24h"].iloc[-1] == 5
    assert math.isnan(h["wet_hours_24h"].iloc[10])          # fewer than 24 hours seen
    assert math.isnan(h["wet_days_3d"].iloc[-1])            # needs 72 hours


def test_api_decays_by_day():
    rain = pd.Series([0.0] * 500, dtype=float)
    rain.iloc[200] = 10.0
    api = rain_history(rain)["api_7d"]
    assert math.isnan(api.iloc[100])                          # under 75% of the 7 days seen yet
    assert api.iloc[200] == pytest.approx(10.0)
    assert api.iloc[224] == pytest.approx(8.5)                # one day later
    assert api.iloc[248] == pytest.approx(10 * 0.85 ** 2)
    assert api.iloc[200 + 7 * 24] == pytest.approx(0.0)       # out of the 7-day window


def test_rain_history_never_uses_future_rain():
    rain = pd.Series(np.random.default_rng(1).gamma(1, 2, 200), dtype=float)
    a = rain_history(rain)
    later = rain.copy()
    later.iloc[150:] = 99.0
    b = rain_history(later)
    for k in a:
        pd.testing.assert_series_equal(a[k].iloc[:150], b[k].iloc[:150])


def test_rain_history_in_features(clean, stations):
    f = build_features(clean, stations)
    assert f["api_7d"].notna().mean() > 0.9
    assert (f[FILL] * f[SPAN]).round(6).equals(f["level_above_normal"].round(6))
    assert FILL_INTERACTION in RAISES_ONLY


def _rows(fill, y, span=1.0):
    return pd.DataFrame({FILL: fill, SPAN: span, "t": y, "station_id": "A", "river_level_m": fill})


def test_high_water_and_prediction_metrics():
    rows = _rows([0.2, 0.6, 0.9, 1.2], [0.1, 0.0, 0.2, 0.0])
    assert high_water(rows, rows["t"]).tolist() == [False, True, True, True]
    s = flood_scores([0.0, 0.0, 0.05, 0.0], rows, "t")
    assert s["high_water_rows"] == 3
    assert s["high_water_metrics"]["rows"] == 3
    assert s["high_water_mae_m"] == pytest.approx(s["high_water_metrics"]["mae_m"])
    assert s["metrics"]["persistence_index"] == pytest.approx(1 - (0.1 ** 2 + 0.15 ** 2) / (0.1 ** 2 + 0.2 ** 2))
    assert "new_alert_crossings" not in s


def test_choose_prefers_high_water_within_the_guard():
    sc = lambda mae, hw: {"mae_m": mae, "high_water_mae_m": hw}  # noqa: E731
    assert choose({"a": sc(0.100, 0.30), "b": sc(0.104, 0.25)}) == "b"   # within 5%: flood score wins
    assert choose({"a": sc(0.100, 0.30), "b": sc(0.120, 0.20)}) == "a"   # too much worse overall
    assert choose({"a": sc(0.100, 0.30), "b": sc(0.100, 0.30)}) == "a"   # tie: the simpler (first) one


@pytest.fixture(scope="module")
def feats_with(raw, clean, stations):
    def make(noise):
        weather = make_practice_weather(raw)
        if noise:  # a forecast with no information: shuffled across hours
            om = weather["openmeteo"]
            rng = np.random.default_rng(3)
            om["precip_mm"] = rng.permutation(om["precip_mm"].to_numpy())
        return build_features(clean, stations, weather=weather)
    return make


def test_useless_correction_is_switched_off(feats_with):
    train, test, _ = time_split(feats_with(noise=True))
    m = ResidualModel.fit(train, fast=True)
    if m.alpha == 0:
        assert np.allclose(m.predict(test), m.base.predict(test))
    # whatever alpha was chosen, it was no worse than alpha 0 on the days it was chosen on
    s = m.alpha_scores
    if s:
        assert s[str(m.alpha)]["mae_m"] <= s["0.0"]["mae_m"] * 1.05 + 1e-12


def test_residual_explanation_adds_up_and_rain_only_raises(feats_with):
    train, test, _ = time_split(feats_with(noise=False))
    m = ResidualModel.fit(train, fast=True)
    rows = test.dropna(subset=["fc_rain_day1_mm"]).head(300).copy()
    contrib = m.contributions(rows)
    assert contrib.shape == (len(rows), len(m.features) + 1)
    assert np.allclose(contrib.sum(axis=1), m.predict(rows), atol=1e-4)
    if m.correction is not None:
        before = m.predict(rows)
        rows["fc_rain_day1_mm"] += 40.0
        rows[FILL_INTERACTION] += 40.0
        assert np.all(m.predict(rows) >= before - 1e-6)
    assert m.describe()["correction_alpha"] == m.alpha


def test_residual_is_a_candidate_only_with_something_to_correct(trained):
    from flood_ml.features import HISTORY_FEATURES
    from flood_ml.weather import FORECAST_FEATURES
    train = trained["train"]
    assert RESIDUAL in candidate_sets(train)  # rain history alone can correct
    bare = train.copy()
    bare[HISTORY_FEATURES + FORECAST_FEATURES + [FILL_INTERACTION]] = np.nan
    assert RESIDUAL not in candidate_sets(bare)  # nothing beyond the observed inputs
