# Switching the AI forecast from practice to the real model

Status on 19 Nov 2026: **practice forecast live, real model not yet published.**

## Where things stand

In the live build, the Home **AI forecast card** shows a *practice forecast* for each Klang /
Selangor / Melaka river station. It is a simple rule worked out in the app: rain in the last
hour pushes the river up, and a river above its normal level drains slowly back. It is **not the
XGBoost model**, and the card says so with a *Practice forecast · Not real predictions yet* badge.

A practice forecast is shown **on the AI forecast card (and its "Why" page) only**. In the live
build it never:
- makes an "expected to reach Warning / Danger" alert (in the app or by push),
- adds a trend arrow to the station lists or the map,
- shows on the station page.

Sample mode (no `secrets.json`) is unchanged: the made-up stations still use the sample
forecast everywhere, so the demo still works.

## How the switch works (already built)

```
main.dart (live)
  FallbackForecastSource
    1. RemoteForecastSource  GET <SUPABASE_URL>/storage/v1/object/public/forecasts/forecast.json
    2. PracticeForecastSource  (only if 1 fails)
```

On every refresh (every 15 minutes and on pull-to-refresh), the app first downloads
`forecast.json` from the public Supabase Storage bucket `forecasts`. It uses that file only if
**all** of these hold:

- the download answers 2xx,
- the file passes `parseForecast` (schema 1, horizon 1–24 h, finite numbers, low ≤ predicted ≤ high),
- `generated_at` is at most 2 hours old and at most 10 minutes in the future.

Otherwise the app uses the practice forecast. One file or the other is used, never a mix of the two.

When the model's file has `"is_practice_data": false`, the badge disappears. The forecast is
then used everywhere: alerts, list arrows and the station page.

**No app release, setting or code change is needed to switch.** Once a valid file is uploaded,
every phone switches over on its next refresh. Deleting the file switches them back.

Code:
- `packages/flood_core/lib/src/services/forecast_service.dart`: `RemoteForecastSource`,
  `FallbackForecastSource`.
- `app/lib/app/sample_data.dart`: `PracticeForecastSource`.
- `app/lib/main.dart`: the wiring.
- `app/lib/app/app_controller.dart`: `cardForecastFor` (card only) and `forecastFor` (everywhere
  else, which leaves out practice forecasts in the live build).

## Steps to switch

### 1. Wait for enough real readings

The model needs at least **200 training rows and 50 test rows** (hourly rows, after cleaning)
for `BKLG0002L`, or `run.py` stops with "Not enough data to train". That is roughly 11–12
days of clean logging from 17 Nov 2026. A model worth trusting needs much longer, ideally
including some monsoon-season rises (Nov–Jan), because a model trained only on dry weeks has
never seen a flood.

Check from your computer:

```powershell
cd logger
$env:SUPABASE_URL="https://YOUR-PROJECT.supabase.co"
$env:SUPABASE_PUBLISHABLE_KEY="sb_publishable_..."
git pull
python -m jps_logger.export --since 2026-11-17 --stations ..\ml\stations_klang.json --out ..\ml\readings.csv
cd ..\ml
python -m flood_ml.run --stations stations_klang.json --readings readings.csv
```

### 2. Check the model is good enough to publish

Open `ml/output/metrics.json` and agree a rule with your supervisor before switching.
Suggested:

| Check | Key in `metrics.json` | Publish only if |
|---|---|---|
| Beats "no change" | `skill_vs_baseline` | > 0 |
| Beats the straight-line trend | `skill_vs_linear_trend` | > 0 |
| Enough test data | `test_rows` | ≥ 50 (≥ 300 is better) |
| Real rises in the test set | `alert_or_above.events` | > 0, otherwise recall cannot be judged |
| Range is useful | `band_m` | small next to the gap between thresholds (e.g. < 0.5 m) |

### 2b. Make the forecast signing key (once)

The app shows a real forecast only if `forecast.json.sig` holds a valid Ed25519 signature
by a key built into the app (`trustedForecastKeys` in
`packages/flood_core/lib/src/security/forecast_signature.dart`). Until a key is added there,
every real file is rejected and the app keeps the practice forecast. So someone who gets the
Storage write key still cannot push a fake "Danger" forecast to phones.

From `ml/`:

```powershell
python -m flood_ml.sign keygen --key-id fr-2026-1
```

- **PRIVATE** line → GitHub → Settings → Secrets → Actions → new secret
  `FORECAST_SIGNING_KEY`. Also add `FORECAST_KEY_ID` = `fr-2026-1`. Do not save the private
  line anywhere else, and never commit or screenshot it.
- **PUBLIC** line → paste into `trustedForecastKeys`, run `dart test`, and release the app.

New key later (leaked or yearly): make a new id, add its public key **next to** the old one,
release, switch the two secrets, then remove the old id in the following release.

### 3. Create the public bucket (once)

In the Supabase SQL Editor:

```sql
insert into storage.buckets (id, name, public)
values ('forecasts', 'forecasts', true)
on conflict (id) do nothing;
```

Anyone can then read the files, and only the secret key can write them. Until this bucket and
file exist, the app's download fails and it simply keeps the practice forecast.

### 4. Try one upload by hand

In PowerShell, from `ml/`, after step 1. **Never commit or paste the secret key.**

```powershell
$env:SUPABASE_SECRET_KEY="sb_secret_..."
$env:FORECAST_SIGNING_KEY="..."; $env:FORECAST_KEY_ID="fr-2026-1"
python -m flood_ml.sign sign output/forecast.json     # writes output/forecast.json.sig
foreach ($f in "forecast.json", "forecast.json.sig") {
  curl.exe -X POST "$env:SUPABASE_URL/storage/v1/object/forecasts/$f" `
    -H "apikey: $env:SUPABASE_SECRET_KEY" -H "Authorization: Bearer $env:SUPABASE_SECRET_KEY" `
    -H "x-upsert: true" -H "Content-Type: application/json" -H "Cache-Control: max-age=300" `
    --data-binary "@output/$f"
}
```

Upload the two files together. If only one is new, the signature does not match and the app
shows practice until both are there (at its next refresh).

Then open the live app and pull to refresh. The Taman Sri Muda (BKLG0002L) card should show
the model's numbers **without** the practice badge. The file is only used within 2 hours of
`generated_at`, so a hand upload stops being used after 2 hours and the app falls back to
practice. That is expected; step 5 keeps the file fresh.

> The two-header form works for the new `sb_secret_...` keys on current Supabase. If the
> upload answers 401/403, check the key and the bucket name first.

### 5. Add the hourly workflow

Create `.github/workflows/forecast.yml`. It runs after the :22 logger run and uses the same
two repository secrets as the logger:

```yaml
name: Publish AI forecast
on:
  schedule:
    - cron: '30 * * * *'
  workflow_dispatch: {}
permissions:
  contents: read
concurrency:
  group: forecast
  cancel-in-progress: true
jobs:
  forecast:
    runs-on: ubuntu-latest
    timeout-minutes: 10
    steps:
      - uses: actions/checkout@v6          # brings the data/ archive
      - uses: actions/setup-python@v6
        with: { python-version: '3.13' }
      - run: pip install -r logger/requirements.txt -r ml/requirements.txt
      - name: Export readings
        working-directory: logger
        run: python -m jps_logger.export --since 2026-11-17 --stations ../ml/stations_klang.json --out ../ml/readings.csv
        env:
          SUPABASE_URL: ${{ secrets.SUPABASE_URL }}
          SUPABASE_SECRET_KEY: ${{ secrets.SUPABASE_SECRET_KEY }}
      - name: Train, forecast and sign
        working-directory: ml
        run: python -m flood_ml.run --stations stations_klang.json --readings readings.csv
        env:
          FORECAST_SIGNING_KEY: ${{ secrets.FORECAST_SIGNING_KEY }}
          FORECAST_KEY_ID: ${{ secrets.FORECAST_KEY_ID }}
      - name: Quality gate
        working-directory: ml
        run: |
          python - <<'EOF'
          import json, sys
          m = json.load(open("output/metrics.json"))
          ok = (m["skill_vs_baseline"] or 0) > 0 and (m["skill_vs_linear_trend"] or 0) > 0 and m["test_rows"] >= 50
          print(json.dumps({k: m[k] for k in ("mae_m", "skill_vs_baseline", "skill_vs_linear_trend", "test_rows", "band_m")}))
          sys.exit(0 if ok else 1)
          EOF
      - name: Upload forecast.json and its signature
        run: |
          test -s ml/output/forecast.json.sig   # never publish an unsigned file
          for f in forecast.json forecast.json.sig; do
            curl -fsS -X POST "$SUPABASE_URL/storage/v1/object/forecasts/$f" \
              -H "apikey: $SUPABASE_SECRET_KEY" -H "Authorization: Bearer $SUPABASE_SECRET_KEY" \
              -H "x-upsert: true" -H "Content-Type: application/json" -H "Cache-Control: max-age=300" \
              --data-binary "@ml/output/$f"
          done
        env:
          SUPABASE_URL: ${{ secrets.SUPABASE_URL }}
          SUPABASE_SECRET_KEY: ${{ secrets.SUPABASE_SECRET_KEY }}
```

Notes:
- If any step fails (not enough data, quality gate, upload), nothing new is uploaded. After
  2 hours the old file is too old and every phone falls back to practice. GitHub emails you
  about the failed run.
- Retraining every hour is fine while the data is small (seconds). Later, retrain daily, save
  `model.json`, and run only the prediction hourly.
- GitHub sometimes starts scheduled runs 15–30 minutes late. Running hourly against the app's
  2-hour limit leaves room for one late or failed run.

### 6. Confirm, then update the docs

- Actions → *Publish AI forecast* → *Run workflow*, and check it is green.
- In the app, the BKLG0002L card has no practice badge, and More → *Alerts near you now* can
  show "expected" alerts.
- Update the README (*Limitations*) and `docs/daily-updates.md`.

## What changes for users after the switch

- The card for **BKLG0002L** (and any station added to `stations_klang.json`) shows the real
  model's forecast and its reasons.
- **Every other station's card shows "No forecast for this area right now".** The app uses one
  file only, so stations that are not in the real file no longer get a practice forecast. This
  is deliberate: a phone never shows real and made-up forecasts side by side. Covering more
  stations means adding them, with their upstream stations, to `ml/stations_klang.json` (or a
  wider stations file).
- "Expected to reach Warning/Danger" alerts become possible for those stations, in the app only.
  Push alerts are still sent for official JPS levels only.

## Rolling back

Delete `forecasts/forecast.json` (Supabase → Storage) and disable the workflow. Within one
refresh every phone is back on the labelled practice forecast. No release is needed.
