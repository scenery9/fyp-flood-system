// Tests for the route Edge Function logic. Run (Node 22.18+):
//   cd supabase/functions && node --test tests/
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { handleRoute, inMalaysia } from '../_shared/route.ts';

const KLANG = { lat: 3.04, lon: 101.45 }, SHAH_ALAM = { lat: 3.07, lon: 101.52 };
const ORS_REPLY = '{"type":"FeatureCollection","features":[]}';

interface Call { url: string; init?: RequestInit }
function setup(o: { allow?: unknown; allowStatus?: number; orsStatus?: number; orsBody?: string; orsThrows?: boolean } = {}) {
  const calls: Call[] = [];
  const fetch = async (url: string, init?: RequestInit) => {
    calls.push({ url, init });
    if (url.endsWith('/rest/v1/rpc/route_allow')) {
      return new Response(JSON.stringify(o.allow ?? true), { status: o.allowStatus ?? 200 });
    }
    if (url.startsWith('https://api.heigit.org/')) {
      if (o.orsThrows) throw new Error('timeout');
      return new Response(o.orsBody ?? ORS_REPLY, { status: o.orsStatus ?? 200 });
    }
    return new Response('?', { status: 404 });
  };
  const env: Record<string, string> = {
    SUPABASE_URL: 'https://demo.supabase.co',
    SUPABASE_PUBLISHABLE_KEYS: '{"default":"sb_publishable_x"}',
    ORS_API_KEY: 'ors-secret-key',
  };
  const call = async (body: unknown, headers: Record<string, string> = { Authorization: 'Bearer user-jwt' }, method = 'POST') => {
    const res = await handleRoute(new Request('https://demo.supabase.co/functions/v1/route', {
      method, headers, body: method === 'POST' ? (typeof body === 'string' ? body : JSON.stringify(body)) : undefined,
    }), { env: (k) => env[k], fetch: fetch as any });
    const text = await res.text();
    let json: any;
    try { json = JSON.parse(text); } catch { json = text; }
    return { status: res.status, json, text, headers: res.headers };
  };
  return { calls, call };
}

test('returns the openrouteservice route; the key never leaves the server', async () => {
  const s = setup();
  const r = await s.call({ from: KLANG, to: SHAH_ALAM, language: 'zh' });
  assert.equal(r.status, 200);
  assert.equal(r.text, ORS_REPLY);
  const allow = s.calls[0];
  assert.equal(allow.url, 'https://demo.supabase.co/rest/v1/rpc/route_allow');
  assert.equal((allow.init!.headers as any).Authorization, 'Bearer user-jwt', 'counted as the phone itself');
  assert.equal((allow.init!.headers as any).apikey, 'sb_publishable_x');
  const ors = s.calls[1];
  assert.equal(ors.url, 'https://api.heigit.org/openrouteservice/v2/directions/driving-car/geojson');
  assert.equal((ors.init!.headers as any).Authorization, 'ors-secret-key');
  const body = JSON.parse(ors.init!.body as string);
  assert.deepEqual(body.coordinates, [[101.45, 3.04], [101.52, 3.07]], 'longitude first');
  assert.equal(body.language, 'zh');
  assert.equal(body.instructions, true);
  assert.equal(r.text.includes('ors-secret-key'), false);
});

test('needs a login; a login the database rejects is refused', async () => {
  const none = setup();
  assert.equal((await none.call({ from: KLANG, to: SHAH_ALAM }, {})).status, 401);
  assert.equal(none.calls.length, 0);
  const bad = setup({ allowStatus: 401, allow: { message: 'JWT expired' } });
  const r = await bad.call({ from: KLANG, to: SHAH_ALAM });
  assert.equal(r.status, 401);
  assert.equal(bad.calls.length, 1, 'openrouteservice is never called');
});

test('over the limit: 429 with a message the app shows', async () => {
  const s = setup({ allow: false });
  const r = await s.call({ from: KLANG, to: SHAH_ALAM });
  assert.equal(r.status, 429);
  assert.match(r.json.error.message, /Too many route requests/);
  assert.equal(s.calls.length, 1);
});

test('bad requests are refused before anything is counted', async () => {
  for (const [body, why] of [
    ['not json', 'not JSON'],
    [{ from: KLANG }, 'no destination'],
    [{ from: { lat: '3', lon: 101 }, to: SHAH_ALAM }, 'text instead of a number'],
    [{ from: { lat: 51.5, lon: -0.1 }, to: SHAH_ALAM }, 'outside Malaysia'],
    [{ from: KLANG, to: { lat: 5.4, lon: 100.3 } }, 'Klang to Penang is over 150 km'],
  ] as const) {
    const s = setup();
    const r = await s.call(body);
    assert.equal(r.status, 400, why);
    assert.equal(s.calls.length, 0, why);
  }
  assert.equal(inMalaysia(1.29, 103.85), true, 'Singapore edge is inside the rough box (border trips)');
  assert.equal(inMalaysia(13.75, 100.5), false, 'Bangkok');
});

test('only known profiles and languages are passed on', async () => {
  const s = setup();
  await s.call({ from: KLANG, to: SHAH_ALAM, profile: 'cycling-road', language: 'de' });
  assert.match(s.calls[1].url, /\/driving-car\/geojson$/);
  assert.equal(JSON.parse(s.calls[1].init!.body as string).language, 'en');
  const walk = setup();
  await walk.call({ from: KLANG, to: SHAH_ALAM, profile: 'foot-walking' });
  assert.match(walk.calls[1].url, /\/foot-walking\/geojson$/);
});

test('openrouteservice problems become clear errors', async () => {
  let r = await setup({ orsStatus: 403 }).call({ from: KLANG, to: SHAH_ALAM });
  assert.equal(r.status, 503, 'quota used up');
  r = await setup({ orsStatus: 404, orsBody: '{"error":{"code":2010,"message":"Could not find routable point"}}' })
    .call({ from: KLANG, to: SHAH_ALAM });
  assert.equal(r.status, 502);
  assert.equal(r.json.error.message, 'Could not find routable point');
  r = await setup({ orsThrows: true }).call({ from: KLANG, to: SHAH_ALAM });
  assert.equal(r.status, 504);
});

test('missing server settings and browser preflight', async () => {
  const s = setup();
  const r = await s.call(undefined, {}, 'OPTIONS');
  assert.equal(r.status, 200);
  assert.equal(r.headers.get('access-control-allow-methods'), 'POST, OPTIONS');
  const res = await handleRoute(new Request('https://x/functions/v1/route', {
    method: 'POST', headers: { Authorization: 'Bearer t' }, body: JSON.stringify({ from: KLANG, to: SHAH_ALAM }),
  }), { env: () => undefined, fetch: (async () => new Response('')) as any });
  assert.equal(res.status, 500);
});
