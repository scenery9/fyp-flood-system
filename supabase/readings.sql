-- =====================================================================
-- JPS Selangor readings logged every 15 minutes by logger/ (GitHub Actions).
-- How to use: Supabase dashboard -> SQL Editor -> paste this whole file -> Run.
-- Run it once, after schema.sql.
--
-- Who can do what:
--   anon, authenticated = may only READ (the readings are public JPS data).
--   service_role        = the logger (secret key, kept in GitHub Secrets). Only it
--                         can add rows, and delete rows once they are archived
--                         (logger/jps_logger/archive.py). Supabase lets it bypass
--                         row level security.
-- Nobody else can change or delete a reading through the API.
-- Size: all Selangor at 15-minute steps is roughly 4-5 MB a day; only the last
-- 30 days are kept here, older days live in data/ in the GitHub repository.
-- =====================================================================

create table public.jps_stations (
  station_code    text primary key,               -- JPS stationCode, e.g. BKLG0002L
  name            text not null,
  district        text,
  river_basin     text,
  lat             double precision check (lat between -90 and 90),
  lon             double precision check (lon between -180 and 180),
  has_river_level boolean not null default false,
  has_rainfall    boolean not null default false,
  wl_normal       double precision,
  wl_alert        double precision,
  wl_warning      double precision,
  wl_danger       double precision,
  updated_at      timestamptz not null default now()
);

-- One row per station per JPS observation time. Re-reading the same
-- observation (JPS shows the latest value until a new one arrives) is ignored.
create table public.jps_river_levels (
  station_code text not null,
  observed_at  timestamptz not null,
  level_m      double precision not null check (level_m > -100 and level_m < 1000),
  primary key (station_code, observed_at)
);

-- hourly_mm = JPS "hourlyRainfall" (a rolling 60-minute total, NOT the rain since
-- the last reading); today_mm = rain since midnight Malaysia time. The export
-- works out rain per interval from today_mm.
create table public.jps_rainfall (
  station_code text not null,
  observed_at  timestamptz not null,
  hourly_mm    double precision check (hourly_mm >= 0 and hourly_mm < 1000),
  today_mm     double precision check (today_mm >= 0 and today_mm < 2000),
  primary key (station_code, observed_at)
);

alter table public.jps_stations enable row level security;
alter table public.jps_river_levels enable row level security;
alter table public.jps_rainfall enable row level security;

create policy jps_stations_read on public.jps_stations for select to anon, authenticated using (true);
create policy jps_levels_read on public.jps_river_levels for select to anon, authenticated using (true);
create policy jps_rain_read on public.jps_rainfall for select to anon, authenticated using (true);

grant select on public.jps_stations, public.jps_river_levels, public.jps_rainfall to anon, authenticated;
revoke insert, update, delete, truncate on public.jps_stations, public.jps_river_levels, public.jps_rainfall
  from anon, authenticated;
grant select, insert, update on public.jps_stations to service_role;
grant select, insert, delete on public.jps_river_levels, public.jps_rainfall to service_role;

-- Database size in MB, for the logger's daily size warning. Only the logger may call it.
create function public.jps_storage_mb() returns double precision
  language sql stable security definer set search_path = pg_catalog as
  $$ select pg_database_size(current_database()) / 1048576.0 $$;
revoke execute on function public.jps_storage_mb() from public, anon, authenticated;
grant execute on function public.jps_storage_mb() to service_role;
