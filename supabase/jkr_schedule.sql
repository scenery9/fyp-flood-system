-- =====================================================================
-- Starts the JKR incident logger (GitHub Actions, .github/workflows/log_jkr.yml)
-- every hour from inside Supabase (pg_cron), at minute 27.
--
-- Why: GitHub's own schedule is best-effort (see logger_schedule.sql), and a new
-- scheduled workflow may not run at all for its first hour or more. The portal
-- only lists CURRENT incidents, so every missed hour can lose a short-lived flood.
-- The workflow's own schedule stays as a backup.
--
-- Needs: logger_schedule.sql run first (it turns on pg_cron and pg_net and stores
-- the GitHub token as 'github_actions_token' in Vault). This file has no secret in
-- it, so it is safe to commit.
-- How to use: Supabase dashboard -> SQL Editor -> paste this whole file -> Run.
-- =====================================================================

select cron.schedule(
  'run-jkr-logger',
  '27 * * * *',
  $$
  select net.http_post(
    url := 'https://api.github.com/repos/scenery9/fyp-flood-system/actions/workflows/log_jkr.yml/dispatches',
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
--   select status, return_message, start_time from cron.job_run_details
--   where jobid = (select jobid from cron.job where jobname = 'run-jkr-logger')
--   order by start_time desc limit 5;
-- Then GitHub -> Actions -> "Log JKR disaster incidents" shows a run every hour, and
--   select count(*), max(seen_at) from public.jkr_incident_seen;
-- grows by one sighting per listed incident each hour.
--
-- ---------- to stop it ----------
--   select cron.unschedule('run-jkr-logger');
