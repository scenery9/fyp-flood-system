"""Chance of a flood within the next 24 hours, at each JPS level.

Questions answered, per station, for each level the river is BELOW now:
    "Will the river reach Alert (Waspada) / Warning (Amaran) / Danger (Bahaya)
     at any time in the next 24 hours?"
The headline "chance of flood" is the Warning one (HEADLINE): at JPS Warning the river is
close to spilling its banks and flood preparations start. Alert and Danger are shown
beside it. A level the river is already at is reported as such; it needs no chance.

One classifier per level (FloodChance), each trained only on rows below that level.
Higher levels can never get a higher chance than lower ones: P(Danger) <= P(Warning) <=
P(Alert) is enforced after calibration (a river must pass Alert to reach Warning).

Model
  classifier   XGBoost (binary logistic), depth 3, regularised. More rain (past, history or
               forecast) may only raise the chance (monotone constraints, as in ensemble.py).
  calibration  Platt scaling: p = 1 / (1 + exp(-(a * z + b))), z = the classifier's log-odds,
               a and b fitted on the NEWEST training day(s), which the classifier did not see.
               A raw classifier score is not a probability; after calibration "30%" should
               mean "about 3 in 10 such cases reached Alert" (checked in rain_evidence.py).
  inputs       chosen among the same sets as the level model (observed only, + rain history,
               + next-day or 3-day forecast), by Brier score on a day not used for fitting.
  explanation  exact TreeSHAP in log-odds. Calibration multiplies every contribution by a and
               adds b to the base value, so the reasons still add up exactly to logit(p).

Rows: one per station per hour; the label needs at least 75% of the next 24 hours read
(features.peak_rise). Training rows whose 24 hours reach into a later fold are dropped.
"""
import numpy as np
import pandas as pd
import xgboost as xgb

from .ensemble import SEED
from .features import HISTORY_FEATURES, LEVEL_SPANS, PEAK_TARGETS
from .train import INPUT_SETS
from .weather import RAISES_ONLY

HORIZON_H = 24
LEVELS = ("alert", "warning", "danger")
HEADLINE = "warning"                 # "flood" = the river reaching JPS Warning (Amaran)
LABEL = "reaches_level_24h"          # for the level add_label() was called with
FILL_TARGET = "fill_to_target"       # input: (level - normal) / (that JPS level - normal)
QUESTIONS = {"alert": "Will the river reach Alert (Waspada) within the next 24 hours?",
             "warning": "Will the river reach Warning (Amaran) within the next 24 hours?",
             "danger": "Will the river reach Danger (Bahaya) within the next 24 hours?"}
# The readings behind the reasons the app shows ("raining for 7 hours, 48 mm"): their
# values now, whatever the model leaned on.
INPUTS_NOW = ["consecutive_wet_hours", "wet_hours_24h", "rain_sum_1h", "rain_sum_3h", "rain_sum_6h",
              "rain_sum_24h", "rain_sum_72h", "api_7d", "level_change_1h", "level_change_2h", "level_change_3h",
              "up_level_change_3h", "up_rain_sum_6h", "fc_rain_next_3h", "fc_rain_day1_mm",
              "fc_rain_prob_day1", "fc_rain_total_3d", "met_warning_level"]
MYT = "Asia/Kuala_Lumpur"
PARAMS = {"objective": "binary:logistic", "max_depth": 3, "eta": 0.05, "lambda": 5.0,
          "min_child_weight": 10, "subsample": 0.8, "colsample_bytree": 0.9, "seed": SEED}
ROUNDS = 200
RAISES = set(RAISES_ONLY) | set(HISTORY_FEATURES) | {FILL_TARGET,
    "rain_sum_1h", "rain_sum_3h", "rain_sum_6h", "rain_sum_24h", "rain_sum_72h", "up_rain_sum_3h", "up_rain_sum_6h"}
MIN_EVENTS = 20   # fewer Alert crossings than this on the calibration day(s): chance marked unreliable
EPS = 1e-6


def with_fill(feats, level):
    """feats with FILL_TARGET for one JPS level: 0 at Normal, 1 at that level."""
    span = feats[LEVEL_SPANS[level]]
    out = feats.copy()
    out[FILL_TARGET] = (feats["level_above_normal"] / span).where(span > 0)
    return out


def add_label(feats, level="alert"):
    """Rows below `level` now, with FILL_TARGET, and LABEL = 1 if the highest level in the
    next 24 h reaches it."""
    f = with_fill(feats, level)
    rise = f[PEAK_TARGETS[HORIZON_H]]
    rows = f[(f[FILL_TARGET] < 1.0) & rise.notna()].copy()
    rows[LABEL] = ((rows["level_above_normal"] + rows[PEAK_TARGETS[HORIZON_H]])
                   >= rows[LEVEL_SPANS[level]]).astype(int)
    return rows


def _logit(p):
    p = np.clip(p, EPS, 1 - EPS)
    return np.log(p / (1 - p))


def _sigmoid(z):
    return 1.0 / (1.0 + np.exp(-z))


def platt(z, y, iters=200):
    """(a, b) minimising log loss of sigmoid(a*z + b) against y (Newton's method, tiny ridge)."""
    a, b = 1.0, 0.0
    z, y = np.asarray(z, float), np.asarray(y, float)
    for _ in range(iters):
        p = _sigmoid(a * z + b)
        w = p * (1 - p) + 1e-9
        g = np.array([np.sum((p - y) * z) + 1e-3 * (a - 1), np.sum(p - y)])
        h = np.array([[np.sum(w * z * z) + 1e-3, np.sum(w * z)], [np.sum(w * z), np.sum(w) + 1e-9]])
        step = np.linalg.solve(h, g)
        a, b = a - step[0], b - step[1]
        if np.max(np.abs(step)) < 1e-8:
            break
    return float(a), float(b)


def brier(p, y):
    return float(np.mean((np.asarray(p, float) - np.asarray(y, float)) ** 2))


def auc(p, y):
    p, y = np.asarray(p, float), np.asarray(y, bool)
    pos, neg = int(y.sum()), int((~y).sum())
    if pos == 0 or neg == 0:
        return None
    r = pd.Series(p).rank(method="average").to_numpy()
    return float((r[y].sum() - pos * (pos + 1) / 2) / (pos * neg))


def reliability(p, y, edges=(0, 0.1, 0.3, 0.6, 1.0001)):
    """Per band of stated chance: rows, mean stated chance, share that really reached Alert."""
    p, y = np.asarray(p, float), np.asarray(y, float)
    out = []
    for lo, hi in zip(edges[:-1], edges[1:]):
        m = (p >= lo) & (p < hi)
        out.append({"band": f"{round(100 * lo)}-{min(100, round(100 * hi))}%", "rows": int(m.sum()),
                    "stated": round(float(p[m].mean()), 3) if m.any() else None,
                    "happened": round(float(y[m].mean()), 3) if m.any() else None})
    return out


class ChanceModel:
    """Chance of reaching ONE level (the one add_label() was called with)."""
    def __init__(self, booster, features, a, b, input_set, calibration, level="alert"):
        self.booster, self.features, self.a, self.b = booster, list(features), a, b
        self.input_set, self.calibration, self.level = input_set, calibration, level

    @staticmethod
    def _fit_booster(rows, features):
        mono = "(" + ",".join("1" if f in RAISES else "0" for f in features) + ")"
        return xgb.train(PARAMS | {"monotone_constraints": mono},
                         xgb.DMatrix(rows[features], label=rows[LABEL]), ROUNDS)

    @staticmethod
    def _split_days(rows, n):
        """(older rows, rows of the newest n days); older rows whose 24 h reach those days are dropped."""
        day = rows["time"].dt.tz_convert(MYT).dt.normalize()
        days = sorted(day.unique())
        if len(days) <= n:
            return None, None
        first = days[-n]
        older = rows[(rows["time"] + pd.Timedelta(hours=HORIZON_H) < first.tz_convert("UTC"))]
        return older, rows[day >= first]

    @classmethod
    def fit(cls, labelled, candidates=None, level="alert"):
        """labelled: add_label(feats, level) rows. Chooses the inputs (Brier on the newest training day,
        each candidate trained only on days before it), then fits on everything older than
        the newest day and calibrates on the newest day."""
        sets = {}
        for name, cols in (candidates or INPUT_SETS).items():
            cols = [c for c in [*cols, FILL_TARGET] if labelled[c].notna().any()]
            if cols and tuple(cols) not in {tuple(v) for v in sets.values()}:
                sets[name] = cols
        fit_rows, calib = cls._split_days(labelled, 1)
        if fit_rows is None or len(fit_rows) < 200 or calib[LABEL].nunique() < 2 or fit_rows[LABEL].nunique() < 2:
            return None
        scores = {}
        inner, check = cls._split_days(fit_rows, 1)
        if inner is not None and len(inner) >= 200 and inner[LABEL].nunique() == 2 and check[LABEL].nunique() == 2:
            # Each held-out day also costs the day before it (its 24 h outcomes reach into the
            # held-out day), so a separate calibration day would leave too little to train on.
            # Platt (2 numbers) is fitted on the check day itself: the same small optimism for
            # every candidate, so the comparison stays fair.
            for name, cols in sets.items():
                bst = cls._fit_booster(inner, cols)
                z = bst.predict(xgb.DMatrix(check[cols]), output_margin=True)
                a, b = platt(z, check[LABEL])
                scores[name] = brier(_sigmoid(a * z + b), check[LABEL])
        name = min(scores, key=lambda n: (scores[n], list(sets).index(n))) if scores else "observed only"
        cols = sets.get(name, sets[next(iter(sets))])
        bst = cls._fit_booster(fit_rows, cols)
        zc = bst.predict(xgb.DMatrix(calib[cols]), output_margin=True)
        a, b = platt(zc, calib[LABEL])
        pc = _sigmoid(a * zc + b)
        base_rate = float(fit_rows[LABEL].mean())
        events = int(calib[LABEL].sum())
        info = {"day": str(calib["time"].dt.tz_convert(MYT).min().date()), "rows": int(len(calib)),
                "events": events, "brier": round(brier(pc, calib[LABEL]), 4),
                "brier_climatology": round(brier(np.full(len(calib), base_rate), calib[LABEL]), 4),
                "auc": None if auc(pc, calib[LABEL]) is None else round(auc(pc, calib[LABEL]), 3),
                "base_rate": round(base_rate, 4), "input_scores_brier": {k: round(v, 4) for k, v in scores.items()},
                "reliable": events >= MIN_EVENTS}
        return cls(bst, cols, a, b, name, info, level)

    def predict(self, rows):
        z = self.booster.predict(xgb.DMatrix(rows[self.features]), output_margin=True)
        return _sigmoid(self.a * z + self.b)

    def contributions(self, rows):
        """(rows, len(features) + 1) in log-odds after calibration; each row sums to logit(predict())."""
        c = self.booster.predict(xgb.DMatrix(rows[self.features]), pred_contribs=True)
        c = c * self.a
        c[:, -1] += self.b
        return c

    def describe(self):
        return {"question": QUESTIONS[self.level], "level": self.level,
                "type": "XGBoost classifier + Platt calibration (exact TreeSHAP in log-odds)",
                "input_set": self.input_set, "inputs": len(self.features),
                "platt_a": round(self.a, 4), "platt_b": round(self.b, 4), "calibration": self.calibration}


class FloodChance:
    """One ChanceModel per JPS level; the headline is Warning (HEADLINE)."""
    def __init__(self, models):
        self.models = models  # {level: ChanceModel or None (too few crossings to learn from)}

    @classmethod
    def fit(cls, feats):
        """feats: build_features() rows up to now (with the 24 h targets)."""
        return cls({lv: ChanceModel.fit(add_label(feats, lv), level=lv) for lv in LEVELS})

    @property
    def headline(self):
        """The level the app headlines: Warning, or the nearest lower one that has a model."""
        order = LEVELS[:LEVELS.index(HEADLINE) + 1][::-1]
        return next((lv for lv in order if self.models.get(lv) is not None), None)

    def __bool__(self):
        return self.headline is not None

    def describe(self):
        h = self.headline
        head = self.models[h].describe() if h else {}
        return {"question": QUESTIONS[h] if h else None, "headline_level": h,
                "type": head.get("type"), "input_set": head.get("input_set"),
                "calibration": head.get("calibration"),
                "levels": {lv: (m.describe() if m is not None else None) for lv, m in self.models.items()}}


def _value(r, f):
    v = r[f].iloc[0] if f in r else np.nan
    return None if pd.isna(v) else round(float(v), 3)


def chance_entries(model, feats_now, stations_by_id):
    """{station id: flood_chance block for forecast.json} from each station's latest row.

    model: FloodChance (or a single ChanceModel, treated as the only level).
        levels      {level: {"already": bool, "chance": 0-1 or None}} for Alert, Warning, Danger
        headline_level, chance, already   the headline level (Warning) repeated at the top
        factors     the headline model's reasons in log-odds; base_logodds + their sum =
                    logit(chance before the ordering cap); capped = True if the cap changed it
        inputs_now  the readings behind the reasons (INPUTS_NOW), for the app's sentences"""
    if isinstance(model, ChanceModel):
        model = FloodChance({model.level: model})
    head = model.headline
    out = {}
    for sid, row in feats_now.groupby("station_id"):
        r = row.iloc[[-1]]
        if pd.isna(r["level_above_normal"].iloc[0]):
            continue
        levels, raw, contrib = {}, {}, {}
        for lv in LEVELS:
            span = r[LEVEL_SPANS[lv]].iloc[0] if LEVEL_SPANS[lv] in r else np.nan
            if pd.isna(span) or span <= 0:
                continue
            already = float(r["level_above_normal"].iloc[0]) >= float(span)
            m = model.models.get(lv)
            p = None
            if not already and m is not None:
                rf = with_fill(r, lv)
                p = float(m.predict(rf)[0])
                raw[lv] = p
                if lv == head:
                    contrib[lv] = (m, rf, m.contributions(rf)[0])
            levels[lv] = {"already": already, "chance": p}
        # a river must pass the lower level first: cap each chance by the one below it
        below = 1.0
        for lv in LEVELS:
            e = levels.get(lv)
            if e is None:
                continue
            if e["already"]:
                below = 1.0
            elif e["chance"] is not None:
                e["chance"] = round(min(e["chance"], below), 4)
                below = e["chance"]
        h = levels.get(head) if head else None
        entry = {"horizon_hours": HORIZON_H, "headline_level": head,
                 "already": bool(h and h["already"]), "chance": h["chance"] if h else None,
                 "levels": levels, "base_logodds": None, "factors": [], "capped": False,
                 "inputs_now": {f: _value(r, f) for f in INPUTS_NOW}}
        if head in contrib:
            m, rf, c = contrib[head]
            entry["base_logodds"] = round(float(c[-1]), 4)
            entry["capped"] = bool(h["chance"] < round(raw[head], 4))
            fs = [{"feature": f, "value": _value(rf, f), "impact_logodds": round(float(v), 4)}
                  for f, v in zip(m.features, c[:-1])]
            entry["factors"] = sorted(fs, key=lambda x: -abs(x["impact_logodds"]))
        out[sid] = entry
    return out
