// The 15-minute push alert job. Called by pg_cron (supabase/alerts_schedule.sql).
//  1. alerts_tick()      -> which notifications are due (rules in supabase/alerts.sql)
//  2. send each one with Firebase
//  3. alerts_mark_sent() -> only for the ones Firebase accepted, so failures retry next run
//  4. alerts_drop_tokens() -> forget phones that uninstalled the app
import { alertText, type DueAlert, groupDue } from './alert_text.ts';
import { accessToken, readServiceAccount, sendPush } from './fcm.ts';
import { type Env, type Fetch, json, keyHeaders, rpc, sameSecret, serverKey } from './supabase_rest.ts';

export interface Deps {
  env: Env;
  fetch: Fetch;
  now: () => Date;
}

export async function handleSendAlerts(req: Request, deps: Deps): Promise<Response> {
  if (req.method !== 'POST') return json({ error: 'Use POST' }, 405);
  const expected = deps.env('ALERTS_CRON_SECRET');
  const given = req.headers.get('x-cron-secret') ?? '';
  if (!expected || expected.length < 20 || !sameSecret(given, expected)) {
    return json({ error: 'Not allowed' }, 401);
  }
  const base = deps.env('SUPABASE_URL');
  if (!base) return json({ error: 'SUPABASE_URL missing' }, 500);

  try {
    const headers = keyHeaders(serverKey(deps.env));
    const at = deps.now().toISOString();
    const due = (await rpc(deps.fetch, base, headers, 'alerts_tick', { p_now: at })) as DueAlert[];
    if (!Array.isArray(due) || due.length === 0) return json({ due: 0, sent: 0, failed: 0, dropped: 0 });

    const sa = readServiceAccount(deps.env('FIREBASE_SERVICE_ACCOUNT'));
    const token = await accessToken(deps.fetch, sa, Math.floor(deps.now().getTime() / 1000));

    const sentIds: string[] = [], sentLevels: string[] = [], gone = new Set<string>();
    let failed = 0;
    for (const group of groupDue(due)) {
      const first = group[0];
      if (gone.has(first.fcm_token)) continue;
      const { title, body } = alertText(group);
      const result = await sendPush(deps.fetch, sa, token, {
        fid: first.fcm_token,
        title,
        body,
        tag: `flood-${first.station_code}`,
        data: { station_code: first.station_code, level: first.level },
      });
      if (result === 'sent') {
        for (const r of group) {
          sentIds.push(r.rule_id);
          sentLevels.push(r.level);
        }
      } else if (result === 'gone') {
        gone.add(first.fcm_token);
      } else {
        failed++;
      }
    }
    if (sentIds.length) {
      await rpc(deps.fetch, base, headers, 'alerts_mark_sent', { p_rule_ids: sentIds, p_levels: sentLevels, p_now: at });
    }
    if (gone.size) await rpc(deps.fetch, base, headers, 'alerts_drop_tokens', { p_tokens: [...gone] });
    return json({ due: due.length, sent: sentIds.length, failed, dropped: gone.size });
  } catch (e) {
    // The message names the step that failed; it never includes keys or tokens.
    return json({ error: e instanceof Error ? e.message : 'Unexpected error' }, 500);
  }
}
