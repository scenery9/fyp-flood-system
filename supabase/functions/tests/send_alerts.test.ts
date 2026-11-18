// Tests for the send-alerts Edge Function logic. Run (Node 22.18+):
//   cd supabase/functions && node --test tests/
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { handleSendAlerts } from '../_shared/send_alerts.ts';
import { alertText, type DueAlert, groupDue } from '../_shared/alert_text.ts';
import { keyHeaders, serverKey } from '../_shared/supabase_rest.ts';

const SECRET = 'cron-secret-0123456789abcdef';

async function serviceAccount() {
  const pair = await crypto.subtle.generateKey(
    { name: 'RSASSA-PKCS1-v1_5', modulusLength: 2048, publicExponent: new Uint8Array([1, 0, 1]), hash: 'SHA-256' },
    true, ['sign', 'verify'],
  );
  const der = new Uint8Array(await crypto.subtle.exportKey('pkcs8', pair.privateKey));
  let bin = '';
  for (const b of der) bin += String.fromCharCode(b);
  const pem = `-----BEGIN PRIVATE KEY-----\n${btoa(bin).match(/.{1,64}/g)!.join('\n')}\n-----END PRIVATE KEY-----\n`;
  return { sa: { project_id: 'flood-demo', client_email: 'push@flood-demo.iam.gserviceaccount.com', private_key: pem }, pub: pair.publicKey };
}

function due(over: Partial<DueAlert> = {}): DueAlert {
  return {
    rule_id: 'r1', user_id: 'u1', fcm_token: 'tok-1', language: 'en', station_code: 'BKLG0002L',
    station_name: 'Taman Sri Muda', kind: 'risk', level: 'warning', level_m: 3.456, alert_level_m: null,
    reason: 'first', ...over,
  };
}

interface Call { url: string; init?: RequestInit; json?: any }
function fakeServer(opts: { due: DueAlert[]; push?: Record<string, number> }) {
  const calls: Call[] = [];
  const fetch = async (url: string, init?: RequestInit) => {
    const body = typeof init?.body === 'string' ? init.body : undefined;
    let parsed: any;
    try { parsed = body ? JSON.parse(body) : undefined; } catch { parsed = body; }
    calls.push({ url, init, json: parsed });
    if (url.endsWith('/rest/v1/rpc/alerts_tick')) return new Response(JSON.stringify(opts.due));
    if (url.endsWith('/rest/v1/rpc/alerts_mark_sent')) return new Response(null, { status: 204 });
    if (url.endsWith('/rest/v1/rpc/alerts_drop_tokens')) return new Response('1');
    if (url === 'https://oauth2.googleapis.com/token') return new Response(JSON.stringify({ access_token: 'google-token' }));
    if (url.includes('fcm.googleapis.com')) {
      const status = opts.push?.[parsed.message.fid] ?? 200;
      const text = status === 404 ? '{"error":{"status":"NOT_FOUND","details":[{"errorCode":"UNREGISTERED"}]}}' : '{}';
      return new Response(status === 200 ? '{"name":"projects/x/messages/1"}' : text, { status });
    }
    return new Response('not found', { status: 404 });
  };
  return { calls, fetch };
}

async function run(opts: { due: DueAlert[]; push?: Record<string, number>; secret?: string | null; env?: Record<string, string> }) {
  const { sa, pub } = await serviceAccount();
  const server = fakeServer(opts);
  const env: Record<string, string> = {
    SUPABASE_URL: 'https://demo.supabase.co',
    SUPABASE_SECRET_KEYS: JSON.stringify({ default: 'sb_secret_test' }),
    ALERTS_CRON_SECRET: SECRET,
    FIREBASE_SERVICE_ACCOUNT: JSON.stringify(sa),
    ...opts.env,
  };
  const headers: Record<string, string> = {};
  if (opts.secret !== null) headers['x-cron-secret'] = opts.secret ?? SECRET;
  const res = await handleSendAlerts(
    new Request('https://demo.supabase.co/functions/v1/send-alerts', { method: 'POST', headers }),
    { env: (k) => env[k], fetch: server.fetch as any, now: () => new Date('2026-11-18T03:00:00Z') },
  );
  return { res, body: await res.json(), calls: server.calls, pub, sa };
}

test('refuses callers without the cron secret, and touches nothing', async () => {
  for (const secret of [null, 'wrong', SECRET + 'x']) {
    const r = await run({ due: [due()], secret });
    assert.equal(r.res.status, 401);
    assert.equal(r.calls.length, 0);
  }
  const weak = await run({ due: [due()], env: { ALERTS_CRON_SECRET: 'short' }, secret: 'short' });
  assert.equal(weak.res.status, 401, 'a secret under 20 characters is never accepted');
});

test('nothing due: no Google calls', async () => {
  const r = await run({ due: [] });
  assert.equal(r.res.status, 200);
  assert.deepEqual(r.body, { due: 0, sent: 0, failed: 0, dropped: 0 });
  assert.deepEqual(r.calls.map((c) => c.url), ['https://demo.supabase.co/rest/v1/rpc/alerts_tick']);
  assert.equal(r.calls[0].json.p_now, '2026-11-18T03:00:00.000Z');
});

test('server key: new secret key in apikey only; legacy key also as Bearer', () => {
  assert.deepEqual(keyHeaders(serverKey((k) => ({ SUPABASE_SECRET_KEYS: '{"default":"sb_secret_x"}' } as any)[k])),
    { apikey: 'sb_secret_x', 'Content-Type': 'application/json' });
  const legacy = keyHeaders(serverKey((k) => ({ SUPABASE_SERVICE_ROLE_KEY: 'eyJlegacy' } as any)[k]));
  assert.equal(legacy.Authorization, 'Bearer eyJlegacy');
  assert.throws(() => serverKey(() => undefined));
});

test('sends one push per phone and station, then marks every rule in it as sent', async () => {
  const r = await run({
    due: [
      due({ rule_id: 'r1', kind: 'risk', level: 'warning' }),
      due({ rule_id: 'r2', kind: 'level', alert_level_m: 3.4 }),
      due({ rule_id: 'r3', user_id: 'u2', fcm_token: 'tok-2', language: 'ms', level: 'danger', reason: 'danger_repeat' }),
    ],
  });
  assert.equal(r.res.status, 200);
  assert.deepEqual(r.body, { due: 3, sent: 3, failed: 0, dropped: 0 });
  const pushes = r.calls.filter((c) => c.url.includes('fcm.googleapis.com'));
  assert.equal(pushes.length, 2);
  assert.equal(pushes[0].url, 'https://fcm.googleapis.com/v1/projects/flood-demo/messages:send');
  assert.equal((pushes[0].init!.headers as any).Authorization, 'Bearer google-token');
  const m = pushes[0].json.message;
  assert.equal(m.fid, 'tok-1', 'sent to the Firebase Installation ID (fid field)');
  assert.equal(m.token, undefined, 'not the deprecated token field');
  assert.equal(m.notification.title, 'Flood alert: Taman Sri Muda');
  assert.equal(m.notification.body, 'River is at Warning level (3.46 m). Follow JPS and NADMA instructions.');
  assert.equal(m.android.notification.tag, 'flood-BKLG0002L');
  assert.equal(m.android.priority, 'HIGH');
  assert.deepEqual(m.data, { station_code: 'BKLG0002L', level: 'warning' });
  assert.equal(pushes[1].json.message.notification.body,
    'Paras sungai masih di tahap Bahaya (3.46 m). Ikut arahan JPS dan NADMA.');
  const mark = r.calls.find((c) => c.url.endsWith('/alerts_mark_sent'))!;
  assert.deepEqual(mark.json, { p_rule_ids: ['r1', 'r2', 'r3'], p_levels: ['warning', 'warning', 'danger'], p_now: '2026-11-18T03:00:00.000Z' });
  assert.equal((mark.init!.headers as any).apikey, 'sb_secret_test');
});

test('the Google sign-in token is a valid RS256 JWT for Firebase Messaging', async () => {
  const r = await run({ due: [due()] });
  const tokenCall = r.calls.find((c) => c.url === 'https://oauth2.googleapis.com/token')!;
  const form = new URLSearchParams(tokenCall.init!.body as string);
  assert.equal(form.get('grant_type'), 'urn:ietf:params:oauth:grant-type:jwt-bearer');
  const [h, c, s] = form.get('assertion')!.split('.');
  const dec = (x: string) => JSON.parse(Buffer.from(x, 'base64url').toString());
  assert.deepEqual(dec(h), { alg: 'RS256', typ: 'JWT' });
  const claims = dec(c);
  assert.equal(claims.iss, 'push@flood-demo.iam.gserviceaccount.com');
  assert.equal(claims.scope, 'https://www.googleapis.com/auth/firebase.messaging');
  assert.equal(claims.aud, 'https://oauth2.googleapis.com/token');
  assert.equal(claims.exp - claims.iat, 3600);
  const ok = await crypto.subtle.verify('RSASSA-PKCS1-v1_5', r.pub, Buffer.from(s, 'base64url'), new TextEncoder().encode(`${h}.${c}`));
  assert.equal(ok, true);
});

test('uninstalled phones are dropped; failed sends are not marked, so they retry', async () => {
  const r = await run({
    due: [
      due({ rule_id: 'r1', fcm_token: 'gone-token' }),
      due({ rule_id: 'r2', user_id: 'u2', fcm_token: 'busy-token' }),
      due({ rule_id: 'r3', user_id: 'u3', fcm_token: 'ok-token' }),
    ],
    push: { 'gone-token': 404, 'busy-token': 503 },
  });
  assert.deepEqual(r.body, { due: 3, sent: 1, failed: 1, dropped: 1 });
  assert.deepEqual(r.calls.find((c) => c.url.endsWith('/alerts_mark_sent'))!.json.p_rule_ids, ['r3']);
  assert.deepEqual(r.calls.find((c) => c.url.endsWith('/alerts_drop_tokens'))!.json, { p_tokens: ['gone-token'] });
});

test('missing Firebase settings: error is reported, nothing marked as sent', async () => {
  const r = await run({ due: [due()], env: { FIREBASE_SERVICE_ACCOUNT: '' } });
  assert.equal(r.res.status, 500);
  assert.match(r.body.error, /FIREBASE_SERVICE_ACCOUNT/);
  assert.equal(r.calls.some((c) => c.url.endsWith('/alerts_mark_sent')), false);
});

test('message wording: height alerts, Chinese, and grouping keeps the highest risk level', () => {
  assert.deepEqual(alertText([due({ kind: 'level', alert_level_m: 3.4, level: 'alert' })]), {
    title: 'Flood alert: Taman Sri Muda',
    body: 'River has reached 3.46 m (your alert: 3.40 m). Level: Alert.',
  });
  assert.equal(alertText([due({ language: 'zh', level: 'danger' })]).body, '河流水位已达危险级（3.46 米）。请遵从JPS和NADMA的指示。');
  assert.equal(alertText([due({ language: 'xx' })]).title, 'Flood alert: Taman Sri Muda');
  const g = groupDue([due({ rule_id: 'a' }), due({ rule_id: 'b', station_code: 'OTHER' }), due({ rule_id: 'c', user_id: 'u9' })]);
  assert.equal(g.length, 3);
  assert.match(alertText([due({ kind: 'level', alert_level_m: 1 }), due({ level: 'danger' })]).body, /Danger level/);
});
