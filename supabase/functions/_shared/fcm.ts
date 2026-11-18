// Firebase Cloud Messaging, HTTP v1 API, with a service account. No libraries:
// the OAuth token is a JWT signed with the account's private key (WebCrypto).
import type { Fetch } from './supabase_rest.ts';

export interface ServiceAccount {
  project_id: string;
  client_email: string;
  private_key: string;
}

export function readServiceAccount(raw: string | undefined): ServiceAccount {
  if (!raw) throw new Error('FIREBASE_SERVICE_ACCOUNT is not set');
  const j = JSON.parse(raw);
  for (const k of ['project_id', 'client_email', 'private_key']) {
    if (typeof j[k] !== 'string' || !j[k]) throw new Error(`FIREBASE_SERVICE_ACCOUNT is missing ${k}`);
  }
  return j as ServiceAccount;
}

const b64url = (bytes: Uint8Array): string => {
  let s = '';
  for (const b of bytes) s += String.fromCharCode(b);
  return btoa(s).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
};
const b64urlText = (text: string) => b64url(new TextEncoder().encode(text));

function pemToDer(pem: string): ArrayBuffer {
  const body = pem.replace(/-----(BEGIN|END) PRIVATE KEY-----/g, '').replace(/\\n/g, '').replace(/\s+/g, '');
  const bin = atob(body);
  const out = new ArrayBuffer(bin.length);
  const view = new Uint8Array(out);
  for (let i = 0; i < bin.length; i++) view[i] = bin.charCodeAt(i);
  return out;
}

/** The signed JWT that is exchanged for an access token. */
export async function signedAssertion(sa: ServiceAccount, nowSeconds: number): Promise<string> {
  const header = b64urlText(JSON.stringify({ alg: 'RS256', typ: 'JWT' }));
  const claims = b64urlText(JSON.stringify({
    iss: sa.client_email,
    scope: 'https://www.googleapis.com/auth/firebase.messaging',
    aud: 'https://oauth2.googleapis.com/token',
    iat: nowSeconds,
    exp: nowSeconds + 3600,
  }));
  const key = await crypto.subtle.importKey(
    'pkcs8', pemToDer(sa.private_key), { name: 'RSASSA-PKCS1-v1_5', hash: 'SHA-256' }, false, ['sign'],
  );
  const sig = new Uint8Array(
    await crypto.subtle.sign('RSASSA-PKCS1-v1_5', key, new TextEncoder().encode(`${header}.${claims}`)),
  );
  return `${header}.${claims}.${b64url(sig)}`;
}

export async function accessToken(fetchFn: Fetch, sa: ServiceAccount, nowSeconds: number): Promise<string> {
  const assertion = await signedAssertion(sa, nowSeconds);
  const res = await fetchFn('https://oauth2.googleapis.com/token', {
    method: 'POST',
    headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
    body: new URLSearchParams({ grant_type: 'urn:ietf:params:oauth:grant-type:jwt-bearer', assertion }).toString(),
  });
  const j = await res.json().catch(() => ({}));
  if (!res.ok || typeof j.access_token !== 'string') {
    throw new Error(`Google sign-in for Firebase failed (${res.status})`);
  }
  return j.access_token;
}

export interface PushMessage {
  /** The phone's Firebase Installation ID (FID). */
  fid: string;
  title: string;
  body: string;
  /** Same tag = a newer alert replaces the older one on the phone. */
  tag: string;
  data: Record<string, string>;
}

/** 'sent', 'gone' (id no longer valid: remove it) or 'failed' (try again later). */
export type SendResult = 'sent' | 'gone' | 'failed';

export async function sendPush(
  fetchFn: Fetch, sa: ServiceAccount, token: string, m: PushMessage,
): Promise<SendResult> {
  let res: Response;
  try {
    res = await fetchFn(`https://fcm.googleapis.com/v1/projects/${sa.project_id}/messages:send`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', Authorization: `Bearer ${token}` },
      body: JSON.stringify({
        message: {
          fid: m.fid,
          notification: { title: m.title, body: m.body },
          data: m.data,
          android: { priority: 'HIGH', notification: { tag: m.tag } },
          apns: { headers: { 'apns-priority': '10' }, payload: { aps: { sound: 'default' } } },
        },
      }),
    });
  } catch {
    return 'failed';
  }
  if (res.ok) return 'sent';
  const text = await res.text().catch(() => '');
  if (res.status === 404 || text.includes('UNREGISTERED')) return 'gone';
  if (res.status === 400 && /registration token|installation id|"fid"/i.test(text)) return 'gone';
  return 'failed';
}
