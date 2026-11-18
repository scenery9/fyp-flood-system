// Tests supabase/schema.sql and staff_districts.sql on a local Postgres (PGlite), with a small
// stand-in for Supabase Auth. Run:  npm install && npm test
import { PGlite } from '@electric-sql/pglite';
import { readFileSync } from 'node:fs';

const db = new PGlite();
// Stand-in for what Supabase provides: roles, auth.users, auth.uid().
await db.exec(`
  create role anon nologin; create role authenticated nologin; create role service_role nologin bypassrls;
  create schema auth;
  create table auth.users (id uuid primary key);
  create function auth.uid() returns uuid language sql stable as
    $$ select nullif(current_setting('request.jwt.claim.sub', true), '')::uuid $$;
  grant usage on schema auth to anon, authenticated;
`);
await db.exec(readFileSync(new URL('../schema.sql', import.meta.url), 'utf8'));
await db.exec(readFileSync(new URL('../readings.sql', import.meta.url), 'utf8'));
await db.exec(readFileSync(new URL('../staff_districts.sql', import.meta.url), 'utf8'));
// Loaded too, to check every file applies cleanly in the documented order.
await db.exec(readFileSync(new URL('../alerts.sql', import.meta.url), 'utf8'));
await db.exec(readFileSync(new URL('../routing.sql', import.meta.url), 'utf8'));

const U = (n) => `00000000-0000-0000-0000-${String(n).padStart(12, '0')}`;
const [ADMIN, COORD, OFFICER, ALICE, BOB, EXSTAFF] = [1, 2, 3, 4, 5, 6].map(U);
const RP = U(100), EV = U(200), CU = U(300), ITEM = U(400);
const RP2 = U(101), EV2 = U(201), ITEM2 = U(401);

// Seed as the database owner (like the Supabase SQL Editor).
await db.exec(`
  insert into auth.users select ('00000000-0000-0000-0000-' || lpad(g::text, 12, '0'))::uuid from generate_series(1, 6) g;
  -- Test stations (made-up positions) so new damage reports get a district.
  insert into public.jps_stations (station_code, name, district, lat, lon) values
    ('TEST-K', 'Test Klang', 'KLANG', 2.5, 102.8), ('TEST-S', 'Test Sepang', 'SEPANG', 2.7, 101.7);
  insert into public.resource_points (id, name, lat, lon, district) values
    ('${RP}', 'Depot', 2.5, 102.8, 'KLANG'), ('${RP2}', 'Sepang Depot', 2.7, 101.7, 'SEPANG');
  insert into public.staff_profiles (id, full_name, username, role, assigned_resource_point_id, assigned_district, active) values
    ('${ADMIN}', 'Admin', 'admin', 'super_admin', null, null, true),
    ('${COORD}', 'Coord', 'coord', 'coordinator', null, 'KLANG', true),
    ('${OFFICER}', 'Officer', 'officer', 'field_officer', '${RP}', null, true),
    ('${EXSTAFF}', 'Left', 'left', 'coordinator', null, 'KLANG', false);
  insert into public.evacuation_points (id, name, lat, lon, capacity, district, resource_point_id) values
    ('${EV}', 'Hall', 2.5, 102.8, 50, 'KLANG', '${RP}'),
    ('${EV2}', 'Sepang Hall', 2.7, 101.7, 50, 'SEPANG', '${RP2}');
  insert into public.catalogue_units (id, name, unit, daily_need_per_person) values ('${CU}', 'Water', 'litre', 3);
  insert into public.inventory_items (id, resource_point_id, name, quantity) values
    ('${ITEM}', '${RP}', 'Water 1.5L', 10), ('${ITEM2}', '${RP2}', 'Rice', 4);
`);

// Run SQL as a given role + user. Returns { rows, count } or { error }.
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
const pub = (uid, sql) => as('authenticated', uid, sql);

let pass = 0, fail = 0;
function check(name, ok, detail = '') {
  ok ? pass++ : fail++;
  console.log(`  ${ok ? 'PASS' : 'FAIL'}  ${name}${ok ? '' : '  -> ' + JSON.stringify(detail)}`);
}
const denied = (r) => !!r.error || r.count === 0;
const report = (extra = '') =>
  `insert into public.damage_reports (lat, lon, incident_date, type, severity${extra ? ', ' + extra.split('=')[0] : ''})
   values (2.5, 102.8, current_date, 'road', 'severe'${extra ? ', ' + extra.split('=')[1] : ''}) returning id, status, reporter_id`;

console.log('SQL1 Not signed in (anon)');
let r = await as('anon', null, 'select name from public.evacuation_points');
check('can read evacuation points', r.rows?.length === 2, r);
for (const t of ['damage_reports', 'headcounts', 'staff_profiles', 'inventory_items', 'resource_points', 'catalogue_units']) {
  r = await as('anon', null, `select * from public.${t}`);
  check(`cannot read ${t}`, !!r.error, r);
}
r = await as('anon', null, `insert into public.evacuation_points (name, lat, lon, capacity) values ('X', 1, 1, 1)`);
check('cannot add an evacuation point', !!r.error, r);

console.log('SQL2 Public user: damage reports');
r = await pub(ALICE, report());
const aliceReport = r.rows?.[0]?.id;
check('can submit; starts pending under own id', r.rows?.[0]?.status === 'pending' && r.rows[0].reporter_id === ALICE, r);
r = await pub(ALICE, report(`status='verified'`));
check('cannot submit a report that is already verified', r.rows?.[0]?.status === 'pending', r);
r = await pub(ALICE, `insert into public.damage_reports (reporter_id, lat, lon, incident_date, type, severity) values ('${BOB}', 2, 102, current_date, 'road', 'minor')`);
check('cannot submit in someone else\'s name', !!r.error, r);
r = await pub(ALICE, `insert into public.damage_reports (lat, lon, incident_date, type, severity) values (2, 102, current_date + 2, 'road', 'minor')`);
check('future date refused', !!r.error, r);
r = await pub(ALICE, `insert into public.damage_reports (lat, lon, incident_date, type, severity, depth_m) values (2, 102, current_date, 'road', 'minor', 11)`);
check('depth above 10 m refused', !!r.error, r);
await pub(BOB, report());
r = await pub(ALICE, 'select id from public.damage_reports');
check('sees only own reports', r.rows?.length === 2, r);
r = await pub(ALICE, `update public.damage_reports set status = 'verified' where id = '${aliceReport}'`);
check('cannot verify own report', denied(r), r);
r = await pub(ALICE, `delete from public.damage_reports where id = '${aliceReport}'`);
check('cannot delete a report', denied(r), r);
for (let i = 0; i < 3; i++) await pub(ALICE, report());
r = await pub(ALICE, report());
check('anti-spam: sixth pending report refused', !!r.error, r);

console.log('SQL3 Public user: headcount');
r = await pub(ALICE, `insert into public.headcounts (total, babies, elderly, evacuation_point_id) values (5, 1, 2, '${EV}') returning household_id`);
check('can submit own headcount', r.rows?.[0]?.household_id === ALICE, r);
r = await pub(ALICE, `insert into public.headcounts (total) values (3)`);
check('second row for the same household refused', !!r.error, r);
r = await pub(ALICE, `update public.headcounts set total = 6 where household_id = '${ALICE}'`);
check('can update own headcount', r.count === 1, r);
r = await pub(BOB, `insert into public.headcounts (total, babies, elderly) values (2, 2, 1)`);
check('parts larger than the total refused', !!r.error, r);
await pub(BOB, `insert into public.headcounts (total) values (2)`);
r = await pub(BOB, 'select * from public.headcounts');
check('sees only own headcount', r.rows?.length === 1, r);
r = await pub(BOB, `update public.headcounts set total = 30 where household_id = '${ALICE}'`);
check('cannot change another household', denied(r), r);
r = await pub(BOB, `delete from public.headcounts where household_id = '${ALICE}'`);
check('cannot delete another household', denied(r), r);

console.log('SQL4 Public user cannot reach staff data');
r = await pub(ALICE, 'select * from public.staff_profiles');
check('sees no staff profiles', r.rows?.length === 0, r);
r = await pub(ALICE, 'select * from public.inventory_items');
check('sees no inventory', r.rows?.length === 0, r);
r = await pub(ALICE, `insert into public.staff_profiles (id, full_name, username, role) values ('${ALICE}', 'A', 'alice', 'super_admin')`);
check('cannot make themselves Super Admin', !!r.error, r);
r = await pub(ALICE, `update public.evacuation_points set occupancy = 50 where id = '${EV}'`);
check('cannot change shelter occupancy', denied(r), r);
r = await pub(ALICE, `insert into public.inventory_items (resource_point_id, name, quantity) values ('${RP}', 'x', 1)`);
check('cannot add stock', !!r.error, r);

console.log('SQL5 Field officer (and review by a coordinator)');
r = await pub(OFFICER, 'select id from public.damage_reports');
check('sees the reports in their district', r.rows?.length === 6, r);
r = await pub(OFFICER, `update public.damage_reports set status = 'verified' where id = '${aliceReport}'`);
check('cannot review a report', denied(r), r);
r = await pub(COORD, `update public.damage_reports set status = 'rejected' where id = '${aliceReport}'`);
check('reject without a note refused', !!r.error, r);
r = await pub(COORD, `update public.damage_reports set status = 'verified', lat = 9, district = 'SEPANG', reviewed_by = '${ADMIN}' where id = '${aliceReport}' returning lat, district, reviewed_by, reviewed_at`);
check('verify: reviewer recorded automatically, report content and district unchanged',
  r.rows?.[0]?.lat === 2.5 && r.rows[0].district === 'KLANG' && r.rows[0].reviewed_by === COORD && r.rows[0].reviewed_at != null, r);
r = await pub(COORD, `update public.damage_reports set status = 'rejected', staff_note = 'x' where id = '${aliceReport}'`);
check('a reviewed report cannot be reviewed again', !!r.error, r);
r = await pub(ALICE, `select status from public.damage_reports where id = '${aliceReport}'`);
check('reporter sees the new status', r.rows?.[0]?.status === 'verified', r);
r = await pub(OFFICER, `update public.evacuation_points set occupancy = 20, is_open = false where id = '${EV}'`);
check('can update occupancy and open/closed', r.count === 1, r);
r = await pub(OFFICER, `update public.evacuation_points set capacity = 999 where id = '${EV}'`);
check('cannot change capacity', !!r.error, r);
r = await pub(OFFICER, `update public.evacuation_points set occupancy = 51 where id = '${EV}'`);
check('occupancy above capacity refused', !!r.error, r);
r = await pub(OFFICER, `insert into public.evacuation_points (name, lat, lon, capacity) values ('New', 1, 1, 1)`);
check('cannot add an evacuation point', !!r.error, r);
r = await pub(OFFICER, `update public.inventory_items set quantity = 5 where id = '${ITEM}'`);
check('can change stock quantity', r.count === 1, r);
r = await pub(OFFICER, `update public.inventory_items set catalogue_unit_id = '${CU}' where id = '${ITEM}'`);
check('cannot map inventory', !!r.error, r);
r = await pub(OFFICER, `insert into public.resource_points (name, lat, lon) values ('New', 1, 1)`);
check('cannot add a resource point', !!r.error, r);
r = await pub(OFFICER, 'select id from public.staff_profiles');
check('sees only own staff profile', r.rows?.length === 1 && r.rows[0].id === OFFICER, r);
r = await pub(OFFICER, `update public.staff_profiles set role = 'super_admin' where id = '${OFFICER}'`);
check('cannot promote themselves', denied(r), r);
r = await pub(OFFICER, 'select * from public.headcounts');
check('sees headcounts at the centres their point supplies only', r.rows?.length === 1 && r.rows[0].household_id === ALICE, r);

console.log('SQL6 Coordinator');
r = await pub(COORD, `update public.inventory_items set catalogue_unit_id = '${CU}' where id = '${ITEM}'`);
check('can map inventory', r.count === 1, r);
r = await pub(COORD, `insert into public.evacuation_points (name, lat, lon, capacity, district) values ('School', 2.6, 102.9, 30, 'KLANG') returning id`);
const school = r.rows?.[0]?.id;
check('can add an evacuation point in their district', !!school, r);
r = await pub(COORD, `insert into public.evacuation_points (name, lat, lon, capacity, district) values ('school', 2.6, 102.9, 30, 'KLANG')`);
check('duplicate name refused', !!r.error, r);
r = await pub(COORD, `delete from public.evacuation_points where id = '${EV}'`);
check('cannot delete a centre with people recorded', !!r.error, r);
r = await pub(COORD, `delete from public.evacuation_points where id = '${school}'`);
check('can delete an empty centre', r.count === 1, r);
r = await pub(COORD, `delete from public.resource_points where id = '${RP}'`);
check('cannot delete a resource point that has stock', !!r.error, r);
r = await pub(COORD, `insert into public.staff_profiles (id, full_name, username, role) values ('${BOB}', 'B', 'bobby', 'field_officer')`);
check('cannot create staff', !!r.error, r);

console.log('SQL7 Deactivated staff');
r = await pub(EXSTAFF, 'select * from public.damage_reports');
check('sees no reports', r.rows?.length === 0, r);
r = await pub(EXSTAFF, `update public.inventory_items set quantity = 0 where id = '${ITEM}'`);
check('cannot change stock', denied(r), r);

console.log('SQL10 Staff areas (district / resource point)');
r = await pub(ALICE, `insert into public.damage_reports (lat, lon, incident_date, type, severity, district) values (2.7, 101.7, current_date, 'road', 'minor', 'KLANG') returning id, district`);
const sepangReport = r.rows?.[0]?.id;
check('report district comes from the nearest station, not the reporter', r.rows?.[0]?.district === 'SEPANG', r);
r = await pub(BOB, `insert into public.damage_reports (lat, lon, incident_date, type, severity) values (5.5, 100.3, current_date, 'road', 'minor') returning district`);
check('no station within 25 km: no district', r.rows?.length === 1 && r.rows[0].district === null, r);
r = await pub(COORD, 'select district from public.damage_reports');
check('coordinator sees only reports in their district', r.rows?.length > 0 && r.rows.every((x) => x.district === 'KLANG'), r);
r = await pub(OFFICER, `select id from public.damage_reports where id = '${sepangReport}'`);
check('field officer cannot see a report in another district', r.rows?.length === 0, r);
r = await pub(COORD, `update public.damage_reports set status = 'verified' where id = '${sepangReport}'`);
check('coordinator cannot review a report in another district', denied(r), r);
r = await pub(ADMIN, 'select id from public.damage_reports where district is null');
check('Super Admin sees reports with no district', r.rows?.length === 1, r);
r = await pub(COORD, 'select name from public.resource_points');
check('coordinator sees resource points in their district only', r.rows?.length === 1 && r.rows[0].name === 'Depot', r);
r = await pub(COORD, 'select name from public.inventory_items');
check('coordinator sees stock in their district only', r.rows?.length === 1, r);
r = await pub(COORD, `update public.inventory_items set quantity = 0 where id = '${ITEM2}'`);
check('coordinator cannot change stock in another district', denied(r), r);
r = await pub(COORD, `insert into public.resource_points (name, lat, lon, district) values ('Far', 2.7, 101.7, 'SEPANG')`);
check('coordinator cannot add a resource point in another district', !!r.error, r);
r = await pub(COORD, `insert into public.resource_points (name, lat, lon, district) values ('Near', 2.5, 102.8, 'KLANG')`);
check('coordinator can add a resource point in their district', r.count === 1, r);
r = await pub(COORD, `insert into public.evacuation_points (name, lat, lon, capacity, district) values ('Far Hall', 2.7, 101.7, 9, 'SEPANG')`);
check('coordinator cannot add a centre in another district', !!r.error, r);
r = await pub(COORD, `update public.evacuation_points set occupancy = 1 where id = '${EV2}'`);
check('coordinator cannot update a centre in another district', denied(r), r);
r = await pub(COORD, `update public.evacuation_points set district = 'SEPANG' where id = '${EV}'`);
check('coordinator cannot move a centre out of their district', !!r.error, r);
r = await pub(OFFICER, 'select name from public.resource_points');
check('field officer sees only their own resource point', r.rows?.length === 1 && r.rows[0].name === 'Depot', r);
r = await pub(OFFICER, `update public.inventory_items set quantity = 0 where id = '${ITEM2}'`);
check('field officer cannot change stock at another point', denied(r), r);
r = await pub(OFFICER, `insert into public.inventory_items (resource_point_id, name, quantity) values ('${RP2}', 'x', 1)`);
check('field officer cannot add stock at another point', !!r.error, r);
r = await pub(OFFICER, `update public.evacuation_points set occupancy = 1 where id = '${EV2}'`);
check('field officer cannot update a centre their point does not supply', denied(r), r);
await pub(BOB, `update public.headcounts set evacuation_point_id = '${EV2}' where household_id = '${BOB}'`);
r = await pub(COORD, `select household_id from public.headcounts where household_id = '${BOB}'`);
check('coordinator cannot see a headcount at a centre in another district', r.rows?.length === 0, r);
r = await pub(ADMIN, `insert into public.resource_points (name, lat, lon) values ('No district', 2, 102)`);
check('a new resource point needs a district', !!r.error, r);
r = await pub(ADMIN, `insert into public.evacuation_points (name, lat, lon, capacity) values ('No district', 2, 102, 5)`);
check('a new centre needs a district', !!r.error, r);
r = await pub(ADMIN, 'select id from public.inventory_items');
check('Super Admin sees stock everywhere', r.rows?.length === 2, r);
r = await as('anon', null, 'select name from public.districts');
check('anyone can read the district list', r.rows?.length === 9, r);
r = await pub(ALICE, `insert into public.districts values ('NEW')`);
check('nobody can change the district list', !!r.error, r);
r = await as('anon', null, 'select public.staff_district()');
check('the public cannot call the area helpers', !!r.error, r);

console.log('SQL8 Super Admin');
r = await pub(ADMIN, 'select id from public.staff_profiles');
check('sees all staff', r.rows?.length === 4, r);
r = await pub(ADMIN, `insert into public.staff_profiles (id, full_name, username, role) values ('${BOB}', 'Bob', 'bob', 'coordinator')`);
check('coordinator without a district refused', !!r.error, r);
r = await pub(ADMIN, `insert into public.staff_profiles (id, full_name, username, role) values ('${BOB}', 'Bob', 'bob', 'field_officer')`);
check('field officer without a resource point refused', !!r.error, r);
r = await pub(ADMIN, `insert into public.staff_profiles (id, full_name, username, role, assigned_district) values ('${BOB}', 'Bob', 'bob', 'coordinator', 'ATLANTIS')`);
check('unknown district refused', !!r.error, r);
r = await pub(ADMIN, `insert into public.staff_profiles (id, full_name, username, role, assigned_resource_point_id) values ('${BOB}', 'Bob', 'Bad Name', 'field_officer', '${RP}')`);
check('bad username refused', !!r.error, r);
r = await pub(ADMIN, `insert into public.staff_profiles (id, full_name, username, role, assigned_resource_point_id) values ('${BOB}', 'Bob', 'bob', 'field_officer', '${RP}')`);
check('can create staff', r.count === 1, r);
r = await pub(BOB, 'select id from public.inventory_items');
check('the new staff member now has staff access', r.rows?.length === 1, r);
r = await pub(ADMIN, `update public.staff_profiles set active = false where id = '${ADMIN}'`);
check('cannot deactivate the last Super Admin', !!r.error, r);
r = await pub(ADMIN, `update public.staff_profiles set role = 'field_officer' where id = '${ADMIN}'`);
check('cannot demote the last Super Admin', !!r.error, r);
r = await pub(ADMIN, `delete from public.staff_profiles where id = '${ADMIN}'`);
check('cannot delete the last Super Admin', !!r.error, r);
await pub(ADMIN, `update public.staff_profiles set role = 'super_admin' where id = '${BOB}'`);
r = await pub(ADMIN, `update public.staff_profiles set active = false where id = '${ADMIN}'`);
check('cannot deactivate own account even with a second admin', !!r.error, r);
r = await pub(BOB, `update public.staff_profiles set active = false where id = '${ADMIN}'`);
check('a second Super Admin can deactivate the first', r.count === 1, r);
r = await pub(ADMIN, 'select * from public.damage_reports');
check('the deactivated admin loses access at once', r.rows?.length === 0, r);

console.log('SQL9 JPS readings (logger tables)');
const rl = `insert into public.jps_river_levels (station_code, observed_at, level_m) values ('BKLG0002L', '2026-11-17T06:45:00Z', 1.55)`;
r = await as('service_role', null, rl);
check('the logger (service role) can add a reading', r.count === 1, r);
r = await as('service_role', null, rl + ' on conflict do nothing');
check('the same observation twice is ignored', r.count === 0, r);
r = await as('service_role', null, `insert into public.jps_rainfall (station_code, observed_at, hourly_mm, today_mm) values ('BKLG0002L', '2026-11-17T06:45:00Z', 24.5, 33.5)`);
check('the logger can add rainfall', r.count === 1, r);
r = await as('service_role', null, `insert into public.jps_stations (station_code, name, has_river_level) values ('BKLG0002L', 'TAMAN SRI MUDA', true)`);
check('the logger can add a station', r.count === 1, r);
r = await as('anon', null, 'select level_m from public.jps_river_levels');
check('anyone can read readings', r.rows?.length === 1, r);
r = await as('anon', null, `select name from public.jps_stations where station_code = 'BKLG0002L'`);
check('anyone can read stations', r.rows?.length === 1, r);
for (const [who, uid] of [['anon', null], ['authenticated', ALICE], ['authenticated', ADMIN]]) {
  r = await as(who, uid, `insert into public.jps_river_levels (station_code, observed_at, level_m) values ('X', now(), 9)`);
  check(`${who}${uid === ADMIN ? ' (Super Admin)' : ''} cannot add readings`, !!r.error, r);
  r = await as(who, uid, 'update public.jps_river_levels set level_m = 99');
  check(`${who}${uid === ADMIN ? ' (Super Admin)' : ''} cannot change readings`, denied(r), r);
  r = await as(who, uid, 'delete from public.jps_rainfall');
  check(`${who}${uid === ADMIN ? ' (Super Admin)' : ''} cannot delete rainfall`, denied(r), r);
}
r = await as('service_role', null, `insert into public.jps_rainfall (station_code, observed_at, hourly_mm, today_mm) values ('Y', now(), -5, 0)`);
check('negative rainfall is refused', !!r.error, r);
r = await as('service_role', null, 'select public.jps_storage_mb() as mb');
check('the logger can check the database size', r.rows?.[0]?.mb > 0, r);
r = await as('anon', null, 'select public.jps_storage_mb()');
check('the public cannot call the size check', !!r.error, r);
r = await as('authenticated', ALICE, 'select public.jps_storage_mb()');
check('signed-in users cannot call the size check', !!r.error, r);
r = await as('service_role', null, `delete from public.jps_river_levels where observed_at < '2026-11-18T00:00:00Z'`);
check('the logger can delete archived readings', r.count === 1, r);

console.log(`\n${pass}/${pass + fail} passed`);
process.exit(fail ? 1 : 0);
