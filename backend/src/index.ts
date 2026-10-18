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
import { checkoutLink, flutterwaveBanks, flutterwaveCharge, flutterwaveTransfer, flutterwaveVerify, verifyWebhookSignature } from './lib/flutterwave';
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
  FLUTTERWAVE_PUBLIC_KEY?: string;
  FIREBASE_SERVICE_ACCOUNT?: string;
  MEDIA_SIGNING_SECRET?: string;
  ADMIN_REVIEW_KEY?: string;
  DROPBOX_ACCESS_TOKEN?: string;
  CLOUDFLARE_DNS_TOKEN?: string;
}

// Nova Coin packages: USD -> coins (bonus on larger packs).
const COIN_PACKAGES = [
  { id: 'coins_500', usd: 5, coins: 500 },
  { id: 'coins_1100', usd: 10, coins: 1100 },
  { id: 'coins_3000', usd: 25, coins: 3000 },
] as const;

const VERIFY_TIERS = {
  personal: { monthly_usd: 15, color: '0xFF20D5EC', label: 'Personal' },
  business: { monthly_usd: 65, color: '0xFFFF2E63', label: 'Business' },
  company: { monthly_usd: 100, color: '0xFFD4AF37', label: 'Company' },
} as const;
type VerifyTier = keyof typeof VERIFY_TIERS;
// Period pricing: 3mo = 3x monthly, 6mo = 5.7x (5% off), 12mo = 10x (2 months free)
function verifyPriceFor(tier: VerifyTier, months: 3 | 6 | 12): number {
  const m = VERIFY_TIERS[tier].monthly_usd;
  if (months === 12) return m * 10;
  if (months === 6) return Math.round(m * 5.7 * 100) / 100;
  return m * 3;
}
const LIVE_MIN_FOLLOWERS = 1000;

function threadId(a: string, b: string) {
  return [a, b].sort().join('__');
}

// HTML-escape for share pages (/v/{id}, /@{handle}, /coins). Any value that
// originated from user input or the database MUST go through this before
// being interpolated into HTML — prevents stored XSS via display names,
// avatar URLs, etc.
function escHtml(s: string): string {
  return s
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;')
    .replace(/'/g, '&#39;');
}

// Avatar URLs rendered into share-page <img src="..."> must be same-origin
// paths or https: URLs — never javascript: or data: URIs.
function safeAvatarUrl(u: string): string {
  if (u.startsWith('/')) return u;
  if (/^https:\/\/[A-Za-z0-9.-]+(\/|$)/.test(u)) return u;
  return '/avatars/nova-logo.png';
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

// Post-editor options: allow_comments, audience_control, tag_products, cover_key.
// Same deploy-safety pattern as ensureAiColumn.
let videoOptsEnsured = false;
async function ensureVideoOptionsColumns(db: D1Database): Promise<void> {
  if (videoOptsEnsured) return;
  const cols = [
    'ALTER TABLE videos ADD COLUMN allow_comments INTEGER NOT NULL DEFAULT 1',
    "ALTER TABLE videos ADD COLUMN audience_control TEXT NOT NULL DEFAULT 'everyone'",
    'ALTER TABLE videos ADD COLUMN tag_products INTEGER NOT NULL DEFAULT 0',
    "ALTER TABLE videos ADD COLUMN cover_key TEXT NOT NULL DEFAULT ''",
  ];
  for (const sql of cols) {
    try {
      await db.prepare(sql).run();
    } catch {
      // Column already exists.
    }
  }
  videoOptsEnsured = true;
}

// TOTP 2FA columns on users (totp_secret, totp_enabled). Deploy-safe: if an
// older database never ran the schema ALTERs, the endpoints below create the
// columns lazily instead of 500ing on first use.
let totpColsEnsured = false;
async function ensureTotpColumns(db: D1Database): Promise<void> {
  if (totpColsEnsured) return;
  const cols = [
    'ALTER TABLE users ADD COLUMN totp_secret TEXT',
    'ALTER TABLE users ADD COLUMN totp_enabled INTEGER NOT NULL DEFAULT 0',
  ];
  for (const sql of cols) {
    try {
      await db.prepare(sql).run();
    } catch {
      // Column already exists.
    }
  }
  totpColsEnsured = true;
}

// Inbox tables: stories (24h expiry), story_views, system_notifications.
// Deploy-safe: CREATE TABLE IF NOT EXISTS, called lazily per request.
let inboxTablesEnsured = false;

// Voice-note duration on chat messages. Deploy-safe: ALTER TABLE in try/catch.
let messageColsEnsured = false;
async function ensureMessageColumns(db: D1Database): Promise<void> {
  if (messageColsEnsured) return;
  try {
    await db.prepare('ALTER TABLE messages ADD COLUMN duration_s INTEGER NOT NULL DEFAULT 0').run();
  } catch {
    // Column already exists.
  }
  messageColsEnsured = true;
}
async function ensureInboxTables(db: D1Database): Promise<void> {
  if (inboxTablesEnsured) return;
  await db.batch([
    db.prepare(`CREATE TABLE IF NOT EXISTS stories (
      id TEXT PRIMARY KEY,
      uid TEXT NOT NULL,
      media_key TEXT NOT NULL,
      media_type TEXT NOT NULL DEFAULT 'photo',
      created_at INTEGER NOT NULL,
      expires_at INTEGER NOT NULL
    )`),
    db.prepare('CREATE INDEX IF NOT EXISTS idx_stories_uid ON stories(uid, expires_at)'),
    db.prepare(`CREATE TABLE IF NOT EXISTS story_views (
      story_id TEXT NOT NULL,
      uid TEXT NOT NULL,
      created_at INTEGER NOT NULL,
      PRIMARY KEY (story_id, uid)
    )`),
    db.prepare(`CREATE TABLE IF NOT EXISTS system_notifications (
      id TEXT PRIMARY KEY,
      uid TEXT NOT NULL,
      title TEXT NOT NULL,
      body TEXT NOT NULL DEFAULT '',
      type TEXT NOT NULL DEFAULT 'general',
      created_at INTEGER NOT NULL,
      read_at INTEGER NOT NULL DEFAULT 0
    )`),
    db.prepare('CREATE INDEX IF NOT EXISTS idx_sysnotif_uid ON system_notifications(uid, created_at)'),
    db.prepare(`CREATE TABLE IF NOT EXISTS thread_reads (
      thread_id TEXT NOT NULL,
      uid TEXT NOT NULL,
      last_read_at INTEGER NOT NULL DEFAULT 0,
      PRIMARY KEY (thread_id, uid)
    )`),
  ]);
  inboxTablesEnsured = true;
}

// X-style company affiliations: a gold-badge company can mark users as its
// affiliates (employees, sub-brands). Only the COMPANY can create these —
// users can never self-affiliate (scam prevention). One company per user.
let affiliationsEnsured = false;
async function ensureAffiliationsTable(db: D1Database): Promise<void> {
  if (affiliationsEnsured) return;
  await db.batch([
    db.prepare(`CREATE TABLE IF NOT EXISTS affiliations (
      id TEXT PRIMARY KEY,
      company_uid TEXT NOT NULL,
      user_uid TEXT NOT NULL,
      created_at INTEGER NOT NULL,
      UNIQUE (user_uid)
    )`),
    db.prepare('CREATE INDEX IF NOT EXISTS idx_affiliations_company ON affiliations(company_uid)'),
  ]);
  affiliationsEnsured = true;
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

// Deploy-safe: adds verification_type/verification_expires_at to users,
// and tier to verification_subscriptions, if missing.
let verificationColsEnsured = false;
async function ensureVerificationColumns(db: D1Database): Promise<void> {
  if (verificationColsEnsured) return;
  try {
    await db.prepare(`ALTER TABLE users ADD COLUMN verification_type TEXT NOT NULL DEFAULT ''`).run();
  } catch { /* already exists */ }
  try {
    await db.prepare(`ALTER TABLE users ADD COLUMN verification_expires_at INTEGER NOT NULL DEFAULT 0`).run();
  } catch { /* already exists */ }
  try {
    await db.prepare(`ALTER TABLE verification_subscriptions ADD COLUMN tier TEXT NOT NULL DEFAULT 'personal'`).run();
  } catch { /* already exists or table missing */ }
  verificationColsEnsured = true;
}


// ---------- subdomain marketplace (domains.novamail.store) ----------
// Sell subdomains of novamail.store to anyone: email-based purchase, no Nova
// account required. Base price $1/mo; short/premium names cost more.
// Payment via Flutterwave hosted checkout. The checkout collects the payer's
// email and Flutterwave emails the receipt there — that is the email-ownership
// gate, because this backend has no outbound email service configured.
// DNS is provisioned via the Cloudflare API from the Worker, which REQUIRES a
// Workers secret named CLOUDFLARE_DNS_TOKEN: an API token with Zone -> DNS ->
// Edit permission on the novamail.store zone. (The wrangler deploy token is
// NOT available at runtime; this must be a separate least-privilege token.)
// Routes the parent must add in Cloudflare for this to work end-to-end:
//   domains.novamail.store/* -> nova-api   (the marketplace itself)
//   *.novamail.store/*        -> nova-api   (buyer "coming soon" parked pages)
const DOMAIN_ZONE_ID = '1bfa194fd141b59c5dd0e7c31c064a0a'; // novamail.store
const DOMAIN_MONTH_MS = 30 * 86400 * 1000;

// Names that are never for sale (infrastructure / brand / confusing).
const DOMAIN_RESERVED = new Set([
  'www', 'api', 'mail', 'admin', 'app', 'cdn', 'static', 'assets', 'support',
  'help', 'blog', 'shop', 'store', 'status', 'dev', 'staging', 'test', 'qa',
  'ftp', 'dns', 'ns1', 'ns2', 'webmail', 'smtp', 'pop', 'imap', 'secure',
  'login', 'account', 'billing', 'pay', 'payment', 'checkout', 'coins',
  'nova', 'user', 'users', 'domains', 'domain', 'root', 'localhost',
  // Osh's personal subdomains — never for sale
  'profile', 'marketplace', 'card', 'forex', 'acp-relay', 'browser',
  'desk', 'room', 'ssh', 'termux', 'termux-ssh', 'uaht',
]);

// Premium pricing by length: short names cost more.
function domainPriceFor(name: string): number {
  const len = name.length;
  if (len <= 3) return 10;
  if (len <= 6) return 5;
  return 1;
}

// DNS label rules: lowercase alnum + hyphen, 1-63 chars, no leading/trailing hyphen.
function isValidSubdomain(name: string): boolean {
  return /^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$/.test(name);
}

// Buyer-supplied point-to target: bare hostname only (no scheme/path/port).
function isValidHostname(host: string): boolean {
  return /^(?=.{1,253}$)([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,}$/.test(host);
}

interface DomainPurchase {
  tx_ref: string; subdomain: string; email: string; target: string;
  amount_usd: number; kind: string; settled: number;
}
interface SubdomainRow {
  id: string; subdomain: string; owner_email: string; price_monthly: number;
  target: string; status: string; dns_record_id: string;
  created_at: number; expires_at: number;
}

let subdomainTablesEnsured = false;
async function ensureSubdomainTables(db: D1Database): Promise<void> {
  if (subdomainTablesEnsured) return;
  await db.batch([
    db.prepare(`CREATE TABLE IF NOT EXISTS subdomains (
      id TEXT PRIMARY KEY,
      subdomain TEXT NOT NULL,
      owner_email TEXT NOT NULL,
      price_monthly REAL NOT NULL,
      target TEXT NOT NULL DEFAULT '',
      status TEXT NOT NULL DEFAULT 'active',
      dns_record_id TEXT NOT NULL DEFAULT '',
      created_at INTEGER NOT NULL,
      expires_at INTEGER NOT NULL,
      UNIQUE (subdomain)
    )`),
    db.prepare('CREATE INDEX IF NOT EXISTS idx_subdomains_email ON subdomains(owner_email)'),
    db.prepare('CREATE INDEX IF NOT EXISTS idx_subdomains_expiry ON subdomains(status, expires_at)'),
    db.prepare(`CREATE TABLE IF NOT EXISTS domain_purchases (
      tx_ref TEXT PRIMARY KEY,
      subdomain TEXT NOT NULL,
      email TEXT NOT NULL,
      target TEXT NOT NULL DEFAULT '',
      amount_usd REAL NOT NULL,
      kind TEXT NOT NULL DEFAULT 'buy',
      settled INTEGER NOT NULL DEFAULT 0,
      created_at INTEGER NOT NULL
    )`),
  ]);
  subdomainTablesEnsured = true;
}

async function domainAvailability(db: D1Database, name: string): Promise<{ available: boolean; reason: string }> {
  if (!isValidSubdomain(name)) return { available: false, reason: 'invalid_name' };
  if (DOMAIN_RESERVED.has(name)) return { available: false, reason: 'reserved' };
  await ensureSubdomainTables(db);
  const row = await db.prepare(
    "SELECT 1 FROM subdomains WHERE subdomain = ? AND status = 'active' AND expires_at > ?"
  ).bind(name, now()).first();
  if (row) return { available: false, reason: 'taken' };
  return { available: true, reason: '' };
}

async function cfDnsCreate(env: Env, name: string, content: string): Promise<string> {
  const token = env.CLOUDFLARE_DNS_TOKEN;
  if (!token) throw httpError(500, 'dns_not_configured');
  const base = `https://api.cloudflare.com/client/v4/zones/${DOMAIN_ZONE_ID}/dns_records`;
  const headers = { 'Authorization': `Bearer ${token}`, 'Content-Type': 'application/json' };
  const r = await fetch(base, {
    method: 'POST', headers,
    body: JSON.stringify({ type: 'CNAME', name, content, ttl: 1, proxied: true }),
  });
  const d = (await r.json()) as { success: boolean; result?: { id: string }; errors?: Array<{ code: number; message: string }> };
  if (d.success && d.result?.id) return d.result.id;
  const codes = (d.errors || []).map((e) => e.code);
  if (codes.includes(81057)) {
    // Identical record already exists (e.g. orphan from a partial provision) — reuse it.
    const q = await fetch(`${base}?type=CNAME&name=${encodeURIComponent(name)}`, { headers });
    const qd = (await q.json()) as { success: boolean; result?: Array<{ id: string; content: string }> };
    const hit = (qd.result || []).find((x) => x.content === content) || (qd.result || [])[0];
    if (hit) return hit.id;
  }
  console.error('cf dns create failed');
  throw httpError(502, 'dns_provision_failed');
}

async function cfDnsDelete(env: Env, recordId: string): Promise<void> {
  const token = env.CLOUDFLARE_DNS_TOKEN;
  if (!token || !recordId) return;
  try {
    await fetch(`https://api.cloudflare.com/client/v4/zones/${DOMAIN_ZONE_ID}/dns_records/${recordId}`, {
      method: 'DELETE',
      headers: { 'Authorization': `Bearer ${token}` },
    });
  } catch { /* best effort; record may already be gone */ }
}

// Provision a paid domain purchase: create the DNS CNAME and activate the
// subdomain row. Idempotent — safe to call from webhook, callback, renewals,
// and the manual confirm endpoint. Throws (leaving the purchase unsettled,
// therefore retryable) if DNS provisioning fails — fail closed so nobody
// pays for a domain that was never pointed.
async function provisionDomainPurchase(env: Env, txRef: string): Promise<void> {
  await ensureSubdomainTables(env.DB);
  const p = await env.DB.prepare(
    'SELECT tx_ref, subdomain, email, target, amount_usd, kind, settled FROM domain_purchases WHERE tx_ref = ?'
  ).bind(txRef).first<DomainPurchase>();
  if (!p || p.settled) return; // unknown tx_ref, or already provisioned
  const name = p.subdomain;
  const t = now();
  const desiredTarget = p.target || 'novamail.store';
  const existing = await env.DB.prepare(
    'SELECT id, target, status, dns_record_id, expires_at FROM subdomains WHERE subdomain = ?'
  ).bind(name).first<SubdomainRow>();
  const fqdn = `${name}.novamail.store`;
  const live = !!existing && (existing.status === 'active' || existing.status === 'pending_dns') && existing.expires_at > t;
  let recordId = existing?.dns_record_id || '';
  if (!live || !existing || existing.target !== desiredTarget || !recordId) {
    if (recordId) await cfDnsDelete(env, recordId);
    // Default (no buyer target): point at the apex; the Worker serves a
    // branded "coming soon" page per-host (see the parked-subdomain block in
    // fetch). That requires the `*.novamail.store/*` -> nova-api route.
    recordId = await cfDnsCreate(env, fqdn, desiredTarget);
  }
  const newExpiry = live ? existing!.expires_at + DOMAIN_MONTH_MS : t + DOMAIN_MONTH_MS;
  if (existing) {
    await env.DB.prepare(
      "UPDATE subdomains SET owner_email = ?, price_monthly = ?, target = ?, status = 'active', dns_record_id = ?, expires_at = ? WHERE id = ?"
    ).bind(p.email, p.amount_usd, p.target, recordId, newExpiry, existing.id).run();
  } else {
    await env.DB.prepare(
      `INSERT INTO subdomains (id, subdomain, owner_email, price_monthly, target, status, dns_record_id, created_at, expires_at)
       VALUES (?, ?, ?, ?, ?, 'active', ?, ?, ?)`
    ).bind(newId(), name, p.email, p.amount_usd, p.target, recordId, t, newExpiry).run();
  }
  await env.DB.prepare('UPDATE domain_purchases SET settled = 1 WHERE tx_ref = ?').bind(txRef).run();
}


// ---------- Buyer DNS management (security-guarded) ----------
// Owners of active subdomains may manage A/CNAME/TXT records under their
// own namespace only. NS/MX/SRV are never allowed (hijack/spam vectors).
const DNS_ALLOWED_TYPES = ['A', 'CNAME', 'TXT'] as const;

// Substring blocklist for CNAME targets: known phishing/impersonation lures.
// Simple and strict by design — a blocked target fails closed (400).
const DNS_TARGET_BLOCKLIST = [
  'paypal', 'appleid', 'icloud', 'apple-pay', 'microsoft', 'office365',
  'metamask', 'phantom', 'trustwallet', 'binance', 'coinbase', 'blockchain',
  'chase', 'wellsfargo', 'bankofamerica', 'citi', 'usps', 'fedex', 'dhl',
  'amazon', 'netflix', 'irs', 'verify-account', 'secure-login', 'account-update',
];

function isValidIPv4(ip: string): boolean {
  const parts = ip.split('.');
  if (parts.length !== 4) return false;
  return parts.every((p) => /^\d{1,3}$/.test(p) && Number(p) >= 0 && Number(p) <= 255);
}

// DNS record name as seen by the buyer: '@' (the subdomain apex) or a single
// label like 'www' / 'blog'. Dots are rejected so buyers cannot escape their
// own namespace (no evil.other.com, no _dmarc tricks on the parent zone).
function isValidDnsName(name: string): boolean {
  if (name === '@') return true;
  return /^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$/.test(name);
}

function dnsFqdn(subdomain: string, name: string): string {
  return name === '@' ? `${subdomain}.novamail.store` : `${name}.${subdomain}.novamail.store`;
}

function blocklistedTarget(host: string): boolean {
  const h = host.toLowerCase();
  return DNS_TARGET_BLOCKLIST.some((b) => h.includes(b));
}

interface DnsRecordRow {
  id: string; subdomain_id: string; type: string; name: string;
  content: string; ttl: number; cf_record_id: string; created_at: number;
}

async function ensureDnsTables(db: D1Database): Promise<void> {
  await ensureSubdomainTables(db);
  await db.batch([
    db.prepare(`CREATE TABLE IF NOT EXISTS dns_records (
      id TEXT PRIMARY KEY,
      subdomain_id TEXT NOT NULL,
      type TEXT NOT NULL,
      name TEXT NOT NULL,
      content TEXT NOT NULL,
      ttl INTEGER NOT NULL DEFAULT 3600,
      cf_record_id TEXT NOT NULL DEFAULT '',
      created_at INTEGER NOT NULL
    )`),
    db.prepare('CREATE INDEX IF NOT EXISTS idx_dns_records_sub ON dns_records(subdomain_id)'),
    db.prepare(`CREATE TABLE IF NOT EXISTS dns_change_log (
      id TEXT PRIMARY KEY,
      subdomain_id TEXT NOT NULL,
      action TEXT NOT NULL,
      details TEXT NOT NULL DEFAULT '',
      ip TEXT NOT NULL DEFAULT '',
      created_at INTEGER NOT NULL
    )`),
    db.prepare('CREATE INDEX IF NOT EXISTS idx_dns_log_sub ON dns_change_log(subdomain_id, created_at)'),
    db.prepare(`CREATE TABLE IF NOT EXISTS abuse_reports (
      id TEXT PRIMARY KEY,
      subdomain TEXT NOT NULL,
      reason TEXT NOT NULL,
      reporter_email TEXT NOT NULL DEFAULT '',
      status TEXT NOT NULL DEFAULT 'open',
      created_at INTEGER NOT NULL
    )`),
    db.prepare('CREATE INDEX IF NOT EXISTS idx_abuse_reports_status ON abuse_reports(status, created_at)'),
  ]);
}

async function dnsLog(db: D1Database, subdomainId: string, action: string, details: string, ip: string): Promise<void> {
  await db.prepare(
    'INSERT INTO dns_change_log (id, subdomain_id, action, details, ip, created_at) VALUES (?, ?, ?, ?, ?, ?)'
  ).bind(newId(), subdomainId, action, details.slice(0, 500), ip.slice(0, 64), now()).run();
}

// Max 10 add/delete changes per rolling 24h per subdomain. Throws 429.
async function dnsChangeQuota(db: D1Database, subdomainId: string): Promise<void> {
  const r = await db.prepare(
    "SELECT COUNT(*) AS c FROM dns_change_log WHERE subdomain_id = ? AND action IN ('add', 'delete') AND created_at > ?"
  ).bind(subdomainId, now() - 86400000).first<{ c: number }>();
  if ((r?.c || 0) >= 10) throw httpError(429, 'dns_rate_limited');
}

// Generalized Cloudflare DNS create for buyer-managed records.
// A/CNAME are proxied (Cloudflare forces ttl=1/auto when proxied);
// TXT is DNS-only with the requested ttl.
async function cfDnsCreateTyped(env: Env, type: string, name: string, content: string, ttl: number): Promise<string> {
  const token = env.CLOUDFLARE_DNS_TOKEN;
  if (!token) throw httpError(500, 'dns_not_configured');
  const proxied = type !== 'TXT';
  const r = await fetch(`https://api.cloudflare.com/client/v4/zones/${DOMAIN_ZONE_ID}/dns_records`, {
    method: 'POST',
    headers: { 'Authorization': `Bearer ${token}`, 'Content-Type': 'application/json' },
    body: JSON.stringify({ type, name, content, ttl: proxied ? 1 : ttl, proxied }),
  });
  const d = (await r.json()) as { success: boolean; result?: { id: string }; errors?: Array<{ code: number }> };
  if (d.success && d.result?.id) return d.result.id;
  console.error('cf dns typed create failed');
  throw httpError(502, 'dns_provision_failed');
}

// Look up an owned subdomain row (any status) for DNS management.
async function ownedSubdomain(db: D1Database, name: string, email: string): Promise<{ id: string; subdomain: string; owner_email: string; status: string }> {
  const sub = await db.prepare('SELECT id, subdomain, owner_email, status FROM subdomains WHERE subdomain = ?')
    .bind(name).first<{ id: string; subdomain: string; owner_email: string; status: string }>();
  if (!sub || sub.owner_email !== email) throw httpError(404, 'domain_not_found');
  return sub;
}

// Marketplace page for domains.novamail.store. Self-contained HTML/JS:
// search availability, buy via Flutterwave hosted checkout, renew, and list
// "my domains" by email. No Nova account required.
function domainMarketplaceHtml(): string {
  return `<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1,maximum-scale=1">
<title>Nova Domains — yourname.novamail.store</title>
<style>
:root{--gold:#D4AF37;--bg:#0b0b0f;--card:#14141b;--muted:#9a9aa5}
*{box-sizing:border-box}
body{background:var(--bg);color:#fff;font-family:system-ui,-apple-system,sans-serif;margin:0;min-height:100vh}
.wrap{max-width:520px;margin:0 auto;padding:28px 18px 60px}
.logo{display:block;width:64px;height:64px;border-radius:18px;margin:4px auto 10px}
h1{text-align:center;font-size:26px;margin:0 0 4px}
.sub{text-align:center;color:var(--muted);font-size:14px;margin:0 0 22px}
.card{background:var(--card);border:1px solid #26262f;border-radius:16px;padding:18px;margin-bottom:14px}
label{display:block;font-size:13px;color:var(--muted);margin:0 0 6px}
input{width:100%;background:#0e0e13;border:1px solid #2c2c36;border-radius:10px;color:#fff;padding:12px 14px;font-size:16px;margin-bottom:12px}
input:focus{outline:none;border-color:var(--gold)}
.btn{display:block;width:100%;background:linear-gradient(135deg,#e8c55a,#b8941f);color:#111;font-weight:800;font-size:16px;border:none;border-radius:12px;padding:14px;cursor:pointer}
.btn:disabled{opacity:.45;cursor:not-allowed}
.btn.ghost{background:#1c1c24;color:#fff;border:1px solid #2c2c36;margin-top:10px}
.row{display:flex;gap:10px}
.row .btn{margin:0}
.status{text-align:center;font-size:14px;min-height:22px;margin:10px 0;color:var(--muted)}
.status.err{color:#ff7a7a}
.status.ok{color:#7dff9a}
.price{font-size:30px;font-weight:900;color:var(--gold);text-align:center}
.per{text-align:center;color:var(--muted);font-size:13px;margin-bottom:8px}
table{width:100%;border-collapse:collapse;font-size:14px;margin-top:6px}
td{padding:8px 4px;border-bottom:1px solid #22222b}
td:last-child{text-align:right;color:var(--gold);font-weight:700}
.dom{display:flex;align-items:center;justify-content:space-between;background:#0e0e13;border:1px solid #26262f;border-radius:12px;padding:12px 14px;margin-bottom:10px}
.dom .n{font-weight:800}
.dom .m{font-size:12px;color:var(--muted)}
.dom button{background:none;border:1px solid var(--gold);color:var(--gold);border-radius:8px;padding:8px 14px;cursor:pointer;font-weight:700}
.small{font-size:12px;color:var(--muted);text-align:center;margin-top:18px;line-height:1.7}
h2{font-size:17px;margin:22px 0 10px}
.hint{font-size:12px;color:var(--muted);margin:-6px 0 12px}
</style>
</head>
<body>
<div class="wrap">
<img class="logo" src="https://user.novamail.store/avatars/nova-logo.png" alt="Nova">
<h1>Nova Domains</h1>
<p class="sub">Own <b>yourname</b>.novamail.store — from $1/month</p>

<div class="card">
<label>Search a subdomain</label>
<div class="row">
<input id="name" placeholder="e.g. shop" autocapitalize="off" autocomplete="off" spellcheck="false" style="margin-bottom:0">
<button class="btn" id="checkBtn" onclick="checkName()">Check</button>
</div>
<div class="status" id="checkStatus"></div>
<div id="buyBox" style="display:none">
<div class="price">$<span id="priceNum">1</span></div>
<div class="per">per month · renews monthly · cancel anytime</div>
<label>Your email</label>
<input id="email" type="email" placeholder="you@example.com" autocomplete="email">
<label>Point it to <span style="color:#6a6a75">(optional hostname — leave blank for a "coming soon" page)</span></label>
<input id="target" placeholder="e.g. myshop.myshopify.com" autocapitalize="off" autocomplete="off" spellcheck="false">
<div class="hint">We create the DNS for you instantly after payment.</div>
<button class="btn" id="buyBtn" onclick="buy()">Buy <span id="buyName"></span></button>
</div>
</div>

<div class="card">
<h2 style="margin-top:0">Pricing</h2>
<table>
<tr><td>7+ characters <span style="color:#6a6a75">(e.g. mybrand)</span></td><td>$1/mo</td></tr>
<tr><td>4–6 characters <span style="color:#6a6a75">(e.g. shop)</span></td><td>$5/mo</td></tr>
<tr><td>1–3 characters <span style="color:#6a6a75">(e.g. go)</span></td><td>$10/mo</td></tr>
</table>
<p class="small">Names like www, api, mail and admin are reserved and never for sale.<br>Expired names return to the pool — renew before the due date.</p>
</div>

<div class="card">
<h2 style="margin-top:0">My domains</h2>
<label>Email used at purchase</label>
<div class="row">
<input id="myEmail" type="email" placeholder="you@example.com" style="margin-bottom:0">
<button class="btn ghost" id="myBtn" onclick="myDomains()">Find</button>
</div>
<div class="status" id="myStatus"></div>
<div id="myList"></div>
</div>

<div class="card" id="dnsCard" style="display:none">
<h2 style="margin-top:0">Manage DNS — <span id="dnsSub"></span></h2>
<div class="status" id="dnsStatus"></div>
<div id="dnsList"></div>
<h2>Add record</h2>
<div class="hint">Allowed: <b>A</b>, <b>CNAME</b>, <b>TXT</b> only — NS/MX/SRV are blocked.<br>Max 10 changes per 24h. All changes are logged.</div>
<label>Type</label>
<select id="dnsType" style="width:100%;background:#0e0e13;border:1px solid #2c2c36;border-radius:10px;color:#fff;padding:12px 14px;font-size:16px;margin-bottom:12px">
<option value="A">A — IPv4 address</option>
<option value="CNAME">CNAME — hostname</option>
<option value="TXT">TXT — text</option>
</select>
<label>Name <span style="color:#6a6a75">(@ = your subdomain itself, or a label like www)</span></label>
<input id="dnsName" placeholder="@" autocapitalize="off" autocomplete="off" spellcheck="false">
<label>Content</label>
<input id="dnsContent" placeholder="A: 93.184.216.34 · CNAME: example.com · TXT: some text" autocapitalize="off" autocomplete="off" spellcheck="false">
<label>TTL <span style="color:#6a6a75">(seconds, 60–86400)</span></label>
<input id="dnsTtl" placeholder="3600" inputmode="numeric" autocomplete="off">
<button class="btn" id="dnsAddBtn" onclick="dnsAdd()">Add record</button>
<button class="btn ghost" onclick="document.getElementById('dnsCard').style.display='none'">Close</button>
<p class="small">Security: phishing/impersonation targets are blocked, NS/MX/SRV never allowed,<br>abuse is suspended immediately.</p>
</div>

<div class="card">
<h2 style="margin-top:0">Report abuse</h2>
<div class="hint">See phishing, malware or impersonation on a .novamail.store name? Tell us.</div>
<label>Subdomain</label>
<input id="repSub" placeholder="e.g. badactor" autocapitalize="off" autocomplete="off" spellcheck="false">
<label>What happened?</label>
<textarea id="repReason" rows="3" placeholder="Describe the abuse…" style="width:100%;background:#0e0e13;border:1px solid #2c2c36;border-radius:10px;color:#fff;padding:12px 14px;font-size:16px;margin-bottom:12px;font-family:inherit"></textarea>
<label>Your email (optional)</label>
<input id="repEmail" type="email" placeholder="you@example.com" autocomplete="email">
<button class="btn ghost" id="repBtn" onclick="reportAbuse()">Submit report</button>
<div class="status" id="repStatus"></div>
</div>

<p class="small">Secure payment by Flutterwave — cards, bank transfer and mobile money.<br>Subdomains are DNS CNAME records on novamail.store.</p>
</div>
<script>
function setStatus(id,msg,cls){var e=document.getElementById(id);e.textContent=msg;e.className='status'+(cls?' '+cls:'');}
function cleanName(v){return v.trim().toLowerCase().replace(/\\.novamail\\.store$/,'');}
var lastChecked=null;
async function checkName(){
  var name=cleanName(document.getElementById('name').value);
  if(!name){setStatus('checkStatus','Type a name first.','err');return;}
  setStatus('checkStatus','Checking…','');document.getElementById('buyBox').style.display='none';
  try{
    var r=await fetch('/api/domains/check?name='+encodeURIComponent(name));
    var d=await r.json();
    if(d.available){
      lastChecked={name:d.name,price:d.price_usd};
      document.getElementById('priceNum').textContent=d.price_usd;
      document.getElementById('buyName').textContent=d.name+'.novamail.store';
      document.getElementById('buyBox').style.display='block';
      setStatus('checkStatus',d.name+'.novamail.store is available!','ok');
    }else{
      var why=d.reason==='reserved'?'That name is reserved.':d.reason==='taken'?'Already taken — try another.':'Invalid name (letters, numbers, hyphens only).';
      setStatus('checkStatus',why,'err');
    }
  }catch(e){setStatus('checkStatus','Check failed — try again.','err');}
}
async function buy(){
  if(!lastChecked)return;
  var email=document.getElementById('email').value.trim();
  var target=cleanName(document.getElementById('target').value);
  if(!/^[^@\\s]+@[^@\\s]+\\.[^@\\s]+$/.test(email)){setStatus('checkStatus','Enter a valid email.','err');return;}
  var btn=document.getElementById('buyBtn');btn.disabled=true;btn.textContent='Creating checkout…';
  try{
    var r=await fetch('/api/domains/buy',{method:'POST',headers:{'Content-Type':'application/json'},
      body:JSON.stringify({subdomain:lastChecked.name,email:email,target:target||undefined})});
    var d=await r.json();
    if(!r.ok)throw new Error(d.error||'buy_failed');
    var url=d.checkoutUrl||(d.flutterwave&&d.flutterwave.data&&d.flutterwave.data.link);
    if(!url)throw new Error('no_checkout');
    window.location.href=url;
  }catch(e){
    setStatus('checkStatus','Could not start payment: '+String(e.message||e),'err');
    btn.disabled=false;btn.textContent='Buy '+lastChecked.name+'.novamail.store';
  }
}
async function renew(name,email){
  if(!confirm('Renew '+name+'.novamail.store for another month?'))return;
  try{
    var r=await fetch('/api/domains/renew',{method:'POST',headers:{'Content-Type':'application/json'},
      body:JSON.stringify({subdomain:name,email:email})});
    var d=await r.json();
    if(!r.ok)throw new Error(d.error||'renew_failed');
    var url=d.checkoutUrl||(d.flutterwave&&d.flutterwave.data&&d.flutterwave.data.link);
    if(url)window.location.href=url;
  }catch(e){setStatus('myStatus','Renew failed: '+String(e.message||e),'err');}
}
async function myDomains(){
  var email=document.getElementById('myEmail').value.trim();
  if(!email){setStatus('myStatus','Enter your email.','err');return;}
  setStatus('myStatus','Loading…','');document.getElementById('myList').innerHTML='';
  try{
    var r=await fetch('/api/domains/my?email='+encodeURIComponent(email));
    var d=await r.json();
    if(!r.ok)throw new Error(d.error||'load_failed');
    if(!d.domains.length){setStatus('myStatus','No domains found for that email.','');return;}
    setStatus('myStatus','','');
    var html='';
    d.domains.forEach(function(x){
      var exp=new Date(x.expires_at).toLocaleDateString();
      var st=x.status==='active'?'Active · renews '+exp:x.status;
      html+='<div class="dom"><div><div class="n">'+x.fqdn+'</div><div class="m">'+st+' · $'+x.price_monthly+'/mo</div></div><div style="display:flex;gap:8px">'+
        (x.status==='active'?'<button onclick="dnsManage(\\''+x.subdomain+'\\',\\''+email.replace(/\\'/g,"")+'\\')">DNS</button>':'')+
        (x.status==='active'?'<button onclick="renew(\\''+x.subdomain+'\\',\\''+email.replace(/\\'/g,"")+'\\')">Renew</button>':'')+'</div></div>';
    });
    document.getElementById('myList').innerHTML=html;
  }catch(e){setStatus('myStatus','Load failed: '+String(e.message||e),'err');}
}
var dnsCtx={sub:'',email:''};
function escH(s){return String(s).replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;').replace(/"/g,'&quot;');}
function dnsManage(sub,email){
  dnsCtx={sub:sub,email:email};
  document.getElementById('dnsSub').textContent=sub+'.novamail.store';
  document.getElementById('dnsCard').style.display='block';
  dnsLoad();
  document.getElementById('dnsCard').scrollIntoView();
}
async function dnsLoad(){
  setStatus('dnsStatus','Loading…','');
  document.getElementById('dnsList').innerHTML='';
  try{
    var r=await fetch('/api/domains/dns?subdomain='+encodeURIComponent(dnsCtx.sub)+'&email='+encodeURIComponent(dnsCtx.email));
    var d=await r.json();
    if(!r.ok)throw new Error(d.error||'load_failed');
    setStatus('dnsStatus','','');
    if(!d.records.length){document.getElementById('dnsList').innerHTML='<p class="small">No custom records yet. Your subdomain currently points where you set it at purchase.</p>';return;}
    var html='<table>';
    d.records.forEach(function(x){
      html+='<tr><td><b>'+escH(x.type)+'</b> '+escH(x.fqdn)+'<br><span style="color:#6a6a75;font-size:12px">'+escH(x.content)+'</span></td>'+
        '<td><button class="btn ghost" style="margin:0;padding:6px 12px" onclick="dnsDel(\\''+x.id+'\\')">Delete</button></td></tr>';
    });
    html+='</table>';
    document.getElementById('dnsList').innerHTML=html;
  }catch(e){setStatus('dnsStatus','Load failed: '+String(e.message||e),'err');}
}
async function dnsAdd(){
  var type=document.getElementById('dnsType').value;
  var name=document.getElementById('dnsName').value.trim()||'@';
  var content=document.getElementById('dnsContent').value.trim();
  var ttl=document.getElementById('dnsTtl').value.trim();
  if(!content){setStatus('dnsStatus','Enter the record content.','err');return;}
  var btn=document.getElementById('dnsAddBtn');btn.disabled=true;btn.textContent='Adding…';
  try{
    var body={subdomain:dnsCtx.sub,email:dnsCtx.email,type:type,name:name,content:content};
    if(ttl)body.ttl=Number(ttl);
    var r=await fetch('/api/domains/dns',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify(body)});
    var d=await r.json();
    if(!r.ok)throw new Error(d.error||'add_failed');
    setStatus('dnsStatus','Record added — DNS can take a minute to propagate.','ok');
    document.getElementById('dnsContent').value='';
    dnsLoad();
  }catch(e){
    var msg=String(e.message||e);
    if(msg==='target_blocklisted')msg='That target looks like a phishing/impersonation lure and is blocked.';
    else if(msg==='dns_rate_limited')msg='Too many changes — max 10 per 24h.';
    else if(msg==='invalid_record_name')msg='Name must be @ or a single label (e.g. www).';
    setStatus('dnsStatus','Add failed: '+msg,'err');
  }
  btn.disabled=false;btn.textContent='Add record';
}
async function dnsDel(id){
  if(!confirm('Delete this DNS record?'))return;
  try{
    var r=await fetch('/api/domains/dns/'+encodeURIComponent(id),{method:'DELETE',headers:{'Content-Type':'application/json'},
      body:JSON.stringify({subdomain:dnsCtx.sub,email:dnsCtx.email})});
    var d=await r.json();
    if(!r.ok)throw new Error(d.error||'delete_failed');
    setStatus('dnsStatus','Record deleted.','ok');
    dnsLoad();
  }catch(e){setStatus('dnsStatus','Delete failed: '+String(e.message||e),'err');}
}
async function reportAbuse(){
  var sub=cleanName(document.getElementById('repSub').value);
  var reason=document.getElementById('repReason').value.trim();
  var email=document.getElementById('repEmail').value.trim();
  if(!sub){setStatus('repStatus','Enter the subdomain.','err');return;}
  if(reason.length<5){setStatus('repStatus','Describe what happened (min 5 characters).','err');return;}
  var btn=document.getElementById('repBtn');btn.disabled=true;btn.textContent='Sending…';
  try{
    var r=await fetch('/api/domains/report',{method:'POST',headers:{'Content-Type':'application/json'},
      body:JSON.stringify({subdomain:sub,reason:reason,reporter_email:email||undefined})});
    var d=await r.json();
    if(!r.ok)throw new Error(d.error||'report_failed');
    setStatus('repStatus','Thanks — report received. We review abuse reports promptly.','ok');
    document.getElementById('repReason').value='';
  }catch(e){setStatus('repStatus','Report failed: '+String(e.message||e),'err');}
  btn.disabled=false;btn.textContent='Submit report';
}
// Pre-fill the abuse form from ?report=<subdomain> (linked from parked pages).
(function(){
  var q=new URLSearchParams(location.search);
  if(q.get('report')){document.getElementById('repSub').value=cleanName(q.get('report'));document.getElementById('repSub').scrollIntoView();}
})();
// If the buyer just returned from Flutterwave (?tx_ref=&transaction_id=&status=),
// confirm the payment server-side.
(async function(){
  var q=new URLSearchParams(location.search);
  if(q.get('tx_ref')&&q.get('transaction_id')){
    setStatus('checkStatus','Confirming your payment…','');
    try{
      var r=await fetch('/api/domains/confirm',{method:'POST',headers:{'Content-Type':'application/json'},
        body:JSON.stringify({txRef:q.get('tx_ref'),transactionId:q.get('transaction_id')})});
      var d=await r.json();
      if(r.ok&&d.ok){setStatus('checkStatus','Payment confirmed! Your subdomain is live — DNS can take a minute to propagate.','ok');}
      else setStatus('checkStatus','We could not confirm that payment yet. If you were charged, try "My domains" in a few minutes.','err');
    }catch(e){setStatus('checkStatus','Confirmation is taking a while — check "My domains" shortly.','err');}
    history.replaceState(null,'',location.pathname);
  }
})();
document.getElementById('name').addEventListener('keydown',function(e){if(e.key==='Enter')checkName();});
</script>
</body>
</html>`;
}


// Admin gate: x-admin-key header. Used by the agent-run review console.
async function adminGuard(request: Request, env: Env): Promise<void> {
  await rateCheck(env.RATELIMIT, `ip:${request.headers.get('cf-connecting-ip') || 'x'}`, 30, 60);
  const key = request.headers.get('x-admin-key') || '';
  if (!env.ADMIN_REVIEW_KEY || key !== env.ADMIN_REVIEW_KEY) throw httpError(403, 'forbidden');
}

// Notify a user: realtime event + FCM push to registered devices.
// Also persists to system_notifications so it shows in the inbox
// System notifications list (account flags, support replies, payouts,
// orders, strikes/bans, seller reviews, broadcasts).
async function notifyUser(env: Env, uid: string, title: string, body: string, data: Record<string, string> = {}): Promise<void> {
  try {
    await ensureInboxTables(env.DB);
    await env.DB.prepare(
      'INSERT INTO system_notifications (id, uid, title, body, type, created_at) VALUES (?, ?, ?, ?, ?, ?)'
    ).bind(newId(), uid, title.slice(0, 120), body.slice(0, 500), data.kind || 'general', now()).run();
  } catch { /* persistence is best-effort */ }
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

/// Returns the active verification tier ('personal'|'business'|'company') or null.
async function verificationTier(db: D1Database, uid: string): Promise<string | null> {
  // Fast path: users.verification_type (set at settlement time)
  try {
    const u = await db.prepare(
      "SELECT verification_type FROM users WHERE uid = ? AND verification_expires_at > ?"
    ).bind(uid, now()).first<{ verification_type: string }>();
    if (u?.verification_type) return u.verification_type;
  } catch { /* column may not exist yet */ }
  // Fallback: subscriptions table
  const r = await db.prepare(
    "SELECT tier FROM verification_subscriptions WHERE uid = ? AND status = 'active' AND expires_at > ?"
  ).bind(uid, now()).first<{ tier: string }>();
  return r?.tier || null;
}

/// X-style affiliation: returns the company (gold badge) the user is
/// affiliated with, or null. Used to render the company logo badge next to
/// the user's name, like X's organization affiliation.
async function affiliationFor(db: D1Database, uid: string): Promise<{ uid: string; handle: string; display_name: string; avatar_url: string } | null> {
  const r = await db.prepare(
    `SELECT u.uid, u.handle, u.display_name, u.avatar_url
     FROM affiliations a JOIN users u ON u.uid = a.company_uid
     WHERE a.user_uid = ?`
  ).bind(uid).first<{ uid: string; handle: string; display_name: string; avatar_url: string }>();
  return r ?? null;
}

/// Caller must hold a company (gold) verification badge to manage affiliations.
/// Users can never affiliate themselves — only the company can grant it.
async function requireCompany(db: D1Database, uid: string): Promise<void> {
  const row = await db.prepare(
    'SELECT verification_type, is_official FROM users WHERE uid = ?'
  ).bind(uid).first<{ verification_type: string; is_official: number }>();
  const vtype = ((row?.verification_type as string) || '').toLowerCase();
  if (vtype !== 'company' && !row?.is_official) throw httpError(403, 'company_required');
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
  verification_type: string; // 'personal' | 'business' | ''
  affiliated_with: { uid: string; handle: string; display_name: string; avatar_url: string } | null;
}

async function publicUser(db: D1Database, uidOrHandle: string): Promise<PublicUser | null> {
  const row = await db
    .prepare('SELECT uid, handle, username, display_name, bio, avatar_url, kyc_status, status, is_bot, is_official, is_verified, verification_type, totp_enabled, trader_score, trades_completed, created_at FROM users WHERE uid = ? OR handle = ? OR username = ?')
    .bind(uidOrHandle, uidOrHandle, uidOrHandle)
    .first<Record<string, unknown>>();
  if (!row) return null;
  const uid = row.uid as string;
  const verified = !!row.is_verified || !!row.is_official || await isVerified(db, uid);
  // Business accounts (e.g. @nova company) get the pink badge; personal gets blue.
  // Fall back to 'business' for official accounts so the company badge stays pink.
  let vtype = (row.verification_type as string) || '';
  if (verified && !vtype) {
    // Check the subscriptions table for the purchased tier, then fall back
    vtype = (await verificationTier(db, uid)) || (row.is_official ? 'business' : 'personal');
  }
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
    is_verified: verified,
    verification_type: vtype,
    affiliated_with: await affiliationFor(db, uid),
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
          headers.set('x-content-type-options', 'nosniff');
          return new Response(obj.body, { headers });
        }
      }

      // ---------- ads.txt (public, no auth) ----------
      // AdSense requires ads.txt at the root domain.
      {
        const host = (request.headers.get('host') || '').split(':')[0].toLowerCase();
        if ((host === 'novamail.store' || host === 'www.novamail.store') && path === '/ads.txt' && method === 'GET') {
          const txt = 'google.com, pub-2431202994591245, DIRECT, f08c47fec0942fa0\n';
          return new Response(txt, { headers: { 'content-type': 'text/plain; charset=utf-8' } });
        }
      }

      // ---------- root domain verification page (public, no auth) ----------
      // AdSense requires verification at the top-level domain novamail.store.
      // Serve a simple page with the AdSense script so the crawler finds it.
      {
        const host = (request.headers.get('host') || '').split(':')[0].toLowerCase();
        if (host === 'novamail.store' && path === '/' && method === 'GET') {
          const html = `<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>Nova</title>
<script async src="https://pagead2.googlesyndication.com/pagead/js/adsbygoogle.js?client=ca-pub-2431202994591245" crossorigin="anonymous"></script>
<style>
body{background:#0b0b0f;color:#fff;font-family:system-ui,-apple-system,sans-serif;margin:0;min-height:100vh;display:flex;align-items:center;justify-content:center;text-align:center}
h1{font-size:32px;margin:0 0 12px}
a{color:#D4AF37;font-size:18px;text-decoration:none}
</style>
</head>
<body>
<div>
<h1>Nova</h1>
<p><a href="https://user.novamail.store/coins">Buy Nova Coins</a></p>
<p><a href=\"https://domains.novamail.store\">Get your own novamail.store subdomain \— from $1/mo</a></p>\n
</div>
</body>
</html>`;
          return new Response(html, { headers: { 'content-type': 'text/html; charset=utf-8', 'x-content-type-options': 'nosniff' } });
        }
      }

      // ---------- subdomain marketplace host (public, no auth) ----------
      // domains.novamail.store serves the marketplace. Buyer subdomains
      // (*.novamail.store, excluding user./domains./apex) get a branded
      // "coming soon" parked page when the buyer did not point the name
      // elsewhere. REQUIRES the Cloudflare routes:
      //   domains.novamail.store/* -> nova-api
      //   *.novamail.store/*        -> nova-api
      {
        const host = (request.headers.get('host') || '').split(':')[0].toLowerCase();
        if (host === 'domains.novamail.store' && path === '/' && method === 'GET') {
          await rateCheck(env.RATELIMIT, `ip:${request.headers.get('cf-connecting-ip') || 'x'}`, 60, 60);
          return new Response(domainMarketplaceHtml(), {
            headers: { 'content-type': 'text/html; charset=utf-8', 'x-content-type-options': 'nosniff' },
          });
        }
        if (
          host.endsWith('.novamail.store') &&
          host !== 'user.novamail.store' &&
          host !== 'domains.novamail.store' &&
          host !== 'novamail.store' &&
          path === '/' && method === 'GET'
        ) {
          await rateCheck(env.RATELIMIT, `ip:${request.headers.get('cf-connecting-ip') || 'x'}`, 60, 60);
          await ensureSubdomainTables(env.DB);
          const label = host.slice(0, -'.novamail.store'.length);
          const row = await env.DB.prepare(
            'SELECT subdomain, status FROM subdomains WHERE subdomain = ? AND expires_at > ?'
          ).bind(label, now()).first<{ subdomain: string; status: string }>();
          if (!row || (row.status !== 'active' && row.status !== 'suspended')) throw httpError(404, 'not_found');
          const safe = escHtml(row.subdomain);
          if (row.status === 'suspended') {
            const suspHtml = `<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>${safe}.novamail.store — suspended</title>
<style>
body{background:#0b0b0f;color:#fff;font-family:system-ui,-apple-system,sans-serif;margin:0;min-height:100vh;display:flex;align-items:center;justify-content:center;text-align:center}
h1{font-size:24px;margin:0 0 8px}
p{color:#9a9aa5}
a{color:#D4AF37;text-decoration:none;font-size:13px}
</style>
</head>
<body>
<div>
<h1>${safe}.novamail.store</h1>
<p>This subdomain has been suspended for abuse.</p>
<p><a href="https://domains.novamail.store/?report=${safe}">Report abuse</a> · <a href="https://domains.novamail.store">Nova Domains</a></p>
</div>
</body>
</html>`;
            return new Response(suspHtml, {
              headers: { 'content-type': 'text/html; charset=utf-8', 'x-content-type-options': 'nosniff' },
            });
          }
          const html = `<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>${safe}.novamail.store</title>
<style>
body{background:#0b0b0f;color:#fff;font-family:system-ui,-apple-system,sans-serif;margin:0;min-height:100vh;display:flex;align-items:center;justify-content:center;text-align:center}
h1{font-size:28px;margin:0 0 8px}
p{color:#9a9aa5}
a{color:#D4AF37;text-decoration:none}
</style>
</head>
<body>
<div>
<h1>${safe}.novamail.store</h1>
<p>Coming soon.</p>
<p style="margin-top:18px"><a href="https://domains.novamail.store/?report=${safe}" style="font-size:12px;color:#6a6a75">Report abuse</a></p>
<p><a href="https://domains.novamail.store">Get your own subdomain</a></p>
</div>
</body>
</html>`;
          return new Response(html, {
            headers: { 'content-type': 'text/html; charset=utf-8', 'x-content-type-options': 'nosniff' },
          });
        }
      }

      // ---------- web coin store (public, no auth) ----------
      // Buy Nova Coins outside the mobile app — same backend, same ledger.
      // Login via Firebase (email/password), pay via Flutterwave inline,
      // coins credit to the same nova_coin_ledger the app reads.
      if (path === '/coins' && method === 'GET') {
        const html = `<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1,maximum-scale=1">
<title>Buy Nova Coins — Nova</title>
<style>
:root{--gold:#D4AF37;--bg:#0b0b0f;--card:#14141b;--muted:#9a9aa5}
*{box-sizing:border-box}
body{background:var(--bg);color:#fff;font-family:system-ui,-apple-system,sans-serif;margin:0;min-height:100vh}
.wrap{max-width:480px;margin:0 auto;padding:24px 18px 48px}
.logo{display:block;width:76px;height:76px;border-radius:20px;margin:8px auto 12px}
h1{text-align:center;font-size:24px;margin:0 0 4px}
.sub{text-align:center;color:var(--muted);font-size:14px;margin:0 0 20px}
.card{background:var(--card);border:1px solid #26262f;border-radius:16px;padding:18px;margin-bottom:14px}
label{display:block;font-size:13px;color:var(--muted);margin:0 0 6px}
input{width:100%;background:#0e0e13;border:1px solid #2c2c36;border-radius:10px;color:#fff;padding:12px 14px;font-size:16px;margin-bottom:12px}
input:focus{outline:none;border-color:var(--gold)}
.btn{display:block;width:100%;background:linear-gradient(135deg,#e8c55a,#b8941f);color:#111;font-weight:800;font-size:16px;border:none;border-radius:12px;padding:14px;cursor:pointer}
.btn:disabled{opacity:.45;cursor:not-allowed}
.pkg{display:flex;align-items:center;justify-content:space-between;background:var(--card);border:1px solid #26262f;border-radius:16px;padding:16px;margin-bottom:12px}
.pkg-info{display:flex;align-items:center;gap:12px}
.coin{width:44px;height:44px;border-radius:50%;background:radial-gradient(circle at 30% 30%,#f4d97b,#b8941f);display:flex;align-items:center;justify-content:center;font-size:22px;font-weight:900;color:#111}
.pkg-coins{font-size:18px;font-weight:800}
.pkg-usd{color:var(--muted);font-size:14px}
.buy{width:auto;padding:10px 22px;font-size:15px;margin:0}
.balance{text-align:center;margin-bottom:18px}
.balance .n{font-size:34px;font-weight:900;color:var(--gold)}
.status{text-align:center;font-size:14px;min-height:22px;margin:10px 0;color:var(--muted)}
.status.err{color:#ff7a7a}
.status.ok{color:#7dff9a}
.row{display:flex;justify-content:space-between;align-items:center;margin-bottom:14px}
.link{color:var(--gold);font-size:14px;text-decoration:none;background:none;border:none;cursor:pointer;padding:0}
.small{font-size:12px;color:var(--muted);text-align:center;margin-top:16px;line-height:1.6}
.ad-slot{margin:0 0 14px;text-align:center}
.ad-slot .ad-label{font-size:10px;color:var(--muted);letter-spacing:1px;text-transform:uppercase;margin-bottom:4px}
</style>

<!-- GOOGLE ADSENSE SETUP: replace ca-pub-2431202994591245 with your real AdSense publisher ID, and replace every data-ad-slot="XXXXXXXXXX" below with your real ad unit IDs. -->
<script async src="https://pagead2.googlesyndication.com/pagead/js/adsbygoogle.js?client=ca-pub-2431202994591245" crossorigin="anonymous"></script>
</head>
<body>
<div class="wrap">
<img class="logo" src="/avatars/nova-logo.png" alt="Nova">
<h1>Nova Coins</h1>
<p class="sub">Top up here — coins appear in the Nova app instantly</p>
<div id="loginView" class="card">
<label>Username or email</label>
<input id="identifier" autocomplete="username" placeholder="e.g. zenas">
<label>Password</label>
<input id="password" type="password" autocomplete="current-password" placeholder="Your Nova password">
<button class="btn" id="loginBtn" onclick="doLogin()">Log in</button>
<div class="status" id="loginStatus"></div>
</div>
<div id="storeView" style="display:none">
<div class="row">
<span class="link" id="helloUser"></span>
<button class="link" onclick="doLogout()">Log out</button>
</div>
<div class="balance"><div class="n"><span id="balNum">0</span> coins</div><div class="sub">Your Nova Coin balance</div></div>
<div id="pkgList"></div>
<div class="status" id="payStatus"></div>
<p class="small">Secure payment by Flutterwave — cards, bank transfer,<br>mobile money and Apple Pay where available.</p>
<div class="ad-slot">
<div class="ad-label">Advertisement</div>
<ins class="adsbygoogle"
     style="display:block"
     data-ad-client="ca-pub-2431202994591245"
     data-ad-slot="XXXXXXXXXX"
     data-ad-format="auto"
     data-full-width-responsive="true"></ins>
<script>(adsbygoogle = window.adsbygoogle || []).push({});</script>
</div>
</div>
</div>
<script src="https://www.gstatic.com/firebasejs/10.12.2/firebase-app-compat.js"></script>
<script src="https://www.gstatic.com/firebasejs/10.12.2/firebase-auth-compat.js"></script>
<script src="https://checkout.flutterwave.com/v3.js"></script>
<script>
var firebaseConfig={apiKey:'AIzaSyCt0aYGuQPmVrRGT-_jGSmCAXCqn092GkE',authDomain:'nova-dc139.firebaseapp.com',projectId:'nova-dc139'};
firebase.initializeApp(firebaseConfig);
var idToken=null,userEmail='',FW_PUBLIC_KEY='',PACKAGES=[],buying=false;
function setStatus(id,msg,cls){var e=document.getElementById(id);e.textContent=msg;e.className='status'+(cls?' '+cls:'');}
function api(path,body){
  var h={'Content-Type':'application/json'};
  if(idToken)h['Authorization']='Bearer '+idToken;
  return fetch(path,{method:body?'POST':'GET',headers:h,body:body?JSON.stringify(body):undefined}).then(function(r){
    return r.json().then(function(j){ if(!r.ok) throw new Error(j.error||j.message||('HTTP '+r.status)); return j; });
  });
}
function doLogin(){
  var id=document.getElementById('identifier').value.trim();
  var pw=document.getElementById('password').value;
  if(!id||!pw){setStatus('loginStatus','Enter your username and password.','err');return;}
  var btn=document.getElementById('loginBtn');btn.disabled=true;btn.textContent='Logging in…';
  setStatus('loginStatus','');
  api('/api/auth/resolve',{identifier:id}).then(function(r){
    if(r.totpRequired) throw new Error('2FA_ENABLED');
    return firebase.auth().signInWithEmailAndPassword(r.email,pw);
  }).then(function(cred){
    userEmail=cred.user.email||'';
    return cred.user.getIdToken();
  }).then(function(tok){
    idToken=tok;
    return api('/api/coins/balance');
  }).then(function(b){
    document.getElementById('balNum').textContent=b.balance;
    document.getElementById('helloUser').textContent='Hi, '+id;
    document.getElementById('loginView').style.display='none';
    document.getElementById('storeView').style.display='block';
    renderPackages();
  }).catch(function(e){
    var m=e&&e.message?e.message:'Login failed';
    if(m==='2FA_ENABLED')m='This account uses 2FA — please buy coins in the Nova app.';
    else if(m.indexOf('auth/')===0)m='Login failed — check your email/username and password.';
    else if(m==='account_not_found')m='No Nova account found for that username.';
    setStatus('loginStatus',m,'err');
  }).finally(function(){btn.disabled=false;btn.textContent='Log in';});
}
function doLogout(){
  firebase.auth().signOut();idToken=null;userEmail='';
  document.getElementById('storeView').style.display='none';
  document.getElementById('loginView').style.display='block';
  document.getElementById('password').value='';
  setStatus('loginStatus','');
}
function renderPackages(){
  var el=document.getElementById('pkgList');el.innerHTML='';
  if(!FW_PUBLIC_KEY){setStatus('payStatus','Payments are not configured yet — try again later.','err');return;}
  PACKAGES.forEach(function(p){
    var d=document.createElement('div');d.className='pkg';
    var info=document.createElement('div');info.className='pkg-info';
    var c=document.createElement('div');c.className='coin';c.textContent='N';
    var t=document.createElement('div');
    var a=document.createElement('div');a.className='pkg-coins';a.textContent=p.coins+' coins';
    var b2=document.createElement('div');b2.className='pkg-usd';b2.textContent='$'+p.usd+' USD';
    t.appendChild(a);t.appendChild(b2);info.appendChild(c);info.appendChild(t);
    var btn=document.createElement('button');btn.className='btn buy';btn.textContent='Buy';
    btn.onclick=(function(pkg){return function(){buyPackage(pkg);};})(p);
    d.appendChild(info);d.appendChild(btn);el.appendChild(d);
  });
}
function buyPackage(pkg){
  if(buying)return;buying=true;
  setStatus('payStatus','Creating your order…');
  api('/api/coins/buy',{packageId:pkg.id,email:userEmail}).then(function(r){
    var txRef=r.txRef;
    setStatus('payStatus','Opening secure checkout…');
    FlutterwaveCheckout({
      public_key:FW_PUBLIC_KEY,tx_ref:txRef,amount:pkg.usd,currency:'USD',
      customer:{email:userEmail},customizations:{title:'Nova',description:pkg.coins+' Nova Coins'},
      callback:function(data){
        if(data&&data.status==='successful'){
          setStatus('payStatus','Confirming payment…');
          api('/api/coins/confirm',{txRef:txRef,transactionId:String(data.transaction_id)}).then(function(c){
            document.getElementById('balNum').textContent=c.balance;
            setStatus('payStatus','Success! '+pkg.coins+' coins added to your balance.','ok');
          }).catch(function(e){
            setStatus('payStatus','Payment went through — coins will appear shortly. ('+(e.message||'confirming')+')','err');
          }).finally(function(){buying=false;});
        }else{setStatus('payStatus','Payment was not completed.','err');buying=false;}
      },
      onclose:function(){if(buying){setStatus('payStatus','Checkout closed — no charge was made.');buying=false;}}
    });
  }).catch(function(e){
    setStatus('payStatus','Could not start checkout: '+(e.message||'error'),'err');buying=false;
  });
}
fetch('/api/coins/config').then(function(r){return r.json();}).then(function(c){
  FW_PUBLIC_KEY=c.publicKey||'';PACKAGES=c.packages||[];
}).catch(function(){});
</script>
</body>
</html>`;
        return new Response(html, { headers: { 'content-type': 'text/html; charset=utf-8', 'cache-control': 'no-store' } });
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
          if (['api', 'avatars', 'media', 'v', 'coins'].includes(handle)) {
            // do nothing, fall through
          } else {
          const row = await env.DB.prepare('SELECT display_name, avatar_url FROM users WHERE handle = ? OR username = ?').bind(handle, handle).first<{ display_name: string; avatar_url: string }>();
          const name = row?.display_name || ('@' + handle);
          const avatar = row?.avatar_url || '/avatars/nova-logo.png';
          // STORED-XSS FIX: escHtml for text content, safeAvatarUrl for the img src.
          const nameEsc = escHtml(name);
          const handleEsc = escHtml(handle);
          const avatarSafe = escHtml(safeAvatarUrl(avatar));
          const html = `<!DOCTYPE html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>${nameEsc} on Nova</title><style>body{background:#000;color:#fff;font-family:system-ui;display:flex;flex-direction:column;align-items:center;justify-content:center;min-height:100vh;margin:0}img{width:120px;height:120px;border-radius:60px}a{background:#fff;color:#000;padding:14px 32px;border-radius:12px;text-decoration:none;font-weight:700;margin-top:24px}</style></head><body><img src="${avatarSafe}" alt="${nameEsc}"><h2>${nameEsc}</h2><p>@${handleEsc}</p><a href="nova://@${handleEsc}">Open in Nova App</a></body></html>`;
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
          headers.set('x-content-type-options', 'nosniff');
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
        if (identifier.includes('@')) {
          // Email login must ALSO check totp_enabled — skipping the DB lookup
          // here silently bypasses 2FA for email sign-ins.
          const emailRow = await env.DB.prepare('SELECT totp_enabled FROM users WHERE LOWER(email) = ?')
            .bind(identifier.toLowerCase()).first<{ totp_enabled: number }>();
          return json({ email: identifier.toLowerCase(), totpRequired: !!emailRow?.totp_enabled });
        }
        const row = await env.DB.prepare('SELECT email, totp_enabled FROM users WHERE username = ? OR handle = ?')
          .bind(identifier.toLowerCase(), identifier.toLowerCase()).first<{ email: string | null; totp_enabled: number }>();
        if (!row?.email) throw httpError(404, 'account_not_found');
        return json({ email: row.email, totpRequired: !!row.totp_enabled });
      }
      // TOTP setup: returns otpauth URI + secret (shown once as QR).
      if (path === '/api/auth/totp/setup' && method === 'POST') {
        await ensureTotpColumns(env.DB);
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
        await ensureTotpColumns(env.DB);
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
        await ensureTotpColumns(env.DB);
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
        await ensureTotpColumns(env.DB);
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
            // INSTANT: push to the followed user in real-time.
            await publishToUser(env, target.uid, { type: 'follow', follower_uid: uid, following: true });
          } else {
            await env.DB.prepare('DELETE FROM follows WHERE follower_uid = ? AND followee_uid = ?').bind(uid, target.uid).run();
            await publishToUser(env, target.uid, { type: 'follow', follower_uid: uid, following: false });
          }
          return json({ following: method === 'POST' });
        }
      }
      // ---------- followers / following / friends lists (authed) ----------
      // TikTok-style 3-tab lists. Each row carries is_live, new_post_count,
      // viewer_follows (the authed viewer follows this user) and
      // follows_viewer (this user follows the authed viewer). Friends =
      // mutual follows. Counts are always for the target profile.
      {
        const m = path.match(/^\/api\/users\/([^/]+)\/(followers|following|friends)$/);
        if (m && method === 'GET') {
          const viewerUid = await guard(request, env, 60);
          const target = await env.DB.prepare(
            'SELECT uid, handle FROM users WHERE uid = ? OR handle = ? OR username = ?'
          ).bind(m[1], m[1], m[1]).first<{ uid: string; handle: string }>();
          if (!target) throw httpError(404, 'user_not_found');
          const kind = m[2];
          const weekAgo = now() - 7 * 24 * 3600 * 1000;
          const relJoin = kind === 'followers'
            ? 'JOIN follows rel ON rel.follower_uid = u.uid'
            : kind === 'following'
              ? 'JOIN follows rel ON rel.followee_uid = u.uid'
              : 'JOIN follows rel ON rel.followee_uid = u.uid JOIN follows rel2 ON rel2.follower_uid = u.uid AND rel2.followee_uid = rel.follower_uid';
          const relWhere = kind === 'followers' ? 'rel.followee_uid = ?' : 'rel.follower_uid = ?';
          // LIVE users surface first in the Following tab (TikTok behavior).
          const liveFirst = kind === 'following' ? 'is_live DESC, ' : '';
          const rows = await env.DB.prepare(
            `SELECT u.uid, u.handle, u.display_name, u.avatar_url, u.is_verified, u.verification_type,
              CASE WHEN ls.uid IS NOT NULL THEN 1 ELSE 0 END AS is_live,
              COALESCE(vc.c, 0) AS new_post_count,
              CASE WHEN vf.follower_uid IS NOT NULL THEN 1 ELSE 0 END AS viewer_follows,
              CASE WHEN fv.follower_uid IS NOT NULL THEN 1 ELSE 0 END AS follows_viewer
            FROM users u
            ${relJoin}
            LEFT JOIN live_sessions ls ON ls.uid = u.uid AND ls.status = 'live'
            LEFT JOIN (SELECT uid, COUNT(*) AS c FROM videos WHERE created_at > ? GROUP BY uid) vc ON vc.uid = u.uid
            LEFT JOIN follows vf ON vf.follower_uid = ? AND vf.followee_uid = u.uid
            LEFT JOIN follows fv ON fv.follower_uid = u.uid AND fv.followee_uid = ?
            WHERE ${relWhere}
            ORDER BY ${liveFirst}rel.created_at DESC
            LIMIT 200`
          ).bind(weekAgo, viewerUid, viewerUid, target.uid).all<{
            uid: string; handle: string; display_name: string; avatar_url: string;
            is_verified: number; verification_type: string; is_live: number;
            new_post_count: number; viewer_follows: number; follows_viewer: number;
          }>();
          const [flc, fgc, frc] = await Promise.all([
            env.DB.prepare('SELECT COUNT(*) c FROM follows WHERE followee_uid = ?').bind(target.uid).first<{ c: number }>(),
            env.DB.prepare('SELECT COUNT(*) c FROM follows WHERE follower_uid = ?').bind(target.uid).first<{ c: number }>(),
            env.DB.prepare(`SELECT COUNT(*) c FROM follows a WHERE a.follower_uid = ?
              AND EXISTS (SELECT 1 FROM follows b WHERE b.follower_uid = a.followee_uid AND b.followee_uid = a.follower_uid)`)
              .bind(target.uid).first<{ c: number }>(),
          ]);
          return json({
            users: (rows.results || []).map((r) => ({
              uid: r.uid,
              handle: r.handle,
              display_name: r.display_name || '',
              avatar_url: r.avatar_url || '',
              is_verified: !!r.is_verified,
              verification_type: r.verification_type || '',
              is_live: r.is_live === 1,
              new_post_count: r.new_post_count || 0,
              viewer_follows: r.viewer_follows === 1,
              follows_viewer: r.follows_viewer === 1,
            })),
            counts: { followers: flc?.c ?? 0, following: fgc?.c ?? 0, friends: frc?.c ?? 0 },
          });
        }
      }
      // ---------- suggested accounts (authed) ----------
      // TikTok-style "Suggested accounts": friends-of-friends (people followed
      // by users the viewer follows), ranked by mutual count, then topped up
      // with popular accounts. Excludes self, already-followed, the viewed
      // profile, bots and blocked users.
      {
        const m = path.match(/^\/api\/users\/([^/]+)\/suggested$/);
        if (m && method === 'GET') {
          const viewerUid = await guard(request, env, 60);
          const target = await env.DB.prepare(
            'SELECT uid FROM users WHERE uid = ? OR handle = ? OR username = ?'
          ).bind(m[1], m[1], m[1]).first<{ uid: string }>();
          if (!target) throw httpError(404, 'user_not_found');
          const limit = 20;
          const rows = await env.DB.prepare(
            `SELECT u.uid, u.handle, u.display_name, u.avatar_url, u.is_verified, u.verification_type,
              COUNT(DISTINCT f.follower_uid) AS mutuals,
              (SELECT GROUP_CONCAT(mu.avatar_url, '|') FROM (
                 SELECT u2.avatar_url AS avatar_url FROM follows mf
                 JOIN users u2 ON u2.uid = mf.follower_uid
                 WHERE mf.followee_uid = u.uid
                   AND mf.follower_uid IN (SELECT followee_uid FROM follows WHERE follower_uid = ?)
                 LIMIT 3
               ) mu) AS mutual_avatars,
              (SELECT u3.display_name FROM follows mf2
               JOIN users u3 ON u3.uid = mf2.follower_uid
               WHERE mf2.followee_uid = u.uid
                 AND mf2.follower_uid IN (SELECT followee_uid FROM follows WHERE follower_uid = ?)
               LIMIT 1) AS mutual_name
            FROM follows f
            JOIN users u ON u.uid = f.followee_uid
            WHERE f.follower_uid IN (SELECT followee_uid FROM follows WHERE follower_uid = ?)
              AND f.followee_uid NOT IN (SELECT followee_uid FROM follows WHERE follower_uid = ?)
              AND f.followee_uid != ?
              AND f.followee_uid != ?
              AND COALESCE(u.is_bot, 0) = 0
              AND NOT EXISTS (SELECT 1 FROM blocks
                WHERE (blocker_uid = ? AND blocked_uid = u.uid)
                   OR (blocker_uid = u.uid AND blocked_uid = ?))
            GROUP BY u.uid
            ORDER BY mutuals DESC
            LIMIT ?`
          ).bind(viewerUid, viewerUid, viewerUid, viewerUid, viewerUid, target.uid, viewerUid, viewerUid, limit)
            .all<{
              uid: string; handle: string; display_name: string; avatar_url: string;
              is_verified: number; verification_type: string; mutuals: number;
              mutual_avatars: string | null; mutual_name: string | null;
            }>();
          let users = (rows.results || []).map((r) => ({
            uid: r.uid,
            handle: r.handle,
            display_name: r.display_name || '',
            avatar_url: r.avatar_url || '',
            is_verified: !!r.is_verified,
            verification_type: r.verification_type || '',
            mutuals: r.mutuals || 0,
            mutual_name: r.mutual_name || '',
            mutual_avatars: (r.mutual_avatars || '').split('|').filter((s) => s.length > 0).slice(0, 3),
          }));
          // Top up with popular accounts when friends-of-friends are scarce.
          if (users.length < limit) {
            const seen = new Set(users.map((u) => u.uid));
            const pop = await env.DB.prepare(
              `SELECT u.uid, u.handle, u.display_name, u.avatar_url, u.is_verified, u.verification_type,
                (SELECT COUNT(*) FROM follows WHERE followee_uid = u.uid) AS fc
              FROM users u
              WHERE u.uid != ?
                AND u.uid != ?
                AND COALESCE(u.is_bot, 0) = 0
                AND u.uid NOT IN (SELECT followee_uid FROM follows WHERE follower_uid = ?)
                AND NOT EXISTS (SELECT 1 FROM blocks
                  WHERE (blocker_uid = ? AND blocked_uid = u.uid)
                     OR (blocker_uid = u.uid AND blocked_uid = ?))
              ORDER BY fc DESC
              LIMIT ?`
            ).bind(viewerUid, target.uid, viewerUid, viewerUid, viewerUid, limit - users.length)
              .all<{
                uid: string; handle: string; display_name: string; avatar_url: string;
                is_verified: number; verification_type: string;
              }>();
            for (const r of (pop.results || [])) {
              if (seen.has(r.uid)) continue;
              users.push({
                uid: r.uid,
                handle: r.handle,
                display_name: r.display_name || '',
                avatar_url: r.avatar_url || '',
                is_verified: !!r.is_verified,
                verification_type: r.verification_type || '',
                mutuals: 0,
                mutual_name: '',
                mutual_avatars: [] as string[],
              });
            }
          }
          return json({ users });
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
      // Public config for the web coin store (/coins): Flutterwave public key
      // (public by design) + coin packages. No auth needed.
      if (path === '/api/coins/config' && method === 'GET') {
        await rateCheck(env.RATELIMIT, `ip:${request.headers.get('cf-connecting-ip') || 'x'}`, 60, 60);
        return json({ publicKey: env.FLUTTERWAVE_PUBLIC_KEY || '', packages: COIN_PACKAGES });
      }
      // Confirm an inline Flutterwave payment from the web coin store.
      // The page already created the purchase via /api/coins/buy (txRef).
      // We re-verify the transaction server-side, then settle (credit coins).
      // Idempotent: settleFlutterwaveTx never double-credits.
      if (path === '/api/coins/confirm' && method === 'POST') {
        const uid = await guard(request, env, 20);
        const b = await readJson(request) as Record<string, unknown>;
        const txRef = vStr(b.txRef, 'txRef', 1, 200);
        const transactionId = vStr(b.transactionId, 'transactionId', 1, 100);
        const purchase = await env.DB.prepare('SELECT uid FROM coin_purchases WHERE tx_ref = ?').bind(txRef).first<{ uid: string }>();
        if (!purchase || purchase.uid !== uid) throw httpError(404, 'purchase_not_found');
        let settled = false;
        try {
          const v = await flutterwaveVerify(env.FLUTTERWAVE_SECRET_KEY, transactionId);
          const vd = ((v as Record<string, unknown>).data || {}) as Record<string, unknown>;
          if (`${vd.status}` === 'successful' && `${vd.tx_ref}` === txRef) {
            await settleFlutterwaveTx(env, txRef, Number(vd.amount || 0), `${vd.currency || ''}`);
            settled = true;
          }
        } catch (e) {
          console.error('coin confirm verify failed');
        }
        if (!settled) throw httpError(502, 'payment_not_confirmed');
        return json({ ok: true, balance: await coinBalance(env.DB, uid) });
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
      // Deploy-safe: payouts table for Flutterwave bank transfers.
      async function ensurePayoutsTable(db: D1Database) {
        await db.prepare(`CREATE TABLE IF NOT EXISTS payouts (
          id TEXT PRIMARY KEY,
          uid TEXT NOT NULL,
          amount_coins INTEGER NOT NULL,
          amount_usd REAL NOT NULL,
          amount_local REAL NOT NULL,
          currency TEXT NOT NULL,
          country TEXT NOT NULL,
          bank_code TEXT NOT NULL,
          bank_name TEXT NOT NULL,
          account_number TEXT NOT NULL,
          fw_transfer_id INTEGER,
          fw_reference TEXT NOT NULL,
          status TEXT NOT NULL DEFAULT 'pending',
          created_at INTEGER NOT NULL,
          updated_at INTEGER NOT NULL
        )`).run();
        await db.prepare('CREATE INDEX IF NOT EXISTS idx_payouts_uid ON payouts (uid)').run();
      }
      if (path === '/api/earnings/banks' && method === 'GET') {
        await guard(request, env);
        const country = new URL(request.url).searchParams.get('country') || 'NG';
        const banks = await flutterwaveBanks(env.FLUTTERWAVE_SECRET_KEY, country);
        return json({ country: country.toUpperCase(), banks });
      }
      if (path === '/api/earnings/payouts' && method === 'GET') {
        const uid = await guard(request, env);
        await ensurePayoutsTable(env.DB);
        const rows = await env.DB.prepare(
          'SELECT id, amount_usd, amount_local, currency, country, bank_name, account_number, status, created_at FROM payouts WHERE uid = ? ORDER BY created_at DESC LIMIT 50'
        ).bind(uid).all();
        return json({ payouts: rows.results });
      }
      if (path === '/api/earnings/payout' && method === 'POST') {
        const uid = await guard(request, env, 20);
        const b = await readJson(request) as Record<string, unknown>;
        const amountCoins = vInt(b.amountCoins, 'amountCoins', 1000, 100_000_000); // min 1000 coins = $10
        const country = vStr(b.country, 'country', 2, 2).toUpperCase();
        const bankCode = vStr(b.bankCode, 'bankCode', 1, 20);
        const bankName = vStr(b.bankName, 'bankName', 1, 120);
        const accountNumber = vStr(b.accountNumber, 'accountNumber', 4, 30).replace(/\D/g, '');
        if (!accountNumber) throw httpError(400, 'account_number_invalid');
        // Currency per country (Flutterwave-supported payout currencies).
        const currencyByCountry: Record<string, string> = {
          NG: 'NGN', GH: 'GHS', KE: 'KES', UG: 'UGX', ZA: 'ZAR',
          US: 'USD', GB: 'GBP', CM: 'XAF', SN: 'XOF', RW: 'RWF', TZ: 'TZS',
        };
        const currency = currencyByCountry[country];
        if (!currency) throw httpError(400, 'country_not_supported');
        const t = now();
        await ensurePayoutsTable(env.DB);
        await env.DB.prepare('INSERT OR IGNORE INTO creator_earnings_balances (uid, balance, lifetime_earned, updated_at) VALUES (?, 0, 0, ?)').bind(uid, t).run();
        const debit = await env.DB.prepare('UPDATE creator_earnings_balances SET balance = balance - ?, updated_at = ? WHERE uid = ? AND balance >= ?')
          .bind(amountCoins, t, uid, amountCoins)
          .run();
        if ((debit.meta as unknown as { changes: number }).changes !== 1) throw httpError(402, 'insufficient_earnings');
        const id = newId();
        const usd = amountCoins / 100; // 100 coins = $1
        // Convert USD to local currency via Flutterwave's transfer (amount in local currency).
        // For simplicity v1: we send the USD amount and let Flutterwave handle FX
        // where supported, else convert at a fixed display rate. Here we use USD
        // for US/GB and local currency otherwise via the transfer amount.
        // NOTE: Flutterwave transfers require the amount in the destination currency.
        // We do a best-effort FX via their /v3/transfers with currency set; the
        // actual FX is applied by Flutterwave. For accounting we store USD.
        const reference = `nova_payout_${id}`;
        let fwTransferId: number | null = null;
        let status = 'pending';
        try {
          const fw = await flutterwaveTransfer(env.FLUTTERWAVE_SECRET_KEY, {
            accountBank: bankCode,
            accountNumber,
            amount: usd, // Flutterwave applies FX to destination currency
            currency,
            narration: 'Nova creator payout',
            reference,
          });
          fwTransferId = (fw.data?.id as number) ?? null;
          status = 'processing';
        } catch (e) {
          // Transfer failed: refund the debit so the creator keeps their earnings.
          await env.DB.prepare('UPDATE creator_earnings_balances SET balance = balance + ?, updated_at = ? WHERE uid = ?')
            .bind(amountCoins, now(), uid).run();
          throw e;
        }
        await env.DB.batch([
          env.DB.prepare('INSERT INTO creator_earnings_ledger (id, uid, delta, reason, ref, created_at) VALUES (?, ?, ?, ?, ?, ?)').bind(newId(), uid, -amountCoins, 'payout_sent', id, t),
          env.DB.prepare(`INSERT INTO payouts (id, uid, amount_coins, amount_usd, amount_local, currency, country, bank_code, bank_name, account_number, fw_transfer_id, fw_reference, status, created_at, updated_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`)
            .bind(id, uid, amountCoins, usd, usd, currency, country, bankCode, bankName, accountNumber, fwTransferId, reference, status, t, t),
        ]);
        await notifyUser(env, uid, 'Payout sent', `$${usd.toFixed(2)} is on its way to your ${bankName} account.`, { kind: 'payout', payoutId: id });
        return json({ id, status, amountUsd: usd, currency, fwTransferId }, 201);
      }

      // ---------- LIVE (1000+ followers to broadcast) ----------
      if (path === '/api/live' && method === 'GET') {
        await guard(request, env);
        const rows = await env.DB.prepare(
          `SELECT l.*, u.handle, u.display_name, u.avatar_url, u.verification_type FROM live_sessions l
           JOIN users u ON u.uid = l.uid WHERE l.status = 'live' ORDER BY l.viewer_count DESC, l.started_at DESC LIMIT 50`,
        ).all();
        const out = [];
        for (const r of rows.results as Record<string, unknown>[]) {
          out.push({ ...r, is_verified: await isVerified(env.DB, r.uid as string), affiliated_with: await affiliationFor(env.DB, r.uid as string) });
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
        await ensureVerificationColumns(env.DB);
        const sub = await env.DB.prepare('SELECT status, tier, started_at, expires_at FROM verification_subscriptions WHERE uid = ?').bind(uid).first() as { status: string; tier: string; started_at: number; expires_at: number } | null;
        const active = !!sub && sub.status === 'active' && sub.expires_at > now();
        return json({ verified: active, subscription: sub || null, tier: active ? sub.tier : null });
      }
      // Verification pricing — public, no auth needed (shown on purchase screen)
      if (path === '/api/verification/pricing' && method === 'GET') {
        const tiers: Record<string, unknown> = {};
        for (const [key, spec] of Object.entries(VERIFY_TIERS)) {
          tiers[key] = {
            label: spec.label,
            color: spec.color,
            monthly_usd: spec.monthly_usd,
            periods: {
              3: verifyPriceFor(key as VerifyTier, 3),
              6: verifyPriceFor(key as VerifyTier, 6),
              12: verifyPriceFor(key as VerifyTier, 12),
            },
          };
        }
        return json({ tiers });
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
        const tier = vEnum(b.tier, ['personal', 'business', 'company'] as const, 'tier');
        const monthsNum = vNum(b.months, 'months', 1, 12);
        if (monthsNum !== 3 && monthsNum !== 6 && monthsNum !== 12) throw httpError(400, 'invalid_months');
        const months = monthsNum as 3 | 6 | 12;
        const price = verifyPriceFor(tier, months);
        // txRef: nova_verify_<tier>_<months>_<uid>_<uuid> (uids never contain '_')
        const txRef = `nova_verify_${tier}_${months}_${uid}_${newId()}`;
        await env.DB.prepare(
          `CREATE TABLE IF NOT EXISTS verification_purchases (
            tx_ref TEXT PRIMARY KEY, uid TEXT NOT NULL, tier TEXT NOT NULL,
            months INTEGER NOT NULL, amount_usd REAL NOT NULL, created_at INTEGER NOT NULL)`
        ).run();
        await env.DB.prepare(
          `INSERT OR IGNORE INTO verification_purchases (tx_ref, uid, tier, months, amount_usd, created_at)
           VALUES (?, ?, ?, ?, ?, ?)`
        ).bind(txRef, uid, tier, months, price, now()).run();
        const data = await flutterwaveCharge(env.FLUTTERWAVE_SECRET_KEY, {
          amount: price,
          currency: 'USD',
          email,
          tx_ref: txRef,
          redirectUrl: `${new URL(request.url).origin}/api/payments/callback`,
        });
        return json({ checkoutUrl: checkoutLink(data), txRef, flutterwave: data, tier, months, price_usd: price });
      }
      // Alias: /api/verification/purchase (accepts {type, months} or {tier, months})
      if (path === '/api/verification/purchase' && method === 'POST') {
        const uid = await guard(request, env, 20);
        const b = await readJson(request) as Record<string, unknown>;
        const email = vStr(b.email, 'email', 3, 120);
        if (!/^[^@\s]+@[^@\s]+\.[^@\s]+$/.test(email)) throw httpError(400, 'email_invalid');
        const tier = vEnum(b.type ?? b.tier, ['personal', 'business', 'company'] as const, 'type');
        const monthsNum = vNum(b.months, 'months', 1, 12);
        if (monthsNum !== 3 && monthsNum !== 6 && monthsNum !== 12) throw httpError(400, 'invalid_months');
        const months = monthsNum as 3 | 6 | 12;
        const price = verifyPriceFor(tier, months);
        const txRef = `nova_verify_${tier}_${months}_${uid}_${newId()}`;
        await env.DB.prepare(
          `CREATE TABLE IF NOT EXISTS verification_purchases (
            tx_ref TEXT PRIMARY KEY, uid TEXT NOT NULL, tier TEXT NOT NULL,
            months INTEGER NOT NULL, amount_usd REAL NOT NULL, created_at INTEGER NOT NULL)`
        ).run();
        await env.DB.prepare(
          `INSERT OR IGNORE INTO verification_purchases (tx_ref, uid, tier, months, amount_usd, created_at)
           VALUES (?, ?, ?, ?, ?, ?)`
        ).bind(txRef, uid, tier, months, price, now()).run();
        const data = await flutterwaveCharge(env.FLUTTERWAVE_SECRET_KEY, {
          amount: price,
          currency: 'USD',
          email,
          tx_ref: txRef,
          redirectUrl: `${new URL(request.url).origin}/api/payments/callback`,
        });
        return json({ checkoutUrl: checkoutLink(data), txRef, tier, months, price_usd: price });
      }

      // ---------- affiliations (X-style company affiliation) ----------
      // Only a gold-badge company can affiliate users. Users can NEVER
      // affiliate themselves — the company grants it (scam prevention).
      if (path === '/api/affiliations' && method === 'GET') {
        const uid = await guard(request, env);
        await ensureAffiliationsTable(env.DB);
        // ?company=<uid|handle> → public list of that company's affiliates.
        // No param → the caller's own affiliates (company only).
        const companyParam = (url.searchParams.get('company') || '').trim();
        let companyUid = uid;
        if (companyParam) {
          const c = await env.DB.prepare(
            'SELECT uid FROM users WHERE uid = ? OR handle = ?'
          ).bind(companyParam, companyParam).first<{ uid: string }>();
          if (!c) throw httpError(404, 'company_not_found');
          companyUid = c.uid;
        } else {
          await requireCompany(env.DB, uid);
        }
        const rows = await env.DB.prepare(
          `SELECT u.uid, u.handle, u.display_name, u.avatar_url, u.verification_type, a.created_at
           FROM affiliations a JOIN users u ON u.uid = a.user_uid
           WHERE a.company_uid = ? ORDER BY a.created_at DESC LIMIT 100`
        ).bind(companyUid).all();
        return json({ affiliates: rows.results });
      }
      if (path === '/api/affiliations' && method === 'POST') {
        const uid = await guard(request, env, 30);
        await ensureAffiliationsTable(env.DB);
        await requireCompany(env.DB, uid);
        const b = await readJson(request) as Record<string, unknown>;
        const target = vStr(b.user_uid ?? b.handle, 'user_uid', 1, 64);
        const userRow = await env.DB.prepare(
          'SELECT uid, handle, status FROM users WHERE uid = ? OR handle = ?'
        ).bind(target, target).first<{ uid: string; handle: string; status: string }>();
        if (!userRow) throw httpError(404, 'user_not_found');
        if (userRow.uid === uid) throw httpError(400, 'cannot_affiliate_self');
        if (userRow.status !== 'active') throw httpError(400, 'user_not_active');
        await env.DB.prepare(
          'INSERT OR IGNORE INTO affiliations (id, company_uid, user_uid, created_at) VALUES (?, ?, ?, ?)'
        ).bind(newId(), uid, userRow.uid, now()).run();
        return json({ ok: true, affiliated: userRow.uid, handle: userRow.handle });
      }
      {
        const m = path.match(/^\/api\/affiliations\/([A-Za-z0-9_-]+)$/);
        if (m && method === 'DELETE') {
          const uid = await guard(request, env, 30);
          await ensureAffiliationsTable(env.DB);
          await requireCompany(env.DB, uid);
          const targetUid = vStr(m[1], 'user_uid', 1, 64);
          await env.DB.prepare(
            'DELETE FROM affiliations WHERE company_uid = ? AND user_uid = ?'
          ).bind(uid, targetUid).run();
          return json({ ok: true });
        }
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
            `SELECT v.*, u.handle, u.display_name, u.avatar_url, u.verification_type FROM videos v
             JOIN users u ON u.uid = v.uid, json_each(v.hashtags) j
             WHERE v.visibility = 'public' AND j.value = ?
               AND ${BLOCK_FILTER}
             ORDER BY v.created_at DESC LIMIT 30`,
          )
            .bind(tag, uid, uid)
            .all();
          const out = [];
          for (const r of rows.results as Record<string, unknown>[]) {
            out.push({ ...r, is_verified: await isVerified(env.DB, r.uid as string), affiliated_with: await affiliationFor(env.DB, r.uid as string), media_url: await signMediaKey(env.MEDIA_SIGNING_SECRET, r.media_key as string).catch(() => r.media_url) });
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
        // Uploader privacy choice: public | friends (mutual) | private.
        const reqVisibility = vOptStr(b.visibility, 'visibility', 20);
        const allowedVis = ['public', 'friends', 'private'];
        const wantVisibility = allowedVis.includes(reqVisibility) ? reqVisibility : 'public';
        // More options from the post editor.
        const allowComments = b.allowComments === false || b.allowComments === 0 ? 0 : 1;
        const audienceControl = vOptStr(b.audienceControl, 'audienceControl', 20) || 'everyone';
        const tagProducts = b.tagProducts === true || b.tagProducts === 1 ? 1 : 0;
        const coverKey = vOptStr(b.coverKey, 'coverKey', 300);
        const id = newId();
        await ensureAiColumn(env.DB);
        await ensureVideoOptionsColumns(env.DB);
        // High-risk devices: uploads are held for review (quarantined from feeds).
        // Borderline on-device nudity scans also quarantine (review decides; strike only if confirmed).
        const scanVerdict = vOptStr(b.scanVerdict, 'scanVerdict', 20);
        let visibility = (await deviceRestricted(env.DB, uid)) ? 'quarantine' : wantVisibility;
        if (scanVerdict === 'borderline') visibility = 'quarantine';
        if (scanVerdict === 'block') throw httpError(400, 'content_blocked_by_safety_scan');
        const t = now();
        await env.DB.prepare(
          `INSERT INTO videos (id, uid, caption, hashtags, media_key, media_url, duration_sec, sound_label, audio_key, visibility, is_ai_generated, allow_comments, audience_control, tag_products, cover_key, created_at)
           VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
        )
          .bind(id, uid, caption, JSON.stringify(hashtags), mediaKey, `/media/${mediaKey}`, durationSec, soundLabel, audioKey, visibility, isAiGenerated, allowComments, audienceControl, tagProducts, coverKey, t)
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
        // Privacy: public → everyone; friends → mutual followers only; private → owner only.
        // The three uid binds below map to the two EXISTS subqueries + the owner check, in order.
        const privacyExpr = `(v.visibility = 'public'
           OR (v.visibility = 'friends'
               AND EXISTS (SELECT 1 FROM follows f1 WHERE f1.follower_uid = ? AND f1.followee_uid = v.uid)
               AND EXISTS (SELECT 1 FROM follows f2 WHERE f2.follower_uid = v.uid AND f2.followee_uid = ?))
           OR (v.visibility = 'private' AND v.uid = ?))`;
        const binds: unknown[] = [cursor, uid, uid, uid, cursor, uid, uid];
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
          `SELECT v.*, u.handle, u.display_name, u.avatar_url, u.verification_type, ${scoreExpr} AS score
           FROM videos v JOIN users u ON u.uid = v.uid
           WHERE ${privacyExpr} AND v.created_at < ?
             AND ${BLOCK_FILTER}
           ORDER BY score DESC, v.created_at DESC LIMIT ?`,
        )
          .bind(...binds)
          .all();
        const out = [];
        for (const r of rows.results as Record<string, unknown>[]) {
          const promo = await env.DB.prepare("SELECT id FROM promotions WHERE video_id = ? AND status = 'active' AND ends_at > ?")
            .bind(r.id, now()).first();
          out.push({ ...r, is_verified: await isVerified(env.DB, r.uid as string), affiliated_with: await affiliationFor(env.DB, r.uid as string), promoted: !!promo, media_url: await signMediaKey(env.MEDIA_SIGNING_SECRET, r.media_key as string).catch(() => r.media_url) });
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
          const v = await env.DB.prepare('SELECT like_count, uid AS owner_uid FROM videos WHERE id = ?').bind(vid).first<{ like_count: number; owner_uid: string }>();
          // INSTANT: push to the video owner in real-time.
          if (v?.owner_uid && v.owner_uid !== uid) {
            await publishToUser(env, v.owner_uid, { type: 'like', video_id: vid, liker_uid: uid, like_count: v.like_count, liked: method === 'POST' });
          }
          return json({ likeCount: v?.like_count ?? 0 });
        }
      }
      // ---------- save / unsave video (bookmark) ----------
      {
        const m = path.match(/^\/api\/videos\/([^/]+)\/save$/);
        if (m && (method === 'POST' || method === 'DELETE')) {
          const uid = await guard(request, env, 60);
          const vid = vStr(m[1], 'videoId', 1, 64);
          await env.DB.prepare(`CREATE TABLE IF NOT EXISTS saved_videos (
            uid TEXT NOT NULL, video_id TEXT NOT NULL, created_at INTEGER NOT NULL,
            PRIMARY KEY (uid, video_id))`).run();
          if (method === 'POST') {
            await env.DB.prepare('INSERT OR IGNORE INTO saved_videos (uid, video_id, created_at) VALUES (?, ?, ?)').bind(uid, vid, now()).run();
          } else {
            await env.DB.prepare('DELETE FROM saved_videos WHERE uid = ? AND video_id = ?').bind(uid, vid).run();
          }
          return json({ saved: method === 'POST' });
        }
        const sm = path.match(/^\/api\/users\/me\/saved$/);
        if (sm && method === 'GET') {
          const uid = await guard(request, env, 60);
          const rows = await env.DB.prepare(
            `SELECT v.*, u.handle, u.display_name, u.avatar_url, u.verification_type
             FROM saved_videos s JOIN videos v ON v.id = s.video_id
             JOIN users u ON u.uid = v.uid
             WHERE s.uid = ? ORDER BY s.created_at DESC LIMIT 50`
          ).bind(uid).all();
          return json({ videos: rows.results || [] });
        }
      }
      {
        const m = path.match(/^\/api\/videos\/([^/]+)\/comments$/);
        if (m && method === 'GET') {
          const uid = await guard(request, env);
          const vid = vStr(m[1], 'videoId', 1, 64);
          const rows = await env.DB.prepare(
            `SELECT c.*, u.handle, u.display_name, u.avatar_url, u.verification_type FROM comments c
             JOIN users u ON u.uid = c.uid WHERE c.video_id = ?
               AND c.uid NOT IN (SELECT blocked_uid FROM blocks WHERE blocker_uid = ?)
               AND c.uid NOT IN (SELECT blocker_uid FROM blocks WHERE blocked_uid = ?)
             ORDER BY c.created_at ASC LIMIT 100`,
          )
            .bind(vid, uid, uid)
            .all();
          const out = [];
          for (const r of rows.results as Record<string, unknown>[]) {
            out.push({ ...r, is_verified: await isVerified(env.DB, r.uid as string), affiliated_with: await affiliationFor(env.DB, r.uid as string) });
          }
          return json({ comments: out });
        }
        if (m && method === 'POST') {
          const uid = await guard(request, env, 12); // tight: spam control
          const vid = vStr(m[1], 'videoId', 1, 64);
          const b = await readJson(request) as Record<string, unknown>;
          const text = vStr(b.text, 'text', 1, 500);
          // Respect the uploader's "allow comments" setting.
          await ensureVideoOptionsColumns(env.DB);
          const vc = await env.DB.prepare('SELECT allow_comments FROM videos WHERE id = ?').bind(vid).first<{ allow_comments: number }>();
          if (vc && vc.allow_comments === 0) throw httpError(403, 'comments_disabled');
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
        await ensureInboxTables(env.DB);
        const rows = await env.DB.prepare(
          `SELECT t.*, u.handle AS peer_handle, u.display_name AS peer_name, u.avatar_url AS peer_avatar,
                  (SELECT COUNT(*) FROM messages m
                    WHERE m.thread_id = t.id AND m.sender_uid != ?
                      AND m.created_at > COALESCE((SELECT last_read_at FROM thread_reads r WHERE r.thread_id = t.id AND r.uid = ?), 0)
                  ) AS unread_count
           FROM threads t JOIN users u ON u.uid = CASE WHEN t.user_a = ? THEN t.user_b ELSE t.user_a END
           WHERE (t.user_a = ? OR t.user_b = ?)
             AND u.uid NOT IN (SELECT blocked_uid FROM blocks WHERE blocker_uid = ?)
             AND u.uid NOT IN (SELECT blocker_uid FROM blocks WHERE blocked_uid = ?)
           ORDER BY t.updated_at DESC LIMIT 50`,
        )
          .bind(uid, uid, uid, uid, uid, uid, uid)
          .all();
        return json({ threads: rows.results });
      }
      // ---------- inbox: new followers ----------
      if (path === '/api/inbox/followers' && method === 'GET') {
        const uid = await guard(request, env);
        const limit = vNum(url.searchParams.get('limit') || 50, 'limit', 1, 100);
        const rows = await env.DB.prepare(
          `SELECT u.uid, u.handle, u.display_name, u.avatar_url, f.created_at
           FROM follows f JOIN users u ON u.uid = f.follower_uid
           WHERE f.followee_uid = ?
           ORDER BY f.created_at DESC LIMIT ?`,
        ).bind(uid, limit).all();
        return json({ followers: rows.results });
      }
      // ---------- inbox: activity (likes on my videos, comments on my videos) ----------
      if (path === '/api/inbox/activity' && method === 'GET') {
        const uid = await guard(request, env);
        const limit = vNum(url.searchParams.get('limit') || 50, 'limit', 1, 100);
        // Likes on my videos.
        const likes = await env.DB.prepare(
          `SELECT 'like' AS kind, l.created_at, v.id AS video_id,
                  u.uid AS actor_uid, u.handle AS actor_handle,
                  u.display_name AS actor_name, u.avatar_url AS actor_avatar,
                  '' AS text
           FROM likes l
           JOIN videos v ON v.id = l.video_id
           JOIN users u ON u.uid = l.uid
           WHERE v.uid = ? AND l.uid != ?
           ORDER BY l.created_at DESC LIMIT ?`,
        ).bind(uid, uid, limit).all();
        // Comments on my videos.
        const comments = await env.DB.prepare(
          `SELECT 'comment' AS kind, c.created_at, v.id AS video_id,
                  u.uid AS actor_uid, u.handle AS actor_handle,
                  u.display_name AS actor_name, u.avatar_url AS actor_avatar,
                  substr(c.text, 1, 120) AS text
           FROM comments c
           JOIN videos v ON v.id = c.video_id
           JOIN users u ON u.uid = c.uid
           WHERE v.uid = ? AND c.uid != ?
           ORDER BY c.created_at DESC LIMIT ?`,
        ).bind(uid, uid, limit).all();
        const items = [...(likes.results as unknown[]), ...(comments.results as unknown[])].sort(
          (a, b) => ((b as Record<string, number>).created_at as number) - ((a as Record<string, number>).created_at as number),
        ).slice(0, limit);
        return json({ activity: items });
      }
      // ---------- inbox: system notifications ----------
      if (path === '/api/inbox/system' && method === 'GET') {
        const uid = await guard(request, env);
        await ensureInboxTables(env.DB);
        const limit = vNum(url.searchParams.get('limit') || 50, 'limit', 1, 100);
        const rows = await env.DB.prepare(
          'SELECT id, title, body, type, created_at, read_at FROM system_notifications WHERE uid = ? ORDER BY created_at DESC LIMIT ?',
        ).bind(uid, limit).all();
        const unread = await env.DB.prepare(
          'SELECT COUNT(*) AS c FROM system_notifications WHERE uid = ? AND read_at = 0',
        ).bind(uid).first<{ c: number }>();
        return json({ notifications: rows.results, unread: unread?.c ?? 0 });
      }
      if (path === '/api/inbox/system/read' && method === 'POST') {
        const uid = await guard(request, env);
        await ensureInboxTables(env.DB);
        const b = await readJson(request) as Record<string, unknown>;
        const id = typeof b.id === 'string' && b.id ? b.id : null;
        if (id) {
          await env.DB.prepare('UPDATE system_notifications SET read_at = ? WHERE id = ? AND uid = ?').bind(now(), id, uid).run();
        } else {
          await env.DB.prepare('UPDATE system_notifications SET read_at = ? WHERE uid = ? AND read_at = 0').bind(now(), uid).run();
        }
        return json({ ok: true });
      }
      // ---------- stories ----------
      if (path === '/api/stories' && method === 'POST') {
        const uid = await guard(request, env, 30);
        await ensureInboxTables(env.DB);
        const b = await readJson(request) as Record<string, unknown>;
        const mediaKey = vStr(b.mediaKey, 'mediaKey', 1, 300);
        const mediaType = (typeof b.mediaType === 'string' && b.mediaType === 'video') ? 'video' : 'photo';
        const t = now();
        // Prune expired stories opportunistically.
        await env.DB.prepare('DELETE FROM stories WHERE expires_at < ?').bind(t).run();
        const id = newId();
        await env.DB.prepare(
          'INSERT INTO stories (id, uid, media_key, media_type, created_at, expires_at) VALUES (?, ?, ?, ?, ?, ?)',
        ).bind(id, uid, mediaKey, mediaType, t, t + 24 * 3600 * 1000).run();
        return json({ id }, 201);
      }
      if (path === '/api/stories/feed' && method === 'GET') {
        const uid = await guard(request, env);
        await ensureInboxTables(env.DB);
        const t = now();
        await env.DB.prepare('DELETE FROM stories WHERE expires_at < ?').bind(t).run();
        // Stories from people I follow + my own, newest first, grouped by user.
        const rows = await env.DB.prepare(
          `SELECT s.id, s.uid, s.media_key, s.media_type, s.created_at,
                  u.handle, u.display_name, u.avatar_url,
                  (SELECT COUNT(*) FROM story_views v WHERE v.story_id = s.id AND v.uid = ?) AS viewed
           FROM stories s JOIN users u ON u.uid = s.uid
           WHERE s.expires_at > ? AND (s.uid = ? OR s.uid IN (SELECT followee_uid FROM follows WHERE follower_uid = ?))
           ORDER BY s.created_at DESC LIMIT 100`,
        ).bind(uid, t, uid, uid).all();
        const out: Record<string, unknown>[] = [];
        for (const r of rows.results as Record<string, unknown>[]) {
          let mediaUrl: string = `/media/${r.media_key}`;
          try {
            mediaUrl = await signMediaKey(env.MEDIA_SIGNING_SECRET, r.media_key as string);
          } catch { /* fall back to unsigned */ }
          out.push({ ...r, media_url: mediaUrl });
        }
        return json({ stories: out });
      }
      {
        const m = path.match(/^\/api\/stories\/([^/]+)\/view$/);
        if (m && method === 'POST') {
          const uid = await guard(request, env);
          await ensureInboxTables(env.DB);
          await env.DB.prepare('INSERT OR IGNORE INTO story_views (story_id, uid, created_at) VALUES (?, ?, ?)')
            .bind(vStr(m[1], 'storyId', 1, 64), uid, now()).run();
          return json({ ok: true });
        }
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
          // Mark thread as read.
          try {
            await ensureInboxTables(env.DB);
            await ensureMessageColumns(env.DB);
            await env.DB.prepare('INSERT INTO thread_reads (thread_id, uid, last_read_at) VALUES (?, ?, ?) ON CONFLICT(thread_id, uid) DO UPDATE SET last_read_at = excluded.last_read_at')
              .bind(tid, uid, now()).run();
          } catch { /* read tracking is best-effort */ }
          // Sign media URLs so voice notes / attachments play directly.
          const msgs: Record<string, unknown>[] = [];
          for (const r of (rows.results as Record<string, unknown>[]).reverse()) {
            let mediaUrl = '';
            const mk = r['media_key'] as string | undefined;
            if (mk) {
              try {
                mediaUrl = await signMediaKey(env.MEDIA_SIGNING_SECRET, mk);
              } catch { /* leave empty */ }
            }
            msgs.push({ ...r, media_url: mediaUrl });
          }
          return json({ messages: msgs });
        }
        if (m && method === 'POST') {
          const uid = await guard(request, env, 120);
          const b = await readJson(request) as Record<string, unknown>;
          const text = vOptStr(b.text, 'text', 2000);
          const mediaKey = vOptStr(b.mediaKey, 'mediaKey', 300);
          const durationS = vNum(b.durationS ?? 0, 'durationS', 0, 600);
          if (!text && !mediaKey) throw httpError(400, 'empty_message');
          await ensureMessageColumns(env.DB);
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
            env.DB.prepare('INSERT INTO messages (id, thread_id, sender_uid, text, media_key, duration_s, created_at) VALUES (?, ?, ?, ?, ?, ?, ?)').bind(id, tid, uid, text, mediaKey, durationS, t),
            env.DB.prepare('UPDATE threads SET last_message = ?, updated_at = ? WHERE id = ?').bind(text.slice(0, 120), t, tid),
          ]);
          let eventMediaUrl = '';
          if (mediaKey) {
            try {
              eventMediaUrl = await signMediaKey(env.MEDIA_SIGNING_SECRET, mediaKey);
            } catch { /* leave empty */ }
          }
          const event = { type: 'message', threadId: tid, message: { id, senderUid: uid, text, createdAt: t, mediaKey, mediaUrl: eventMediaUrl, durationS } };
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
        // Debug logging for 0-byte upload investigation (sizes only — no PII).
        console.log(`[upload] size=${file.size} type=${file.type}`);
        if (file.size > 200 * 1024 * 1024) throw httpError(413, 'file_too_large');
        if (file.size === 0) throw httpError(400, 'file_empty');
        // SECURITY: only media types may be uploaded. Attacker-controlled
        // content-types (text/html, application/javascript, svg) would be
        // served back via /media/* and could execute as stored XSS.
        const upCt = (file.type || '').toLowerCase();
        if (!/^(video|image|audio)\//.test(upCt)) throw httpError(415, 'media_type_not_allowed');
        const ext = (file.name.split('.').pop() || 'bin').toLowerCase().replace(/[^a-z0-9]/g, '').slice(0, 5) || 'bin';
        const key = `${uid}/${newId()}.${ext}`;
        // Read the full buffer first to verify content before R2 put
        const buf = await file.arrayBuffer();
        console.log(`[upload] buffer byteLength=${buf.byteLength}`);
        if (buf.byteLength === 0) throw httpError(400, 'file_empty_buffer');
        await env.MEDIA.put(key, buf, {
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
            'SELECT uid, handle, display_name, avatar_url, evm_address, btc_address, is_verified, verification_type, kyc_status FROM users WHERE uid = ? OR handle = ?'
          ).bind(targetUid, targetUid).first<{
            uid: string; handle: string; display_name: string; avatar_url: string;
            evm_address: string; btc_address: string; is_verified: number; verification_type: string; kyc_status: string;
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
            verification_type: row.verification_type || '',
            kyc_status: row.kyc_status,
            affiliated_with: await affiliationFor(env.DB, row.uid),
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

      // ---------- subdomain marketplace API (public, no auth) ----------
      // Email-based: anyone can buy, no Nova account needed.
      // Also serve the marketplace at the /domains path on any host (handy for
      // testing before the domains.novamail.store DNS/route is live).
      if (path === '/domains' && method === 'GET') {
        await rateCheck(env.RATELIMIT, `ip:${request.headers.get('cf-connecting-ip') || 'x'}`, 60, 60);
        return new Response(domainMarketplaceHtml(), {
          headers: { 'content-type': 'text/html; charset=utf-8', 'x-content-type-options': 'nosniff' },
        });
      }
      if (path === '/api/domains/check' && method === 'GET') {
        await rateCheck(env.RATELIMIT, `ip:${request.headers.get('cf-connecting-ip') || 'x'}`, 60, 60);
        const name = (`${url.searchParams.get('name') || ''}`).toLowerCase().trim().replace(/\.novamail\.store$/, '');
        const { available, reason } = await domainAvailability(env.DB, name);
        return json({
          name, available,
          reason: reason || undefined,
          price_usd: available ? domainPriceFor(name) : undefined,
        });
      }
      if (path === '/api/domains/buy' && method === 'POST') {
        await rateCheck(env.RATELIMIT, `ip:${request.headers.get('cf-connecting-ip') || 'x'}`, 20, 60);
        await ensureSubdomainTables(env.DB);
        const b = await readJson(request) as Record<string, unknown>;
        const name = (`${b.subdomain || ''}`).toLowerCase().trim().replace(/\.novamail\.store$/, '');
        const email = vStr(b.email, 'email', 3, 120);
        if (!/^[^@\s]+@[^@\s]+\.[^@\s]+$/.test(email)) throw httpError(400, 'email_invalid');
        const { available, reason } = await domainAvailability(env.DB, name);
        if (!available) {
          throw httpError(409, reason === 'reserved' ? 'name_reserved' : reason === 'taken' ? 'name_taken' : 'invalid_name');
        }
        let target = '';
        if (b.target !== undefined && `${b.target}`.trim() !== '') {
          target = `${b.target}`.trim().toLowerCase().replace(/^https?:\/\//, '').split('/')[0].split(':')[0].split('?')[0];
          if (!isValidHostname(target)) throw httpError(400, 'invalid_target');
          if (target === 'novamail.store' || target.endsWith('.novamail.store')) throw httpError(400, 'target_not_allowed');
        }
        const price = domainPriceFor(name);
        const txRef = `nova_domain_${name}_${newId()}`;
        await env.DB.prepare(
          `INSERT OR IGNORE INTO domain_purchases (tx_ref, subdomain, email, target, amount_usd, kind, settled, created_at)
           VALUES (?, ?, ?, ?, ?, 'buy', 0, ?)`
        ).bind(txRef, name, email.toLowerCase(), target, price, now()).run();
        const data = await flutterwaveCharge(env.FLUTTERWAVE_SECRET_KEY, {
          amount: price,
          currency: 'USD',
          email: email.toLowerCase(),
          tx_ref: txRef,
          redirectUrl: `${new URL(request.url).origin}/api/payments/callback`,
        });
        return json({ checkoutUrl: checkoutLink(data), txRef, flutterwave: data, subdomain: name, price_usd: price });
      }
      if (path === '/api/domains/confirm' && method === 'POST') {
        await rateCheck(env.RATELIMIT, `ip:${request.headers.get('cf-connecting-ip') || 'x'}`, 20, 60);
        const b = await readJson(request) as Record<string, unknown>;
        const txRef = vStr(b.txRef, 'txRef', 1, 200);
        const transactionId = vStr(b.transactionId, 'transactionId', 1, 100);
        const p = await env.DB.prepare('SELECT amount_usd FROM domain_purchases WHERE tx_ref = ?')
          .bind(txRef).first<{ amount_usd: number }>();
        if (!p) throw httpError(404, 'purchase_not_found');
        let ok = false;
        try {
          const v = await flutterwaveVerify(env.FLUTTERWAVE_SECRET_KEY, transactionId);
          const vd = ((v as Record<string, unknown>).data || {}) as Record<string, unknown>;
          if (`${vd.status}` === 'successful' && `${vd.tx_ref}` === txRef && Math.abs(Number(vd.amount || 0) - p.amount_usd) < 0.001) {
            await provisionDomainPurchase(env, txRef);
            ok = true;
          }
        } catch { console.error('domain confirm verify failed'); }
        if (!ok) throw httpError(502, 'payment_not_confirmed');
        return json({ ok: true });
      }
      if (path === '/api/domains/renew' && method === 'POST') {
        await rateCheck(env.RATELIMIT, `ip:${request.headers.get('cf-connecting-ip') || 'x'}`, 20, 60);
        await ensureSubdomainTables(env.DB);
        const b = await readJson(request) as Record<string, unknown>;
        const name = (`${b.subdomain || ''}`).toLowerCase().trim().replace(/\.novamail\.store$/, '');
        const email = vStr(b.email, 'email', 3, 120).toLowerCase();
        const row = await env.DB.prepare(
          'SELECT subdomain, owner_email, target FROM subdomains WHERE subdomain = ?'
        ).bind(name).first<{ subdomain: string; owner_email: string; target: string }>();
        if (!row || row.owner_email !== email) throw httpError(404, 'domain_not_found');
        const price = domainPriceFor(name);
        const txRef = `nova_domain_renew_${name}_${newId()}`;
        await env.DB.prepare(
          `INSERT OR IGNORE INTO domain_purchases (tx_ref, subdomain, email, target, amount_usd, kind, settled, created_at)
           VALUES (?, ?, ?, ?, ?, 'renew', 0, ?)`
        ).bind(txRef, name, email, row.target || '', price, now()).run();
        const data = await flutterwaveCharge(env.FLUTTERWAVE_SECRET_KEY, {
          amount: price,
          currency: 'USD',
          email,
          tx_ref: txRef,
          redirectUrl: `${new URL(request.url).origin}/api/payments/callback`,
        });
        return json({ checkoutUrl: checkoutLink(data), txRef, flutterwave: data, subdomain: name, price_usd: price });
      }
      if (path === '/api/domains/my' && method === 'GET') {
        await rateCheck(env.RATELIMIT, `ip:${request.headers.get('cf-connecting-ip') || 'x'}`, 30, 60);
        await ensureSubdomainTables(env.DB);
        const email = vStr(url.searchParams.get('email'), 'email', 3, 120).toLowerCase();
        const rows = await env.DB.prepare(
          'SELECT subdomain, price_monthly, status, target, created_at, expires_at FROM subdomains WHERE owner_email = ? ORDER BY created_at DESC LIMIT 100'
        ).bind(email).all<SubdomainRow>();
        return json({
          domains: rows.results.map((r) => ({
            subdomain: r.subdomain,
            fqdn: `${r.subdomain}.novamail.store`,
            price_monthly: r.price_monthly,
            status: r.status,
            target: r.target || null,
            created_at: r.created_at,
            expires_at: r.expires_at,
          })),
        });
      }


      // ---------- Buyer DNS management (email-ownership verified) ----------
      // Only A/CNAME/TXT. NS/MX/SRV are rejected by vEnum (fail closed).
      if (path === '/api/domains/dns' && method === 'GET') {
        await rateCheck(env.RATELIMIT, `ip:${request.headers.get('cf-connecting-ip') || 'x'}`, 30, 60);
        await ensureDnsTables(env.DB);
        const name = (`${url.searchParams.get('subdomain') || ''}`).toLowerCase().trim().replace(/\.novamail\.store$/, '');
        const email = vStr(url.searchParams.get('email'), 'email', 3, 120).toLowerCase();
        const sub = await ownedSubdomain(env.DB, name, email);
        const rows = await env.DB.prepare(
          'SELECT id, type, name, content, ttl, created_at FROM dns_records WHERE subdomain_id = ? ORDER BY created_at ASC LIMIT 100'
        ).bind(sub.id).all<DnsRecordRow>();
        return json({
          subdomain: sub.subdomain,
          fqdn: `${sub.subdomain}.novamail.store`,
          status: sub.status,
          records: rows.results.map((r) => ({
            id: r.id, type: r.type, name: r.name,
            fqdn: dnsFqdn(sub.subdomain, r.name),
            content: r.content, ttl: r.ttl, created_at: r.created_at,
          })),
        });
      }
      if (path === '/api/domains/dns' && method === 'POST') {
        await rateCheck(env.RATELIMIT, `ip:${request.headers.get('cf-connecting-ip') || 'x'}`, 20, 60);
        await ensureDnsTables(env.DB);
        const dip = request.headers.get('cf-connecting-ip') || 'unknown-ip';
        const b = await readJson(request) as Record<string, unknown>;
        const name = (`${b.subdomain || ''}`).toLowerCase().trim().replace(/\.novamail\.store$/, '');
        const email = vStr(b.email, 'email', 3, 120).toLowerCase();
        const type = vEnum(`${b.type || ''}`.toUpperCase(), DNS_ALLOWED_TYPES, 'type');
        const recName = `${b.name === undefined || b.name === null || `${b.name}`.trim() === '' ? '@' : b.name}`.toLowerCase().trim();
        const rawContent = `${b.content || ''}`.trim();
        const ttl = (b.ttl === undefined || b.ttl === null || `${b.ttl}`.trim() === '') ? 3600 : vNum(Number(b.ttl), 'ttl', 60, 86400);
        if (!isValidDnsName(recName)) throw httpError(400, 'invalid_record_name');
        const sub = await ownedSubdomain(env.DB, name, email);
        if (sub.status !== 'active') throw httpError(403, 'domain_not_active');
        // Per-type content validation.
        let content = rawContent;
        if (type === 'A') {
          if (!isValidIPv4(content)) throw httpError(400, 'invalid_ipv4');
        } else if (type === 'CNAME') {
          content = content.toLowerCase().replace(/^https?:\/\//, '').split('/')[0].split(':')[0].split('?')[0];
          if (!isValidHostname(content)) throw httpError(400, 'invalid_hostname');
          if (content === 'novamail.store' || content.endsWith('.novamail.store')) throw httpError(400, 'target_not_allowed');
          if (blocklistedTarget(content)) throw httpError(400, 'target_blocklisted');
        } else {
          if (!content || content.length > 255 || /[\r\n]/.test(content)) throw httpError(400, 'invalid_txt');
        }
        await dnsChangeQuota(env.DB, sub.id);
        const fqdn = dnsFqdn(sub.subdomain, recName);
        const cfId = await cfDnsCreateTyped(env, type, fqdn, content, ttl);
        const id = newId();
        await env.DB.prepare(
          'INSERT INTO dns_records (id, subdomain_id, type, name, content, ttl, cf_record_id, created_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?)'
        ).bind(id, sub.id, type, recName, content, ttl, cfId, now()).run();
        await dnsLog(env.DB, sub.id, 'add', `${type} ${fqdn} -> ${content.slice(0, 120)}`, dip);
        return json({ ok: true, id });
      }
      if (path.startsWith('/api/domains/dns/') && method === 'DELETE') {
        await rateCheck(env.RATELIMIT, `ip:${request.headers.get('cf-connecting-ip') || 'x'}`, 20, 60);
        await ensureDnsTables(env.DB);
        const dip = request.headers.get('cf-connecting-ip') || 'unknown-ip';
        const recId = vStr(decodeURIComponent(path.slice('/api/domains/dns/'.length)), 'id', 1, 64);
        const b = await readJson(request) as Record<string, unknown>;
        const name = (`${b.subdomain || ''}`).toLowerCase().trim().replace(/\.novamail\.store$/, '');
        const email = vStr(b.email, 'email', 3, 120).toLowerCase();
        const sub = await ownedSubdomain(env.DB, name, email);
        if (sub.status !== 'active') throw httpError(403, 'domain_not_active');
        const rec = await env.DB.prepare(
          'SELECT id, type, name, content, cf_record_id FROM dns_records WHERE id = ? AND subdomain_id = ?'
        ).bind(recId, sub.id).first<DnsRecordRow>();
        if (!rec) throw httpError(404, 'record_not_found');
        await dnsChangeQuota(env.DB, sub.id);
        await cfDnsDelete(env, rec.cf_record_id);
        await env.DB.prepare('DELETE FROM dns_records WHERE id = ?').bind(rec.id).run();
        await dnsLog(env.DB, sub.id, 'delete', `${rec.type} ${dnsFqdn(sub.subdomain, rec.name)}`, dip);
        return json({ ok: true });
      }
      // ---------- Abuse reports (public) ----------
      if (path === '/api/domains/report' && method === 'POST') {
        await rateCheck(env.RATELIMIT, `ip:${request.headers.get('cf-connecting-ip') || 'x'}`, 10, 60);
        await ensureDnsTables(env.DB);
        const b = await readJson(request) as Record<string, unknown>;
        const name = (`${b.subdomain || ''}`).toLowerCase().trim().replace(/\.novamail\.store$/, '');
        const reason = vStr(b.reason, 'reason', 5, 500);
        const reporterRaw = `${b.reporter_email || ''}`.trim();
        const reporter = reporterRaw === '' ? '' : vStr(reporterRaw, 'reporter_email', 3, 120).toLowerCase();
        if (reporter && !/^[^@\s]+@[^@\s]+\.[^@\s]+$/.test(reporter)) throw httpError(400, 'email_invalid');
        if (!isValidSubdomain(name)) throw httpError(400, 'invalid_name');
        const sub = await env.DB.prepare('SELECT id FROM subdomains WHERE subdomain = ?').bind(name).first();
        if (!sub) throw httpError(404, 'domain_not_found');
        await env.DB.prepare(
          "INSERT INTO abuse_reports (id, subdomain, reason, reporter_email, status, created_at) VALUES (?, ?, ?, ?, 'open', ?)"
        ).bind(newId(), name, reason, reporter, now()).run();
        return json({ ok: true });
      }
      // ---------- Admin: suspend a subdomain (abuse). Deletes ALL DNS. ----------
      if (path === '/api/admin/domains/suspend' && method === 'POST') {
        await adminGuard(request, env);
        await ensureDnsTables(env.DB);
        const b = await readJson(request) as Record<string, unknown>;
        const name = (`${b.subdomain || ''}`).toLowerCase().trim().replace(/\.novamail\.store$/, '');
        const sub = await env.DB.prepare('SELECT id, dns_record_id FROM subdomains WHERE subdomain = ?')
          .bind(name).first<{ id: string; dns_record_id: string }>();
        if (!sub) throw httpError(404, 'domain_not_found');
        await cfDnsDelete(env, sub.dns_record_id);
        const recs = await env.DB.prepare('SELECT id, cf_record_id FROM dns_records WHERE subdomain_id = ?')
          .bind(sub.id).all<{ id: string; cf_record_id: string }>();
        for (const r of recs.results) await cfDnsDelete(env, r.cf_record_id);
        await env.DB.prepare('DELETE FROM dns_records WHERE subdomain_id = ?').bind(sub.id).run();
        await env.DB.prepare("UPDATE subdomains SET status = 'suspended', dns_record_id = '' WHERE id = ?").bind(sub.id).run();
        await env.DB.prepare("UPDATE abuse_reports SET status = 'actioned' WHERE subdomain = ? AND status = 'open'").bind(name).run();
        await dnsLog(env.DB, sub.id, 'suspend', 'admin suspension', 'admin');
        return json({ ok: true });
      }
      if (path === '/api/admin/domains/reports' && method === 'GET') {
        await adminGuard(request, env);
        await ensureDnsTables(env.DB);
        const status = vEnum(`${url.searchParams.get('status') || 'open'}`, ['open', 'actioned', 'dismissed'] as const, 'status');
        const rows = await env.DB.prepare(
          'SELECT id, subdomain, reason, reporter_email, status, created_at FROM abuse_reports WHERE status = ? ORDER BY created_at DESC LIMIT 100'
        ).bind(status).all();
        return json({ reports: rows.results });
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
        const domainBuy = txRef.startsWith('nova_domain_');
        const msg = settled
          ? (domainBuy
              ? 'Payment confirmed — your subdomain is being activated. It can take a minute for DNS to propagate; check https://domains.novamail.store for status.'
              : 'Payment confirmed. Your Nova Coins are on the way — you can return to the Nova app.')
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
        // SECURITY: users may only notify their OWN devices. Cross-user push
        // is an abuse/spam/phishing vector — server-side events use notifyUser().
        const targetUid = uid;
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
          await rateCheck(env.RATELIMIT, `ip:${request.headers.get('cf-connecting-ip') || 'x'}`, 60, 60);
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


      // ---------- marketplace cart ----------
      {
        const cm = path.match(/^\/api\/market\/cart$/);
        if (cm && method === 'GET') {
          const uid = await guard(request, env, 60);
          await env.DB.prepare(`CREATE TABLE IF NOT EXISTS cart_items (
            uid TEXT NOT NULL, product_id TEXT NOT NULL, qty INTEGER NOT NULL DEFAULT 1,
            added_at INTEGER NOT NULL, PRIMARY KEY (uid, product_id))`).run();
          const rows = await env.DB.prepare(
            `SELECT c.*, p.title, p.price_usd, p.image_url, p.seller_uid, u.handle as seller_handle
             FROM cart_items c JOIN products p ON p.id = c.product_id
             JOIN users u ON u.uid = p.seller_uid
             WHERE c.uid = ? ORDER BY c.added_at DESC`
          ).bind(uid).all();
          return json({ items: rows.results || [] });
        }
        if (cm && method === 'POST') {
          const uid = await guard(request, env, 60);
          const body = await request.json() as Record<string, unknown>;
          const pid = vStr(body.product_id, 'product_id', 1, 64);
          const qty = Math.max(1, Math.min(99, Number(body.qty) || 1));
          await env.DB.prepare(`CREATE TABLE IF NOT EXISTS cart_items (
            uid TEXT NOT NULL, product_id TEXT NOT NULL, qty INTEGER NOT NULL DEFAULT 1,
            added_at INTEGER NOT NULL, PRIMARY KEY (uid, product_id))`).run();
          await env.DB.prepare(
            'INSERT INTO cart_items (uid, product_id, qty, added_at) VALUES (?, ?, ?, ?) ON CONFLICT(uid, product_id) DO UPDATE SET qty = qty + ?'
          ).bind(uid, pid, qty, now(), qty).run();
          return json({ ok: true });
        }
        if (cm && method === 'DELETE') {
          const uid = await guard(request, env, 60);
          const body = await request.json().catch(() => ({})) as Record<string, unknown>;
          if (body.product_id) {
            await env.DB.prepare('DELETE FROM cart_items WHERE uid = ? AND product_id = ?').bind(uid, vStr(body.product_id, 'product_id', 1, 64)).run();
          } else {
            await env.DB.prepare('DELETE FROM cart_items WHERE uid = ?').bind(uid).run();
          }
          return json({ ok: true });
        }
      }
      // ---------- shipments with tracking ----------
      {
        const sm = path.match(/^\/api\/market\/shipments$/);
        if (sm && method === 'GET') {
          const uid = await guard(request, env, 60);
          await env.DB.prepare(`CREATE TABLE IF NOT EXISTS nova_shipments (
            id TEXT PRIMARY KEY, order_id TEXT NOT NULL, buyer_uid TEXT NOT NULL,
            seller_uid TEXT NOT NULL, carrier TEXT NOT NULL, service TEXT NOT NULL,
            tracking_number TEXT NOT NULL, status TEXT NOT NULL DEFAULT 'label_created',
            created_at INTEGER NOT NULL)`).run();
          const rows = await env.DB.prepare(
            `SELECT s.*, p.title as product_title FROM nova_shipments s
             LEFT JOIN orders o ON o.id = s.order_id
             LEFT JOIN products p ON p.id = o.product_id
             WHERE s.buyer_uid = ? ORDER BY s.created_at DESC LIMIT 50`
          ).bind(uid).all();
          return json({ shipments: rows.results || [] });
        }
      }


      // ---------- marketplace escrow checkout ----------
      {
        const cm = path.match(/^\/api\/market\/checkout$/);
        if (cm && method === 'POST') {
          const uid = await guard(request, env, 60);
          const body = await request.json() as Record<string, unknown>;
          const carrier = vStr(body.carrier, 'carrier', 1, 32); // 'easyship' | 'fedex' | 'ups'
          const service = vStr(body.service, 'service', 1, 32); // 'express' | 'standard' | 'economy'
          // Get cart items
          const cart = await env.DB.prepare(
            `SELECT c.*, p.price_usd, p.seller_uid, p.title, p.weight_kg
             FROM cart_items c JOIN products p ON p.id = c.product_id WHERE c.uid = ?`
          ).bind(uid).all();
          const items = cart.results || [];
          if (!items.length) throw httpError(400, 'cart_empty');
          // Calculate subtotal
          let subtotal = 0;
          for (const it of items as any[]) subtotal += (it.price_usd || 0) * (it.qty || 1);
          // Shipping: distance-based (simplified - real calc via carrier API)
          // Base rates: domestic $5-15, international $25-80 by service level
          const isIntl = body.is_international === true;
          let shipping = 0;
          if (service === 'express') shipping = isIntl ? 80 : 25;
          else if (service === 'standard') shipping = isIntl ? 45 : 12;
          else shipping = isIntl ? 25 : 5;
          // Tax: 8% (simplified)
          const tax = Math.round(subtotal * 0.08 * 100) / 100;
          const total = Math.round((subtotal + shipping + tax) * 100) / 100;
          // Nova commission: 5%
          const commission = Math.round(subtotal * 0.05 * 100) / 100;
          // Create escrow order
          const orderId = 'ord_' + crypto.randomUUID().slice(0, 12);
          await env.DB.prepare(`CREATE TABLE IF NOT EXISTS market_orders (
            id TEXT PRIMARY KEY, buyer_uid TEXT NOT NULL, total_usd REAL NOT NULL,
            subtotal_usd REAL NOT NULL, shipping_usd REAL NOT NULL, tax_usd REAL NOT NULL,
            commission_usd REAL NOT NULL, carrier TEXT NOT NULL, service TEXT NOT NULL,
            status TEXT NOT NULL DEFAULT 'payment_pending', flutterwave_ref TEXT,
            created_at INTEGER NOT NULL)`).run();
          await env.DB.prepare(
            'INSERT INTO market_orders (id, buyer_uid, total_usd, subtotal_usd, shipping_usd, tax_usd, commission_usd, carrier, service, status, created_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)'
          ).bind(orderId, uid, total, subtotal, shipping, tax, commission, carrier, service, 'payment_pending', now()).run();
          // Create order items
          await env.DB.prepare(`CREATE TABLE IF NOT EXISTS market_order_items (
            id TEXT PRIMARY KEY, order_id TEXT NOT NULL, product_id TEXT NOT NULL,
            seller_uid TEXT NOT NULL, qty INTEGER NOT NULL, price_usd REAL NOT NULL)`).run();
          for (const it of items as any[]) {
            await env.DB.prepare(
              'INSERT INTO market_order_items (id, order_id, product_id, seller_uid, qty, price_usd) VALUES (?, ?, ?, ?, ?, ?)'
            ).bind('oi_' + crypto.randomUUID().slice(0, 12), orderId, it.product_id, it.seller_uid, it.qty, it.price_usd).run();
          }
          // Clear cart
          await env.DB.prepare('DELETE FROM cart_items WHERE uid = ?').bind(uid).run();
          return json({ order_id: orderId, subtotal, shipping, tax, total, commission, currency: 'USD' });
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
    // Expire sold subdomains: delete the DNS record, mark expired.
    // Buyers can renew via /api/domains/renew (manual monthly renewal).
    try {
      await ensureSubdomainTables(env.DB);
      const expired = await env.DB.prepare(
        "SELECT id, dns_record_id FROM subdomains WHERE status = 'active' AND expires_at <= ? LIMIT 100"
      ).bind(t).all<{ id: string; dns_record_id: string }>();
      for (const r of expired.results) {
        await cfDnsDelete(env, r.dns_record_id);
        await env.DB.prepare("UPDATE subdomains SET status = 'expired', dns_record_id = '' WHERE id = ?").bind(r.id).run();
      }
    } catch { /* retry tomorrow */ }
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
    // New format: nova_verify_<tier>_<months>_<uid>_<uuid>
    // Legacy format: nova_verify_<uid>_<uuid> (treated as personal/1 month)
    const parts = txRef.split('_');
    let tier: string, months: number, uid: string;
    if (parts.length >= 6 && ['personal', 'business', 'company'].includes(parts[2])) {
      tier = parts[2];
      months = parseInt(parts[3], 10) || 1;
      uid = parts.slice(4, -1).join('_'); // uid may contain underscores? no, but safe
      // Actually uids never contain '_', and uuid is last part
      uid = parts[4];
    } else {
      // Legacy: nova_verify_<uid>_<uuid>
      tier = 'personal';
      months = 1;
      uid = parts[2];
    }
    // Verify against the purchase record (source of truth for amount)
    const purchase = await env.DB.prepare(
      'SELECT tier, months, amount_usd FROM verification_purchases WHERE tx_ref = ?'
    ).bind(txRef).first<{ tier: string; months: number; amount_usd: number }>();
    const expectedTier = purchase?.tier || tier;
    const expectedMonths = purchase?.months || months;
    const expectedAmount = purchase?.amount_usd ?? verifyPriceFor(expectedTier as VerifyTier, expectedMonths as 3 | 6 | 12);
    if (currency !== 'USD' || Math.abs(amount - expectedAmount) > 0.01) {
      console.error('verify settlement mismatch', JSON.stringify({ txRef, amount, expectedAmount }));
      return;
    }
    const dup = await env.DB.prepare('SELECT 1 FROM verification_subscriptions WHERE tx_ref = ?').bind(txRef).first();
    if (dup) return; // idempotent
    const userRow = await env.DB.prepare('SELECT uid FROM users WHERE uid = ?').bind(uid).first();
    if (!userRow) return;
    const expiresAt = t + expectedMonths * 30 * 86400 * 1000;
    await env.DB.prepare(
      `INSERT INTO verification_subscriptions (uid, status, tier, started_at, expires_at, tx_ref, updated_at)
       VALUES (?, 'active', ?, ?, ?, ?, ?)
       ON CONFLICT(uid) DO UPDATE SET status='active', tier=excluded.tier, started_at=excluded.started_at, expires_at=excluded.expires_at, tx_ref=excluded.tx_ref, updated_at=excluded.updated_at`,
    )
      .bind(uid, expectedTier, t, expiresAt, txRef, t)
      .run();
    // Also set verification_type on users table for fast lookups
    await env.DB.prepare(
      `UPDATE users SET verification_type = ?, verification_expires_at = ? WHERE uid = ?`
    ).bind(expectedTier, expiresAt, uid).run().catch(() => {});
    await publishToUser(env, uid, { type: 'verification', verified: true, tier: expectedTier });
    return;
  }
  if (txRef.startsWith('nova_domain_')) {
    // Subdomain purchase or renewal. Source of truth is domain_purchases
    // (written at buy/renew time); tx_ref is never parsed.
    const p = await env.DB.prepare('SELECT amount_usd, settled FROM domain_purchases WHERE tx_ref = ?')
      .bind(txRef).first<{ amount_usd: number; settled: number }>();
    if (!p || p.settled) return; // unknown tx_ref, or already provisioned
    if (currency !== 'USD' || Math.abs(amount - p.amount_usd) > 0.001) {
      console.error('domain settlement mismatch');
      return;
    }
    await provisionDomainPurchase(env, txRef);
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
