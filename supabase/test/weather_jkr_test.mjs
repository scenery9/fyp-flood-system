// Tests supabase/weather.sql (rain forecast) and supabase/jkr.sql (JKR disaster incidents)
// on a local Postgres (PGlite), after readings.sql: everyone may read, only the logger
// (service_role) may write, and no column exists for the JKR officer's personal details.
// Run:  npm install && npm test
import { PGlite } from '@electric-sql/pglite';
import { readFileSync } from 'node:fs';

const db = new PGlite();
await db.exec(`
  create role anon nologin; create role authenticated nologin; create role service_role nologin bypassrls;
  create schema auth;
  create table auth.users (id uuid primary key);
  create function auth.uid() returns uuid language sql stable as
    $$ select nullif(current_setting('request.jwt.claim.sub', true), '')::uuid $$;
  grant usage on schema auth to anon, authenticated;
  grant usage on schema public to service_role;
`);
for (const f of ['schema.sql', 'readings.sql', 'weather.sql', 'jkr.sql']) {
  await db.exec(readFileSync(new URL(`../${f}`, import.meta.url), 'utf8'));
}

async function as(role, sql) {
  await db.exec(`set role ${role};`);
  try {
    const r = await db.query(sql);
    return { rows: r.rows };
  } catch (e) {
    return { error: e.message };
  } finally {
    await db.exec('reset role;');
  }
}

let pass = 0, fail = 0;
function check(name, ok, detail = '') {
  ok ? pass++ : fail++;
  console.log(`${ok ? 'PASS' : 'FAIL'}  ${name}${ok ? '' : `  ${JSON.stringify(detail)}`}`);
}

// WJ1 the weather logger writes; everyone reads; the public cannot write
let r = await as('service_role', `insert into public.weather_forecast values
  ('BKLG0002L', '2026-11-27T07:00:00Z', '2026-11-27T08:00:00Z', 4.2, 75, 8, 60),
  ('JKR-10637', '2026-11-27T07:00:00Z', '2026-11-27T08:00:00Z', 6.0, 88, 8, 70)`);
check('the logger can store forecasts for stations and JKR incident places', !r.error, r);
r = await as('anon', `select count(*)::int as n from public.weather_forecast`);
check('anyone can read the forecast', r.rows?.[0]?.n === 2, r);
r = await as('anon', `insert into public.weather_forecast values ('X', now(), now(), 1, 1, 1, 1)`);
check('the public cannot add forecasts', !!r.error, r);
r = await as('service_role', `insert into public.weather_forecast values ('Y', now(), now(), 5, 140, 8, 1)`);
check('a chance above 100% is refused', !!r.error, r);

// WJ2 JKR incidents: logger writes, sightings and nearby gauges, everyone reads
r = await as('service_role', `insert into public.jkr_incident
  (incident_id, type, type_ms, occurred_at, lat, lon, state, district, situation, depth_m, is_verified, last_seen_at)
  values (10637, 'Flood', 'Banjir', '2026-11-25T01:00:00Z', 2.814308, 101.65328, 'Selangor', 'Kuala Langat',
          'Water Rising', 0.1, 1, '2026-11-27T07:27:00Z')`);
check('the logger can store an incident', !r.error, r);
r = await as('service_role', `insert into public.jkr_incident_seen values (10637, '2026-11-27T07:27:00Z', 'Water Rising', 'Open', 0.1)`);
check('the logger can store an hourly sighting', !r.error, r);
r = await as('service_role', `insert into public.jkr_incident_gauges (incident_id, seen_at, kind, rank, station_code, distance_km, level_m, alert_m)
  values (10637, '2026-11-27T07:27:00Z', 'river', 1, 'BKLT0001L', 1.27, 3.92, 3.3)`);
check('the logger can store the nearest gauge', !r.error, r);
r = await as('service_role', `insert into public.jkr_incident_gauges (incident_id, seen_at, kind, rank, station_code)
  values (10637, '2026-11-27T07:27:00Z', 'tide', 1, 'X')`);
check('only river and rain gauges are accepted', !!r.error, r);
r = await as('service_role', `insert into public.jkr_incident_seen values (99999, now(), null, null, null)`);
check('a sighting of an unknown incident is refused', !!r.error, r);
r = await as('anon', `select i.district, g.station_code from public.jkr_incident i
  join public.jkr_incident_gauges g using (incident_id)`);
check('anyone can read incidents with their nearby gauges',
  r.rows?.[0]?.district === 'Kuala Langat' && r.rows?.[0]?.station_code === 'BKLT0001L', r);
for (const t of ['jkr_incident', 'jkr_incident_seen', 'jkr_incident_gauges']) {
  r = await as('authenticated', `delete from public.${t}`);
  check(`the public cannot delete from ${t}`, !!r.error, r);
}

// WJ3 privacy: no column for the reporting officer's details
r = await db.query(`select column_name from information_schema.columns
  where table_schema = 'public' and table_name like 'jkr_%'
    and column_name in ('report_by', 'phone_no', 'phone_no_office', 'user_id', 'action_by_id', 'verification_note')`);
check('no JKR table has a column for personal details', r.rows.length === 0, r.rows);

console.log(`\n${pass} passed, ${fail} failed`);
if (fail) process.exit(1);
