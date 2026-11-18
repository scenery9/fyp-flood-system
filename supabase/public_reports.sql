-- =====================================================================
-- Round 7: public flood reports ("Flooding here now" or "Damage") and the
-- household's "We're coming" headcount for a relief centre.
-- How to use: Supabase dashboard -> SQL Editor -> paste this whole file -> Run.
-- Run it once, AFTER schema.sql, readings.sql and staff_districts.sql.
-- It mirrors the rules in packages/flood_core (public_reports_service.dart).
--
-- The app only calls the functions at the end of this file, as the phone's
-- anonymous user. Row level security from schema.sql / staff_districts.sql
-- still decides who sees what: a household or reporter sees only their own
-- rows; staff see their own area.
-- =====================================================================

-- ---------- damage_reports: sightings, body-height depth, exact time, retry key ----------

alter table public.damage_reports
  add column kind text not null default 'damage' check (kind in ('damage', 'sighting')),
  add column occurred_at timestamptz,
  add column depth_band text check (depth_band in ('ankle', 'knee', 'waist', 'chest', 'unsure')),
  -- Made by the phone once per form, so a retry after a network failure
  -- returns the first report instead of adding a second one.
  add column client_ref text check (client_ref is null or length(client_ref) between 8 and 64);

-- A sighting ("Flooding here now") has no damage type or severity.
alter table public.damage_reports alter column type drop not null, alter column severity drop not null;
alter table public.damage_reports add constraint damage_reports_kind_fields
  check (kind = 'sighting' or (type is not null and severity is not null));
create unique index damage_reports_client_ref_key on public.damage_reports (reporter_id, client_ref)
  where client_ref is not null;

-- A review never changes what the reporter sent (the original trigger in
-- schema.sql already keeps the older fields).
create function public.damage_reports_keep_round7() returns trigger
language plpgsql security definer set search_path = ''
as $$
begin
  new.kind := old.kind;
  new.occurred_at := old.occurred_at;
  new.depth_band := old.depth_band;
  new.client_ref := old.client_ref;
  return new;
end $$;
create trigger damage_reports_keep_round7 before update on public.damage_reports
  for each row execute function public.damage_reports_keep_round7();

-- ---------- headcounts: needs, status, expiry ----------

alter table public.headcounts
  add column needs text[] not null default '{}'
    check (needs <@ array['wheelchair', 'power', 'formula', 'diapers', 'cold_medicine', 'pet', 'other']::text[]),
  add column other_need text not null default '' check (length(other_need) <= 200),
  add column status text not null default 'on_the_way' check (status in ('on_the_way', 'arrived', 'left')),
  add column updated_at timestamptz not null default now(),
  -- People who forget to tap "Left" stop being counted after 72 hours.
  add column expires_at timestamptz not null default now() + interval '72 hours';

create function public.headcounts_before_write() returns trigger
language plpgsql security definer set search_path = ''
as $$
begin
  new.updated_at := now();
  new.expires_at := now() + interval '72 hours';
  new.other_need := trim(new.other_need);
  if not ('other' = any (new.needs)) then
    new.other_need := '';
  end if;
  if tg_op = 'UPDATE' then
    new.household_id := old.household_id;
    new.submitted_at := old.submitted_at;
  end if;
  return new;
end $$;
create trigger headcounts_before_write before insert or update on public.headcounts
  for each row execute function public.headcounts_before_write();

-- ---------- helpers ----------

-- Text to uuid, or null when it is not a uuid (e.g. a sample centre id).
create function public.try_uuid(v text) returns uuid
language sql immutable set search_path = ''
as $$
  select case when v ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
              then v::uuid end
$$;

-- Nearest open relief centre with space, within 150 km.
create function public.nearest_open_centre(p_lat double precision, p_lon double precision)
returns uuid
language sql stable security definer set search_path = ''
as $$
  select e.id
  from public.evacuation_points e
  where e.is_open and e.occupancy < e.capacity
    and 2 * 6371 * asin(least(1, sqrt(
          power(sin(radians(e.lat - p_lat) / 2), 2)
          + cos(radians(p_lat)) * cos(radians(e.lat))
            * power(sin(radians(e.lon - p_lon) / 2), 2)))) <= 150
  order by power(e.lat - p_lat, 2) + power((e.lon - p_lon) * cos(radians(p_lat)), 2)
  limit 1
$$;

-- The caller's headcount as the app shows it (null when there is none).
create function public.headcount_json(p_household uuid) returns json
language sql stable security invoker set search_path = ''
as $$
  select json_build_object(
    'total', h.total, 'babies', h.babies, 'elderly', h.elderly,
    'reduced_mobility', h.reduced_mobility, 'needs', to_json(h.needs),
    'other_need', h.other_need, 'status', h.status,
    'updated_at', h.updated_at, 'expires_at', h.expires_at,
    'centre_id', h.evacuation_point_id, 'centre_name', e.name)
  from public.headcounts h
  left join public.evacuation_points e on e.id = h.evacuation_point_id
  where h.household_id = p_household
$$;

-- ---------- functions the app calls ----------

-- p: {"kind": "sighting"|"damage", "lat", "lon", "occurred_at", "client_ref",
--     "depth_band", "depth_m", "type", "severity", "description"}
create function public.submit_flood_report(p jsonb) returns uuid
language plpgsql security invoker set search_path = ''
as $$
declare
  me uuid := auth.uid();
  happened timestamptz;
  ref text := nullif(trim(coalesce(p->>'client_ref', '')), '');
  existing uuid;
  new_id uuid;
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
  insert into public.damage_reports
    (lat, lon, incident_date, occurred_at, kind, type, severity, depth_band, depth_m, description, client_ref)
  values (
    (p->>'lat')::double precision, (p->>'lon')::double precision,
    (happened at time zone 'Asia/Kuala_Lumpur')::date, happened,
    coalesce(p->>'kind', 'damage'),
    case when p->>'kind' = 'sighting' then null else p->>'type' end,
    case when p->>'kind' = 'sighting' then null else p->>'severity' end,
    coalesce(p->>'depth_band', 'unsure'),
    (p->>'depth_m')::double precision,
    coalesce(p->>'description', ''),
    ref)
  returning id into new_id;
  return new_id;
end $$;

-- "My reports": newest first, at most 50.
create function public.my_flood_reports() returns json
language sql stable security invoker set search_path = ''
as $$
  select coalesce(json_agg(r order by r.created_at desc), '[]'::json)
  from (
    select id, kind, coalesce(occurred_at, incident_date::timestamptz) as occurred_at,
           type, severity, depth_band, status, staff_note, created_at
    from public.damage_reports
    where reporter_id = auth.uid()
    order by created_at desc
    limit 50
  ) r
$$;

-- p: {"total", "babies", "elderly", "reduced_mobility", "needs": [...],
--     "other_need", "centre_id", "lat", "lon", "status"}
-- The centre is the one the user chose when it exists; otherwise the
-- nearest open centre with space from lat/lon. The location is not stored.
create function public.submit_headcount(p jsonb) returns json
language plpgsql security invoker set search_path = ''
as $$
declare
  me uuid := auth.uid();
  centre uuid := public.try_uuid(p->>'centre_id');
begin
  if me is null then raise exception 'Sign in first'; end if;
  if centre is not null and not exists (select 1 from public.evacuation_points where id = centre) then
    centre := null;
  end if;
  if centre is null and p ? 'lat' and p ? 'lon' then
    centre := public.nearest_open_centre((p->>'lat')::double precision, (p->>'lon')::double precision);
  end if;
  insert into public.headcounts
    (household_id, evacuation_point_id, total, babies, elderly, reduced_mobility, needs, other_need, status)
  values (
    me, centre, (p->>'total')::int, coalesce((p->>'babies')::int, 0), coalesce((p->>'elderly')::int, 0),
    coalesce((p->>'reduced_mobility')::int, 0),
    coalesce(array(select jsonb_array_elements_text(p->'needs')), '{}'),
    coalesce(p->>'other_need', ''), coalesce(p->>'status', 'on_the_way'))
  on conflict (household_id) do update set
    evacuation_point_id = excluded.evacuation_point_id, total = excluded.total,
    babies = excluded.babies, elderly = excluded.elderly,
    reduced_mobility = excluded.reduced_mobility, needs = excluded.needs,
    other_need = excluded.other_need, status = excluded.status;
  return public.headcount_json(me);
end $$;

create function public.my_headcount() returns json
language sql stable security invoker set search_path = ''
as $$ select public.headcount_json(auth.uid()) $$;

-- On the way -> Arrived -> Left the centre.
create function public.set_headcount_status(p_status text) returns json
language plpgsql security invoker set search_path = ''
as $$
begin
  update public.headcounts set status = p_status where household_id = auth.uid();
  if not found then raise exception 'No headcount sent from this phone'; end if;
  return public.headcount_json(auth.uid());
end $$;

create function public.remove_headcount() returns void
language sql security invoker set search_path = ''
as $$ delete from public.headcounts where household_id = auth.uid() $$;

-- People reported per centre: on the way or arrived, not expired. Totals
-- only (no households), so the public may read them.
create function public.reported_people() returns table (centre_id uuid, people bigint)
language sql stable security definer set search_path = ''
as $$
  select evacuation_point_id, sum(total)
  from public.headcounts
  where evacuation_point_id is not null and status in ('on_the_way', 'arrived') and expires_at > now()
  group by evacuation_point_id
$$;

do $$
declare f text;
begin
  foreach f in array array['try_uuid(text)', 'nearest_open_centre(double precision, double precision)',
      'headcount_json(uuid)', 'submit_flood_report(jsonb)', 'my_flood_reports()',
      'submit_headcount(jsonb)', 'my_headcount()', 'set_headcount_status(text)',
      'remove_headcount()', 'reported_people()'] loop
    execute format('revoke execute on function public.%s from public', f);
    execute format('grant execute on function public.%s to authenticated', f);
  end loop;
end $$;
grant execute on function public.reported_people() to anon;
