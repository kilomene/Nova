-- Nova backend D1 schema (SQLite). Apply with:
--   wrangler d1 execute nova-db --file=./schema.sql

CREATE TABLE IF NOT EXISTS users (
  uid TEXT PRIMARY KEY,                 -- Firebase Auth uid
  handle TEXT UNIQUE NOT NULL,
  display_name TEXT NOT NULL DEFAULT '',
  bio TEXT NOT NULL DEFAULT '',
  avatar_url TEXT NOT NULL DEFAULT '',
  kyc_status TEXT NOT NULL DEFAULT 'none', -- none|pending|verified|rejected
  status TEXT NOT NULL DEFAULT 'active',   -- active|suspended|banned (moderation)
  is_bot INTEGER NOT NULL DEFAULT 0,       -- 1 = agent-created bot account
  trader_score REAL NOT NULL DEFAULT 0,     -- reputation from completed trades
  trades_completed INTEGER NOT NULL DEFAULT 0,
  created_at INTEGER NOT NULL,
  updated_at INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_users_handle ON users(handle);

-- OPAQUE ciphertext only. Server must never see PIN or plaintext keys.
CREATE TABLE IF NOT EXISTS keystores (
  uid TEXT PRIMARY KEY REFERENCES users(uid) ON DELETE CASCADE,
  bundle TEXT NOT NULL,  -- JSON: {kdf, iterations, salt, nonce, ciphertext, evmAddress, btcAddress, createdAt}
  updated_at INTEGER NOT NULL
);

CREATE TABLE IF NOT EXISTS videos (
  id TEXT PRIMARY KEY,
  uid TEXT NOT NULL REFERENCES users(uid) ON DELETE CASCADE,
  caption TEXT NOT NULL DEFAULT '',
  hashtags TEXT NOT NULL DEFAULT '[]',  -- JSON array
  media_key TEXT NOT NULL,               -- R2 key
  media_url TEXT NOT NULL DEFAULT '',   -- /media/<key>
  thumb_url TEXT NOT NULL DEFAULT '',
  duration_sec REAL NOT NULL DEFAULT 0,
  sound_label TEXT NOT NULL DEFAULT '',
  audio_key TEXT NOT NULL DEFAULT '',    -- user-supplied original audio (R2 key); no licensed catalog in v1
  like_count INTEGER NOT NULL DEFAULT 0,
  comment_count INTEGER NOT NULL DEFAULT 0,
  share_count INTEGER NOT NULL DEFAULT 0,
  view_count INTEGER NOT NULL DEFAULT 0,
  visibility TEXT NOT NULL DEFAULT 'public',
  created_at INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_videos_uid ON videos(uid);
CREATE INDEX IF NOT EXISTS idx_videos_created ON videos(created_at DESC);

CREATE TABLE IF NOT EXISTS likes (
  uid TEXT NOT NULL,
  video_id TEXT NOT NULL REFERENCES videos(id) ON DELETE CASCADE,
  created_at INTEGER NOT NULL,
  PRIMARY KEY (uid, video_id)
);

CREATE TABLE IF NOT EXISTS comments (
  id TEXT PRIMARY KEY,
  video_id TEXT NOT NULL REFERENCES videos(id) ON DELETE CASCADE,
  uid TEXT NOT NULL,
  text TEXT NOT NULL,
  parent_id TEXT,
  like_count INTEGER NOT NULL DEFAULT 0,
  created_at INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_comments_video ON comments(video_id, created_at);

CREATE TABLE IF NOT EXISTS follows (
  follower_uid TEXT NOT NULL,
  followee_uid TEXT NOT NULL,
  created_at INTEGER NOT NULL,
  PRIMARY KEY (follower_uid, followee_uid)
);

-- Blocking: a blocked user cannot see the blocker's content AT ALL
-- (feed, profile, comments, messages) until unblocked.
CREATE TABLE IF NOT EXISTS blocks (
  blocker_uid TEXT NOT NULL,
  blocked_uid TEXT NOT NULL,
  created_at INTEGER NOT NULL,
  PRIMARY KEY (blocker_uid, blocked_uid)
);

CREATE TABLE IF NOT EXISTS threads (
  id TEXT PRIMARY KEY,          -- deterministic: sort(uidA,uidB) joined
  user_a TEXT NOT NULL,
  user_b TEXT NOT NULL,
  last_message TEXT NOT NULL DEFAULT '',
  updated_at INTEGER NOT NULL
);

CREATE TABLE IF NOT EXISTS messages (
  id TEXT PRIMARY KEY,
  thread_id TEXT NOT NULL REFERENCES threads(id) ON DELETE CASCADE,
  sender_uid TEXT NOT NULL,
  text TEXT NOT NULL DEFAULT '',
  media_key TEXT NOT NULL DEFAULT '',
  created_at INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_messages_thread ON messages(thread_id, created_at);

CREATE TABLE IF NOT EXISTS p2p_offers (
  id TEXT PRIMARY KEY,
  uid TEXT NOT NULL REFERENCES users(uid) ON DELETE CASCADE,
  side TEXT NOT NULL,            -- buy | sell  (side of the maker, in crypto)
  asset TEXT NOT NULL,           -- BTC | ETH | USDT | USDC
  fiat_currency TEXT NOT NULL,   -- USD | NGN | ...
  price REAL NOT NULL,           -- fiat per 1 unit of asset
  min_amount REAL NOT NULL,
  max_amount REAL NOT NULL,
  payment_methods TEXT NOT NULL DEFAULT '[]', -- JSON array of strings
  terms TEXT NOT NULL DEFAULT '',
  status TEXT NOT NULL DEFAULT 'open',        -- open | paused | closed
  created_at INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_offers_asset ON p2p_offers(asset, fiat_currency, status);

CREATE TABLE IF NOT EXISTS escrows (
  id TEXT PRIMARY KEY,
  offer_id TEXT NOT NULL REFERENCES p2p_offers(id),
  buyer_uid TEXT NOT NULL,
  seller_uid TEXT NOT NULL,
  asset TEXT NOT NULL,
  crypto_amount REAL NOT NULL,
  fiat_amount REAL NOT NULL,
  fiat_currency TEXT NOT NULL,
  -- v1: escrow is a RECORD of the trade state. On-chain HTLC escrow is a labeled TODO.
  status TEXT NOT NULL DEFAULT 'awaiting_payment', -- awaiting_payment|paid|released|disputed|cancelled
  created_at INTEGER NOT NULL,
  updated_at INTEGER NOT NULL
);

CREATE TABLE IF NOT EXISTS listings (
  id TEXT PRIMARY KEY,
  uid TEXT NOT NULL REFERENCES users(uid) ON DELETE CASCADE,
  title TEXT NOT NULL,
  description TEXT NOT NULL DEFAULT '',
  price_usd REAL NOT NULL,
  asset TEXT NOT NULL DEFAULT 'USDC',
  media_keys TEXT NOT NULL DEFAULT '[]',  -- JSON array of R2 keys
  category TEXT NOT NULL DEFAULT 'general',
  status TEXT NOT NULL DEFAULT 'active',
  created_at INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_listings_cat ON listings(category, status);

CREATE TABLE IF NOT EXISTS orders (
  id TEXT PRIMARY KEY,
  listing_id TEXT NOT NULL REFERENCES listings(id),
  buyer_uid TEXT NOT NULL,
  seller_uid TEXT NOT NULL,
  price_usd REAL NOT NULL,
  asset TEXT NOT NULL,
  status TEXT NOT NULL DEFAULT 'pending', -- pending|paid|shipped|completed|cancelled|disputed
  -- TikTok Shop-grade receipt (itemized, stored in order history)
  items_json TEXT NOT NULL DEFAULT '[]',   -- [{title, priceUsd}]
  shipping_usd REAL NOT NULL DEFAULT 0,
  tax_usd REAL NOT NULL DEFAULT 0,
  total_usd REAL NOT NULL DEFAULT 0,
  payment_method TEXT NOT NULL DEFAULT 'flutterwave', -- flutterwave | crypto
  tracking_number TEXT NOT NULL DEFAULT '',
  shipping_carrier TEXT NOT NULL DEFAULT '',
  created_at INTEGER NOT NULL,
  updated_at INTEGER NOT NULL
);

-- Shipping/tracking timeline per order.
CREATE TABLE IF NOT EXISTS order_events (
  id TEXT PRIMARY KEY,
  order_id TEXT NOT NULL REFERENCES orders(id) ON DELETE CASCADE,
  status TEXT NOT NULL,
  note TEXT NOT NULL DEFAULT '',
  created_at INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_order_events ON order_events(order_id, created_at);

CREATE TABLE IF NOT EXISTS push_tokens (
  uid TEXT NOT NULL,
  token TEXT NOT NULL,
  platform TEXT NOT NULL DEFAULT 'android',
  updated_at INTEGER NOT NULL,
  PRIMARY KEY (uid, token)
);

-- ============ Nova Coin: in-app virtual currency (NOT crypto) ============
-- Bought with USD via Flutterwave; spent on LIVE gifts and tips.
CREATE TABLE IF NOT EXISTS nova_coin_balances (
  uid TEXT PRIMARY KEY REFERENCES users(uid) ON DELETE CASCADE,
  balance INTEGER NOT NULL DEFAULT 0,
  updated_at INTEGER NOT NULL
);
CREATE TABLE IF NOT EXISTS nova_coin_ledger (
  id TEXT PRIMARY KEY,
  uid TEXT NOT NULL,
  delta INTEGER NOT NULL,       -- +credit / -debit
  reason TEXT NOT NULL,         -- purchase | gift_sent | gift_received | verification | adjustment
  ref TEXT NOT NULL DEFAULT '',
  created_at INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_ledger_uid ON nova_coin_ledger(uid, created_at DESC);

CREATE TABLE IF NOT EXISTS gift_catalog (
  id TEXT PRIMARY KEY,
  name TEXT NOT NULL,
  coin_price INTEGER NOT NULL,
  creator_share INTEGER NOT NULL, -- coins credited to the recipient
  animation TEXT NOT NULL,        -- key the app maps to a built-in animation
  created_at INTEGER NOT NULL
);
INSERT OR IGNORE INTO gift_catalog (id, name, coin_price, creator_share, animation, created_at) VALUES
  ('coin_burst', 'Coin Burst', 10, 5, 'coin_burst', 0),
  ('nova_heart', 'Nova Heart', 50, 25, 'nova_heart', 0),
  ('rocket', 'Rocket', 100, 50, 'rocket', 0),
  ('crown', 'Golden Crown', 500, 250, 'crown', 0);

CREATE TABLE IF NOT EXISTS gift_transactions (
  id TEXT PRIMARY KEY,
  sender_uid TEXT NOT NULL,
  recipient_uid TEXT NOT NULL,
  gift_id TEXT NOT NULL,
  live_session_id TEXT NOT NULL DEFAULT '',
  coins_spent INTEGER NOT NULL,
  coins_credited INTEGER NOT NULL,
  created_at INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_gifts_recipient ON gift_transactions(recipient_uid, created_at DESC);

-- ============ LIVE sessions (1000+ followers required to go live) ============
CREATE TABLE IF NOT EXISTS live_sessions (
  id TEXT PRIMARY KEY,
  uid TEXT NOT NULL REFERENCES users(uid) ON DELETE CASCADE,
  title TEXT NOT NULL DEFAULT '',
  status TEXT NOT NULL DEFAULT 'live', -- live | ended
  viewer_count INTEGER NOT NULL DEFAULT 0,
  started_at INTEGER NOT NULL,
  ended_at INTEGER NOT NULL DEFAULT 0
);
CREATE INDEX IF NOT EXISTS idx_live_status ON live_sessions(status, started_at DESC);

-- ============ Verification badge: $25/month subscription ============
CREATE TABLE IF NOT EXISTS verification_subscriptions (
  uid TEXT PRIMARY KEY REFERENCES users(uid) ON DELETE CASCADE,
  status TEXT NOT NULL DEFAULT 'inactive', -- active | expired | cancelled
  started_at INTEGER NOT NULL DEFAULT 0,
  expires_at INTEGER NOT NULL DEFAULT 0,
  tx_ref TEXT NOT NULL DEFAULT '',
  updated_at INTEGER NOT NULL
);

-- ============ KYC: wallet is ONLY issued after verification ============
CREATE TABLE IF NOT EXISTS kyc_submissions (
  uid TEXT PRIMARY KEY REFERENCES users(uid) ON DELETE CASCADE,
  status TEXT NOT NULL DEFAULT 'pending', -- pending | verified | rejected
  doc_front_key TEXT NOT NULL DEFAULT '',
  doc_back_key TEXT NOT NULL DEFAULT '',
  selfie_key TEXT NOT NULL DEFAULT '',
  reviewer_note TEXT NOT NULL DEFAULT '',
  created_at INTEGER NOT NULL,
  updated_at INTEGER NOT NULL
);

-- ============ THREE-WALLET ARCHITECTURE (see SECURITY.md) ============
-- (a) Nova Coin purchase wallet: nova_coin_balances (above). Buy with USD via
--     Flutterwave, spend on gifts/tips ONLY. NEVER withdrawable/convertible.
-- (b) Creator earnings wallet: gift revenue lands here (platform cut applied).
--     This is the payout/withdrawal path.
-- (c) Crypto wallet: on-chain only (device-held keys); never in this DB.
CREATE TABLE IF NOT EXISTS creator_earnings_balances (
  uid TEXT PRIMARY KEY REFERENCES users(uid) ON DELETE CASCADE,
  balance INTEGER NOT NULL DEFAULT 0,        -- coins available for payout
  lifetime_earned INTEGER NOT NULL DEFAULT 0,
  updated_at INTEGER NOT NULL
);
CREATE TABLE IF NOT EXISTS creator_earnings_ledger (
  id TEXT PRIMARY KEY,
  uid TEXT NOT NULL,
  delta INTEGER NOT NULL,
  reason TEXT NOT NULL,  -- gift_received | payout_requested | payout_paid | adjustment
  ref TEXT NOT NULL DEFAULT '',
  created_at INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_earnings_uid ON creator_earnings_ledger(uid, created_at DESC);

-- Creator payouts: v1 records the request (status pending). Actual USD movement
-- via Flutterwave transfers is phase 2 (needs his Flutterwave transfer setup).
CREATE TABLE IF NOT EXISTS payout_requests (
  id TEXT PRIMARY KEY,
  uid TEXT NOT NULL,
  amount_coins INTEGER NOT NULL,
  amount_usd REAL NOT NULL,     -- coins / 100
  destination TEXT NOT NULL DEFAULT '',
  status TEXT NOT NULL DEFAULT 'pending', -- pending | paid | rejected
  created_at INTEGER NOT NULL,
  updated_at INTEGER NOT NULL
);

-- ============ Moderation: strikes, reports, review queue ============
-- Zero tolerance on nudity: instant flag + strike. 3 strikes = suspended.
-- Nudity on LIVESTREAM = instant ban (no 3-strike path).
CREATE TABLE IF NOT EXISTS strikes (
  id TEXT PRIMARY KEY,
  uid TEXT NOT NULL,
  reason TEXT NOT NULL,
  details TEXT NOT NULL DEFAULT '',
  created_at INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_strikes_uid ON strikes(uid, created_at DESC);

CREATE TABLE IF NOT EXISTS reports (
  id TEXT PRIMARY KEY,
  reporter_uid TEXT NOT NULL,
  target_type TEXT NOT NULL,  -- video | comment | user | live
  target_id TEXT NOT NULL,
  reason TEXT NOT NULL,       -- nudity | spam | harassment | fraud | other
  status TEXT NOT NULL DEFAULT 'open',  -- open | dismissed | actioned
  created_at INTEGER NOT NULL,
  reviewed_at INTEGER NOT NULL DEFAULT 0
);
CREATE INDEX IF NOT EXISTS idx_reports_status ON reports(status, created_at DESC);

-- ============ Seller onboarding (strict, TikTok-Shop-style) ============
-- Buyers need NO verification. Sellers must pass this before listing.
CREATE TABLE IF NOT EXISTS seller_profiles (
  uid TEXT PRIMARY KEY REFERENCES users(uid) ON DELETE CASCADE,
  full_name TEXT NOT NULL DEFAULT '',
  address TEXT NOT NULL DEFAULT '',
  phone TEXT NOT NULL DEFAULT '',
  email TEXT NOT NULL DEFAULT '',
  zip TEXT NOT NULL DEFAULT '',
  country TEXT NOT NULL DEFAULT '',
  id_type TEXT NOT NULL DEFAULT '',    -- ssn | nin | passport | drivers_license | national_id | other
  id_number TEXT NOT NULL DEFAULT '',  -- country-specific identity number
  id_doc_key TEXT NOT NULL DEFAULT '', -- R2 key of government ID scan
  status TEXT NOT NULL DEFAULT 'pending', -- pending | verified | rejected
  reviewer_note TEXT NOT NULL DEFAULT '',
  created_at INTEGER NOT NULL,
  updated_at INTEGER NOT NULL
);

-- ============ Devices: repeat-offender tracking ============
-- After 3 suspensions tied to a device it goes high-risk: no LIVE, no
-- selling, uploads held for review.
CREATE TABLE IF NOT EXISTS devices (
  device_id TEXT PRIMARY KEY,
  uid TEXT NOT NULL DEFAULT '',
  suspensions INTEGER NOT NULL DEFAULT 0,
  last_seen INTEGER NOT NULL DEFAULT 0
);

-- ============ Network blacklist: VPN / proxy / Tor egress ============
-- Server-side layer of the anti-VPN wall. IP reputation provider is a
-- pluggable interface (see docs/SETUP.md); auto+manual entries live here.
CREATE TABLE IF NOT EXISTS network_blacklist (
  ip TEXT PRIMARY KEY,
  reason TEXT NOT NULL,  -- vpn | proxy | tor | manual
  added_at INTEGER NOT NULL,
  expires_at INTEGER NOT NULL DEFAULT 0  -- 0 = permanent
);

-- ============ Support desk (agent-run console via /api/admin/support) ============
CREATE TABLE IF NOT EXISTS support_tickets (
  id TEXT PRIMARY KEY,
  uid TEXT NOT NULL,
  subject TEXT NOT NULL,
  status TEXT NOT NULL DEFAULT 'open',  -- open | answered | closed
  created_at INTEGER NOT NULL,
  updated_at INTEGER NOT NULL
);
CREATE TABLE IF NOT EXISTS support_replies (
  id TEXT PRIMARY KEY,
  ticket_id TEXT NOT NULL REFERENCES support_tickets(id) ON DELETE CASCADE,
  author TEXT NOT NULL,  -- user | agent
  message TEXT NOT NULL,
  created_at INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_support_uid ON support_tickets(uid, updated_at DESC);

-- ============ Auth: username login, TOTP 2FA, official account ============
-- Username login (username -> email resolution for Firebase sign-in).
ALTER TABLE users ADD COLUMN username TEXT UNIQUE;
-- Official company account (@nova): auto-verified (free), auto-followed,
-- cannot be blocked or reported.
ALTER TABLE users ADD COLUMN is_official INTEGER NOT NULL DEFAULT 0;
-- TOTP 2FA: secret stored encrypted with MEDIA_SIGNING_SECRET-derived key.
-- NULL = not set up; totp_enabled = 1 after verification.
ALTER TABLE users ADD COLUMN totp_secret TEXT;
ALTER TABLE users ADD COLUMN totp_enabled INTEGER NOT NULL DEFAULT 0;
-- Country for fraud jurisdiction routing (NG->NG = EFCC, NG->US = FBI/IC3).
ALTER TABLE users ADD COLUMN country TEXT NOT NULL DEFAULT '';

-- ============ Post promotion (TikTok Promote-style) ============
CREATE TABLE IF NOT EXISTS promotions (
  id TEXT PRIMARY KEY,
  video_id TEXT NOT NULL REFERENCES videos(id) ON DELETE CASCADE,
  uid TEXT NOT NULL,
  package TEXT NOT NULL,        -- starter | growth | scale
  amount_usd REAL NOT NULL,
  days INTEGER NOT NULL,
  est_reach INTEGER NOT NULL,   -- estimated engagements (NOT guaranteed)
  starts_at INTEGER NOT NULL,
  ends_at INTEGER NOT NULL,
  status TEXT NOT NULL DEFAULT 'active',  -- active | ended | cancelled
  payment_ref TEXT NOT NULL,    -- Flutterwave tx_ref
  created_at INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_promotions_video ON promotions(video_id, status, ends_at);

CREATE TABLE IF NOT EXISTS promotion_metrics (
  promotion_id TEXT NOT NULL REFERENCES promotions(id) ON DELETE CASCADE,
  day INTEGER NOT NULL,         -- days since start (0-based)
  views INTEGER NOT NULL DEFAULT 0,
  likes INTEGER NOT NULL DEFAULT 0,
  follows INTEGER NOT NULL DEFAULT 0,
  PRIMARY KEY (promotion_id, day)
);

-- ============ Fraud -> law enforcement pipeline ============
CREATE TABLE IF NOT EXISTS fraud_cases (
  id TEXT PRIMARY KEY,
  report_id TEXT NOT NULL REFERENCES reports(id),
  reporter_uid TEXT NOT NULL,
  target_uid TEXT NOT NULL,
  reporter_country TEXT NOT NULL DEFAULT '',
  target_country TEXT NOT NULL DEFAULT '',
  jurisdiction TEXT NOT NULL,   -- EFCC | FBI_IC3 | LOCAL | UNMAPPED
  evidence TEXT NOT NULL DEFAULT '{}',  -- JSON: descriptions, references
  status TEXT NOT NULL DEFAULT 'open',  -- open | investigating | filed | closed
  filed_ref TEXT NOT NULL DEFAULT '',   -- external case reference when filed
  created_at INTEGER NOT NULL,
  updated_at INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_fraud_status ON fraud_cases(status, created_at DESC);

-- KYC data access audit log (who accessed KYC data, when, why).
CREATE TABLE IF NOT EXISTS kyc_access_log (
  id TEXT PRIMARY KEY,
  accessor TEXT NOT NULL,       -- admin key id or 'system'
  uid TEXT NOT NULL,            -- whose KYC was accessed
  reason TEXT NOT NULL,
  created_at INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_kyc_access ON kyc_access_log(uid, created_at DESC);

-- Seed the official NOVA company account (@nova).
-- Managed by him + the agent; auto-verified (free, NOT the $25 subscription).
INSERT OR IGNORE INTO users (uid, handle, username, display_name, bio, kyc_status, status, is_official, created_at, updated_at)
VALUES ('nova_official', 'nova', 'nova', 'NOVA', 'The official NOVA account. Updates, announcements, and help.', 'verified', 'active', 1, 0, 0);

-- Email for username->email login resolution (Firebase holds the password).
ALTER TABLE users ADD COLUMN email TEXT;
