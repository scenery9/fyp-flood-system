-- =====================================================================
-- One-off clean-up: 4 Melaka stations that were stored twice on 19 Nov 2026.
-- How to use: Supabase dashboard -> SQL Editor -> paste this whole file -> Run.
-- Run it once, after the logger with collect.MELAKA_CODES is on GitHub.
-- Safe to run again (it then changes nothing).
--
-- Why: for a few hours the logger read Melaka from publicinfobanjir first.
-- That site names 4 stations differently from the JPS Melaka site, so they
-- were added a second time, without a map position, and the original
-- stations (which the app's saved areas use) stopped getting readings.
-- This moves the readings from each duplicate onto the original station
-- (a reading at the same time is kept once) and deletes the duplicate.
-- A pair whose original station does not exist is left alone (no readings lost).
--
-- The other Melaka stations added that day (Bukit Katil, Telok Rimba,
-- Chohong, ...) are real stations the Melaka site does not list; they stay.
--
-- No temporary table: the SQL Editor does not keep one between statements.
-- The same list of pairs is written in each statement instead:
--   0270231WL -> 0270231    Sg. Siput di Jamb. Sg. Simpang Ampat
--   0290161WL -> 2322415    Sg. Durian Tunggal di Bt. 11 Air Resam
--   0290221WL -> 029022WL   Pintu Air Durian Tunggal D/S
--   0290301RF -> 2421004    Kg. Sg. Siput (rain)
-- =====================================================================

begin;

-- 1. River readings: copy onto the original station.
insert into public.jps_river_levels (station_code, observed_at, level_m)
select m.original, l.observed_at, l.level_m
  from public.jps_river_levels l
  join (values ('0270231WL', '0270231'), ('0290161WL', '2322415'),
               ('0290221WL', '029022WL'), ('0290301RF', '2421004')) as m(duplicate, original)
    on m.duplicate = l.station_code
 where exists (select 1 from public.jps_stations s where s.station_code = m.original)
on conflict (station_code, observed_at) do nothing;

-- 2. Rain readings: copy onto the original station.
insert into public.jps_rainfall (station_code, observed_at, hourly_mm, today_mm)
select m.original, r.observed_at, r.hourly_mm, r.today_mm
  from public.jps_rainfall r
  join (values ('0270231WL', '0270231'), ('0290161WL', '2322415'),
               ('0290221WL', '029022WL'), ('0290301RF', '2421004')) as m(duplicate, original)
    on m.duplicate = r.station_code
 where exists (select 1 from public.jps_stations s where s.station_code = m.original)
on conflict (station_code, observed_at) do nothing;

-- 3. Delete the duplicates' readings and the duplicate stations
--    (only where the original exists, so nothing is lost).
delete from public.jps_river_levels l
 using (values ('0270231WL', '0270231'), ('0290161WL', '2322415'),
               ('0290221WL', '029022WL'), ('0290301RF', '2421004')) as m(duplicate, original)
 where l.station_code = m.duplicate
   and exists (select 1 from public.jps_stations s where s.station_code = m.original);

delete from public.jps_rainfall r
 using (values ('0270231WL', '0270231'), ('0290161WL', '2322415'),
               ('0290221WL', '029022WL'), ('0290301RF', '2421004')) as m(duplicate, original)
 where r.station_code = m.duplicate
   and exists (select 1 from public.jps_stations s where s.station_code = m.original);

delete from public.jps_stations d
 using (values ('0270231WL', '0270231'), ('0290161WL', '2322415'),
               ('0290221WL', '029022WL'), ('0290301RF', '2421004')) as m(duplicate, original)
 where d.station_code = m.duplicate
   and exists (select 1 from public.jps_stations s where s.station_code = m.original);

commit;

-- ---------- checking it worked ----------
-- No rows (the duplicates are gone):
--   select station_code from public.jps_stations
--   where station_code in ('0270231WL', '0290161WL', '0290221WL', '0290301RF');
-- The originals have recent readings again (after the next logger run):
--   select station_code, level_at, rain_at from public.jps_latest
--   where station_code in ('0270231', '2322415', '029022WL', '2421004');
