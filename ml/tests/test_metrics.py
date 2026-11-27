"""ML11 prediction metrics (metrics.py), checked on hand-worked numbers."""
import numpy as np
import pandas as pd
import pytest

from flood_ml.metrics import NAMES, forecast_metrics

T = "y"


def rows(levels_now, change, station="A"):
    return pd.DataFrame({"station_id": station, "river_level_m": levels_now, T: change})


def test_perfect_forecast():
    r = rows([1.0, 1.2, 1.5, 1.1], [0.2, 0.3, -0.4, 0.0])
    m = forecast_metrics(r[T], r, T)
    assert m["mae_m"] == 0 and m["rmse_m"] == 0 and m["bias_m"] == 0 and m["peak_error_m"] == 0
    assert m["nse"] == 1 and m["willmott_d"] == 1 and m["persistence_index"] == 1


def test_no_change_forecast_has_persistence_index_zero():
    r = rows([1.0, 1.2, 1.5, 1.1], [0.2, 0.3, -0.4, 0.1])
    m = forecast_metrics(np.zeros(4), r, T)
    assert m["persistence_index"] == pytest.approx(0.0)


def test_hand_worked_values():
    # actual levels 2, 3, 4; predicted 2.5, 3, 3.5
    r = rows([2.0, 3.0, 4.0], [0.0, 0.0, 0.0])
    m = forecast_metrics([0.5, 0.0, -0.5], r, T)
    assert m["mae_m"] == pytest.approx(1 / 3)
    assert m["rmse_m"] == pytest.approx(np.sqrt(0.5 / 3))
    assert m["bias_m"] == pytest.approx(0.0)
    assert m["nse"] == pytest.approx(1 - 0.5 / 2.0)  # SST = 1 + 0 + 1
    assert m["willmott_d"] == pytest.approx(1 - 0.5 / ((0.5 + 1) ** 2 * 2))
    assert m["peak_error_m"] == pytest.approx(0.5)  # at the highest actual level (4 m)
    assert m["persistence_index"] is None  # the river did not move: undefined


def test_nse_does_not_depend_on_the_station_datum():
    """Two stations with the same errors but datums 2 m and 20 m apart: NSE stays the
    same as for one station on its own (it is worked out within each station)."""
    a = rows([1.0, 1.4, 1.2], [0.2, -0.1, 0.3], "A")
    b = rows([19.0, 19.4, 19.2], [0.2, -0.1, 0.3], "B")
    pred = [0.1, 0.0, 0.2]
    one = forecast_metrics(pred, a, T)
    both = forecast_metrics(pred * 2, pd.concat([a, b], ignore_index=True), T)
    assert both["nse"] == pytest.approx(one["nse"])
    assert both["willmott_d"] == pytest.approx(one["willmott_d"])


def test_too_high_forecast_gives_positive_bias():
    r = rows([1.0, 1.0], [0.1, 0.2])
    assert forecast_metrics([0.3, 0.4], r, T)["bias_m"] == pytest.approx(0.2)


def test_every_metric_is_named():
    r = rows([1.0, 1.2], [0.1, 0.0])
    assert set(NAMES) <= set(forecast_metrics([0.0, 0.0], r, T))
