-- =====================================================================
-- Family profile, one shelter registration per family, and end-to-end
-- encrypted live location.
-- How to use: Supabase dashboard -> SQL Editor -> paste this whole file -> Run.
-- Run it once, AFTER security.sql.
--
-- A family is one row in family_groups and up to 10 people in
-- family_members: people with the app (user_id set) and people without a
-- phone (babies, grandparents: user_id and phone empty). Each person is one
-- row, so nobody is counted twice.
--
-- The app reads and changes all of this only through the functions below
-- (security definer, each checks who is calling). The tables can be read
-- by the caller's own family and never written directly.
--
-- Location: the phone encrypts (AES-256-GCM, family key from the invite
-- link's #fragment) before upload. family_locations holds only ciphertext;
-- this database never sees the key or a coordinate.
-- =====================================================================

-- ---------- tables ----------

create table public.family_groups (
  id uuid primary key default gen_random_uuid(),
  name text not null default 'My Family' check (length(trim(name)) between 1 and 40),
  -- 12 characters, 72 random bits. Renewed with regenerate_family_invite().
  invite_code text not null unique check (invite_code ~ '^[A-Za-z0-9_-]{12}$'),
  -- Goes up with every new invite: phones then make a new family key.
  key_version integer not null default 1 check (key_version >= 1),
  created_by uuid not null references auth.users (id) on delete cascade,
  created_at timestamptz not null default now()
);

create table public.family_members (
  id uuid primary key default gen_random_uuid(),
  group_id uuid not null references public.family_groups (id) on delete cascade,
  user_id uuid references auth.users (id) on delete set null,      -- null: no app / no phone
  phone_e164 text check (phone_e164 is null or phone_e164 ~ '^\+[1-9][0-9]{7,14}$'),
  display_name text not null check (length(trim(display_name)) between 1 and 40),
  age_category text not null check (age_category in ('baby', 'child', 'adult', 'elderly')),
  mobility_aid boolean not null default false,
  -- Everyday illnesses a relief centre can help with; nothing more medical.
  common_sickness text[] not null default '{}'
    check (common_sickness <@ array['fever', 'flu', 'asthma', 'cough', 'stomach_ache']::text[]),
  role text not null default 'member' check (role in ('admin', 'member')),
  is_outstation boolean not null default false,
  -- Location sharing: off until the person turns it on, for at most 24 hours,
  -- to the family members listed (family_members.id).
  consent_enabled boolean not null default false,
  sharing_expires_at timestamptz,
  allowed_viewer_ids uuid[] not null default '{}',
  created_at timestamptz not null default now(),
  unique (group_id, phone_e164)
);
-- One family per app user.
create unique index family_members_user_key on public.family_members (user_id) where user_id is not null;
create index family_members_group_idx on public.family_members (group_id);

create table public.family_locations (
  member_id uuid primary key references public.family_members (id) on delete cascade,
  group_id uuid not null references public.family_groups (id) on delete cascade,
  ciphertext text not null check (ciphertext ~ '^[A-Za-z0-9+/]+={0,2}$' and length(ciphertext) between 24 and 1024),
  iv text not null check (iv ~ '^[A-Za-z0-9+/]{16}$'),   -- 96 bits
  key_version integer not null,
  updated_at timestamptz not null default now(),
  -- A pin older than this is not shown (the phone refreshes it while sharing).
  expires_at timestamptz not null
);

-- ---------- headcounts: one active registration per family ----------

alter table public.headcounts
  add column family_group_id uuid references public.family_groups (id) on delete set null,
  add column registered_by_user_id uuid references auth.users (id) on delete set null,
  add column selected_member_ids uuid[] not null default '{}',
  add column common_sickness_summary jsonb not null default '{}'::jsonb,
  -- Why this centre was chosen (filled in by shelter.sql's allocation).
  add column allocation_note text;

create unique index headcounts_one_active_per_family on public.headcounts (family_group_id)
  where family_group_id is not null and status in ('on_the_way', 'arrived');

-- ---------- helpers ----------

-- The caller's family and their own row in it (null when not in a family).
-- security definer so the row policies below can use them without recursion.
create function public.my_family_group_id() returns uuid
language sql stable security definer set search_path = ''
as $$ select group_id from public.family_members where user_id = (select auth.uid()) $$;

create function public.my_family_member_id() returns uuid
language sql stable security definer set search_path = ''
as $$ select id from public.family_members where user_id = (select auth.uid()) $$;

create function private.new_invite_code() returns text
language sql volatile set search_path = ''
as $$ select translate(encode(extensions.gen_random_bytes(9), 'base64'), '+/', '-_') $$;

create function private.me_in_family() returns public.family_members
language plpgsql stable security definer set search_path = ''
as $$
declare m public.family_members;
begin
  if (select auth.uid()) is null then raise exception 'Sign in first'; end if;
  select * into m from public.family_members where user_id = (select auth.uid());
  if m.id is null then raise exception 'You are not in a family yet'; end if;
  return m;
end $$;

create function private.require_admin() returns public.family_members
language plpgsql stable security definer set search_path = ''
as $$
declare m public.family_members := private.me_in_family();
begin
  if m.role <> 'admin' then raise exception 'Only the family admin can do this'; end if;
  return m;
end $$;

create function private.check_member_fields(p jsonb) returns void
language plpgsql immutable set search_path = ''
as $$
begin
  if p ? 'display_name' and length(trim(coalesce(p->>'display_name', ''))) not between 1 and 40 then
    raise exception 'Name must be 1 to 40 characters';
  end if;
  if p ? 'age_category' and coalesce(p->>'age_category', '') not in ('baby', 'child', 'adult', 'elderly') then
    raise exception 'Choose Baby, Child, Adult or Elderly';
  end if;
  if nullif(p->>'phone_e164', '') is not null and p->>'phone_e164' !~ '^\+[1-9][0-9]{7,14}$' then
    raise exception 'Phone number must be in +60123456789 form';
  end if;
  if p ? 'common_sickness' and exists (
      select 1 from jsonb_array_elements_text(p->'common_sickness') s
      where s not in ('fever', 'flu', 'asthma', 'cough', 'stomach_ache')) then
    raise exception 'Unknown sickness: choose fever, flu, asthma, cough or stomach_ache';
  end if;
end $$;

create function private.sickness(p jsonb) returns text[]
language sql immutable set search_path = ''
as $$ select coalesce(array(select distinct jsonb_array_elements_text(p->'common_sickness') order by 1), '{}') $$;

-- Takes a member out of everyone's viewer list (left, removed).
create function private.forget_viewer(p_group uuid, p_member uuid) returns void
language sql volatile security definer set search_path = ''
as $$
  update public.family_members set allowed_viewer_ids = array_remove(allowed_viewer_ids, p_member)
  where group_id = p_group and p_member = any (allowed_viewer_ids)
$$;

-- ---------- the family as the app shows it ----------

create function private.family_headcount_json(p_group uuid) returns json
language sql stable security definer set search_path = ''
as $$
  select json_build_object(
    'household_id', h.household_id,
    'registered_by', (select m.display_name from public.family_members m
                      where m.group_id = p_group and m.user_id = h.registered_by_user_id),
    'registered_by_me', h.registered_by_user_id = (select auth.uid()),
    'total', h.total, 'babies', h.babies, 'children', h.children, 'adults', h.adults,
    'elderly', h.elderly, 'reduced_mobility', h.reduced_mobility, 'pets', h.pets,
    'members', coalesce((select json_agg(json_build_object('id', m.id, 'name', m.display_name) order by m.created_at)
                         from public.family_members m where m.id = any (h.selected_member_ids)), '[]'::json),
    'extra_people', h.total - cardinality(h.selected_member_ids),
    'common_sickness', h.common_sickness_summary,
    'status', h.status, 'updated_at', h.updated_at, 'expires_at', h.expires_at,
    'centre_id', h.evacuation_point_id, 'centre_name', e.name, 'allocation_note', h.allocation_note)
  from public.headcounts h
  left join public.evacuation_points e on e.id = h.evacuation_point_id
  where h.family_group_id = p_group and h.status in ('on_the_way', 'arrived') and h.expires_at > now()
$$;

create function public.my_family() returns json
language plpgsql stable security definer set search_path = ''
as $$
declare m public.family_members;
begin
  select * into m from public.family_members where user_id = (select auth.uid());
  if m.id is null then return null; end if;
  return (
    select json_build_object(
      'id', g.id, 'name', g.name, 'key_version', g.key_version,
      -- Only the admin sees the code that lets people join.
      'invite_code', case when m.role = 'admin' then g.invite_code end,
      'me', m.id,
      'members', (select json_agg(json_build_object(
          'id', x.id, 'name', x.display_name, 'role', x.role, 'age_category', x.age_category,
          'phone_e164', x.phone_e164, 'linked', x.user_id is not null, 'is_me', x.id = m.id,
          'mobility_aid', x.mobility_aid, 'common_sickness', to_json(x.common_sickness),
          'is_outstation', x.is_outstation,
          'sharing', x.consent_enabled and x.sharing_expires_at > now() and not x.is_outstation,
          'sharing_expires_at', x.sharing_expires_at,
          'can_see_me', x.id = any (m.allowed_viewer_ids)) order by x.created_at)
        from public.family_members x where x.group_id = g.id),
      'active_headcount', private.family_headcount_json(g.id))
    from public.family_groups g where g.id = m.group_id);
end $$;

-- ---------- membership ----------

-- p: {"name", "display_name", "age_category", "phone_e164"?, "mobility_aid"?, "common_sickness"?}
create function public.create_family_group(p jsonb) returns json
language plpgsql security definer set search_path = ''
as $$
declare g uuid;
begin
  if (select auth.uid()) is null then raise exception 'Sign in first'; end if;
  if public.my_family_group_id() is not null then raise exception 'Leave your current family first'; end if;
  perform private.check_member_fields(p || jsonb_build_object(
    'display_name', coalesce(p->>'display_name', ''), 'age_category', coalesce(p->>'age_category', '')));
  insert into public.family_groups (name, invite_code, created_by)
  values (coalesce(nullif(trim(p->>'name'), ''), 'My Family'), private.new_invite_code(), (select auth.uid()))
  returning id into g;
  insert into public.family_members (group_id, user_id, phone_e164, display_name, age_category,
      mobility_aid, common_sickness, role)
  values (g, (select auth.uid()), nullif(p->>'phone_e164', ''), trim(p->>'display_name'), p->>'age_category',
      coalesce((p->>'mobility_aid')::boolean, false), private.sickness(p), 'admin');
  return public.my_family();
end $$;

-- Admin adds someone: with a phone (they can link it later by joining) or
-- without (a baby, a grandparent with no phone).
create function public.add_family_member(p jsonb) returns uuid
language plpgsql security definer set search_path = ''
as $$
declare me public.family_members := private.require_admin(); new_id uuid;
begin
  perform private.check_member_fields(p || jsonb_build_object(
    'display_name', coalesce(p->>'display_name', ''), 'age_category', coalesce(p->>'age_category', '')));
  if (select count(*) from public.family_members where group_id = me.group_id) >= 10 then
    raise exception 'A family can have up to 10 people';
  end if;
  if nullif(p->>'phone_e164', '') is not null and exists (
      select 1 from public.family_members where group_id = me.group_id and phone_e164 = p->>'phone_e164') then
    raise exception 'Someone with this phone number is already in the family';
  end if;
  insert into public.family_members (group_id, phone_e164, display_name, age_category, mobility_aid,
      common_sickness, is_outstation)
  values (me.group_id, nullif(p->>'phone_e164', ''), trim(p->>'display_name'), p->>'age_category',
      coalesce((p->>'mobility_aid')::boolean, false), private.sickness(p),
      coalesce((p->>'is_outstation')::boolean, false))
  returning id into new_id;
  return new_id;
end $$;

-- The admin changes anyone; others change only themselves. Only the keys
-- sent are changed. Phone: only for someone who has not linked the app.
create function public.update_family_member(p_member uuid, p jsonb) returns json
language plpgsql security definer set search_path = ''
as $$
declare me public.family_members := private.me_in_family(); t public.family_members;
begin
  select * into t from public.family_members where id = p_member and group_id = me.group_id;
  if t.id is null then raise exception 'No such family member'; end if;
  if me.role <> 'admin' and t.id <> me.id then raise exception 'You can only change your own details'; end if;
  perform private.check_member_fields(p);
  if p ? 'phone_e164' and t.user_id is not null and p->>'phone_e164' is distinct from t.phone_e164 then
    raise exception 'This person links their own phone';
  end if;
  update public.family_members set
    display_name = coalesce(trim(p->>'display_name'), display_name),
    age_category = coalesce(p->>'age_category', age_category),
    phone_e164 = case when p ? 'phone_e164' then nullif(p->>'phone_e164', '') else phone_e164 end,
    mobility_aid = coalesce((p->>'mobility_aid')::boolean, mobility_aid),
    common_sickness = case when p ? 'common_sickness' then private.sickness(p) else common_sickness end,
    is_outstation = coalesce((p->>'is_outstation')::boolean, is_outstation),
    -- Going outstation stops location sharing.
    consent_enabled = case when coalesce((p->>'is_outstation')::boolean, false) then false else consent_enabled end
  where id = t.id;
  if coalesce((p->>'is_outstation')::boolean, false) then
    delete from public.family_locations where member_id = t.id;
  end if;
  return public.my_family();
exception when unique_violation then
  raise exception 'Someone with this phone number is already in the family';
end $$;

-- p: {"code", "display_name", "age_category", "phone_e164"?}
-- With a phone number the admin already added, joining links that person
-- (no second row). Otherwise a new person is added (up to 10).
create function public.join_family_group(p jsonb) returns json
language plpgsql security definer set search_path = ''
as $$
declare g public.family_groups; t public.family_members; phone text := nullif(p->>'phone_e164', '');
begin
  if (select auth.uid()) is null then raise exception 'Sign in first'; end if;
  select * into g from public.family_groups where invite_code = coalesce(p->>'code', '');
  if g.id is null then raise exception 'This invite is not valid any more. Ask for a new one'; end if;
  if public.my_family_group_id() = g.id then return public.my_family(); end if;
  if public.my_family_group_id() is not null then raise exception 'Leave your current family first'; end if;
  perform private.check_member_fields(p);
  if phone is not null then
    select * into t from public.family_members where group_id = g.id and phone_e164 = phone;
  end if;
  if t.id is not null then
    if t.user_id is not null then raise exception 'This phone number is already linked'; end if;
    update public.family_members set user_id = (select auth.uid()) where id = t.id;
  else
    perform private.check_member_fields(jsonb_build_object(
      'display_name', coalesce(p->>'display_name', ''), 'age_category', coalesce(p->>'age_category', '')));
    if (select count(*) from public.family_members where group_id = g.id) >= 10 then
      raise exception 'A family can have up to 10 people';
    end if;
    insert into public.family_members (group_id, user_id, phone_e164, display_name, age_category)
    values (g.id, (select auth.uid()), phone, trim(p->>'display_name'), p->>'age_category');
  end if;
  return public.my_family();
end $$;

create function public.remove_family_member(p_member uuid) returns json
language plpgsql security definer set search_path = ''
as $$
declare me public.family_members := private.require_admin();
begin
  if p_member = me.id then raise exception 'To leave the family, use Leave'; end if;
  delete from public.family_members where id = p_member and group_id = me.group_id;
  if not found then raise exception 'No such family member'; end if;
  perform private.forget_viewer(me.group_id, p_member);
  return public.my_family();
end $$;

-- Leaving removes the caller's row (and their location). If they were the
-- only admin, the longest-standing linked member becomes admin; if nobody
-- with the app is left, the family is deleted.
create function public.leave_family_group() returns void
language plpgsql security definer set search_path = ''
as $$
declare me public.family_members := private.me_in_family(); heir uuid;
begin
  delete from public.family_members where id = me.id;
  perform private.forget_viewer(me.group_id, me.id);
  if me.role = 'admin' and not exists (
      select 1 from public.family_members where group_id = me.group_id and role = 'admin') then
    select id into heir from public.family_members
    where group_id = me.group_id and user_id is not null order by created_at limit 1;
    if heir is null then
      delete from public.family_groups where id = me.group_id;
    else
      update public.family_members set role = 'admin' where id = heir;
    end if;
  end if;
end $$;

-- New invite: the old code stops working and key_version goes up, so the
-- admin's phone makes a new family key. Stored locations under the old key
-- are deleted; a removed member keeps nothing they can still decrypt.
create function public.regenerate_family_invite() returns json
language plpgsql security definer set search_path = ''
as $$
declare me public.family_members := private.require_admin(); g public.family_groups;
begin
  update public.family_groups set invite_code = private.new_invite_code(), key_version = key_version + 1
  where id = me.group_id returning * into g;
  delete from public.family_locations where group_id = g.id;
  update public.family_members set consent_enabled = false where group_id = g.id;
  return json_build_object('invite_code', g.invite_code, 'key_version', g.key_version);
end $$;

-- ---------- live location (ciphertext only) ----------

-- p: {"enabled": bool, "hours": 1-24, "viewer_ids": [family_members.id, ...]}
create function public.set_location_sharing(p jsonb) returns json
language plpgsql security definer set search_path = ''
as $$
declare me public.family_members := private.me_in_family(); viewers uuid[]; hrs int;
begin
  if coalesce((p->>'enabled')::boolean, false) then
    if me.is_outstation then raise exception 'You are marked outstation: location is paused'; end if;
    hrs := coalesce((p->>'hours')::int, 24);
    if hrs not between 1 and 24 then raise exception 'Share for 1 to 24 hours'; end if;
    viewers := coalesce(array(select distinct public.try_uuid(v) from jsonb_array_elements_text(p->'viewer_ids') v), '{}');
    if cardinality(viewers) = 0 then raise exception 'Choose who can see your location'; end if;
    if me.id = any (viewers) or exists (
        select 1 from unnest(viewers) v
        where v is null or not exists (select 1 from public.family_members x
                                       where x.id = v and x.group_id = me.group_id and x.user_id is not null)) then
      raise exception 'Viewers must be other family members with the app';
    end if;
    update public.family_members set consent_enabled = true, allowed_viewer_ids = viewers,
      sharing_expires_at = now() + make_interval(hours => hrs)
    where id = me.id;
  else
    update public.family_members set consent_enabled = false, sharing_expires_at = null where id = me.id;
    delete from public.family_locations where member_id = me.id;
  end if;
  return public.my_family();
end $$;

-- p: {"ciphertext", "iv", "key_version"} (base64, from FamilyLocationCrypto).
create function public.put_family_location(p jsonb) returns void
language plpgsql security definer set search_path = ''
as $$
declare me public.family_members := private.me_in_family();
begin
  if not me.consent_enabled or me.sharing_expires_at is null or me.sharing_expires_at <= now() then
    raise exception 'Location sharing is off';
  end if;
  if me.is_outstation then raise exception 'You are marked outstation: location is paused'; end if;
  if (p->>'key_version')::int is distinct from (select key_version from public.family_groups where id = me.group_id) then
    raise exception 'The family key has changed: open the new invite';
  end if;
  insert into public.family_locations (member_id, group_id, ciphertext, iv, key_version, updated_at, expires_at)
  values (me.id, me.group_id, p->>'ciphertext', p->>'iv', (p->>'key_version')::int, now(),
          least(now() + interval '10 minutes', me.sharing_expires_at))
  on conflict (member_id) do update set ciphertext = excluded.ciphertext, iv = excluded.iv,
    key_version = excluded.key_version, updated_at = excluded.updated_at, expires_at = excluded.expires_at;
end $$;

-- ---------- shelter check-in for the family ----------

-- Which centre a family registration goes to. Here: the centre chosen if it
-- exists, else the nearest open one with space. shelter.sql replaces this
-- with the capacity- and access-aware allocation.
create function public.assign_family_centre(p_household uuid, p_preferred uuid,
    p_lat double precision, p_lon double precision) returns uuid
language plpgsql security definer set search_path = ''
as $$
declare c uuid;
begin
  if p_preferred is not null and exists (select 1 from public.evacuation_points where id = p_preferred) then
    c := p_preferred;
  elsif p_lat is not null and p_lon is not null then
    c := public.nearest_open_centre(p_lat, p_lon);
  end if;
  update public.headcounts set evacuation_point_id = c, allocation_note = null where household_id = p_household;
  return c;
end $$;

-- p: {"member_ids": [...], "extra_people": 0, "pets": 0, "needs": [...],
--     "centre_id"?, "lat"?, "lon"?, "force_update": false}
-- Any linked member (child, adult or elderly) may register. If another
-- member already has an active registration, nothing is written and
-- {"status": "already_registered", "existing": ...} comes back, unless
-- force_update is true (the "Edit existing" button), which updates it.
create function public.submit_family_headcount(p jsonb) returns json
language plpgsql security definer set search_path = ''
as $$
declare
  me public.family_members := private.me_in_family();
  sel uuid[] := coalesce(array(select distinct public.try_uuid(v) from jsonb_array_elements_text(p->'member_ids') v), '{}');
  extra int := coalesce((p->>'extra_people')::int, 0);
  existing public.headcounts;
  away text;
  c record;
  sick jsonb;
  needs text[];
  row_owner uuid;
begin
  if extra not between 0 and 20 then raise exception 'Extra people must be 0 to 20'; end if;
  -- Registrations nobody closed stop counting after 72 hours; free the lock.
  update public.headcounts set status = 'left'
  where family_group_id = me.group_id and status in ('on_the_way', 'arrived') and expires_at <= now();

  select * into existing from public.headcounts
  where family_group_id = me.group_id and status in ('on_the_way', 'arrived') for update;
  if existing.household_id is not null and existing.registered_by_user_id is distinct from (select auth.uid())
     and not coalesce((p->>'force_update')::boolean, false) then
    return json_build_object('status', 'already_registered', 'existing', private.family_headcount_json(me.group_id));
  end if;

  if exists (select 1 from unnest(sel) s where s is null or not exists (
      select 1 from public.family_members m where m.id = s and m.group_id = me.group_id)) then
    raise exception 'Choose people from your own family';
  end if;
  select string_agg(display_name, ', ') into away from public.family_members
  where id = any (sel) and is_outstation;
  if away is not null then raise exception '% is marked outstation. Untick them or change that first', away; end if;
  if cardinality(sel) + extra < 1 then raise exception 'Choose who is coming'; end if;

  select count(*) filter (where age_category = 'baby') as babies,
         count(*) filter (where age_category = 'child') as children,
         count(*) filter (where age_category = 'adult') as adults,
         count(*) filter (where age_category = 'elderly') as elderly,
         count(*) filter (where mobility_aid) as mobility
  into c from public.family_members where id = any (sel);
  select coalesce(jsonb_object_agg(s, n), '{}'::jsonb) into sick from (
    select s, count(*) as n from public.family_members m, unnest(m.common_sickness) s
    where m.id = any (sel) group by s) t;
  needs := array(select distinct x from unnest(
    coalesce(array(select jsonb_array_elements_text(p->'needs')), '{}')
    || case when c.mobility > 0 then array['wheelchair'] else '{}'::text[] end
    || case when coalesce((p->>'pets')::int, 0) > 0 then array['pet'] else '{}'::text[] end) x order by 1);

  -- The row belongs to whoever first registered; the editor is recorded.
  row_owner := coalesce(existing.household_id, (select auth.uid()));
  begin
    insert into public.headcounts (household_id, total, babies, children, adults, elderly, reduced_mobility,
        pets, needs, status, family_group_id, registered_by_user_id, selected_member_ids, common_sickness_summary)
    values (row_owner, cardinality(sel) + extra, c.babies, c.children, c.adults, c.elderly, c.mobility,
        coalesce((p->>'pets')::int, 0), needs, coalesce(existing.status, 'on_the_way'), me.group_id,
        (select auth.uid()), sel, sick)
    on conflict (household_id) do update set
      total = excluded.total, babies = excluded.babies, children = excluded.children,
      adults = excluded.adults, elderly = excluded.elderly, reduced_mobility = excluded.reduced_mobility,
      pets = excluded.pets, needs = excluded.needs, status = excluded.status,
      family_group_id = excluded.family_group_id, registered_by_user_id = excluded.registered_by_user_id,
      selected_member_ids = excluded.selected_member_ids, common_sickness_summary = excluded.common_sickness_summary,
      daily_medicine = false, power_machine = false;
  exception when unique_violation then
    -- Another member registered at the same moment: theirs stands.
    return json_build_object('status', 'already_registered', 'existing', private.family_headcount_json(me.group_id));
  end;

  perform public.assign_family_centre(row_owner, public.try_uuid(p->>'centre_id'),
    (p->>'lat')::double precision, (p->>'lon')::double precision);

  -- People in this registration who had also sent their own headcount are
  -- now counted here, not twice.
  update public.headcounts h set status = 'left'
  from public.family_members m
  where m.id = any (sel) and m.user_id = h.household_id and h.household_id <> row_owner
    and h.status in ('on_the_way', 'arrived');

  return json_build_object('status', 'registered', 'headcount', private.family_headcount_json(me.group_id));
end $$;

create function public.my_family_headcount() returns json
language sql stable security definer set search_path = ''
as $$ select private.family_headcount_json(public.my_family_group_id()) $$;

-- "Mark arrived" / "We left" by any linked member.
create function public.set_family_headcount_status(p_status text) returns json
language plpgsql security definer set search_path = ''
as $$
declare me public.family_members := private.me_in_family();
begin
  if p_status not in ('on_the_way', 'arrived', 'left') then raise exception 'Unknown status'; end if;
  update public.headcounts set status = p_status
  where family_group_id = me.group_id and status in ('on_the_way', 'arrived') and expires_at > now();
  if not found then raise exception 'Your family has no active registration'; end if;
  return private.family_headcount_json(me.group_id);
end $$;

-- ---------- row level security: read your own family, write nothing ----------

alter table public.family_groups enable row level security;
alter table public.family_members enable row level security;
alter table public.family_locations enable row level security;

create policy fg_read on public.family_groups for select to authenticated
  using (id = (select public.my_family_group_id()));
create policy fm_read on public.family_members for select to authenticated
  using (group_id = (select public.my_family_group_id()));
-- A pin is readable only by the members its owner chose, while sharing is on
-- and the pin is recent. (It is ciphertext anyway; this limits who even gets it.)
create policy fl_read on public.family_locations for select to authenticated
  using (expires_at > now() and exists (
    select 1 from public.family_members o
    where o.id = member_id and o.group_id = (select public.my_family_group_id())
      and o.consent_enabled and o.sharing_expires_at > now() and not o.is_outstation
      and (select public.my_family_member_id()) = any (o.allowed_viewer_ids)));

-- No invite_code here: members see it only through my_family() (admin only).
grant select (id, name, key_version, created_by, created_at) on public.family_groups to authenticated;
grant select on public.family_members, public.family_locations to authenticated;

do $$
declare f text;
begin
  foreach f in array array['my_family_group_id()', 'my_family_member_id()', 'my_family()',
      'create_family_group(jsonb)', 'add_family_member(jsonb)', 'update_family_member(uuid, jsonb)',
      'join_family_group(jsonb)', 'remove_family_member(uuid)', 'leave_family_group()',
      'regenerate_family_invite()', 'set_location_sharing(jsonb)', 'put_family_location(jsonb)',
      'submit_family_headcount(jsonb)', 'my_family_headcount()', 'set_family_headcount_status(text)'] loop
    execute format('revoke execute on function public.%s from public', f);
    execute format('grant execute on function public.%s to authenticated', f);
  end loop;
end $$;
-- Internal only: called by submit_family_headcount.
revoke execute on function public.assign_family_centre(uuid, uuid, double precision, double precision) from public;
revoke execute on all functions in schema private from public;
