-- =====================================================================
-- Weather forecast for each river station, 3 days ahead, from two sources,
-- logged every 6 hours by logger/jps_logger/weather.py (GitHub Actions):
--   Open-Meteo     rain in mm and chance of rain (share of 8 weather models), per hour
--   MET Malaysia   official forecast text per district and day, and warnings
--                  (api.data.gov.my/weather)
-- How to use: Supabase dashboard -> SQL Editor -> paste this whole file -> Run.
-- Run it once, after readings.sql.
--
-- Same rules as readings.sql: everyone may READ (public forecasts); only the
-- logger (service_role) writes. Kept 30 days here, older days in data/forecast/.
-- Size: about 41,000 Open-Meteo rows a day (143 stations x 72 h x 4 runs).
-- =====================================================================

create table public.weather_forecast (
  station_code text not null,
  issued_at    timestamptz not null,           -- when the forecast was read (whole hour, UTC)
  valid_at     timestamptz not null,           -- the hour it is for (rain in the hour ending then)
  precip_mm    double precision check (precip_mm >= 0 and precip_mm < 1000),
  prob_pct     double precision check (prob_pct between 0 and 100),  -- share of models with >= 0.1 mm
  n_models     smallint,
  om_prob_pct  double precision check (om_prob_pct between 0 and 100), -- Open-Meteo's own probability
  primary key (station_code, issued_at, valid_at)
);

create table public.met_forecast (
  station_code text not null,
  issued_at    timestamptz not null,
  valid_date   date not null,                  -- Malaysia date
  location_id  text,                           -- MET location, e.g. Ds057 (Petaling)
  morning      text,
  afternoon    text,
  night        text,
  summary      text,
  rain_class   smallint check (rain_class between 0 and 4),
  thunder      smallint check (thunder in (0, 1)),
  primary key (station_code, issued_at, valid_date)
);

create table public.met_warning (
  station_code text not null,
  issued_at    timestamptz not null,
  valid_from   timestamptz,
  valid_to     timestamptz,
  kind         text not null check (kind in ('continuous_rain', 'heavy_rain', 'thunderstorm')),
  level        smallint not null check (level between 1 and 3),  -- 1 Waspada, 2 Buruk, 3 Bahaya
  title        text,
  primary key (station_code, issued_at, kind)
);

-- One row per station: the latest combined outlook (logger/jps_logger/outlook.py).
-- The app reads this; "day1" = the next 24 hours, "day2" = 24-48 h, "day3" = 48-72 h.
create table public.weather_outlook (
  station_code      text primary key,
  updated_at        timestamptz not null,
  om_issued_at      timestamptz,
  met_issued_at     timestamptz,
  next_3h_mm        double precision,
  next_3h_prob      double precision,
  day1_mm double precision, day1_prob double precision, day1_om_prob double precision, day1_band smallint,
  day1_met_class smallint, day1_met_text text, day1_met_thunder smallint, day1_agree smallint,
  day2_mm double precision, day2_prob double precision, day2_om_prob double precision, day2_band smallint,
  day2_met_class smallint, day2_met_text text, day2_met_thunder smallint, day2_agree smallint,
  day3_mm double precision, day3_prob double precision, day3_om_prob double precision, day3_band smallint,
  day3_met_class smallint, day3_met_text text, day3_met_thunder smallint, day3_agree smallint,
  rain_days_3d      smallint,
  total_3d_mm       double precision,
  warning_level     smallint not null default 0,
  warning_kind      text,
  warning_title     text,
  warning_valid_to  timestamptz
);

create index weather_forecast_issued on public.weather_forecast (issued_at);
create index met_forecast_issued on public.met_forecast (issued_at);
create index met_warning_issued on public.met_warning (issued_at);

alter table public.weather_forecast enable row level security;
alter table public.met_forecast enable row level security;
alter table public.met_warning enable row level security;
alter table public.weather_outlook enable row level security;

create policy weather_forecast_read on public.weather_forecast for select to anon, authenticated using (true);
create policy met_forecast_read on public.met_forecast for select to anon, authenticated using (true);
create policy met_warning_read on public.met_warning for select to anon, authenticated using (true);
create policy weather_outlook_read on public.weather_outlook for select to anon, authenticated using (true);

grant select on public.weather_forecast, public.met_forecast, public.met_warning, public.weather_outlook
  to anon, authenticated;
revoke insert, update, delete, truncate
  on public.weather_forecast, public.met_forecast, public.met_warning, public.weather_outlook
  from anon, authenticated;
grant select, insert, update, delete
  on public.weather_forecast, public.met_forecast, public.met_warning, public.weather_outlook
  to service_role;
