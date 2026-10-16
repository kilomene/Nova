import { createRemoteJWKSet, jwtVerify } from 'jose';
import type { Env } from '../index';

let jwks: ReturnType<typeof createRemoteJWKSet> | null = null;

// Verifies a Firebase ID token using Google's public JWKS. Real verification,
// no Admin SDK needed. Throws with a clear message when the project id is unset.
export async function verifyFirebaseIdToken(token: string, env: Env): Promise<{ uid: string; email?: string }> {
  const projectId = env.FIREBASE_PROJECT_ID;
  if (!projectId || projectId.startsWith('REPLACE_')) {
    throw httpError(501, 'auth_not_configured: set FIREBASE_PROJECT_ID in wrangler.toml (see docs/SETUP.md)');
  }
  if (!jwks) {
    jwks = createRemoteJWKSet(
      new URL('https://www.googleapis.com/service_accounts/v1/jwk/securetoken@system.gserviceaccount.com'),
    );
  }
  try {
    const { payload } = await jwtVerify(token, jwks, {
      issuer: `https://securetoken.google.com/${projectId}`,
      audience: projectId,
    });
    if (!payload.sub) throw new Error('no sub');
    return { uid: payload.sub, email: (payload.email as string | undefined) ?? undefined };
  } catch {
    throw httpError(401, 'invalid_token');
  }
}

export async function requireUid(request: Request, env: Env): Promise<string> {
  const h = request.headers.get('Authorization') || '';
  const m = h.match(/^Bearer (.+)$/);
  if (!m) throw httpError(401, 'missing_bearer_token');
  const { uid } = await verifyFirebaseIdToken(m[1], env);
  return uid;
}

export function httpError(status: number, message: string): Error & { status: number } {
  const e = new Error(message) as Error & { status: number };
  e.status = status;
  return e;
}

export function json(data: unknown, status = 200): Response {
  return new Response(JSON.stringify(data), {
    status,
    headers: { 'content-type': 'application/json; charset=utf-8' },
  });
}

export async function readJson<T = Record<string, unknown>>(request: Request): Promise<T> {
  try {
    return (await request.json()) as T;
  } catch {
    throw httpError(400, 'invalid_json');
  }
}

export const now = () => Date.now();
export const newId = () => crypto.randomUUID().replace(/-/g, '');
