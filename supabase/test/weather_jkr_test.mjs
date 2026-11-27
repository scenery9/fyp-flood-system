// Tests supabase/weather.sql (rain forecast), supabase/jkr.sql (JKR disaster incidents)
// and supabase/flood_events.sql (one row per flood spot)
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
for (const f of ['schema.sql', 'readings.sql', 'weather.sql', 'jkr.sql', 'flood_events.sql']) {
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

// WJ4 flood spots: every report counts, except a re-post of the same spot
// (same road, within 3 hours, under 300 m). 10637 is already stored above.
r = await as('service_role', `insert into public.jkr_incident
  (incident_id, type, type_ms, occurred_at, lat, lon, district, route_name, depth_m, last_seen_at) values
  (10636, 'Flood', 'Banjir', '2026-11-25T01:00:00Z', 2.815525, 101.661452, 'Kuala Langat', 'JALAN TM 3', 0.1, '2026-11-27T07:27:00Z'),
  (10638, 'Flood', 'Banjir', '2026-11-25T01:00:00Z', 2.814630, 101.658478, 'Kuala Langat', 'JALAN 3 RTB', 0.1, '2026-11-27T07:27:00Z'),
  (10700, 'Flood', 'Banjir', '2026-11-25T02:30:00Z', 2.815600, 101.661500, 'Kuala Langat', 'Jalan TM 3 ', 0.4, '2026-11-27T07:27:00Z'),
  (10701, 'Flood', 'Banjir', '2026-11-26T09:00:00Z', 2.815525, 101.661452, 'Kuala Langat', 'JALAN TM 3', 0.2, '2026-11-27T07:27:00Z'),
  (10702, 'Landslide', 'Tanah Runtuh', '2026-11-25T01:00:00Z', 2.8, 101.6, 'Kuala Langat', 'JALAN X', 4, '2026-11-27T07:27:00Z')`);
check('the logger can store more incidents', !r.error, r);
await as('service_role', `update public.jkr_incident set route_name = 'JALAN 2 RTB' where incident_id = 10637`);
await as('service_role', `insert into public.jkr_incident_seen values (10700, '2026-11-27T08:27:00Z', 'Water Rising', 'Closed', 0.5)`);
r = await as('anon', `select spot_id::int, reports::int, incident_ids::int[] as ids, max_depth_m, river_station,
  river_reached_warning from public.jkr_flood_spot order by spot_id`);
const spots = Object.fromEntries((r.rows ?? []).map((x) => [x.spot_id, x]));
check('anyone can read the flood spots', !r.error && r.rows.length > 0, r);
check('three nearby reports on different roads stay three spots',
  !!spots[10636] && !!spots[10637] && !!spots[10638], r.rows);
check('a re-post (same road, 1.5 h later, 10 m away) joins its spot',
  spots[10636]?.reports === 2 && JSON.stringify(spots[10636]?.ids) === '[10636,10700]' && !spots[10700], spots[10636]);
check('the spot keeps the deepest depth seen', spots[10636]?.max_depth_m === 0.5, spots[10636]);
check('the same road flooding again a day later is a new spot', !!spots[10701], r.rows);
check('a landslide is not a flood spot', !spots[10702], r.rows);
check('4 flood spots in all (10636 + its re-post, 10637, 10638, 10701)', r.rows?.length === 4, r.rows);
check('a spot has its nearest river station; Warning not stored, so not counted as reached',
  spots[10637]?.river_station === 'BKLT0001L' && spots[10637]?.river_reached_warning === false, spots[10637]);
r = await as('anon', `select round(public.distance_km(2.815525, 101.661452, 2.814308, 101.65328)::numeric, 2) as d`);
check('distance_km is the great-circle distance (0.92 km)', Number(r.rows?.[0]?.d) === 0.92, r);

console.log(`\n${pass} passed, ${fail} failed`);
if (fail) process.exit(1);
