// Shared setup for the security pack tests: a local Postgres (PGlite) with
// Supabase's roles, auth.uid(), a stand-in for Vault, pgcrypto and pg_trgm,
// then every SQL file in the documented order up to `upTo`.
import { PGlite } from '@electric-sql/pglite';
import { pgcrypto } from '@electric-sql/pglite/contrib/pgcrypto';
import { pg_trgm } from '@electric-sql/pglite/contrib/pg_trgm';
import { readFileSync } from 'node:fs';

export const ORDER = ['schema.sql', 'readings.sql', 'staff_districts.sql', 'alerts.sql', 'routing.sql',
  'public_reports.sql', 'household_groups.sql', 'places.sql', 'sources.sql', 'reading_problems.sql',
  'security.sql', 'family.sql', 'shelter.sql', 'report_triage.sql'];

export async function makeDb(upTo, { columnKey = 'a'.repeat(64) } = {}) {
  const db = new PGlite({ extensions: { pgcrypto, pg_trgm } });
  await db.exec(`
    create role anon nologin; create role authenticated nologin; create role service_role nologin bypassrls;
    create schema auth;
    create table auth.users (id uuid primary key);
    create function auth.uid() returns uuid language sql stable as
      $$ select nullif(current_setting('request.jwt.claim.sub', true), '')::uuid $$;
    grant usage on schema auth to anon, authenticated;
    grant usage on schema public to service_role;
    create schema extensions;
    -- Stand-in for Supabase Vault (only the view the SQL files read).
    create schema vault;
    create table vault.decrypted_secrets (name text primary key, decrypted_secret text);
  `);
  if (columnKey) await db.query(`insert into vault.decrypted_secrets values ('column_encryption_key', $1)`, [columnKey]);
  for (const f of ORDER.slice(0, ORDER.indexOf(upTo) + 1)) {
    try {
      await db.exec(readFileSync(new URL(`../${f}`, import.meta.url), 'utf8'));
    } catch (e) {
      throw new Error(`${f}: ${e.message}`);
    }
  }
  return db;
}

export const U = (n) => `00000000-0000-0000-0000-${String(n).padStart(12, '0')}`;
export const q = (o) => `'${JSON.stringify(o).replaceAll("'", "''")}'::jsonb`;

export function harness(db) {
  let pass = 0, fail = 0;
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
  return {
    as,
    pub: (uid, sql) => as('authenticated', uid, sql),
    check(name, ok, detail = '') {
      ok ? pass++ : fail++;
      console.log(`  ${ok ? 'PASS' : 'FAIL'}  ${name}${ok ? '' : '  -> ' + JSON.stringify(detail)}`);
    },
    done() {
      console.log(`\n${pass} passed, ${fail} failed`);
      if (fail) process.exit(1);
    },
  };
}
