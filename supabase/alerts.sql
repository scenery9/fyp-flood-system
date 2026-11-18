-- =====================================================================
-- Push alerts: phones register, choose stations, and get a notification
-- when the river reaches their level, even with the app closed.
-- How to use: Supabase dashboard -> SQL Editor -> paste this whole file -> Run.
-- Run it once, AFTER schema.sql, readings.sql and staff_districts.sql.
-- Then follow supabase/alerts_schedule.sql to check every 15 minutes.
--
-- Who can do what:
--   a phone (signed in anonymously) = sees and changes only its own token and rules
--   anon                            = reads the latest readings (public JPS data)
--   service_role (Edge Function send-alerts) = runs the check and records what was sent
--
-- The alert rules are the same as packages/flood_core AlertRules:
--   first time true -> notify; river moves up a level -> notify again;
--   at Danger -> repeat every 45 min; gone for 60 min -> starts again;
--   height alerts have a 0.10 m buffer once they have fired;
--   readings older than 3 hours (or from the future) change nothing.
-- =====================================================================

-- ---------- latest reading per station (also used by the app) ----------

create view public.jps_latest with (security_invoker = on) as
select s.station_code, s.name, s.district, s.river_basin, s.lat, s.lon,
       s.wl_normal, s.wl_alert, s.wl_warning, s.wl_danger,
       r.level_m, r.observed_at as level_at,
       f.hourly_mm, f.observed_at as rain_at
from public.jps_stations s
left join lateral (select level_m, observed_at from public.jps_river_levels l
                   where l.station_code = s.station_code
                   order by observed_at desc limit 1) r on true
left join lateral (select hourly_mm, observed_at from public.jps_rainfall x
                   where x.station_code = s.station_code
                   order by observed_at desc limit 1) f on true;
grant select on public.jps_latest to anon, authenticated, service_role;

-- Risk level from the river level and the station's thresholds
-- (same as flood_core RiskCalculator). Null when thresholds are missing or
-- do not rise.
create function public.river_risk(lvl double precision, normal double precision,
    alert double precision, warning double precision, danger double precision)
returns text language sql immutable set search_path = ''
as $$
  select case
    when lvl is null or normal is null or alert is null or warning is null or danger is null
         or not (normal < alert and alert < warning and warning < danger) then null
    when lvl >= danger then 'danger'
    when lvl >= warning then 'warning'
    when lvl >= alert then 'alert'
    else 'normal' end
$$;

create function public.risk_rank(level text) returns int
language sql immutable set search_path = ''
as $$ select case level when 'alert' then 1 when 'warning' then 2 when 'danger' then 3 else 0 end $$;

-- ---------- tables ----------

-- One row per phone (anonymous user). fcm_token holds the phone's Firebase
-- Installation ID (FID), which replaced Firebase's old registration tokens.
create table public.device_tokens (
  user_id uuid primary key default auth.uid() references auth.users (id) on delete cascade,
  fcm_token text not null unique check (length(fcm_token) between 20 and 4096),
  platform text not null default 'android' check (platform in ('android', 'ios', 'web')),
  language text not null default 'en' check (language in ('en', 'ms', 'zh')),
  updated_at timestamptz not null default now()
);

create table public.alert_rules (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null default auth.uid() references auth.users (id) on delete cascade,
  station_code text not null references public.jps_stations (station_code) on delete cascade,
  kind text not null check (kind in ('risk', 'level')),
  min_level text check (min_level in ('alert', 'warning', 'danger')),
  level_m double precision check (level_m > -100 and level_m < 1000),
  enabled boolean not null default true,
  created_at timestamptz not null default now(),
  check ((kind = 'risk' and min_level is not null and level_m is null)
      or (kind = 'level' and level_m is not null and min_level is null)),
  unique (user_id, station_code, kind)
);
create index alert_rules_station_idx on public.alert_rules (station_code) where enabled;

-- What has been sent for each rule. Only the server reads and writes it.
create table public.alert_state (
  rule_id uuid primary key references public.alert_rules (id) on delete cascade,
  last_level text check (last_level in ('normal', 'alert', 'warning', 'danger')),
  last_notified_at timestamptz,
  below_since timestamptz
);

-- At most 20 rules per phone.
create function public.alert_rules_limit() returns trigger
language plpgsql security definer set search_path = ''
as $$
begin
  if (select count(*) from public.alert_rules where user_id = new.user_id) >= 20 then
    raise exception 'Maximum 20 alerts';
  end if;
  return new;
end $$;
create trigger alert_rules_limit before insert on public.alert_rules
  for each row execute function public.alert_rules_limit();

-- A changed rule starts fresh (same as flood_core AlertService).
create function public.alert_rules_changed() returns trigger
language plpgsql security definer set search_path = ''
as $$
begin
  new.user_id := old.user_id;
  if (new.station_code, new.kind, new.min_level, new.level_m, new.enabled)
     is distinct from (old.station_code, old.kind, old.min_level, old.level_m, old.enabled) then
    delete from public.alert_state where rule_id = old.id;
  end if;
  return new;
end $$;
create trigger alert_rules_changed before update on public.alert_rules
  for each row execute function public.alert_rules_changed();

alter table public.device_tokens enable row level security;
alter table public.alert_rules enable row level security;
alter table public.alert_state enable row level security;

create policy dt_own on public.device_tokens for all to authenticated
  using (user_id = (select auth.uid())) with check (user_id = (select auth.uid()));
create policy ar_own on public.alert_rules for all to authenticated
  using (user_id = (select auth.uid())) with check (user_id = (select auth.uid()));
-- alert_state: no policy, so the API cannot reach it (service_role bypasses).

grant select, insert, update, delete on public.device_tokens, public.alert_rules to authenticated;
grant select, insert, update, delete on public.device_tokens, public.alert_rules, public.alert_state
  to service_role;

-- ---------- what the app calls ----------

-- Saves this phone's Firebase token. A token belongs to one phone only:
-- if the app was reinstalled (new anonymous user), the old row is removed.
create function public.register_device(p_token text, p_platform text, p_language text)
returns void
language plpgsql security definer set search_path = ''
as $$
declare me uuid := auth.uid();
begin
  if me is null then raise exception 'Not signed in'; end if;
  delete from public.device_tokens where fcm_token = p_token and user_id <> me;
  insert into public.device_tokens (user_id, fcm_token, platform, language, updated_at)
  values (me, p_token, p_platform, p_language, now())
  on conflict (user_id) do update
    set fcm_token = excluded.fcm_token, platform = excluded.platform,
        language = excluded.language, updated_at = now();
end $$;

-- Replaces this phone's whole set of rules in one step.
-- p_rules: [{"station_code": "...", "kind": "risk", "min_level": "warning"},
--           {"station_code": "...", "kind": "level", "level_m": 4.2}]
-- Rules that did not change keep what was already sent (no repeat alert).
-- Stations the server does not know are skipped. Returns the number saved.
create function public.sync_alert_rules(p_rules jsonb) returns int
language plpgsql security definer set search_path = ''
as $$
declare
  me uuid := auth.uid();
  n int := 0;
  r jsonb;
begin
  if me is null then raise exception 'Not signed in'; end if;
  if jsonb_typeof(p_rules) <> 'array' then raise exception 'Rules must be a list'; end if;
  if jsonb_array_length(p_rules) > 20 then raise exception 'Maximum 20 alerts'; end if;
  delete from public.alert_rules a
  where a.user_id = me
    and not exists (select 1 from jsonb_array_elements(p_rules) x
                    where x->>'station_code' = a.station_code and x->>'kind' = a.kind);
  for r in select * from jsonb_array_elements(p_rules) loop
    if not exists (select 1 from public.jps_stations where station_code = r->>'station_code') then
      continue;
    end if;
    insert into public.alert_rules (user_id, station_code, kind, min_level, level_m, enabled)
    values (me, r->>'station_code', r->>'kind',
            case when r->>'kind' = 'risk' then r->>'min_level' end,
            case when r->>'kind' = 'level' then (r->>'level_m')::double precision end,
            coalesce((r->>'enabled')::boolean, true))
    on conflict (user_id, station_code, kind) do update
      set min_level = excluded.min_level, level_m = excluded.level_m, enabled = excluded.enabled;
    n := n + 1;
  end loop;
  return n;
end $$;

-- Removes this phone's token and rules (notifications turned off).
create function public.unregister_device() returns void
language sql security definer set search_path = ''
as $$
  delete from public.alert_rules where user_id = auth.uid();
  delete from public.device_tokens where user_id = auth.uid();
$$;

revoke execute on function public.register_device(text, text, text) from public, anon;
revoke execute on function public.sync_alert_rules(jsonb) from public, anon;
revoke execute on function public.unregister_device() from public, anon;
grant execute on function public.register_device(text, text, text) to authenticated;
grant execute on function public.sync_alert_rules(jsonb) to authenticated;
grant execute on function public.unregister_device() to authenticated;

-- ---------- what the server calls (Edge Function send-alerts) ----------

-- Works out which notifications are due now and updates the "gone since"
-- times. Does NOT mark anything as sent: call alerts_mark_sent for the ones
-- Firebase accepted, so a failed send is tried again next time.
create function public.alerts_tick(p_now timestamptz default now())
returns table (rule_id uuid, user_id uuid, fcm_token text, language text,
               station_code text, station_name text, kind text, level text,
               level_m double precision, alert_level_m double precision, reason text)
language plpgsql security definer set search_path = ''
as $$
declare
  x record;
  lvl text;
  is_on boolean;
  notified boolean;
  cur text;
begin
  for x in
    select a.id, a.user_id, a.kind, a.min_level, a.level_m as rule_m, a.station_code,
           t.fcm_token, t.language, l.name, l.level_m, l.level_at,
           l.wl_normal, l.wl_alert, l.wl_warning, l.wl_danger,
           st.last_level, st.last_notified_at, st.below_since
    from public.alert_rules a
    join public.device_tokens t on t.user_id = a.user_id
    join public.jps_latest l on l.station_code = a.station_code
    left join public.alert_state st on st.rule_id = a.id
    where a.enabled
  loop
    -- Old, missing or future readings: change nothing.
    if x.level_m is null or x.level_at < p_now - interval '3 hours'
       or x.level_at > p_now + interval '5 minutes' then
      continue;
    end if;
    lvl := public.river_risk(x.level_m, x.wl_normal, x.wl_alert, x.wl_warning, x.wl_danger);
    notified := x.last_notified_at is not null;
    if x.kind = 'risk' then
      if lvl is null then continue; end if;
      is_on := public.risk_rank(lvl) >= public.risk_rank(x.min_level);
    else
      is_on := x.level_m >= x.rule_m - (case when notified then 0.10 else 0 end) - 1e-9;
    end if;

    if not is_on then
      if notified then
        if x.below_since is null then
          update public.alert_state set below_since = p_now where alert_state.rule_id = x.id;
        elsif p_now - x.below_since >= interval '60 minutes' then
          delete from public.alert_state where alert_state.rule_id = x.id;
        end if;
      end if;
      continue;
    end if;

    if x.below_since is not null then
      update public.alert_state set below_since = null where alert_state.rule_id = x.id;
    end if;
    cur := coalesce(lvl, 'normal');
    reason := case
      when not notified then 'first'
      when public.risk_rank(cur) > public.risk_rank(coalesce(x.last_level, 'normal')) then 'escalated'
      when cur = 'danger' and p_now - x.last_notified_at >= interval '45 minutes' then 'danger_repeat'
    end;
    if reason is null then continue; end if;

    rule_id := x.id; user_id := x.user_id; fcm_token := x.fcm_token; language := x.language;
    station_code := x.station_code; station_name := x.name; kind := x.kind; level := cur;
    level_m := x.level_m; alert_level_m := x.rule_m;
    return next;
  end loop;
end $$;

-- Records that these rules were notified at [p_now], at these levels.
create function public.alerts_mark_sent(p_rule_ids uuid[], p_levels text[],
    p_now timestamptz default now())
returns void
language sql security definer set search_path = ''
as $$
  insert into public.alert_state (rule_id, last_level, last_notified_at, below_since)
  select r.id, r.lvl, p_now, null
  from unnest(p_rule_ids, p_levels) as r(id, lvl)
  where exists (select 1 from public.alert_rules a where a.id = r.id)
  on conflict (rule_id) do update
    set last_level = excluded.last_level, last_notified_at = excluded.last_notified_at,
        below_since = null
$$;

-- Removes tokens that Firebase says no longer exist (app uninstalled).
create function public.alerts_drop_tokens(p_tokens text[]) returns int
language sql security definer set search_path = ''
as $$
  with d as (delete from public.device_tokens where fcm_token = any(p_tokens) returning 1)
  select count(*)::int from d
$$;

revoke execute on function public.alerts_tick(timestamptz) from public, anon, authenticated;
revoke execute on function public.alerts_mark_sent(uuid[], text[], timestamptz) from public, anon, authenticated;
revoke execute on function public.alerts_drop_tokens(text[]) from public, anon, authenticated;
grant execute on function public.alerts_tick(timestamptz) to service_role;
grant execute on function public.alerts_mark_sent(uuid[], text[], timestamptz) to service_role;
grant execute on function public.alerts_drop_tokens(text[]) to service_role;
