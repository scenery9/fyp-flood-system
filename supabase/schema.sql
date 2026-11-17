-- =====================================================================
-- Flood system: tables and access rules for Supabase (free plan).
-- How to use: Supabase dashboard -> SQL Editor -> paste this whole file -> Run.
-- Run it once on a new project. It mirrors the rules in packages/flood_core.
--
-- Who is who:
--   anon          = app opened, not signed in. May only read evacuation points.
--   authenticated = any signed-in user. Members of the public use Supabase
--                   "anonymous sign-in" (no account needed) so each phone
--                   gets its own id; staff sign in with email + password.
--   staff         = an authenticated user who has an active row in staff_profiles.
-- Passwords are stored and checked by Supabase Auth, never in these tables.
-- =====================================================================

-- ---------- tables ----------

create table public.resource_points (
  id uuid primary key default gen_random_uuid(),
  name text not null check (length(trim(name)) > 0),
  lat double precision not null check (lat between -90 and 90),
  lon double precision not null check (lon between -180 and 180),
  created_at timestamptz not null default now()
);
create unique index resource_points_name_key on public.resource_points (lower(name));

create table public.staff_profiles (
  id uuid primary key references auth.users (id) on delete cascade,
  full_name text not null check (length(trim(full_name)) > 0),
  username text not null unique check (username ~ '^[a-z0-9._]{3,30}$'),
  phone text check (phone is null or phone ~ '^\+?[0-9]{7,15}$'),
  role text not null check (role in ('super_admin', 'coordinator', 'field_officer')),
  assigned_resource_point_id uuid references public.resource_points (id) on delete restrict,
  active boolean not null default true,
  created_at timestamptz not null default now(),
  check (role <> 'coordinator' or assigned_resource_point_id is not null)
);

create table public.evacuation_points (
  id uuid primary key default gen_random_uuid(),
  name text not null check (length(trim(name)) > 0),
  lat double precision not null check (lat between -90 and 90),
  lon double precision not null check (lon between -180 and 180),
  capacity integer not null check (capacity > 0),
  occupancy integer not null default 0,
  is_open boolean not null default true,
  resource_point_id uuid references public.resource_points (id) on delete restrict,
  created_at timestamptz not null default now(),
  check (occupancy between 0 and capacity)
);
create unique index evacuation_points_name_key on public.evacuation_points (lower(name));

create table public.catalogue_units (
  id uuid primary key default gen_random_uuid(),
  name text not null check (length(trim(name)) > 0),
  unit text not null check (length(trim(unit)) > 0),
  daily_need_per_person double precision not null check (daily_need_per_person > 0)
);

create table public.inventory_items (
  id uuid primary key default gen_random_uuid(),
  resource_point_id uuid not null references public.resource_points (id) on delete restrict,
  name text not null check (length(trim(name)) > 0),
  quantity double precision not null check (quantity >= 0),
  catalogue_unit_id uuid references public.catalogue_units (id) on delete set null,
  expiry_date date
);

create table public.damage_reports (
  id uuid primary key default gen_random_uuid(),
  reporter_id uuid not null default auth.uid() references auth.users (id) on delete cascade,
  lat double precision not null check (lat between -90 and 90),
  lon double precision not null check (lon between -180 and 180),
  incident_date date not null,
  type text not null check (type in ('house', 'vehicle', 'road', 'utilities', 'crops', 'other')),
  severity text not null check (severity in ('minor', 'moderate', 'severe')),
  depth_m double precision check (depth_m is null or depth_m between 0 and 10),
  description text not null default '' check (length(description) <= 500),
  status text not null default 'pending' check (status in ('pending', 'verified', 'rejected', 'duplicate')),
  staff_note text,
  reviewed_by uuid references public.staff_profiles (id) on delete set null,
  reviewed_at timestamptz,
  duplicate_of_id uuid references public.damage_reports (id) on delete set null,
  created_at timestamptz not null default now(),
  check (status <> 'rejected' or length(trim(coalesce(staff_note, ''))) > 0),
  check (duplicate_of_id is null or duplicate_of_id <> id)
);
create index damage_reports_reporter_idx on public.damage_reports (reporter_id);
create index damage_reports_status_idx on public.damage_reports (status);

-- One row per household (phone), so a household is never counted twice.
create table public.headcounts (
  household_id uuid primary key default auth.uid() references auth.users (id) on delete cascade,
  evacuation_point_id uuid references public.evacuation_points (id) on delete set null,
  total integer not null check (total between 1 and 30),
  babies integer not null default 0 check (babies >= 0),
  elderly integer not null default 0 check (elderly >= 0),
  reduced_mobility integer not null default 0 check (reduced_mobility >= 0),
  submitted_at timestamptz not null default now(),
  check (babies + elderly <= total),
  check (reduced_mobility <= total)
);

-- ---------- helper: the caller's staff role (null if not active staff) ----------

create function public.staff_role() returns text
language sql stable security definer set search_path = ''
as $$
  select role from public.staff_profiles where id = (select auth.uid()) and active
$$;
revoke execute on function public.staff_role() from public;
grant execute on function public.staff_role() to authenticated;

-- ---------- triggers: rules that row policies alone cannot express ----------

-- New reports always start as pending; date and anti-spam checks.
create function public.damage_reports_before_insert() returns trigger
language plpgsql security definer set search_path = ''
as $$
declare today date := (now() at time zone 'Asia/Kuala_Lumpur')::date;
begin
  new.status := 'pending';
  new.staff_note := null;
  new.reviewed_by := null;
  new.reviewed_at := null;
  new.duplicate_of_id := null;
  new.created_at := now();
  new.description := trim(new.description);
  if new.incident_date > today then
    raise exception 'Date cannot be in the future';
  end if;
  if new.incident_date < today - 365 then
    raise exception 'Date cannot be more than a year ago';
  end if;
  if (select count(*) from public.damage_reports
      where reporter_id = new.reporter_id and status = 'pending') >= 5 then
    raise exception 'Too many reports waiting for review';
  end if;
  return new;
end $$;
create trigger damage_reports_before_insert before insert on public.damage_reports
  for each row execute function public.damage_reports_before_insert();

-- Review: only pending reports, only the review fields may change.
create function public.damage_reports_before_update() returns trigger
language plpgsql security definer set search_path = ''
as $$
begin
  if old.status <> 'pending' then
    raise exception 'Report was already reviewed';
  end if;
  if new.status = 'pending' then
    raise exception 'Choose verified, rejected or duplicate';
  end if;
  new.reporter_id := old.reporter_id;
  new.lat := old.lat;
  new.lon := old.lon;
  new.incident_date := old.incident_date;
  new.type := old.type;
  new.severity := old.severity;
  new.depth_m := old.depth_m;
  new.description := old.description;
  new.created_at := old.created_at;
  new.reviewed_by := auth.uid();
  new.reviewed_at := now();
  if new.status = 'duplicate' then
    if new.duplicate_of_id is null or not exists (
        select 1 from public.damage_reports
        where id = new.duplicate_of_id and status in ('pending', 'verified')) then
      raise exception 'Duplicate must point to a pending or verified report';
    end if;
  else
    new.duplicate_of_id := null;
  end if;
  return new;
end $$;
create trigger damage_reports_before_update before update on public.damage_reports
  for each row execute function public.damage_reports_before_update();

-- Keep at least one active Super Admin; nobody deactivates their own account.
create function public.staff_profiles_guard() returns trigger
language plpgsql security definer set search_path = ''
as $$
begin
  if old.role = 'super_admin' and old.active
     and (tg_op = 'DELETE' or new.role <> 'super_admin' or not new.active) then
    if not exists (select 1 from public.staff_profiles
                   where role = 'super_admin' and active and id <> old.id) then
      raise exception 'At least one active Super Admin is required';
    end if;
  end if;
  if tg_op = 'UPDATE' then
    if old.id = auth.uid() and old.active and not new.active then
      raise exception 'You cannot deactivate your own account';
    end if;
    return new;
  end if;
  return old;
end $$;
create trigger staff_profiles_guard before update or delete on public.staff_profiles
  for each row execute function public.staff_profiles_guard();

-- Field officers may change only occupancy and open/closed; no delete while occupied.
create function public.evacuation_points_guard() returns trigger
language plpgsql security definer set search_path = ''
as $$
begin
  if tg_op = 'DELETE' then
    if old.occupancy > 0 then
      raise exception 'Centre still has people recorded';
    end if;
    return old;
  end if;
  if public.staff_role() = 'field_officer'
     and (new.name, new.lat, new.lon, new.capacity, new.resource_point_id)
         is distinct from (old.name, old.lat, old.lon, old.capacity, old.resource_point_id) then
    raise exception 'Field officers can only change occupancy and open/closed';
  end if;
  return new;
end $$;
create trigger evacuation_points_guard before update or delete on public.evacuation_points
  for each row execute function public.evacuation_points_guard();

-- Field officers may change stock quantity, but not the catalogue mapping.
create function public.inventory_items_guard() returns trigger
language plpgsql security definer set search_path = ''
as $$
begin
  if public.staff_role() = 'field_officer'
     and (new.catalogue_unit_id, new.resource_point_id)
         is distinct from (old.catalogue_unit_id, old.resource_point_id) then
    raise exception 'Field officers cannot change the catalogue mapping';
  end if;
  return new;
end $$;
create trigger inventory_items_guard before update on public.inventory_items
  for each row execute function public.inventory_items_guard();

-- ---------- row level security ----------

alter table public.resource_points enable row level security;
alter table public.staff_profiles enable row level security;
alter table public.evacuation_points enable row level security;
alter table public.catalogue_units enable row level security;
alter table public.inventory_items enable row level security;
alter table public.damage_reports enable row level security;
alter table public.headcounts enable row level security;

-- evacuation points: everyone reads; coordinators and admins add/delete; any staff updates
create policy evac_read on public.evacuation_points for select to anon, authenticated using (true);
create policy evac_insert on public.evacuation_points for insert to authenticated
  with check ((select public.staff_role()) in ('super_admin', 'coordinator'));
create policy evac_update on public.evacuation_points for update to authenticated
  using ((select public.staff_role()) is not null) with check ((select public.staff_role()) is not null);
create policy evac_delete on public.evacuation_points for delete to authenticated
  using ((select public.staff_role()) in ('super_admin', 'coordinator'));

-- resource points: staff read; coordinators and admins change
create policy rp_read on public.resource_points for select to authenticated
  using ((select public.staff_role()) is not null);
create policy rp_insert on public.resource_points for insert to authenticated
  with check ((select public.staff_role()) in ('super_admin', 'coordinator'));
create policy rp_update on public.resource_points for update to authenticated
  using ((select public.staff_role()) in ('super_admin', 'coordinator'))
  with check ((select public.staff_role()) in ('super_admin', 'coordinator'));
create policy rp_delete on public.resource_points for delete to authenticated
  using ((select public.staff_role()) in ('super_admin', 'coordinator'));

-- catalogue units: staff read; coordinators and admins change
create policy cu_read on public.catalogue_units for select to authenticated
  using ((select public.staff_role()) is not null);
create policy cu_insert on public.catalogue_units for insert to authenticated
  with check ((select public.staff_role()) in ('super_admin', 'coordinator'));
create policy cu_update on public.catalogue_units for update to authenticated
  using ((select public.staff_role()) in ('super_admin', 'coordinator'))
  with check ((select public.staff_role()) in ('super_admin', 'coordinator'));
create policy cu_delete on public.catalogue_units for delete to authenticated
  using ((select public.staff_role()) in ('super_admin', 'coordinator'));

-- inventory: any staff reads, adds and updates; coordinators and admins delete
create policy inv_read on public.inventory_items for select to authenticated
  using ((select public.staff_role()) is not null);
create policy inv_insert on public.inventory_items for insert to authenticated
  with check ((select public.staff_role()) is not null);
create policy inv_update on public.inventory_items for update to authenticated
  using ((select public.staff_role()) is not null) with check ((select public.staff_role()) is not null);
create policy inv_delete on public.inventory_items for delete to authenticated
  using ((select public.staff_role()) in ('super_admin', 'coordinator'));

-- damage reports: reporters see their own; staff see and review all; nobody deletes
create policy dr_read on public.damage_reports for select to authenticated
  using (reporter_id = (select auth.uid()) or (select public.staff_role()) is not null);
create policy dr_insert on public.damage_reports for insert to authenticated
  with check (reporter_id = (select auth.uid()));
create policy dr_review on public.damage_reports for update to authenticated
  using ((select public.staff_role()) is not null) with check ((select public.staff_role()) is not null);

-- headcounts: a household manages its own row; staff read all
create policy hc_read on public.headcounts for select to authenticated
  using (household_id = (select auth.uid()) or (select public.staff_role()) is not null);
create policy hc_insert on public.headcounts for insert to authenticated
  with check (household_id = (select auth.uid()));
create policy hc_update on public.headcounts for update to authenticated
  using (household_id = (select auth.uid())) with check (household_id = (select auth.uid()));
create policy hc_delete on public.headcounts for delete to authenticated
  using (household_id = (select auth.uid()));

-- staff profiles: staff see their own row; only Super Admins see and change all
create policy sp_read on public.staff_profiles for select to authenticated
  using (id = (select auth.uid()) or (select public.staff_role()) = 'super_admin');
create policy sp_insert on public.staff_profiles for insert to authenticated
  with check ((select public.staff_role()) = 'super_admin');
create policy sp_update on public.staff_profiles for update to authenticated
  using ((select public.staff_role()) = 'super_admin') with check ((select public.staff_role()) = 'super_admin');
create policy sp_delete on public.staff_profiles for delete to authenticated
  using ((select public.staff_role()) = 'super_admin');

-- ---------- grants (the API can only touch what is granted here) ----------

grant usage on schema public to anon, authenticated;
grant select on public.evacuation_points to anon;
grant select, insert, update, delete on
  public.evacuation_points, public.resource_points, public.catalogue_units,
  public.inventory_items, public.headcounts, public.staff_profiles to authenticated;
grant select, insert, update on public.damage_reports to authenticated;

-- ---------- first Super Admin (do this once, by hand) ----------
-- 1. Dashboard -> Authentication -> Users -> Add user (email + password).
-- 2. Copy that user's id, then run in the SQL Editor:
--    insert into public.staff_profiles (id, full_name, username, role)
--    values ('<paste-user-id>', 'Your Name', 'admin', 'super_admin');
