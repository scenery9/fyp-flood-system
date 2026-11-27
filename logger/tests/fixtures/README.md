Real responses from the JPS Selangor API (infobanjirjps.selangor.gov.my), captured
17 Nov 2026 and trimmed to a few Klang district stations. Public data, used only for tests.

Weather forecast fixtures, captured 27 Nov 2026 (public data, used only for tests):
- `met_forecast.json`: MET Malaysia 7-day forecast from api.data.gov.my/weather/forecast,
  trimmed to Klang (Ds054), Petaling (Ds057), Melaka Tengah (Ds078), Selangor and Melaka.
- `met_warning.json`: every MET warning in force (api.data.gov.my/weather/warning).
- `openmeteo_live_models.json` / `openmeteo_live_prob.json`: api.open-meteo.com forecast for
  two points (Petaling, Melaka): hourly rain from 8 models, and Open-Meteo's own probability.
- `openmeteo_previous_runs.json`: previous-runs-api.open-meteo.com for 20 Nov 2026 at Petaling:
  the 8 models' forecasts made 1, 2 and 3 days before each hour.

JKR disaster portal fixture, captured 27 Nov 2026:
- `jkr_disasters.json`: one page of bencana.jkr.gov.my/portal/disasters with two real
  incidents (10637, the Sungai Langat bund breach flood in Kuala Langat, and 10620, a
  landslide near Rawang), trimmed to their plain fields and the four label objects.
  The reporting officer's name, phone numbers and user ids are replaced by fake values
  ("TEST REPORTER", "000-0000000", 1); the tests check that none of them is kept.
