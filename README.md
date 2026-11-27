# FloodReady: explainable AI flood early-warning app

FloodReady is a final-year project (FYP): a mobile app that helps households in **Selangor and
Melaka, Malaysia** follow river levels near them, get flood alerts, prepare, and find a relief
centre. It also predicts the river level 3 hours ahead with an AI model and **explains each
forecast in plain words** (for example, "42 mm of rain in the last 3 hours raises the forecast").

> **Not an official warning service.** FloodReady uses public JPS (Department of Irrigation and
> Drainage) readings and a student-built model. Always follow JPS, NADMA and local authorities.

Contents: [What the app does](#what-the-app-does) ·
[How it works](#how-it-works) · [AI prediction logic](#ai-prediction-logic) ·
[Tech stack](#tech-stack) · [Repository layout](#repository-layout) ·
[Install and run](#install-and-run) · [Backend setup](#backend-setup-live-mode) ·
[Tests](#tests) · [Limitations](#limitations) · [More documents](#more-documents)

---

## What the app does

The app has four tabs and runs in **English, Bahasa Melayu and Chinese**.

### Home
- **Saved areas** (up to 5): a swipeable card per area. Each card shows the river's risk level
  (**Normal / Waspada (Alert) / Amaran (Warning) / Bahaya (Danger)**), the level in metres, the
  next threshold, and how old the reading is. Under that is the **rain band** (No rain / Light /
  Moderate / Heavy / Very heavy, with mm/h). It comes from the station's own gauge or, if it
  has none reporting, the nearest gauge within 10 km, named with its distance. A saved rain
  gauge with no river sensor leads with the rain band ("Heavy rain") instead.
- With no saved areas, the card shows the **river station nearest you**, with a Save button.
- The **AI forecast card** ("Next 3 hours") shows the expected level, a likely range, a gauge
  and a read-aloud button. *Why does the AI say this?* lists the readings that pushed the
  forecast up or down the most.
- A **High-risk stations** list, an alert banner, and a **Report flooding** button.

### Prepare
- A household profile (people by age group, older adults, daily medicine, oxygen or other
  powered equipment, wheelchair, pets, transport). It can be locked behind the phone's
  fingerprint, face or PIN.
- A checklist that changes with the current risk level, a go-bag list matched to the
  household, and safety cards with one-tap *Call 999*.

### Centres
- A map (OpenStreetMap) with river and rain layers and relief centres.
- Station lists sorted *Near me* or *Highest risk*, with 5 / 10 / 30 km filters.
- Relief centres with capacity, opening status and drive time.
- An **in-app route guide** that works offline once saved: one step at a time, read aloud,
  with warnings for flooded river stations near the route.
- *Tell this centre we're coming*: a headcount with people, needs and pets, then
  *On the way / Arrived / Left*.

### More
- *Alerts near you now* covers saved areas, the nearest station and stations within 10 km.
  It also lists what the AI expects to reach Warning or Danger within 3 hours.
- **Push notifications**, which arrive even when the app is closed. You choose the
  *Notify me from* level, and can set a river-height alert for any station using its own JPS
  Alert / Warning / Danger heights.
- Saved areas (add by State, then District), language, text size, high contrast, read aloud,
  emergency contact, *My reports*, and pages on how the AI works.

### Staff side (rules and database built, screens not yet)
- Roles: Super Admin, Coordinator (one district), Field Officer (one resource point).
- Each role has its own access to damage reports, relief centres, stock and headcounts.
- The rules are enforced in `flood_core` **and** by Supabase row-level security, so a modified
  app cannot get round them.

---

## How it works

```
 JPS Selangor API ──┐                      ┌─► data/YYYY/MM/*.csv.gz   (daily archive in this repo)
 JPS Melaka pages ──┼─► logger (GitHub     │
 publicinfobanjir ──┘   Actions, every ────┼─► Supabase Postgres  ◄──── app (live stations, centres,
 (both states,          15 min) ◄──────────┼──── pg_cron starts it      reports, headcount)
  second source)                           │     jps_latest view
                                           │     pg_cron, every 15 min
                                           │       └─► Edge Function send-alerts ─► Firebase ─► phone
                                           │     Edge Function route ─► openrouteservice (key stays server-side)
                                           │
 ml/ (Python, XGBoost + SHAP) ◄── export ──┘──► forecast.json ─► Supabase Storage ─► app's AI forecast card
                                                 (publishing job: see "AI prediction logic")
```

- **Data logger (`logger/`).** Every 15 minutes a GitHub Actions job reads every JPS river-level
  and rainfall station in Selangor (about 330) and Melaka, and stores new readings in Supabase.
  JPS only shows each station's latest value, so this log is what builds the history the
  model needs. A daily job moves finished days into compressed CSV files in `data/`, so
  Supabase keeps only 30 days (about 150 MB, within the free plan).
  - **Two sources per state.** Selangor is read from the Selangor API first; if it fails, finds
    nothing, or a district fails, the national pages (publicinfobanjir.water.gov.my) fill in.
    Melaka is read from the JPS Melaka pages first, and publicinfobanjir is always read too:
    it lists about 23 Melaka stations the Melaka pages do not. The order is `SOURCES` (and
    `ALWAYS_BOTH`) in `logger/jps_logger/collect.py`. publicinfobanjir has no map positions, so
    stored positions are kept; Selangor stations are matched by their national id
    (`jps_stations.jps_wl_id`, `jps_rf_id`), which every normal run saves, and 4 Melaka
    stations with a different code there by `MELAKA_CODES`.
  - **Started by Supabase.** GitHub's own schedule is best-effort and at times ran the job
    only every 5–8 hours, so the app showed "No recent data". Supabase `pg_cron` now starts
    the workflow every 15 minutes (`supabase/logger_schedule.sql`); GitHub's schedule stays
    as a backup.
- **Risk level.** Each river station has JPS thresholds (normal, alert, warning, danger). The
  level is taken from the latest reading against those thresholds. A reading older than
  **3 hours** is *stale*: it is shown but never raises a warning. Sensor fault codes
  (-9999 / -8888) count as no data.
- **Rain bands** (1-hour rolling total from JPS): no rain 0 mm; light ≤ 10; moderate ≤ 30;
  heavy ≤ 60; very heavy > 60 mm/h. These cut-offs are provisional and still to be confirmed
  against MetMalaysia. Measured rain does not change the river risk level.
- **Rain forecast, 3 days ahead** (`logger/jps_logger/weather.py`, every 6 hours): Open-Meteo
  (mm and the share of 8 weather models expecting rain) and MET Malaysia (official forecast text
  per district, and warnings), stored in `weather_outlook` (`supabase/weather.sql`) and archived
  in `data/forecast/`. The river risk level stays as measured; a separate **outlook** is one
  level higher when very heavy rain (>= 20 mm/day, ETCCDI R20mm) is forecast with >= 70% of
  models agreeing AND MET Malaysia also expects rain or has a warning out (or a MET Buruk/Bahaya
  warning is in force), while the river is at Alert or within 80% of it
  (`packages/flood_core/lib/src/risk/joint_risk.dart`). Each reason names its source
  ([docs/references.md](docs/references.md)). What the real logs show:
  [docs/rain-forecast-evidence.md](docs/rain-forecast-evidence.md). Plan to the W10 performance
  analysis and panel demo: [docs/roadmap.md](docs/roadmap.md); progress by day:
  [docs/daily-updates.md](docs/daily-updates.md).
- **Reported incidents from JKR** (`logger/jps_logger/jkr.py`, every hour, `log_jkr.yml`): the
  current floods, landslides and road collapses on JKR's public portal (bencana.jkr.gov.my),
  with position, district, status (e.g. "Water Rising"), road status and flood depth, plus the
  3 nearest JPS river stations and rain gauges within 15 km and what they read at that moment
  (`supabase/jkr.sql`, archived in `data/incidents/`). The officer's name and phone numbers in
  the portal's records are never stored. The 6-hourly rain forecast also covers each current
  incident location (ids `JKR-<id>`), so the areas being reported get their own forecast.
- **Push alerts.** The phone signs in to Supabase anonymously (no account) and registers its
  Firebase token and its rules. Every 15 minutes Supabase's `pg_cron` calls the `send-alerts`
  Edge Function. A notification is sent:
  - when a rule first becomes true;
  - when the river moves up a level;
  - every 45 minutes while at Danger.

  Stale readings change nothing.
- **Routing.** The app calls our own `route` Edge Function, which holds the openrouteservice
  key and applies per-phone and overall rate limits. The last 3 routes are kept on the phone.
- **Offline.** The last centres list and saved routes are kept on the phone. Data reloads every
  15 minutes while the app is open.
- **Two modes.** With `app/secrets.json` (Supabase URL + publishable key) the app runs in **live
  mode** on real JPS data. Without it, it runs in **sample mode** on made-up Johor/Selangor
  stations, so every screen can be demonstrated offline.

---

## AI prediction logic

### Model (Python, `ml/flood_ml/`)

**Goal.** For each river station, predict the **change in river level over the next 3 hours**
(`target_change_m = level(t+3h) − level(t)`). The app then adds that change to the current
level and turns the result into Normal / Waspada / Amaran / Bahaya using the station's
thresholds.

1. **Cleaning (`features.py`).**
   - Fault codes and negative rain are removed.
   - **Levels below 0 are kept.** They are real: about 25 tide gates (*pintu air*, *kunci
     air*) and river mouths read below 0 at low tide, and 8 stations have a JPS normal
     level below 0 (e.g. Barrage Sungai Melaka D/S, -2.0 m).
   - **A 0.00 m glitch is removed.** The feed sometimes sends exactly 0.00 for a moment,
     e.g. 42.86 → 0.00 → 42.86, often at many stations at once (11 stations on 19 Nov 2026
     at 22:30 UTC). A 0.00 is removed when:
     - the nearest readings within 2 h on each side are more than 0.3 m away; or
     - the readings within 30 min on both sides are on the same side of 0 and at least
       0.1 m from it (0.21 → 0.00 → 0.20).

     A 0.00 the tide passes through (0.08 → 0.00 → -0.08) is kept. On the 17–23 Nov
     archive, 34 of 77 zero readings were removed. The logger also skips such a 0.00 as it
     arrives, when the station's previous reading is under 2 h old and more than 0.3 m
     away, so the app never shows a false "0.00 m".
   - Readings are resampled to **hourly**: rain is summed, and the last level in each hour
     is kept.
   - River-level gaps of up to **2 hours** inside the series are filled by straight-line
     interpolation. Longer gaps stay missing.
2. **Features: 14 inputs per hour.**

   | Group | Inputs |
   |---|---|
   | This station (10) | `level_above_normal`, `level_change_1h`, `level_change_2h`, `level_change_3h`, `same_time_12h_ago`, `same_time_25h_ago`, `rain_sum_1h`, `rain_sum_3h`, `rain_sum_6h`, `rain_sum_24h` |
   | Upstream stations (4, averaged) | `up_level_change_1h`, `up_level_change_3h`, `up_rain_sum_3h`, `up_rain_sum_6h` (left empty when a station has no upstream stations) |

   **What the river did one cycle ago.** `same_time_12h_ago` is the change over the 3 hours
   that followed the same moment 12 hours earlier, about one tide (12.42 h).
   `same_time_25h_ago` is the same 25 hours earlier, about one lunar day (24.84 h).
   - Taman Sri Muda is tidal: it rises and falls about twice a day, by a median of 1.6 m a day.
   - Each station's own history carries its tide timing, so no tide table is needed.
   - Inland stations simply learn that these inputs matter less.
   - On the Selangor readings of 20–23 Nov 2026, adding these two inputs gave:

     | | Before | After |
     |---|---|---|
     | MAE | 0.209 m | 0.124 m |
     | Recall (Alert or above) | 0.29 | 0.65 |
     | F1 | 0.36 | 0.76 |
     | Taman Sri Muda MAE | 0.345 m | 0.111 m |

   - Clock-based tide waves (sin and cos of the time over 12.42 h and 24 h) added little,
     so they are not used.

   Upstream links come from the stations file. The Klang target is Taman Sri Muda
   (`BKLG0002L`), with Puchong Drop (`BPTL0004L`) and USJ 1 (`BPTL0061L`) upstream
   (`ml/stations_klang.json`).

   **Training on many stations (`ml/stations_training.json`).** Three stations give few rows
   and, until the river floods, no Alert-level hours at all. The inputs are all relative to
   each station (level above its own normal, changes, rain), so one model can learn from
   every sound river station in **Selangor and Melaka**, and every station gets a forecast.
   The file holds the three Klang stations unchanged (with their upstream links), then about
   120 Selangor and 20 Melaka stations. Thresholds are read from the same JPS sites as the
   logger: the Selangor feed, and the Melaka site plus publicinfobanjir, under the codes
   the logger stores readings with. Each station has a `state`, and `metrics.json` reports
   the main results per state (`by_state`), so a good overall score cannot hide a state the
   model does badly in. It is made with
   `python -m jps_logger.stations_file --base ../ml/stations_klang.json --data ../data --out ../ml/stations_training.json`
   (run in `logger/`). A station is left out when:
   - a threshold is missing or 0, or the thresholds are out of order;
   - it has under 300 logged readings;
   - its level never moves (a stuck sensor);
   - its usual level is already at or above Alert.

   Export with `--stations ../ml/stations_training.json` and train with
   `--stations stations_training.json`.

   First run on both states (17–23 Nov 2026 archive):

   | | Stations | Test rows | MAE (no change) | Alert-or-above hours | F1 |
   |---|---|---|---|---|---|
   | Selangor | 123 | 2,538 | 0.122 m (0.248 m) | 52 | 0.76 |
   | Melaka | 20 | 420 | 0.185 m (0.301 m) | 13 | 0.56 |

   A Melaka-only model did no better on Melaka (MAE 0.184 m), so one shared model is used.
3. **Training (`train.py`, `ensemble.py`).**
   - A **weighted tree ensemble** of XGBoost, LightGBM, CatBoost and a random forest
     (XGBoost's random-forest mode), all predicting the 3-hour change.
   - Weights are 1 / MAE on a validation slice at the end of the training period, and sum to 1.
     The models are then retrained on all training rows.
   - The ensemble's TreeSHAP values are the same weighted average of each model's TreeSHAP
     values, so they still add up exactly to the forecast.
   - The split is **by time**: the oldest 80% of hours train the model and the newest 20% test
     it, with a 3-hour gap so no future value leaks into training. There is no random split.
   - Training needs at least 200 training rows and 50 test rows.
4. **Evaluation.**
   - The model is compared with two baselines:
     - "no change" (the river stays where it is);
     - the straight-line trend used by the existing FloodWatch app (a line through the last
       4 hourly levels, extended 3 hours).
   - Reported measures are **prediction metrics only** (`ml/flood_ml/metrics.py`; the forecast
     is a water level, not a yes/no answer): MAE, RMSE, Nash-Sutcliffe efficiency (NSE),
     Willmott's index of agreement (d), persistence index (PI: 0 = no better than "no change"),
     bias and peak error. They are given overall, on high-water hours, and per state.
     NSE and d are worked out within each station, because river levels use local datums.
     Sources: `docs/literature.md`. Accuracy, precision, recall, F1, AUC and confusion
     matrices were removed in Nov 2026 at the supervisor's request (older tables below
     still show them).
   - **Model comparison (`compare.py`).** 16 methods on the same inputs, split and metrics:
     no change, the FloodWatch line, ridge regression, SVR, k-nearest neighbours, random
     forest, extra trees, histogram gradient boosting, MLP, LSTM and GRU (only when PyTorch
     is installed), each ensemble member on its own, and the weighted ensemble. Run `python -m flood_ml.compare --practice` (or
     `--stations stations_klang.json --readings readings.csv`); it prints a table and writes
     `ml/output/comparison.json`.
5. **Likely range (`band_m`).** The error that 80% of test forecasts stayed within. The app
   shows *likely between* `predicted ± band_m`.
6. **Explanation (`predict.py`).** Exact **TreeSHAP** (each member's built-in TreeSHAP, averaged
   with the ensemble weights) splits each prediction into one contribution per input, in
   metres, plus a base value. These add
   up exactly to the predicted change, so every reason shown is part of the real calculation,
   not a separate guess.
7. **Output (`run.py`).** Writes `forecast.json` (schema 1): per station, the current level,
   the predicted level, low and high, and the factors with their `impact_m`. It also writes
   `metrics.json` and `model.json`.

### In the app (Dart, `packages/flood_core`)

- **The file is refused** if:
  - the schema is wrong, the horizon is outside 1–24 h, a number is not finite, or the range
    does not contain the prediction;
  - it is over 2 hours old or dated in the future.
- **A station's forecast is refused** if:
  - it is based on readings over 2 hours old;
  - it is absurd: a change over 5 m, or a level far outside the station's thresholds.
- **Trend.** Rising or falling if the change is at least 5 cm, otherwise steady.
  - *Predicted risk* uses the most likely level.
  - *Worst case* uses the top of the range ("If it reaches the top of the range: Amaran").
- **Reasons.** The three inputs with the largest effect (at least 1 cm) are shown as sentences
  in English, Malay or Chinese, such as "River rose 0.12 m in the last 3 hours (raises the
  forecast)".

### Current status: practice forecast, automatic switch to the real model

Real JPS logging started on **17 Nov 2026**, so there is not yet enough history to train a
trustworthy model. Until there is:

- **Live mode.** The AI forecast card shows a **practice forecast**: a simple rule worked out
  in the app (rain pushes the river up; a high river drains slowly back). It is clearly marked
  *Practice forecast · Not real predictions yet*. It appears **on the forecast card only**: it
  never makes alerts, list arrows or station-page forecasts.
- **Sample mode.** The made-up stations use a sample `forecast.json` in the model's format.
- **Switching.** The live app first tries to download the real `forecast.json` from Supabase
  Storage (`forecasts/forecast.json`). It falls back to practice only if that file is missing,
  invalid or over 2 hours old. When the hourly model job starts uploading, every phone
  switches on its next refresh, with no app release. The steps, quality gate and rollback are
  in **[docs/forecast-switch-plan.md](docs/forecast-switch-plan.md)**.

Run the model yourself on generated practice data (the numbers are **not results**):

```powershell
cd ml
python -m venv .venv
.venv\Scripts\activate
pip install -r requirements.txt
python -m flood_ml.run --practice            # writes ml/output/{model,metrics,forecast}.json
```

On real JPS readings (archive in `data/` plus, with the Supabase variables set, the last 30
days from the database):

```powershell
cd logger
python -m jps_logger.export --since 2026-11-17 --stations ..\ml\stations_training.json --out ..\ml\readings.csv
cd ..\ml
python -m flood_ml.run --stations stations_training.json --readings readings.csv --weather ..\data\forecast
```

Retraining, then running the debug app on live data, step by step:
[docs/dev-roadmap.md](docs/dev-roadmap.md#how-to-retrain-and-run-the-app-on-real-jps-data).

---

## Tech stack

| Layer | Technology |
|---|---|
| Mobile app | **Flutter** (Dart 3, Material), Android first. Web and Windows run as previews. |
| App logic | `packages/flood_core`: pure Dart (models, risk rules, services), fully unit-tested |
| Maps and location | `flutter_map` + OpenStreetMap tiles, `latlong2`, `geolocator` |
| Phone features | `local_auth` (fingerprint/PIN lock), `flutter_tts` (read aloud), `url_launcher` (999, SMS, WhatsApp, Google Maps), `shared_preferences`, `flutter_native_contact_picker` |
| Push | Firebase Cloud Messaging (`firebase_core`, `firebase_messaging`), free plan |
| Backend | **Supabase**: Postgres with row-level security, anonymous auth, Storage, `pg_cron`, Edge Functions (TypeScript/Deno: `route`, `send-alerts`) |
| Routing | openrouteservice (HeiGIT), called only from the Edge Function |
| AI / ML | Python 3.13, pandas, numpy, **XGBoost, LightGBM, CatBoost** (weighted ensemble), TreeSHAP (built into each), scikit-learn (comparison) |
| Data logger | Python, `requests`, pandas, run by GitHub Actions, started every 15 min by Supabase `pg_cron` |
| CI | GitHub Actions: Dart, Flutter, Supabase SQL, Edge Function, ML and logger tests on every push |
| Data source | JPS Selangor public API, JPS Melaka public pages, national JPS pages (publicinfobanjir.water.gov.my); each state has a first and a second source |

---

## Repository layout

```
app/                  Flutter app (screens in lib/screens, wiring in lib/main.dart)
packages/flood_core/  Pure-Dart logic shared by the app: models, risk, forecast, alerts, services
ml/                   Python forecasting pipeline (flood_ml) + stations files + tests
logger/               Python JPS logger, daily archive, export to CSV for the model
supabase/             SQL (tables, RLS, views, cron), Edge Functions, database tests
places/               Relief centres and resource points (CSV), uploaded to Supabase by CI
data/                 Daily archive of logged readings (*.csv.gz), written by CI
docs/                 Development log, daily updates, UI test plan, forecast switch plan
.github/workflows/    log_jps, log_weather, log_jkr, archive_jps, places, test
```

---

## Install and run

### Prerequisites

- **Flutter 3.50 (stable) or newer.** It includes Dart; `pubspec.yaml` needs Dart SDK ≥ 3.14.
  Follow https://docs.flutter.dev/get-started, choose *Android*, and install to a short path
  with no spaces (e.g. `C:\dev\flutter`).
- **Android Studio**, for the Android SDK, platform tools and the emulator. Run
  `flutter doctor --android-licenses`.
- **Git.** Optionally Python 3.13 (ML and logger) and Node.js 22.18+ (Supabase tests).
- Keep the project **outside OneDrive** (e.g. `D:\dev\fyp-flood-system`), then run
  `flutter doctor` and fix anything marked with a red cross.

```powershell
git clone <this repository>
cd fyp-flood-system\app
flutter pub get
```

### Sample mode or live mode

| Mode | When | What you see |
|---|---|---|
| **Sample** | no `app/secrets.json`, or run without it | made-up stations, sample relief centres and sample forecast; push and in-app routes off; works offline |
| **Live** | `app/secrets.json` present and passed to Flutter | real JPS stations (Klang river saved by default), real relief centres, push alerts, in-app routes, practice/real AI forecast |

For live mode, create `app/secrets.json`. It is in `.gitignore`, so never commit it:

```json
{
  "SUPABASE_URL": "https://YOUR-PROJECT-REF.supabase.co",
  "SUPABASE_PUBLISHABLE_KEY": "sb_publishable_..."
}
```

Then add `--dart-define-from-file=secrets.json` to any `flutter run` or `flutter build` command.
In VS Code, the included launch configuration (**Run → "Flood app"**, `app/.vscode/launch.json`)
already does this.

### On an Android phone (recommended)

1. On the phone: Settings → About phone → tap *Build number* 7 times. Then Developer options →
   turn on **USB debugging**.
2. Plug it in, accept the prompt, and check it is listed by `flutter devices`.
3. Run:

   ```powershell
   cd app
   flutter run --dart-define-from-file=secrets.json      # live
   flutter run                                           # sample
   ```

Requirements:
- Android 7.0 (API 24) or newer. The package name is `com.scenery9.floodready`.
- **Push notifications** also need `app/android/app/google-services.json` from your Firebase
  project (in `.gitignore`). Without it the app runs normally with push turned off.

Install a release build without a cable:

```powershell
flutter build apk --release --dart-define-from-file=secrets.json
# app\build\app\outputs\flutter-apk\app-release.apk  -> copy to the phone and open it
```

### On the Android emulator

1. Android Studio → *Device Manager* → **Create device**. A Pixel phone with a recent
   **Google Play** system image (API 34+) works well, because push needs Google Play services.
2. Start it, then check it appears in `flutter emulators` / `flutter devices`.
3. Run it with `flutter run --dart-define-from-file=secrets.json` (or pick the emulator in
   VS Code's device list and press F5).

Emulator tips:
- **Location.** The emulator has no GPS. Open *Extended controls (⋯) → Location* and set a
  point, e.g. Taman Sri Muda 3.0185, 101.5310. If location is refused, the app uses a default
  point and says so.
- **Fingerprint lock.** First set a screen PIN in the emulator's Settings → Security and add
  a fingerprint. When the app asks, touch the sensor from *Extended controls → Fingerprint*.

### In a web browser (preview)

```powershell
cd app
flutter run -d chrome --dart-define-from-file=secrets.json
# or a static build:  flutter build web --dart-define-from-file=secrets.json   (output in app\build\web)
```

The web build is for quick previews and demos. Phone-only features are off or limited:
- no push notifications;
- no household lock (the page opens unlocked);
- no contact picker;
- location comes from the browser and needs `localhost` or HTTPS.

The layout is designed for a phone, so use the browser's device toolbar (F12 → phone size).

### Windows desktop (preview)

`flutter run -d windows` works for previewing screens. It needs Visual Studio with the
*Desktop development with C++* workload. Phone features are off, as on the web.

### Troubleshooting

- **Android build fails inside `.gradle\caches\...\transforms`.** The Gradle cache is damaged.
  Close VS Code and Android Studio, end any `java` processes, delete that cache folder, run
  `flutter clean`, then build again.
- **Live mode shows sample stations.** `secrets.json` was not passed. Add
  `--dart-define-from-file=secrets.json`, or use the VS Code launch configuration.
- **"No forecast for this area right now".** The station is not a river station with
  thresholds and a fresh reading (for example a rain gauge, or a sensor offline for over 2
  hours).

---

## Backend setup (live mode)

You only need this to run your own live backend. Full details and history are in
[docs/development-log.md](docs/development-log.md).

1. **Supabase project (free plan).** In the SQL Editor run, in order:
   1. `supabase/schema.sql`
   2. `supabase/readings.sql`
   3. `supabase/staff_districts.sql`
   4. `supabase/alerts.sql`
   5. `supabase/routing.sql`
   6. `supabase/public_reports.sql`
   7. `supabase/household_groups.sql`
   8. `supabase/places.sql`
   9. `supabase/sources.sql`
   10. `supabase/reading_problems.sql`: lets the app say *why* a station has no usable level
       (JPS shows the sensor offline, an estimated value, no value, an out-of-date time, or a
       0.00 m glitch). Until it is run, the logger leaves these columns out, with a warning.

   Security pack. **First**, once, make the column encryption key in Vault (do not save it anywhere else):
   `select vault.create_secret(encode(extensions.gen_random_bytes(32), 'hex'), 'column_encryption_key');`
   Then run:
   11. `supabase/security.sql`: pgcrypto encryption of headcount free text and staff phone numbers
   12. `supabase/family.sql`: family roster, one shelter registration per family, encrypted live location
   13. `supabase/shelter.sql`: capacity- and wheelchair-aware centre allocation, supplies needed vs stock
   14. `supabase/report_triage.sql`: 3 reports/hour limit, credibility score, report clusters for staff

   Weather and incidents (public data, read by everyone, written only by the logger):
   15. `supabase/weather.sql`: 3-day rain forecast (Open-Meteo, MET Malaysia) and the outlook
   16. `supabase/jkr.sql`: JKR disaster incidents and the JPS gauges near each one

   Then turn on Authentication → *Allow anonymous sign-ins*.
2. **GitHub repository secrets:** `SUPABASE_URL` and `SUPABASE_SECRET_KEY`. The secret key
   can write to the database, so never put it in the app, in code or in screenshots. The
   repository must be public for unlimited free Actions minutes. Run *Log JPS Selangor and
   Melaka readings* once by hand.
   **Logger schedule:** make a fine-grained GitHub token (this repository only, *Actions: Read
   and write*), put it in `supabase/logger_schedule.sql` and run that file. Supabase then starts
   the logger every 15 minutes. Do not commit the filled-in copy; renew the token before it expires.
3. **Firebase.** Add an Android app `com.scenery9.floodready` and put `google-services.json` in
   `app/android/app/`. Generate a service-account key; it is a secret.
4. **Edge Function secrets:** `ORS_API_KEY` (from account.heigit.org),
   `FIREBASE_SERVICE_ACCOUNT` and `ALERTS_CRON_SECRET`. Then deploy:

   ```powershell
   npx supabase login
   npx supabase link --project-ref YOUR-PROJECT-REF
   npx supabase functions deploy route --no-verify-jwt
   npx supabase functions deploy send-alerts --no-verify-jwt
   ```
5. **Alert schedule.** Fill in and run `supabase/alerts_schedule.sql`. Do not commit the
   filled-in copy.
6. **Relief centres.** Edit `places/*.csv` and push. The *places* workflow uploads them.
7. **AI forecast.** See [docs/forecast-switch-plan.md](docs/forecast-switch-plan.md) (bucket
   `forecasts`, hourly job).

---

## Tests

All of these run on every push in `.github/workflows/test.yml`.

| Part | Command |
|---|---|
| Logic (`flood_core`) | `cd packages/flood_core; dart pub get; dart test` |
| App (widgets and flows) | `cd app; flutter test` |
| ML pipeline | `cd ml; python -m pytest -q` |
| Logger | `cd logger; python -m pytest -q` |
| Database rules (RLS, alerts, routing, reports, places) | `cd supabase/test; npm install; npm test` |
| Edge Functions | `cd supabase/functions; node --test tests/*.test.ts` |

The test plan IDs (TP1–TP96, SQL1–SQL10, ML1–ML10, LG, AR, PL, RP, AL, RT, EF) and what each
one checks are listed in [docs/development-log.md](docs/development-log.md). The manual UI
checks are in [docs/ui_test_plan.md](docs/ui_test_plan.md).

---

## Limitations

**AI forecast**
- The live AI forecast is still a **practice rule**, not the trained model, until enough real
  readings have been logged (logging began 17 Nov 2026). Model results printed from practice
  data are not findings.
- The real model is trained on, and forecasts, all 143 stations in `ml/stations_training.json`.
  Only Taman Sri Muda (`BKLG0002L`) has upstream links (Puchong Drop and USJ 1), and those
  still need to be checked on a map. A few stations send single faulty readings (e.g. 32.8 → 16.0 → 32.7 m) that cleaning
  does not yet remove; see [docs/dev-roadmap.md](docs/dev-roadmap.md).
- The level model has a fixed **3-hour horizon** and gives a single likely range.
- The **chance of flood in the next 24 hours** (`ml/flood_ml/probability.py`) is a separate
  XGBoost classifier per JPS level, calibrated on the newest day it did not learn from. "Flood"
  in the headline means the river reaching **Warning (Amaran)**; Alert and Danger are shown
  beside it, never higher than the level below. The app says it as a band (Low < 10%,
  Moderate 10-30%, High 30-60%, Very high >= 60%) with up to 3 reasons for and 1 against,
  grouped from the TreeSHAP values (e.g. "Moderate rain without a break for 7 hours").
  On unseen test days (23-24 Nov) the Warning chances matched what happened (stated 17% /
  41% / 72%, happened 21% / 39% / 71%), but are only slightly better than
  always stating the average rate (Brier skill 0.07); Alert is better (skill 0.15); Danger is barely better than the
  average rate (skill 0.01), so it is shown small. Treat all three as rough until more days
  are logged; the check is in `docs/rain-forecast-evidence.md`, section 3b.
- If a sensor is offline for **over 2 hours**, that station gets no forecast. Missing rain
  gauges are not replaced by nearby ones yet.
- The forecast file is signed (Ed25519, `ml/flood_ml/sign.py`), but the app trusts no key until
  the real one is added, so it shows the practice forecast for now.
- Inputs are chosen on the newest training days, each predicted by a model trained only on
  earlier days (`train.choose_inputs`), judged first on high-water hours and new Alert crossings
  (`scoring.py`). Candidates: observed only, + rain history (continuous rain, antecedent
  precipitation index), + next-day or 3-day forecast, and a residual correction that can only
  switch itself on when it helps (`residual.py`). On the first 8 logged days the forecast did
  not help on unseen days, so the 3 h model uses observed readings only; it is re-decided as
  more days are logged. Why each input: [docs/literature.md](docs/literature.md).
  MET Malaysia publishes no past forecasts, so its inputs fill in only as the logger runs.

**Data**
- Data comes from public JPS pages and APIs, which can be late, wrong, stuck or blocked.
  GitHub may start scheduled runs 15–30 minutes late, so an alert can arrive up to about
  30 minutes after the river changes.
- JPS Melaka updates about once an hour.
- Rain bands are provisional. Rain is shown but does not change the river risk level.
- Home area cards show rain from the station's own gauge or the nearest reporting gauge
  within 10 km (named, with its distance). The station lists and station page show only a
  station's own gauge. Saved-area cards on Home do not yet open the station page when tapped
  (it opens from lists, the map and the High-risk list).

**Platforms**
- Push notifications are **Android only**; an iPhone needs an Apple developer account.
- Web and Windows are previews without phone features.

**Backend**
- Staff screens are not built yet (the rules and the database are).
- Each phone is an anonymous Supabase user, and reinstalling creates a new one.
- Free-plan limits:
  - Supabase becomes read-only at 500 MB, and the logger keeps it near 150 MB.
  - Supabase pauses after 7 days idle; the logger's writes keep it active.
  - openrouteservice allows about 2,000 routes a day, shared by every user.
  - GitHub disables scheduled workflows after 60 days without a commit.

---

## More documents

- [docs/forecast-switch-plan.md](docs/forecast-switch-plan.md): moving the AI forecast from
  practice to the real model.
- [docs/development-log.md](docs/development-log.md): the build history (rounds 1–8), detailed
  setup notes and every test-plan table.
- [docs/daily-updates.md](docs/daily-updates.md): progress notes.
- [docs/ui_test_plan.md](docs/ui_test_plan.md): manual UI test plan.
- [places/README.md](places/README.md): relief centre and resource point files.
