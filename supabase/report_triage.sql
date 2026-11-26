-- =====================================================================
-- Flood report triage for large floods: anti-spam limits, a credibility
-- score per report, and clusters for staff.
-- How to use: Supabase dashboard -> SQL Editor -> paste this whole file -> Run.
-- Run it once, AFTER shelter.sql.
--
-- Limits (on top of schema.sql's "5 waiting for review"):
--   * at most 3 reports an hour from one phone;
--   * official-data points and CORROBORATED need the reporter's phone to have
--     been within 5 km of the pin (the app sends its GPS; only the distance
--     is stored, not where the reporter was).
--
-- Credibility, 0-100, worked out when the report arrives:
--   up to 50  JPS fact support: the nearest gauge within 5 km of the pin was
--             at Alert (Waspada) or above, or had > 20 mm rain in the 3 hours
--             before (25 for 5-20 mm)
--   up to 50  crowd consensus: 25 for each OTHER phone that reported within
--             1 km and 60 minutes with the same kind/type or a similar
--             description (pg_trgm similarity > 0.35)
--   CORROBORATED = 70 or more, and the reporter was within 5 km.
-- It is a triage aid for staff, never shown to the public as "true".
--
-- Clusters (report_clusters): reports in the same ~500 m grid cell
-- (0.0045 degrees) and the same 30-minute window, ranked by severity and
-- count, so 10,000 reports become a short list of places.
-- =====================================================================

create extension if not exists pg_trgm with schema extensions;

alter table public.damage_reports
  add column reporter_distance_km double precision check (reporter_distance_km is null or reporter_distance_km >= 0),
  add column fact_support smallint not null default 0 check (fact_support between 0 and 50),
  add column consensus smallint not null default 0 check (consensus between 0 and 50),
  add column credibility_score smallint not null default 0 check (credibility_score between 0 and 100),
  add column corroborated boolean not null default false;

create index damage_reports_occurred_idx on public.damage_reports (occurred_at);
create index damage_reports_created_by_reporter_idx on public.damage_reports (reporter_id, created_at);
create index damage_reports_description_trgm on public.damage_reports
  using gin (description extensions.gin_trgm_ops);

-- ---------- scoring ----------

-- 0, 25 or 50 from JPS readings near (p_lat, p_lon) around p_at.
create function private.report_fact_support(p_lat double precision, p_lon double precision,
    p_at timestamptz) returns smallint
language sql stable security definer set search_path = ''
as $$
  with near as (
    select s.station_code, s.wl_alert
    from public.jps_stations s
    where s.lat is not null and private.km(p_lat, p_lon, s.lat, s.lon) <= 5
  ), river as (
    select bool_or(l.level_m >= n.wl_alert) as high
    from near n
    cross join lateral (
      select level_m from public.jps_river_levels r
      where r.station_code = n.station_code
        and r.observed_at between p_at - interval '3 hours' and p_at + interval '30 minutes'
      order by r.observed_at desc limit 1) l
    where n.wl_alert is not null
  ), rain as (
    -- hourly_mm is a rolling 60-minute total: add the readings nearest to
    -- p_at, p_at - 1 h and p_at - 2 h.
    select max(t.mm) as mm3
    from near n
    cross join lateral (
      select coalesce(sum(x.hourly_mm), 0) as mm
      from generate_series(0, 2) k
      cross join lateral (
        select f.hourly_mm from public.jps_rainfall f
        where f.station_code = n.station_code
          and f.observed_at between p_at - make_interval(hours => k) - interval '20 minutes'
                                and p_at - make_interval(hours => k) + interval '20 minutes'
        order by abs(extract(epoch from f.observed_at - (p_at - make_interval(hours => k))))
        limit 1) x) t
  )
  select (case
    when coalesce((select high from river), false) or coalesce((select mm3 from rain), 0) > 20 then 50
    when coalesce((select mm3 from rain), 0) >= 5 then 25
    else 0 end)::smallint
$$;

-- Rate limit, district already set (triggers run in name order), then score.
create function public.damage_reports_triage() returns trigger
language plpgsql security definer set search_path = ''
as $$
declare
  at timestamptz := coalesce(new.occurred_at, new.incident_date::timestamptz, now());
  near_ok boolean;
  others int;
begin
  if (select count(*) from public.damage_reports
      where reporter_id = new.reporter_id and created_at > now() - interval '1 hour') >= 3 then
    raise exception 'You can send up to 3 reports an hour';
  end if;
  near_ok := new.reporter_distance_km is not null and new.reporter_distance_km <= 5;

  select count(distinct r.reporter_id) into others
  from public.damage_reports r
  where r.reporter_id <> new.reporter_id
    and r.status in ('pending', 'verified')
    and coalesce(r.occurred_at, r.created_at) between at - interval '60 minutes' and at + interval '60 minutes'
    and private.km(new.lat, new.lon, r.lat, r.lon) <= 1
    and ((r.kind = new.kind and r.type is not distinct from new.type)
         or (length(new.description) >= 8 and length(r.description) >= 8
             and extensions.similarity(r.description, new.description) > 0.35));

  -- Never taken from the client.
  new.fact_support := case when near_ok then private.report_fact_support(new.lat, new.lon, at) else 0 end;
  new.consensus := least(50, 25 * others);
  new.credibility_score := new.fact_support + new.consensus;
  new.corroborated := near_ok and new.credibility_score >= 70;
  return new;
end $$;
create trigger damage_reports_triage before insert on public.damage_reports
  for each row execute function public.damage_reports_triage();

-- A review never changes the score or the reporter's distance.
create function public.damage_reports_keep_triage() returns trigger
language plpgsql security definer set search_path = ''
as $$
begin
  new.reporter_distance_km := old.reporter_distance_km;
  new.fact_support := old.fact_support;
  new.consensus := old.consensus;
  new.credibility_score := old.credibility_score;
  new.corroborated := old.corroborated;
  return new;
end $$;
create trigger damage_reports_keep_triage before update on public.damage_reports
  for each row execute function public.damage_reports_keep_triage();

-- ---------- submitting: same as public_reports.sql, plus the reporter's GPS ----------
-- p also takes "reporter_lat", "reporter_lon": where the phone is now. Only
-- the distance to the pin is kept.
create or replace function public.submit_flood_report(p jsonb) returns uuid
language plpgsql security invoker set search_path = ''
as $$
declare
  me uuid := auth.uid();
  happened timestamptz;
  ref text := nullif(trim(coalesce(p->>'client_ref', '')), '');
  existing uuid;
  new_id uuid;
  dist double precision;
begin
  if me is null then raise exception 'Sign in first'; end if;
  if ref is not null then
    select id into existing from public.damage_reports where reporter_id = me and client_ref = ref;
    if existing is not null then return existing; end if; -- a retry: same report
  end if;
  happened := (p->>'occurred_at')::timestamptz;
  if happened is null then raise exception 'When did it happen?'; end if;
  if happened > now() + interval '5 minutes' then raise exception 'The time cannot be in the future'; end if;
  if happened < now() - interval '60 days' then raise exception 'Reports can be up to 60 days old'; end if;
  if p ? 'reporter_lat' and p ? 'reporter_lon' then
    if (p->>'reporter_lat')::double precision not between -90 and 90
       or (p->>'reporter_lon')::double precision not between -180 and 180 then
      raise exception 'Bad phone location';
    end if;
    -- Haversine, written out: this function runs as the caller, who cannot use private.*.
    select 2 * 6371 * asin(least(1, sqrt(
             power(sin(radians(b.la - a.la) / 2), 2)
             + cos(radians(a.la)) * cos(radians(b.la)) * power(sin(radians(b.lo - a.lo) / 2), 2))))
    into dist
    from (select (p->>'lat')::double precision as la, (p->>'lon')::double precision as lo) a,
         (select (p->>'reporter_lat')::double precision as la, (p->>'reporter_lon')::double precision as lo) b;
  end if;
  insert into public.damage_reports
    (lat, lon, incident_date, occurred_at, kind, type, severity, depth_band, depth_m, description,
     client_ref, reporter_distance_km)
  values (
    (p->>'lat')::double precision, (p->>'lon')::double precision,
    (happened at time zone 'Asia/Kuala_Lumpur')::date, happened,
    coalesce(p->>'kind', 'damage'),
    case when p->>'kind' = 'sighting' then null else p->>'type' end,
    case when p->>'kind' = 'sighting' then null else p->>'severity' end,
    coalesce(p->>'depth_band', 'unsure'),
    (p->>'depth_m')::double precision,
    coalesce(p->>'description', ''),
    ref, dist)
  returning id into new_id;
  return new_id;
end $$;

revoke execute on all functions in schema private from public;

-- ---------- clusters for staff ----------

create function public.report_clusters(p_since timestamptz default now() - interval '24 hours',
    p_limit integer default 100)
returns table (cell_lat double precision, cell_lon double precision, window_start timestamptz,
  reports bigint, reporters bigint, severe bigint, moderate bigint, minor bigint, sightings bigint,
  corroborated bigint, max_credibility smallint, district text, priority bigint, report_ids uuid[])
language sql stable security invoker set search_path = ''
as $$
  select (floor(r.lat / 0.0045) + 0.5) * 0.0045, (floor(r.lon / 0.0045) + 0.5) * 0.0045,
         to_timestamp(floor(extract(epoch from coalesce(r.occurred_at, r.created_at)) / 1800) * 1800),
         count(*), count(distinct r.reporter_id),
         count(*) filter (where r.severity = 'severe'),
         count(*) filter (where r.severity = 'moderate'),
         count(*) filter (where r.severity = 'minor'),
         count(*) filter (where r.kind = 'sighting'),
         count(*) filter (where r.corroborated),
         max(r.credibility_score),
         min(r.district),
         3 * count(*) filter (where r.severity = 'severe') + 2 * count(*) filter (where r.severity = 'moderate')
           + count(*) filter (where r.severity = 'minor' or r.kind = 'sighting')
           + 2 * count(*) filter (where r.corroborated),
         (array_agg(r.id order by r.credibility_score desc, r.created_at))[1:20]
  from public.damage_reports r
  where public.staff_role() is not null           -- staff only; row rules limit it to their area
    and coalesce(r.occurred_at, r.created_at) >= p_since
    and r.status in ('pending', 'verified')
  group by 1, 2, 3
  order by 13 desc, 4 desc, 3 desc
  limit least(greatest(p_limit, 1), 1000)
$$;
revoke execute on function public.report_clusters(timestamptz, integer) from public;
grant execute on function public.report_clusters(timestamptz, integer) to authenticated;
