// Tests supabase/alerts.sql (push alert rules) on a local Postgres (PGlite),
// with a small stand-in for Supabase Auth. Run:  npm install && npm run alerts
// The timing cases match packages/flood_core/test/personalise_test.dart (TP24).
import { PGlite } from '@electric-sql/pglite';
import { readFileSync } from 'node:fs';

const db = new PGlite();
await db.exec(`
  create role anon nologin; create role authenticated nologin; create role service_role nologin bypassrls;
  create schema auth;
  create table auth.users (id uuid primary key);
  create function auth.uid() returns uuid language sql stable as
    $$ select nullif(current_setting('request.jwt.claim.sub', true), '')::uuid $$;
  grant usage on schema auth to anon, authenticated, service_role;
  grant usage on schema public to service_role;
`);
for (const f of ['schema.sql', 'readings.sql', 'staff_districts.sql', 'alerts.sql']) {
  await db.exec(readFileSync(new URL(`../${f}`, import.meta.url), 'utf8'));
}

const U = (n) => `00000000-0000-0000-0000-${String(n).padStart(12, '0')}`;
const [ALICE, BOB, CAROL] = [1, 2, 3].map(U);
const T0 = Date.parse('2026-11-18T00:00:00Z');
const at = (min) => new Date(T0 + min * 60000).toISOString();
const TOKEN_A = 'token-alice-0123456789abcdef', TOKEN_B = 'token-bob-0123456789abcdefgh';

await db.exec(`
  insert into auth.users values ('${ALICE}'), ('${BOB}'), ('${CAROL}');
  insert into public.jps_stations (station_code, name, district, lat, lon, has_river_level,
                                   wl_normal, wl_alert, wl_warning, wl_danger) values
    ('S1', 'Sg. Satu', 'KLANG', 3.0, 101.4, true, 1, 2, 3, 4),
    ('S2', 'Sg. Dua', 'KLANG', 3.1, 101.5, true, 1, 2, 3, 4),
    ('RAIN', 'Hujan Sahaja', 'KLANG', 3.2, 101.5, false, null, null, null, null);
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
const me = (uid, sql) => as('authenticated', uid, sql);
const server = (sql) => as('service_role', null, sql);

let pass = 0, fail = 0;
function check(name, ok, detail = '') {
  ok ? pass++ : fail++;
  console.log(`  ${ok ? 'PASS' : 'FAIL'}  ${name}${ok ? '' : '  -> ' + JSON.stringify(detail)}`);
}
const denied = (r) => !!r.error || r.count === 0;

// River reading for a station at minute [min] after T0.
let minute = 0;
async function river(code, level, min = minute) {
  await db.exec(`insert into public.jps_river_levels values ('${code}', '${at(min)}', ${level})
                 on conflict (station_code, observed_at) do update set level_m = excluded.level_m`);
}
// One run of the 15-minute job: what is due, and mark it sent (like send-alerts).
async function tick(min = minute, { send = true } = {}) {
  const r = await server(`select * from public.alerts_tick('${at(min)}')`);
  if (r.error) throw new Error(r.error);
  if (send && r.rows.length) {
    const ids = r.rows.map((x) => `'${x.rule_id}'`).join(',');
    const lv = r.rows.map((x) => `'${x.level}'`).join(',');
    const m = await server(`select public.alerts_mark_sent(array[${ids}]::uuid[], array[${lv}]::text[], '${at(min)}')`);
    if (m.error) throw new Error(m.error);
  }
  return r.rows;
}
const codes = (rows) => rows.map((x) => `${x.station_code}:${x.kind}`).sort();
async function rules(uid, list) {
  return me(uid, `select public.sync_alert_rules('${JSON.stringify(list)}'::jsonb) as n`);
}
async function reset() {
  await db.exec(`delete from public.alert_rules; delete from public.jps_river_levels;`);
  minute = 0;
}

console.log('AL1 Access');
let r = await as('anon', null, 'select * from public.device_tokens');
check('the public cannot read tokens', !!r.error, r);
r = await as('anon', null, `select public.register_device('${TOKEN_A}', 'android', 'en')`);
check('the public cannot register a phone', !!r.error, r);
r = await me(ALICE, `select public.register_device('${TOKEN_A}', 'android', 'ms')`);
check('a phone can register its token', !r.error, r);
r = await me(ALICE, `select public.register_device('${TOKEN_A}', 'android', 'zh')`);
r = await me(ALICE, 'select language from public.device_tokens');
check('registering again updates the same row', r.rows?.length === 1 && r.rows[0].language === 'zh', r);
r = await me(BOB, `select public.register_device('${TOKEN_A}', 'android', 'en')`);
r = await server(`select user_id from public.device_tokens where fcm_token = '${TOKEN_A}'`);
check('a token moves to the new user after a reinstall', r.rows?.length === 1 && r.rows[0].user_id === BOB, r);
await me(ALICE, `select public.register_device('${TOKEN_A}', 'android', 'en')`);
await me(BOB, `select public.register_device('${TOKEN_B}', 'android', 'ms')`);
r = await me(ALICE, 'select fcm_token from public.device_tokens');
check('a phone sees only its own token', r.rows?.length === 1 && r.rows[0].fcm_token === TOKEN_A, r);
r = await me(ALICE, `select public.register_device('short', 'android', 'en')`);
check('a bad token is refused', !!r.error, r);
r = await me(ALICE, `select public.register_device('${TOKEN_A}x', 'android', 'fr')`);
check('an unknown language is refused', !!r.error, r);

console.log('AL2 My rules');
r = await rules(ALICE, [
  { station_code: 'S1', kind: 'risk', min_level: 'warning' },
  { station_code: 'S2', kind: 'level', level_m: 2.5 },
  { station_code: 'NOPE', kind: 'risk', min_level: 'alert' },
]);
check('sync saves the rules and skips unknown stations', r.rows?.[0]?.n === 2, r);
r = await me(BOB, 'select * from public.alert_rules');
check("another phone cannot see Alice's rules", r.rows?.length === 0, r);
r = await me(BOB, `insert into public.alert_rules (user_id, station_code, kind, min_level) values ('${ALICE}', 'S1', 'risk', 'alert')`);
check("cannot add a rule in someone else's name", !!r.error, r);
r = await me(BOB, `delete from public.alert_rules where user_id = '${ALICE}'`);
check("cannot delete someone else's rules", denied(r), r);
r = await rules(ALICE, [{ station_code: 'S1', kind: 'risk', min_level: 'normal' }]);
check('a risk rule must be Alert or higher', !!r.error, r);
r = await me(ALICE, 'select count(*)::int as n from public.alert_rules');
check('a refused sync changes nothing', r.rows?.[0]?.n === 2, r);
r = await rules(ALICE, Array.from({ length: 21 }, (_, i) => ({ station_code: 'S1', kind: 'risk', min_level: 'alert', i })));
check('more than 20 rules refused', !!r.error, r);
r = await me(ALICE, 'select * from public.alert_state');
check('a phone cannot read the sent-state table', !!r.error || r.rows.length === 0, r);
r = await me(ALICE, `select * from public.alerts_tick()`);
check('a phone cannot run the check', !!r.error, r);
r = await as('anon', null, `select level_m from public.jps_latest where station_code = 'S1'`);
check('anyone can read the latest readings', !r.error, r);
r = await rules(ALICE, [{ station_code: 'S2', kind: 'level', level_m: 2.5 }]);
r = await me(ALICE, 'select station_code from public.alert_rules');
check('sync removes rules that are no longer listed', r.rows?.length === 1 && r.rows[0].station_code === 'S2', r);

console.log('AL3 When to notify (same cases as TP24)');
await reset();
await rules(ALICE, [{ station_code: 'S1', kind: 'risk', min_level: 'alert' }]);
await river('S1', 1.5);
check('nothing while the river is normal', (await tick()).length === 0);
await river('S1', 2.5, (minute = 15));
let rows = await tick();
check('fires once when the level is reached', rows.length === 1 && rows[0].reason === 'first' && rows[0].level === 'alert', rows);
check('the message details are returned', rows[0]?.fcm_token === TOKEN_A && rows[0]?.station_name === 'Sg. Satu' && rows[0]?.language === 'en', rows);
minute = 30;
check('not again on the next run', (await tick()).length === 0);
await river('S1', 3.5, (minute = 45));
rows = await tick();
check('fires again when the river moves up a level', rows.length === 1 && rows[0].reason === 'escalated' && rows[0].level === 'warning', rows);
await river('S1', 2.5, (minute = 60));
check('no alert for going down', (await tick()).length === 0);

await reset();
await rules(ALICE, [{ station_code: 'S1', kind: 'risk', min_level: 'warning' }]);
await river('S1', 4.5);
check('Danger: first alert', (await tick()).length === 1);
await river('S1', 4.5, (minute = 44));
check('Danger: nothing after 44 minutes', (await tick()).length === 0);
await river('S1', 4.5, (minute = 45));
rows = await tick();
check('Danger: repeats after 45 minutes', rows.length === 1 && rows[0].reason === 'danger_repeat', rows);
await river('S1', 4.5, (minute = 55));
check('Danger: not again 10 minutes later', (await tick()).length === 0);

await reset();
await rules(ALICE, [{ station_code: 'S1', kind: 'risk', min_level: 'warning' }]);
await river('S1', 3.5);
await tick();
await river('S1', 3.5, (minute = 300));
check('Warning does not repeat', (await tick()).length === 0);

await reset();
await rules(ALICE, [{ station_code: 'S1', kind: 'risk', min_level: 'warning' }]);
await river('S1', 3.1);
check('hover: first alert', (await tick()).length === 1);
await river('S1', 2.9, (minute = 15)); await tick();
await river('S1', 3.1, (minute = 30));
check('hover: back within 60 minutes is the same event', (await tick()).length === 0);
await river('S1', 2.9, (minute = 45)); await tick();
await river('S1', 2.9, (minute = 75)); await tick();
await river('S1', 3.1, (minute = 76));
check('hover: back after 31 minutes below is still the same event', (await tick()).length === 0);
await river('S1', 2.9, (minute = 80)); await tick();
await river('S1', 2.9, (minute = 139));
check('hover: 59 minutes below, nothing', (await tick()).length === 0);
await river('S1', 2.9, (minute = 140));
check('hover: 60 minutes below resets quietly', (await tick()).length === 0);
await river('S1', 3.1, (minute = 141));
rows = await tick();
check('hover: after the reset it fires again', rows.length === 1 && rows[0].reason === 'first', rows);

await reset();
await rules(ALICE, [{ station_code: 'S2', kind: 'level', level_m: 2.5 }]);
await river('S2', 2.5);
rows = await tick();
check('height: fires at the exact height', rows.length === 1 && rows[0].kind === 'level' && rows[0].alert_level_m === 2.5, rows);
await river('S2', 2.41, (minute = 61)); await tick();
await river('S2', 2.41, (minute = 130)); await tick();
await river('S2', 2.5, (minute = 131));
check('height: within 0.10 m still counts as reached (no reset, no repeat)', (await tick()).length === 0);
await river('S2', 2.39, (minute = 132)); await tick();
await river('S2', 2.39, (minute = 192));
check('height: more than 0.10 m below for an hour resets', (await tick()).length === 0);
await river('S2', 2.45, (minute = 193));
check('height: the buffer only applies after firing', (await tick()).length === 0);
await river('S2', 2.5, (minute = 194));
check('height: fires again at the height', (await tick()).length === 1);

console.log('AL4 Old data, failures and tokens');
await reset();
await rules(ALICE, [{ station_code: 'S1', kind: 'risk', min_level: 'warning' }]);
await river('S1', 4.5, -181);
check('a reading over 3 hours old never fires', (await tick(0)).length === 0);
await river('S1', 4.5, 10);
check('a reading from the future never fires', (await tick(0)).length === 0);
check('a fresh reading fires', (await tick(10)).length === 1);
await reset();
await rules(ALICE, [{ station_code: 'S1', kind: 'risk', min_level: 'warning' }]);
await river('S1', 3.5);
check('a failed send is not recorded', (await tick(0, { send: false })).length === 1);
check('so it is tried again next run', (await tick(15)).length === 1);
check('and stops once sent', (await tick(30)).length === 0);
await rules(ALICE, [{ station_code: 'S1', kind: 'risk', min_level: 'alert' }]);
check('a changed rule starts fresh', (await tick(45)).length === 1);
await rules(ALICE, [{ station_code: 'S1', kind: 'risk', min_level: 'alert' }]);
check('syncing the same rule again does not repeat the alert', (await tick(50)).length === 0);
await reset();
await rules(ALICE, [{ station_code: 'RAIN', kind: 'risk', min_level: 'alert' }]);
await river('RAIN', 9);
check('a station without thresholds never fires a risk rule', (await tick()).length === 0);
await reset();
await rules(CAROL, [{ station_code: 'S1', kind: 'risk', min_level: 'alert' }]);
await river('S1', 4.5);
check('a phone without a token gets nothing', (await tick()).length === 0);
await rules(ALICE, [{ station_code: 'S1', kind: 'risk', min_level: 'alert' }]);
await rules(BOB, [{ station_code: 'S1', kind: 'risk', min_level: 'alert' }]);
rows = await tick();
check('each phone gets its own alert', rows.map((x) => x.user_id).sort().join() === [ALICE, BOB].sort().join(), rows);
r = await server(`select public.alerts_drop_tokens(array['${TOKEN_B}']) as n`);
check('tokens Firebase rejects are removed', r.rows?.[0]?.n === 1, r);
r = await me(ALICE, 'select public.unregister_device()');
r = await server(`select (select count(*) from public.alert_rules where user_id = '${ALICE}')::int as rules,
                         (select count(*) from public.device_tokens where user_id = '${ALICE}')::int as tokens`);
check('turning notifications off removes the token and rules', r.rows?.[0]?.rules === 0 && r.rows[0].tokens === 0, r);

console.log(`\n${pass}/${pass + fail} passed`);
process.exit(fail ? 1 : 0);
