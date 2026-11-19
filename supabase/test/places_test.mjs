// Tests supabase/places.sql (centres and resource points from places/*.csv, Melaka)
// on a local Postgres (PGlite), after every other file in the documented order.
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
for (const f of ['schema.sql', 'readings.sql', 'staff_districts.sql', 'alerts.sql', 'routing.sql',
  'public_reports.sql', 'household_groups.sql', 'places.sql', 'sources.sql']) {
  await db.exec(readFileSync(new URL(`../${f}`, import.meta.url), 'utf8'));
}

const U = (n) => `00000000-0000-0000-0000-${String(n).padStart(12, '0')}`;
const [ADMIN, COORD, ALICE] = [1, 2, 4].map(U);
const RP = U(100), CHECKED = U(200), UNCHECKED = U(201), STAFF_ADDED = U(202);

await db.exec(`
  insert into auth.users select ('00000000-0000-0000-0000-' || lpad(g::text, 12, '0'))::uuid from generate_series(1, 4) g;
  insert into public.staff_profiles (id, full_name, username, role, assigned_district, active) values
    ('${ADMIN}', 'Admin', 'admin', 'super_admin', null, true),
    ('${COORD}', 'Coord', 'coord', 'coordinator', 'KLANG', true);
`);

async function as(role, uid, sql) {
  await db.exec(`set role ${role}; set request.jwt.claim.sub = '${uid ?? ''}';`);
  try {
    const r = await db.query(sql);
    return { rows: r.rows, count: r.affectedRows ?? r.rows.length };
  } catch (e) {
    return { error: e.message };
  } finally {
    await db.exec('reset role; reset request.jwt.claim.sub;');
  }
}

let pass = 0, fail = 0;
function check(name, ok, detail = '') {
  ok ? pass++ : fail++;
  console.log(`${ok ? 'PASS' : 'FAIL'}  ${name}${ok ? '' : `  ${JSON.stringify(detail)}`}`);
}

// PL1 the loader (service_role) keeps rows with a code in step with the files
let r = await as('service_role', null, `insert into public.resource_points (id, code, name, lat, lon, district)
  values ('${RP}', 'DEMO-MLK-DEPOT', 'DEMO Melaka Depot', 2.211, 102.26, 'MELAKA TENGAH')`);
check('a resource point in a Melaka district can be added', !r.error, r);
r = await as('service_role', null, `insert into public.evacuation_points
  (id, code, name, lat, lon, capacity, capacity_estimated, district, resource_point_id) values
  ('${CHECKED}', 'PPS-MLK-AYER-KEROH', 'Ayer Keroh', 2.265102, 102.280205, 200, true, 'MELAKA TENGAH', '${RP}')`);
check('a centre with a code can be added', !r.error, r);
r = await as('service_role', null, `insert into public.evacuation_points
  (id, code, name, lat, lon, capacity, district) values ('${UNCHECKED}', 'bad code', 'X', 2.5, 102.3, 10, 'JASIN')`);
check('a code with spaces or small letters is refused', !!r.error, r);
r = await as('service_role', null, `insert into public.evacuation_points
  (code, name, lat, lon, capacity, district) values ('PPS-X', 'Y', 2.5, 102.3, 10, 'SEGAMAT')`);
check('a district that is not in the list is refused', !!r.error, r);
r = await as('service_role', null, `insert into public.evacuation_points
  (id, code, name, lat, lon, capacity, district, location_checked) values
  ('${UNCHECKED}', 'PPS-SGR-TEST', 'Unchecked Hall', 3.04, 101.45, 100, 'KLANG', false)`);
check('an unchecked centre can be added', !r.error, r);
r = await as('service_role', null, `insert into public.evacuation_points (code, name, lat, lon, capacity, district)
  values ('PPS-SGR-TEST', 'Renamed', 3.04, 101.45, 120, 'KLANG')
  on conflict (code) do update set name = excluded.name, capacity = excluded.capacity`);
r = await as('service_role', null, `select name, capacity, occupancy from public.evacuation_points where code = 'PPS-SGR-TEST'`);
check('the same code updates the row (as the loader does)', r.rows?.[0]?.name === 'Renamed' && r.rows[0].capacity === 120, r);

// PL2 everyone can read centres with the new columns
r = await as('anon', null, `select code, location_checked, capacity_estimated from public.evacuation_points order by code`);
check('the public reads the new columns', r.rows?.length === 2 && r.rows[0].capacity_estimated === true, r);

// PL3 staff cannot quietly change what the file says, but can still update occupancy
r = await as('authenticated', ADMIN, `update public.evacuation_points set name = 'Hacked' where id = '${CHECKED}'`);
check('even a Super Admin cannot rename a centre from the file', !!r.error && /centres.csv/.test(r.error), r);
r = await as('authenticated', ADMIN, `update public.evacuation_points set occupancy = 5 where id = '${CHECKED}'`);
check('staff can still record occupancy at a file centre', !r.error && r.count === 1, r);
r = await as('authenticated', ADMIN, `update public.resource_points set lat = 1 where id = '${RP}'`);
check('staff cannot move a resource point from the file', !!r.error, r);
r = await as('authenticated', COORD, `insert into public.evacuation_points (id, name, lat, lon, capacity, district)
  values ('${STAFF_ADDED}', 'Staff Hall', 3.0, 101.4, 50, 'KLANG')`);
check('a coordinator can still add a centre without a code', !r.error, r);
r = await as('authenticated', COORD, `update public.evacuation_points set name = 'Staff Hall 2' where id = '${STAFF_ADDED}'`);
check('and rename it (it is not from the file)', !r.error && r.count === 1, r);

// PL4 a centre still in use cannot be removed by the loader
r = await as('service_role', null, `delete from public.evacuation_points where code = 'PPS-MLK-AYER-KEROH'`);
check('a centre with people recorded is not deleted', !!r.error, r);
r = await as('service_role', null, `delete from public.evacuation_points where code is not null and code not in ('PPS-MLK-AYER-KEROH')`);
check('removed rows go; rows without a code stay', !r.error && r.count === 1, r);
r = await as('anon', null, `select count(*)::int as n from public.evacuation_points where code is null`);
check('the staff-added centre is still there', r.rows?.[0]?.n === 1, r);

// PL5 headcounts never go to an unchecked centre
await as('service_role', null, `insert into public.evacuation_points (code, name, lat, lon, capacity, district, location_checked)
  values ('PPS-SGR-NEAR', 'Near but unchecked', 3.0001, 101.4001, 100, 'KLANG', false)`);
r = await as('authenticated', ALICE, `select public.nearest_open_centre(3.0, 101.4) as id`);
check('the nearest checked centre is chosen, not the unchecked one', r.rows?.[0]?.id === STAFF_ADDED, r);

// PL6 Melaka stations and the state in jps_latest
r = await as('service_role', null, `insert into public.jps_stations (station_code, name, district, lat, lon, state)
  values ('0290211WL', 'Sg. Melaka di Melaka Pindah', 'ALOR GAJAH', 2.37349, 102.22111, 'Melaka')`);
check('the logger can add a Melaka station', !r.error, r);
r = await as('service_role', null, `insert into public.jps_stations (station_code, name, state) values ('Z', 'Z', 'Johor')`);
check('an unknown state is refused', !!r.error, r);
r = await as('anon', null, `select state from public.jps_latest where station_code = '0290211WL'`);
check('jps_latest shows the state', r.rows?.[0]?.state === 'Melaka', r);
r = await as('authenticated', ALICE, `select public.nearest_district(2.37, 102.22) as d`);
check('a report in Melaka gets a Melaka district', r.rows?.[0]?.d === 'ALOR GAJAH', r);
r = await as('anon', null, `select count(*)::int as n from public.districts where state = 'Melaka'`);
check('the three Melaka districts are listed', r.rows?.[0]?.n === 3, r);

// PL7 national station ids (sources.sql), for the second data source
r = await as('service_role', null, `insert into public.jps_stations (station_code, name, state, jps_wl_id, jps_rf_id)
  values ('BKLG0002L', 'TAMAN SRI MUDA', 'Selangor', '3015432', '3015084')
  on conflict (station_code) do update set jps_wl_id = excluded.jps_wl_id, jps_rf_id = excluded.jps_rf_id`);
check('the logger can store national station ids', !r.error, r);
r = await as('service_role', null, `select station_code from public.jps_stations where jps_wl_id = '3015432'`);
check('the logger can look a station up by national id', r.rows?.[0]?.station_code === 'BKLG0002L', r);
try {
  await db.exec(readFileSync(new URL('../sources.sql', import.meta.url), 'utf8'));
  check('sources.sql can be run twice', true);
} catch (e) {
  check('sources.sql can be run twice', false, e.message);
}

console.log(`\n${pass}/${pass + fail} passed`);
process.exit(fail ? 1 : 0);
