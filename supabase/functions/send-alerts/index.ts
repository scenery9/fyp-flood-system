// Edge Function: send due flood alerts. Deploy with:
//   npx supabase functions deploy send-alerts --no-verify-jwt
// It checks its own secret header (ALERTS_CRON_SECRET) instead of a user login.
import { handleSendAlerts } from '../_shared/send_alerts.ts';

Deno.serve((req) => handleSendAlerts(req, { env: (k) => Deno.env.get(k), fetch, now: () => new Date() }));
