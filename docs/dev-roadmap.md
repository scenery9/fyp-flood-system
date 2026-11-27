# Roadmap to the system performance analysis (W10) and panel demo

Supervisor's requests, turned into dated steps. Week numbers are **project weeks**: the current
week, 23-29 Nov 2026, is **W3**.

| Week | Dates | |
|---|---|---|
| W3 | 23-29 Nov 2026 | Now. Prediction metrics added (done, below) |
| W4-W8 | 30 Nov 2026 - 3 Jan 2027 | Logging continues; build the items below |
| W9 | 4-10 Jan 2027 | **Test week** (held out, never trained on) |
| W10 | 11-17 Jan 2027 | **System performance analysis** (due Fri 15 Jan) and panel preparation |

**Assumption about the split (confirm with supervisor).** The logs start on 17 Nov 2026, and the
analysis is in W10. So the model is trained on **17 Nov 2026 - 3 Jan 2027 (about 7 weeks)** and
tested on **W9**. W10 is not complete by 15 Jan, so it cannot be the test week.

---

## Done (W3)

- [x] **Prediction metrics only** for the water-level forecast (`ml/flood_ml/metrics.py`):
  MAE, RMSE, **NSE** (Nash & Sutcliffe 1970), **Willmott's d** (Willmott 1981), **persistence
  index** (Kitanidis & Bras 1980), plus bias and peak error. Removed: accuracy, precision,
  recall, F1, AUC and the confusion matrices from `metrics.json`, the model comparison table and
  the evidence report. Sources and first real-log numbers: [literature.md](literature.md).
- [x] **Past water levels t−1, t−2, t−3 as inputs** (lecturer's comment). Added
  `level_change_2h` = h(t) − h(t−2) next to the 1 h and 3 h changes
  (`ml/flood_ml/features.py`), so the model sees h(t), h(t−1), h(t−2) and h(t−3) and predicts
  h(t+3). Also in the flood-chance reasons, the rain-evidence groups, the app's reason text
  ("the last 2 hours"), the tests and Methodology Table 3.2. All 103 ML tests and the
  `flood_core` tests pass.

## How to retrain and run the app on real JPS data

Python: Anaconda's `D:\Anaconda\python.exe` (3.12) works. It needed
`pip install xgboost lightgbm catboost` once; everything else was already there. Below,
`python` means that file (or put `D:\Anaconda` on PATH).

### A. Retrain the model on real readings

```powershell
cd d:\1_dev\fyp-flood-system\fyp-flood-system
git pull                                     # newest daily archive files in data/
cd logger
# Last 30 days from the database: take the URL and publishable key from app\secrets.json
# (readings are public). Without them, add --no-database (archive files only).
$s = Get-Content ..\app\secrets.json -Raw | ConvertFrom-Json
$env:SUPABASE_URL = $s.SUPABASE_URL; $env:SUPABASE_PUBLISHABLE_KEY = $s.SUPABASE_PUBLISHABLE_KEY
python -m jps_logger.export --since 2026-11-17 --stations ..\ml\stations_training.json --out ..\ml\readings.csv
cd ..\ml
python -m pytest -q                          # 103 tests, about 3 minutes
python -m flood_ml.run --stations stations_training.json --readings readings.csv --weather ..\data\forecast
```

- Results go to `ml\output\` (`metrics.json`, `forecast.json`, `model\`). Check the printed MAE
  against the "no-change" and "straight-line trend" numbers: the model must beat both.
- `stations_training.json` is all 143 Selangor and Melaka stations: one model is trained on all
  of them, and every station with a reading in the last 2 hours gets a forecast. For Taman Sri
  Muda and its two upstream stations only, use `stations_klang.json` (in both commands).
- Time on this laptop: export about 50 s, train and forecast about 55 s.
- **"0 station forecasts written"** means the newest reading is more than 2 hours old.
  Training still worked, but there is nothing current to forecast. Run `git pull` and set the
  Supabase variables so the export includes today's readings.
- **"Not enough data to train"** means fewer than 200 training or 50 test hours. Wait for more
  logging days.
- `readings.csv` and `ml\output\` are in `.gitignore`.

Trials on 28 Nov 2026 (about 11 days of logs; for checking only, not results to report):

| Run | Readings | Stations | Test hours | MAE | "No change" MAE | NSE |
|---|---|---|---|---|---|---|
| Klang only, archive to 24 Nov | 1,382 | 3 | 78 | 0.146 m | 0.310 m | 0.612 |
| All stations, archive + database | 105,276 | 143 (136 forecast) | 5,693 | 0.207 m | 0.346 m | −0.162 |
| All stations, without the 5 worst | | 135 | | 0.178 m | 0.321 m | 0.636 |

**Why the all-station NSE is negative: faulty readings, not the model.** Two stations give 64%
of all squared error, and in each case the "actual" change is one impossible reading in the
JPS feed:
- `BPTL0006L` Kg. Melayu Subang: flat at 14.56 m, then 34.21 m (+19.6 m in 3 h).
- `BGBK0001L` Taman Tun Teja, Rawang: 32.77 → **15.97** → 32.74 m within 30 minutes.
- `BPTL0002L` Jalan 222: 17.01 → **10.14** → 17.01 m, and again → **10.27** m.
- `BKSL0010` Pintu Air Sg Yu 1 (tide gate): 0.08 → 3.47 m, then steady. Possibly the gate
  working, so not clearly an error.

Cleaning only removes false 0.00 readings, so these spikes reach the test set.
- [ ] **Spike filter** in `clean_readings`: drop a reading that jumps far from both
  neighbours while they agree with each other (like the 0.00 glitch rule). Then re-run and
  report NSE with it on. Fix before W9; the W9 test is scored on cleaned data.

### B. Run the app (debug) on real JPS data

Needs `app\secrets.json` with `SUPABASE_URL` and `SUPABASE_PUBLISHABLE_KEY`
(see README, "Sample mode or live mode").

```powershell
cd d:\1_dev\fyp-flood-system\fyp-flood-system\app
flutter pub get
flutter devices                                       # phone (USB debugging on) or emulator
flutter run --dart-define-from-file=secrets.json      # debug build, live JPS data
```

Or in VS Code: **Run → "Flood app"** (F5), which passes `secrets.json` for you. In the
running app press `r` for hot reload and `R` for hot restart. Without `secrets.json`, the app
shows made-up sample stations.

**What is real in this run:** JPS stations and levels, relief centres, rain outlook, routes,
and push (push only with `app\android\app\google-services.json` present). **What is not yet:** the AI forecast card. The app downloads `forecast.json` from
Supabase Storage, not from `ml\output\`, and accepts it only when it is signed with a key in
`trustedForecastKeys`. That list is still empty, so the card shows the labelled **practice**
forecast. Showing the retrained model needs steps 2b-4 of
[forecast-switch-plan.md](forecast-switch-plan.md): make the signing key, add its public half
to the app, then upload the signed `forecast.json`.

## 1. Regression charts for three study areas (W9-W10)

Each area gets the station or stations **closest to where people live, or whose flooding
affects the most people**. Final pick in W9: the station has to have logged at least 90% of hours.

| Area | Candidate stations (from `ml/stations_training.json`) | Why |
|---|---|---|
| Shah Alam | **Taman Sri Muda** `BKLG0002L` (Sg. Klang); Batu Tiga `BPTL0012L` or TTDI Jaya `BPTL0008L` (Sg. Damansara) | Taman Sri Muda is a dense housing area beside the Klang River and the worst-hit area in Dec 2021 |
| Klang | **Bandar Klang** `BKLG0003L` (Sg. Klang, town centre); Tugu Keris `BKLG0006L` (Sg. Rasah) | Town centre. Tugu Keris has already passed Alert in the logs |
| Melaka | **Sg. Duyong** `0300051WL` (Melaka Tengah, city); Sg. Melaka di Melaka Pindah `0290211WL` | Urban river in Melaka city. Melaka Pindah has passed Danger in the logs |

For each chosen station, and for **both 3 h and 24 h ahead**:
- [ ] Time-series chart of actual against predicted water level over W9, with the Normal, Alert,
      Warning and Danger lines and the 80% error band.
- [ ] Scatter chart of predicted against actual, with the 1:1 line.
- [ ] Table: MAE, RMSE, NSE, Willmott d, persistence index, bias, peak error. Also for the
      "no change" baseline, so the panel can see the gain.
- [ ] Script `python -m flood_ml.area_report --train-to 2027-01-03 --test-week 2027-01-04`
      that writes the charts (PNG) and tables for the report.

**"The predicted line must touch the actual line."** This is a result to aim for, not something
to force:
- The 3 h line will follow the actual line closely. The 24 h line is harder and will drift more.
  Both are shown, and the difference is explained.
- Tuning the model on W9 itself is not allowed (the test would no longer be fair). Any
  improvement is made with W1-W8 data only.
- What helps: more weeks of data, the residual correction, and checking the peak error at each
  chosen station.

## 2. Flood flagging one day ahead: simulated floods in W9 (W9-W10)

- [ ] Use real floods in W9 if they happen. A real flood is a JKR incident (logged hourly by
      `jkr.py`) with a nearby JPS station reaching Warning.
- [ ] Otherwise, **two simulated floods** in W9, clearly labelled as simulations. Each one is
      built from a real past heavy-rain event: its rain, and the upstream and river readings, are
      replayed into the W9 timeline at a chosen station.
- [ ] Pass rule, fixed before the test is run: **24 h before** each flood, the station's flood
      chance is at least the admin threshold (80%), and the 24 h level forecast crosses Warning.
      Also recorded: the time the flag first appeared, and any false flags in the week.
- [ ] If the model misses: say so, fix it using W1-W8 only (inputs, more data, calibration), then
      re-run. Never adjust the model on the test week.
- [ ] Chart for the panel: river level, rain and the flood % over the days before each flood,
      with the "flagged 24 h ahead" moment marked.

## 3. Alerts (W5-W8)

- [ ] **User alerts by preference.** The user picks Alert, Warning or Danger, or a set height, per
      station. This exists (`AlertService`, `PushAlertService`). Check it end to end: a level
      crossing triggers the push, with the right wording.
- [ ] **Flood-chance alerts to admin (new).** When a station's flood chance is 80% or more:
  - Create a review item for staff of that district (station, %, reasons, level chart).
  - Staff **approve and send**, or dismiss with a reason. Users following the area, or in the
    district, get a push marked as sent by staff. Nothing reaches users automatically.
  - New Supabase table with RLS: only staff of that district can approve. Every send and
    dismissal is logged.

## 4. Panel demo (W10)

- [ ] W9 charts for the three areas (3 h and 24 h) and the metrics table.
- [ ] Replay of the two floods, flagged a day ahead.
- [ ] A user alert firing at the user's chosen level.
- [ ] Admin receiving an 80%+ flood alert, approving it, and the user receiving it.
