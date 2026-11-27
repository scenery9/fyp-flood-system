# Rain forecast evidence (generated from the real logs)

Generated 2026-11-27 13:50 UTC by `python -m flood_ml.rain_evidence`. Do not edit by hand: re-run it as more days are logged.

Data: JPS archive, 143 river stations, 2026-11-17 to 2026-11-24 (8 Malaysia days, 24230 station-hours). Open-Meteo: 133848 hourly forecast rows (2026-11-13 to 2026-11-27); MET Malaysia: 572 forecast rows, 73 warning rows.

Thresholds: a rain day is >= 1 mm, heavy >= 10 mm and very heavy >= 20 mm in a day (ETCCDI indices R1mm, R10mm, R20mm; see [references.md](references.md)). A river "rise" is >= 0.3 m above the level at the time of the forecast.

## 1. Is the Open-Meteo rain forecast any good here?

1758 station-days where a JPS rain gauge and a forecast for the same station and day both exist (121 stations, days 2026-11-20, ..., 2026-11-24). Forecast = 8-model mean made 1, 2 or 3 days before.

| Made ahead | Pairs | MAE mm | Mean fcst / obs mm | Spearman r | Rain day POD | FAR | CSI | Heavy (>=10) POD | FAR | Brier skill vs climatology |
|---|---|---|---|---|---|---|---|---|---|---|
| 1 day | 586 | 10.55 | 10.74 / 9.06 | 0.394 | 100.0% | 48.5% | 51.5% | 57.3% | 58.3% | -0.257 |
| 2 day | 586 | 11.23 | 11.68 / 9.06 | 0.465 | 100.0% | 48.5% | 51.5% | 68.2% | 63.6% | -0.404 |
| 3 day | 586 | 13.9 | 14.43 / 9.06 | 0.259 | 100.0% | 48.5% | 51.5% | 84.1% | 66.9% | -0.358 |

MET Malaysia: MET Malaysia forecasts are logged, but none yet for a day in the JPS archive.

## 2. Does more forecast rain go with a bigger river rise?

One sample per station per day (forecast as known at 08:00 Malaysia time). 95% Wilson intervals.

### next 24 h (input `fc_rain_day1_mm`, 693 station-days, Spearman r = 0.104)

| Forecast rain | Station-days | Rose >= 0.3 m | Rate (95% CI) | Below Alert | Reached Alert | Rate (95% CI) |
|---|---|---|---|---|---|---|
| < 1 mm (dry) | 0 | 0 | - (-) | 0 | 0 | - (-) |
| 1-10 mm | 534 | 196 | 36.7% (32.7-40.9%) | 518 | 48 | 9.3% (7.1-12.1%) |
| 10-20 mm (heavy) | 157 | 51 | 32.5% (25.7-40.2%) | 151 | 15 | 9.9% (6.1-15.7%) |
| >= 20 mm (very heavy) | 2 | 0 | 0.0% (0.0-65.8%) | 2 | 0 | 0.0% (0.0-65.8%) |

### next 72 h (input `fc_rain_total_3d`, 662 station-days, Spearman r = 0.285)

| Forecast rain | Station-days | Rose >= 0.3 m | Rate (95% CI) | Below Alert | Reached Alert | Rate (95% CI) |
|---|---|---|---|---|---|---|
| < 1 mm (dry) | 0 | 0 | - (-) | 0 | 0 | - (-) |
| 1-10 mm | 2 | 0 | 0.0% (0.0-65.8%) | 2 | 0 | 0.0% (0.0-65.8%) |
| 10-20 mm (heavy) | 78 | 12 | 15.4% (9.0-25.0%) | 75 | 4 | 5.3% (2.1-12.9%) |
| >= 20 mm (very heavy) | 582 | 344 | 59.1% (55.1-63.0%) | 557 | 100 | 17.9% (15.0-21.4%) |

### rain days in the next 3 days (input `fc_rain_days_3d`, 662 station-days)

| Forecast rain days | Station-days | Rose >= 0.3 m | Rate (95% CI) |
|---|---|---|---|
| 0 | 0 | 0 | - (-) |
| 1 | 0 | 0 | - (-) |
| 2 | 0 | 0 | - (-) |
| 3 | 662 | 356 | 53.8% (50.0-57.5%) |

## 3. Which inputs make the flood forecast better?

Rolling origin by day: for each of the last few days, every candidate is trained only on earlier rows and tested on that day; results are pooled over those test days. Judged first on high-water hours (river at least half-way from Normal to Alert, or reaching Alert), with overall MAE as a guard (`scoring.py`). RMSE, NSE, Willmott d, persistence index and peak error are explained in `metrics.py`. Differences are against 'observed only' (negative = better), with 95% intervals from resampling whole station-days.

### 3 h (level change)

Test days 2026-11-21, 2026-11-22, 2026-11-23, 2026-11-24; 13148 test rows, 2402 high-water rows, 570 station-days. Best on these test days: **observed only**. Chosen on validation for the app's model: **observed only**.

| Inputs | MAE m | vs observed (95% CI) | High-water MAE m | vs observed (95% CI) | RMSE m | NSE | Willmott d | Persistence index | Peak error m |
|---|---|---|---|---|---|---|---|---|---|
| observed only | 0.1410 | - | 0.1969 | - | 0.303 | 0.448 | 0.837 | 0.608 | 0.638 |
| observed + rain history | 0.1419 | +0.0009 (0.0002 to 0.0017) | 0.1998 | +0.0029 (0.0004 to 0.0054) | 0.304 | 0.443 | 0.834 | 0.605 | 0.644 |
| observed + next-day forecast | 0.1776 | +0.0366 (0.0297 to 0.0438) | 0.2166 | +0.0197 (0.0123 to 0.0282) | 0.333 | 0.332 | 0.811 | 0.526 | 0.622 |
| observed + 3-day forecast | 0.1784 | +0.0375 (0.03 to 0.0455) | 0.2204 | +0.0235 (0.0153 to 0.0325) | 0.338 | 0.313 | 0.807 | 0.513 | 0.640 |
| observed + residual correction (rain history, forecast) | 0.1410 | +0.0000 (0.0 to 0.0) | 0.1969 | +0.0000 (0.0 to 0.0) | 0.303 | 0.448 | 0.837 | 0.608 | 0.638 |
| no change (persistence) | 0.2316 | - | 0.3911 | - | 0.484 | -0.409 | 0.576 | 0.000 | 0.770 |

Residual correction weight alpha per test day: [0.0, 0.0, 0.0, 0.0] (0 = correction switched off).

### 24 h (highest level ahead)

Test days 2026-11-22, 2026-11-23, 2026-11-24; 7576 test rows, 1811 high-water rows, 422 station-days. Best on these test days: **observed + rain history**. Chosen on validation for the app's model: **observed + rain history**.

| Inputs | MAE m | vs observed (95% CI) | High-water MAE m | vs observed (95% CI) | RMSE m | NSE | Willmott d | Persistence index | Peak error m |
|---|---|---|---|---|---|---|---|---|---|
| observed only | 0.3625 | - | 0.4806 | - | 0.606 | -1.401 | 0.453 | 0.551 | 0.466 |
| observed + rain history | 0.3672 | +0.0047 (-0.0028 to 0.0118) | 0.4726 | -0.0080 (-0.02 to 0.0045) | 0.605 | -1.391 | 0.439 | 0.553 | 0.472 |
| observed + next-day forecast | 0.4035 | +0.0410 (0.0251 to 0.0576) | 0.4822 | +0.0017 (-0.0177 to 0.0202) | 0.625 | -1.554 | 0.458 | 0.522 | 0.497 |
| observed + 3-day forecast | 0.4397 | +0.0772 (0.0637 to 0.0919) | 0.5585 | +0.0779 (0.0528 to 0.1033) | 0.639 | -1.663 | 0.392 | 0.502 | 0.490 |
| observed + residual correction (rain history, forecast) | 0.3625 | +0.0000 (0.0 to 0.0) | 0.4806 | +0.0000 (0.0 to 0.0) | 0.606 | -1.401 | 0.453 | 0.551 | 0.466 |
| no change (persistence) | 0.5220 | - | 0.8758 | - | 0.905 | -4.344 | 0.331 | 0.000 | 0.635 |

Residual correction weight alpha per test day: [0.0, 0.0, 0.0] (0 = correction switched off).

### 72 h (highest level ahead)

not enough data yet for this horizon

## 3b. Chance of flood within 24 hours: is it honest?

For each JPS level the river is below, `probability.py` states a chance (XGBoost classifier, calibrated on the newest day it was not trained on). The app headlines the Warning level as "flood". Here each test day is predicted by a model fitted only on earlier days, and the stated chances are compared with what happened. Brier score: lower is better; 'climatology' always states the past average rate. Brier skill > 0 means better than that average.

### Alert

Test days 2026-11-23, 2026-11-24: 4042 station-hours, 550 reached Alert (13.6%). Brier 0.105 vs climatology 0.1231 (skill 0.147).

| Stated chance | Station-hours | Mean stated | Share that reached Alert |
|---|---|---|---|
| 0-10% | 3039 | 4.3% | 7.2% |
| 10-30% | 834 | 14.8% | 28.2% |
| 30-60% | 149 | 43.0% | 53.0% |
| 60-100% | 20 | 73.6% | 80.0% |

### Warning (headline: flood)

Test days 2026-11-23, 2026-11-24: 4094 station-hours, 241 reached Warning (5.9%). Brier 0.0525 vs climatology 0.0562 (skill 0.067).

| Stated chance | Station-hours | Mean stated | Share that reached Warning |
|---|---|---|---|
| 0-10% | 3820 | 2.3% | 4.5% |
| 10-30% | 218 | 16.6% | 20.6% |
| 30-60% | 49 | 41.1% | 38.8% |
| 60-100% | 7 | 72.4% | 71.4% |

### Danger

Test days 2026-11-23, 2026-11-24: 4118 station-hours, 126 reached Danger (3.1%). Brier 0.0296 vs climatology 0.0299 (skill 0.009).

| Stated chance | Station-hours | Mean stated | Share that reached Danger |
|---|---|---|---|
| 0-10% | 4067 | 1.6% | 2.9% |
| 10-30% | 37 | 17.8% | 10.8% |
| 30-60% | 14 | 36.4% | 21.4% |
| 60-100% | 0 | - | - |


## 4. What the model leans on (TreeSHAP, share of mean |impact|)

| Inputs | 3 h (level change) | 24 h (highest level ahead) |
|---|---|---|
| river level now and its recent change | 59.7% | 58.5% |
| rain measured at the station (past) | 3.0% | 7.2% |
| upstream stations (past) | 0.0% | 0.0% |
| forecast: next 3 hours | 7.4% | 1.2% |
| forecast: days 1-3 (Open-Meteo) | 29.7% | 31.6% |
| rain history (wet hours, wet days, API) | 0.2% | 1.5% |
| forecast x how full the river is | 0.0% | 0.0% |
| forecast: MET Malaysia and agreement | 0.0% | 0.0% |

## Limits

- Only 8 days of JPS readings are in the archive; the first 3 days cover few stations. Every interval above is wide, and one rainy spell dominates the results.
- Station-hours next to each other are not independent; parts 2 and 3 therefore count station-days.
- Open-Meteo forecasts for days before logging started are backfilled from its Previous Runs API (made 1-3 days before each hour). Live forecasts are made more recently, so they should be at least this good.
- Open-Meteo's own % chance is not archived for past days, so the chance used everywhere is the share of 8 weather models forecasting rain.
- MET Malaysia publishes no past forecasts, so its inputs are empty in all training rows until the logger has run for some weeks; the model cannot use them before then (TreeSHAP share 0).
- The 72 h model needs at least 72 h after every training row, so it gets the fewest rows.
