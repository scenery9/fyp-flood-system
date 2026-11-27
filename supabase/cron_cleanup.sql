-- =====================================================================
-- Weekly cleanup of pg_cron's run log (cron.job_run_details).
-- How to use: Supabase dashboard -> SQL Editor -> paste this whole file -> Run.
-- Run it once, after logger_schedule.sql. No secret in it; safe to commit.
--
-- Why: pg_cron writes one log row per scheduled run (JPS logger 96 a day, JKR
-- logger 24, alerts ...) and never removes them. This job deletes log rows older
-- than 7 days, every Sunday at 03:00 Malaysia time (Saturday 19:00 UTC; pg_cron
-- on Supabase runs in UTC).
--
-- What it touches: ONLY the cron run log (when each job ran, succeeded or failed).
-- No data table (readings, JKR incidents, weather, reports, ...) and no archive
-- file in data/ is affected. To keep more history, change '7 days' below.
-- =====================================================================

select cron.schedule(
  'cleanup-cron-log',
  '0 19 * * 6',
  $$ delete from cron.job_run_details where end_time < now() - interval '7 days' $$
);

-- ---------- checking it works ----------
--   select jobname, schedule, active from cron.job order by jobname;
--   select min(start_time), count(*) from cron.job_run_details;   -- oldest stays within ~2 weeks
--
-- ---------- to stop it ----------
--   select cron.unschedule('cleanup-cron-log');
