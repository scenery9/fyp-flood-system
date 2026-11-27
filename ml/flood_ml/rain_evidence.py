"""Evidence, from the real logs only, for using the 3-day rain forecast in the flood forecast.

    python -m flood_ml.rain_evidence --readings readings.csv --stations stations_training.json \
        --archive ../data --forecast ../data/forecast --out output --doc ../docs/rain-forecast-evidence.md

readings.csv comes from `python -m jps_logger.export --no-database` (the JPS archive).
Nothing here uses practice data. Four parts:

1. Forecast skill: Open-Meteo's daily rain (made 1, 2 and 3 days ahead) against
   the JPS rain gauge at the same station, per Malaysia day. Rain day >= 1 mm,
   heavy >= 10 mm, very heavy >= 20 mm (ETCCDI). Hits, misses, false alarms, POD,
   FAR, CSI, bias, MAE, Brier score. MET Malaysia is scored the same way once
   its logged forecasts overlap the JPS archive.
2. Does more forecast rain go with a bigger river rise? One sample per station
   per day (forecast made at 08:00 Malaysia time, so samples are not hour-by-hour
   copies of each other): the share of station-days in each forecast band whose
   river rose >= 0.3 m, or reached Alert, in the next 24 h / 72 h. 95% Wilson intervals.
3. With / without the weather forecast: the same tree ensemble, same time split,
   for 3 h, 24 h and 72 h ahead. MAE, RMSE, NSE, Willmott's d, persistence index (metrics.py).
   95% interval of the MAE difference by resampling whole station-days (bootstrap).
4. TreeSHAP: the share of the forecast explained by each group of inputs.
The numbers are whatever the data give; with only a few days logged, the intervals are wide.
"""
import argparse
import json
from pathlib import Path

import numpy as np
import pandas as pd

from .ensemble import TreeEnsemble
from .features import (HORIZON_H, PEAK_TARGETS, TARGET, build_features, clean_readings,
                       validate_stations)
from .probability import HEADLINE, LABEL, LEVELS, ChanceModel, add_label, brier, reliability
from .scoring import choose, flood_scores, high_water
from .train import candidate_sets, choose_inputs, fit_candidate
from .weather import FORECAST_FEATURES, RAIN_DAY_MM, load_weather

MYT = "Asia/Kuala_Lumpur"
THRESHOLDS_MM = {"rain day (>= 1 mm)": 1.0, "heavy (>= 10 mm)": 10.0, "very heavy (>= 20 mm)": 20.0}
BANDS = [(0, 1, "< 1 mm (dry)"), (1, 10, "1-10 mm"), (10, 20, "10-20 mm (heavy)"), (20, np.inf, ">= 20 mm (very heavy)")]
RISE_M = 0.3
MIN_GAUGE_READINGS = 72  # of 96 quarter-hours: a gauge-day with fewer is left out
SEED = 7

GROUPS = {
    "river level now and its recent change": ["level_above_normal", "level_change_1h", "level_change_2h", "level_change_3h",
                                              "same_time_12h_ago", "same_time_25h_ago"],
    "rain measured at the station (past)": ["rain_sum_1h", "rain_sum_3h", "rain_sum_6h", "rain_sum_24h",
                                            "rain_sum_72h"],
    "upstream stations (past)": ["up_level_change_1h", "up_level_change_3h", "up_rain_sum_3h", "up_rain_sum_6h"],
    "forecast: next 3 hours": ["fc_rain_next_3h", "fc_rain_prob_next_3h"],
    "forecast: days 1-3 (Open-Meteo)": ["fc_rain_day1_mm", "fc_rain_day2_mm", "fc_rain_day3_mm",
                                        "fc_rain_prob_day1", "fc_rain_prob_day2", "fc_rain_prob_day3",
                                        "fc_rain_days_3d", "fc_rain_total_3d"],
    "rain history (wet hours, wet days, API)": ["wet_hours_24h", "consecutive_wet_hours", "wet_days_3d", "api_7d"],
    "forecast x how full the river is": ["fc_rain_day1_x_fill"],
    "forecast: MET Malaysia and agreement": ["met_rain_class_day1", "met_rain_class_day2", "met_rain_class_day3",
                                             "met_thunder_days_3d", "met_warning_level", "sources_agree_days_3d"],
}


def wilson(k, n, z=1.96):
    """95% Wilson score interval for k successes in n trials (None if n = 0)."""
    if n == 0:
        return None, None
    p = k / n
    d = 1 + z * z / n
    c = (p + z * z / (2 * n)) / d
    h = z * np.sqrt(p * (1 - p) / n + z * z / (4 * n * n)) / d
    return round(float(c - h), 4), round(float(c + h), 4)


# ---------- 1. forecast skill against the gauges ----------

def gauge_days(archive_root):
    """Observed rain per JPS gauge per Malaysia day: the day's last today_mm
    (rain since midnight), for days with at least MIN_GAUGE_READINGS readings."""
    paths = sorted(Path(archive_root).glob("[0-9][0-9][0-9][0-9]/*/*.csv.gz"))
    df = pd.concat([pd.read_csv(p, compression="gzip", dtype={"station_code": str}) for p in paths],
                   ignore_index=True)
    rain = df[(df["kind"] == "rain") & df["today_mm"].notna() & (df["today_mm"] >= 0)].copy()
    rain["t"] = pd.to_datetime(rain["observed_at"], utc=True)
    rain["day"] = rain["t"].dt.tz_convert(MYT).dt.strftime("%Y-%m-%d")
    rain = rain.sort_values("t")
    g = rain.groupby(["station_code", "day"])
    out = pd.DataFrame({"obs_mm": g["today_mm"].last(), "n": g.size(),
                        "last_local_hour": g["t"].last().dt.tz_convert(MYT).dt.hour})
    out = out[(out["n"] >= MIN_GAUGE_READINGS) & (out["last_local_hour"] >= 23)]
    return out.reset_index()[["station_code", "day", "obs_mm"]]


def openmeteo_days(om):
    """Forecast rain per station per Malaysia day and lead (1-3 days): the 24 hourly
    values of that day, each from the latest forecast made that many days before."""
    if om is None or om.empty:
        return pd.DataFrame(columns=["station_code", "day", "lead", "fc_mm", "fc_prob"])
    df = om.copy()
    lead_h = (df["valid_at"] - df["issued_at"]).dt.total_seconds() / 3600
    df["lead"] = np.ceil(lead_h / 24).astype(int)
    df = df[df["lead"].between(1, 3)]
    df = df.sort_values("issued_at").drop_duplicates(["station_code", "valid_at", "lead"], keep="last")
    # valid_at is the END of the hour: the hour ending 00:00 belongs to the day before
    df["day"] = (df["valid_at"] - pd.Timedelta(minutes=1)).dt.tz_convert(MYT).dt.strftime("%Y-%m-%d")
    g = df.groupby(["station_code", "day", "lead"])
    out = pd.DataFrame({"fc_mm": g["precip_mm"].sum(), "fc_prob": g["prob_pct"].max(), "hours": g.size()})
    return out[out["hours"] == 24].reset_index().drop(columns="hours")


def contingency(obs, fc, thr):
    o, f = obs >= thr, fc >= thr
    hits, misses = int((o & f).sum()), int((o & ~f).sum())
    fa, cn = int((~o & f).sum()), int((~o & ~f).sum())
    pod = hits / (hits + misses) if hits + misses else None
    far = fa / (hits + fa) if hits + fa else None
    csi = hits / (hits + misses + fa) if hits + misses + fa else None
    bias = (hits + fa) / (hits + misses) if hits + misses else None
    r = lambda v: None if v is None else round(v, 3)  # noqa: E731
    return {"hits": hits, "misses": misses, "false_alarms": fa, "correct_negatives": cn,
            "pod": r(pod), "far": r(far), "csi": r(csi), "bias": r(bias), "observed_events": hits + misses}


def forecast_skill(gauges, fdays):
    m = gauges.merge(fdays, on=["station_code", "day"])
    out = {"pairs": int(len(m)), "stations": int(m["station_code"].nunique()) if len(m) else 0,
           "days": sorted(m["day"].unique().tolist()) if len(m) else [], "by_lead": {}}
    for lead in (1, 2, 3):
        x = m[m["lead"] == lead]
        if x.empty:
            continue
        obs, fc = x["obs_mm"].to_numpy(float), x["fc_mm"].to_numpy(float)
        wet = (obs >= RAIN_DAY_MM).astype(float)
        p = x["fc_prob"].to_numpy(float) / 100.0
        base = wet.mean()
        brier, brier_clim = float(np.mean((p - wet) ** 2)), float(np.mean((base - wet) ** 2))
        out["by_lead"][str(lead)] = {
            "pairs": int(len(x)),
            "mae_mm": round(float(np.mean(np.abs(fc - obs))), 2),
            "mean_observed_mm": round(float(obs.mean()), 2), "mean_forecast_mm": round(float(fc.mean()), 2),
            "spearman_r": round(float(pd.Series(fc).corr(pd.Series(obs), method="spearman")), 3),
            "categories": {name: contingency(obs, fc, thr) for name, thr in THRESHOLDS_MM.items()},
            "brier_rain_day": round(brier, 4),
            "brier_skill_vs_climatology": round(1 - brier / brier_clim, 3) if brier_clim > 0 else None,
        }
    return out


def met_skill(gauges, met):
    """MET Malaysia class (>= 1 = rain expected) against the gauge rain day, per lead day."""
    if met is None or met.empty:
        return {"pairs": 0, "note": "no MET Malaysia forecasts logged yet"}
    m = met.copy()
    m["day"] = m["valid_date"].astype(str)
    m["lead"] = (pd.to_datetime(m["day"]).dt.tz_localize(MYT)
                 - m["issued_at"].dt.tz_convert(MYT).dt.normalize()).dt.days
    m = m.sort_values("issued_at").drop_duplicates(["station_code", "day", "lead"], keep="last")
    x = gauges.merge(m, on=["station_code", "day"])
    if x.empty:
        return {"pairs": 0, "note": "MET Malaysia forecasts are logged, but none yet for a day in the JPS archive"}
    out = {"pairs": int(len(x)), "by_lead": {}}
    for lead, part in x.groupby("lead"):
        out["by_lead"][str(int(lead))] = contingency(part["obs_mm"].to_numpy(float),
                                                     part["rain_class"].to_numpy(float), 1)
    return out


# ---------- 2. forecast rain band vs river response ----------

def band_label(mm):
    for lo, hi, name in BANDS:
        if lo <= mm < hi:
            return name
    return None


def response_table(feats, stations):
    """One row per station per day: the hour 00:00 UTC (08:00 Malaysia time)."""
    alert = {s["id"]: s["alert"] for s in stations}
    x = feats[feats["time"].dt.hour == 0].copy()
    x["alert"] = x["station_id"].map(alert)
    tables = {}
    specs = [("next 24 h", "fc_rain_day1_mm", PEAK_TARGETS[24], 24),
             ("next 72 h", "fc_rain_total_3d", PEAK_TARGETS[72], 72)]
    for name, col, target, _h in specs:
        y = x.dropna(subset=[col, target, "river_level_m"])
        rows = []
        for lo, hi, label in BANDS:
            part = y[(y[col] >= lo) & (y[col] < hi)]
            n = len(part)
            rise = int((part[target] >= RISE_M).sum())
            below = part[part["river_level_m"] < part["alert"]]
            reach = int((below["river_level_m"] + below[target] >= below["alert"]).sum())
            rows.append({"band": label, "station_days": n, "stations": int(part["station_id"].nunique()),
                         "rose_0_3m": rise, "rose_0_3m_rate": round(rise / n, 4) if n else None,
                         "rose_0_3m_ci95": wilson(rise, n),
                         "below_alert": int(len(below)), "reached_alert": reach,
                         "reached_alert_rate": round(reach / len(below), 4) if len(below) else None,
                         "reached_alert_ci95": wilson(reach, len(below))})
        rho = float(y[col].corr(y[target], method="spearman")) if len(y) > 2 else None
        tables[name] = {"forecast_input": col, "outcome": target, "station_days": int(len(y)),
                        "spearman_r": None if rho is None else round(rho, 3), "bands": rows}
    # rain days: how many of the next 3 days are forecast rain days
    y = x.dropna(subset=["fc_rain_days_3d", PEAK_TARGETS[72]])
    rows = []
    for k in (0, 1, 2, 3):
        part = y[y["fc_rain_days_3d"] == k]
        rise = int((part[PEAK_TARGETS[72]] >= RISE_M).sum())
        rows.append({"rain_days": k, "station_days": int(len(part)), "rose_0_3m": rise,
                     "rose_0_3m_rate": round(rise / len(part), 4) if len(part) else None,
                     "rose_0_3m_ci95": wilson(rise, len(part))})
    tables["rain days in the next 3 days"] = {"forecast_input": "fc_rain_days_3d", "outcome": PEAK_TARGETS[72],
                                              "station_days": int(len(y)), "bands": rows}
    return tables


# ---------- 3. with / without the forecast, 4. TreeSHAP ----------

def _bootstrap_mae_diff(err_a, err_b, blocks, n=1000):
    """95% interval of MAE(a) - MAE(b), resampling whole blocks (station-days)."""
    rng = np.random.default_rng(SEED)
    codes, idx = np.unique(blocks, return_inverse=True)
    sa = np.bincount(idx, np.abs(err_a))
    sb = np.bincount(idx, np.abs(err_b))
    cnt = np.bincount(idx)
    diffs = []
    for _ in range(n):
        pick = rng.integers(0, len(codes), len(codes))
        c = cnt[pick].sum()
        diffs.append((sa[pick].sum() - sb[pick].sum()) / c)
    return [round(float(np.quantile(diffs, 0.025)), 4), round(float(np.quantile(diffs, 0.975)), 4)]


FOLDS = {HORIZON_H: 4, 24: 3, 72: 2}  # test days per horizon (rolling origin)


def _blocks(rows):
    return (rows["station_id"] + "|" + rows["time"].dt.tz_convert(MYT).dt.strftime("%Y-%m-%d")).to_numpy()


def _ci_diff(err_a, err_b, blocks):
    return _bootstrap_mae_diff(err_a, err_b, blocks) if len(blocks) else None


def ablation(feats, stations, fast=True):
    """Rolling origin by day: for each of the last FOLDS[h] days, every candidate is trained
    on the rows whose target ends before that day and tested on that day. Scores are pooled
    over the test days (and given per day)."""
    out = {}
    specs = [(f"{HORIZON_H} h (level change)", TARGET, HORIZON_H)] + \
            [(f"{h} h (highest level ahead)", t, h) for h, t in PEAK_TARGETS.items()]
    for name, target, h in specs:
        rows = feats.dropna(subset=[target, "level_above_normal"])
        day = rows["time"].dt.tz_convert(MYT).dt.normalize()
        test_days = sorted(day.unique())[-FOLDS[h]:]
        entry = {"target": target, "horizon_hours": h, "folds": []}
        preds, tests, fold_mae = {}, [], {}
        last_train = None
        for d in test_days:
            train = rows[rows["time"] + pd.Timedelta(hours=h) < d.tz_convert("UTC")]
            test = rows[day == d]
            if len(train) < 500 or len(test) < 50 or train["time"].dt.tz_convert(MYT).dt.date.nunique() < 2:
                continue
            last_train = train
            sets = candidate_sets(train)
            entry["folds"].append({"test_day": str(d.date()), "train_rows": int(len(train)), "test_rows": int(len(test))})
            tests.append(test)
            for label, cols in sets.items():
                m = fit_candidate(label, cols, train, fast, target, h)
                p_ = m.predict(test)
                preds.setdefault(label, []).append(p_)
                fold_mae.setdefault(label, []).append(float(np.mean(np.abs(p_ - test[target].to_numpy(float)))))
                if label == "observed + 3-day forecast":
                    shap_model, shap_rows = m, test
                if hasattr(m, "alpha"):
                    entry["folds"][-1]["residual_alpha"] = m.alpha
            preds.setdefault("no change (persistence)", []).append(np.zeros(len(test)))
        if not tests:
            entry["result"] = "not enough data yet for this horizon"
            out[name] = entry
            continue
        test = pd.concat(tests)
        y = test[target].to_numpy(float)
        blocks = _blocks(test)
        hw = high_water(test, y)
        base_err = np.concatenate(preds["observed only"]) - y
        res = {}
        for label, parts in preds.items():
            p_ = np.concatenate(parts)
            sc = flood_scores(p_, test, target)
            maes = fold_mae.get(label)
            sc["mae_by_day_m"] = [round(v, 4) for v in maes] if maes else None
            if label not in ("observed only", "no change (persistence)"):
                e = p_ - y
                sc["mae_minus_observed_only"] = round(float(np.mean(np.abs(e)) - np.mean(np.abs(base_err))), 4)
                sc["mae_diff_ci95"] = _ci_diff(e, base_err, blocks)
                if hw.any():
                    sc["high_water_mae_minus_observed_only"] = round(
                        float(np.mean(np.abs(e[hw])) - np.mean(np.abs(base_err[hw]))), 4)
                    sc["high_water_diff_ci95"] = _ci_diff(e[hw], base_err[hw], blocks[hw])
            res[label] = sc
        entry["models"] = res
        entry["best_on_test_days"] = choose({k: v for k, v in res.items() if k != "no change (persistence)"})
        entry["test_rows"], entry["station_days_in_test"] = int(len(test)), int(len(np.unique(blocks)))
        entry["high_water_rows"] = int(hw.sum())
        chosen, _, _ = choose_inputs(last_train, target=target, horizon_h=h, fast=True)
        entry["chosen_on_validation"] = chosen
        if "shap_model" in locals():
            contrib = np.abs(shap_model.contributions(shap_rows)[:, :-1])
            mean_abs = dict(zip(shap_model.features, contrib.mean(axis=0)))
            total = sum(mean_abs.values()) or 1.0
            entry["shap_share"] = {g: round(sum(mean_abs.get(f, 0.0) for f in cols) / total, 4)
                                   for g, cols in GROUPS.items()}
            entry["shap_top_inputs"] = [{"input": f, "mean_abs_impact_m": round(v, 4)}
                                        for f, v in sorted(mean_abs.items(), key=lambda kv: -kv[1])[:8]]
            del shap_model
        out[name] = entry
    return out


def chance_check(feats, test_days=3, level="alert"):
    """Rolling origin for the 24 h chance of reaching one JPS level: for each of the newest
    days, a ChanceModel fitted (and calibrated) only on earlier rows states a chance for every
    row of that day; pooled, the stated chances are compared with what happened."""
    labelled = add_label(feats, level)
    day = labelled["time"].dt.tz_convert(MYT).dt.normalize()
    ps, ys, clim, folds = [], [], [], []
    for d in sorted(day.unique())[-test_days:]:
        past = labelled[labelled["time"] + pd.Timedelta(hours=24) < d.tz_convert("UTC")]
        test = labelled[day == d]
        m = ChanceModel.fit(past, level=level) if len(past) >= 400 else None
        if m is None or test.empty:
            continue
        p_ = m.predict(test)
        ps.append(p_)
        ys.append(test[LABEL].to_numpy())
        clim.append(np.full(len(test), past[LABEL].mean()))
        folds.append({"test_day": str(d.date()), "rows": int(len(test)), "events": int(test[LABEL].sum()),
                      "calibrated_on": m.calibration["day"], "inputs": m.input_set})
    if not ps:
        return {"result": "not enough data yet"}
    p_, y, c = np.concatenate(ps), np.concatenate(ys), np.concatenate(clim)
    b, bc = brier(p_, y), brier(c, y)
    return {"folds": folds, "rows": int(len(y)), "events": int(y.sum()), "base_rate": round(float(y.mean()), 4),
            "brier": round(b, 4), "brier_climatology": round(bc, 4),
            "brier_skill": round(1 - b / bc, 3) if bc > 0 else None,
            "reliability": reliability(p_, y)}


# ---------- report ----------

def _p(v, pct=True):
    if v is None:
        return "-"
    return f"{100 * v:.1f}%" if pct else f"{v:.3f}"


def _ci(ci):
    return "-" if ci is None or ci[0] is None else f"{100 * ci[0]:.1f}-{100 * ci[1]:.1f}%"


def markdown(ev):
    L = ["# Rain forecast evidence (generated from the real logs)", "",
         f"Generated {ev['generated_at']} by `python -m flood_ml.rain_evidence`. Do not edit by hand: "
         "re-run it as more days are logged.", "",
         "Data: " + ev["data"]["readings"] + ". " + ev["data"]["forecasts"], "",
         "Thresholds: a rain day is >= 1 mm, heavy >= 10 mm and very heavy >= 20 mm in a day "
         "(ETCCDI indices R1mm, R10mm, R20mm; see [references.md](references.md)). "
         f"A river \"rise\" is >= {RISE_M} m above the level at the time of the forecast.", ""]
    fs = ev["forecast_skill"]["openmeteo"]
    L += ["## 1. Is the Open-Meteo rain forecast any good here?", "",
          f"{fs['pairs']} station-days where a JPS rain gauge and a forecast for the same station and day both "
          f"exist ({fs['stations']} stations, days {', '.join(fs['days'][:1] + ['...'] + fs['days'][-1:]) if fs['days'] else '-'}). "
          "Forecast = 8-model mean made 1, 2 or 3 days before.", "",
          "| Made ahead | Pairs | MAE mm | Mean fcst / obs mm | Spearman r | Rain day POD | FAR | CSI | "
          "Heavy (>=10) POD | FAR | Brier skill vs climatology |",
          "|---|---|---|---|---|---|---|---|---|---|---|"]
    for lead, s in fs["by_lead"].items():
        rd, hv = s["categories"]["rain day (>= 1 mm)"], s["categories"]["heavy (>= 10 mm)"]
        L.append(f"| {lead} day | {s['pairs']} | {s['mae_mm']} | {s['mean_forecast_mm']} / {s['mean_observed_mm']} | "
                 f"{s['spearman_r']} | {_p(rd['pod'])} | {_p(rd['far'])} | {_p(rd['csi'])} | {_p(hv['pod'])} | "
                 f"{_p(hv['far'])} | {s['brier_skill_vs_climatology']} |")
    met = ev["forecast_skill"]["met_malaysia"]
    L += ["", f"MET Malaysia: {met.get('note') or str(met['pairs']) + ' pairs'}.", ""]
    L += ["## 2. Does more forecast rain go with a bigger river rise?", "",
          "One sample per station per day (forecast as known at 08:00 Malaysia time). "
          "95% Wilson intervals.", ""]
    for name, t in ev["response"].items():
        L += [f"### {name} (input `{t['forecast_input']}`, {t['station_days']} station-days"
              + (f", Spearman r = {t['spearman_r']})" if t.get("spearman_r") is not None else ")"), ""]
        if "rain_days" in t["bands"][0]:
            L += ["| Forecast rain days | Station-days | Rose >= 0.3 m | Rate (95% CI) |", "|---|---|---|---|"]
            for b in t["bands"]:
                L.append(f"| {b['rain_days']} | {b['station_days']} | {b['rose_0_3m']} | "
                         f"{_p(b['rose_0_3m_rate'])} ({_ci(b['rose_0_3m_ci95'])}) |")
        else:
            L += ["| Forecast rain | Station-days | Rose >= 0.3 m | Rate (95% CI) | Below Alert | Reached Alert | Rate (95% CI) |",
                  "|---|---|---|---|---|---|---|"]
            for b in t["bands"]:
                L.append(f"| {b['band']} | {b['station_days']} | {b['rose_0_3m']} | {_p(b['rose_0_3m_rate'])} "
                         f"({_ci(b['rose_0_3m_ci95'])}) | {b['below_alert']} | {b['reached_alert']} | "
                         f"{_p(b['reached_alert_rate'])} ({_ci(b['reached_alert_ci95'])}) |")
        L.append("")
    L += ["## 3. Which inputs make the flood forecast better?", "",
          "Rolling origin by day: for each of the last few days, every candidate is trained only on "
          "earlier rows and tested on that day; results are pooled over those test days. "
          "Judged first on high-water hours (river at least half-way from Normal to Alert, or "
          "reaching Alert), with overall MAE as a guard (`scoring.py`). RMSE, NSE, Willmott d, "
          "persistence index and peak error are explained in `metrics.py`. "
          "Differences are against 'observed only' (negative = better), with 95% intervals from "
          "resampling whole station-days.", ""]
    for name, a in ev["ablation"].items():
        L += [f"### {name}", ""]
        if "models" not in a:
            L += [a["result"], ""]
            continue
        L += [f"Test days {', '.join(f['test_day'] for f in a['folds'])}; {a['test_rows']} test rows, "
              f"{a['high_water_rows']} high-water rows, {a['station_days_in_test']} station-days. "
              f"Best on these test days: **{a['best_on_test_days']}**. "
              f"Chosen on validation for the app's model: **{a['chosen_on_validation']}**.", "",
              "| Inputs | MAE m | vs observed (95% CI) | High-water MAE m | vs observed (95% CI) | "
              "RMSE m | NSE | Willmott d | Persistence index | Peak error m |",
              "|---|---|---|---|---|---|---|---|---|---|"]
        for label, sc in a["models"].items():
            fm = sc["metrics"]
            d1 = ("-" if "mae_minus_observed_only" not in sc else
                  f"{sc['mae_minus_observed_only']:+.4f} ({sc['mae_diff_ci95'][0]} to {sc['mae_diff_ci95'][1]})")
            d2 = ("-" if "high_water_mae_minus_observed_only" not in sc else
                  f"{sc['high_water_mae_minus_observed_only']:+.4f} "
                  f"({sc['high_water_diff_ci95'][0]} to {sc['high_water_diff_ci95'][1]})")
            hwm = "-" if sc["high_water_mae_m"] is None else f"{sc['high_water_mae_m']:.4f}"
            L.append(f"| {label} | {sc['mae_m']:.4f} | {d1} | {hwm} | {d2} | "
                     f"{_p(fm['rmse_m'], False)} | {_p(fm['nse'], False)} | {_p(fm['willmott_d'], False)} | "
                     f"{_p(fm['persistence_index'], False)} | {_p(fm['peak_error_m'], False)} |")
        alphas = [f["residual_alpha"] for f in a["folds"] if "residual_alpha" in f]
        if alphas:
            L.append(f"\nResidual correction weight alpha per test day: {alphas} (0 = correction switched off).")
        L.append("")
    chances = ev.get("chance_24h", {})
    L += ["## 3b. Chance of flood within 24 hours: is it honest?", "",
          f"For each JPS level the river is below, `probability.py` states a chance (XGBoost classifier, "
          f"calibrated on the newest day it was not trained on). The app headlines the {HEADLINE.title()} "
          "level as \"flood\". Here each test day is predicted by a model fitted only on earlier days, and "
          "the stated chances are compared with what happened. Brier score: lower is better; "
          "'climatology' always states the past average rate. Brier skill > 0 means better than that "
          "average.", ""]
    for lv in LEVELS:
        ch = chances.get(lv, {})
        L += [f"### {lv.title()}{' (headline: flood)' if lv == HEADLINE else ''}", ""]
        if "folds" not in ch:
            L += [ch.get("result", "not run"), ""]
            continue
        L += [f"Test days {', '.join(f['test_day'] for f in ch['folds'])}: {ch['rows']} station-hours, "
              f"{ch['events']} reached {lv.title()} ({100 * ch['base_rate']:.1f}%). Brier {ch['brier']} vs "
              f"climatology {ch['brier_climatology']} (skill {ch['brier_skill']}).", "",
              f"| Stated chance | Station-hours | Mean stated | Share that reached {lv.title()} |",
              "|---|---|---|---|"]
        for r in ch["reliability"]:
            L.append(f"| {r['band']} | {r['rows']} | {_p(r['stated'])} | {_p(r['happened'])} |")
        L.append("")
    L += ["", "## 4. What the model leans on (TreeSHAP, share of mean |impact|)", ""]
    names = [n for n, a in ev["ablation"].items() if "shap_share" in a]
    if names:
        L += ["| Inputs | " + " | ".join(names) + " |", "|---|" + "---|" * len(names)]
        for g in GROUPS:
            L.append(f"| {g} | " + " | ".join(_p(ev['ablation'][n]['shap_share'][g]) for n in names) + " |")
    L += ["", "## Limits", ""] + [f"- {x}" for x in ev["limits"]] + [""]
    return "\n".join(L)


def run(readings, stations, archive_root, forecast_root, fast=False):
    validate_stations(stations)
    weather = load_weather(forecast_root)
    clean = clean_readings(readings)
    feats = build_features(clean, stations, weather=weather)
    gauges = gauge_days(archive_root)
    codes = {s["id"] for s in stations}
    gauges = gauges[gauges["station_code"].isin(codes)]
    om = weather["openmeteo"]
    days = sorted(clean["time"].dt.tz_convert(MYT).dt.date.astype(str).unique())
    ev = {
        "generated_at": pd.Timestamp.now(tz="UTC").strftime("%Y-%m-%d %H:%M UTC"),
        "data": {
            "readings": (f"JPS archive, {clean['station_id'].nunique()} river stations, {days[0]} to {days[-1]} "
                         f"({len(days)} Malaysia days, {len(clean)} station-hours)"),
            "forecasts": (f"Open-Meteo: {len(om)} hourly forecast rows "
                          f"({'none' if om.empty else str(om['issued_at'].min().date()) + ' to ' + str(om['issued_at'].max().date())}); "
                          f"MET Malaysia: {len(weather['met'])} forecast rows, {len(weather['met_warning'])} warning rows."),
        },
        "forecast_skill": {"openmeteo": forecast_skill(gauges, openmeteo_days(om)),
                           "met_malaysia": met_skill(gauges, weather["met"])},
        "response": response_table(feats, stations),
        "ablation": ablation(feats, stations, fast=True),
        "chance_24h": {lv: chance_check(feats, level=lv) for lv in LEVELS},
        "inputs_filled": {c: round(float(feats[c].notna().mean()), 3) for c in FORECAST_FEATURES},
    }
    ev["limits"] = [
        f"Only {len(days)} days of JPS readings are in the archive; the first 3 days cover few stations. "
        "Every interval above is wide, and one rainy spell dominates the results.",
        "Station-hours next to each other are not independent; parts 2 and 3 therefore count station-days.",
        "Open-Meteo forecasts for days before logging started are backfilled from its Previous Runs API "
        "(made 1-3 days before each hour). Live forecasts are made more recently, so they should be at "
        "least this good.",
        "Open-Meteo's own % chance is not archived for past days, so the chance used everywhere is the "
        "share of 8 weather models forecasting rain.",
        "MET Malaysia publishes no past forecasts, so its inputs are empty in all training rows until the "
        "logger has run for some weeks; the model cannot use them before then (TreeSHAP share 0).",
        "The 72 h model needs at least 72 h after every training row, so it gets the fewest rows.",
    ]
    return ev


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--readings", required=True)
    p.add_argument("--stations", required=True)
    p.add_argument("--archive", default="../data")
    p.add_argument("--forecast", default="../data/forecast")
    p.add_argument("--out", default="output")
    p.add_argument("--doc", help="also write the Markdown report here")
    p.add_argument("--fast", action="store_true")
    a = p.parse_args()
    stations = json.loads(Path(a.stations).read_text(encoding="utf-8"))
    ev = run(pd.read_csv(a.readings), stations, a.archive, a.forecast, fast=a.fast)
    Path(a.out).mkdir(parents=True, exist_ok=True)
    (Path(a.out) / "rain_evidence.json").write_text(json.dumps(ev, indent=2, default=str))
    if a.doc:
        Path(a.doc).write_text(markdown(ev), encoding="utf-8")
    print(markdown(ev))


if __name__ == "__main__":
    main()
