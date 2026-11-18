// Calls the project's own database functions (PostgREST RPC) from an Edge Function.

export type Fetch = (input: string, init?: RequestInit) => Promise<Response>;
export type Env = (name: string) => string | undefined;

/** The secret (server) key: new sb_secret_ key if set, else the legacy service_role key. */
export function serverKey(env: Env): string {
  const keys = env('SUPABASE_SECRET_KEYS');
  if (keys) {
    try {
      const k = JSON.parse(keys)['default'];
      if (typeof k === 'string' && k) return k;
    } catch { /* fall through */ }
  }
  const legacy = env('SUPABASE_SERVICE_ROLE_KEY');
  if (!legacy) throw new Error('No server key: SUPABASE_SECRET_KEYS / SUPABASE_SERVICE_ROLE_KEY missing');
  return legacy;
}

/** The publishable (public) key: new sb_publishable_ key if set, else the legacy anon key. */
export function publicKey(env: Env): string {
  const keys = env('SUPABASE_PUBLISHABLE_KEYS');
  if (keys) {
    try {
      const k = JSON.parse(keys)['default'];
      if (typeof k === 'string' && k) return k;
    } catch { /* fall through */ }
  }
  const legacy = env('SUPABASE_ANON_KEY');
  if (!legacy) throw new Error('No public key: SUPABASE_PUBLISHABLE_KEYS / SUPABASE_ANON_KEY missing');
  return legacy;
}

/** Headers for a call with [key]. New-style keys go in apikey only; legacy JWT keys also as Bearer. */
export function keyHeaders(key: string): Record<string, string> {
  const h: Record<string, string> = { apikey: key, 'Content-Type': 'application/json' };
  if (!key.startsWith('sb_')) h['Authorization'] = `Bearer ${key}`;
  return h;
}

export class RpcError extends Error {
  status: number;
  constructor(message: string, status: number) {
    super(message);
    this.status = status;
  }
}

/** POST /rest/v1/rpc/<name>. Returns the JSON result (null for no content). */
export async function rpc(
  fetchFn: Fetch, baseUrl: string, headers: Record<string, string>, name: string, args: unknown,
): Promise<unknown> {
  const res = await fetchFn(`${baseUrl.replace(/\/+$/, '')}/rest/v1/rpc/${name}`, {
    method: 'POST',
    headers,
    body: JSON.stringify(args),
  });
  const text = await res.text();
  if (!res.ok) {
    let msg = `${name} failed (${res.status})`;
    try {
      const j = JSON.parse(text);
      if (typeof j?.message === 'string') msg = j.message;
    } catch { /* keep default */ }
    throw new RpcError(msg, res.status);
  }
  return text.trim() ? JSON.parse(text) : null;
}

/** Compares two secrets without leaking how many characters matched. */
export function sameSecret(a: string, b: string): boolean {
  const x = new TextEncoder().encode(a), y = new TextEncoder().encode(b);
  let diff = x.length ^ y.length;
  for (let i = 0; i < Math.max(x.length, y.length); i++) diff |= (x[i] ?? 0) ^ (y[i] ?? 0);
  return diff === 0;
}

export function json(body: unknown, status = 200, extra: Record<string, string> = {}): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { 'Content-Type': 'application/json', ...extra },
  });
}
