# Nova

A TikTok-style short-video social app, expanded with a per-user crypto
wallet, cross-border P2P trading with escrow, a marketplace with
in-profile storefronts, trade-based reputation, and x402-ready hooks for
AI-agent commerce.

**Clean-room build:** product behavior was reverse-engineered from public
sources (see `docs/TIKTOK_RESEARCH.md`). All code, UI, and assets are
original. No TikTok code, brand, logo, or music is used or referenced.

## Repo layout

```
Nova/
  app/        Flutter app (package com.nova.app) — feed, upload, profiles,
              DMs, wallet, P2P, marketplace, settings
  backend/    Cloudflare Workers API (TypeScript) + D1 schema + R2 media +
              Durable Object realtime sync
  docs/       TIKTOK_RESEARCH.md, SETUP.md
  SECURITY.md Threat model + key-custody contract
```

## What v1 actually is (honest scope)

**Works out of the box (demo mode, no cloud keys needed):**
- TikTok-style vertical video feed with like/comment/share/save, seeded
  with sample videos; heuristic ranking (no ML); blue-tick rendering
- Following feed, upload flow (pick video → caption/hashtags → post),
  profiles with Videos + Store tabs, search/discover, inbox + 1:1 chat UI
- **On-device nudity scan**: real TFLite NSFW classifier (bundled model)
  scans sampled video frames pre-upload — high-confidence blocks the
  upload + files a report, borderline quarantines for review (see
  SECURITY.md §10). Strict, $0, private (nothing leaves the phone).
- **Auth**: username or email login (server-side resolution), TOTP 2FA
  (authenticator app), biometric wallet unlock. Official **@nova** account
  (auto-verified, auto-followed, can't be blocked/reported); #nova and
  #officialnova pinned trending with FYP boost.
- **Promote**: boost videos from $7/day (~1k engagements) via Flutterwave;
  labeled "Promoted", metrics dashboard, estimated (not guaranteed) reach.
- **Trust**: fraud/impersonation reports → review queue; fraud cases get
  jurisdiction routing (EFCC / FBI-IC3) with evidence capture and
  audit-logged KYC access; bot accounts labeled BOT.
- KYC flow UI (document upload + status; verification is manual-review in
  v1). **Wallet unlocks only after KYC verified** — enforced app-side and
  server-side.
- Wallet: real BIP39 mnemonic → EVM (ETH/USDT/USDC) + BTC addresses via
  on-device BIP32 derivation (verified against official BIP32 test vectors
  in `test/`), AES-256-GCM keystore encrypted with a PIN-derived key
  (PBKDF2 210k), ciphertext-only backup to the API. Send/receive on-chain
  only — no fiat in the wallet UI.
- **Nova Coin**: in-app currency bought with USD via Flutterwave
  (packages $5/$10/$25); spent on LIVE gifts and tips; never touches the
  crypto wallet. Demo mode simulates purchase credit (labeled).
- **LIVE rooms**: 1000+ followers required to broadcast (enforced both
  ends); live chat, viewer count, gift picker with original full-screen
  animated gift effects (coin burst, heart, rocket, crown — pure Flutter,
  no copied assets). v1 video layer is a realtime room; RTMP/WebRTC
  ingest is a documented TODO.
- **Verification badge**: $25/month via the Flutterwave backend flow;
  blue tick on profiles + comments; status checked server-side.
- P2P offer board, offer detail, escrow lifecycle UI against the API
  contract (works against a local demo ledger when the API is unset)
- Marketplace listings + product detail + in-profile storefronts
- Settings: network toggle (testnet default), KYC status, security info

**Needs your cloud keys (see docs/SETUP.md):** Firebase Auth + FCM,
Cloudflare Worker/D1/R2 deploy, Flutterwave keys. Until then the app
runs locally and every cloud call fails closed with a clear message.

**Labeled stubs in v1:** Duet/Stitch (API fields reserved), LIVE video
ingest (RTMP/WebRTC provider integration), on-chain HTLC escrow (v1
escrow is an API-enforced state record — see SECURITY.md §5), mainnet
broadcasts (gated, testnet default), KYC provider (manual review),
verification auto-renewal (manual monthly re-subscribe).

## Architecture

- **Auth:** Firebase Auth (email). Every API call carries the Firebase ID
  token; the Worker verifies it against Google's JWKS (`jose`), no Admin
  SDK needed.
- **Data:** Cloudflare D1 (SQLite) via Workers; media in R2.
- **Realtime:** Durable Object `SyncHub` per user, WebSocket pub/sub;
  D1 remains the source of truth.
- **Push:** Firebase Cloud Messaging; token registered to backend, sends
  via FCM HTTP v1 with a service-account secret.
- **Fiat:** Flutterwave v3, server-side only (`/api/payments/charge`),
  webhook signature-verified. No payment links anywhere.
- **Wallet security:** see SECURITY.md — ciphertext-only backups, server
  never sees PIN or plaintext keys.

## Build

```bash
export PATH=~/workspace/.flutter-sdk/flutter/bin:$PATH
export ANDROID_HOME=~/workspace/android-sdk
cd app && flutter pub get && flutter analyze && flutter build apk --debug
```

## Roadmap (phases, per the product plan)

1. **Wallet + P2P** (this repo's v1 core): non-custodial wallet, in-chat
   sends, P2P offers, escrow records, trade reputation.
2. **Marketplace**: storefronts on reputation, verified reviews.
3. **Rich social**: ranking upgrades, LIVE, duet/stitch.
4. **AI agents + x402**: paywalled content/APIs payable in stablecoins,
   agent spending limits.

## License

MIT — see LICENSE.
