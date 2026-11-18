-- =====================================================================
-- Staff areas: each staff member works only inside their own area.
-- How to use: Supabase dashboard -> SQL Editor -> paste this whole file -> Run.
-- Run it once, AFTER schema.sql and readings.sql.
--
--   Super Admin   = every district.
--   Coordinator   = one district (staff_profiles.assigned_district).
--   Field Officer = one resource point (staff_profiles.assigned_resource_point_id)
--                   and the relief centres it supplies. Sees damage reports in
--                   that point's district but cannot review them.
--
-- Same rules as packages/flood_core (StaffSession.covers..., AccessControl).
-- Rows that already exist without a district are visible to Super Admins only
-- until a district is set. The query at the end of this file lists them.
-- =====================================================================

-- ---------- the nine Selangor districts (JPS spelling) ----------

create table public.districts (name text primary key);
insert into public.districts (name) values
  ('GOMBAK'), ('HULU LANGAT'), ('HULU SELANGOR'), ('KLANG'), ('KUALA LANGAT'),
  ('KUALA SELANGOR'), ('PETALING'), ('SABAK BERNAM'), ('SEPANG');
alter table public.districts enable row level security;
create policy districts_read on public.districts for select to anon, authenticated using (true);
grant select on public.districts to anon, authenticated;

-- ---------- new columns ----------

alter table public.resource_points add column district text references public.districts (name);
alter table public.evacuation_points add column district text references public.districts (name);
alter table public.staff_profiles add column assigned_district text references public.districts (name);
alter table public.damage_reports add column district text references public.districts (name);
create index damage_reports_district_idx on public.damage_reports (district);

-- New and edited points must have a district. "not valid" leaves old rows
-- alone until someone edits them.
alter table public.resource_points
  add constraint resource_points_district_required check (district is not null) not valid;
alter table public.evacuation_points
  add constraint evacuation_points_district_required check (district is not null) not valid;

-- A coordinator now needs a district (was: a resource point);
-- a field officer needs a resource point.
alter table public.staff_profiles drop constraint staff_profiles_check;
alter table public.staff_profiles
  add constraint staff_coordinator_needs_district
    check (role <> 'coordinator' or assigned_district is not null) not valid,
  add constraint staff_officer_needs_point
    check (role <> 'field_officer' or assigned_resource_point_id is not null) not valid;

-- ---------- helpers: what is inside the caller's area ----------
-- security definer: they read staff_profiles / resource_points / evacuation_points
-- without being limited by those tables' own row rules.

-- Coordinator: their district. Field officer: their resource point's district.
create function public.staff_district() returns text
language sql stable security definer set search_path = ''
as $$
  select case s.role
           when 'coordinator' then s.assigned_district
           when 'field_officer' then (select r.district from public.resource_points r
                                      where r.id = s.assigned_resource_point_id)
         end
  from public.staff_profiles s where s.id = (select auth.uid()) and s.active
$$;

create function public.staff_resource_point() returns uuid
language sql stable security definer set search_path = ''
as $$
  select assigned_resource_point_id from public.staff_profiles
  where id = (select auth.uid()) and active and role = 'field_officer'
$$;

-- Records with no district: Super Admin only.
create function public.staff_covers_district(d text) returns boolean
language sql stable security definer set search_path = ''
as $$
  select coalesce(public.staff_role() = 'super_admin'
                  or (d is not null and d = public.staff_district()), false)
$$;

create function public.staff_covers_point(rp uuid) returns boolean
language sql stable security definer set search_path = ''
as $$
  select coalesce(case public.staff_role()
    when 'super_admin' then true
    when 'coordinator' then (select r.district from public.resource_points r where r.id = rp)
                            = public.staff_district()
    when 'field_officer' then rp = public.staff_resource_point()
  end, false)
$$;

-- A relief centre, given its district and supplying resource point.
create function public.staff_covers_centre(d text, rp uuid) returns boolean
language sql stable security definer set search_path = ''
as $$
  select coalesce(case public.staff_role()
    when 'super_admin' then true
    when 'coordinator' then d = public.staff_district()
    when 'field_officer' then rp = public.staff_resource_point()
  end, false)
$$;

-- Same, by centre id (for headcounts). No centre: Super Admin only.
create function public.staff_covers_centre_id(ep uuid) returns boolean
language sql stable security definer set search_path = ''
as $$
  select coalesce(public.staff_role() = 'super_admin'
    or (select public.staff_covers_centre(e.district, e.resource_point_id)
        from public.evacuation_points e where e.id = ep), false)
$$;

do $$
declare f text;
begin
  foreach f in array array['staff_district()', 'staff_resource_point()',
      'staff_covers_district(text)', 'staff_covers_point(uuid)',
      'staff_covers_centre(text, uuid)', 'staff_covers_centre_id(uuid)'] loop
    execute format('revoke execute on function public.%s from public', f);
    execute format('grant execute on function public.%s to authenticated', f);
  end loop;
end $$;

-- ---------- damage reports: district from the nearest JPS station ----------
-- Within 25 km, Selangor stations only (readings.sql keeps jps_stations up to
-- date). Always worked out here, so a reporter cannot choose it.
create function public.nearest_district(p_lat double precision, p_lon double precision)
returns text
language sql stable security definer set search_path = ''
as $$
  select d.name
  from public.jps_stations s
  join public.districts d on d.name = upper(trim(s.district))
  where s.lat is not null and s.lon is not null
    and 2 * 6371 * asin(least(1, sqrt(
          power(sin(radians(s.lat - p_lat) / 2), 2)
          + cos(radians(p_lat)) * cos(radians(s.lat))
            * power(sin(radians(s.lon - p_lon) / 2), 2)))) <= 25
  order by power(s.lat - p_lat, 2) + power((s.lon - p_lon) * cos(radians(p_lat)), 2)
  limit 1
$$;
revoke execute on function public.nearest_district(double precision, double precision) from public;
grant execute on function public.nearest_district(double precision, double precision) to authenticated;

create function public.damage_reports_set_district() returns trigger
language plpgsql security definer set search_path = ''
as $$
begin
  if tg_op = 'INSERT' then
    new.district := public.nearest_district(new.lat, new.lon);
  else
    new.district := old.district; -- a review never moves a report to another area
  end if;
  return new;
end $$;
create trigger damage_reports_set_district before insert or update on public.damage_reports
  for each row execute function public.damage_reports_set_district();

-- ---------- row rules, now limited by area ----------

-- evacuation points: everyone reads (public map); changes only inside the area
drop policy evac_insert on public.evacuation_points;
drop policy evac_update on public.evacuation_points;
drop policy evac_delete on public.evacuation_points;
create policy evac_insert on public.evacuation_points for insert to authenticated
  with check ((select public.staff_role()) in ('super_admin', 'coordinator')
              and public.staff_covers_centre(district, resource_point_id));
create policy evac_update on public.evacuation_points for update to authenticated
  using (public.staff_covers_centre(district, resource_point_id))
  with check (public.staff_covers_centre(district, resource_point_id));
create policy evac_delete on public.evacuation_points for delete to authenticated
  using ((select public.staff_role()) in ('super_admin', 'coordinator')
         and public.staff_covers_centre(district, resource_point_id));

-- resource points
drop policy rp_read on public.resource_points;
drop policy rp_insert on public.resource_points;
drop policy rp_update on public.resource_points;
drop policy rp_delete on public.resource_points;
create policy rp_read on public.resource_points for select to authenticated
  using (public.staff_covers_point(id));
create policy rp_insert on public.resource_points for insert to authenticated
  with check ((select public.staff_role()) in ('super_admin', 'coordinator')
              and public.staff_covers_district(district));
create policy rp_update on public.resource_points for update to authenticated
  using ((select public.staff_role()) in ('super_admin', 'coordinator') and public.staff_covers_point(id))
  with check (public.staff_covers_district(district));
create policy rp_delete on public.resource_points for delete to authenticated
  using ((select public.staff_role()) in ('super_admin', 'coordinator') and public.staff_covers_point(id));

-- inventory: by the resource point that holds it
drop policy inv_read on public.inventory_items;
drop policy inv_insert on public.inventory_items;
drop policy inv_update on public.inventory_items;
drop policy inv_delete on public.inventory_items;
create policy inv_read on public.inventory_items for select to authenticated
  using (public.staff_covers_point(resource_point_id));
create policy inv_insert on public.inventory_items for insert to authenticated
  with check (public.staff_covers_point(resource_point_id));
create policy inv_update on public.inventory_items for update to authenticated
  using (public.staff_covers_point(resource_point_id))
  with check (public.staff_covers_point(resource_point_id));
create policy inv_delete on public.inventory_items for delete to authenticated
  using ((select public.staff_role()) in ('super_admin', 'coordinator')
         and public.staff_covers_point(resource_point_id));

-- damage reports: reporters see their own; staff see their district;
-- only Super Admins and Coordinators review
drop policy dr_read on public.damage_reports;
drop policy dr_review on public.damage_reports;
create policy dr_read on public.damage_reports for select to authenticated
  using (reporter_id = (select auth.uid()) or public.staff_covers_district(district));
create policy dr_review on public.damage_reports for update to authenticated
  using ((select public.staff_role()) in ('super_admin', 'coordinator')
         and public.staff_covers_district(district))
  with check ((select public.staff_role()) in ('super_admin', 'coordinator'));

-- headcounts: households manage their own; staff see their centres
drop policy hc_read on public.headcounts;
create policy hc_read on public.headcounts for select to authenticated
  using (household_id = (select auth.uid()) or public.staff_covers_centre_id(evacuation_point_id));

-- ---------- after running: rows that still need a district ----------
-- select 'resource point' as kind, name from public.resource_points where district is null
-- union all select 'relief centre', name from public.evacuation_points where district is null
-- union all select 'coordinator', username from public.staff_profiles
--   where role = 'coordinator' and assigned_district is null
-- union all select 'field officer', username from public.staff_profiles
--   where role = 'field_officer' and assigned_resource_point_id is null;
