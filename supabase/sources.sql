-- =====================================================================
-- Second data source: the national JPS pages (publicinfobanjir.water.gov.my).
-- How to use: Supabase dashboard -> SQL Editor -> paste this whole file -> Run.
-- Run it once, after places.sql. Safe to run again.
--
-- The logger (logger/jps_logger/collect.py) reads each state from two sources
-- and switches when one fails. The national pages name Selangor stations by
-- their national id (e.g. 3015432), not by the Selangor code the database uses
-- (BKLG0002L). The Selangor feed gives both, so every normal run stores the
-- national ids here, and a run where the Selangor feed is down can still match
-- the national page's readings to the right station.
--
-- A river gauge and a rain gauge at one place share a Selangor code but have
-- different national ids, so there is one column for each.
-- Melaka stations use the same codes on both sources and leave these empty.
-- =====================================================================

alter table public.jps_stations
  add column if not exists jps_wl_id text,  -- national id of the river level gauge
  add column if not exists jps_rf_id text;  -- national id of the rain gauge

create index if not exists jps_stations_wl_id on public.jps_stations (jps_wl_id) where jps_wl_id is not null;
create index if not exists jps_stations_rf_id on public.jps_stations (jps_rf_id) where jps_rf_id is not null;
