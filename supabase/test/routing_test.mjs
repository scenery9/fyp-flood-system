// Tests supabase/routing.sql (route limits) on a local Postgres (PGlite).
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
for (const f of ['schema.sql', 'routing.sql']) {
  await db.exec(readFileSync(new URL(`../${f}`, import.meta.url), 'utf8'));
}
const U = (n) => `00000000-0000-0000-0000-${String(n).padStart(12, '0')}`;
const [ALICE, BOB] = [U(1), U(2)];

async function as(role, uid, sql) {
  await db.exec(`set role ${role}; set request.jwt.claim.sub = '${uid ?? ''}';`);
  try {
    const r = await db.query(sql);
    return { rows: r.rows };
  } catch (e) {
    return { error: e.message };
  } finally {
    await db.exec('reset role; reset request.jwt.claim.sub;');
  }
}
const allow = async (uid) => (await as('authenticated', uid, 'select public.route_allow() as ok')).rows?.[0]?.ok;
let pass = 0, fail = 0;
function check(name, ok, detail = '') {
  ok ? pass++ : fail++;
  console.log(`  ${ok ? 'PASS' : 'FAIL'}  ${name}${ok ? '' : '  -> ' + JSON.stringify(detail)}`);
}
// Past requests, added as the database owner.
async function past(uid, n, minutesAgo) {
  await db.exec(`insert into public.route_requests (user_id, at)
                 select '${uid}', now() - interval '${minutesAgo} minutes' from generate_series(1, ${n})`);
}
const clear = () => db.exec('delete from public.route_requests');

console.log('RT1 Route limits');
let r = await as('anon', null, 'select public.route_allow()');
check('the public (not signed in) cannot ask for routes', !!r.error, r);
r = await as('authenticated', ALICE, 'select * from public.route_requests');
check('a phone cannot read the request log', !!r.error || r.rows.length === 0, r);
const six = [];
for (let i = 0; i < 7; i++) six.push(await allow(ALICE));
check('6 a minute per phone, the 7th is refused', six.slice(0, 6).every(Boolean) && six[6] === false, six);
check('another phone is not affected', await allow(BOB) === true);
await clear();
await past(ALICE, 59, 30);
check('59 earlier today: one more allowed', await allow(ALICE) === true);
check('60 a day per phone', await allow(ALICE) === false);
await clear();
await past(ALICE, 60, 24 * 60 + 5);
check('requests older than a day no longer count (and are removed)', await allow(ALICE) === true);
r = await as('postgres', null, 'select count(*)::int as n from public.route_requests');
check('old requests are cleaned up', r.rows?.[0]?.n === 1, r);
await clear();
await past(BOB, 35, 0);
check('35 a minute for everyone together', await allow(ALICE) === false);
await clear();
await past(BOB, 1800, 120);
check('1,800 a day for everyone together', await allow(ALICE) === false);

console.log(`\n${pass}/${pass + fail} passed`);
process.exit(fail ? 1 : 0);
