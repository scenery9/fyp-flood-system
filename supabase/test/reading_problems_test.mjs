// Tests supabase/reading_problems.sql (why a station has no usable river reading)
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
const files = ['schema.sql', 'readings.sql', 'staff_districts.sql', 'alerts.sql', 'routing.sql',
  'public_reports.sql', 'household_groups.sql', 'places.sql', 'sources.sql', 'reading_problems.sql'];
for (const f of files) {
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

// RP1 the logger records the problem; anyone can read it in jps_latest
let r = await as('service_role', `insert into public.jps_stations (station_code, name, has_river_level, wl_problem, wl_problem_at)
  values ('A', 'A', true, 'offline', '2026-11-17T07:20:00Z'), ('B', 'B', true, null, null)`);
check('the logger can record a problem', !r.error, r);
await db.exec(`insert into public.jps_river_levels values ('A', '2026-11-17T06:00:00Z', 2.5), ('B', '2026-11-17T07:15:00Z', -1.2)`);
r = await as('anon', `select station_code, level_m, level_at, wl_problem, wl_problem_at, state
  from public.jps_latest order by station_code`);
check('jps_latest shows the problem next to the last good reading',
  !r.error && r.rows[0].wl_problem === 'offline' && r.rows[0].level_m === 2.5 && r.rows[0].state === 'Selangor', r);
check('a station with no problem shows none, and a level below 0 as it is',
  r.rows?.[1]?.wl_problem === null && r.rows?.[1]?.level_m === -1.2, r);

// RP2 only the known problems are accepted, and the public cannot change them
r = await as('service_role', `update public.jps_stations set wl_problem = 'broken' where station_code = 'A'`);
check('an unknown problem is refused', !!r.error, r);
for (const p of ['offline', 'estimated', 'no_value', 'old_time', 'bad_time', 'glitch']) {
  r = await as('service_role', `update public.jps_stations set wl_problem = '${p}' where station_code = 'A'`);
  check(`'${p}' is accepted`, !r.error, r);
}
r = await as('anon', `update public.jps_stations set wl_problem = null where station_code = 'A'`);
const after = await db.query(`select wl_problem from public.jps_stations where station_code = 'A'`);
check('the public cannot clear a problem', !!r.error || after.rows[0].wl_problem === 'glitch', { r, after: after.rows });

// RP3 the file can be run twice
try {
  await db.exec(readFileSync(new URL('../reading_problems.sql', import.meta.url), 'utf8'));
  check('the file can be run twice', true);
} catch (e) {
  check('the file can be run twice', false, e.message);
}

console.log(`\n${pass}/${pass + fail} passed`);
process.exit(fail ? 1 : 0);
