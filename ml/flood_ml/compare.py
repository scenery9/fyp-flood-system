"""Compare many forecasting methods on the SAME data, inputs and time split.

Every method predicts the change in river level over the next 3 hours from the
same inputs (FEATURES that have at least one value in the training rows: the
weather-forecast inputs are empty without logged forecasts), is trained on the same oldest 80% of hours and is
scored on the same newest 20%, with the same metrics:
MAE, RMSE, NSE, Willmott's d, persistence index, bias and peak error (metrics.py),
plus skill vs "no change" on MAE.

Methods:
  baselines   no change; FloodWatch straight-line trend
  classical   ridge regression; SVR; k-nearest neighbours
  ensembles   random forest; extra trees; histogram gradient boosting
  neural      MLP; LSTM and GRU (only when PyTorch is installed)
  members     XGBoost, LightGBM, CatBoost, random forest, each on its own
  ours        their weighted ensemble (the model the app uses, explained with TreeSHAP)

Practice data (numbers are NOT results):
    python -m flood_ml.compare --practice
Real readings:
    python -m flood_ml.compare --stations stations_klang.json --readings readings.csv
Writes <out>/comparison.json.
"""
import argparse
import json
import time
from pathlib import Path

import numpy as np
import pandas as pd

from .features import FEATURES, HORIZON_H, TARGET, build_features, clean_readings, validate_stations
from .practice_data import make_practice_readings
from .ensemble import MEMBER_NAMES, MEMBERS, TreeEnsemble, make_member
from .train import high_water_metrics, linear_trend_prediction, regression_metrics, time_split

HERE = Path(__file__).resolve().parent.parent
SEED = 7
OURS = "Weighted tree ensemble + TreeSHAP (FloodReady)"
SEQ_HOURS = 12  # LSTM/GRU look at the last 12 hourly input rows of the station


def _sklearn_models(fast):
    from sklearn.ensemble import ExtraTreesRegressor, HistGradientBoostingRegressor, RandomForestRegressor
    from sklearn.impute import SimpleImputer
    from sklearn.linear_model import Ridge
    from sklearn.neighbors import KNeighborsRegressor
    from sklearn.neural_network import MLPRegressor
    from sklearn.pipeline import make_pipeline
    from sklearn.preprocessing import StandardScaler
    from sklearn.svm import SVR

    # Upstream inputs are empty for stations without upstream stations, so
    # models that cannot take NaN get 0 plus a "was missing" flag.
    def imputed(est):
        return make_pipeline(SimpleImputer(strategy="constant", fill_value=0, add_indicator=True), est)

    def scaled(est):
        return make_pipeline(SimpleImputer(strategy="constant", fill_value=0, add_indicator=True),
                             StandardScaler(), est)

    trees = 40 if fast else 300
    return [
        ("Ridge regression", "classical", scaled(Ridge(alpha=1.0))),
        ("Support vector regression (RBF)", "classical", scaled(SVR(C=1.0, epsilon=0.005))),
        ("k-nearest neighbours", "classical", scaled(KNeighborsRegressor(n_neighbors=10, weights="distance"))),
        ("Random forest", "ensemble", imputed(RandomForestRegressor(
            n_estimators=trees, min_samples_leaf=3, n_jobs=-1, random_state=SEED))),
        ("Extra trees", "ensemble", imputed(ExtraTreesRegressor(
            n_estimators=trees, min_samples_leaf=3, n_jobs=-1, random_state=SEED))),
        ("Histogram gradient boosting", "ensemble", HistGradientBoostingRegressor(
            max_iter=60 if fast else 300, learning_rate=0.05, random_state=SEED)),
        ("MLP neural network", "neural", scaled(MLPRegressor(
            hidden_layer_sizes=(64, 32), max_iter=60 if fast else 300, early_stopping=True,
            random_state=SEED))),
    ]


def _sequences(feats_all, rows, mean, std, cols):
    """For each row, the last SEQ_HOURS rows of the same station (scaled, NaN -> 0),
    zero-padded at the start when there is less history. Rows of one station are
    consecutive and in time order in build_features' output."""
    x = ((feats_all[cols] - mean) / std).fillna(0.0).to_numpy(dtype=np.float32)
    first = feats_all.groupby("station_id").cumcount().to_numpy()  # position within station
    out = np.zeros((len(rows), SEQ_HOURS, len(cols)), dtype=np.float32)
    for k, i in enumerate(rows.index.to_numpy()):
        n = min(SEQ_HOURS, first[i] + 1)
        out[k, SEQ_HOURS - n:] = x[i - n + 1:i + 1]
    return out


def _recurrent(kind, train, test, feats_all, fast, cols):
    import torch

    torch.manual_seed(SEED)
    mean, std = train[cols].mean(), train[cols].std().replace(0, 1).fillna(1)
    y_scale = float(train[TARGET].std()) or 1.0
    x_tr = torch.from_numpy(_sequences(feats_all, train, mean, std, cols))
    y_tr = torch.from_numpy((train[TARGET].to_numpy() / y_scale).astype(np.float32))
    x_te = torch.from_numpy(_sequences(feats_all, test, mean, std, cols))

    class Net(torch.nn.Module):
        def __init__(self):
            super().__init__()
            rnn = torch.nn.LSTM if kind == "LSTM" else torch.nn.GRU
            self.rnn = rnn(len(cols), 32, batch_first=True)
            self.out = torch.nn.Linear(32, 1)

        def forward(self, x):
            h, _ = self.rnn(x)
            return self.out(h[:, -1]).squeeze(-1)

    net = Net()
    opt = torch.optim.Adam(net.parameters(), lr=1e-3)
    loss_fn = torch.nn.MSELoss()
    gen = torch.Generator().manual_seed(SEED)
    for _ in range(3 if fast else 20):
        net.train()
        for idx in torch.randperm(len(x_tr), generator=gen).split(256):
            opt.zero_grad()
            loss = loss_fn(net(x_tr[idx]), y_tr[idx])
            loss.backward()
            opt.step()
    net.eval()
    with torch.no_grad():
        return net(x_te).numpy().astype(float) * y_scale


def _score(name, kind, pred, test, stations, seconds):
    return {"name": name, "kind": kind, **regression_metrics(pred, test),
            "high_water": high_water_metrics(pred, test), "fit_seconds": round(seconds, 2)}


def compare(feats_all, stations, fast=False):
    """feats_all: build_features() output. Returns the comparison dict."""
    feats_all = feats_all.reset_index(drop=True)  # row labels = positions, for _sequences
    train, test, cutoff = time_split(feats_all)
    if len(train) < 200 or len(test) < 50:
        raise SystemExit(f"Not enough data to compare (train={len(train)}, test={len(test)} rows)")
    cols = [f for f in FEATURES if train[f].notna().any()]  # some methods cannot take an all-empty input
    results = [
        _score("No change (persistence)", "baseline", np.zeros(len(test)), test, stations, 0.0),
        _score("Straight-line trend (FloodWatch)", "baseline", linear_trend_prediction(test)[0],
               test, stations, 0.0),
    ]
    for name, kind, est in _sklearn_models(fast):
        t0 = time.perf_counter()
        est.fit(train[cols], train[TARGET])
        pred = est.predict(test[cols])
        results.append(_score(name, kind, pred, test, stations, time.perf_counter() - t0))
    for kind in ("LSTM", "GRU"):
        try:
            import torch  # noqa: F401
        except ImportError:
            results.append({"name": kind, "kind": "neural", "skipped": "PyTorch not installed"})
            continue
        t0 = time.perf_counter()
        pred = _recurrent(kind, train, test, feats_all, fast, cols)
        results.append(_score(kind, "neural", pred, test, stations, time.perf_counter() - t0))
    for name in MEMBERS:  # each ensemble member on its own
        t0 = time.perf_counter()
        m = make_member(name, fast).fit(train[cols], train[TARGET])
        results.append(_score(f"{MEMBER_NAMES[name]} (single model)", "ensemble member",
                              m.predict(test[cols]), test, stations, time.perf_counter() - t0))
    t0 = time.perf_counter()
    model = TreeEnsemble.fit(train, fast=fast, features=cols)
    results.append(_score(OURS, "ours", model.predict(test), test, stations, time.perf_counter() - t0)
                   | {"weights": model.describe()["weights"], "chosen": model.describe()["chosen"]})
    return {
        "horizon_hours": HORIZON_H,
        "features": cols,
        "train_rows": int(len(train)),
        "test_rows": int(len(test)),
        "test_from": cutoff.isoformat(),
        "models": results,
    }


def _fmt(v, digits=3):
    return "-" if v is None else f"{v:.{digits}f}"


def print_table(result):
    scored = sorted((m for m in result["models"] if "skipped" not in m), key=lambda m: m["mae_m"])
    print(f"{'Method':48} {'MAE m':>7} {'RMSE m':>7} {'NSE':>6} {'d':>6} {'PI':>6} {'Bias m':>7} {'Peak m':>7}")
    for m in scored:
        print(f"{m['name']:48} {_fmt(m['mae_m']):>7} {_fmt(m['rmse_m']):>7} {_fmt(m['nse']):>6} "
              f"{_fmt(m['willmott_d']):>6} {_fmt(m['persistence_index']):>6} {_fmt(m['bias_m']):>7} "
              f"{_fmt(m['peak_error_m']):>7}")
    for m in result["models"]:
        if "skipped" in m:
            print(f"{m['name']:48} skipped: {m['skipped']}")
        if "chosen" in m:
            print(f"{m['name']}: chosen on validation = {m['chosen']}")


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--practice", action="store_true")
    p.add_argument("--readings")
    p.add_argument("--stations", default=str(HERE / "stations.json"))
    p.add_argument("--out", default=str(HERE / "output"))
    p.add_argument("--fast", action="store_true", help="smaller models, for a quick check")
    a = p.parse_args()
    if a.practice == bool(a.readings):
        raise SystemExit("Choose one: --practice or --readings FILE")
    stations = json.loads(Path(a.stations).read_text())
    validate_stations(stations)
    raw = (make_practice_readings(stations, end=pd.Timestamp.now(tz="UTC")) if a.practice
           else pd.read_csv(a.readings))
    result = compare(build_features(clean_readings(raw), stations), stations, fast=a.fast)
    result["is_practice_data"] = bool(a.practice)
    out = Path(a.out)
    out.mkdir(parents=True, exist_ok=True)
    (out / "comparison.json").write_text(json.dumps(result, indent=2))
    if a.practice:
        print("PRACTICE DATA - not a real result. Do not report these numbers.")
    print_table(result)
    print(f"Written to {out / 'comparison.json'}")


if __name__ == "__main__":
    main()
