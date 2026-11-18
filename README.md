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

Expected last line: `All tests passed!` (316 tests).

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
  Field Officer updates stock quantity and shelter occupancy only (and only sees damage
  reports). Since Round 6 each role is limited to an area: see "Round 6" below.
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

Since Round 6 the app asks our own Edge Function for routes (`EdgeRouteProvider`), so the
openrouteservice key is never inside the app. Setup is in "Round 6" below.

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

## Round 4: household details lock (security)

Public users can lock **My household** with their phone's own fingerprint, face or PIN.

| Rule | Where |
|---|---|
| First visit asks "Lock your household details?" with a "Don't ask me again" box | `HouseholdLockService` (flood_core) |
| Said no without ticking the box: asked again the next time the page is opened | same |
| Agreed: never asked again; the phone's prompt (fingerprint or PIN) is shown instead | same |
| One successful check unlocks it until the app is closed | same |
| Phone has no screen lock: told how to set one up, or "Skip for now" (until the app is closed) | same |
| Settings switch turns it on or off; turning off needs the fingerprint/PIN first | same |
| Phone prompt, saving on the phone, screens | `app/lib/security/`, `app/lib/main.dart` |

The lock only protects the page on the phone. The data itself is still protected by
Supabase login and row level security.

### The Flutter app: `app/`

    cd app
    flutter pub get
    flutter test
    flutter run        (with your Android phone plugged in, USB debugging on)

The fingerprint prompt only works on a real phone. In a Windows or web preview the
page opens without the lock.

Android setup for the prompt (already done unless noted):
- `USE_BIOMETRIC` permission in `android/app/src/main/AndroidManifest.xml`.
- `MainActivity.kt` must extend `FlutterFragmentActivity` (edit by hand, see below).
- Phones on Android 8 or older also need an AppCompat launch theme in `res/values/styles.xml`.

`android/app/src/main/kotlin/com/example/flood_app/MainActivity.kt` must contain:

    package com.example.flood_app

    import io.flutter.embedding.android.FlutterFragmentActivity

    class MainActivity : FlutterFragmentActivity()

### Round 4 test plans

| Plan | File | What it checks |
|---|---|---|
| TP41 Household lock rules | packages/flood_core/test/household_lock_test | first ask, don't-ask box, ask next time, once per app start, failed check, no phone lock, unsupported device, damaged saves |
| TP42 Lock Settings switch | packages/flood_core/test/household_lock_test | on/off, turning on after saying no, relocks at once, fingerprint/PIN needed to turn off |
| TP43 Lock screens | app/test/widget_test | question, prompt, failed prompt, don't-ask box, set-up message, Settings switch |

## Round 6: staff areas, live data, push alerts, safe routing

### Staff areas (who sees what)

| Role | Works in | Damage reports |
|---|---|---|
| Super Admin | every district | sees and reviews all |
| Coordinator | one district (`assigned_district`) | sees and reviews their district |
| Field Officer | one resource point and the centres it supplies | sees their point's district, cannot review |

- Districts are the 9 Selangor districts in the JPS spelling (`KLANG`, `PETALING`, ...).
  Resource points and relief centres must have one.
- A damage report's district comes from the nearest JPS station within 25 km, worked out
  by the database (the reporter cannot choose it). No station that close: Super Admin only.
- Same rules in the app (`StaffSession.covers...`, `AccessControl`) and in the database
  (`supabase/staff_districts.sql`).

### Push alerts (phone notifications, even with the app closed)

- The phone signs in to Supabase anonymously (no account), registers its Firebase token
  and sends its rules: every saved area at the "Notify me from" level, plus any river
  heights set on a station page ("Alert me at a river level").
- Every 15 minutes Supabase itself (pg_cron, not GitHub) calls the Edge Function
  `send-alerts`, which asks the database what is due (`alerts_tick`) and sends it with
  Firebase Cloud Messaging (free).
- When to notify (same in `AlertRules` in flood_core and in `alerts.sql`): when a rule first
  becomes true; again whenever the river moves up a level; every 45 minutes while at
  Danger; once gone for 60 minutes it starts again; height alerts have a 0.10 m buffer once
  they have fired; readings over 3 hours old change nothing. A send that fails is retried
  on the next run.

### Routing without a key in the app

The Edge Function `route` holds the openrouteservice key and checks the phone's login.
Limits (`routing.sql`): each phone 6 a minute and 60 a day; everyone 35 a minute and 1,800 a
day (the free plan allows 2,000 a day, 40 a minute). It uses the new address
`api.heigit.org` (the old `api.openrouteservice.org` was switched off on 28 Sep 2026).
Academic projects can apply for a larger free plan at https://openrouteservice.org/plans/.

### Setup (once, in this order)

1. **Database.** Supabase -> SQL Editor: run `supabase/staff_districts.sql`, then
   `supabase/alerts.sql`, then `supabase/routing.sql` (after `schema.sql` and
   `readings.sql`). Run the query at the end of `staff_districts.sql` and give every row
   it lists a district.
2. **Anonymous sign-ins.** Supabase -> Authentication -> Sign In / Providers -> turn on
   "Allow anonymous sign-ins".
3. **Firebase (free plan).** At https://console.firebase.google.com create a project, add
   an Android app with package name `com.scenery9.floodready`, and download
   `google-services.json` into `app/android/app/` (it is in `.gitignore`; the repository
   is public). Then Project settings -> Service accounts -> Generate new private key. That
   JSON file is a secret: never commit it or paste it in chat.
4. **Secrets for the Edge Functions.** Supabase -> Edge Functions -> Secrets, add:
   - `ORS_API_KEY`: your key from https://account.heigit.org
   - `FIREBASE_SERVICE_ACCOUNT`: the whole service account JSON from step 3
   - `ALERTS_CRON_SECRET`: a long random text (at least 20 characters), e.g. in
     PowerShell `[guid]::NewGuid().ToString() + [guid]::NewGuid().ToString()`
5. **Deploy the two functions** (needs Node.js; in the repository folder):

       npx supabase login
       npx supabase link --project-ref YOUR-PROJECT-REF
       npx supabase functions deploy route --no-verify-jwt
       npx supabase functions deploy send-alerts --no-verify-jwt

   `--no-verify-jwt` is intended: `route` checks the login itself (through the database)
   and `send-alerts` checks `ALERTS_CRON_SECRET`.
6. **Schedule.** Put your Project URL and the same `ALERTS_CRON_SECRET` into
   `supabase/alerts_schedule.sql` (do not commit it with the real secret), and run it in the
   SQL Editor. The end of that file shows how to check the runs.
7. **App.** `app/secrets.json` (in `.gitignore`) becomes:

       {
         "SUPABASE_URL": "https://YOUR-PROJECT-REF.supabase.co",
         "SUPABASE_PUBLISHABLE_KEY": "sb_publishable_..."
       }

   (the old `ORS_KEY` line is no longer used; remove it). Then `flutter pub get` and run.
   With these two values the app shows live JPS stations (Klang river by default) and
   offers More -> Notify me from -> "Turn on phone notifications". Without them it runs on
   sample data exactly as before, with push and in-app routes off.

### Limits to know

- An alert can arrive up to about 30 minutes after the river changes: JPS updates, the
  GitHub logger (sometimes late), then the 15-minute check. Not a replacement for official
  JPS/NADMA warnings; the app says so.
- Relief centres and the AI forecast in the app are still sample data. Staff screens are not
  built yet (the rules and the database are).
- Push is set up for Android only (iPhone needs an Apple developer account and
  `GoogleService-Info.plist`).
- Each phone is an anonymous user in Supabase Authentication; reinstalling the app makes a
  new one; when the same Firebase token registers again the old one stops getting alerts.
- Free Supabase pauses after 7 days without database activity; the logger's 15-minute
  writes keep it active.

### Round 6 test plans

| Plan | File | What it checks |
|---|---|---|
| TP24 My Alerts (updated) | flood_core personalise_test | first alert, level up, Danger every 45 min, 60-min reset, 0.10 m buffer, old data |
| TP15-16 Roles (updated) | flood_core access_staff_test | officers no longer review; coordinator needs a district, officer a resource point |
| TP63-67 Staff areas | flood_core staff_area_test | district names, points/stock/centres by area, damage reports by area, nearest-station district, overview |
| TP68 Anonymous sign-in | flood_core live_push_test | one sign-in, session kept, refresh, new sign-in when refused, errors |
| TP69 Live stations | flood_core live_push_test | one download, reuse for a minute, odd JPS data, server errors |
| TP70-71 Push registration | flood_core live_push_test | rules sent, retry after an expired login, height alerts on the phone |
| TP31 Routing (updated) | flood_core routing_test | app calls its own function, no key sent, error replies |
| TP72-73 Notifications UI | app push_test | not set up, permission, rules sent, blocked, retry, river-level alert box |
| SQL10 Staff areas | supabase/test/rls_test | every table limited by district / resource point; district set by the database |
| AL1-AL4 Push rules | supabase/test/alerts_test | access, sync, the same timing cases as TP24, failed sends retried, token clean-up |
| RT1 Route limits | supabase/test/routing_test | per-phone and total limits, old requests removed |
| EF Edge Functions | supabase/functions/tests | cron secret, Firebase JWT signature, grouping, retries, route validation, no key leaked |

Edge Function tests: `cd supabase/functions` then `node --test tests/*.test.ts` (Node.js 22.18
or newer). Database tests now run three files: `cd supabase/test`, `npm install`, `npm test`.

## Round 7: easier alerts, offline route guide, flood reports, headcount

Improvements from comparing the app with the reference app's walkthrough. The aim: no typing
where a button can do, and no setup before alerts work.

- **Alerts with no setup.** Saved areas, the river station nearest the user and stations within
  10 km are checked at the "Notify me from" level, which is now **Warning** by default. The
  app asks for notification permission once at first launch. Home shows the app name at the
  top (no banner); *More > Alerts near you now* lists one row per station (not a
  log of readings), plus what the AI expects to reach Warning or Danger within 3 hours.
  Push rules now include the nearest station (only from the phone's real location).
- **River-level alert without typing.** The station page offers the station's own JPS
  Alert / Warning / Danger heights as buttons (Warning suggested). Rain gauges get no
  river-level alert. Heights typed in an older version still show and can be removed.
- **Route guide.** Every road route is kept on the phone (last 3 centres). Home saves the
  route to the nearest open centre in the background, so it works without internet. The page
  says when it was saved, warns after 1 hour, and has *Update route from where I am*. Steps
  are worded by the app from the step type, so they read in English, Malay and Chinese. A
  large *Next step* card has Read aloud. River stations at Warning/Danger within 1 km of the
  route are shown as a warning, and centres over 10 km away get a reminder that closer ones
  may open.
- **Station lists by distance.** Rain and River layers on Centres: *Near me / Highest risk*,
  5 / 10 / 30 km buttons, distance and age on each row, a % bar towards the next level, the
  AI trend, and a star to save a station without opening it. With no saved areas, Home shows
  the station nearest the user with a Save button.
- **Report flooding** (Home button, More > Reports): *Flooding here now* or *Damage*; place
  from the phone or a pin on the map (shown as "Near Kg. Awat, Segamat", never coordinates);
  time as Now / 1 hour ago / 3 hours ago / Yesterday / Pick a date (last 60 days); water depth
  as Ankle / Knee / Waist / Chest / Not sure; damage type and how bad as buttons. *My reports*
  shows the officer's decision. A retry after a network failure is never counted twice.
- **"Tell this centre we're coming"** (Centres and route page): people coming, then the same
  − / + groups as the household form (babies or toddlers, children, adults, aged 60+; together
  never more than the people coming), wheelchair or walking aid, pets, and on/off switches
  for daily medicine and oxygen or a machine that needs power. Filled in from the household
  details (behind the household lock); other needs as buttons (wheelchair access, formula,
  diapers, cold medicine, other). Then *On the way / Arrived / Left the centre*; a headcount stops
  counting after 72 hours or when "Left" is tapped. If the chosen centre is not on the
  server (sample centres), the server picks the nearest open centre with space.
- **Location like a typical app.** When the app opens and location is not allowed yet,
  FloodReady first explains why (nearest station, alerts near you, closest centre), then the
  phone's own pop-up appears only after *Allow location*. *Not now* asks again next time
  unless *Don't ask me again* is ticked. Once allowed (even "Only this time"), the app uses
  location every time it opens; if Android's permission has since ended, only the phone's
  pop-up shows, never FloodReady's screen again. A refused-for-good permission is
  remembered, so the button opens the phone settings instead. *More > Use my location
  automatically* turns it on or off; off means GPS is not used and nothing is asked. Pull
  to refresh, the 15-minute reload and coming back to the app never show a pop-up.
- **Household form.** The people total stays as it was; under it, − / + for babies or
  toddlers, children, adults and aged 60+ ("2 of 4 counted"; + turns off when everyone is
  counted, and lowering the total takes people off the groups). Separate − / + for wheelchair
  or walking aid and for pets; switches for daily medicine and oxygen or a machine.
- **Prepare.** Safety tips (call 999 if you cannot leave, do not walk or drive through flood
  water, go to the highest floor if trapped) are tinted cards with an icon, not tick boxes,
  and are not counted. The 999 card has a one-tap *Call 999* button that opens the phone app.
  The Warning go-bag item lists *What to bring*, with extra lines for the household (medicine,
  spare battery for oxygen, baby items, glasses, walking aid, pet food).
- **Same numbers everywhere.** The River list badge shows the level now (like Home, the
  station page and saved areas). Rain is shown with one decimal on the map and in lists, and
  distances with one decimal.
- **Short station lists.** River and Rain rows show only the name (full width), the status
  and reading ("19.97 m ↑", the arrow from the AI forecast kept on the same line), distance
  and age, and for rivers "91% to Warning (8.20 m)" with a bar. The forecast and other details
  are on the station page (tap the row). On Home the forecast card shows "2 cm above the
  Danger line" smaller on its own line.
- **Smaller changes.** Add an area:
  nearest stations first and district buttons (search is last). Share opens WhatsApp or
  SMS directly. Emergency contact can be chosen from the phone's contacts. Centres show
  the drive time once known, an *Open with space only* filter, and a Call button when a
  centre has a phone number. Data reloads every 15 minutes while the app is open and when
  it comes back to the front.

### Setup (once)

1. **Database.** Supabase > SQL Editor: run `supabase/public_reports.sql` after the files in
   Round 6, then `supabase/household_groups.sql` (age groups, pets and health needs in the
   headcount). Without Supabase the app keeps reports and the headcount on the phone and says
   staff will not see them.
2. **App.** `flutter pub get` (new package: `flutter_native_contact_picker`, which uses the
   phone's own contact screen and needs no contacts permission).

### Limits to know

- The relief centres in the app are still sample data, so a headcount sent from the live
  build goes to the nearest centre the server knows. `reported_people()` gives per-centre
  totals for the staff screens (to be built).
- Expected alerts come from the AI forecast and are shown in the app only; push messages are
  still sent for official JPS levels.
- Hazards near the route use river stations within 1 km; they do not mean the road is closed
  or open.

### Round 7 test plans

| Plan | File | What it checks |
|---|---|---|
| TP80-86 | flood_core round7_test | step types, saved routes, hazards near a route, current step, level buttons, active alerts, nearest station, lists by distance, household counts, report and headcount rules, phone-only and Supabase versions |
| TP72-74 | app push_test | default Warning level, nearest station in push rules, first-launch question, level buttons instead of a height box |
| TP75-79 | app round7_ui_test | app name on Home and Alerts page from More, saved route without internet, steps in Malay, drive time, open-only filter, reports, headcount groups within the total, household − / +, safety cards and Call 999, go-bag list, contact picker, near-me list and star |
| TP87 | flood_core location_consent_test | explain first, phone pop-up only after agreeing, "Only this time", Don't ask again, blocked, More switch |
| TP88 | app location_test | the same rules on screen: question, Allow, Not now, next launches, no pop-up on refresh, More switch, blocked |
| RP1-RP2 | supabase/test/reports_test | sightings, retries, time limits, district, review cannot change a report; headcount centre choice, needs, age groups within the total, pets, status, 72-hour expiry, who sees what |

Run as before: `dart test` in `packages/flood_core`, `flutter test` in `app`,
`npm test` in `supabase/test` (now four files).


## Round 8: relief centres from a file, Melaka

- **Relief centres are real now.** The live build reads them from Supabase instead of the
  sample list. They are kept in `places/centres.csv` and `places/resource_points.csv`, one
  row per place (see `places/README.md`). Pushing a change to `places/` runs
  *Upload relief centres and resource points* (`.github/workflows/places.yml`), which checks
  every row and then makes Supabase match the files. The last list is kept on the phone, so
  Centres and the route guide work without internet.
- **Starting data.** The 5 centres the FloodWatch app showed (4 in Selangor, 1 in Melaka),
  with FloodWatch's hand-picked positions (marked checked) and estimated capacities (the app
  says "estimate"). Resource points: FloodWatch's 2 made-up depots, named DEMO.
- **Unchecked positions.** A centre with `location_checked = no` is listed, but has no map
  pin and no in-app route, is never suggested as the nearest centre or picked automatically for a headcount,
  and Google Maps searches for it by name.
- **Melaka.** The logger also reads the JPS Melaka pages (river level and rainfall, with the
  map positions from the page) every 15 minutes. JPS Melaka updates about once an hour.
  If its website blocks GitHub's servers or changes its layout, the run shows a warning and
  Selangor is still logged. Melaka's three districts (ALOR GAJAH, JASIN, MELAKA TENGAH) are
  added for staff areas and reports; the station page says "JPS Melaka data".

### Setup (once, in this order)

1. **Database first.** Supabase > SQL Editor: run `supabase/places.sql` (after all earlier
   files). The logger sends the new `state` column, so it fails until this has run.
2. **Push** to `main`. The upload workflow runs and loads the places (it uses the logger's
   secrets). Check it in the Actions tab; *Run workflow* there runs it again.
3. **App.** Nothing new to install.

- **Route guide: one step at a time.** The route page shows the steps in one list. One
  step is highlighted (large print, in colour, its stretch of road drawn stronger on the map);
  the others are greyed out. *Next* moves the highlight down, *Back* moves it up, and tapping a
  greyed-out step jumps to it. The map moves to that step, and with Read aloud on the step is
  read out. The highlight starts at the step for where the phone is and follows the phone
  until a step is chosen by hand; *Update route from where I am* lets it follow again.

### Round 8 test plans

| Plan | File | What it checks |
|---|---|---|
| LG5 | logger test_melaka | Melaka pages: names, districts, positions, thresholds, rain since midnight and last hour; stale and empty readings skipped; blocked site or new layout only a warning |
| PL7-PL9 | logger test_places | the files in `places/` are valid; every mistake listed with its line; positions outside the state; upload adds, updates, links depots, removes, and reports a centre still in use |
| PL1-PL6 | supabase/test/places_test | codes, districts, staff cannot change file rows but can record occupancy, loader deletes, headcount skips unchecked centres, Melaka stations and districts |
| TP89-TP90 | flood_core round8_test | centres from Supabase, old rows, broken rows, kept on the phone without internet, read-only, Melaka districts and station state |
| TP91 | app round8_ui_test | unchecked centre listed without route or suggestion, Google Maps by name, estimated capacity |
| TP92 | flood_core round8_test | each step's stretch of road; highlight follows the phone until chosen by hand; Next / Back stop at the ends |
| TP93 | app round8_ui_test | Next / Back / tap a step move the highlight, read aloud only when Read aloud is on, each step shown once |
| TP94 | app round8_ui_test | Add an area: State dropdown starts on the nearest station's state; District dropdown lists only that state's districts and resets when the state changes |
| TP95 | app round8_ui_test | A centre over 150 km away (the route server's limit) gets "too far for a route in the app" and Google Maps, with no request to the server |
| TP96 | app round8_ui_test | Home card for a saved rain-only station leads with the rain ("Very heavy rain", "Rain gauge only, no river reading") instead of "No recent data" |

Run as before: `dart test` in `packages/flood_core`, `flutter test` in `app`,
`npm test` in `supabase/test` (now five files), `python -m pytest` in `logger`.
