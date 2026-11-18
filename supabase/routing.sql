-- =====================================================================
-- Road routes through our own Edge Function (supabase/functions/route), so
-- the openrouteservice key never goes into the app.
-- How to use: Supabase dashboard -> SQL Editor -> paste this whole file -> Run.
-- Run it once, after schema.sql.
--
-- Limits stop one phone (or a copied app) from using up the free
-- openrouteservice quota (2,000 routes a day, 40 a minute):
--   each phone: 6 a minute, 60 a day
--   everyone together: 35 a minute, 1,800 a day
-- =====================================================================

create table public.route_requests (
  user_id uuid not null,
  at timestamptz not null default now()
);
create index route_requests_user_idx on public.route_requests (user_id, at);
create index route_requests_at_idx on public.route_requests (at);
alter table public.route_requests enable row level security;
-- No policies: only route_allow() below reads and writes it.

-- Called by the route function with the phone's own login, so auth.uid() is
-- the phone. Returns true and counts the request, or false when over a limit.
create function public.route_allow() returns boolean
language plpgsql security definer set search_path = ''
as $$
declare
  me uuid := auth.uid();
  now_ts timestamptz := now();
begin
  if me is null then raise exception 'Not signed in'; end if;
  perform pg_advisory_xact_lock(hashtext('route_allow'));
  delete from public.route_requests where at < now_ts - interval '1 day';
  if (select count(*) from public.route_requests where user_id = me and at > now_ts - interval '1 minute') >= 6
     or (select count(*) from public.route_requests where user_id = me) >= 60
     or (select count(*) from public.route_requests where at > now_ts - interval '1 minute') >= 35
     or (select count(*) from public.route_requests) >= 1800 then
    return false;
  end if;
  insert into public.route_requests (user_id, at) values (me, now_ts);
  return true;
end $$;
revoke execute on function public.route_allow() from public, anon;
grant execute on function public.route_allow() to authenticated;
