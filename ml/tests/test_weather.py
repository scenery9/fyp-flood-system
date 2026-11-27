"""Weather-forecast inputs (Open-Meteo, MET Malaysia), the choice of input set,
the monotone rule and the rain outlook in forecast.json."""
import math

import numpy as np
import pandas as pd
import pytest

from flood_ml.ensemble import TreeEnsemble
from flood_ml.features import BASE_FEATURES, FEATURES, PEAK_TARGETS, build_features, peak_rise
from flood_ml.practice_data import make_practice_weather
from flood_ml.predict import make_forecast
from flood_ml.train import INPUT_SETS, choose_inputs, time_split
from flood_ml.weather import FORECAST_FEATURES, RAISES_ONLY, weather_features

T0 = pd.Timestamp("2026-11-20T00:00:00Z")


def _om(issued, hours_mm, code="S", prob=90.0):
    return pd.DataFrame([{"station_code": code, "issued_at": issued, "valid_at": issued + pd.Timedelta(hours=h),
                          "precip_mm": mm, "prob_pct": prob, "n_models": 8, "om_prob_pct": np.nan}
                         for h, mm in hours_mm.items()])


def _q(*times, code="S"):
    return pd.DataFrame({"station_id": [code] * len(times), "time": list(times)})


def test_windows_next_3h_and_days_1_to_3():
    hours = {h: 0.0 for h in range(1, 73)} | {1: 1.0, 3: 2.0, 4: 5.0, 30: 3.0, 60: 1.5}
    f = weather_features(_q(T0), {"openmeteo": _om(T0, hours)})
    r = f.iloc[0]
    assert r["fc_rain_next_3h"] == 3.0
    assert (r["fc_rain_day1_mm"], r["fc_rain_day2_mm"], r["fc_rain_day3_mm"]) == (8.0, 3.0, 1.5)
    assert r["fc_rain_days_3d"] == 3 and r["fc_rain_total_3d"] == 12.5
    assert r["fc_rain_prob_day1"] == 90.0
    assert math.isnan(r["met_rain_class_day1"]) and math.isnan(r["met_warning_level"])


def test_no_leakage_a_forecast_made_after_t_is_never_used():
    early = _om(T0 - pd.Timedelta(hours=6), {h: 1.0 for h in range(1, 79)})
    late = _om(T0 + pd.Timedelta(hours=1), {h: 50.0 for h in range(1, 79)})  # made after t
    f = weather_features(_q(T0), {"openmeteo": pd.concat([early, late])})
    assert f.iloc[0]["fc_rain_next_3h"] == 3.0
    assert f.iloc[0]["fc_rain_day1_mm"] == 24.0


def test_latest_forecast_issued_by_t_wins():
    old = _om(T0 - pd.Timedelta(hours=12), {h: 1.0 for h in range(1, 85)})
    new = _om(T0, {h: 2.0 for h in range(1, 73)})
    f = weather_features(_q(T0, T0 - pd.Timedelta(hours=6)), {"openmeteo": pd.concat([old, new])})
    assert f.iloc[0]["fc_rain_next_3h"] == 6.0  # from the forecast made at t
    assert f.iloc[1]["fc_rain_next_3h"] == 3.0  # at t-6h only the older one existed


def test_backfilled_rows_give_each_lead_day_its_own_forecast():
    # backfill format: the hour v forecast 1, 2, 3 days before (issued_at = v - N days)
    rows = []
    for k in range(1, 73):
        v = T0 + pd.Timedelta(hours=k)
        for n in (1, 2, 3):
            rows.append({"station_code": "S", "issued_at": v - pd.Timedelta(days=n), "valid_at": v,
                         "precip_mm": float(n), "prob_pct": 50.0, "n_models": 8, "om_prob_pct": np.nan})
    f = weather_features(_q(T0), {"openmeteo": pd.DataFrame(rows)})
    # day 1 can use the 1-day-ahead forecast; day 2 needs one made >= 2 days before; day 3 >= 3 days
    assert (f.iloc[0]["fc_rain_day1_mm"], f.iloc[0]["fc_rain_day2_mm"], f.iloc[0]["fc_rain_day3_mm"]) == (24, 48, 72)


def test_missing_hours_leave_the_day_empty():
    f = weather_features(_q(T0), {"openmeteo": _om(T0, {h: 1.0 for h in range(1, 10)})})
    assert f.iloc[0]["fc_rain_next_3h"] == 3.0
    assert math.isnan(f.iloc[0]["fc_rain_day1_mm"]) and math.isnan(f.iloc[0]["fc_rain_days_3d"])


def test_met_classes_warning_and_agreement():
    om = _om(T0, {h: (1.0 if h <= 24 else 0.0) for h in range(1, 73)})
    issued = T0 - pd.Timedelta(hours=1)
    dates = [(T0 + pd.Timedelta(hours=24 * (d - 1) + 12)).tz_convert("Asia/Kuala_Lumpur").strftime("%Y-%m-%d")
             for d in (1, 2, 3)]
    met = pd.DataFrame([{"station_code": "S", "issued_at": issued, "valid_date": dates[0], "rain_class": 3, "thunder": 1},
                        {"station_code": "S", "issued_at": issued, "valid_date": dates[1], "rain_class": 0, "thunder": 0},
                        {"station_code": "S", "issued_at": issued, "valid_date": dates[2], "rain_class": 2, "thunder": 1}])
    warn = pd.DataFrame([{"station_code": "S", "issued_at": issued, "valid_from": T0 + pd.Timedelta(hours=5),
                          "valid_to": T0 + pd.Timedelta(hours=30), "kind": "continuous_rain", "level": 2, "title": "x"}])
    f = weather_features(_q(T0, T0 - pd.Timedelta(hours=3)),
                         {"openmeteo": om, "met": met, "met_warning": warn}).iloc[0]
    assert (f["met_rain_class_day1"], f["met_rain_class_day2"], f["met_rain_class_day3"]) == (3, 0, 2)
    assert f["met_thunder_days_3d"] == 2
    assert f["met_warning_level"] == 2
    # day 1 both wet, day 2 both dry, day 3 Open-Meteo dry but MET rain
    assert f["sources_agree_days_3d"] == 2


def test_no_weather_means_empty_inputs(stations, clean):
    f = build_features(clean, stations)
    assert f[FORECAST_FEATURES].isna().all().all()
    from flood_ml.features import HISTORY_FEATURES
    from flood_ml.weather import FILL_INTERACTION
    assert FEATURES == BASE_FEATURES + HISTORY_FEATURES + FORECAST_FEATURES + [FILL_INTERACTION]


def test_peak_rise_target():
    level = pd.Series([1.0, 1.2, 1.5, 1.1, 1.0, np.nan])
    r = peak_rise(level, 3)
    assert r.iloc[0] == pytest.approx(0.5)   # highest of 1.2, 1.5, 1.1
    assert r.iloc[1] == pytest.approx(0.3)
    assert math.isnan(r.iloc[4])             # fewer than 75% of the hours ahead


@pytest.fixture(scope="module")
def weather_feats(raw, clean, stations):
    weather = make_practice_weather(raw)
    return weather, build_features(clean, stations, weather=weather)


def test_more_forecast_rain_never_lowers_the_forecast(weather_feats):
    _, feats = weather_feats
    train, test, _ = time_split(feats)
    m = TreeEnsemble.fit(train, fast=True, features=FEATURES)
    rows = test.dropna(subset=["fc_rain_day1_mm"]).head(200).copy()
    before = m.predict(rows)
    for col in ("fc_rain_next_3h", "fc_rain_day1_mm", "fc_rain_total_3d"):
        rows[col] = rows[col] + 40.0
    assert np.all(m.predict(rows) >= before - 1e-9)
    assert "sources_agree_days_3d" not in RAISES_ONLY


def test_forecast_inputs_are_explained_and_add_up(weather_feats, clean, stations):
    weather, feats = weather_feats
    train, _, _ = time_split(feats)
    m = TreeEnsemble.fit(train, fast=True, features=FEATURES)
    now = pd.Timestamp("2026-11-17T03:00:00Z")
    fc = make_forecast(m, clean, stations, now, 0.1, True, weather=weather, input_set="observed + 3-day forecast")
    assert fc["schema"] == 2 and fc["inputs"]["weather_forecast_used"] is True
    for e in fc["stations"]:
        names = {f["feature"] for f in e["factors"]}
        assert set(FORECAST_FEATURES) <= names
        total = e["base_change_m"] + sum(f["impact_m"] for f in e["factors"])
        assert math.isclose(total, e["predicted_level_m"] - e["current_level_m"], abs_tol=0.005)
        assert e["rain_outlook"] is not None and e["rain_outlook"]["day1_mm"] is not None


def test_choose_inputs_without_weather_uses_no_forecast_input(trained):
    name, cols, _ = choose_inputs(trained["train"])
    assert not set(cols) & set(FORECAST_FEATURES)
    assert set(BASE_FEATURES) <= set(cols)


def test_choose_inputs_picks_a_set_on_validation(weather_feats):
    _, feats = weather_feats
    train, _, _ = time_split(feats)
    name, cols, scores = choose_inputs(train)
    from flood_ml.scoring import choose
    from flood_ml.train import RESIDUAL
    assert set(scores) <= set(INPUT_SETS) | {RESIDUAL}
    assert name == choose(scores)
    assert scores[name]["mae_m"] <= min(v["mae_m"] for v in scores.values()) * 1.05 + 1e-12


def test_peak_targets_are_built(weather_feats):
    _, feats = weather_feats
    for col in PEAK_TARGETS.values():
        assert feats[col].notna().sum() > 1000
