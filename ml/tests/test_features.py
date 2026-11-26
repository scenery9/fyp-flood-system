import numpy as np
import pandas as pd
import pytest

from flood_ml.features import (FEATURES, HORIZON_H, LINEAR_TREND, TARGET, UPSTREAM_FEATURES, build_features,
                               clean_readings, risk_level, validate_stations)
from flood_ml.practice_data import make_practice_readings

ST = [{"id": "A", "normal": 10.0, "alert": 12.0, "warning": 14.0, "danger": 16.0}]


def frame(levels, rain=None, start="2026-01-01T00:00:00Z", sid="A"):
    t = pd.date_range(start, periods=len(levels), freq="h")
    return pd.DataFrame({"station_id": sid, "time": t,
                         "rainfall_mm": rain if rain is not None else [0.0] * len(levels),
                         "river_level_m": levels})


# ML1 cleaning
def test_fault_codes_become_missing():
    c = clean_readings(frame([10, -9999, -9999, -9999, 10.4], rain=[1, -9999, -8888, -1, 2]))
    assert c["river_level_m"].isna().sum() == 1  # 3-hour gap: only 2 hours are filled
    assert c["rainfall_mm"].isna().sum() == 3


def test_short_gaps_filled_long_gaps_left():
    c = clean_readings(frame([10.0, np.nan, np.nan, 10.3]))
    assert np.allclose(c["river_level_m"], [10.0, 10.1, 10.2, 10.3])
    c = clean_readings(frame([10.0, np.nan, np.nan, np.nan, 10.4]))
    assert c["river_level_m"].isna().sum() == 1


def test_missing_hours_are_restored_and_duplicates_removed():
    df = frame([10.0, 10.1, 10.2, 10.3]).drop(index=1)
    df = pd.concat([df, df.iloc[[0]].assign(river_level_m=11.0)])
    c = clean_readings(df)
    assert len(c) == 4
    assert c["river_level_m"].iloc[0] == 11.0  # last duplicate wins


def test_half_hourly_readings_become_hourly():
    t = pd.date_range("2026-01-01T00:00:00Z", periods=4, freq="30min")
    df = pd.DataFrame({"station_id": "A", "time": t, "rainfall_mm": [1, 2, 3, 4], "river_level_m": [10, 10.1, 10.2, 10.3]})
    c = clean_readings(df)
    assert list(c["rainfall_mm"]) == [3, 7]
    assert list(c["river_level_m"]) == [10.1, 10.3]


def test_text_and_empty_input_do_not_crash():
    c = clean_readings(frame(["10.0", "bad", "10.2"]))
    assert c["river_level_m"].iloc[2] == 10.2
    assert len(clean_readings(frame([]))) == 0


# ML15 0.00 m glitches; levels below 0 are kept
def test_isolated_zero_is_a_glitch_but_zero_with_the_tide_and_negatives_are_real():
    t = pd.date_range("2026-11-19T22:00:00Z", periods=5, freq="15min")
    raw = pd.concat([
        pd.DataFrame({"station_id": "A", "time": t, "rainfall_mm": 0.0,
                      "river_level_m": [42.86, 42.86, 0.0, 42.87, 42.86]}),      # glitch
        pd.DataFrame({"station_id": "B", "time": t, "rainfall_mm": 0.0,
                      "river_level_m": [0.11, 0.05, 0.0, -0.04, -0.10]}),        # tide passing 0
        pd.DataFrame({"station_id": "C", "time": t, "rainfall_mm": 0.0,
                      "river_level_m": [-1.77, -1.60, -1.40, -1.20, -1.11]}),    # below 0 all along
    ])
    from flood_ml.features import drop_zero_glitches
    a = drop_zero_glitches(raw[raw.station_id == "A"].set_index("time")["river_level_m"])
    assert a.isna().sum() == 1 and np.isnan(a.iloc[2])
    b = drop_zero_glitches(raw[raw.station_id == "B"].set_index("time")["river_level_m"])
    assert b.iloc[2] == 0.0
    c = clean_readings(raw)
    assert (c[c.station_id == "C"]["river_level_m"] < 0).all()
    # hourly: A's 22:00 hour ends at 22:45 = 42.86, and no hour is pulled to 0
    assert c[c.station_id == "A"]["river_level_m"].min() > 42


def test_small_v_shaped_spike_to_zero_is_a_glitch_but_a_flat_low_tide_is_not():
    from flood_ml.features import drop_zero_glitches
    t = pd.to_datetime(["2026-11-22T16:10:00Z", "2026-11-22T16:25:00Z", "2026-11-22T16:40:00Z"])
    assert np.isnan(drop_zero_glitches(pd.Series([0.21, 0.0, 0.20], index=t)).iloc[1])
    assert drop_zero_glitches(pd.Series([0.05, 0.0, 0.06], index=t)).iloc[1] == 0.0  # low tide, near 0
    assert drop_zero_glitches(pd.Series([0.11, 0.0, -0.10], index=t)).iloc[1] == 0.0  # crossing 0
    hours = pd.to_datetime(["2026-11-22T14:00:00Z", "2026-11-22T16:00:00Z", "2026-11-22T18:00:00Z"])
    assert drop_zero_glitches(pd.Series([0.25, 0.0, 0.28], index=hours)).iloc[1] == 0.0  # slow real low tide


def test_zero_with_nothing_near_it_is_kept():
    from flood_ml.features import drop_zero_glitches
    s = pd.Series([5.0, 0.0], index=pd.to_datetime(["2026-11-19T10:00:00Z", "2026-11-19T22:00:00Z"]))
    assert drop_zero_glitches(s).iloc[1] == 0.0


# ML2 features and target
def test_feature_values():
    c = clean_readings(frame([10.0, 10.5, 11.0, 12.0, 12.5, 13.0], rain=[1, 2, 3, 4, 5, 6]))
    f = build_features(c, ST)
    r = f.iloc[3]
    assert r["level_above_normal"] == 2.0
    assert r["level_change_1h"] == 1.0
    assert r["level_change_3h"] == 2.0
    assert r["rain_sum_1h"] == 4
    assert r["rain_sum_3h"] == 9
    assert np.isnan(r["rain_sum_6h"])  # not enough history yet
    assert f.iloc[5]["rain_sum_6h"] == 21


# ML14 "same time one cycle ago" inputs (tide)
def test_same_time_inputs_repeat_what_the_river_did_one_cycle_ago():
    hours = np.arange(60)
    levels = list(1.5 + 0.8 * np.sin(2 * np.pi * hours / 12))  # a 12-hour tide
    f = build_features(clean_readings(frame(levels)), ST)
    lv = np.array(levels)
    t = 30
    assert np.isclose(f["same_time_12h_ago"].iloc[t], lv[t - 9] - lv[t - 12])
    assert np.isclose(f["same_time_25h_ago"].iloc[t], lv[t - 22] - lv[t - 25])
    # with an exact 12-hour tide, one cycle ago predicts the next 3 hours exactly
    assert np.isclose(f["same_time_12h_ago"].iloc[t], f[TARGET].iloc[t])
    assert np.isnan(f["same_time_12h_ago"].iloc[11]) and np.isnan(f["same_time_25h_ago"].iloc[24])
    assert not np.isnan(f["same_time_25h_ago"].iloc[25])


def test_target_is_change_three_hours_ahead():
    f = build_features(clean_readings(frame([10.0, 10.5, 11.0, 12.0, 12.5, 13.0])), ST)
    assert HORIZON_H == 3
    assert f[TARGET].iloc[0] == 2.0
    assert f[TARGET].iloc[2] == 2.0
    assert f[TARGET].iloc[3:].isna().all()  # future unknown


def test_no_leakage_future_changes_do_not_alter_features():
    levels = list(np.linspace(10, 12, 40))
    a = build_features(clean_readings(frame(levels, rain=[1.0] * 40)), ST)
    changed = levels[:30] + [99.0] * 10
    b = build_features(clean_readings(frame(changed, rain=[1.0] * 30 + [50.0] * 10)), ST)
    pd.testing.assert_frame_equal(a[FEATURES].iloc[:30], b[FEATURES].iloc[:30])


def test_stations_do_not_mix():
    two = pd.concat([frame([10.0, 10.1, 10.2, 10.3]), frame([50.0, 50.0, 50.0, 50.0], sid="B")])
    st = ST + [{"id": "B", "normal": 49.0, "alert": 51.0, "warning": 52.0, "danger": 53.0}]
    f = build_features(clean_readings(two), st)
    b = f[f["station_id"] == "B"]
    assert np.isnan(b["level_change_1h"].iloc[0])  # no value borrowed from station A
    assert (b["level_above_normal"] == 1.0).all()


def test_unknown_station_is_skipped():
    assert len(build_features(clean_readings(frame([1.0, 2.0], sid="ZZZ")), ST)) == 0


def test_risk_level_boundaries():
    s = ST[0]
    assert [risk_level(v, s) for v in (11.99, 12, 13.99, 14, 15.99, 16)] == [0, 1, 1, 2, 2, 3]


# ML3 practice data
def test_practice_data_is_repeatable_and_has_events(stations):
    end = pd.Timestamp("2026-11-17T03:00:00Z")
    a = make_practice_readings(stations, end=end, days=30)
    b = make_practice_readings(stations, end=end, days=30)
    pd.testing.assert_frame_equal(a, b)
    assert a["time"].max() == end
    assert (a["river_level_m"] == -9999).any()
    assert set(a["station_id"]) == {s["id"] for s in stations}


# ML7 upstream inputs
UP = [
    {"id": "DOWN", "normal": 10.0, "alert": 12.0, "warning": 14.0, "danger": 16.0, "upstream": ["U1", "U2"]},
    {"id": "U1", "normal": 5.0, "alert": 6.0, "warning": 7.0, "danger": 8.0},
    {"id": "U2", "normal": 5.0, "alert": 6.0, "warning": 7.0, "danger": 8.0},
]


def three(down, u1, u2, rain_u1=None, rain_u2=None):
    return clean_readings(pd.concat([
        frame(down, sid="DOWN"),
        frame(u1, rain=rain_u1, sid="U1"),
        frame(u2, rain=rain_u2, sid="U2"),
    ]))


def test_upstream_features_are_the_average_of_upstream_stations():
    n = 8
    f = build_features(three([10.0] * n, list(np.arange(n) * 0.1 + 5), list(np.arange(n) * 0.3 + 5),
                             rain_u1=[2.0] * n, rain_u2=[4.0] * n), UP)
    d = f[f["station_id"] == "DOWN"].iloc[6]
    assert np.isclose(d["up_level_change_1h"], 0.2)  # mean of 0.1 and 0.3
    assert np.isclose(d["up_level_change_3h"], 0.6)
    assert np.isclose(d["up_rain_sum_3h"], 9.0)  # mean of 6 and 12
    assert np.isclose(d["up_rain_sum_6h"], 18.0)


def test_station_without_upstream_has_empty_upstream_features():
    f = build_features(three([10.0] * 8, [5.0] * 8, [5.0] * 8), UP)
    assert f[f["station_id"] == "U1"][UPSTREAM_FEATURES].isna().all().all()


def test_missing_upstream_station_uses_the_other_one():
    c = clean_readings(pd.concat([frame([10.0] * 8, sid="DOWN"), frame(list(np.arange(8) * 0.1 + 5), sid="U1")]))
    d = build_features(c, UP)
    d = d[d["station_id"] == "DOWN"].iloc[6]
    assert np.isclose(d["up_level_change_1h"], 0.1)


def test_no_leakage_from_future_upstream_readings():
    n = 40
    base = list(np.linspace(5, 6, n))
    a = build_features(three([10.0] * n, base, base, [1.0] * n, [1.0] * n), UP)
    later = base[:30] + [99.0] * 10
    b = build_features(three([10.0] * n, later, later, [1.0] * 30 + [80.0] * 10, [1.0] * n), UP)
    a, b = a[a["station_id"] == "DOWN"], b[b["station_id"] == "DOWN"]
    pd.testing.assert_frame_equal(a[FEATURES].iloc[:30].reset_index(drop=True),
                                  b[FEATURES].iloc[:30].reset_index(drop=True))


def test_bad_station_files_are_rejected():
    with pytest.raises(ValueError, match="itself"):
        validate_stations([{**ST[0], "upstream": ["A"]}])
    with pytest.raises(ValueError, match="not in the file"):
        validate_stations([{**ST[0], "upstream": ["NOPE"]}])
    with pytest.raises(ValueError, match="twice"):
        validate_stations(ST + ST)
    with pytest.raises(ValueError, match="order"):
        validate_stations([{**ST[0], "alert": 9.0}])
    validate_stations(UP)


def test_station_files_in_the_project_are_valid():
    from pathlib import Path
    root = Path(__file__).resolve().parent.parent
    files = {name: __import__("json").loads((root / name).read_text(encoding="utf-8"))
             for name in ("stations.json", "stations_klang.json", "stations_training.json")}
    for stations in files.values():
        validate_stations(stations)
    # the Selangor file keeps the Klang stations (with their upstream links) unchanged
    assert files["stations_training.json"][:3] == files["stations_klang.json"]


# ML8 straight-line baseline (the existing FloodWatch app's method)
def test_straight_line_continues_a_steady_rise():
    f = build_features(clean_readings(frame([10.0, 10.1, 10.2, 10.3, 10.4, 10.5])), ST)
    assert np.isnan(f[LINEAR_TREND].iloc[2])  # fewer than 4 readings so far
    assert np.isclose(f[LINEAR_TREND].iloc[3], 0.3)  # 0.1 m/h for 3 more hours
    assert np.isclose(f[LINEAR_TREND].iloc[5], 0.3)


def test_straight_line_ignores_tiny_changes():
    f = build_features(clean_readings(frame([10.0, 10.01, 10.02, 10.03])), ST)
    assert f[LINEAR_TREND].iloc[3] == 0.0  # 0.01 m/h is below 0.02 m/h


def test_straight_line_is_not_a_model_input():
    assert LINEAR_TREND not in FEATURES
