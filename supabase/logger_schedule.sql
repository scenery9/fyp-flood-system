-- =====================================================================
-- Starts the JPS logger (GitHub Actions, .github/workflows/log_jps.yml) every
-- 15 minutes from inside Supabase (pg_cron), at minutes 7, 22, 37 and 52.
--
-- Why: GitHub's own schedule is best-effort. On 19 Nov 2026 it started the
-- "every 15 minutes" workflow only every 5-8 hours, so the app showed
-- "No recent data". Supabase asks GitHub to run the workflow instead (the same
-- as pressing "Run workflow"). The workflow's own schedule stays as a backup.
-- pg_cron and pg_net are included in the Supabase Free plan at no cost.
--
-- Before running this file, make a GitHub token:
--   GitHub -> Settings -> Developer settings -> Fine-grained tokens -> Generate:
--     Repository access: Only select repositories -> this repository
--     Permissions: Actions -> Read and write (nothing else)
--     Expiration: the longest allowed; note the date and renew it before then.
--
-- How to use: replace the value marked <<< below, then
-- Supabase dashboard -> SQL Editor -> paste this whole file -> Run.
-- The token is stored in Supabase Vault (encrypted), not in this file.
-- Do NOT commit this file with your real token in it.
-- =====================================================================

-- If these two lines give an error, turn on "pg_cron" and "pg_net" in
-- Dashboard -> Database -> Extensions instead, then run the rest.
create extension if not exists pg_cron;
create extension if not exists pg_net with schema extensions;

select vault.create_secret('PASTE-YOUR-GITHUB-TOKEN-HERE', 'github_actions_token'); -- <<< the fine-grained token

select cron.schedule(
  'run-jps-logger',
  '7,22,37,52 * * * *',
  $$
  select net.http_post(
    url := 'https://api.github.com/repos/scenery9/fyp-flood-system/actions/workflows/log_jps.yml/dispatches',
    headers := jsonb_build_object(
      'Accept', 'application/vnd.github+json',
      'Authorization', 'Bearer ' || (select decrypted_secret from vault.decrypted_secrets where name = 'github_actions_token'),
      'X-GitHub-Api-Version', '2022-11-28',
      'User-Agent', 'fyp-flood-system-cron'),
    body := '{"ref":"main"}'::jsonb,
    timeout_milliseconds := 30000
  );
  $$
);

-- ---------- checking it works ----------
-- Last runs of the schedule (status should be 'succeeded'):
--   select status, return_message, start_time from cron.job_run_details
--   where jobid = (select jobid from cron.job where jobname = 'run-jps-logger')
--   order by start_time desc limit 5;
-- What GitHub answered: 204 = workflow started; 401 = token wrong or expired;
-- 403/404 = token lacks "Actions: Read and write" on this repository.
--   select status_code, content, created from net._http_response order by created desc limit 5;
-- Then GitHub -> Actions -> "Log JPS Selangor and Melaka readings" shows a
-- "workflow_dispatch" run every 15 minutes.
--
-- ---------- new token (e.g. after it expires) ----------
--   select vault.update_secret((select id from vault.secrets where name = 'github_actions_token'), 'NEW-TOKEN');
--
-- ---------- to stop it ----------
--   select cron.unschedule('run-jps-logger');
