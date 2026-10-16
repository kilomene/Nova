// FCM HTTP v1 sender. Needs a Firebase service-account JSON in the Workers
// secret FIREBASE_SERVICE_ACCOUNT. We mint an OAuth2 access token with a
// self-signed JWT (no firebase-admin dependency needed in Workers).
import { SignJWT, importPKCS8 } from 'jose';
import { httpError } from './auth';

interface ServiceAccount {
  client_email: string;
  private_key: string;
  project_id: string;
}

let cached: { token: string; exp: number } | null = null;

async function accessToken(sa: ServiceAccount): Promise<string> {
  if (cached && cached.exp > Date.now() + 60_000) return cached.token;
  const key = await importPKCS8(sa.private_key, 'RS256');
  const jwt = await new SignJWT({ scope: 'https://www.googleapis.com/auth/firebase.messaging' })
    .setProtectedHeader({ alg: 'RS256', typ: 'JWT' })
    .setIssuer(sa.client_email)
    .setSubject(sa.client_email)
    .setAudience('https://oauth2.googleapis.com/token')
    .setIssuedAt()
    .setExpirationTime('1h')
    .sign(key);
  const res = await fetch('https://oauth2.googleapis.com/token', {
    method: 'POST',
    headers: { 'content-type': 'application/x-www-form-urlencoded' },
    body: `grant_type=urn%3Aietf%3Aparams%3Aoauth%3Agrant-type%3Ajwt-bearer&assertion=${jwt}`,
  });
  if (!res.ok) throw httpError(502, 'fcm_token_exchange_failed');
  const data = (await res.json()) as { access_token: string; expires_in: number };
  cached = { token: data.access_token, exp: Date.now() + data.expires_in * 1000 };
  return cached.token;
}

export async function sendFcm(envSecret: string | undefined, token: string, title: string, body: string, data: Record<string, string> = {}) {
  if (!envSecret) throw httpError(501, 'fcm_not_configured: set FIREBASE_SERVICE_ACCOUNT (see docs/SETUP.md)');
  const sa = JSON.parse(envSecret) as ServiceAccount;
  const at = await accessToken(sa);
  const res = await fetch(`https://fcm.googleapis.com/v1/projects/${sa.project_id}/messages:send`, {
    method: 'POST',
    headers: { Authorization: `Bearer ${at}`, 'content-type': 'application/json' },
    body: JSON.stringify({ message: { token, notification: { title, body }, data } }),
  });
  if (!res.ok) {
    const t = await res.text();
    throw httpError(502, `fcm_send_failed: ${t.slice(0, 200)}`);
  }
  return res.json();
}
