-- =====================================================================
-- Flood spots from JKR's incident reports: one row per place that flooded.
-- How to use: Supabase dashboard -> SQL Editor -> paste this whole file -> Run.
-- Run it after jkr.sql. Safe to run again (create or replace).
--
-- Why: these are the OBSERVED floods the forecast is checked against
-- (ml/flood_ml/incidents.py does the same with the archived files in data/incidents/).
--
-- Counting rule: every JKR flood report counts as its own flood spot. Nearby reports
-- on DIFFERENT roads stay separate (e.g. 25 Nov 2026, Banting: Jalan TM 3, Jalan 2 RTB
-- and Jalan 3 RTB flooded at the same hour, 0.4-0.9 km apart = 3 spots). Two reports
-- are merged only when they look like the same spot posted twice:
--   same road name, AND reported within 3 hours, AND less than 300 m apart.
-- The merged spot keeps the lowest incident id (spot_id).
--
-- Read access is the same as jkr_incident (everyone may read; security_invoker
-- makes the view use the tables' own row level security).
-- =====================================================================

create or replace function public.distance_km(lat1 double precision, lon1 double precision,
                                              lat2 double precision, lon2 double precision)
returns double precision
language sql immutable parallel safe
set search_path = ''
as $$
  select 2 * 6371.0 * asin(sqrt(
    power(sin(radians(lat2 - lat1) / 2), 2)
    + cos(radians(lat1)) * cos(radians(lat2)) * power(sin(radians(lon2 - lon1) / 2), 2)))
$$;

create or replace view public.jkr_flood_spot
with (security_invoker = true) as
with flood as (
  select * from public.jkr_incident
  where type = 'Flood' or type_ms = 'Banjir'
),
-- each report -> the lowest-id report it is a re-post of (itself if none)
grouped as (
  select f.*,
         coalesce((
           select min(o.incident_id) from flood o
           where o.incident_id < f.incident_id
             and upper(trim(coalesce(o.route_name, ''))) = upper(trim(coalesce(f.route_name, '')))
             and abs(extract(epoch from (o.occurred_at - f.occurred_at))) <= 3 * 3600
             and public.distance_km(o.lat, o.lon, f.lat, f.lon) < 0.3
         ), f.incident_id) as spot_id
  from flood f
),
seen as (
  select g.spot_id, min(s.seen_at) as first_seen_at, max(s.seen_at) as last_seen_at,
         max(s.depth_m) as max_depth_m, count(*) as sightings
  from grouped g join public.jkr_incident_seen s using (incident_id)
  group by g.spot_id
),
-- nearest JPS river station of the spot's first report, and the highest level it
-- read while the spot was listed
river as (
  select distinct on (g.incident_id)
         g.incident_id as spot_id, n.station_code, n.station_name, n.distance_km,
         n.alert_m, n.warning_m, n.danger_m
  from grouped g join public.jkr_incident_gauges n using (incident_id)
  where g.incident_id = g.spot_id and n.kind = 'river' and n.rank = 1
  order by g.incident_id, n.seen_at
),
river_peak as (
  select r.spot_id, max(n.level_m) as max_level_m
  from river r join grouped g on g.spot_id = r.spot_id
  join public.jkr_incident_gauges n
    on n.incident_id = g.incident_id and n.kind = 'river' and n.station_code = r.station_code
  group by r.spot_id
)
select
  g.spot_id,
  array_agg(g.incident_id order by g.incident_id) as incident_ids,
  count(*)                                        as reports,
  min(g.occurred_at)                              as occurred_at,
  (array_agg(g.lat order by g.incident_id))[1]    as lat,
  (array_agg(g.lon order by g.incident_id))[1]    as lon,
  min(g.state)                                    as state,
  min(g.district)                                 as district,
  min(g.route_name)                               as route_name,
  min(g.location_name)                            as location_name,
  greatest(max(g.depth_m), max(s.max_depth_m))    as max_depth_m,
  bool_or(g.is_verified = 1)                      as is_verified,
  max(s.first_seen_at)                            as first_seen_at,
  max(s.last_seen_at)                             as last_seen_at,
  max(s.sightings)                                as sightings,
  max(r.station_code)                             as river_station,
  max(r.station_name)                             as river_station_name,
  max(r.distance_km)                              as river_distance_km,
  max(r.warning_m)                                as river_warning_m,
  max(p.max_level_m)                              as river_max_level_m,
  coalesce(max(p.max_level_m) >= max(r.warning_m), false) as river_reached_warning
from grouped g
left join seen s on s.spot_id = g.spot_id
left join river r on r.spot_id = g.spot_id
left join river_peak p on p.spot_id = g.spot_id
group by g.spot_id;

grant execute on function public.distance_km(double precision, double precision, double precision, double precision)
  to anon, authenticated, service_role;
grant select on public.jkr_flood_spot to anon, authenticated, service_role;

-- ---------- examples ----------
-- Every flood spot, newest first:
--   select spot_id, reports, occurred_at, district, route_name, max_depth_m,
--          river_station, river_distance_km, river_max_level_m, river_reached_warning
--   from public.jkr_flood_spot order by occurred_at desc;
-- Floods per district:
--   select state, district, count(*) as spots from public.jkr_flood_spot group by 1, 2 order by 3 desc;
