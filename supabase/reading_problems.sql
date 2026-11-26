-- =====================================================================
-- Why a station has no usable river reading, so the app can say so plainly.
-- How to use: Supabase dashboard -> SQL Editor -> paste this whole file -> Run.
-- Run it once, after sources.sql. Safe to run again.
--
-- The logger never stores a bad river reading (a sensor fault code, an empty
-- value, a time far in the past or the future, or a 0.00 m glitch). Without this
-- file the app only sees that the last good reading is getting old. With it, the
-- logger notes on each station what JPS is showing instead:
--   wl_problem    'offline'    JPS shows -9999 (sensor offline)
--                 'estimated'  JPS shows -8888 (estimated, not measured)
--                 'no_value'   JPS shows no level at all
--                 'old_time'   JPS still shows a reading over 24 hours old
--                 'bad_time'   JPS shows a reading time in the future
--                 'glitch'     JPS shows 0.00 m, far from the previous reading
--                 null         the latest reading was fine
--   wl_problem_at when the logger last saw that problem
-- The app only uses a problem seen after the last good reading.
-- =====================================================================

alter table public.jps_stations
  add column if not exists wl_problem text
    check (wl_problem in ('offline', 'estimated', 'no_value', 'old_time', 'bad_time', 'glitch')),
  add column if not exists wl_problem_at timestamptz;

-- Same view as places.sql, with the two columns added at the end.
create or replace view public.jps_latest with (security_invoker = on) as
select s.station_code, s.name, s.district, s.river_basin, s.lat, s.lon,
       s.wl_normal, s.wl_alert, s.wl_warning, s.wl_danger,
       r.level_m, r.observed_at as level_at,
       f.hourly_mm, f.observed_at as rain_at,
       s.state,
       s.wl_problem, s.wl_problem_at
from public.jps_stations s
left join lateral (select level_m, observed_at from public.jps_river_levels l
                   where l.station_code = s.station_code
                   order by observed_at desc limit 1) r on true
left join lateral (select hourly_mm, observed_at from public.jps_rainfall x
                   where x.station_code = s.station_code
                   order by observed_at desc limit 1) f on true;
