-- =====================================================================
-- Round 8: relief centres and resource points from places/*.csv, and Melaka.
-- How to use: Supabase dashboard -> SQL Editor -> paste this whole file -> Run.
-- Run it once, after every file of Rounds 6 and 7.
--
-- What it adds:
--   * Melaka's three districts (as the JPS Melaka pages spell them, in capitals).
--   * jps_stations.state, so the app can say "JPS Melaka" or "JPS Selangor".
--   * A "code" on relief centres and resource points. Rows with a code come
--     from places/centres.csv and places/resource_points.csv and are kept in
--     step with those files by logger/jps_logger/places.py (GitHub Actions).
--     Rows without a code (added by staff later) are never touched by it.
--   * location_checked: a centre whose position nobody has checked is listed in
--     the app but gets no map pin, no road route and is never picked for a headcount.
--   * capacity_estimated: the capacity is a guess, and the app says so.
-- =====================================================================

-- ---------- districts: Melaka ----------
alter table public.districts add column state text not null default 'Selangor';
insert into public.districts (name, state) values
  ('ALOR GAJAH', 'Melaka'), ('JASIN', 'Melaka'), ('MELAKA TENGAH', 'Melaka');

-- ---------- stations: which state ----------
alter table public.jps_stations add column state text not null default 'Selangor'
  check (state in ('Selangor', 'Melaka'));

-- Same view as alerts.sql, with the state added at the end.
create or replace view public.jps_latest with (security_invoker = on) as
select s.station_code, s.name, s.district, s.river_basin, s.lat, s.lon,
       s.wl_normal, s.wl_alert, s.wl_warning, s.wl_danger,
       r.level_m, r.observed_at as level_at,
       f.hourly_mm, f.observed_at as rain_at,
       s.state
from public.jps_stations s
left join lateral (select level_m, observed_at from public.jps_river_levels l
                   where l.station_code = s.station_code
                   order by observed_at desc limit 1) r on true
left join lateral (select hourly_mm, observed_at from public.jps_rainfall x
                   where x.station_code = s.station_code
                   order by observed_at desc limit 1) f on true;

-- ---------- centres and resource points kept in places/*.csv ----------
alter table public.resource_points
  add column code text unique check (code ~ '^[A-Z0-9][A-Z0-9-]{1,39}$');
alter table public.evacuation_points
  add column code text unique check (code ~ '^[A-Z0-9][A-Z0-9-]{1,39}$'),
  add column location_checked boolean not null default true,
  add column capacity_estimated boolean not null default false;

-- The loader (service_role) adds, updates and removes the rows that have a code.
grant select, insert, update, delete on public.evacuation_points, public.resource_points to service_role;

-- Staff screens (later) must not quietly change what the files say: rows with a
-- code keep their name, place and capacity unless the loader changes them.
-- Occupancy and open/closed stay free for staff, as before.
create function public.places_file_guard() returns trigger
language plpgsql security definer set search_path = ''
as $$
begin
  if old.code is not null and auth.uid() is not null then
    if tg_table_name = 'evacuation_points'
       and (new.code, new.name, new.lat, new.lon, new.capacity, new.district, new.location_checked,
            new.capacity_estimated, new.resource_point_id)
           is distinct from (old.code, old.name, old.lat, old.lon, old.capacity, old.district,
            old.location_checked, old.capacity_estimated, old.resource_point_id) then
      raise exception 'This centre comes from places/centres.csv: change it there';
    end if;
    if tg_table_name = 'resource_points'
       and (new.code, new.name, new.lat, new.lon, new.district)
           is distinct from (old.code, old.name, old.lat, old.lon, old.district) then
      raise exception 'This resource point comes from places/resource_points.csv: change it there';
    end if;
  end if;
  return new;
end $$;
create trigger evacuation_points_file_guard before update on public.evacuation_points
  for each row execute function public.places_file_guard();
create trigger resource_points_file_guard before update on public.resource_points
  for each row execute function public.places_file_guard();

-- ---------- headcounts never go to an unchecked centre ----------
-- Same as public_reports.sql, plus "location_checked".
create or replace function public.nearest_open_centre(p_lat double precision, p_lon double precision)
returns uuid
language sql stable security definer set search_path = ''
as $$
  select e.id
  from public.evacuation_points e
  where e.is_open and e.occupancy < e.capacity and e.location_checked
    and 2 * 6371 * asin(least(1, sqrt(
          power(sin(radians(e.lat - p_lat) / 2), 2)
          + cos(radians(p_lat)) * cos(radians(e.lat))
            * power(sin(radians(e.lon - p_lon) / 2), 2)))) <= 150
  order by power(e.lat - p_lat, 2) + power((e.lon - p_lon) * cos(radians(p_lat)), 2)
  limit 1
$$;
