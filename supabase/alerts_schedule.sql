-- =====================================================================
-- Runs the push alert check every 15 minutes, inside Supabase (pg_cron).
-- This is more dependable than a GitHub schedule, which can start 15-30
-- minutes late or be skipped when GitHub is busy.
--
-- Before running this file:
--   1. alerts.sql has been run.
--   2. The Edge Function send-alerts is deployed, and its secrets are set
--      (ALERTS_CRON_SECRET and FIREBASE_SERVICE_ACCOUNT; see README, Round 6).
--
-- How to use: replace the TWO values marked <<< below, then
-- Supabase dashboard -> SQL Editor -> paste this whole file -> Run.
-- The values are stored in Supabase Vault (encrypted), not in this file.
-- Do NOT commit this file with your real secret in it.
-- =====================================================================

-- If these two lines give an error, turn on "pg_cron" and "pg_net" in
-- Dashboard -> Database -> Extensions instead, then run the rest.
create extension if not exists pg_cron;
create extension if not exists pg_net with schema extensions;

select vault.create_secret('https://YOUR-PROJECT-REF.supabase.co', 'project_url');   -- <<< your Project URL
select vault.create_secret('PASTE-YOUR-ALERTS_CRON_SECRET-HERE', 'alerts_cron_secret'); -- <<< same text as the function secret

-- Minutes 12, 27, 42 and 57: about 5 minutes after the logger's runs
-- (.github/workflows/log_jps.yml runs at 7, 22, 37 and 52).
select cron.schedule(
  'send-flood-alerts',
  '12,27,42,57 * * * *',
  $$
  select net.http_post(
    url := (select decrypted_secret from vault.decrypted_secrets where name = 'project_url')
           || '/functions/v1/send-alerts',
    headers := jsonb_build_object(
      'Content-Type', 'application/json',
      'x-cron-secret', (select decrypted_secret from vault.decrypted_secrets where name = 'alerts_cron_secret')),
    body := '{}'::jsonb,
    timeout_milliseconds := 30000
  );
  $$
);

-- ---------- checking it works ----------
-- Last runs of the schedule (status should be 'succeeded'):
--   select status, return_message, start_time from cron.job_run_details
--   where jobid = (select jobid from cron.job where jobname = 'send-flood-alerts')
--   order by start_time desc limit 5;
-- What the function answered (e.g. {"due":0,"sent":0,...}):
--   select status_code, content, created from net._http_response order by created desc limit 5;
--
-- ---------- to stop it ----------
--   select cron.unschedule('send-flood-alerts');
