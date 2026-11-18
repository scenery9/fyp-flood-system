-- =====================================================================
-- Headcount by age group, pets and health needs.
-- How to use: Supabase dashboard -> SQL Editor -> paste this whole file -> Run.
-- Run it once, AFTER public_reports.sql.
-- Same rules as packages/flood_core (public_reports_service.dart).
-- =====================================================================

alter table public.headcounts
  add column children integer not null default 0 check (children >= 0),
  add column adults integer not null default 0 check (adults >= 0),
  add column pets integer not null default 0 check (pets between 0 and 20),
  add column daily_medicine boolean not null default false,
  -- Someone uses oxygen or another machine that needs power.
  add column power_machine boolean not null default false,
  add constraint headcounts_groups_within_total
    check (babies + children + adults + elderly <= total);

create or replace function public.headcount_json(p_household uuid) returns json
language sql stable security invoker set search_path = ''
as $$
  select json_build_object(
    'total', h.total, 'babies', h.babies, 'children', h.children, 'adults', h.adults,
    'elderly', h.elderly, 'reduced_mobility', h.reduced_mobility, 'pets', h.pets,
    'daily_medicine', h.daily_medicine, 'power_machine', h.power_machine,
    'needs', to_json(h.needs), 'other_need', h.other_need, 'status', h.status,
    'updated_at', h.updated_at, 'expires_at', h.expires_at,
    'centre_id', h.evacuation_point_id, 'centre_name', e.name)
  from public.headcounts h
  left join public.evacuation_points e on e.id = h.evacuation_point_id
  where h.household_id = p_household
$$;

-- Same as in public_reports.sql, now with the age groups, pets and needs.
create or replace function public.submit_headcount(p jsonb) returns json
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
    (household_id, evacuation_point_id, total, babies, children, adults, elderly, reduced_mobility,
     pets, daily_medicine, power_machine, needs, other_need, status)
  values (
    me, centre, (p->>'total')::int, coalesce((p->>'babies')::int, 0), coalesce((p->>'children')::int, 0),
    coalesce((p->>'adults')::int, 0), coalesce((p->>'elderly')::int, 0),
    coalesce((p->>'reduced_mobility')::int, 0), coalesce((p->>'pets')::int, 0),
    coalesce((p->>'daily_medicine')::boolean, false), coalesce((p->>'power_machine')::boolean, false),
    coalesce(array(select jsonb_array_elements_text(p->'needs')), '{}'),
    coalesce(p->>'other_need', ''), coalesce(p->>'status', 'on_the_way'))
  on conflict (household_id) do update set
    evacuation_point_id = excluded.evacuation_point_id, total = excluded.total,
    babies = excluded.babies, children = excluded.children, adults = excluded.adults,
    elderly = excluded.elderly, reduced_mobility = excluded.reduced_mobility, pets = excluded.pets,
    daily_medicine = excluded.daily_medicine, power_machine = excluded.power_machine,
    needs = excluded.needs, other_need = excluded.other_need, status = excluded.status;
  return public.headcount_json(me);
end $$;
