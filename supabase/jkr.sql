-- =====================================================================
-- Disaster incidents on public roads from JKR's public portal
-- (bencana.jkr.gov.my, Sistem eBencana JKR): floods, landslides, road collapses,
-- read every hour by logger/jps_logger/jkr.py (GitHub Actions, log_jkr.yml).
-- How to use: Supabase dashboard -> SQL Editor -> paste this whole file -> Run.
-- Run it once, after readings.sql.
--
-- Why: a JKR flood report is an OBSERVED flood at a known place and time. Each
-- sighting is stored with the nearest JPS river stations and rain gauges and what
-- they read at that moment, so floods can be matched to the readings before them.
--
-- Privacy: the portal's records also hold the reporting officer's name, phone
-- numbers and user ids. The logger never reads them, and there are no columns for them.
--
-- Same rules as readings.sql: everyone may READ (public information); only the
-- logger (service_role) writes. Small: about 10 incidents x 24 sightings a day.
-- Finished days are also saved to data/incidents/ by the daily archive job.
-- =====================================================================

-- One row per incident: its details as last seen on the portal.
create table public.jkr_incident (
  incident_id      bigint primary key,
  type             text,                   -- Flood, Landslide, ... (portal label, English)
  type_ms          text,                   -- Banjir, Tanah Runtuh, ...
  occurred_at      timestamptz,            -- reported date and time (Malaysia time on the portal)
  lat              double precision check (lat between -90 and 90),
  lon              double precision check (lon between -180 and 180),
  state            text,
  district         text,
  location_name    text,
  route_name       text,
  route_type       text,
  depth_m          double precision,       -- flood depth for a flood; for other types JKR uses it for size
  length_m         double precision,
  status           text,                   -- In Progress, Completed, ...
  situation        text,                   -- Water Rising, Water Receding, ...
  road_status      text,
  road_status_code text,
  is_verified      smallint check (is_verified in (0, 1)),
  remarks          text,
  updated_at       timestamptz,            -- portal's last update
  url              text,
  last_seen_at     timestamptz not null    -- last hour the portal still listed it
);

-- Every hourly sighting: how the situation changed over time.
create table public.jkr_incident_seen (
  incident_id bigint not null references public.jkr_incident (incident_id) on delete cascade,
  seen_at     timestamptz not null,
  situation   text,
  road_status text,
  depth_m     double precision,
  primary key (incident_id, seen_at)
);

-- The nearest JPS river stations and rain gauges (up to 3 of each within 15 km)
-- and their latest reading at each sighting.
create table public.jkr_incident_gauges (
  incident_id  bigint not null references public.jkr_incident (incident_id) on delete cascade,
  seen_at      timestamptz not null,
  kind         text not null check (kind in ('river', 'rain')),
  rank         smallint not null check (rank between 1 and 10),   -- 1 = nearest
  station_code text not null,
  station_name text,
  distance_km  double precision,
  observed_at  timestamptz,
  level_m      double precision,
  alert_m      double precision,
  warning_m    double precision,
  danger_m     double precision,
  hourly_mm    double precision,
  today_mm     double precision,
  primary key (incident_id, seen_at, kind, rank)
);

create index jkr_incident_last_seen on public.jkr_incident (last_seen_at);
create index jkr_incident_seen_at on public.jkr_incident_seen (seen_at);
create index jkr_incident_gauges_seen_at on public.jkr_incident_gauges (seen_at);

alter table public.jkr_incident enable row level security;
alter table public.jkr_incident_seen enable row level security;
alter table public.jkr_incident_gauges enable row level security;

create policy jkr_incident_read on public.jkr_incident for select to anon, authenticated using (true);
create policy jkr_incident_seen_read on public.jkr_incident_seen for select to anon, authenticated using (true);
create policy jkr_incident_gauges_read on public.jkr_incident_gauges for select to anon, authenticated using (true);

grant select on public.jkr_incident, public.jkr_incident_seen, public.jkr_incident_gauges
  to anon, authenticated;
revoke insert, update, delete, truncate
  on public.jkr_incident, public.jkr_incident_seen, public.jkr_incident_gauges
  from anon, authenticated;
grant select, insert, update, delete
  on public.jkr_incident, public.jkr_incident_seen, public.jkr_incident_gauges
  to service_role;
