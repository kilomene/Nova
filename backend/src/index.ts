// Nova backend API — Cloudflare Workers + D1 + R2 + Durable Objects.
// Security contract: SECURITY.md. Setup: docs/SETUP.md.
//
// Controls enforced here:
//  - Firebase ID-token auth on EVERY endpoint except /api/health.
//  - Per-IP + per-user rate limiting via the RateLimit Durable Object.
//  - Server-side network blacklist (VPN/proxy/Tor egress) checked in guard().
//  - Suspended/banned accounts are rejected in guard() (allowlisted paths only).
//  - Input validation on every parameter (see lib/validate.ts).
//  - 500s never leak internals (generic 'internal_error' to clients).
//  - Media served only via short-lived HMAC-signed URLs.
//  - Wallet keystore writes require verified KYC.
//  - LIVE requires 1000+ followers. Gifts move Nova Coin (not crypto):
//    sender debits the PURCHASE wallet; creator credits the EARNINGS wallet.
//  - DMs require the sender to follow the recipient.
//  - Comment spam: rate-limited + duplicate-pattern auto-flag.
//  - Admin routes use x-admin-key (ADMIN_REVIEW_KEY), never user auth.

import { SyncHub, publishToUser } from './do/sync';
import { RateLimit, rateCheck } from './do/ratelimit';
import { checkoutLink, flutterwaveCharge, flutterwaveVerify, verifyWebhookSignature } from './lib/flutterwave';
import { sendFcm } from './lib/fcm';
import { httpError, json, newId, now, readJson, requireUid } from './lib/auth';
import { ASSETS, FIATS, vEnum, vHandle, vInt, vNum, vOptStr, vStr, vStrList } from './lib/validate';
import { validateIdNumber, idSpecFor } from './lib/country_ids';
import { recordingStore } from './lib/recordings';

export { SyncHub, RateLimit };

export interface Env {
  DB: D1Database;
  MEDIA: R2Bucket;
  SYNC: DurableObjectNamespace;
  RATELIMIT: DurableObjectNamespace;
  FIREBASE_PROJECT_ID: string;
  APP_ORIGIN: string;
  FLUTTERWAVE_SECRET_KEY?: string;
  FLUTTERWAVE_SECRET_HASH?: string;
  FIREBASE_SERVICE_ACCOUNT?: string;
  MEDIA_SIGNING_SECRET?: string;
  ADMIN_REVIEW_KEY?: string;
  DROPBOX_ACCESS_TOKEN?: string;
}

// Nova Coin packages: USD -> coins (bonus on larger packs).
const COIN_PACKAGES = [
  { id: 'coins_500', usd: 5, coins: 500 },
  { id: 'coins_1100', usd: 10, coins: 1100 },
  { id: 'coins_3000', usd: 25, coins: 3000 },
] as const;

const VERIFY_PRICE_USD = 25;
const VERIFY_DAYS = 30;
const LIVE_MIN_FOLLOWERS = 1000;

function threadId(a: string, b: string) {
  return [a, b].sort().join('__');
}

// Paths a suspended/banned user may still call (appeals, status checks).
const STATUS_ALLOWLIST = ['/api/users/sync', '/api/strikes/me', '/api/support/tickets'];

// Promotion packages (module scope: used by the route and the webhook settler).
const PROMO_PACKAGES: Record<string, { amount: number; days: number; estReach: number }> = {
  starter: { amount: 7, days: 1, estReach: 1000 },
  growth: { amount: 25, days: 3, estReach: 3500 },
  scale: { amount: 70, days: 7, estReach: 10000 },
};

// Auth + rate limit + network-blacklist + account-status gate.
// Returns the verified uid.
async function guard(request: Request, env: Env, perMin = 240): Promise<string> {
  const ip = request.headers.get('cf-connecting-ip') || 'unknown-ip';
  await rateCheck(env.RATELIMIT, `ip:${ip}`, 600, 60);
  // Server-side anti-VPN layer: egress IP blacklist (auto + manual entries).
  const blocked = await env.DB.prepare('SELECT 1 FROM network_blacklist WHERE ip = ? AND (expires_at = 0 OR expires_at > ?)')
    .bind(ip, now())
    .first();
  if (blocked) throw httpError(403, 'network_blocked');
  const uid = await requireUid(request, env);
  await rateCheck(env.RATELIMIT, `uid:${uid}`, perMin, 60);
  const path = new URL(request.url).pathname;
  const allowlisted = STATUS_ALLOWLIST.some((p) => path === p || path.startsWith(p + '/'));
  if (!allowlisted) {
    const u = await env.DB.prepare('SELECT status FROM users WHERE uid = ?').bind(uid).first<{ status: string }>();
    const st = u?.status || 'active';
    if (st === 'banned') throw httpError(403, 'account_banned');
    if (st === 'suspended') throw httpError(403, 'account_suspended');
  }
  return uid;
}

// Idempotent schema guard for the is_ai_generated column (migration 001).
// The canonical migration lives in backend/migrations/; this guard keeps
// uploads working even if a deploy ever lands before the migration is run.
let aiColEnsured = false;
async function ensureAiColumn(db: D1Database): Promise<void> {
  if (aiColEnsured) return;
  try {
    await db.prepare('ALTER TABLE videos ADD COLUMN is_ai_generated INTEGER NOT NULL DEFAULT 0').run();
  } catch {
    // Column already exists.
  }
  aiColEnsured = true;
}

// coin_purchases maps each Flutterwave tx_ref to its buyer + package so the
// webhook/callback settler never has to parse underscores out of tx_refs
// (package ids like "coins_500" contain them). Same deploy-safety pattern.
let coinPurchasesEnsured = false;
async function ensureCoinPurchasesTable(db: D1Database): Promise<void> {
  if (coinPurchasesEnsured) return;
  await db.prepare(`CREATE TABLE IF NOT EXISTS coin_purchases (
    tx_ref TEXT PRIMARY KEY,
    uid TEXT NOT NULL,
    package_id TEXT NOT NULL,
    amount_usd REAL NOT NULL,
    created_at INTEGER NOT NULL
  )`).run();
  coinPurchasesEnsured = true;
}

// Admin gate: x-admin-key header. Used by the agent-run review console.
async function adminGuard(request: Request, env: Env): Promise<void> {
  await rateCheck(env.RATELIMIT, `ip:${request.headers.get('cf-connecting-ip') || 'x'}`, 30, 60);
  const key = request.headers.get('x-admin-key') || '';
  if (!env.ADMIN_REVIEW_KEY || key !== env.ADMIN_REVIEW_KEY) throw httpError(403, 'forbidden');
}

// Notify a user: realtime event + FCM push to registered devices.
async function notifyUser(env: Env, uid: string, title: string, body: string, data: Record<string, string> = {}): Promise<void> {
  await publishToUser(env, uid, { type: 'notify', title, body, ...data });
  try {
    const rows = await env.DB.prepare('SELECT token FROM push_tokens WHERE uid = ?').bind(uid).all<{ token: string }>();
    for (const r of rows.results) {
      try {
        await sendFcm(env.FIREBASE_SERVICE_ACCOUNT, r.token, title, body, data);
      } catch { /* per-device failure is not fatal */ }
    }
  } catch { /* push is best-effort */ }
}

async function earningsBalance(db: D1Database, uid: string): Promise<{ balance: number; lifetime: number }> {
  const r = await db.prepare('SELECT balance, lifetime_earned FROM creator_earnings_balances WHERE uid = ?').bind(uid).first<{ balance: number; lifetime_earned: number }>();
  return { balance: r?.balance ?? 0, lifetime: r?.lifetime_earned ?? 0 };
}

async function sellerStatus(db: D1Database, uid: string): Promise<string> {
  const r = await db.prepare('SELECT status FROM seller_profiles WHERE uid = ?').bind(uid).first<{ status: string }>();
  return r?.status || 'none';
}

// High-risk device (3+ suspensions): no LIVE, no selling, uploads held.
async function deviceRestricted(db: D1Database, uid: string): Promise<boolean> {
  const r = await db.prepare('SELECT suspensions FROM devices WHERE uid = ? ORDER BY last_seen DESC LIMIT 1').bind(uid).first<{ suspensions: number }>();
  return (r?.suspensions ?? 0) >= 3;
}

// SQL fragment: hide content from users in a blocking relationship with ? (either direction).
const BLOCK_FILTER = `v.uid NOT IN (SELECT blocked_uid FROM blocks WHERE blocker_uid = ?) AND v.uid NOT IN (SELECT blocker_uid FROM blocks WHERE blocked_uid = ?)`;

async function isBlockedEitherWay(db: D1Database, a: string, b: string): Promise<boolean> {
  const r = await db.prepare('SELECT 1 FROM blocks WHERE (blocker_uid = ? AND blocked_uid = ?) OR (blocker_uid = ? AND blocked_uid = ?)').bind(a, b, b, a).first();
  return !!r;
}

async function applySuspension(env: Env, uid: string, reason: string): Promise<void> {
  const t = now();
  await env.DB.prepare("UPDATE users SET status = 'suspended', updated_at = ? WHERE uid = ?").bind(t, uid).run();
  // Tie the suspension to the device for repeat-offender tracking.
  await env.DB.prepare('UPDATE devices SET suspensions = suspensions + 1, last_seen = ? WHERE uid = ?').bind(t, uid).run();
  await notifyUser(env, uid, 'Account suspended', `Your Nova account was suspended: ${reason}. You can appeal via Support.`, { kind: 'suspension' });
}

async function isVerified(db: D1Database, uid: string): Promise<boolean> {
  const r = await db
    .prepare("SELECT 1 FROM verification_subscriptions WHERE uid = ? AND status = 'active' AND expires_at > ?")
    .bind(uid, now())
    .first();
  return !!r;
}

// Reputation from real transactions (pillar 5). Review count + average rating
// feed the seller's trust score, which drives marketplace search ranking,
// featured/popular-seller placement, and badges.
async function updateSellerTrust(db: D1Database, sellerUid: string): Promise<void> {
  const agg = await db.prepare(
    'SELECT COUNT(*) as n, AVG(rating) as avg FROM reviews WHERE seller_uid = ?'
  ).bind(sellerUid).first<{ n: number; avg: number }>();
  const n = agg?.n ?? 0;
  const avg = agg?.avg ?? 0;
  // Trust score: 0-100. Weighted by count (more reviews = more confidence)
  // and average rating. 50+ reviews at 4.5+ = top tier.
  const countWeight = Math.min(n / 50, 1); // 0..1, saturates at 50 reviews
  const ratingScore = (avg / 5) * 100;     // 0..100
  const trust = Math.round(ratingScore * (0.4 + 0.6 * countWeight));
  const completed = await db.prepare(
    "SELECT COUNT(*) as c FROM orders WHERE seller_uid = ? AND status IN ('completed', 'delivered')"
  ).bind(sellerUid).first<{ c: number }>();
  await db.prepare(
    'UPDATE users SET trader_score = ?, trades_completed = ? WHERE uid = ?'
  ).bind(trust, completed?.c ?? 0, sellerUid).run();
}

async function kycStatus(db: D1Database, uid: string): Promise<string> {
  const r = await db.prepare('SELECT kyc_status FROM users WHERE uid = ?').bind(uid).first<{ kyc_status: string }>();
  return r?.kyc_status || 'none';
}

interface PublicUser {
  uid: string;
  handle: string;
  username: string;
  display_name: string;
  bio: string;
  avatar_url: string;
  kyc_status: string;
  status: string;
  is_bot: boolean;
  is_official: boolean;
  totp_enabled: boolean;
  trader_score: number;
  trades_completed: number;
  created_at: number;
  is_verified: boolean;
}

async function publicUser(db: D1Database, uidOrHandle: string): Promise<PublicUser | null> {
  const row = await db
    .prepare('SELECT uid, handle, username, display_name, bio, avatar_url, kyc_status, status, is_bot, is_official, totp_enabled, trader_score, trades_completed, created_at FROM users WHERE uid = ? OR handle = ? OR username = ?')
    .bind(uidOrHandle, uidOrHandle, uidOrHandle)
    .first<Record<string, unknown>>();
  if (!row) return null;
  const uid = row.uid as string;
  return {
    uid,
    handle: row.handle as string,
    username: (row.username as string) || '',
    display_name: (row.display_name as string) || '',
    bio: (row.bio as string) || '',
    avatar_url: (row.avatar_url as string) || '',
    kyc_status: (row.kyc_status as string) || 'none',
    status: (row.status as string) || 'active',
    is_bot: !!row.is_bot,
    is_official: !!row.is_official,
    totp_enabled: !!row.totp_enabled,
    trader_score: (row.trader_score as number) || 0,
    trades_completed: (row.trades_completed as number) || 0,
    created_at: (row.created_at as number) || 0,
    is_verified: (row.is_official ? true : await isVerified(db, uid)),
  };
}

async function followerCount(db: D1Database, uid: string): Promise<number> {
  const r = await db.prepare('SELECT COUNT(*) c FROM follows WHERE followee_uid = ?').bind(uid).first<{ c: number }>();
  return r?.c ?? 0;
}

async function coinBalance(db: D1Database, uid: string): Promise<number> {
  const r = await db.prepare('SELECT balance FROM nova_coin_balances WHERE uid = ?').bind(uid).first<{ balance: number }>();
  return r?.balance ?? 0;
}

// HMAC-signed media URL: /media/<key>?exp=<ms>&sig=<hex>
async function signMediaKey(secret: string | undefined, key: string, ttlMs = 15 * 60 * 1000): Promise<string> {
  if (!secret) throw httpError(501, 'media_signing_not_configured');
  const exp = now() + ttlMs;
  const msg = `${key}:${exp}`;
  const mac = await crypto.subtle.importKey('raw', new TextEncoder().encode(secret), { name: 'HMAC', hash: 'SHA-256' }, false, ['sign']);
  const sig = await crypto.subtle.sign('HMAC', mac, new TextEncoder().encode(msg));
  const hex = [...new Uint8Array(sig)].map((b) => b.toString(16).padStart(2, '0')).join('');
  return `/media/${encodeURIComponent(key)}?exp=${exp}&sig=${hex}`;
}

async function verifyMediaSig(secret: string | undefined, key: string, exp: string, sig: string): Promise<boolean> {
  if (!secret || !exp || !sig) return false;
  if (Number(exp) < now()) return false;
  const msg = `${key}:${exp}`;
  const mac = await crypto.subtle.importKey('raw', new TextEncoder().encode(secret), { name: 'HMAC', hash: 'SHA-256' }, false, ['sign']);
  const raw = await crypto.subtle.sign('HMAC', mac, new TextEncoder().encode(msg));
  const hex = [...new Uint8Array(raw)].map((b) => b.toString(16).padStart(2, '0')).join('');
  if (hex.length !== sig.length) return false;
  let diff = 0;
  for (let i = 0; i < hex.length; i++) diff |= hex.charCodeAt(i) ^ sig.charCodeAt(i);
  return diff === 0;
}

export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    const url = new URL(request.url);
    const path = url.pathname;
    const method = request.method;
    try {
      // ---------- health (only unauthenticated endpoint) ----------
      if (path === '/api/health' && method === 'GET') return json({ ok: true, ts: now() });

      // ---------- public avatar serving (no signing - avatars are public) ----------
      {
        const m = path.match(/^\/avatars\/(.+)$/);
        if (m && method === 'GET') {
          const key = 'avatars/' + decodeURIComponent(m[1]).replace(/^avatars\//, '');
          const obj = await env.MEDIA.get(key);
          if (!obj) throw httpError(404, 'not_found');
          const headers = new Headers();
          obj.writeHttpMetadata(headers);
          headers.set('cache-control', 'public, max-age=86400');
          return new Response(obj.body, { headers });
        }
      }

      // ---------- share links (public, no auth) ----------
      {
        const vm = path.match(/^\/v\/([A-Za-z0-9_-]+)$/);
        if (vm && method === 'GET') {
          const vid = vm[1];
          const html = `<!DOCTYPE html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>Nova Video</title><style>body{background:#000;color:#fff;font-family:system-ui;display:flex;flex-direction:column;align-items:center;justify-content:center;min-height:100vh;margin:0}img{width:120px;height:120px;border-radius:24px}a{background:#fff;color:#000;padding:14px 32px;border-radius:12px;text-decoration:none;font-weight:700;margin-top:24px}</style></head><body><img src="/avatars/nova-logo.png" alt="Nova"><h2>Watch on Nova</h2><p>Video ${vid}</p><a href="nova://v/${vid}">Open in Nova App</a></body></html>`;
          return new Response(html, { headers: { 'content-type': 'text/html; charset=utf-8' } });
        }
        const um = path.match(/^\/@([A-Za-z0-9_.-]+)$/) || path.match(/^\/([A-Za-z0-9_.-]+)$/);
        if (um && method === 'GET') {
          const handle = um[1];
          // Skip reserved paths - let them fall through to other handlers
          if (['api', 'avatars', 'media', 'v'].includes(handle)) {
            // do nothing, fall through
          } else {
          const row = await env.DB.prepare('SELECT display_name, avatar_url FROM users WHERE handle = ? OR username = ?').bind(handle, handle).first<{ display_name: string; avatar_url: string }>();
          const name = row?.display_name || ('@' + handle);
          const avatar = row?.avatar_url || '/avatars/nova-logo.png';
          const html = `<!DOCTYPE html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>${name} on Nova</title><style>body{background:#000;color:#fff;font-family:system-ui;display:flex;flex-direction:column;align-items:center;justify-content:center;min-height:100vh;margin:0}img{width:120px;height:120px;border-radius:60px}a{background:#fff;color:#000;padding:14px 32px;border-radius:12px;text-decoration:none;font-weight:700;margin-top:24px}</style></head><body><img src="${avatar}" alt="${name}"><h2>${name}</h2><p>@${handle}</p><a href="nova://@${handle}">Open in Nova App</a></body></html>`;
          return new Response(html, { headers: { 'content-type': 'text/html; charset=utf-8' } });
          }
        }
      }

      // ---------- signed media serving ----------
      {
        const m = path.match(/^\/media\/(.+)$/);
        if (m && method === 'GET') {
          const key = decodeURIComponent(m[1]);
          const ok = await verifyMediaSig(env.MEDIA_SIGNING_SECRET, key, url.searchParams.get('exp') || '', url.searchParams.get('sig') || '');
          if (!ok) throw httpError(403, 'bad_or_expired_media_url');
          await rateCheck(env.RATELIMIT, `ip:${request.headers.get('cf-connecting-ip') || 'x'}`, 600, 60);
          const obj = await env.MEDIA.get(key);
          if (!obj) throw httpError(404, 'not_found');
          const headers = new Headers();
          obj.writeHttpMetadata(headers);
          headers.set('cache-control', 'private, max-age=900');
          return new Response(obj.body, { headers });
        }
      }
      if (path === '/api/media/url' && method === 'GET') {
        const uid = await guard(request, env);
        const key = vStr(url.searchParams.get('key'), 'key', 1, 300);
        return json({ url: await signMediaKey(env.MEDIA_SIGNING_SECRET, key) });
      }

      // ---------- realtime socket ----------
      if (path === '/api/sync/ws' && method === 'GET') {
        if (request.headers.get('Upgrade') !== 'websocket') return new Response('expected websocket', { status: 426 });
        await rateCheck(env.RATELIMIT, `ip:${request.headers.get('cf-connecting-ip') || 'x'}`, 60, 60);
        const { verifyFirebaseIdToken } = await import('./lib/auth');
        let uid = '';
        try {
          uid = (await verifyFirebaseIdToken(url.searchParams.get('token') || '', env)).uid;
        } catch {
          return new Response('unauthorized', { status: 401 });
        }
        return env.SYNC.get(env.SYNC.idFromName(`user:${uid}`)).fetch(request);
      }

      // ---------- users ----------
      if (path === '/api/users/sync' && method === 'POST') {
        const uid = await guard(request, env);
        const b = await readJson(request);
        const handle = vHandle((b as Record<string, unknown>).handle || `user_${uid.slice(0, 8)}`);
        const username = vOptStr((b as Record<string, unknown>).username, 'username', 30);
        const displayName = vOptStr((b as Record<string, unknown>).displayName, 'displayName', 60);
        const avatarUrl = vOptStr((b as Record<string, unknown>).avatarUrl, 'avatarUrl', 500);
        const deviceId = vOptStr((b as Record<string, unknown>).deviceId, 'deviceId', 64);
        const country = vOptStr((b as Record<string, unknown>).country, 'country', 2).toUpperCase();
        const email = vOptStr((b as Record<string, unknown>).email, 'email', 320);
        const t = now();
        const isNew = !(await env.DB.prepare('SELECT 1 FROM users WHERE uid = ?').bind(uid).first());
        if (isNew) {
          try {
            await env.DB.prepare(
              `INSERT INTO users (uid, handle, username, display_name, avatar_url, country, email, created_at, updated_at)
               VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)`
            )
              .bind(uid, handle, username || null, displayName, avatarUrl, country, email || null, t, t)
              .run();
          } catch {
            throw httpError(409, 'handle_taken');
          }
        } else {
          // Existing user: update profile fields in place. (A bare INSERT..ON CONFLICT(uid)
          // would still trip the handle UNIQUE index when the proposed handle already exists.)
          // avatar_url is only overwritten when a non-empty value is sent — the app
          // calls sync on every launch without an avatar, which used to wipe it.
          await env.DB.prepare(
            `UPDATE users SET display_name = ?,
               avatar_url = CASE WHEN ? != '' THEN ? ELSE avatar_url END,
               country = CASE WHEN ? != '' THEN ? ELSE country END,
               email = COALESCE(?, email), username = COALESCE(?, username), updated_at = ? WHERE uid = ?`
          )
            .bind(displayName, avatarUrl, avatarUrl, country, country, email || null, username || null, t, uid)
            .run();
        }
        if (isNew) {
          // Every new user auto-follows the official @nova company account
          // (idempotent INSERT OR IGNORE). Prefer the canonical @nova uid;
          // fall back to the is_official flag if that row is ever reseeded.
          const NOVA_UID = 'wkx3Pte47Aa66fSVyPUE4raZcii2';
          const novaRow = await env.DB.prepare('SELECT uid FROM users WHERE uid = ?').bind(NOVA_UID).first<{ uid: string }>();
          const official = novaRow
            ?? await env.DB.prepare('SELECT uid FROM users WHERE is_official = 1 LIMIT 1').first<{ uid: string }>();
          if (official && official.uid !== uid) {
            await env.DB.prepare('INSERT OR IGNORE INTO follows (follower_uid, followee_uid, created_at) VALUES (?, ?, ?)')
              .bind(uid, official.uid, t)
              .run();
          }
        }
        if (deviceId) {
          // Record the device for repeat-offender tracking (one row per device).
          await env.DB.prepare('INSERT INTO devices (device_id, uid, last_seen) VALUES (?, ?, ?) ON CONFLICT(device_id) DO UPDATE SET uid=excluded.uid, last_seen=excluded.last_seen')
            .bind(deviceId, uid, t)
            .run();
        }
        return json({ user: await publicUser(env.DB, uid) });
      }
      // ---------- auth: username/email login + TOTP 2FA ----------
      // Username -> email resolution for Firebase password sign-in.
      // Pre-auth by design (login flow); strictly rate-limited. Exact match
      // only — this is the standard username-enumeration tradeoff.
      if (path === '/api/auth/resolve' && method === 'POST') {
        await rateCheck(env.RATELIMIT, `ip:${request.headers.get('cf-connecting-ip') || 'x'}`, 10, 60);
        const b = await readJson(request) as Record<string, unknown>;
        const identifier = vStr(b.identifier, 'identifier', 1, 320);
        if (identifier.includes('@')) return json({ email: identifier.toLowerCase(), totpRequired: false });
        const row = await env.DB.prepare('SELECT email, totp_enabled FROM users WHERE username = ? OR handle = ?')
          .bind(identifier.toLowerCase(), identifier.toLowerCase()).first<{ email: string | null; totp_enabled: number }>();
        if (!row?.email) throw httpError(404, 'account_not_found');
        return json({ email: row.email, totpRequired: !!row.totp_enabled });
      }
      // TOTP setup: returns otpauth URI + secret (shown once as QR).
      if (path === '/api/auth/totp/setup' && method === 'POST') {
        const uid = await guard(request, env, 20);
        const { randomBase32, otpauthUri, encryptSecret } = await import('./lib/totp');
        if (!env.MEDIA_SIGNING_SECRET) throw httpError(501, 'server_misconfigured');
        const secret = randomBase32();
        const enc = await encryptSecret(secret, env.MEDIA_SIGNING_SECRET);
        await env.DB.prepare('UPDATE users SET totp_secret = ?, totp_enabled = 0 WHERE uid = ?').bind(enc, uid).run();
        const u = await env.DB.prepare('SELECT handle FROM users WHERE uid = ?').bind(uid).first<{ handle: string }>();
        return json({ otpauthUri: otpauthUri(secret, u?.handle || uid), secret });
      }
      // TOTP verify: confirms the code and enables 2FA.
      if (path === '/api/auth/totp/verify' && method === 'POST') {
        const uid = await guard(request, env, 20);
        const b = await readJson(request) as Record<string, unknown>;
        const code = vStr(b.code, 'code', 6, 6);
        const { verifyTotp, decryptSecret } = await import('./lib/totp');
        if (!env.MEDIA_SIGNING_SECRET) throw httpError(501, 'server_misconfigured');
        const row = await env.DB.prepare('SELECT totp_secret FROM users WHERE uid = ?').bind(uid).first<{ totp_secret: string | null }>();
        if (!row?.totp_secret) throw httpError(400, 'totp_not_set_up');
        const secret = await decryptSecret(row.totp_secret, env.MEDIA_SIGNING_SECRET);
        if (!(await verifyTotp(secret, code))) throw httpError(400, 'invalid_code');
        await env.DB.prepare('UPDATE users SET totp_enabled = 1 WHERE uid = ?').bind(uid).run();
        return json({ enabled: true });
      }
      // TOTP disable (requires a valid code).
      if (path === '/api/auth/totp/disable' && method === 'POST') {
        const uid = await guard(request, env, 20);
        const b = await readJson(request) as Record<string, unknown>;
        const code = vStr(b.code, 'code', 6, 6);
        const { verifyTotp, decryptSecret } = await import('./lib/totp');
        if (!env.MEDIA_SIGNING_SECRET) throw httpError(501, 'server_misconfigured');
        const row = await env.DB.prepare('SELECT totp_secret FROM users WHERE uid = ?').bind(uid).first<{ totp_secret: string | null }>();
        if (!row?.totp_secret) throw httpError(400, 'totp_not_set_up');
        const secret = await decryptSecret(row.totp_secret, env.MEDIA_SIGNING_SECRET);
        if (!(await verifyTotp(secret, code))) throw httpError(400, 'invalid_code');
        await env.DB.prepare('UPDATE users SET totp_secret = NULL, totp_enabled = 0 WHERE uid = ?').bind(uid).run();
        return json({ enabled: false });
      }
      // TOTP login challenge (pre-auth, after Firebase password sign-in).
      if (path === '/api/auth/totp/challenge' && method === 'POST') {
        await rateCheck(env.RATELIMIT, `ip:${request.headers.get('cf-connecting-ip') || 'x'}`, 10, 60);
        const b = await readJson(request) as Record<string, unknown>;
        const uid = vStr(b.uid, 'uid', 1, 128);
        const code = vStr(b.code, 'code', 6, 6);
        const { verifyTotp, decryptSecret } = await import('./lib/totp');
        if (!env.MEDIA_SIGNING_SECRET) throw httpError(501, 'server_misconfigured');
        const row = await env.DB.prepare('SELECT totp_secret, totp_enabled FROM users WHERE uid = ?').bind(uid).first<{ totp_secret: string | null; totp_enabled: number }>();
        if (!row?.totp_enabled || !row.totp_secret) return json({ ok: true, required: false });
        const secret = await decryptSecret(row.totp_secret, env.MEDIA_SIGNING_SECRET);
        if (!(await verifyTotp(secret, code))) throw httpError(400, 'invalid_code');
        return json({ ok: true, required: true });
      }
      {
        const m = path.match(/^\/api\/users\/([^/]+)$/);
        if (m && method === 'GET') {
          const uid = await guard(request, env);
          const user = await publicUser(env.DB, decodeURIComponent(m[1]));
          if (!user) throw httpError(404, 'user_not_found');
          if (user.uid !== uid && await isBlockedEitherWay(env.DB, uid, user.uid)) throw httpError(403, 'blocked');
          const [v, fl, fg] = await Promise.all([
            env.DB.prepare('SELECT COUNT(*) c FROM videos WHERE uid = ?').bind(user.uid).first<{ c: number }>(),
            env.DB.prepare('SELECT COUNT(*) c FROM follows WHERE followee_uid = ?').bind(user.uid).first<{ c: number }>(),
            env.DB.prepare('SELECT COUNT(*) c FROM follows WHERE follower_uid = ?').bind(user.uid).first<{ c: number }>(),
          ]);
          return json({ user, counts: { videos: v?.c ?? 0, followers: fl?.c ?? 0, following: fg?.c ?? 0 } });
        }
      }
      {
        const m = path.match(/^\/api\/users\/([^/]+)\/follow$/);
        if (m && (method === 'POST' || method === 'DELETE')) {
          const uid = await guard(request, env, 120);
          const target = await env.DB.prepare('SELECT uid FROM users WHERE uid = ? OR handle = ?').bind(m[1], m[1]).first<{ uid: string }>();
          if (!target) throw httpError(404, 'user_not_found');
          if (target.uid === uid) throw httpError(400, 'cannot_follow_self');
          if (method === 'POST') {
            await env.DB.prepare('INSERT OR IGNORE INTO follows (follower_uid, followee_uid, created_at) VALUES (?, ?, ?)').bind(uid, target.uid, now()).run();
          } else {
            await env.DB.prepare('DELETE FROM follows WHERE follower_uid = ? AND followee_uid = ?').bind(uid, target.uid).run();
          }
          return json({ following: method === 'POST' });
        }
      }
      // ---------- blocking ----------
      {
        const m = path.match(/^\/api\/blocks\/([^/]+)$/);
        if (m && (method === 'POST' || method === 'DELETE')) {
          const uid = await guard(request, env, 60);
          const target = await env.DB.prepare('SELECT uid, is_official FROM users WHERE uid = ? OR handle = ?').bind(m[1], m[1]).first<{ uid: string; is_official: number }>();
          if (!target) throw httpError(404, 'user_not_found');
          if (target.uid === uid) throw httpError(400, 'cannot_block_self');
          if (target.is_official === 1) throw httpError(400, 'cannot_block_official_account');
          if (method === 'POST') {
            await env.DB.batch([
              env.DB.prepare('INSERT OR IGNORE INTO blocks (blocker_uid, blocked_uid, created_at) VALUES (?, ?, ?)').bind(uid, target.uid, now()),
              // Blocking severs the follow graph both ways.
              env.DB.prepare('DELETE FROM follows WHERE (follower_uid = ? AND followee_uid = ?) OR (follower_uid = ? AND followee_uid = ?)').bind(uid, target.uid, target.uid, uid),
            ]);
          } else {
            await env.DB.prepare('DELETE FROM blocks WHERE blocker_uid = ? AND blocked_uid = ?').bind(uid, target.uid).run();
          }
          return json({ blocked: method === 'POST' });
        }
      }
      if (path === '/api/blocks' && method === 'GET') {
        const uid = await guard(request, env);
        const rows = await env.DB.prepare('SELECT u.uid, u.handle, u.display_name FROM blocks b JOIN users u ON u.uid = b.blocked_uid WHERE b.blocker_uid = ?').bind(uid).all();
        return json({ blocked: rows.results });
      }

      // ---------- KYC (wallet unlocks only after verified) ----------
      if (path === '/api/kyc/submit' && method === 'POST') {
        const uid = await guard(request, env, 20);
        const b = await readJson(request) as Record<string, unknown>;
        const front = vStr(b.docFrontKey, 'docFrontKey', 1, 300);
        const back = vStr(b.docBackKey, 'docBackKey', 1, 300);
        const selfie = vStr(b.selfieKey, 'selfieKey', 1, 300);
        const t = now();
        await env.DB.batch([
          env.DB.prepare('INSERT INTO kyc_submissions (uid, status, doc_front_key, doc_back_key, selfie_key, created_at, updated_at) VALUES (?, ?, ?, ?, ?, ?, ?) ON CONFLICT(uid) DO UPDATE SET status=?, doc_front_key=?, doc_back_key=?, selfie_key=?, updated_at=?')
            .bind(uid, 'pending', front, back, selfie, t, t, 'pending', front, back, selfie, t),
          env.DB.prepare("UPDATE users SET kyc_status = 'pending', updated_at = ? WHERE uid = ?").bind(t, uid),
        ]);
        // v1: verification itself is manual review (see /api/kyc/review + docs/SETUP.md).
        return json({ status: 'pending' });
      }
      if (path === '/api/kyc/status' && method === 'GET') {
        const uid = await guard(request, env);
        const sub = await env.DB.prepare('SELECT status, reviewer_note, updated_at FROM kyc_submissions WHERE uid = ?').bind(uid).first();
        return json({ kyc_status: await kycStatus(env.DB, uid), submission: sub || null });
      }
      if (path === '/api/kyc/review' && method === 'POST') {
        // Manual-review back office: protected by ADMIN_REVIEW_KEY, NOT by user auth.
        await rateCheck(env.RATELIMIT, `ip:${request.headers.get('cf-connecting-ip') || 'x'}`, 30, 60);
        const key = request.headers.get('x-admin-key') || '';
        if (!env.ADMIN_REVIEW_KEY || key !== env.ADMIN_REVIEW_KEY) throw httpError(403, 'forbidden');
        const b = await readJson(request) as Record<string, unknown>;
        const target = vStr(b.uid, 'uid', 1, 128);
        const decision = vEnum(b.decision, ['verified', 'rejected'] as const, 'decision');
        const note = vOptStr(b.note, 'note', 300);
        const t = now();
        await env.DB.batch([
          env.DB.prepare('UPDATE kyc_submissions SET status = ?, reviewer_note = ?, updated_at = ? WHERE uid = ?').bind(decision, note, t, target),
          env.DB.prepare('UPDATE users SET kyc_status = ?, updated_at = ? WHERE uid = ?').bind(decision, t, target),
        ]);
        await publishToUser(env, target, { type: 'kyc', status: decision });
        return json({ uid: target, kyc_status: decision });
      }

      // ---------- keystore (opaque ciphertext ONLY; KYC-gated) ----------
      if (path === '/api/keystore' && method === 'POST') {
        const uid = await guard(request, env, 10);
        if ((await kycStatus(env.DB, uid)) !== 'verified') throw httpError(403, 'kyc_required');
        const b = await readJson(request) as Record<string, unknown>;
        if (!b.bundle || typeof b.bundle !== 'object') throw httpError(400, 'bundle_required');
        const s = JSON.stringify(b.bundle);
        if (s.length > 16_384) throw httpError(413, 'bundle_too_large');
        if (/["':\s][0-9a-fA-F]{64}["',\s}]/.test(s)) throw httpError(400, 'plaintext_key_rejected');
        await env.DB.prepare('INSERT INTO keystores (uid, bundle, updated_at) VALUES (?, ?, ?) ON CONFLICT(uid) DO UPDATE SET bundle=excluded.bundle, updated_at=excluded.updated_at')
          .bind(uid, s, now())
          .run();
        return json({ ok: true });
      }
      if (path === '/api/keystore' && method === 'GET') {
        const uid = await guard(request, env, 30);
        const row = await env.DB.prepare('SELECT bundle FROM keystores WHERE uid = ?').bind(uid).first<{ bundle: string }>();
        return json({ bundle: row ? JSON.parse(row.bundle) : null, kyc_status: await kycStatus(env.DB, uid) });
      }

      // ---------- Nova Coin ----------
      if (path === '/api/coins/balance' && method === 'GET') {
        const uid = await guard(request, env);
        return json({ balance: await coinBalance(env.DB, uid) });
      }
      if (path === '/api/coins/packages' && method === 'GET') {
        await guard(request, env);
        return json({ packages: COIN_PACKAGES });
      }
      if (path === '/api/coins/buy' && method === 'POST') {
        const uid = await guard(request, env, 20);
        const b = await readJson(request) as Record<string, unknown>;
        const pkg = COIN_PACKAGES.find((p) => p.id === b.packageId);
        if (!pkg) throw httpError(400, 'unknown_package');
        const email = vStr(b.email, 'email', 3, 120);
        if (!/^[^@\s]+@[^@\s]+\.[^@\s]+$/.test(email)) throw httpError(400, 'email_invalid');
        await ensureCoinPurchasesTable(env.DB);
        // tx_ref embeds uid/package for humans; the MACHINE source of truth is
        // coin_purchases (package ids contain underscores, so tx_ref is never parsed).
        const txRef = `nova_coins_${uid}_${pkg.id}_${newId()}`;
        await env.DB.prepare(
          'INSERT OR IGNORE INTO coin_purchases (tx_ref, uid, package_id, amount_usd, created_at) VALUES (?, ?, ?, ?, ?)',
        ).bind(txRef, uid, pkg.id, pkg.usd, now()).run();
        const data = await flutterwaveCharge(env.FLUTTERWAVE_SECRET_KEY, {
          amount: pkg.usd,
          currency: 'USD',
          email,
          tx_ref: txRef,
          redirectUrl: `${new URL(request.url).origin}/api/payments/callback`,
        });
        // flutterwaveCharge throws checkout_unavailable unless the response
        // carries a real hosted-checkout link — no silent null-link 200s.
        return json({ checkoutUrl: checkoutLink(data), txRef, flutterwave: data, package: pkg });
      }
      if (path === '/api/coins/ledger' && method === 'GET') {
        const uid = await guard(request, env);
        const rows = await env.DB.prepare('SELECT id, delta, reason, ref, created_at FROM nova_coin_ledger WHERE uid = ? ORDER BY created_at DESC LIMIT 50').bind(uid).all();
        return json({ entries: rows.results });
      }

      // ---------- gifts (Nova Coin; NOT crypto) ----------
      if (path === '/api/gifts/catalog' && method === 'GET') {
        await guard(request, env);
        const rows = await env.DB.prepare('SELECT id, name, coin_price, creator_share, animation FROM gift_catalog ORDER BY coin_price ASC').all();
        return json({ gifts: rows.results });
      }
      if (path === '/api/gifts/send' && method === 'POST') {
        const uid = await guard(request, env, 30);
        const b = await readJson(request) as Record<string, unknown>;
        const recipientUid = vStr(b.recipientUid, 'recipientUid', 1, 128);
        const giftId = vStr(b.giftId, 'giftId', 1, 40);
        const liveSessionId = vOptStr(b.liveSessionId, 'liveSessionId', 64);
        if (recipientUid === uid) throw httpError(400, 'cannot_gift_self'); // self-gifting blocked: kills cash-out gaming
        const gift = await env.DB.prepare('SELECT * FROM gift_catalog WHERE id = ?').bind(giftId).first<{ coin_price: number; creator_share: number }>();
        if (!gift) throw httpError(404, 'gift_not_found');
        const recipient = await env.DB.prepare('SELECT uid FROM users WHERE uid = ?').bind(recipientUid).first();
        if (!recipient) throw httpError(404, 'recipient_not_found');
        const t = now();
        const gid = newId();
        // Atomic debit from the sender's PURCHASE wallet (spend-only, never withdrawable).
        await env.DB.prepare('INSERT OR IGNORE INTO nova_coin_balances (uid, balance, updated_at) VALUES (?, 0, ?)').bind(uid, t).run();
        const debit = await env.DB.prepare('UPDATE nova_coin_balances SET balance = balance - ?, updated_at = ? WHERE uid = ? AND balance >= ?')
          .bind(gift.coin_price, t, uid, gift.coin_price)
          .run();
        if ((debit.meta as unknown as { changes: number }).changes !== 1) throw httpError(402, 'insufficient_coins');
        // Creator share lands in the EARNINGS wallet (payout path), NOT the purchase wallet.
        await env.DB.batch([
          env.DB.prepare('INSERT INTO nova_coin_ledger (id, uid, delta, reason, ref, created_at) VALUES (?, ?, ?, ?, ?, ?)').bind(newId(), uid, -gift.coin_price, 'gift_sent', gid, t),
          env.DB.prepare('INSERT OR IGNORE INTO creator_earnings_balances (uid, balance, lifetime_earned, updated_at) VALUES (?, 0, 0, ?)').bind(recipientUid, t),
          env.DB.prepare('UPDATE creator_earnings_balances SET balance = balance + ?, lifetime_earned = lifetime_earned + ?, updated_at = ? WHERE uid = ?').bind(gift.creator_share, gift.creator_share, t, recipientUid),
          env.DB.prepare('INSERT INTO creator_earnings_ledger (id, uid, delta, reason, ref, created_at) VALUES (?, ?, ?, ?, ?, ?)').bind(newId(), recipientUid, gift.creator_share, 'gift_received', gid, t),
          env.DB.prepare('INSERT INTO gift_transactions (id, sender_uid, recipient_uid, gift_id, live_session_id, coins_spent, coins_credited, created_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?)')
            .bind(gid, uid, recipientUid, giftId, liveSessionId, gift.coin_price, gift.creator_share, t),
        ]);
        const event = { type: 'gift', giftId, senderUid: uid, liveSessionId, createdAt: t };
        await publishToUser(env, recipientUid, event);
        return json({ ok: true, giftId, coinsSpent: gift.coin_price }, 201);
      }

      // ---------- creator earnings wallet (payout path) ----------
      if (path === '/api/earnings/balance' && method === 'GET') {
        const uid = await guard(request, env);
        const e = await earningsBalance(env.DB, uid);
        return json({ balance: e.balance, lifetimeEarned: e.lifetime, usdValue: e.balance / 100 });
      }
      if (path === '/api/earnings/ledger' && method === 'GET') {
        const uid = await guard(request, env);
        const rows = await env.DB.prepare('SELECT id, delta, reason, ref, created_at FROM creator_earnings_ledger WHERE uid = ? ORDER BY created_at DESC LIMIT 50').bind(uid).all();
        return json({ entries: rows.results });
      }
      if (path === '/api/earnings/payout' && method === 'POST') {
        const uid = await guard(request, env, 20);
        const b = await readJson(request) as Record<string, unknown>;
        const amountCoins = vInt(b.amountCoins, 'amountCoins', 1000, 100_000_000); // min 1000 coins = $10
        const destination = vStr(b.destination, 'destination', 1, 300); // bank/mobile-money details
        const t = now();
        await env.DB.prepare('INSERT OR IGNORE INTO creator_earnings_balances (uid, balance, lifetime_earned, updated_at) VALUES (?, 0, 0, ?)').bind(uid, t).run();
        const debit = await env.DB.prepare('UPDATE creator_earnings_balances SET balance = balance - ?, updated_at = ? WHERE uid = ? AND balance >= ?')
          .bind(amountCoins, t, uid, amountCoins)
          .run();
        if ((debit.meta as unknown as { changes: number }).changes !== 1) throw httpError(402, 'insufficient_earnings');
        const id = newId();
        const usd = amountCoins / 100;
        await env.DB.batch([
          env.DB.prepare('INSERT INTO creator_earnings_ledger (id, uid, delta, reason, ref, created_at) VALUES (?, ?, ?, ?, ?, ?)').bind(newId(), uid, -amountCoins, 'payout_requested', id, t),
          env.DB.prepare('INSERT INTO payout_requests (id, uid, amount_coins, amount_usd, destination, created_at, updated_at) VALUES (?, ?, ?, ?, ?, ?, ?)').bind(id, uid, amountCoins, usd, destination, t, t),
        ]);
        await notifyUser(env, uid, 'Payout requested', `$${usd.toFixed(2)} payout requested. You will be notified when it is processed.`, { kind: 'payout', payoutId: id });
        // v1: the request is RECORDED. Actual USD movement via Flutterwave
        // transfers is phase 2 (needs his Flutterwave transfer setup).
        return json({ id, status: 'pending', amountUsd: usd, note: 'recorded_for_manual_processing' }, 201);
      }

      // ---------- LIVE (1000+ followers to broadcast) ----------
      if (path === '/api/live' && method === 'GET') {
        await guard(request, env);
        const rows = await env.DB.prepare(
          `SELECT l.*, u.handle, u.display_name, u.avatar_url FROM live_sessions l
           JOIN users u ON u.uid = l.uid WHERE l.status = 'live' ORDER BY l.viewer_count DESC, l.started_at DESC LIMIT 50`,
        ).all();
        const out = [];
        for (const r of rows.results as Record<string, unknown>[]) {
          out.push({ ...r, is_verified: await isVerified(env.DB, r.uid as string) });
        }
        return json({ sessions: out });
      }
      if (path === '/api/live/start' && method === 'POST') {
        const uid = await guard(request, env, 20);
        if (await deviceRestricted(env.DB, uid)) throw httpError(403, 'device_restricted');
        // @nova official account is EXEMPT from the 1000-follower gate (spec correction).
        const me = await env.DB.prepare('SELECT is_official FROM users WHERE uid = ?').bind(uid).first<{ is_official: number }>();
        if (!me || me.is_official !== 1) {
          const followers = await followerCount(env.DB, uid);
          if (followers < LIVE_MIN_FOLLOWERS) throw httpError(403, `live_requires_${LIVE_MIN_FOLLOWERS}_followers`);
        }
        const existing = await env.DB.prepare("SELECT id FROM live_sessions WHERE uid = ? AND status = 'live'").bind(uid).first();
        if (existing) throw httpError(409, 'already_live');
        const b = await readJson(request) as Record<string, unknown>;
        const title = vOptStr(b.title, 'title', 120);
        const id = newId();
        await env.DB.prepare("INSERT INTO live_sessions (id, uid, title, status, started_at) VALUES (?, ?, ?, 'live', ?)").bind(id, uid, title, now()).run();
        // v1: realtime room (chat/gifts/viewers). RTMP/WebRTC ingest is a documented TODO.
        return json({ id }, 201);
      }
      {
        const m = path.match(/^\/api\/live\/([^/]+)\/(end|join|leave)$/);
        if (m && method === 'POST') {
          const uid = await guard(request, env, 60);
          const s = await env.DB.prepare('SELECT * FROM live_sessions WHERE id = ?').bind(m[1]).first<{ uid: string; status: string; viewer_count: number }>();
          if (!s) throw httpError(404, 'session_not_found');
          if (m[2] === 'end') {
            if (s.uid !== uid) throw httpError(403, 'not_broadcaster');
            await env.DB.prepare("UPDATE live_sessions SET status = 'ended', ended_at = ? WHERE id = ?").bind(now(), m[1]).run();
            await publishToUser(env, s.uid, { type: 'live_ended', sessionId: m[1] });
            return json({ ok: true });
          }
          if (s.status !== 'live') throw httpError(410, 'session_ended');
          const delta = m[2] === 'join' ? 1 : -1;
          await env.DB.prepare('UPDATE live_sessions SET viewer_count = MAX(0, viewer_count + ?) WHERE id = ?').bind(delta, m[1]).run();
          return json({ ok: true });
        }
      }

      // ---------- verification badge ($25/month) ----------
      if (path === '/api/verification/status' && method === 'GET') {
        const uid = await guard(request, env);
        const sub = await env.DB.prepare('SELECT status, started_at, expires_at FROM verification_subscriptions WHERE uid = ?').bind(uid).first();
        const active = !!sub && sub.status === 'active' && (sub.expires_at as number) > now();
        return json({ verified: active, subscription: sub || null, price_usd: VERIFY_PRICE_USD, days: VERIFY_DAYS });
      }
      // ---------- post promotion (TikTok Promote-style) ----------
      // Packages: $7/day -> ~1,000 mixed engagements/day (followers/likes/views).
      // Paid via Flutterwave; reach is ESTIMATED, never guaranteed.
      if (path === '/api/promotions/packages' && method === 'GET') {
        await guard(request, env);
        return json({ packages: PROMO_PACKAGES });
      }
      if (path === '/api/promotions' && method === 'POST') {
        const uid = await guard(request, env, 20);
        const b = await readJson(request) as Record<string, unknown>;
        const videoId = vStr(b.videoId, 'videoId', 1, 64);
        const pkg = vEnum(b.package, ['starter', 'growth', 'scale'] as const, 'package');
        const v = await env.DB.prepare('SELECT id, uid FROM videos WHERE id = ?').bind(videoId).first<{ id: string; uid: string }>();
        if (!v) throw httpError(404, 'video_not_found');
        if (v.uid !== uid) throw httpError(403, 'not_your_video');
        const spec = PROMO_PACKAGES[pkg];
        // Charge via Flutterwave (same hardened flow as Nova Coin).
        // promo_<uid>_<videoId>_<package>_<uuid> (uids/videoIds never contain '_')
        const txRef = `promo_${uid}_${videoId}_${pkg}_${newId()}`;
        const charge = await flutterwaveCharge(env.FLUTTERWAVE_SECRET_KEY, {
          tx_ref: txRef,
          amount: spec.amount,
          currency: 'USD',
          email: `${uid}@nova.user`,
          name: `Promotion ${pkg}`,
          redirectUrl: `${new URL(request.url).origin}/api/payments/callback`,
        });
        return json({ txRef, checkoutUrl: checkoutLink(charge), package: pkg, amount: spec.amount });
      }
      // Called by the payments webhook after successful charge.
      // (Invoked internally; the webhook handler calls activatePromotion.)
      if (path === '/api/promotions/mine' && method === 'GET') {
        const uid = await guard(request, env);
        const rows = await env.DB.prepare('SELECT * FROM promotions WHERE uid = ? ORDER BY created_at DESC LIMIT 50').bind(uid).all();
        return json({ promotions: rows.results });
      }
      {
        const m = path.match(/^\/api\/promotions\/([^/]+)\/metrics$/);
        if (m && method === 'GET') {
          const uid = await guard(request, env);
          const p = await env.DB.prepare('SELECT * FROM promotions WHERE id = ?').bind(m[1]).first<Record<string, unknown>>();
          if (!p) throw httpError(404, 'promotion_not_found');
          if (p.uid !== uid) throw httpError(403, 'forbidden');
          const metrics = await env.DB.prepare('SELECT * FROM promotion_metrics WHERE promotion_id = ? ORDER BY day').bind(m[1]).all();
          const totals = (metrics.results as Record<string, number>[]).reduce(
            (a, r) => ({ views: a.views + r.views, likes: a.likes + r.likes, follows: a.follows + r.follows }),
            { views: 0, likes: 0, follows: 0 },
          );
          return json({ promotion: p, daily: metrics.results, totals });
        }
      }
      if (path === '/api/verification/subscribe' && method === 'POST') {
        const uid = await guard(request, env, 20);
        const b = await readJson(request) as Record<string, unknown>;
        const email = vStr(b.email, 'email', 3, 120);
        if (!/^[^@\s]+@[^@\s]+\.[^@\s]+$/.test(email)) throw httpError(400, 'email_invalid');
        const txRef = `nova_verify_${uid}_${newId()}`;
        const data = await flutterwaveCharge(env.FLUTTERWAVE_SECRET_KEY, {
          amount: VERIFY_PRICE_USD,
          currency: 'USD',
          email,
          tx_ref: txRef,
          redirectUrl: `${new URL(request.url).origin}/api/payments/callback`,
        });
        return json({ checkoutUrl: checkoutLink(data), txRef, flutterwave: data, price_usd: VERIFY_PRICE_USD, days: VERIFY_DAYS });
      }

      // ---------- hashtags ----------
      if (path === '/api/hashtags/trending' && method === 'GET') {
        await guard(request, env);
        const rows = await env.DB.prepare(
          `SELECT j.value AS tag, COUNT(*) AS uses
           FROM videos v, json_each(v.hashtags) j
           WHERE v.visibility = 'public'
           GROUP BY j.value ORDER BY uses DESC LIMIT 20`,
        ).all();
        // #nova and #officialnova are pinned top-trending (official tags).
        const pinned = [
          { tag: 'nova', uses: 0, pinned: true },
          { tag: 'officialnova', uses: 0, pinned: true },
        ];
        const rest = (rows.results as Record<string, unknown>[]).filter(
          (r) => r.tag !== 'nova' && r.tag !== 'officialnova',
        );
        return json({ hashtags: [...pinned, ...rest] });
      }
      {
        const m = path.match(/^\/api\/hashtags\/([^/]+)$/);
        if (m && method === 'GET') {
          const uid = await guard(request, env);
          const tag = vStr(decodeURIComponent(m[1]), 'tag', 1, 40).toLowerCase();
          const rows = await env.DB.prepare(
            `SELECT v.*, u.handle, u.display_name, u.avatar_url FROM videos v
             JOIN users u ON u.uid = v.uid, json_each(v.hashtags) j
             WHERE v.visibility = 'public' AND j.value = ?
               AND ${BLOCK_FILTER}
             ORDER BY v.created_at DESC LIMIT 30`,
          )
            .bind(tag, uid, uid)
            .all();
          const out = [];
          for (const r of rows.results as Record<string, unknown>[]) {
            out.push({ ...r, is_verified: await isVerified(env.DB, r.uid as string), media_url: await signMediaKey(env.MEDIA_SIGNING_SECRET, r.media_key as string).catch(() => r.media_url) });
          }
          return json({ tag, videos: out });
        }
      }
      // Tags the user engages with (from liked videos) — FYP interest signals.
      if (path === '/api/me/tag-affinity' && method === 'GET') {
        const uid = await guard(request, env);
        const rows = await env.DB.prepare(
          `SELECT j.value AS tag, COUNT(*) AS n
           FROM likes l JOIN videos v ON v.id = l.video_id, json_each(v.hashtags) j
           WHERE l.uid = ?
           GROUP BY j.value ORDER BY n DESC LIMIT 10`,
        ).bind(uid).all();
        return json({ tags: (rows.results as { tag: string }[]).map((r) => r.tag) });
      }
      // ---------- videos ----------
      if (path === '/api/videos' && method === 'POST') {
        const uid = await guard(request, env, 60);
        const b = await readJson(request) as Record<string, unknown>;
        const mediaKey = vStr(b.mediaKey, 'mediaKey', 1, 300);
        const caption = vOptStr(b.caption, 'caption', 500);
        const hashtags = vStrList(b.hashtags, 'hashtags', 10, 40);
        const soundLabel = vOptStr(b.soundLabel, 'soundLabel', 120);
        const audioKey = vOptStr(b.audioKey, 'audioKey', 300); // user-supplied audio (their own upload); no licensed catalog in v1
        const rightsAffirmed = b.rightsAffirmed === true;
        if (!rightsAffirmed) throw httpError(400, 'rights_affirmation_required');
        const durationSec = vNum(b.durationSec ?? 0, 'durationSec', 0, 36000);
        // AI-generated declaration: optional for now (defaults to false).
        // The mandatory uploader toggle ships with the premium upload redesign.
        const isAiGenerated = b.isAiGenerated === true || b.isAiGenerated === 1 ? 1 : 0;
        const id = newId();
        await ensureAiColumn(env.DB);
        // High-risk devices: uploads are held for review (quarantined from feeds).
        // Borderline on-device nudity scans also quarantine (review decides; strike only if confirmed).
        const scanVerdict = vOptStr(b.scanVerdict, 'scanVerdict', 20);
        let visibility = (await deviceRestricted(env.DB, uid)) ? 'quarantine' : 'public';
        if (scanVerdict === 'borderline') visibility = 'quarantine';
        if (scanVerdict === 'block') throw httpError(400, 'content_blocked_by_safety_scan');
        const t = now();
        await env.DB.prepare(
          `INSERT INTO videos (id, uid, caption, hashtags, media_key, media_url, duration_sec, sound_label, audio_key, visibility, is_ai_generated, created_at)
           VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
        )
          .bind(id, uid, caption, JSON.stringify(hashtags), mediaKey, `/media/${mediaKey}`, durationSec, soundLabel, audioKey, visibility, isAiGenerated, t)
          .run();
        if (scanVerdict === 'borderline') {
          // Every borderline scan lands in the review queue — no auto-dismissal.
          await env.DB.prepare("INSERT INTO reports (id, reporter_uid, target_type, target_id, reason, created_at) VALUES (?, ?, 'video', ?, 'nudity', ?)")
            .bind(newId(), uid, id, t)
            .run();
        }
        // Return a signed playback URL (video_player can't attach auth headers).
        const playbackUrl = await signMediaKey(env.MEDIA_SIGNING_SECRET, mediaKey);
        return json({ id, playbackUrl, visibility }, 201);
      }
      // Original sounds: user-uploaded audio, attributed "Original audio - @handle", reusable.
      if (path === '/api/sounds' && method === 'GET') {
        await guard(request, env);
        const rows = await env.DB.prepare(
          `SELECT sound_label, audio_key, COUNT(*) AS uses FROM videos
           WHERE visibility = 'public' AND sound_label != '' AND audio_key != ''
           GROUP BY sound_label, audio_key ORDER BY uses DESC LIMIT 50`,
        ).all();
        return json({ sounds: rows.results });
      }
      if (path === '/api/feed' && method === 'GET') {
        const uid = await guard(request, env);
        const cursor = vNum(url.searchParams.get('cursor') || Date.now(), 'cursor', 1, 4102444800000);
        const limit = Math.min(vInt(url.searchParams.get('limit') || 20, 'limit', 1, 50), 50);
        // Hashtag interest signals: client sends top engaged tags (?boost=a,b).
        const boostTags = vOptStr(url.searchParams.get('boost'), 'boost', 400)
          .split(',')
          .map((t) => t.trim().toLowerCase().replace(/[^a-z0-9_]/g, ''))
          .filter((t) => t.length > 0)
          .slice(0, 10);
        let scoreExpr = `(v.like_count*2 + v.comment_count*3 + v.share_count*4 - ((? - v.created_at)/3600000.0)*0.8)`;
        const binds: unknown[] = [cursor, cursor, uid, uid];
        if (boostTags.length > 0) {
          const ph = boostTags.map(() => '?').join(',');
          scoreExpr += ` + (SELECT COUNT(*) FROM json_each(v.hashtags) j WHERE j.value IN (${ph})) * 5`;
          binds.push(...boostTags);
        }
        // Official tags get FYP boost weight (#nova, #officialnova).
        scoreExpr += ` + (SELECT COUNT(*) FROM json_each(v.hashtags) j WHERE j.value IN ('nova','officialnova')) * 8`;
        // Active promotions get real ranking amplification (labeled "Promoted").
        scoreExpr += ` + (SELECT COUNT(*) FROM promotions p WHERE p.video_id = v.id AND p.status = 'active' AND p.ends_at > ?) * 25`;
        binds.push(now());
        binds.push(limit);
        const rows = await env.DB.prepare(
          `SELECT v.*, u.handle, u.display_name, u.avatar_url, ${scoreExpr} AS score
           FROM videos v JOIN users u ON u.uid = v.uid
           WHERE v.visibility = 'public' AND v.created_at < ?
             AND ${BLOCK_FILTER}
           ORDER BY score DESC, v.created_at DESC LIMIT ?`,
        )
          .bind(...binds)
          .all();
        const out = [];
        for (const r of rows.results as Record<string, unknown>[]) {
          const promo = await env.DB.prepare("SELECT id FROM promotions WHERE video_id = ? AND status = 'active' AND ends_at > ?")
            .bind(r.id, now()).first();
          out.push({ ...r, is_verified: await isVerified(env.DB, r.uid as string), promoted: !!promo, media_url: await signMediaKey(env.MEDIA_SIGNING_SECRET, r.media_key as string).catch(() => r.media_url) });
        }
        return json({ videos: out, nextCursor: cursor });
      }
      if (path === '/api/feed/following' && method === 'GET') {
        const uid = await guard(request, env);
        const cursor = vNum(url.searchParams.get('cursor') || Date.now(), 'cursor', 1, 4102444800000);
        const rows = await env.DB.prepare(
          `SELECT v.*, u.handle, u.display_name, u.avatar_url FROM videos v
           JOIN users u ON u.uid = v.uid
           JOIN follows f ON f.followee_uid = v.uid AND f.follower_uid = ?
           WHERE v.visibility = 'public' AND v.created_at < ?
             AND ${BLOCK_FILTER}
           ORDER BY v.created_at DESC LIMIT 30`,
        )
          .bind(uid, cursor, uid, uid)
          .all();
        return json({ videos: rows.results });
      }
      {
        const m = path.match(/^\/api\/videos\/([^/]+)\/like$/);
        if (m && (method === 'POST' || method === 'DELETE')) {
          const uid = await guard(request, env, 120);
          const vid = vStr(m[1], 'videoId', 1, 64);
          if (method === 'POST') {
            await env.DB.prepare('INSERT OR IGNORE INTO likes (uid, video_id, created_at) VALUES (?, ?, ?)').bind(uid, vid, now()).run();
          } else {
            await env.DB.prepare('DELETE FROM likes WHERE uid = ? AND video_id = ?').bind(uid, vid).run();
          }
          await env.DB.prepare('UPDATE videos SET like_count = (SELECT COUNT(*) FROM likes WHERE video_id = ?) WHERE id = ?').bind(vid, vid).run();
          const v = await env.DB.prepare('SELECT like_count FROM videos WHERE id = ?').bind(vid).first<{ like_count: number }>();
          return json({ likeCount: v?.like_count ?? 0 });
        }
      }
      {
        const m = path.match(/^\/api\/videos\/([^/]+)\/comments$/);
        if (m && method === 'GET') {
          const uid = await guard(request, env);
          const vid = vStr(m[1], 'videoId', 1, 64);
          const rows = await env.DB.prepare(
            `SELECT c.*, u.handle, u.display_name, u.avatar_url FROM comments c
             JOIN users u ON u.uid = c.uid WHERE c.video_id = ?
               AND c.uid NOT IN (SELECT blocked_uid FROM blocks WHERE blocker_uid = ?)
               AND c.uid NOT IN (SELECT blocker_uid FROM blocks WHERE blocked_uid = ?)
             ORDER BY c.created_at ASC LIMIT 100`,
          )
            .bind(vid, uid, uid)
            .all();
          const out = [];
          for (const r of rows.results as Record<string, unknown>[]) {
            out.push({ ...r, is_verified: await isVerified(env.DB, r.uid as string) });
          }
          return json({ comments: out });
        }
        if (m && method === 'POST') {
          const uid = await guard(request, env, 12); // tight: spam control
          const vid = vStr(m[1], 'videoId', 1, 64);
          const b = await readJson(request) as Record<string, unknown>;
          const text = vStr(b.text, 'text', 1, 500);
          const id = newId();
          const t = now();
          // Pattern detection: same text 3+ times in 5 minutes = spam flag.
          const dup = await env.DB.prepare('SELECT COUNT(*) c FROM comments WHERE uid = ? AND text = ? AND created_at > ?').bind(uid, text, t - 5 * 60 * 1000).first<{ c: number }>();
          if ((dup?.c ?? 0) >= 2) {
            await env.DB.prepare("INSERT INTO reports (id, reporter_uid, target_type, target_id, reason, created_at) VALUES (?, ?, 'comment', ?, 'spam', ?)")
              .bind(newId(), uid, vid, t)
              .run();
            throw httpError(429, 'spam_flagged_for_review');
          }
          await env.DB.batch([
            env.DB.prepare('INSERT INTO comments (id, video_id, uid, text, created_at) VALUES (?, ?, ?, ?, ?)').bind(id, vid, uid, text, t),
            env.DB.prepare('UPDATE videos SET comment_count = comment_count + 1 WHERE id = ?').bind(vid),
          ]);
          return json({ id }, 201);
        }
      }
      {
        const m = path.match(/^\/api\/videos\/([^/]+)\/share$/);
        if (m && method === 'POST') {
          await guard(request, env, 120);
          const vid = vStr(m[1], 'videoId', 1, 64);
          await env.DB.prepare('UPDATE videos SET share_count = share_count + 1 WHERE id = ?').bind(vid).run();
          return json({ ok: true });
        }
      }
      {
        const m = path.match(/^\/api\/videos\/([^/]+)\/view$/);
        if (m && method === 'POST') {
          const uid = await guard(request, env, 300);
          const vid = vStr(m[1], 'videoId', 1, 64);
          // One view per account — INSERT OR IGNORE deduplicates by (uid, video_id)
          await env.DB.prepare(
            'CREATE TABLE IF NOT EXISTS video_views (uid TEXT NOT NULL, video_id TEXT NOT NULL, created_at INTEGER NOT NULL, PRIMARY KEY (uid, video_id))'
          ).run();
          await env.DB.prepare('INSERT OR IGNORE INTO video_views (uid, video_id, created_at) VALUES (?, ?, ?)')
            .bind(uid, vid, now()).run();
          await env.DB.prepare('UPDATE videos SET view_count = (SELECT COUNT(*) FROM video_views WHERE video_id = ?) WHERE id = ?')
            .bind(vid, vid).run();
          return json({ ok: true });
        }
      }

      // ---------- messaging ----------
      if (path === '/api/inbox' && method === 'GET') {
        const uid = await guard(request, env);
        const rows = await env.DB.prepare(
          `SELECT t.*, u.handle AS peer_handle, u.display_name AS peer_name, u.avatar_url AS peer_avatar
           FROM threads t JOIN users u ON u.uid = CASE WHEN t.user_a = ? THEN t.user_b ELSE t.user_a END
           WHERE (t.user_a = ? OR t.user_b = ?)
             AND u.uid NOT IN (SELECT blocked_uid FROM blocks WHERE blocker_uid = ?)
             AND u.uid NOT IN (SELECT blocker_uid FROM blocks WHERE blocked_uid = ?)
           ORDER BY t.updated_at DESC LIMIT 50`,
        )
          .bind(uid, uid, uid, uid, uid)
          .all();
        return json({ threads: rows.results });
      }
      {
        const m = path.match(/^\/api\/threads\/([^/]+)\/messages$/);
        if (m && method === 'GET') {
          const uid = await guard(request, env);
          const peerId = vStr(m[1], 'peer', 1, 128);
          const tid = threadId(uid, peerId);
          const cursor = vNum(url.searchParams.get('cursor') || Date.now(), 'cursor', 1, 4102444800000);
          const rows = await env.DB.prepare('SELECT * FROM messages WHERE thread_id = ? AND created_at < ? ORDER BY created_at DESC LIMIT 50')
            .bind(tid, cursor)
            .all();
          return json({ messages: (rows.results as unknown[]).reverse() });
        }
        if (m && method === 'POST') {
          const uid = await guard(request, env, 120);
          const b = await readJson(request) as Record<string, unknown>;
          const text = vOptStr(b.text, 'text', 2000);
          const mediaKey = vOptStr(b.mediaKey, 'mediaKey', 300);
          if (!text && !mediaKey) throw httpError(400, 'empty_message');
          const peerId = vStr(m[1], 'peer', 1, 128);
          const peer = await env.DB.prepare('SELECT uid FROM users WHERE uid = ?').bind(peerId).first<{ uid: string }>();
          if (!peer) throw httpError(404, 'user_not_found');
          // DMs require follow: you cannot message someone you don't follow.
          const follows = await env.DB.prepare('SELECT 1 FROM follows WHERE follower_uid = ? AND followee_uid = ?').bind(uid, peer.uid).first();
          if (!follows) throw httpError(403, 'follow_required_to_message');
          // Blocked users cannot message each other at all.
          if (await isBlockedEitherWay(env.DB, uid, peer.uid)) throw httpError(403, 'blocked');
          const tid = threadId(uid, peer.uid);
          const id = newId();
          const t = now();
          await env.DB.batch([
            env.DB.prepare('INSERT OR IGNORE INTO threads (id, user_a, user_b, updated_at) VALUES (?, ?, ?, ?)').bind(tid, ...[uid, peer.uid].sort(), t),
            env.DB.prepare('INSERT INTO messages (id, thread_id, sender_uid, text, media_key, created_at) VALUES (?, ?, ?, ?, ?, ?)').bind(id, tid, uid, text, mediaKey, t),
            env.DB.prepare('UPDATE threads SET last_message = ?, updated_at = ? WHERE id = ?').bind(text.slice(0, 120), t, tid),
          ]);
          const event = { type: 'message', threadId: tid, message: { id, senderUid: uid, text, createdAt: t } };
          await publishToUser(env, peer.uid, event);
          await publishToUser(env, uid, event);
          return json({ id, threadId: tid }, 201);
        }
      }

      // ---------- voice calls (VOICE ONLY; auto-recorded to Dropbox) ----------
      // No video in v1. Every call is recorded; the backend pushes the file
      // to the owner's Dropbox. No in-app recording disclosure (his order).
      if (path === '/api/calls/start' && method === 'POST') {
        const uid = await guard(request, env, 30);
        const b = await readJson(request) as Record<string, unknown>;
        const peerUid = vStr(b.peerUid, 'peerUid', 1, 128);
        if (peerUid === uid) throw httpError(400, 'cannot_call_self');
        // DM rule: must follow the peer to call.
        const f = await env.DB.prepare('SELECT 1 FROM follows WHERE follower_uid = ? AND followee_uid = ?').bind(uid, peerUid).first();
        if (!f) throw httpError(403, 'must_follow_to_call');
        const id = newId();
        const t = now();
        await env.DB.prepare(
          'INSERT INTO call_recordings (id, caller_uid, callee_uid, started_at, created_at) VALUES (?, ?, ?, ?, ?)'
        ).bind(id, uid, peerUid, t, t).run();
        await publishToUser(env, peerUid, { type: 'incoming_call', callId: id, from: uid });
        return json({ id }, 201);
      }
      {
        const m = path.match(/^\/api\/calls\/([^/]+)\/finish$/);
        if (m && method === 'POST') {
          const uid = await guard(request, env, 30);
          const cid = vStr(m[1], 'callId', 1, 64);
          const call = await env.DB.prepare('SELECT * FROM call_recordings WHERE id = ?').bind(cid)
            .first<{ caller_uid: string; callee_uid: string; started_at: number }>();
          if (!call) throw httpError(404, 'call_not_found');
          if (call.caller_uid !== uid && call.callee_uid !== uid) throw httpError(403, 'not_a_party');
          const b = await readJson(request) as Record<string, unknown>;
          // The app uploads the audio file via /api/uploads first, then passes the R2 key.
          const r2Key = vOptStr(b.r2Key, 'r2Key', 300);
          const t = now();
          const durationS = Math.max(0, Math.floor((t - call.started_at) / 1000));
          const dropboxPath = `/Nova/calls/${cid}.m4a`;
          let uploadStatus = 'pending';
          if (r2Key) {
            try {
              const obj = await env.MEDIA.get(r2Key);
              if (obj) {
                const data = await obj.arrayBuffer();
                await recordingStore(env.DROPBOX_ACCESS_TOKEN).upload(`${cid}.m4a`, data, dropboxPath);
                uploadStatus = env.DROPBOX_ACCESS_TOKEN ? 'uploaded' : 'pending';
              }
            } catch { uploadStatus = 'failed'; }
          }
          await env.DB.prepare(
            'UPDATE call_recordings SET ended_at = ?, duration_s = ?, r2_key = ?, dropbox_path = ?, upload_status = ? WHERE id = ?'
          ).bind(t, durationS, r2Key || '', dropboxPath, uploadStatus, cid).run();
          return json({ ok: true, uploadStatus });
        }
      }

      // ---------- voice notes (1-on-1 DMs; Opus; R2 24h -> Dropbox 30d) ----------
      if (path === '/api/voice-notes' && method === 'POST') {
        const uid = await guard(request, env, 30);
        const b = await readJson(request) as Record<string, unknown>;
        const threadId = vStr(b.threadId, 'threadId', 1, 64);
        const thread = await env.DB.prepare('SELECT user_a, user_b FROM threads WHERE id = ?').bind(threadId)
          .first<{ user_a: string; user_b: string }>();
        if (!thread) throw httpError(404, 'thread_not_found');
        if (thread.user_a !== uid && thread.user_b !== uid) throw httpError(403, 'not_a_party');
        const r2Key = vStr(b.r2Key, 'r2Key', 1, 300);
        const durationS = vInt(b.durationS ?? 0, 'durationS', 1, 600); // max 10 min
        const id = newId();
        const t = now();
        const dropboxPath = `/Nova/voice-notes/${id}.ogg`;
        // Async Dropbox archive (best-effort; R2 is the hot path).
        let dbStatus = 'pending';
        try {
          const obj = await env.MEDIA.get(r2Key);
          if (obj && env.DROPBOX_ACCESS_TOKEN) {
            await recordingStore(env.DROPBOX_ACCESS_TOKEN).upload(`${id}.ogg`, await obj.arrayBuffer(), dropboxPath);
            dbStatus = 'archived';
          }
        } catch { dbStatus = 'failed'; }
        await env.DB.prepare(
          'INSERT INTO voice_notes (id, thread_id, sender_uid, r2_key, dropbox_path, duration_s, dropbox_status, created_at, expires_r2_at, expires_dropbox_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)'
        ).bind(id, threadId, uid, r2Key, dropboxPath, durationS, dbStatus, t, t + 86400_000, t + 30 * 86400_000).run();
        const peer = thread.user_a === uid ? thread.user_b : thread.user_a;
        await publishToUser(env, peer, { type: 'voice_note', threadId, noteId: id, durationS });
        return json({ id, dropboxStatus: dbStatus }, 201);
      }
      {
        const m = path.match(/^\/api\/voice-notes\/thread\/([^/]+)$/);
        if (m && method === 'GET') {
          const uid = await guard(request, env);
          const tid = vStr(m[1], 'threadId', 1, 64);
          const thread = await env.DB.prepare('SELECT user_a, user_b FROM threads WHERE id = ?').bind(tid)
            .first<{ user_a: string; user_b: string }>();
          if (!thread) throw httpError(404, 'thread_not_found');
          if (thread.user_a !== uid && thread.user_b !== uid) throw httpError(403, 'not_a_party');
          const rows = await env.DB.prepare(
            'SELECT id, sender_uid, duration_s, created_at FROM voice_notes WHERE thread_id = ? AND expires_r2_at > ? ORDER BY created_at DESC LIMIT 50'
          ).bind(tid, now()).all();
          return json({ notes: rows.results });
        }
      }

      // ---------- P2P ----------
      if (path === '/api/p2p/offers' && method === 'GET') {
        await guard(request, env);
        const asset = url.searchParams.get('asset');
        const fiat = url.searchParams.get('fiat');
        let q = `SELECT o.*, u.handle, u.display_name, u.trader_score, u.trades_completed FROM p2p_offers o JOIN users u ON u.uid = o.uid WHERE o.status = 'open'`;
        const binds: unknown[] = [];
        if (asset) { vEnum(asset, ASSETS, 'asset'); q += ' AND o.asset = ?'; binds.push(asset); }
        if (fiat) { vEnum(fiat, FIATS, 'fiat'); q += ' AND o.fiat_currency = ?'; binds.push(fiat); }
        q += ' ORDER BY u.trader_score DESC, o.created_at DESC LIMIT 100';
        const rows = await env.DB.prepare(q).bind(...binds).all();
        return json({ offers: rows.results });
      }
      if (path === '/api/p2p/offers' && method === 'POST') {
        const uid = await guard(request, env, 60);
        const b = await readJson(request) as Record<string, unknown>;
        const side = vEnum(b.side, ['buy', 'sell'] as const, 'side');
        const asset = vEnum(b.asset, ASSETS, 'asset');
        const fiatCurrency = vEnum(b.fiatCurrency, FIATS, 'fiatCurrency');
        const price = vNum(b.price, 'price', 0.00000001, 1e12);
        const minAmount = vNum(b.minAmount, 'minAmount', 0.00000001, 1e12);
        const maxAmount = vNum(b.maxAmount, 'maxAmount', minAmount, 1e12);
        const paymentMethods = vStrList(b.paymentMethods, 'paymentMethods', 10, 40);
        const terms = vOptStr(b.terms, 'terms', 1000);
        const id = newId();
        await env.DB.prepare(
          `INSERT INTO p2p_offers (id, uid, side, asset, fiat_currency, price, min_amount, max_amount, payment_methods, terms, created_at)
           VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
        )
          .bind(id, uid, side, asset, fiatCurrency, price, minAmount, maxAmount, JSON.stringify(paymentMethods), terms, now())
          .run();
        return json({ id }, 201);
      }
      if (path === '/api/escrows' && method === 'POST') {
        const uid = await guard(request, env, 60);
        const b = await readJson(request) as Record<string, unknown>;
        const offerId = vStr(b.offerId, 'offerId', 1, 64);
        const offer = await env.DB.prepare('SELECT * FROM p2p_offers WHERE id = ? AND status = ?').bind(offerId, 'open').first<{
          id: string; uid: string; side: string; asset: string; fiat_currency: string; price: number; min_amount: number; max_amount: number;
        }>();
        if (!offer) throw httpError(404, 'offer_not_found');
        const amt = vNum(b.cryptoAmount, 'cryptoAmount', offer.min_amount, offer.max_amount);
        const buyer = offer.side === 'sell' ? uid : offer.uid;
        const seller = offer.side === 'sell' ? offer.uid : uid;
        if (buyer === seller) throw httpError(400, 'cannot_trade_with_self');
        const id = newId();
        const t = now();
        await env.DB.prepare(
          `INSERT INTO escrows (id, offer_id, buyer_uid, seller_uid, asset, crypto_amount, fiat_amount, fiat_currency, created_at, updated_at)
           VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
        )
          .bind(id, offer.id, buyer, seller, offer.asset, amt, amt * offer.price, offer.fiat_currency, t, t)
          .run();
        const event = { type: 'escrow', escrowId: id, status: 'awaiting_payment' };
        await publishToUser(env, buyer, event);
        await publishToUser(env, seller, event);
        return json({ id, status: 'awaiting_payment' }, 201);
      }
      {
        const m = path.match(/^\/api\/escrows\/([^/]+)\/(mark-paid|release|dispute|cancel)$/);
        if (m && method === 'POST') {
          const uid = await guard(request, env, 60);
          const escId = vStr(m[1], 'escrowId', 1, 64);
          const esc = await env.DB.prepare('SELECT * FROM escrows WHERE id = ?').bind(escId).first<{
            id: string; buyer_uid: string; seller_uid: string; status: string;
          }>();
          if (!esc) throw httpError(404, 'escrow_not_found');
          const action = m[2];
          let next: string | null = null;
          if (action === 'mark-paid' && uid === esc.buyer_uid && esc.status === 'awaiting_payment') next = 'paid';
          if (action === 'release' && uid === esc.seller_uid && esc.status === 'paid') next = 'released';
          if (action === 'dispute' && (uid === esc.buyer_uid || uid === esc.seller_uid) && ['awaiting_payment', 'paid'].includes(esc.status)) next = 'disputed';
          if (action === 'cancel' && (uid === esc.buyer_uid || uid === esc.seller_uid) && esc.status === 'awaiting_payment') next = 'cancelled';
          if (!next) throw httpError(403, 'action_not_allowed');
          await env.DB.prepare('UPDATE escrows SET status = ?, updated_at = ? WHERE id = ?').bind(next, now(), escId).run();
          if (next === 'released') {
            await env.DB.batch([
              env.DB.prepare('UPDATE users SET trades_completed = trades_completed + 1, trader_score = trader_score + 1 WHERE uid = ?').bind(esc.buyer_uid),
              env.DB.prepare('UPDATE users SET trades_completed = trades_completed + 1, trader_score = trader_score + 1 WHERE uid = ?').bind(esc.seller_uid),
            ]);
          }
          const event = { type: 'escrow', escrowId: escId, status: next };
          await publishToUser(env, esc.buyer_uid, event);
          await publishToUser(env, esc.seller_uid, event);
          return json({ status: next });
        }
      }
      {
        const m = path.match(/^\/api\/escrows\/([^/]+)$/);
        if (m && method === 'GET') {
          const uid = await guard(request, env);
          const escId = vStr(m[1], 'escrowId', 1, 64);
          const esc = await env.DB.prepare('SELECT * FROM escrows WHERE id = ?').bind(escId).first();
          if (!esc) throw httpError(404, 'escrow_not_found');
          const e = esc as { buyer_uid: string; seller_uid: string };
          if (e.buyer_uid !== uid && e.seller_uid !== uid) throw httpError(403, 'not_a_party');
          return json({ escrow: esc });
        }
      }

      // ---------- marketplace ----------
      if (path === '/api/listings' && method === 'GET') {
        await guard(request, env);
        const q = url.searchParams.get('q');
        const cat = url.searchParams.get('category');
        let sql = `SELECT l.*, u.handle, u.display_name, u.trader_score FROM listings l JOIN users u ON u.uid = l.uid WHERE l.status = 'active'`;
        const binds: unknown[] = [];
        if (cat) { sql += ' AND l.category = ?'; binds.push(vStr(cat, 'category', 1, 40)); }
        if (q) { const qq = vStr(q, 'q', 1, 100); sql += ' AND (l.title LIKE ? OR l.description LIKE ?)'; binds.push(`%${qq}%`, `%${qq}%`); }
        sql += ' ORDER BY l.created_at DESC LIMIT 100';
        const rows = await env.DB.prepare(sql).bind(...binds).all();
        return json({ listings: rows.results });
      }
      if (path === '/api/listings' && method === 'POST') {
        const uid = await guard(request, env, 60);
        // Strict seller onboarding: only verified sellers may list. Buyers need nothing.
        if ((await sellerStatus(env.DB, uid)) !== 'verified') throw httpError(403, 'seller_verification_required');
        if (await deviceRestricted(env.DB, uid)) throw httpError(403, 'device_restricted');
        const b = await readJson(request) as Record<string, unknown>;
        const title = vStr(b.title, 'title', 1, 120);
        const description = vOptStr(b.description, 'description', 2000);
        const priceUsd = vNum(b.priceUsd, 'priceUsd', 0, 1e9);
        const asset = vEnum(b.asset ?? 'USDC', ['USDC', 'USDT'] as const, 'asset');
        const mediaKeys = vStrList(b.mediaKeys, 'mediaKeys', 8, 300);
        const category = vOptStr(b.category, 'category', 40) || 'general';
        const id = newId();
        await env.DB.prepare(
          `INSERT INTO listings (id, uid, title, description, price_usd, asset, media_keys, category, created_at)
           VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)`,
        )
          .bind(id, uid, title, description, priceUsd, asset, JSON.stringify(mediaKeys), category, now())
          .run();
        return json({ id }, 201);
      }
      {
        const m = path.match(/^\/api\/listings\/([^/]+)$/);
        if (m && method === 'GET') {
          await guard(request, env);
          const row = await env.DB.prepare(`SELECT l.*, u.handle, u.display_name, u.avatar_url, u.trader_score FROM listings l JOIN users u ON u.uid = l.uid WHERE l.id = ?`).bind(vStr(m[1], 'listingId', 1, 64)).first();
          if (!row) throw httpError(404, 'listing_not_found');
          return json({ listing: row });
        }
      }
      if (path === '/api/orders' && method === 'POST') {
        const uid = await guard(request, env, 60);
        const b = await readJson(request) as Record<string, unknown>;
        const listingId = vStr(b.listingId, 'listingId', 1, 64);
        const listing = await env.DB.prepare("SELECT * FROM listings WHERE id = ? AND status = 'active'").bind(listingId).first<{
          id: string; uid: string; title: string; price_usd: number; asset: string;
        }>();
        if (!listing) throw httpError(404, 'listing_not_found');
        if (listing.uid === uid) throw httpError(400, 'cannot_buy_own_listing');
        // Payment method: Flutterwave fiat checkout OR crypto (wallet).
        const paymentMethod = vEnum(b.paymentMethod ?? 'flutterwave', ['flutterwave', 'crypto'] as const, 'paymentMethod');
        const id = newId();
        const t = now();
        // TikTok Shop-grade itemized receipt, stored in order history.
        const items = JSON.stringify([{ title: listing.title, priceUsd: listing.price_usd }]);
        const shippingUsd = 0; // v1: seller-arranged shipping; partner integrations phase 2 (see docs/SETUP.md)
        const taxUsd = 0;
        const totalUsd = listing.price_usd + shippingUsd + taxUsd;
        await env.DB.batch([
          env.DB.prepare('INSERT INTO orders (id, listing_id, buyer_uid, seller_uid, price_usd, asset, items_json, shipping_usd, tax_usd, total_usd, payment_method, created_at, updated_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)')
            .bind(id, listing.id, uid, listing.uid, listing.price_usd, listing.asset, items, shippingUsd, taxUsd, totalUsd, paymentMethod, t, t),
          env.DB.prepare('INSERT INTO order_events (id, order_id, status, note, created_at) VALUES (?, ?, ?, ?, ?)').bind(newId(), id, 'pending', `Order placed (${paymentMethod})`, t),
        ]);
        await publishToUser(env, listing.uid, { type: 'order', orderId: id, status: 'pending' });
        return json({ id, status: 'pending', totalUsd, paymentMethod }, 201);
      }
      {
        const m = path.match(/^\/api\/orders\/([^/]+)$/);
        if (m && method === 'GET') {
          const uid = await guard(request, env);
          const oid = vStr(m[1], 'orderId', 1, 64);
          const order = await env.DB.prepare('SELECT * FROM orders WHERE id = ?').bind(oid).first<{ buyer_uid: string; seller_uid: string }>();
          if (!order) throw httpError(404, 'order_not_found');
          if (order.buyer_uid !== uid && order.seller_uid !== uid) throw httpError(403, 'not_a_party');
          const events = await env.DB.prepare('SELECT status, note, created_at FROM order_events WHERE order_id = ? ORDER BY created_at ASC').bind(oid).all();
          return json({ order, receipt: {
            orderId: oid,
            items: JSON.parse((order as unknown as { items_json: string }).items_json || '[]'),
            shippingUsd: (order as unknown as { shipping_usd: number }).shipping_usd,
            taxUsd: (order as unknown as { tax_usd: number }).tax_usd,
            totalUsd: (order as unknown as { total_usd: number }).total_usd,
            paymentMethod: (order as unknown as { payment_method: string }).payment_method,
            trackingNumber: (order as unknown as { tracking_number: string }).tracking_number,
            carrier: (order as unknown as { shipping_carrier: string }).shipping_carrier,
          }, timeline: events.results });
        }
      }
      {
        // Seller advances the shipping/tracking timeline.
        const m = path.match(/^\/api\/orders\/([^/]+)\/track$/);
        if (m && method === 'POST') {
          const uid = await guard(request, env, 60);
          const b = await readJson(request) as Record<string, unknown>;
          const oid = vStr(m[1], 'orderId', 1, 64);
          const order = await env.DB.prepare('SELECT * FROM orders WHERE id = ?').bind(oid).first<{ seller_uid: string; buyer_uid: string; status: string }>();
          if (!order) throw httpError(404, 'order_not_found');
          if (order.seller_uid !== uid) throw httpError(403, 'not_seller');
          const status = vEnum(b.status, ['paid', 'shipped', 'completed', 'cancelled', 'disputed'] as const, 'status');
          const note = vOptStr(b.note, 'note', 300);
          const trackingNumber = vOptStr(b.trackingNumber, 'trackingNumber', 80);
          const carrier = vOptStr(b.carrier, 'carrier', 60);
          const t = now();
          await env.DB.batch([
            env.DB.prepare('UPDATE orders SET status = ?, tracking_number = COALESCE(NULLIF(?, \'\'), tracking_number), shipping_carrier = COALESCE(NULLIF(?, \'\'), shipping_carrier), updated_at = ? WHERE id = ?')
              .bind(status, trackingNumber, carrier, t, oid),
            env.DB.prepare('INSERT INTO order_events (id, order_id, status, note, created_at) VALUES (?, ?, ?, ?, ?)').bind(newId(), oid, status, note, t),
          ]);
          await publishToUser(env, order.buyer_uid, { type: 'order', orderId: oid, status });
          return json({ ok: true, status });
        }
      }

      // ---------- reviews (verified-purchase ONLY) ----------
      // A review requires a COMPLETED order for that product from that seller,
      // belonging to the reviewer. No open/unverified reviews, ever.
      if (path === '/api/reviews' && method === 'POST') {
        const uid = await guard(request, env, 30);
        const b = await readJson(request) as Record<string, unknown>;
        const orderId = vStr(b.orderId, 'orderId', 1, 64);
        const order = await env.DB.prepare(
          "SELECT id, listing_id, buyer_uid, seller_uid, status FROM orders WHERE id = ?"
        ).bind(orderId).first<{ id: string; listing_id: string; buyer_uid: string; seller_uid: string; status: string }>();
        if (!order) throw httpError(404, 'order_not_found');
        if (order.buyer_uid !== uid) throw httpError(403, 'not_your_order');
        if (order.status !== 'completed' && order.status !== 'delivered') {
          throw httpError(400, 'order_not_completed');
        }
        const existing = await env.DB.prepare('SELECT id FROM reviews WHERE order_id = ?').bind(orderId).first();
        if (existing) throw httpError(409, 'already_reviewed');
        const rating = vInt(b.rating, 'rating', 1, 5);
        const title = vOptStr(b.title, 'title', 120);
        const body = vOptStr(b.body, 'body', 2000);
        const id = newId();
        const t = now();
        await env.DB.prepare(
          'INSERT INTO reviews (id, order_id, product_id, seller_uid, reviewer_uid, rating, title, body, created_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)'
        ).bind(id, orderId, order.listing_id, order.seller_uid, uid, rating, title, body, t).run();
        // Feed the seller's trust/reputation score (pillar 5: reputation from real transactions).
        await updateSellerTrust(env.DB, order.seller_uid);
        return json({ id }, 201);
      }
      {
        const m = path.match(/^\/api\/reviews\/(product|seller)\/([^/]+)$/);
        if (m && method === 'GET') {
          await guard(request, env);
          const kind = m[1];
          const targetId = vStr(m[2], 'targetId', 1, 64);
          const col = kind === 'product' ? 'product_id' : 'seller_uid';
          const rows = await env.DB.prepare(
            `SELECT r.*, u.handle FROM reviews r JOIN users u ON u.uid = r.reviewer_uid WHERE r.${col} = ? ORDER BY r.created_at DESC LIMIT 50`
          ).bind(targetId).all();
          const agg = await env.DB.prepare(
            `SELECT COUNT(*) as n, AVG(rating) as avg FROM reviews WHERE ${col} = ?`
          ).bind(targetId).first<{ n: number; avg: number }>();
          return json({ reviews: rows.results, count: agg?.n ?? 0, avgRating: agg?.avg ?? 0 });
        }
      }

      // ---------- disputes ----------
      if (path === '/api/disputes' && method === 'POST') {
        const uid = await guard(request, env, 30);
        const b = await readJson(request) as Record<string, unknown>;
        const orderId = vStr(b.orderId, 'orderId', 1, 64);
        const order = await env.DB.prepare('SELECT buyer_uid, seller_uid FROM orders WHERE id = ?').bind(orderId)
          .first<{ buyer_uid: string; seller_uid: string }>();
        if (!order) throw httpError(404, 'order_not_found');
        if (order.buyer_uid !== uid && order.seller_uid !== uid) throw httpError(403, 'not_a_party');
        const reason = vEnum(b.reason, ['not_received', 'damaged', 'wrong_item', 'fraud', 'other'] as const, 'reason');
        const description = vOptStr(b.description, 'description', 2000);
        const evidenceKeys = vStrList(b.evidenceKeys ?? [], 'evidenceKeys', 10, 300);
        const id = newId();
        const t = now();
        await env.DB.batch([
          env.DB.prepare('INSERT INTO disputes (id, order_id, opener_uid, reason, description, evidence_keys, status, created_at, updated_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)')
            .bind(id, orderId, uid, reason, description, JSON.stringify(evidenceKeys), 'open', t, t),
          env.DB.prepare("UPDATE orders SET status = 'disputed', updated_at = ? WHERE id = ?").bind(t, orderId),
        ]);
        return json({ id }, 201);
      }
      if (path === '/api/disputes/mine' && method === 'GET') {
        const uid = await guard(request, env);
        const rows = await env.DB.prepare(
          'SELECT d.* FROM disputes d JOIN orders o ON o.id = d.order_id WHERE o.buyer_uid = ? OR o.seller_uid = ? ORDER BY d.created_at DESC LIMIT 50'
        ).bind(uid, uid).all();
        return json({ disputes: rows.results });
      }

      // ---------- shipments (provider abstraction; manual flow in v1) ----------
      // v1: seller enters carrier + tracking number; buyer sees the timeline.
      // Carrier adapters (EasyPost/Shippo-style) are stubbed interfaces —
      // real partnerships need his business entity + API keys (docs/SETUP.md).
      if (path === '/api/shipments' && method === 'POST') {
        const uid = await guard(request, env, 30);
        const b = await readJson(request) as Record<string, unknown>;
        const orderId = vStr(b.orderId, 'orderId', 1, 64);
        const order = await env.DB.prepare('SELECT seller_uid, buyer_uid FROM orders WHERE id = ?').bind(orderId)
          .first<{ seller_uid: string; buyer_uid: string }>();
        if (!order) throw httpError(404, 'order_not_found');
        if (order.seller_uid !== uid) throw httpError(403, 'not_seller');
        const carrier = vStr(b.carrier, 'carrier', 1, 60);
        const trackingNumber = vStr(b.trackingNumber, 'trackingNumber', 1, 80);
        const id = newId();
        const t = now();
        const events = JSON.stringify([{ ts: t, status: 'label_created', note: `Shipment created via ${carrier}` }]);
        await env.DB.batch([
          env.DB.prepare('INSERT INTO shipments (id, order_id, carrier, tracking_number, status, events, created_at, updated_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?)')
            .bind(id, orderId, carrier, trackingNumber, 'label_created', events, t, t),
          env.DB.prepare("UPDATE orders SET status = 'shipped', updated_at = ? WHERE id = ?").bind(t, orderId),
          env.DB.prepare('INSERT INTO order_events (id, order_id, status, note, created_at) VALUES (?, ?, ?, ?, ?)')
            .bind(newId(), orderId, 'shipped', `Shipped via ${carrier} (${trackingNumber})`, t),
        ]);
        await notifyUser(env, order.buyer_uid, 'Order shipped', `Your order is on its way via ${carrier}.`);
        await publishToUser(env, order.buyer_uid, { type: 'order', orderId, status: 'shipped' });
        return json({ id }, 201);
      }
      {
        const m = path.match(/^\/api\/shipments\/([^/]+)\/track$/);
        if (m && method === 'POST') {
          const uid = await guard(request, env, 30);
          const sid = vStr(m[1], 'shipmentId', 1, 64);
          const ship = await env.DB.prepare('SELECT s.*, o.seller_uid, o.buyer_uid FROM shipments s JOIN orders o ON o.id = s.order_id WHERE s.id = ?').bind(sid)
            .first<{ seller_uid: string; buyer_uid: string; events: string; order_id: string }>();
          if (!ship) throw httpError(404, 'shipment_not_found');
          if (ship.seller_uid !== uid) throw httpError(403, 'not_seller');
          const b = await readJson(request) as Record<string, unknown>;
          const status = vEnum(b.status, ['in_transit', 'out_for_delivery', 'delivered'] as const, 'status');
          const note = vOptStr(b.note, 'note', 300);
          const t = now();
          const events = JSON.parse(ship.events || '[]') as Array<Record<string, unknown>>;
          events.push({ ts: t, status, note });
          await env.DB.batch([
            env.DB.prepare('UPDATE shipments SET status = ?, events = ?, updated_at = ? WHERE id = ?').bind(status, JSON.stringify(events), t, sid),
            env.DB.prepare('UPDATE orders SET status = ?, updated_at = ? WHERE id = ?').bind(status === 'delivered' ? 'completed' : 'shipped', t, ship.order_id),
            env.DB.prepare('INSERT INTO order_events (id, order_id, status, note, created_at) VALUES (?, ?, ?, ?, ?)').bind(newId(), ship.order_id, status, note, t),
          ]);
          const titles: Record<string, string> = { in_transit: 'Order in transit', out_for_delivery: 'Out for delivery', delivered: 'Order delivered' };
          await notifyUser(env, ship.buyer_uid, titles[status], note || titles[status]);
          await publishToUser(env, ship.buyer_uid, { type: 'order', orderId: ship.order_id, status });
          return json({ ok: true, status });
        }
      }

      // ---------- uploads (R2; authed; media served via signed URLs) ----------
      if (path === '/api/uploads' && method === 'POST') {
        const uid = await guard(request, env, 30);
        const form = await request.formData();
        const file = form.get('file');
        if (!(file instanceof File)) throw httpError(400, 'file_required');
        if (file.size > 200 * 1024 * 1024) throw httpError(413, 'file_too_large');
        if (file.size === 0) throw httpError(400, 'file_empty');
        const ext = (file.name.split('.').pop() || 'bin').toLowerCase().replace(/[^a-z0-9]/g, '').slice(0, 5) || 'bin';
        const key = `${uid}/${newId()}.${ext}`;
        await env.MEDIA.put(key, file.stream(), {
          httpMetadata: { contentType: file.type || 'application/octet-stream' },
        });
        return json({ key, playbackUrl: await signMediaKey(env.MEDIA_SIGNING_SECRET, key) }, 201);
      }

      // ---------- avatar upload (R2; authed; served publicly via /avatars/) ----------
      // One call does the whole chain: validates the image, stores it under
      // avatars/<uid>/, and sets users.avatar_url to a PERMANENT public URL
      // (the /api/uploads signed URL expires after 15 minutes, so it must
      // never be stored as an avatar).
      if (path === '/api/users/avatar' && method === 'POST') {
        const uid = await guard(request, env, 30);
        const form = await request.formData();
        const file = form.get('file');
        if (!(file instanceof File)) throw httpError(400, 'file_required');
        const extByType: Record<string, string> = { 'image/jpeg': 'jpg', 'image/png': 'png', 'image/webp': 'webp' };
        const ct = (file.type || '').toLowerCase();
        const ext = extByType[ct];
        if (!ext) throw httpError(415, 'avatar_must_be_image');
        if (file.size > 10 * 1024 * 1024) throw httpError(413, 'file_too_large');
        if (file.size === 0) throw httpError(400, 'file_empty');
        const rel = `${uid}/${newId()}.${ext}`;
        const key = `avatars/${rel}`;
        await env.MEDIA.put(key, file.stream(), {
          httpMetadata: { contentType: ct, cacheControl: 'public, max-age=31536000' },
        });
        const t = now();
        const avatarUrl = `${new URL(request.url).origin}/avatars/${encodeURIComponent(rel)}`;
        await env.DB.prepare('UPDATE users SET avatar_url = ?, updated_at = ? WHERE uid = ?')
          .bind(avatarUrl, t, uid)
          .run();
        return json({ avatarUrl, key }, 201);
      }
      // Get user by uid (for wallet address lookup in DMs, etc.)
      {
        const m = path.match(/^\/api\/users\/([A-Za-z0-9_-]+)$/);
        if (m && method === 'GET') {
          await guard(request, env);
          const targetUid = m[1];
          const row = await env.DB.prepare(
            'SELECT uid, handle, display_name, avatar_url, evm_address, btc_address, is_verified, kyc_status FROM users WHERE uid = ? OR handle = ?'
          ).bind(targetUid, targetUid).first<{
            uid: string; handle: string; display_name: string; avatar_url: string;
            evm_address: string; btc_address: string; is_verified: number; kyc_status: string;
          }>();
          if (!row) throw httpError(404, 'user_not_found');
          return json({
            uid: row.uid,
            handle: row.handle,
            displayName: row.display_name,
            avatarUrl: row.avatar_url,
            evm_address: row.evm_address,
            btc_address: row.btc_address,
            is_verified: !!row.is_verified,
            kyc_status: row.kyc_status,
          });
        }
      }
      // Register wallet addresses (called when user opens Wallet tab)
      if (path === '/api/users/wallet-addresses' && method === 'POST') {
        const uid = await guard(request, env);
        const b = await readJson(request) as Record<string, unknown>;
        const evm = vStr(b.evm_address, 'evm_address', 0, 100);
        const btc = vStr(b.btc_address, 'btc_address', 0, 100);
        await env.DB.prepare('UPDATE users SET evm_address = ?, btc_address = ?, updated_at = ? WHERE uid = ?')
          .bind(evm, btc, now(), uid).run();
        return json({ ok: true });
      }

      // ---------- Flutterwave (server-side only) ----------
      if (path === '/api/payments/charge' && method === 'POST') {
        const uid = await guard(request, env, 20);
        const b = await readJson(request) as Record<string, unknown>;
        // Generic top-up path (kept for compatibility); prefer /api/coins/buy.
        const amount = vNum(b.amount, 'amount', 0.5, 100000);
        const currency = vEnum((b.currency as string) || 'NGN', ['NGN', 'USD', 'GHS', 'KES'] as const, 'currency');
        const email = vStr(b.email, 'email', 3, 120);
        if (!/^[^@\s]+@[^@\s]+\.[^@\s]+$/.test(email)) throw httpError(400, 'email_invalid');
        const txRef = `nova_${uid.slice(0, 8)}_${newId()}`;
        const data = await flutterwaveCharge(env.FLUTTERWAVE_SECRET_KEY, {
          amount, currency, email,
          tx_ref: txRef,
          redirectUrl: `${new URL(request.url).origin}/api/payments/callback`,
        });
        return json({ checkoutUrl: checkoutLink(data), txRef, flutterwave: data });
      }
      if (path === '/api/payments/webhook' && method === 'POST') {
        await rateCheck(env.RATELIMIT, `ip:${request.headers.get('cf-connecting-ip') || 'x'}`, 120, 60);
        if (!verifyWebhookSignature(request.headers.get('verif-hash'), env.FLUTTERWAVE_SECRET_HASH)) {
          throw httpError(401, 'bad_webhook_signature');
        }
        const b = await readJson(request) as Record<string, unknown>;
        const data = (b.data || {}) as Record<string, unknown>;
        const txRef = `${data.tx_ref || ''}`;
        const txId = data.id;
        const status = `${data.status || ''}`;
        // Only act on successful charges, and ALWAYS re-verify server-side.
        if (status === 'successful' && txId) {
          try {
            const v = await flutterwaveVerify(env.FLUTTERWAVE_SECRET_KEY, txId as string | number);
            const vd = ((v as Record<string, unknown>).data || {}) as Record<string, unknown>;
            if (`${vd.status}` === 'successful' && `${vd.tx_ref}` === txRef) {
              await settleFlutterwaveTx(env, txRef, Number(vd.amount || 0), `${vd.currency || ''}`);
            }
          } catch (e) {
            console.error('webhook verify failed');
          }
        }
        return json({ received: true });
      }
      // Checkout redirect fallback: Flutterwave sends the payer here with
      // ?status=&tx_ref=&transaction_id=. We re-verify server-side and settle,
      // so coins credit even if the webhook secret was never configured.
      // Public by design (the payer's browser lands here); rate-limited.
      if (path === '/api/payments/callback' && method === 'GET') {
        await rateCheck(env.RATELIMIT, `ip:${request.headers.get('cf-connecting-ip') || 'x'}`, 60, 60);
        const txRef = url.searchParams.get('tx_ref') || '';
        const txId = url.searchParams.get('transaction_id') || '';
        const status = url.searchParams.get('status') || '';
        let settled = false;
        if (status === 'successful' && txRef && txId) {
          try {
            const v = await flutterwaveVerify(env.FLUTTERWAVE_SECRET_KEY, txId);
            const vd = ((v as Record<string, unknown>).data || {}) as Record<string, unknown>;
            if (`${vd.status}` === 'successful' && `${vd.tx_ref}` === txRef) {
              await settleFlutterwaveTx(env, txRef, Number(vd.amount || 0), `${vd.currency || ''}`);
              settled = true;
            }
          } catch (e) {
            console.error('callback verify failed');
          }
        }
        const msg = settled
          ? 'Payment confirmed. Your Nova Coins are on the way — you can return to the Nova app.'
          : 'We could not confirm that payment. If you were charged, contact Nova support from the app.';
        return new Response(
          `<!doctype html><html><head><meta name="viewport" content="width=device-width,initial-scale=1"><title>Nova payment</title></head>` +
          `<body style="background:#0b0b0f;color:#fff;font-family:sans-serif;display:flex;align-items:center;justify-content:center;height:100vh;margin:0">` +
          `<p style="max-width:320px;text-align:center;line-height:1.6">${msg}</p></body></html>`,
          { headers: { 'content-type': 'text/html; charset=utf-8' } },
        );
      }

      // ---------- push ----------
      if (path === '/api/push/register' && method === 'POST') {
        const uid = await guard(request, env, 30);
        const b = await readJson(request) as Record<string, unknown>;
        const token = vStr(b.token, 'token', 10, 500);
        const platform = vOptStr(b.platform, 'platform', 20) || 'android';
        await env.DB.prepare('INSERT INTO push_tokens (uid, token, platform, updated_at) VALUES (?, ?, ?, ?) ON CONFLICT(uid, token) DO UPDATE SET updated_at=excluded.updated_at')
          .bind(uid, token, platform, now())
          .run();
        return json({ ok: true });
      }
      if (path === '/api/notify' && method === 'POST') {
        const uid = await guard(request, env, 60);
        const b = await readJson(request) as Record<string, unknown>;
        const targetUid = vStr((b.targetUid as string) || uid, 'targetUid', 1, 128);
        const title = vOptStr(b.title, 'title', 120) || 'Nova';
        const body = vOptStr(b.body, 'body', 500);
        const data = (b.data as Record<string, string>) || {};
        const rows = await env.DB.prepare('SELECT token FROM push_tokens WHERE uid = ?').bind(targetUid).all<{ token: string }>();
        let sent = 0;
        for (const r of rows.results) {
          try {
            await sendFcm(env.FIREBASE_SERVICE_ACCOUNT, r.token, title, body, data);
            sent++;
          } catch { /* per-device failure shouldn't fail the batch */ }
        }
        return json({ sent, devices: rows.results.length });
      }

      // ---------- moderation: reports + strikes ----------
      if (path === '/api/reports' && method === 'POST') {
        const uid = await guard(request, env, 30);
        const b = await readJson(request) as Record<string, unknown>;
        const targetType = vEnum(b.targetType, ['video', 'comment', 'user', 'live'] as const, 'targetType');
        const targetId = vStr(b.targetId, 'targetId', 1, 128);
        const reason = vEnum(b.reason, ['nudity', 'spam', 'harassment', 'fraud', 'impersonation', 'copyright', 'other'] as const, 'reason');
        const id = newId();
        // The official @nova account cannot be reported.
        if (targetType === 'user') {
          const t = await env.DB.prepare('SELECT is_official FROM users WHERE uid = ?').bind(targetId).first<{ is_official: number }>();
          if (t?.is_official === 1) throw httpError(400, 'cannot_report_official_account');
        }
        await env.DB.prepare('INSERT INTO reports (id, reporter_uid, target_type, target_id, reason, created_at) VALUES (?, ?, ?, ?, ?, ?)')
          .bind(id, uid, targetType, targetId, reason, now())
          .run();
        // Fraud reports feed the law-enforcement pipeline (evidence captured).
        if (reason === 'fraud' && targetType === 'user') {
          const rc = await env.DB.prepare('SELECT country FROM users WHERE uid = ?').bind(uid).first<{ country: string }>();
          const tc = await env.DB.prepare('SELECT country FROM users WHERE uid = ?').bind(targetId).first<{ country: string }>();
          const rCountry = (rc?.country || '').toUpperCase();
          const tCountry = (tc?.country || '').toUpperCase();
          let jurisdiction = 'UNMAPPED';
          if (rCountry === 'NG' && tCountry === 'NG') jurisdiction = 'EFCC';
          else if ((rCountry === 'NG' && tCountry === 'US') || (rCountry === 'US' && tCountry === 'NG')) jurisdiction = 'FBI_IC3';
          else if (rCountry !== '' && rCountry === tCountry) jurisdiction = 'LOCAL';
          const fid = newId();
          const t = now();
          await env.DB.prepare(
            `INSERT INTO fraud_cases (id, report_id, reporter_uid, target_uid, reporter_country, target_country, jurisdiction, evidence, status, created_at, updated_at)
             VALUES (?, ?, ?, ?, ?, ?, ?, ?, 'open', ?, ?)`,
          ).bind(fid, id, uid, targetId, rCountry, tCountry, jurisdiction, '{}', t, t).run();
        }
        return json({ id }, 201);
      }
      if (path === '/api/strikes/me' && method === 'GET') {
        const uid = await guard(request, env);
        const rows = await env.DB.prepare('SELECT id, reason, details, created_at FROM strikes WHERE uid = ? ORDER BY created_at DESC').bind(uid).all();
        const u = await env.DB.prepare('SELECT status FROM users WHERE uid = ?').bind(uid).first<{ status: string }>();
        return json({ strikes: rows.results, count: rows.results.length, status: u?.status || 'active' });
      }
      // Nudity on LIVESTREAM = instant ban (no 3-strike path).
      {
        const m = path.match(/^\/api\/live\/([^/]+)\/report$/);
        if (m && method === 'POST') {
          const uid = await guard(request, env, 30);
          const b = await readJson(request) as Record<string, unknown>;
          const reason = vEnum(b.reason, ['nudity', 'spam', 'harassment', 'other'] as const, 'reason');
          const s = await env.DB.prepare('SELECT uid FROM live_sessions WHERE id = ?').bind(vStr(m[1], 'sessionId', 1, 64)).first<{ uid: string }>();
          if (!s) throw httpError(404, 'session_not_found');
          const t = now();
          if (reason === 'nudity') {
            await env.DB.batch([
              env.DB.prepare("UPDATE users SET status = 'banned', updated_at = ? WHERE uid = ?").bind(t, s.uid),
              env.DB.prepare("UPDATE live_sessions SET status = 'ended', ended_at = ? WHERE id = ?").bind(t, m[1]),
              env.DB.prepare("INSERT INTO reports (id, reporter_uid, target_type, target_id, reason, status, created_at, reviewed_at) VALUES (?, ?, 'live', ?, 'nudity', 'actioned', ?, ?)").bind(newId(), uid, m[1], t, t),
            ]);
            await notifyUser(env, s.uid, 'Account banned', 'Your account was banned for nudity on a livestream. This decision is final.', { kind: 'ban' });
            return json({ action: 'banned' });
          }
          await env.DB.prepare('INSERT INTO reports (id, reporter_uid, target_type, target_id, reason, created_at) VALUES (?, ?, ?, ?, ?, ?)')
            .bind(newId(), uid, 'live', m[1], reason, t)
            .run();
          return json({ action: 'reported' });
        }
      }

      // ---------- agent-run admin console (x-admin-key) ----------
      if (path === '/api/admin/reports' && method === 'GET') {
        await adminGuard(request, env);
        const status = vOptStr(url.searchParams.get('status'), 'status', 20) || 'open';
        const rows = await env.DB.prepare('SELECT * FROM reports WHERE status = ? ORDER BY created_at DESC LIMIT 100').bind(status).all();
        return json({ reports: rows.results });
      }
      // Fraud -> law enforcement pipeline (admin/agent console).
      if (path === '/api/admin/fraud-cases' && method === 'GET') {
        await adminGuard(request, env);
        const status = vOptStr(url.searchParams.get('status'), 'status', 20) || 'open';
        const rows = await env.DB.prepare(
          `SELECT f.*, ru.handle AS reporter_handle, tu.handle AS target_handle
           FROM fraud_cases f
           LEFT JOIN users ru ON ru.uid = f.reporter_uid
           LEFT JOIN users tu ON tu.uid = f.target_uid
           WHERE f.status = ? ORDER BY f.created_at DESC LIMIT 100`,
        ).bind(status).all();
        return json({ cases: rows.results });
      }
      {
        const m = path.match(/^\/api\/admin\/fraud-cases\/([^/]+)$/);
        if (m && method === 'POST') {
          await adminGuard(request, env);
          const b = await readJson(request) as Record<string, unknown>;
          const status = vEnum(b.status, ['open', 'investigating', 'filed', 'closed'] as const, 'status');
          const filedRef = vOptStr(b.filedRef, 'filedRef', 120);
          const evidence = b.evidence !== undefined ? JSON.stringify(b.evidence).slice(0, 8000) : undefined;
          const t = now();
          const c = await env.DB.prepare('SELECT * FROM fraud_cases WHERE id = ?').bind(m[1]).first<Record<string, unknown>>();
          if (!c) throw httpError(404, 'case_not_found');
          await env.DB.prepare('UPDATE fraud_cases SET status = ?, filed_ref = COALESCE(?, filed_ref), evidence = COALESCE(?, evidence), updated_at = ? WHERE id = ?')
            .bind(status, filedRef || null, evidence || null, t, m[1]).run();
          // KYC access is audit-logged (who, whose, why).
          await env.DB.prepare('INSERT INTO kyc_access_log (id, accessor, uid, reason, created_at) VALUES (?, ?, ?, ?, ?)')
            .bind(newId(), 'admin', `${c.target_uid}`, `fraud_case:${m[1]}:${status}`, t).run();
          await publishToUser(env, `${c.reporter_uid}`, { type: 'fraud_case', caseId: m[1], status });
          return json({ id: m[1], status });
        }
      }
      {
        const m = path.match(/^\/api\/admin\/reports\/([^/]+)\/review$/);
        if (m && method === 'POST') {
          await adminGuard(request, env);
          const b = await readJson(request) as Record<string, unknown>;
          const action = vEnum(b.action, ['dismiss', 'strike', 'ban'] as const, 'action');
          const rep = await env.DB.prepare('SELECT * FROM reports WHERE id = ?').bind(vStr(m[1], 'reportId', 1, 64)).first<{ target_type: string; target_id: string; reason: string; status: string }>();
          if (!rep) throw httpError(404, 'report_not_found');
          if (rep.status !== 'open') throw httpError(409, 'already_reviewed');
          const t = now();
          // Resolve the offending user from the target.
          let offender: string | null = null;
          if (rep.target_type === 'user') offender = rep.target_id;
          else if (rep.target_type === 'video') offender = (await env.DB.prepare('SELECT uid FROM videos WHERE id = ?').bind(rep.target_id).first<{ uid: string }>())?.uid || null;
          else if (rep.target_type === 'comment') offender = (await env.DB.prepare('SELECT uid FROM comments WHERE id = ?').bind(rep.target_id).first<{ uid: string }>())?.uid || null;
          else if (rep.target_type === 'live') offender = (await env.DB.prepare('SELECT uid FROM live_sessions WHERE id = ?').bind(rep.target_id).first<{ uid: string }>())?.uid || null;
          if (action === 'dismiss') {
            await env.DB.prepare("UPDATE reports SET status = 'dismissed', reviewed_at = ? WHERE id = ?").bind(t, m[1]).run();
            return json({ action: 'dismissed' });
          }
          if (!offender) throw httpError(422, 'offender_not_found');
          if (action === 'ban') {
            await env.DB.batch([
              env.DB.prepare("UPDATE users SET status = 'banned', updated_at = ? WHERE uid = ?").bind(t, offender),
              env.DB.prepare("UPDATE reports SET status = 'actioned', reviewed_at = ? WHERE id = ?").bind(t, m[1]),
            ]);
            await notifyUser(env, offender, 'Account banned', 'Your Nova account was banned after review. This decision is final.', { kind: 'ban' });
            return json({ action: 'banned' });
          }
          // strike: 1st/2nd = warning, 3rd = suspended.
          const sid = newId();
          await env.DB.prepare('INSERT INTO strikes (id, uid, reason, details, created_at) VALUES (?, ?, ?, ?, ?)').bind(sid, offender, rep.reason, `report ${m[1]}`, t).run();
          const cnt = await env.DB.prepare('SELECT COUNT(*) c FROM strikes WHERE uid = ?').bind(offender).first<{ c: number }>();
          const strikes = cnt?.c ?? 1;
          await env.DB.prepare("UPDATE reports SET status = 'actioned', reviewed_at = ? WHERE id = ?").bind(t, m[1]).run();
          if (strikes >= 3) {
            await applySuspension(env, offender, `${strikes} strikes`);
            return json({ action: 'suspended', strikes });
          }
          await notifyUser(env, offender, `Warning ${strikes}/3`, `Your content violated community guidelines (${rep.reason}). ${3 - strikes} more strike(s) will suspend your account.`, { kind: 'strike', count: `${strikes}` });
          return json({ action: 'strike', strikes });
        }
      }
      // Bot accounts: ONLY the agent (admin key) can create them.
      if (path === '/api/admin/bots' && method === 'POST') {
        await adminGuard(request, env);
        const b = await readJson(request) as Record<string, unknown>;
        const handle = vHandle(b.handle);
        const displayName = vOptStr(b.displayName, 'displayName', 60) || handle;
        const uid = `bot_${newId()}`;
        const t = now();
        try {
          await env.DB.prepare("INSERT INTO users (uid, handle, display_name, is_bot, bot_kind, created_at, updated_at) VALUES (?, ?, ?, 1, 'worker', ?, ?)").bind(uid, handle, displayName, t, t).run();
        } catch {
          throw httpError(409, 'handle_taken');
        }
        return json({ uid, handle }, 201);
      }
      // Bot fleet: BULK provision (thousands), admin key only. No email flow.
      // Chunked: batch up to 2000 per call; D1-batched inserts (no timeouts).
      if (path === '/api/admin/bots/bulk' && method === 'POST') {
        await adminGuard(request, env);
        const b = await readJson(request) as Record<string, unknown>;
        const count = vInt(b.count ?? 100, 'count', 1, 2000);
        const prefix = vOptStr(b.prefix, 'prefix', 24) || 'nova_bot';
        const fleetId = vOptStr(b.fleetId, 'fleetId', 64) || '';
        const t = now();
        const stmts: D1PreparedStatement[] = [];
        const uids: string[] = [];
        for (let i = 0; i < count; i++) {
          const uid = `bot_${newId()}`;
          const handle = `${prefix}_${t.toString(36)}_${i}`;
          uids.push(uid);
          stmts.push(
            env.DB.prepare("INSERT INTO users (uid, handle, display_name, is_bot, bot_kind, created_at, updated_at) VALUES (?, ?, ?, 1, 'worker', ?, ?)")
              .bind(uid, handle, handle, t, t)
          );
          if (fleetId) {
            stmts.push(
              env.DB.prepare('INSERT OR IGNORE INTO bot_fleet_members (fleet_id, bot_uid, added_at) VALUES (?, ?, ?)').bind(fleetId, uid, t)
            );
          }
        }
        for (let i = 0; i < stmts.length; i += 100) {
          await env.DB.batch(stmts.slice(i, i + 100));
        }
        return json({ count, uids: uids.slice(0, 10) }, 201);
      }
      // Bot fleet FINAL SHAPE: 100k passive follower bots for @nova.
      // Chunked: the agent calls repeatedly (batch up to 2000) until done.
      // Each bot gets ONE follow edge -> nova_official. No posts, no DMs.
      if (path === '/api/admin/fleet/followers/seed' && method === 'POST') {
        await adminGuard(request, env);
        const b = await readJson(request) as Record<string, unknown>;
        const batch = vInt(b.batch ?? 1000, 'batch', 1, 2000);
        const total = vInt(b.total ?? 100000, 'total', 1, 1000000);
        const t = now();
        const prog = await env.DB.prepare("SELECT done FROM fleet_seed_progress WHERE key = 'nova_followers'").first<{ done: number }>();
        const start = prog?.done || 0;
        if (start >= total) return json({ done: start, total, complete: true });
        const end = Math.min(start + batch, total);
        const officialUidRow = await env.DB.prepare('SELECT uid FROM users WHERE is_official = 1 LIMIT 1').first<{ uid: string }>();
        const officialUid = officialUidRow?.uid || '';
        const stmts: D1PreparedStatement[] = [];
        for (let i = start; i < end; i++) {
          const uid = `botf_${newId()}`;
          // Unique handle: index + random suffix (survives progress desync).
          const handle = `nova_fan_${String(i).padStart(6, '0')}_${newId().slice(0, 6)}`;
          stmts.push(
            env.DB.prepare("INSERT OR IGNORE INTO users (uid, handle, display_name, is_bot, bot_kind, created_at, updated_at) VALUES (?, ?, ?, 1, 'passive', ?, ?)")
              .bind(uid, handle, handle, t, t),
            env.DB.prepare('INSERT OR IGNORE INTO follows (follower_uid, followee_uid, created_at) VALUES (?, ?, ?)')
              .bind(uid, officialUid, t)
          );
        }
        // D1 batch: single call with all statements (2000 max per batch).
        // Split into 2 calls of 1000 statements if needed.
        for (let i = 0; i < stmts.length; i += 1000) {
          await env.DB.batch(stmts.slice(i, i + 1000));
        }
        await env.DB.prepare(
          "INSERT INTO fleet_seed_progress (key, done, total, updated_at) VALUES ('nova_followers', ?, ?, ?) ON CONFLICT(key) DO UPDATE SET done = ?, total = ?, updated_at = ?"
        ).bind(end, total, t, end, total, t).run();
        return json({ done: end, total, complete: end >= total, created: end - start }, 201);
      }
      if (path === '/api/admin/fleet/followers/progress' && method === 'GET') {
        await adminGuard(request, env);
        const prog = await env.DB.prepare("SELECT * FROM fleet_seed_progress WHERE key = 'nova_followers'").first();
        const count = await env.DB.prepare("SELECT COUNT(*) AS n FROM users WHERE is_bot = 1 AND bot_kind = 'passive'").first<{ n: number }>();
        const offUid = await env.DB.prepare('SELECT uid FROM users WHERE is_official = 1 LIMIT 1').first<{ uid: string }>();
        const follows = offUid ? await env.DB.prepare('SELECT COUNT(*) AS n FROM follows WHERE followee_uid = ?').bind(offUid.uid).first<{ n: number }>() : { n: 0 };
        return json({ progress: prog, passiveBots: count?.n || 0, novaFollowers: follows?.n || 0 });
      }
      // Fleet console: list bots (paginated, labeled).
      if (path === '/api/admin/fleet/bots' && method === 'GET') {
        await adminGuard(request, env);
        const fleetId = url.searchParams.get('fleetId');
        const limit = Math.min(200, Math.max(1, parseInt(url.searchParams.get('limit') || '50', 10) || 50));
        const offset = Math.max(0, parseInt(url.searchParams.get('offset') || '0', 10) || 0);
        let rows;
        if (fleetId) {
          rows = await env.DB.prepare(
            `SELECT u.uid, u.handle, u.display_name, u.created_at FROM users u
             JOIN bot_fleet_members m ON m.bot_uid = u.uid
             WHERE m.fleet_id = ? AND u.is_bot = 1 ORDER BY u.created_at DESC LIMIT ? OFFSET ?`
          ).bind(fleetId, limit, offset).all();
        } else {
          rows = await env.DB.prepare(
            'SELECT uid, handle, display_name, created_at FROM users WHERE is_bot = 1 ORDER BY created_at DESC LIMIT ? OFFSET ?'
          ).bind(limit, offset).all();
        }
        return json({ bots: rows.results, limit, offset });
      }
      // Fleet console: create fleet.
      if (path === '/api/admin/fleet/fleets' && method === 'POST') {
        await adminGuard(request, env);
        const b = await readJson(request) as Record<string, unknown>;
        const name = vStr(b.name, 'name', 1, 60);
        const description = vOptStr(b.description, 'description', 200) || '';
        const id = newId();
        const t = now();
        await env.DB.prepare('INSERT INTO bot_fleets (id, name, description, created_at) VALUES (?, ?, ?, ?)').bind(id, name, description, t).run();
        return json({ id, name }, 201);
      }
      if (path === '/api/admin/fleet/fleets' && method === 'GET') {
        await adminGuard(request, env);
        const rows = await env.DB.prepare(
          `SELECT f.*, (SELECT COUNT(*) FROM bot_fleet_members m WHERE m.fleet_id = f.id) AS bot_count
           FROM bot_fleets f ORDER BY f.created_at DESC LIMIT 100`
        ).all();
        return json({ fleets: rows.results });
      }
      // Fleet console: create mission + dispatch to bots/fleet.
      if (path === '/api/admin/fleet/missions' && method === 'POST') {
        await adminGuard(request, env);
        const b = await readJson(request) as Record<string, unknown>;
        const title = vStr(b.title, 'title', 1, 120);
        const taskType = vStr(b.taskType, 'taskType', 1, 40);
        const payload = typeof b.payload === 'object' && b.payload ? JSON.stringify(b.payload) : '{}';
        const targetKind = vOptStr(b.targetKind, 'targetKind', 10) || 'bots';
        if (!['bots', 'fleet', 'all'].includes(targetKind)) throw httpError(400, 'bad_target_kind');
        const targetFleetId = vOptStr(b.targetFleetId, 'targetFleetId', 64) || '';
        const botUids = Array.isArray(b.botUids) ? b.botUids.filter((u): u is string => typeof u === 'string').slice(0, 5000) : [];
        const id = newId();
        const t = now();
        await env.DB.prepare(
          'INSERT INTO fleet_missions (id, title, task_type, payload, target_kind, target_fleet_id, status, created_by, created_at, updated_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)'
        ).bind(id, title, taskType, payload, targetKind, targetFleetId || null, 'pending', 'agent', t, t).run();
        // Resolve targets.
        let targets: string[] = [];
        if (targetKind === 'fleet' && targetFleetId) {
          const rows = await env.DB.prepare('SELECT bot_uid FROM bot_fleet_members WHERE fleet_id = ?').bind(targetFleetId).all<{ bot_uid: string }>();
          targets = rows.results.map(r => r.bot_uid);
        } else if (targetKind === 'all') {
          const rows = await env.DB.prepare('SELECT uid FROM users WHERE is_bot = 1 LIMIT 10000').all<{ uid: string }>();
          targets = rows.results.map(r => r.uid);
        } else {
          targets = botUids;
        }
        const batch = targets.map(uid =>
          env.DB.prepare('INSERT INTO fleet_assignments (id, mission_id, bot_uid, status, created_at) VALUES (?, ?, ?, ?, ?)')
            .bind(newId(), id, uid, 'queued', t)
        );
        // D1 batch in chunks of 100.
        for (let i = 0; i < batch.length; i += 100) {
          await env.DB.batch(batch.slice(i, i + 100));
        }
        await env.DB.prepare("UPDATE fleet_missions SET status = 'dispatched', updated_at = ? WHERE id = ?").bind(now(), id).run();
        return json({ id, assigned: targets.length }, 201);
      }
      // Fleet console: mission status + results.
      {
        const m = path.match(/^\/api\/admin\/fleet\/missions\/([^/]+)$/);
        if (m && method === 'GET') {
          await adminGuard(request, env);
          const mid = vStr(m[1], 'missionId', 1, 64);
          const mission = await env.DB.prepare('SELECT * FROM fleet_missions WHERE id = ?').bind(mid).first();
          if (!mission) throw httpError(404, 'mission_not_found');
          const summary = await env.DB.prepare(
            'SELECT status, COUNT(*) AS n FROM fleet_assignments WHERE mission_id = ? GROUP BY status'
          ).bind(mid).all<{ status: string; n: number }>();
          const results = await env.DB.prepare(
            "SELECT bot_uid, status, result, error, completed_at FROM fleet_assignments WHERE mission_id = ? AND status IN ('done','failed') ORDER BY completed_at DESC LIMIT 200"
          ).bind(mid).all();
          return json({ mission, summary: summary.results, results: results.results });
        }
      }
      // Bot self-report: assignment result (bot uid from its own token; admin key for now in v1).
      if (path === '/api/admin/fleet/assignments/complete' && method === 'POST') {
        await adminGuard(request, env);
        const b = await readJson(request) as Record<string, unknown>;
        const assignmentId = vStr(b.assignmentId, 'assignmentId', 1, 64);
        const status = vOptStr(b.status, 'status', 10) || 'done';
        if (!['done', 'failed', 'skipped'].includes(status)) throw httpError(400, 'bad_status');
        const result = typeof b.result === 'object' && b.result ? JSON.stringify(b.result) : (vOptStr(b.result as string, 'result', 20000) || '');
        const error = vOptStr(b.error, 'error', 2000) || '';
        const t = now();
        await env.DB.prepare(
          "UPDATE fleet_assignments SET status = ?, result = ?, error = ?, completed_at = ? WHERE id = ?"
        ).bind(status, result, error, t, assignmentId).run();
        return json({ ok: true });
      }
      if (path === '/api/admin/sellers' && method === 'GET') {
        await adminGuard(request, env);
        const status = vOptStr(url.searchParams.get('status'), 'status', 20) || 'pending';
        const rows = await env.DB.prepare('SELECT * FROM seller_profiles WHERE status = ? ORDER BY created_at DESC LIMIT 100').bind(status).all();
        return json({ sellers: rows.results });
      }
      {
        const m = path.match(/^\/api\/admin\/sellers\/([^/]+)\/review$/);
        if (m && method === 'POST') {
          await adminGuard(request, env);
          const b = await readJson(request) as Record<string, unknown>;
          const decision = vEnum(b.decision, ['verified', 'rejected'] as const, 'decision');
          const note = vOptStr(b.note, 'note', 300);
          const t = now();
          await env.DB.prepare('UPDATE seller_profiles SET status = ?, reviewer_note = ?, updated_at = ? WHERE uid = ?').bind(decision, note, t, vStr(m[1], 'uid', 1, 128)).run();
          await notifyUser(env, m[1], decision === 'verified' ? 'Seller approved' : 'Seller application rejected', note || '', { kind: 'seller_review', decision });
          return json({ uid: m[1], status: decision });
        }
      }
      if (path === '/api/admin/vpn-blacklist' && method === 'POST') {
        await adminGuard(request, env);
        const b = await readJson(request) as Record<string, unknown>;
        const ip = vStr(b.ip, 'ip', 3, 64);
        const reason = vEnum(b.reason, ['vpn', 'proxy', 'tor', 'manual'] as const, 'reason');
        const ttlH = vOptStr(`${b.ttlHours ?? ''}`, 'ttlHours', 10);
        const expires = ttlH ? now() + Number(ttlH) * 3600 * 1000 : 0;
        await env.DB.prepare('INSERT OR REPLACE INTO network_blacklist (ip, reason, added_at, expires_at) VALUES (?, ?, ?, ?)').bind(ip, reason, now(), expires).run();
        return json({ ok: true }, 201);
      }
      // Quarantined uploads (high-risk devices): approve to public or delete.
      if (path === '/api/admin/quarantine' && method === 'GET') {
        await adminGuard(request, env);
        const rows = await env.DB.prepare("SELECT v.*, u.handle FROM videos v JOIN users u ON u.uid = v.uid WHERE v.visibility = 'quarantine' ORDER BY v.created_at DESC LIMIT 100").all();
        return json({ videos: rows.results });
      }
      {
        const m = path.match(/^\/api\/admin\/quarantine\/([^/]+)\/review$/);
        if (m && method === 'POST') {
          await adminGuard(request, env);
          const b = await readJson(request) as Record<string, unknown>;
          const decision = vEnum(b.decision, ['approve', 'delete'] as const, 'decision');
          const vid = vStr(m[1], 'videoId', 1, 64);
          if (decision === 'approve') {
            await env.DB.prepare("UPDATE videos SET visibility = 'public' WHERE id = ?").bind(vid).run();
          } else {
            await env.DB.prepare('DELETE FROM videos WHERE id = ?').bind(vid).run();
          }
          return json({ ok: true, decision });
        }
      }
      {
        const m = path.match(/^\/api\/admin\/vpn-blacklist\/(.+)$/);
        if (m && method === 'DELETE') {
          await adminGuard(request, env);
          await env.DB.prepare('DELETE FROM network_blacklist WHERE ip = ?').bind(decodeURIComponent(m[1])).run();
          return json({ ok: true });
        }
      }
      if (path === '/api/admin/support/tickets' && method === 'GET') {        await adminGuard(request, env);
        const status = vOptStr(url.searchParams.get('status'), 'status', 20) || 'open';
        const rows = await env.DB.prepare('SELECT * FROM support_tickets WHERE status = ? ORDER BY updated_at DESC LIMIT 100').bind(status).all();
        return json({ tickets: rows.results });
      }
      {
        const m = path.match(/^\/api\/admin\/support\/tickets\/([^/]+)\/reply$/);
        if (m && method === 'POST') {
          await adminGuard(request, env);
          const b = await readJson(request) as Record<string, unknown>;
          const message = vStr(b.message, 'message', 1, 2000);
          const tid = vStr(m[1], 'ticketId', 1, 64);
          const t = now();
          const ticket = await env.DB.prepare('SELECT uid FROM support_tickets WHERE id = ?').bind(tid).first<{ uid: string }>();
          if (!ticket) throw httpError(404, 'ticket_not_found');
          await env.DB.batch([
            env.DB.prepare('INSERT INTO support_replies (id, ticket_id, author, message, created_at) VALUES (?, ?, ?, ?, ?)').bind(newId(), tid, 'agent', message, t),
            env.DB.prepare("UPDATE support_tickets SET status = 'answered', updated_at = ? WHERE id = ?").bind(t, tid),
          ]);
          await notifyUser(env, ticket.uid, 'Support reply', message.slice(0, 120), { kind: 'support', ticketId: tid });
          return json({ ok: true }, 201);
        }
      }

      // ---------- sellers (strict onboarding; buyers need nothing) ----------
      // Public: get the ID requirements for a country (for the signup form).
      {
        const m = path.match(/^\/api\/sellers\/id-spec\/([A-Za-z]{2})$/);
        if (m && method === 'GET') {
          const spec = idSpecFor(m[1]);
          // Don't expose the regex itself; just the human-facing fields.
          return json({ country: spec.country, name: spec.name, idName: spec.idName, idKey: spec.idKey, example: spec.example, hint: spec.hint });
        }
      }
      if (path === '/api/sellers/apply' && method === 'POST') {
        const uid = await guard(request, env, 20);
        const b = await readJson(request) as Record<string, unknown>;
        const t = now();
        const country = vStr(b.country, 'country', 2, 2).toUpperCase();
        const idNumber = vStr(b.idNumber, 'idNumber', 1, 60);
        // Country-specific ID format check (syntactic; registry verification is future).
        const { ok: idOk, spec } = validateIdNumber(country, idNumber);
        if (!idOk) throw httpError(400, `invalid_id_number:${spec.idKey}`);
        await env.DB.prepare(
          `INSERT INTO seller_profiles (uid, full_name, address, phone, email, zip, country, id_type, id_number, id_doc_key, created_at, updated_at)
           VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
           ON CONFLICT(uid) DO UPDATE SET full_name=excluded.full_name, address=excluded.address, phone=excluded.phone, email=excluded.email, zip=excluded.zip, country=excluded.country, id_type=excluded.id_type, id_number=excluded.id_number, id_doc_key=excluded.id_doc_key, status='pending', updated_at=excluded.updated_at`,
        )
          .bind(
            uid,
            vStr(b.fullName, 'fullName', 1, 120),
            vStr(b.address, 'address', 1, 300),
            vStr(b.phone, 'phone', 1, 40),
            vStr(b.email, 'email', 3, 120),
            vStr(b.zip, 'zip', 1, 20),
            vStr(b.country, 'country', 1, 60),
            vEnum(b.idType, ['ssn', 'nin', 'passport', 'drivers_license', 'national_id', 'other'] as const, 'idType'),
            vStr(b.idNumber, 'idNumber', 1, 60),
            vStr(b.idDocKey, 'idDocKey', 1, 300),
            t, t,
          )
          .run();
        return json({ status: 'pending' }, 201);
      }
      if (path === '/api/sellers/me' && method === 'GET') {
        const uid = await guard(request, env);
        const row = await env.DB.prepare('SELECT * FROM seller_profiles WHERE uid = ?').bind(uid).first();
        return json({ seller: row || null, status: (row as { status?: string } | null)?.status || 'none' });
      }

      // ---------- network security: client-visible egress check ----------
      if (path === '/api/security/network-check' && method === 'GET') {
        const ip = request.headers.get('cf-connecting-ip') || 'unknown-ip';
        await rateCheck(env.RATELIMIT, `ip:${ip}`, 60, 60);
        const row = await env.DB.prepare('SELECT reason FROM network_blacklist WHERE ip = ? AND (expires_at = 0 OR expires_at > ?)').bind(ip, now()).first<{ reason: string }>();
        if (row) throw httpError(403, 'network_blocked');
        // IP/ASN reputation provider is a PLUGGABLE interface (see docs/SETUP.md).
        // When configured, auto-blacklist hits land in network_blacklist via the
        // admin endpoint or a scheduled worker; this check stays a pure lookup.
        return json({ ok: true });
      }

      // ---------- support desk ----------
      if (path === '/api/support/tickets' && method === 'POST') {
        const uid = await guard(request, env, 30);
        const b = await readJson(request) as Record<string, unknown>;
        const subject = vStr(b.subject, 'subject', 1, 120);
        const message = vStr(b.message, 'message', 1, 2000);
        const id = newId();
        const t = now();
        await env.DB.batch([
          env.DB.prepare('INSERT INTO support_tickets (id, uid, subject, created_at, updated_at) VALUES (?, ?, ?, ?, ?)').bind(id, uid, subject, t, t),
          env.DB.prepare('INSERT INTO support_replies (id, ticket_id, author, message, created_at) VALUES (?, ?, ?, ?, ?)').bind(newId(), id, 'user', message, t),
        ]);
        return json({ id }, 201);
      }
      if (path === '/api/support/tickets' && method === 'GET') {
        const uid = await guard(request, env);
        const rows = await env.DB.prepare('SELECT * FROM support_tickets WHERE uid = ? ORDER BY updated_at DESC LIMIT 50').bind(uid).all();
        return json({ tickets: rows.results });
      }
      {
        const m = path.match(/^\/api\/support\/tickets\/([^/]+)(\/reply)?$/);
        if (m && method === 'GET' && !m[2]) {
          const uid = await guard(request, env);
          const tid = vStr(m[1], 'ticketId', 1, 64);
          const ticket = await env.DB.prepare('SELECT * FROM support_tickets WHERE id = ? AND uid = ?').bind(tid, uid).first();
          if (!ticket) throw httpError(404, 'ticket_not_found');
          const replies = await env.DB.prepare('SELECT * FROM support_replies WHERE ticket_id = ? ORDER BY created_at ASC').bind(tid).all();
          return json({ ticket, replies: replies.results });
        }
        if (m && m[2] && method === 'POST') {
          const uid = await guard(request, env, 60);
          const b = await readJson(request) as Record<string, unknown>;
          const message = vStr(b.message, 'message', 1, 2000);
          const tid = vStr(m[1], 'ticketId', 1, 64);
          const ticket = await env.DB.prepare('SELECT * FROM support_tickets WHERE id = ? AND uid = ?').bind(tid, uid).first();
          if (!ticket) throw httpError(404, 'ticket_not_found');
          const t = now();
          await env.DB.batch([
            env.DB.prepare('INSERT INTO support_replies (id, ticket_id, author, message, created_at) VALUES (?, ?, ?, ?, ?)').bind(newId(), tid, 'user', message, t),
            env.DB.prepare("UPDATE support_tickets SET status = 'open', updated_at = ? WHERE id = ?").bind(t, tid),
          ]);
          return json({ ok: true }, 201);
        }
      }

      return json({ error: 'not_found' }, 404);
    } catch (e) {
      const err = e as { status?: number; message?: string };
      const status = err.status || 500;
      if (status === 429) {
        return new Response(JSON.stringify({ error: 'rate_limited' }), {
          status: 429,
          headers: { 'content-type': 'application/json', 'retry-after': '60' },
        });
      }
      if (status >= 500) {
        console.error('nova-api error'); // message only; never request data
        return json({ error: 'internal_error' }, 500);
      }
      return json({ error: err.message || 'bad_request' }, status);
    }
  },

  // Daily cleanup: voice-note lifecycle.
  // - R2 copies older than 24h are deleted (hot storage expiry).
  // - Dropbox copies older than 30d are deleted via the Dropbox API.
  async scheduled(event: ScheduledEvent, env: Env): Promise<void> {
    const t = now();
    // Expire R2 hot copies.
    const stale = await env.DB.prepare(
      'SELECT id, r2_key FROM voice_notes WHERE expires_r2_at <= ? AND r2_key != ? LIMIT 100'
    ).bind(t, '').all<{ id: string; r2_key: string }>();
    for (const r of stale.results) {
      try { await env.MEDIA.delete(r.r2_key); } catch { /* already gone */ }
      await env.DB.prepare("UPDATE voice_notes SET r2_key = '' WHERE id = ?").bind(r.id).run();
    }
    // Expire Dropbox archive copies.
    if (env.DROPBOX_ACCESS_TOKEN) {
      const old = await env.DB.prepare(
        "SELECT id, dropbox_path FROM voice_notes WHERE expires_dropbox_at <= ? AND dropbox_status = 'archived' LIMIT 100"
      ).bind(t).all<{ id: string; dropbox_path: string }>();
      for (const r of old.results) {
        try {
          await fetch('https://api.dropboxapi.com/2/files/delete_v2', {
            method: 'POST',
            headers: {
              Authorization: `Bearer ${env.DROPBOX_ACCESS_TOKEN}`,
              'Content-Type': 'application/json',
            },
            body: JSON.stringify({ path: r.dropbox_path }),
          });
          await env.DB.prepare("UPDATE voice_notes SET dropbox_status = 'expired' WHERE id = ?").bind(r.id).run();
        } catch { /* retry tomorrow */ }
      }
    }
  },
};

// Settle a verified Flutterwave transaction: credit Nova Coin or activate verification.
// Idempotency: tx_ref contains a uuid; we record settlement in the ledger ref.
async function settleFlutterwaveTx(env: Env, txRef: string, amount: number, currency: string) {
  const t = now();
  if (txRef.startsWith('nova_coins_')) {
    // Source of truth is coin_purchases (written at buy time). tx_ref is
    // NEVER parsed: package ids like "coins_500" contain underscores.
    const purchase = await env.DB.prepare('SELECT uid, package_id, amount_usd FROM coin_purchases WHERE tx_ref = ?')
      .bind(txRef).first<{ uid: string; package_id: string; amount_usd: number }>();
    if (!purchase) {
      console.error('coin settlement: unknown tx_ref');
      return;
    }
    const uid = purchase.uid;
    const pkg = COIN_PACKAGES.find((p) => p.id === purchase.package_id);
    if (!pkg || currency !== 'USD' || Math.abs(amount - pkg.usd) > 0.001 || Math.abs(purchase.amount_usd - pkg.usd) > 0.001) {
      console.error('coin settlement mismatch');
      return;
    }
    const userRow = await env.DB.prepare('SELECT uid FROM users WHERE uid = ?').bind(uid).first();
    const dup = await env.DB.prepare('SELECT 1 FROM nova_coin_ledger WHERE ref = ?').bind(txRef).first();
    if (dup || !userRow) return; // idempotent: never double-credit
    await env.DB.batch([
      env.DB.prepare('INSERT OR IGNORE INTO nova_coin_balances (uid, balance, updated_at) VALUES (?, 0, ?)').bind(uid, t),
      env.DB.prepare('UPDATE nova_coin_balances SET balance = balance + ?, updated_at = ? WHERE uid = ?').bind(pkg.coins, t, uid),
      env.DB.prepare('INSERT INTO nova_coin_ledger (id, uid, delta, reason, ref, created_at) VALUES (?, ?, ?, ?, ?, ?)').bind(newId(), uid, pkg.coins, 'purchase', txRef, t),
    ]);
    await publishToUser(env, uid, { type: 'coins', balance: await coinBalance(env.DB, uid) });
    return;
  }
  if (txRef.startsWith('nova_verify_')) {
    // nova_verify_<fullUid>_<uuid>
    const uid = txRef.split('_')[2];
    if (currency !== 'USD' || Math.abs(amount - VERIFY_PRICE_USD) > 0.001) {
      console.error('verify settlement mismatch');
      return;
    }
    const dup = await env.DB.prepare('SELECT 1 FROM verification_subscriptions WHERE tx_ref = ?').bind(txRef).first();
    if (dup) return; // idempotent
    const userRow = await env.DB.prepare('SELECT uid FROM users WHERE uid = ?').bind(uid).first();
    if (!userRow) return;
    await env.DB.prepare(
      `INSERT INTO verification_subscriptions (uid, status, started_at, expires_at, tx_ref, updated_at)
       VALUES (?, 'active', ?, ?, ?, ?)
       ON CONFLICT(uid) DO UPDATE SET status='active', started_at=excluded.started_at, expires_at=excluded.expires_at, tx_ref=excluded.tx_ref, updated_at=excluded.updated_at`,
    )
      .bind(uid, t, t + VERIFY_DAYS * 86400 * 1000, txRef, t)
      .run();
    await publishToUser(env, uid, { type: 'verification', verified: true });
    return;
  }
  if (txRef.startsWith('promo_')) {
    // promo_<uid>_<videoId>_<package>_<uuid>
    const parts = txRef.split('_');
    const uid = parts[1], videoId = parts[2], pkg = parts[3];
    const spec = PROMO_PACKAGES[pkg];
    if (!spec || currency !== 'USD' || Math.abs(amount - spec.amount) > 0.001) {
      console.error('promo settlement mismatch');
      return;
    }
    const dup = await env.DB.prepare('SELECT 1 FROM promotions WHERE payment_ref = ?').bind(txRef).first();
    if (dup) return; // idempotent
    const v = await env.DB.prepare('SELECT id, uid FROM videos WHERE id = ?').bind(videoId).first<{ id: string; uid: string }>();
    if (!v || v.uid !== uid) return;
    const startsAt = t;
    const endsAt = t + spec.days * 86400 * 1000;
    const pid = newId();
    await env.DB.prepare(
      `INSERT INTO promotions (id, video_id, uid, package, amount_usd, days, est_reach, starts_at, ends_at, status, payment_ref, created_at)
       VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, 'active', ?, ?)`,
    ).bind(pid, videoId, uid, pkg, spec.amount, spec.days, spec.estReach, startsAt, endsAt, txRef, t).run();
    await publishToUser(env, uid, { type: 'promotion', promotionId: pid, videoId });
    return;
  }
}
