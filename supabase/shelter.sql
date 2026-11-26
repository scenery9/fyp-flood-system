-- =====================================================================
-- Relief centre allocation for a family, and supplies needed vs in stock.
-- How to use: Supabase dashboard -> SQL Editor -> paste this whole file -> Run.
-- Run it once, AFTER family.sql.
--
-- Allocation (assign_family_centre): a small multi-criteria choice made
-- inside one transaction, so two families can never both take the last
-- places. For family f of N people, each open centre c is
--   feasible  if  occupied(c) + N <= capacity(c)                (whole family together)
--            and (nobody uses a wheelchair or c has a ramp)
--   cost(c) = 0.5 * min(distance/50 km, 1)
--           + 0.3 * (occupied(c) + N) / capacity(c)
--           + 0.2 * flood hazard at c (0 normal .. 1 danger, nearest gauge within 5 km)
--           + 0.15 if the family has pets and c does not take them
-- and the feasible centre with the lowest cost wins; centres that would be
-- over 90% full are used only when nothing else fits. occupied(c) = staff
-- count + families still on the way. The answer says why ("allocation_note").
-- ml/ (later) checks the same model with an exact solver on batches.
-- =====================================================================

-- ---------- what each centre offers ----------

alter table public.evacuation_points
  -- Each hall is its own row with its own (unique) name, e.g. "PPS Sri Muda
  -- Dewan A"; hall_group names the site that groups them ("PPS Sri Muda").
  add column hall_group text check (hall_group is null or length(trim(hall_group)) between 1 and 40),
  add column has_wheelchair_ramp boolean not null default false,
  add column pet_friendly boolean not null default false;

-- Field officers record people and open/closed; access details are for coordinators.
create function public.evacuation_points_access_guard() returns trigger
language plpgsql security definer set search_path = ''
as $$
begin
  if public.staff_role() = 'field_officer'
     and (new.hall_group, new.has_wheelchair_ramp, new.pet_friendly)
         is distinct from (old.hall_group, old.has_wheelchair_ramp, old.pet_friendly) then
    raise exception 'Field officers can only change occupancy and open/closed';
  end if;
  return new;
end $$;
create trigger evacuation_points_access_guard before update on public.evacuation_points
  for each row execute function public.evacuation_points_access_guard();

-- Stock that the supply check counts (other stock simply has no kind).
alter table public.inventory_items
  add column supply_kind text check (supply_kind in
    ('water_l', 'blanket', 'baby_pack', 'sanitary_pack', 'wheelchair', 'first_aid_kit'));

-- ---------- helpers ----------

create function private.km(lat1 double precision, lon1 double precision,
    lat2 double precision, lon2 double precision) returns double precision
language sql immutable set search_path = ''
as $$
  select 2 * 6371 * asin(least(1, sqrt(
    power(sin(radians(lat2 - lat1) / 2), 2)
    + cos(radians(lat1)) * cos(radians(lat2)) * power(sin(radians(lon2 - lon1) / 2), 2))))
$$;

-- 0 / 0.33 / 0.67 / 1 for Normal / Alert / Warning / Danger at the nearest
-- river gauge within 5 km with a reading from the last 3 hours; 0 if none.
create function private.centre_hazard(p_lat double precision, p_lon double precision) returns double precision
language sql stable security definer set search_path = ''
as $$
  select coalesce((
    select case when l.level_m >= l.wl_danger then 1.0
                when l.level_m >= l.wl_warning then 0.67
                when l.level_m >= l.wl_alert then 0.33
                else 0 end
    from public.jps_latest l
    where l.level_m is not null and l.level_at > now() - interval '3 hours'
      and l.lat is not null and private.km(p_lat, p_lon, l.lat, l.lon) <= 5
    order by private.km(p_lat, p_lon, l.lat, l.lon)
    limit 1), 0)
$$;

-- ---------- allocation (replaces the simple version in family.sql) ----------

create or replace function public.assign_family_centre(p_household uuid, p_preferred uuid,
    p_lat double precision, p_lon double precision) returns uuid
language plpgsql security definer set search_path = ''
as $$
declare
  h public.headcounts;
  o_lat double precision := p_lat;
  o_lon double precision := p_lon;
  best record;
  pref record;
  why text := '';
  r record;
begin
  -- One allocation at a time: the capacity counts below cannot go stale.
  perform pg_advisory_xact_lock(hashtext('floodready:shelter_allocation'));
  select * into h from public.headcounts where household_id = p_household;
  if h.household_id is null then return null; end if;

  -- No location: measure from the centre the family picked, if any.
  if o_lat is null or o_lon is null then
    select lat, lon into o_lat, o_lon from public.evacuation_points where id = p_preferred;
  end if;
  if o_lat is null or o_lon is null then
    update public.headcounts set evacuation_point_id = null,
      allocation_note = 'No location: choose a centre or allow location'
    where household_id = p_household;
    return null;
  end if;

  create temp table if not exists pg_temp.alloc (
    id uuid, name text, dist double precision, occupied integer, capacity integer, load_after double precision,
    fits boolean, ramp_ok boolean, pets_ok boolean, hazard double precision, cost double precision
  ) on commit drop;
  delete from pg_temp.alloc;
  insert into pg_temp.alloc
  select e.id, e.name, d.km, o.occupied, e.capacity,
         (o.occupied + h.total)::double precision / e.capacity,
         o.occupied + h.total <= e.capacity,
         h.reduced_mobility = 0 or e.has_wheelchair_ramp,
         h.pets = 0 or e.pet_friendly,
         z.hazard,
         0.5 * least(d.km / 50, 1) + 0.3 * (o.occupied + h.total)::double precision / e.capacity
           + 0.2 * z.hazard + case when h.pets > 0 and not e.pet_friendly then 0.15 else 0 end
  from public.evacuation_points e
  cross join lateral (select private.km(o_lat, o_lon, e.lat, e.lon) as km) d
  cross join lateral (select e.occupancy + coalesce((
      select sum(x.total) from public.headcounts x
      where x.evacuation_point_id = e.id and x.status = 'on_the_way' and x.expires_at > now()
        and x.household_id <> p_household), 0)::integer as occupied) o
  cross join lateral (select private.centre_hazard(e.lat, e.lon) as hazard) z
  where e.is_open and e.location_checked and d.km <= 150;

  select * into best from pg_temp.alloc
  where fits and ramp_ok
  order by (load_after > 0.9), cost, dist
  limit 1;
  select * into pref from pg_temp.alloc where id = p_preferred;

  if best.id is null then
    update public.headcounts set evacuation_point_id = null,
      allocation_note = format('No open centre within 150 km has space for %s people%s', h.total,
        case when h.reduced_mobility > 0 then ' with wheelchair access' else '' end)
    where household_id = p_household;
    return null;
  end if;

  -- The family's own choice stands when it fits and is not nearly full.
  if pref.id is not null and pref.fits and pref.ramp_ok and pref.load_after <= 0.9 then
    best := pref;
    why := format('Your choice: %s (%s km)', pref.name, round(pref.dist::numeric, 1));
  else
    why := format('Assigned to %s (%s km)', best.name, round(best.dist::numeric, 1));
    -- Explain each nearer (or chosen) centre that was passed over.
    for r in select * from pg_temp.alloc
             where id <> best.id and (dist < best.dist or id = p_preferred)
             order by dist limit 3 loop
      why := why || format('. %s: %s', r.name, case
        when not r.fits then format('full (%s of %s places taken)', r.occupied, r.capacity)
        when not r.ramp_ok then 'no wheelchair ramp'
        when r.load_after > 0.9 then format('would be %s%% full', round(r.load_after * 100))
        when r.hazard > 0 then 'river near it is above normal'
        when not r.pets_ok then 'does not take pets'
        else 'busier or farther overall' end);
    end loop;
    if h.reduced_mobility > 0 then why := why || format('. %s has wheelchair ramp access', best.name); end if;
  end if;

  update public.headcounts set evacuation_point_id = best.id, allocation_note = left(why, 500)
  where household_id = p_household;
  return best.id;
end $$;
revoke execute on function public.assign_family_centre(uuid, uuid, double precision, double precision) from public;

-- Ask again (e.g. the centre filled up): re-runs the allocation for the
-- caller's active family registration from where they are now.
create function public.allocate_family_shelter(p_lat double precision, p_lon double precision) returns json
language plpgsql security definer set search_path = ''
as $$
declare me public.family_members := private.me_in_family(); hh uuid;
begin
  select household_id into hh from public.headcounts
  where family_group_id = me.group_id and status = 'on_the_way' and expires_at > now();
  if hh is null then raise exception 'Your family has no registration on the way'; end if;
  perform public.assign_family_centre(hh, null, p_lat, p_lon);
  return private.family_headcount_json(me.group_id);
end $$;
revoke execute on function public.allocate_family_shelter(double precision, double precision) from public;
grant execute on function public.allocate_family_shelter(double precision, double precision) to authenticated;

-- ---------- supplies needed vs in stock ----------
-- Per resource point (stock is kept there for all its centres), people on
-- the way or arrived and not expired:
--   water_l       = people x 3          blanket       = people x 1
--   baby_pack     = babies x 1          sanitary_pack = ceil((people - babies - elderly) x 0.5)
--   wheelchair    = people using one    first_aid_kit = each common sickness + "cold medicine" need
-- (people - babies - elderly = children and adults, including extra people
-- whose age was not given.) security_invoker: staff see only their area.
create view public.shelter_supply_demand with (security_invoker = on) as
with demand as (
  select e.resource_point_id,
         sum(h.total) as people, sum(h.babies) as babies,
         sum(greatest(h.total - h.babies - h.elderly, 0)) as children_adults,
         sum(h.reduced_mobility) as mobility,
         sum(coalesce((select sum(v::int) from jsonb_each_text(h.common_sickness_summary) as j(k, v)), 0)
             + case when 'cold_medicine' = any (h.needs) then 1 else 0 end) as sick
  from public.headcounts h
  join public.evacuation_points e on e.id = h.evacuation_point_id
  where h.status in ('on_the_way', 'arrived') and h.expires_at > now() and e.resource_point_id is not null
  group by e.resource_point_id
), need as (
  select d.resource_point_id, k.kind, k.required
  from demand d
  cross join lateral (values
    ('water_l', d.people * 3.0), ('blanket', d.people * 1.0), ('baby_pack', d.babies * 1.0),
    ('sanitary_pack', ceil(d.children_adults * 0.5)), ('wheelchair', d.mobility * 1.0),
    ('first_aid_kit', d.sick * 1.0)) as k(kind, required)
), stock as (
  select resource_point_id, supply_kind, sum(quantity) as qty
  from public.inventory_items where supply_kind is not null
  group by resource_point_id, supply_kind
)
select n.resource_point_id, r.name as resource_point, n.kind, n.required,
       coalesce(s.qty, 0) as in_stock, greatest(n.required - coalesce(s.qty, 0), 0) as deficit
from need n
join public.resource_points r on r.id = n.resource_point_id
left join stock s on s.resource_point_id = n.resource_point_id and s.supply_kind = n.kind;

grant select on public.shelter_supply_demand to authenticated;
