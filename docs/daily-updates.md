# Daily updates

## 17 Nov 2026

### Done today
- **Data logger (`logger/`)**: records all JPS Selangor river-level and rainfall stations
  (about 330) every 15 minutes through GitHub Actions into Supabase. Offline, empty,
  future-dated and stale (over 24 h) readings are skipped.
- **Daily archive**: each finished day is saved as `data/YYYY/MM/YYYY-MM-DD.csv.gz` in the
  repo. Supabase keeps only the last 30 days (about 150 MB), with a size warning at 300 MB,
  so logging can run for 8+ months for free. The export tool joins the archive and Supabase
  into one `readings.csv` for the model.
- **Klang river target**: `ml/stations_klang.json` holds the station codes and thresholds read
  from JPS on 17 Nov. Taman Sri Muda is forecast using two upstream stations (still to be
  checked on a map).
- **Supervisor email** drafted, asking about the dataset, model scope and using practice data
  for the interim report.
- **Location permission (Centres)**:
  - Reverted to the original behaviour: the app asks only when **Use my location** is tapped,
    never at startup.
  - When Android has blocked the pop-up (refused twice), the **Open settings** card now stays
    until location is allowed, instead of flipping back.
  - A unit test for the blocked case was added.

### Not finished
- **Android build fails** because of a damaged Gradle cache (`.gradle\caches\9.5.0\transforms`).
  The fix is to close VS Code, stop Java/Gradle, delete the cache folder, run
  `flutter clean`, then rebuild.
- The location fix has **not been tested on the phone yet**: the build has to work first.
- `flutter test` has not been run on the PC since the change.

### Upcoming backend plans

**1. Live map directions (real road route, not a straight line)**
- Make one real openrouteservice (ORS) request with the key from `app/secrets.json`, and check
  the reply matches what `OrsRouteProvider` expects. The tests so far only use a canned reply.
- Draw the road route on the map as a solid line. The dotted straight line is only kept as the
  fallback when there is no internet or no key.
- Follow the user's live position on the map, and fetch a new route when they move more than
  about 50 m off it.
- Free limit: about 2,000 ORS requests a day, 40 a minute, so only re-route when needed.

**2. Route guidance (as in the reference FloodWatch app)**
- Show turn-by-turn steps from ORS instruction types (turn left/right, keep left/right,
  roundabout with exit number, U-turn, arrive), each with an icon and the road name.
- Build the step text from the type code, not ORS's English text, so steps can switch between
  English, Malay and Chinese even when offline.
- Save the last route on the phone for offline use, and warn when it is over 1 hour old.
- Always show the warning that a route does not confirm roads are passable. Google Maps stays
  as the backup button.

**3. AI flood prediction (real data)**
- Keep the logger running to build up real readings. Practice-data numbers must not go in the
  report.
- Once there are enough weeks of data, train XGBoost on the Klang stations and compare it with
  the "no change" baseline and FloodWatch's straight-line trend method (MAE, RMSE, missed
  events, false alarms).
- Add an hourly GitHub job that runs the model on the newest readings and publishes
  `forecast.json` for the app. Sign the file so the app can reject fake forecasts.
- Show SHAP reasons in the app ("why"), with Malay and Chinese wording.

**4. Rainfall and river-level data in the app**
- Write a Supabase `StationRepository` that reads the logger's readings, replacing the sample
  data on Home, the station lists and Warnings.
- Keep the existing rules: readings over 3 h old are marked stale and raise no warning, and
  -9999 / -8888 mean no data.

**5. Relief centre locations and stock**
- Load real relief centres (name, district, coordinates, capacity) into Supabase. Check the
  coordinates first: the reference app needed several fix scripts for wrong ones.
- Connect `ResourceService` to Supabase tables: stock per item, expiry dates, centre
  occupancy, and supply alerts when stock lasts under 3 days.
- Public users see only open centres and their distance. Stock details stay staff-only.

**6. Staff roles**
- Staff log in with Supabase Auth, and each account gets a role:
  - **Super Admin**: everything, including managing staff accounts.
  - **Coordinator**: everything except staff accounts.
  - **Field Officer**: reviews damage reports, updates stock quantities and occupancy only.
- Enforce roles in two places: in the app (`AccessControl`) and in the database (row level
  security), so a changed app still cannot bypass them.
- Build the staff screens: login, dashboard, centres and stock, damage review, staff accounts.

### Risks to watch
- ORS reply format not yet verified against the live service.
- Real flood events may be rare during the logging period, so the model may see few high-water
  cases. Waiting on the supervisor's reply about the dataset.
- Permission to reuse JPS data is still unconfirmed.
