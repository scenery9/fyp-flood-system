# FYP Flood System — backend core (rounds 1 to 3)

`packages/flood_core` is the app's logic layer in pure Dart: data models, risk rules and
the services behind Home, Station Detail, Manage My Areas, Live Rainfall, Live River
Level, Warnings and Share. It has no screens. The Flutter app will import it later.

**All station data here is SAMPLE data** (invented thresholds and readings). The live
feed plugs in later by writing one new class that implements `StationRepository`.

## Which function serves which screen

| Screen | Call |
|---|---|
| Home | `HomeService.load()` → area cards + high-risk list |
| Station Detail | `MonitoringService.statusFor(id)` |
| Manage My Areas / star button | `FollowedAreasService` (`follow`, `unfollow`, `toggle`, max 5) |
| Live Rainfall / River Level | `StationListService.apply(...)` (search, state filter, sort) |
| Warnings | `WarningService.active(...)` |
| Share button | `ShareFormatter.statusText(...)` |

## Rules built in (change in one place if your supervisor disagrees)

- Risk level comes from river level vs the station's thresholds (`risk_calculator.dart`).
- Percent = rise from normal level towards the next level, 0–100.
- A reading older than 3 hours is stale: still shown, never raises a warning.
- Sensor codes -9999 / -8888 count as "no data".
- Rainfall bands 10 / 30 / 60 mm/hr are provisional (`risk_level.dart`).

## Run the tests

**On GitHub (no install):** push this folder to a GitHub repo. The "Tests" workflow runs
on every push; see the Actions tab for a green tick or red cross.

    git init
    git add .
    git commit -m "Backend core round 1"
    git branch -M main
    git remote add origin https://github.com/<your-username>/<your-repo>.git
    git push -u origin main

**On your computer (after installing Flutter, which includes Dart):**

1. Install Flutter by following https://docs.flutter.dev/get-started (choose Windows → Android).
   Install to a short path with no spaces, e.g. `C:\dev\flutter`.
2. Keep this project outside OneDrive, e.g. `C:\dev\fyp-flood-system`.
3. Run `flutter doctor` and fix anything marked with a red cross.
4. Then:

       cd C:\dev\fyp-flood-system\packages\flood_core
       dart pub get
       dart test

Expected last line: `All tests passed!` (234 tests).

## Test plans

| Plan | File | What it checks |
|---|---|---|
| TP1 Models | models_test | level order, threshold validation, fault-code cleaning, rain bands |
| TP2 Distance | models_test | zero, known distance, symmetry, invalid coordinates |
| TP3 Risk level | risk_calculator_test | every threshold boundary, percent, 0–100 clamp |
| TP4 Missing/old data | risk_calculator_test | no reading, offline sensor, rainfall-only, stale boundary, clock skew |
| TP5 Cause + distance | risk_calculator_test | cause wording, distance needs both locations |
| TP6 Followed areas | followed_areas_test | add, duplicate, limit of 5, unknown id, unfollow, toggle, restart, damaged data, failure |
| TP7 Search/filter | station_list_test | case, district/state match, no match, state filter |
| TP8 Sorting | station_list_test | risk, percent tie, nearest, no location, rainfall mode, list not mutated |
| TP9 Monitoring/detail | home_warning_share_test | all stations, one station, unknown id, source failure, empty |
| TP10 Home | home_warning_share_test | cards order, high-risk rules, limit, removed station |
| TP11 Warnings | home_warning_share_test | order, minimum level, newest first, none |
| TP12 Share | home_warning_share_test | full, stale and no-data text |
| TP13 Sample data | regression_test | ids unique, every UI case present |
| TP14 Regression | regression_test | whole flows: one function must not change another's result |

## Round 2: public actions, staff portal, assistant

| Screen | Call |
|---|---|
| Evacuation | `EvacuationService.nearest(...)`, `directionsUrl(...)` |
| Headcount | `HeadcountService.submit(...)`, staff `summary(...)` |
| Report Flood Damage / My reports | `DamageReportService.submit(...)`, `mine(...)` |
| What To Do | `GuidanceService.steps(...)`, `forStatus(...)` |
| My Alerts | `AlertService` (`setRiskRule`, `setWaterLevelRule`, `evaluate`) |
| Settings | `SettingsService` + `AppSettings` |
| Ask the Assistant | `AssistantService.ask(...)` (rule-based, free, lists its sources) |
| Staff login | Supabase Auth, then `StaffAccountService.sessionFor(userId)` |
| Staff Accounts | `StaffAccountService` (Super Admin only) |
| Damage Reports (staff) | `DamageReportService.list / verify / reject / markDuplicate` |
| Resource / Evacuation Points | `ResourceService`, `EvacuationService` staff methods |
| Map Inventory, Supply Alerts | `ResourceService.mapItem`, `supplyAlerts`, `expiringItems` |
| Staff Overview | `StaffOverviewService.load(...)` |

Every staff method takes the staff session first and checks the role in `AccessControl`.
Storage sits behind `Table<T>`; tests use `MemoryTable`. The Supabase connection code
(one `Table` per database table) is not written yet.

### Rules built in (confirm with your supervisor)

- Roles: Super Admin does everything; Coordinator everything except staff accounts;
  Field Officer reviews reports, updates stock quantity and shelter occupancy only.
- Damage reports: date not in the future and not over a year old, depth 0-10 m or blank,
  at most 5 unreviewed reports per person, reject needs a note, reviewed once only.
- Headcount: 1-30 people, one entry per household (resubmitting replaces it).
- Supply alert: stock lasts under 3 days for the people in the open centres a resource
  point supplies. Expired and unmapped stock is not counted.
- Alerts notify once when a rule becomes true, and again only after it has cleared.
- What To Do wording is a draft (English and Malay; Chinese not written).

### Database: `supabase/schema.sql`

Tables, row level security and triggers that enforce the same rules on the server, so a
modified app cannot bypass them. Paste it into the Supabase SQL Editor on a new project.
Public users need Supabase "anonymous sign-ins" turned on (Authentication settings).

`supabase/test/rls_test.mjs` runs 64 access checks (SQL1-SQL8) against a local Postgres
with a stand-in for Supabase Auth: `cd supabase/test`, `npm install`, `npm test` (needs
Node.js). It has NOT been run on a real Supabase project.

### Round 2 test plans

| Plan | File | What it checks |
|---|---|---|
| TP15 Roles | access_staff_test | permission matrix, no session, wrong role, deactivated |
| TP16 Staff accounts | access_staff_test | login, create, validation, duplicates, last Super Admin |
| TP17-18 Evacuation | evacuation_headcount_test | nearest, closed/full, directions link, staff add/delete/occupancy |
| TP19 Headcount | evacuation_headcount_test | validation, boundaries, replace, summary, withdraw |
| TP20 Report damage | damage_report_test | date/depth/description limits, anti-spam, my reports |
| TP21 Review | damage_report_test | verify, reject note, duplicate, review once, tabs, storage failure |
| TP22 What To Do | personalise_test | all levels, languages, unknown/old data |
| TP23 Settings | personalise_test | defaults, restart, damaged values, threshold |
| TP24 My Alerts | personalise_test | rules, fire once, re-arm, threshold, old data, limit |
| TP25-27 Resources | resources_overview_test | points, stock, mapping, expiry, supply alerts |
| TP28 Overview | resources_overview_test | counts, nearby risk |
| TP29 Assistant | assistant_test | every intent, Malay keywords, old data, nonsense input |
| TP30 Regression | regression2_test | public+staff flows, every staff call refuses no-session, round 1 unchanged |
| SQL1-SQL8 | supabase/test/rls_test.mjs | database access rules per role |

## Round 3: routing, map data, AI forecast

| Screen | Call |
|---|---|
| Evacuation (turn-by-turn) | `EvacuationRouteService.toNearest(user)` → live route, saved route, or none |
| Live Map | `MapService.liveMap(...)` → markers, styles, area to show |
| Operations Map (staff) | `MapService.operationsMap(session)` |
| Forecast line and "Kenapa?" | `ForecastService.load(statuses)` → summary + up to 3 reasons |

These give the screens their data. The map and route drawing are UI work (not written).

### Routing: openrouteservice

1. Create a free account at https://openrouteservice.org and make an API key
   (free plan: about 2,000 direction requests a day, 40 a minute).
2. Never commit the key. Pass it when running the app:
   `flutter run --dart-define=ORS_KEY=your_key`
3. The app gives `OrsRouteProvider` a small download function (`HttpGet`) built on the
   `http` package. Tests use a canned reply, so **the reply format has not been checked
   against the live service**: make one real request and compare before relying on it.

Rules: nearest centre is by straight line; the last route is saved and reused offline only
for the same centre and if you are within 1 km of where it started; otherwise the screen
gets a Google Maps link.

### AI forecast: `ml/` (Python)

Predicts the river level 3 hours ahead per station with XGBoost, then explains each
forecast with SHAP values (how many metres each input added or removed). The app turns
the level into Normal / Waspada / Amaran / Bahaya with the station thresholds.

**It currently runs on generated PRACTICE data. The numbers it prints are not results
and must not go in the report as findings.**

    cd ml
    python -m venv .venv
    .venv\Scripts\activate
    pip install -r requirements.txt
    python -m pytest -q
    python -m flood_ml.run --practice

Outputs in `ml/output/`: `model.json`, `metrics.json`, `forecast.json`. With real data:
`python -m flood_ml.run --readings readings.csv` (columns `station_id,time,rainfall_mm,
river_level_m`; `ml/stations.json` holds each station's thresholds and must use real values).

Station files:
- `ml/stations.json`: the app's sample stations, for practice runs and tests. Its upstream link
  (JHR-BULOH upstream of JHR-AWAT) exists only to exercise the code.
- `ml/stations_klang.json`: the Klang river target. Codes and thresholds were read from the JPS
  Selangor API on 17 Nov 2026. Taman Sri Muda (BKLG0002L) is forecast using Puchong Drop
  (BPTL0004L) and USJ 1 (BPTL0061L) as upstream stations. **Check on a map that both really
  are upstream on Sg. Klang before relying on this.** Run it with
  `python -m flood_ml.run --stations stations_klang.json --readings readings.csv`
  (`station_id` = JPS `stationCode`).

Each station may list `"upstream": [ids]`; every id must be in the same file.

Method choices to confirm with your supervisor:
- Target is the change in level over the next 3 hours (added to the current level).
- Inputs: level above normal, change over 1 h and 3 h, rain over 1, 3, 6 and 24 h; and,
  averaged over the upstream stations, their level change over 1 h and 3 h and rain over 3 h
  and 6 h (left empty for a station with no upstream stations).
- Split by time (oldest 80% trains, newest 20% tests), with a 3-hour gap. No random split.
- Compared against two baselines: "no change", and the straight-line trend of the existing
  FloodWatch app (a line through the last 4 hourly levels extended 3 hours; changes slower
  than 0.02 m/h count as no change; with fewer than 4 readings it is scored as no change and
  counted in `fallback_rows`). That app fits 15-minute readings over 3 to 6 hours, so this is
  an hourly approximation of its method. Reports MAE, RMSE, and recall, precision, missed
  events and false alarms for Alert-or-above, for the model and both baselines.
- The likely range is plus or minus the error that 80% of test forecasts stayed within.

The app refuses a forecast that is over 2 hours old, dated in the future, based on old
readings, or absurd (over 5 m change), and shows nothing instead.

Not built yet: the scheduled job that runs the model hourly on the logged data and
publishes `forecast.json`; signing the file; Malay and Chinese wording for the reasons.

### Data logger: `logger/` (Python, runs on GitHub every 15 minutes)

Records every JPS Selangor river-level and rainfall station (all 9 districts, about
330 stations) into Supabase, so real readings build up for the model. JPS only shows
each station's latest value, so a reading that is not logged in time is lost.

Two GitHub workflows:
- `log_jps.yml`, every 15 minutes: stores new readings in Supabase.
- `archive_jps.yml`, daily at 03:13 Malaysia time: saves each finished day to
  `data/YYYY/MM/YYYY-MM-DD.csv.gz` in this repository and pushes it, then deletes days
  older than 30 days from Supabase (only days whose file exists), then checks the
  database size. Supabase stays around 150 MB however long the logger runs; the full
  15-minute history is in `data/` (about 0.3-0.5 MB a day, roughly 100 MB for 8 months).

Setup (once):
1. Supabase dashboard -> SQL Editor -> paste `supabase/readings.sql` -> Run.
   (If you already ran an earlier version of this file, run only the part from
   `grant select, insert, delete` to the end.)
2. Supabase -> Settings -> API Keys: note the project URL and a **secret** key
   (`sb_secret_...`). The secret key can write to the database: never put it in code,
   the app, screenshots or chat.
3. GitHub repository (must be **public** for unlimited free Actions minutes) ->
   Settings -> Secrets and variables -> Actions -> New repository secret:
   `SUPABASE_URL` and `SUPABASE_SECRET_KEY`.
4. Actions tab -> "Log JPS Selangor readings" -> Run workflow. The log should end with
   "Read N stations: ... river levels, ... rainfall readings". After that it runs by itself.
5. Nothing to set up for the archive: it uses the same two secrets. Two days after the
   first readings, the first file appears in `data/`.

Because the archive workflow pushes to the repository every day, run `git pull` before
you push your own changes.

Exporting for the model (on your computer, PowerShell):

    cd logger
    pip install -r requirements.txt
    $env:SUPABASE_URL="https://YOUR-PROJECT.supabase.co"
    $env:SUPABASE_PUBLISHABLE_KEY="sb_publishable_..."   # reading only needs this key
    git pull                                             # newest archive files
    python -m jps_logger.export --since 2026-11-18 --stations ..\ml\stations_klang.json --out ..\ml\readings.csv
    # or, without any key, from the archive files only (up to two days ago):
    python -m jps_logger.export --since 2026-11-18 --no-database --out ..\ml\readings.csv
    cd ..\ml
    python -m flood_ml.run --stations stations_klang.json --readings readings.csv

How readings are stored:
- One row per station per JPS observation time. JPS keeps showing the last value until a
  new one arrives; repeats are ignored.
- Offline (-9999), empty, future-dated and stale (over 24 hours old) readings are skipped.
  Stuck stations, such as Kg. Jawa showing an October 2025 reading, are therefore not
  stored at all; they still appear in the station list. Because nothing older than a day
  is accepted, a day is complete two days later, and that is when it is archived.
- Rain: JPS `hourlyRainfall` is a rolling 60-minute total, so adding up four 15-minute
  snapshots would count the same rain about four times. Both JPS totals are stored as
  given, and the export works out rain per interval from `todayRainfall` (since midnight,
  Malaysia time). After a gap over 75 minutes, or if the day total goes down, that
  interval's rain is left empty instead of guessed.
- Station names, district, river basin, position and warning levels are refreshed each run.

Limits to know:
- **Not yet tested from GitHub's servers.** The first manual run shows whether JPS answers
  requests from GitHub (some government sites block overseas servers).
- GitHub may start a scheduled run late (sometimes 15-30 minutes) when busy, and turns
  scheduled runs off after 60 days without a commit. Gaps of up to 2 hours are filled
  by the model's cleaning step; longer gaps stay missing.
- Size: Supabase keeps 30 days (about 150 MB, estimated). The daily size check warns at
  300 MB and fails at 400 MB (GitHub then emails you); lower `KEEP_DAYS` in
  `logger/jps_logger/archive.py` if that happens. Check the real size after the first
  week. At 500 MB Supabase switches to read-only and new readings would be lost.
- If the archive job fails, those days stay in Supabase and are archived on the next
  successful run; nothing is deleted without its file.
- A district that cannot be read is reported as a warning and skipped; the run fails
  only when nothing could be read.

### Data logger test plans

| Plan | File | What it checks |
|---|---|---|
| LG1 Reading the JPS feed | logger/tests/test_jps | Malaysia time to UTC, offline/empty/future/stale readings, bad values |
| LG2 Station list | logger/tests/test_jps | both feeds combined, positions, basins, warning levels |
| LG3 One logging run | logger/tests/test_collect_export | stores all three tables, failing district, nothing read, dry run, duplicates |
| LG4 Supabase connection | logger/tests/test_collect_export | key only in apikey header, chunks, errors hide the key, paging |
| LG5 Rain per interval | logger/tests/test_collect_export | day total not rolling hour, midnight, gaps, corrections, per station |
| LG6 Export | logger/tests/test_collect_export | CSV the model reads, rainfall-only stations, limit to a river |
| AR1 Days and files | logger/tests/test_archive | Malaysia days in UTC, file paths, identical rewrites, empty days |
| AR2 Archiving | logger/tests/test_archive | finished days only, catch-up, nothing rewritten, day boundaries |
| AR3 Cleanup | logger/tests/test_archive | only archived days over 30 days old; unarchived days kept and reported |
| AR4 Size check | logger/tests/test_archive | below 300 MB, warning, failure at 400 MB |
| AR5 Export | logger/tests/test_archive | archive + database counted once, archive-only export without a key |
| AR6 Supabase calls | logger/tests/test_archive | delete range, earliest reading, size function |
| SQL9 Readings access | supabase/test/rls_test | only the logger writes and deletes; anyone reads; size check for the logger only; no negative rain |

### Round 3 test plans

| Plan | File | What it checks |
|---|---|---|
| TP31 openrouteservice | routing_test | request address, reply parsing, errors, save/restore |
| TP32 Evacuation route | routing_test | live, saved with age, none, moved away, centre changed, damaged save |
| TP33 Live map | map_test | styles by risk, unknown data, layers, filter, bounds |
| TP34 Operations map | map_test | staff only, shelters, warehouses, risk stations |
| TP35 Forecast file | forecast_test | valid file, practice flag, damaged files |
| TP36 Forecast line | forecast_test | rise/stay/fall wording, boundaries, worst case, steady band |
| TP37 Refusing forecasts | forecast_test | too old, future, download failure, absurd values |
| TP38 Reasons | forecast_test | wording per input (incl. upstream), top three, tiny impacts dropped, missing upstream not shown |
| TP39 Contract | forecast_test | app reads the file the Python pipeline wrote |
| TP40 Regression | regression3_test | forecast/map/route do not change other functions |
| ML1-ML6 | ml/tests | cleaning, features, no leakage, time split, beats baseline, explanation adds up, pipeline |
| ML7 Upstream inputs | ml/tests/test_features | averages, missing upstream station, no leakage, station file checks |
| ML8 Straight-line baseline | ml/tests/test_features | continues a rise, ignores tiny changes, not a model input |
| ML9 Baseline comparison | ml/tests/test_train_predict | straight-line results reported and beaten on practice data |
| ML10 Upstream explanations | ml/tests/test_train_predict | upstream inputs in forecast.json, Klang file runs end to end |
