// Road routes for the app. The openrouteservice key stays here (secret ORS_API_KEY).
// The caller must be signed in (the app's anonymous login); route_allow()
// (supabase/routing.sql) counts each request and refuses over the limits.
import { type Env, type Fetch, json, publicKey, rpc, RpcError } from './supabase_rest.ts';

export interface Deps {
  env: Env;
  fetch: Fetch;
}

const CORS = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, apikey, content-type, x-client-info',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
};
const PROFILES = new Set(['driving-car', 'foot-walking']);
// openrouteservice step languages we offer; anything else gets English.
const LANGUAGES = new Set(['en', 'zh']);
const ORS_URL = 'https://api.heigit.org/openrouteservice/v2/directions';

/** Roughly Malaysia (Peninsular and Borneo). Stops the key being used for other countries. */
export function inMalaysia(lat: number, lon: number): boolean {
  return lat >= 0.8 && lat <= 7.5 && lon >= 99.5 && lon <= 119.5;
}

export function distanceKm(aLat: number, aLon: number, bLat: number, bLon: number): number {
  const r = (d: number) => (d * Math.PI) / 180;
  const h = Math.sin(r(bLat - aLat) / 2) ** 2 +
    Math.cos(r(aLat)) * Math.cos(r(bLat)) * Math.sin(r(bLon - aLon) / 2) ** 2;
  return 2 * 6371 * Math.asin(Math.min(1, Math.sqrt(h)));
}

const point = (v: unknown): { lat: number; lon: number } | null => {
  if (typeof v !== 'object' || v === null) return null;
  const { lat, lon } = v as Record<string, unknown>;
  return typeof lat === 'number' && typeof lon === 'number' && Number.isFinite(lat) && Number.isFinite(lon)
    ? { lat, lon }
    : null;
};

/** Same shape as an openrouteservice error, so the app shows the message. */
const orsError = (status: number, message: string) => json({ error: { message } }, status, CORS);

export async function handleRoute(req: Request, deps: Deps): Promise<Response> {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: CORS });
  if (req.method !== 'POST') return orsError(405, 'Use POST');

  const auth = req.headers.get('authorization') ?? '';
  if (!/^Bearer\s+\S+$/i.test(auth)) return orsError(401, 'Sign in first');

  let input: Record<string, unknown>;
  try {
    input = await req.json();
  } catch {
    return orsError(400, 'Send JSON');
  }
  const from = point(input.from), to = point(input.to);
  if (!from || !to) return orsError(400, 'from and to need lat and lon');
  if (!inMalaysia(from.lat, from.lon) || !inMalaysia(to.lat, to.lon)) {
    return orsError(400, 'Routes are only available in Malaysia');
  }
  if (distanceKm(from.lat, from.lon, to.lat, to.lon) > 150) {
    return orsError(400, 'The destination is too far for a route (over 150 km)');
  }
  const profile = typeof input.profile === 'string' && PROFILES.has(input.profile) ? input.profile : 'driving-car';
  const language = typeof input.language === 'string' && LANGUAGES.has(input.language) ? input.language : 'en';

  const base = deps.env('SUPABASE_URL');
  const orsKey = deps.env('ORS_API_KEY');
  if (!base || !orsKey) return orsError(500, 'Routing is not set up on the server');

  // Checks the login (an invalid token is refused by the database API) and the limits.
  let allowed: unknown;
  try {
    allowed = await rpc(deps.fetch, base, {
      apikey: publicKey(deps.env),
      Authorization: auth,
      'Content-Type': 'application/json',
    }, 'route_allow', {});
  } catch (e) {
    if (e instanceof RpcError && (e.status === 401 || e.status === 403)) return orsError(401, 'Sign in first');
    return orsError(503, 'Routing is busy, try again soon');
  }
  if (allowed !== true) return orsError(429, 'Too many route requests. Try again in a minute.');

  let res: Response;
  try {
    res = await deps.fetch(`${ORS_URL}/${profile}/geojson`, {
      method: 'POST',
      headers: { Authorization: orsKey, 'Content-Type': 'application/json', Accept: 'application/geo+json' },
      body: JSON.stringify({
        coordinates: [[from.lon, from.lat], [to.lon, to.lat]],
        instructions: true,
        language,
        units: 'm',
      }),
      signal: AbortSignal.timeout(15000),
    });
  } catch {
    return orsError(504, 'The routing service did not answer');
  }
  const text = await res.text();
  if (res.ok) {
    return new Response(text, { status: 200, headers: { 'Content-Type': 'application/json', ...CORS } });
  }
  if (res.status === 403 || res.status === 429) return orsError(503, 'Routing is busy, try again later');
  let message = `Routing service error (${res.status})`;
  try {
    const m = JSON.parse(text)?.error?.message;
    if (typeof m === 'string' && m) message = m;
  } catch { /* keep default */ }
  return orsError(502, message);
}
