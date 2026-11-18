// Tests supabase/public_reports.sql (flood reports and the relief-centre headcount)
// on a local Postgres (PGlite), after the other files in the documented order.
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
`);
for (const f of ['schema.sql', 'readings.sql', 'staff_districts.sql', 'alerts.sql', 'routing.sql', 'public_reports.sql', 'household_groups.sql']) {
  await db.exec(readFileSync(new URL(`../${f}`, import.meta.url), 'utf8'));
}

const U = (n) => `00000000-0000-0000-0000-${String(n).padStart(12, '0')}`;
const [ADMIN, COORD, ALICE, BOB, SEPANG_COORD] = [1, 2, 4, 5, 7].map(U);
const RP = U(100), EV = U(200), RP2 = U(101), EV2 = U(201), FULL = U(202);

await db.exec(`
  insert into auth.users select ('00000000-0000-0000-0000-' || lpad(g::text, 12, '0'))::uuid from generate_series(1, 7) g;
  insert into public.jps_stations (station_code, name, district, lat, lon) values
    ('TEST-K', 'Test Klang', 'KLANG', 2.5, 102.8), ('TEST-S', 'Test Sepang', 'SEPANG', 2.7, 101.7);
  insert into public.resource_points (id, name, lat, lon, district) values
    ('${RP}', 'Depot', 2.5, 102.8, 'KLANG'), ('${RP2}', 'Sepang Depot', 2.7, 101.7, 'SEPANG');
  insert into public.staff_profiles (id, full_name, username, role, assigned_district, active) values
    ('${ADMIN}', 'Admin', 'admin', 'super_admin', null, true),
    ('${COORD}', 'Coord', 'coord', 'coordinator', 'KLANG', true),
    ('${SEPANG_COORD}', 'Coord S', 'coords', 'coordinator', 'SEPANG', true);
  insert into public.evacuation_points (id, name, lat, lon, capacity, occupancy, district, resource_point_id) values
    ('${EV}', 'Hall', 2.5, 102.8, 50, 0, 'KLANG', '${RP}'),
    ('${FULL}', 'Full Hall', 2.501, 102.801, 10, 10, 'KLANG', '${RP}'),
    ('${EV2}', 'Sepang Hall', 2.7, 101.7, 50, 0, 'SEPANG', '${RP2}');
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
const pub = (uid, sql) => as('authenticated', uid, sql);
const q = (o) => `'${JSON.stringify(o).replaceAll("'", "''")}'::jsonb`;
const ago = (h) => new Date(Date.now() - h * 3600e3).toISOString();

let pass = 0, fail = 0;
function check(name, ok, detail = '') {
  ok ? pass++ : fail++;
  console.log(`  ${ok ? 'PASS' : 'FAIL'}  ${name}${ok ? '' : '  -> ' + JSON.stringify(detail)}`);
}

const sighting = (extra = {}) => ({ kind: 'sighting', lat: 2.5, lon: 102.8, occurred_at: ago(0.1),
  client_ref: 'ref-sight-1', depth_band: 'knee', depth_m: 0.5, description: ' water on road ', ...extra });
const damage = (extra = {}) => ({ ...sighting(), kind: 'damage', client_ref: 'ref-dmg-0001', type: 'road', severity: 'severe', ...extra });

console.log('RP1 Flood reports');
let r = await as('anon', null, `select public.submit_flood_report(${q(sighting())})`);
check('not signed in: refused', !!r.error, r);
r = await pub(ALICE, `select public.submit_flood_report(${q(sighting({ type: 'road', severity: 'minor' }))}) as id`);
const first = r.rows?.[0]?.id;
check('"Flooding here now" without damage questions is accepted', !!first, r);
r = await pub(ALICE, `select kind, type, severity, depth_band, district, status, description from public.damage_reports where id = '${first}'`);
const row = r.rows?.[0];
check('stored as a sighting; damage fields ignored; district from the nearest station; trimmed',
  row?.kind === 'sighting' && row.type === null && row.severity === null && row.depth_band === 'knee'
  && row.district === 'KLANG' && row.status === 'pending' && row.description === 'water on road', row);
r = await pub(ALICE, `select public.submit_flood_report(${q(sighting())}) as id`);
check('sending again with the same reference returns the same report', r.rows?.[0]?.id === first, r);
r = await pub(ALICE, `select count(*)::int as n from public.damage_reports`);
check('... and adds no second row', r.rows?.[0]?.n === 1, r);
r = await pub(ALICE, `select public.submit_flood_report(${q(damage({ type: null }))})`);
check('damage without a type is refused', !!r.error, r);
r = await pub(ALICE, `select public.submit_flood_report(${q(damage({ client_ref: 'ref-future', occurred_at: ago(-1) }))})`);
check('a time in the future is refused', /future/.test(r.error ?? ''), r);
r = await pub(ALICE, `select public.submit_flood_report(${q(damage({ client_ref: 'ref-old-0001', occurred_at: ago(24 * 61) }))})`);
check('older than 60 days is refused', /60 days/.test(r.error ?? ''), r);
r = await pub(ALICE, `select public.submit_flood_report(${q(damage({ depth_band: 'neck', client_ref: 'ref-neck-001' }))})`);
check('an unknown depth is refused', !!r.error, r);
r = await pub(ALICE, `select public.submit_flood_report(${q(damage())}) as id`);
const dmg = r.rows?.[0]?.id;
check('a damage report is accepted', !!dmg, r);
await pub(BOB, `select public.submit_flood_report(${q(damage({ client_ref: 'ref-bob-0001' }))})`);
r = await pub(ALICE, `select public.my_flood_reports() as j`);
const mine = r.rows?.[0]?.j;
check('"My reports": own only, newest first', mine?.length === 2 && mine[0].kind === 'damage' && mine[1].kind === 'sighting', mine);
r = await pub(COORD, `update public.damage_reports set status = 'verified', kind = 'damage', depth_band = 'chest' where id = '${first}'`);
r = await pub(COORD, `select status, kind, depth_band from public.damage_reports where id = '${first}'`);
check('a review cannot change what the reporter sent', r.rows?.[0]?.status === 'verified'
  && r.rows[0].kind === 'sighting' && r.rows[0].depth_band === 'knee', r);
r = await pub(ALICE, `select public.my_flood_reports() as j`);
check('the reporter sees the new status', r.rows?.[0]?.j?.[1]?.status === 'verified', r);
r = await pub(SEPANG_COORD, `select id from public.damage_reports`);
check('staff in another district do not see the reports', r.rows?.length === 0, r);

console.log('RP2 Headcount');
const hc = (extra = {}) => ({ total: 4, babies: 1, elderly: 1, reduced_mobility: 1,
  needs: ['power', 'formula'], other_need: 'ignored', centre_id: 'PPS-SAMPLE', lat: 2.501, lon: 102.801 /* at the full centre */, status: 'on_the_way', ...extra });
r = await as('anon', null, `select public.submit_headcount(${q(hc())})`);
check('not signed in: refused', !!r.error, r);
r = await pub(ALICE, `select public.submit_headcount(${q(hc())}) as j`);
let h = r.rows?.[0]?.j;
check('a sample centre id: the nearest open centre with space is used (not the full one)',
  h?.centre_id === EV && h.centre_name === 'Hall', h);
check('needs kept; "other" text dropped when Other is not chosen', h?.needs?.join() === 'power,formula' && h.other_need === '', h);
const hours = (new Date(h?.expires_at) - Date.now()) / 3600e3;
check('counts for 72 hours from now', hours > 71.9 && hours <= 72.01, h);
r = await pub(ALICE, `select public.submit_headcount(${q(hc({ centre_id: EV2, needs: ['other'], other_need: ' halal food ' }))}) as j`);
h = r.rows?.[0]?.j;
check('sending again updates the same row, to the centre chosen', h?.centre_id === EV2 && h.other_need === 'halal food', h);
r = await pub(ALICE, `select count(*)::int as n from public.headcounts`);
check('... still one row for the household', r.rows?.[0]?.n === 1, r);
r = await pub(ALICE, `select public.submit_headcount(${q(hc({ needs: ['jacuzzi'] }))})`);
check('an unknown need is refused', !!r.error, r);
r = await pub(ALICE, `select public.submit_headcount(${q(hc({ total: 2, babies: 2, elderly: 1 }))})`);
check('parts larger than the total are refused', !!r.error, r);
r = await pub(ALICE, `select public.submit_headcount(${q(hc({ total: 4, babies: 1, children: 1, adults: 1, elderly: 1, pets: 2, daily_medicine: true, power_machine: true }))}) as j`);
h = r.rows?.[0]?.j;
check('age groups, pets and health needs are kept', h?.children === 1 && h.adults === 1 && h.pets === 2 && h.daily_medicine === true && h.power_machine === true, h);
r = await pub(ALICE, `select public.submit_headcount(${q(hc({ total: 3, babies: 1, children: 1, adults: 1, elderly: 1 }))})`);
check('age groups adding up to more than the total are refused', !!r.error, r);
r = await pub(ALICE, `select public.submit_headcount(${q(hc({ pets: 21 }))})`);
check('more than 20 pets refused', !!r.error, r);
await pub(ALICE, `select public.submit_headcount(${q(hc({ centre_id: EV2, needs: ['other'], other_need: ' halal food ' }))})`);
r = await pub(BOB, `select public.submit_headcount(${q(hc({ centre_id: null, lat: undefined, lon: undefined, total: 2, babies: 0, elderly: 0, reduced_mobility: 0 }))}) as j`);
check('no centre and no location: kept without a centre', r.rows?.[0]?.j?.centre_id === null, r);
r = await pub(BOB, `select public.my_headcount() as j`);
check('Bob sees only his own', r.rows?.[0]?.j?.total === 2, r);
r = await pub(ALICE, `select * from public.reported_people()`);
check('people reported per centre (on the way)', r.rows?.length === 1 && r.rows[0].centre_id === EV2 && Number(r.rows[0].people) === 4, r);
r = await pub(ALICE, `select public.set_headcount_status('arrived') as j`);
check('Arrived', r.rows?.[0]?.j?.status === 'arrived', r);
r = await pub(ALICE, `select public.set_headcount_status('swimming')`);
check('an unknown status is refused', !!r.error, r);
r = await pub(SEPANG_COORD, `select total, needs, other_need from public.headcounts`);
check('the coordinator of that centre sees the household and its needs',
  r.rows?.length === 1 && r.rows[0].other_need === 'halal food', r);
r = await pub(COORD, `select total from public.headcounts`);
check('another district\'s coordinator does not', r.rows?.length === 0, r);
r = await pub(ALICE, `select public.set_headcount_status('left') as j`);
r = await as('anon', null, `select * from public.reported_people()`);
check('after "Left the centre" the household is no longer counted (public totals)', r.rows?.length === 0, r);
await db.exec(`update public.headcounts set status = 'arrived' where household_id = '${ALICE}'`);
await db.exec(`alter table public.headcounts disable trigger headcounts_before_write;
  update public.headcounts set expires_at = now() - interval '1 minute' where household_id = '${ALICE}';
  alter table public.headcounts enable trigger headcounts_before_write;`);
r = await pub(ALICE, `select * from public.reported_people()`);
check('an expired headcount is no longer counted', r.rows?.length === 0, r);
r = await pub(ALICE, `update public.headcounts set expires_at = now() + interval '30 days' where household_id = '${ALICE}' returning expires_at`);
const e2 = (new Date(r.rows?.[0]?.expires_at) - Date.now()) / 3600e3;
check('the phone cannot choose its own expiry', e2 > 71.9 && e2 <= 72.01, r);
r = await pub(ALICE, `select public.remove_headcount()`);
r = await pub(ALICE, `select public.my_headcount() as j`);
check('Remove: nothing left', r.rows?.[0]?.j === null, r);
r = await pub(ALICE, `select public.set_headcount_status('arrived')`);
check('status without a headcount: clear message', /No headcount/.test(r.error ?? ''), r);

console.log(`\n${pass}/${pass + fail} passed`);
process.exit(fail ? 1 : 0);
