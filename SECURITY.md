# Nova Security Model

This document is the security contract for Nova v1. Read before touching
anything that handles keys, tokens, or money.

## 1. Key custody: the rule

**No plaintext private key or mnemonic may exist anywhere except in the
user's device RAM during an active signing session.** Not in code, not in
the database, not in logs, not in crash reports, not in the repo, not in
backups readable by us.

How we satisfy "private key safe in our database, never leaks":

1. On signup the app generates a fresh BIP39 mnemonic **on-device**
   (256-bit entropy from the platform CSPRNG).
2. The user picks a PIN. A 256-bit encryption key is derived from the PIN
   with PBKDF2-HMAC-SHA512, 210,000 iterations, random 16-byte salt.
3. The mnemonic JSON is encrypted with AES-256-GCM (random 12-byte nonce).
4. **Only the ciphertext bundle** `{kdf, iterations, salt, nonce,
   ciphertext, evmAddress, btcAddress, createdAt}` (all base64) is uploaded
   to D1 via the Workers API. The server stores it opaquely and can never
   decrypt it — it never sees the PIN.
5. To sign, the user enters the PIN on-device, the app decrypts in RAM,
   signs, and wipes the memory.

This is strictly safer than storing raw private keys server-side. A
database breach of Nova leaks only AES-GCM ciphertext, which is useless
without each user's PIN. (Server-side plaintext key storage is how
exchanges get drained; we deliberately do not do the literal reading of
"put the private key in our database".)

## 2. Threat model

| Threat | Mitigation |
|---|---|
| D1/R2 breach | Keys are ciphertext; PII minimal (handle, display name). No passwords stored — Firebase Auth owns identity. |
| Malicious insider at Nova | Cannot decrypt keystores (no PINs). Cannot mint Firebase tokens. |
| Lost/stolen device | Attacker needs the device PIN *and* the wallet PIN. Keystore ciphertext alone is insufficient. |
| Phishing / fake Nova app | Official builds only from this repo; APK signatures documented in README. Firebase App Check recommended before mainnet. |
| Firebase token theft | Short-lived ID tokens, verified server-side against Google JWKS on every authed call. |
| Webhook spoofing (Flutterwave) | `verif-hash` header compared (constant-time) against `FLUTTERWAVE_SECRET_HASH`. |
| Replay of payment webhooks | `tx_ref` values are unique per charge (`nova_<uid>_<uuid>`); verify every transaction server-side via Flutterwave `/verify` before crediting. |
| P2P fraud | Escrow state machine (only buyer→paid, only seller→release), dispute freeze, trader reputation from *completed* trades, payment-method evidence. v1 escrow is a state record — see §5. |
| Malicious video/media upload | 200 MB cap, content-type sniffed on serve, served from separate R2 origin, never executed. |
| Dependency supply chain | `flutter pub get` + `npm install` from lockfiles; no obfuscated blobs. |

## 3. Secrets handling

- All server secrets live in **Workers secrets** (`wrangler secret put`):
  `FLUTTERWAVE_SECRET_KEY`, `FLUTTERWAVE_SECRET_HASH`,
  `FIREBASE_SERVICE_ACCOUNT`. They never appear in code, logs, or git.
- `google-services.json` (real) is git-ignored; the repo carries a
  placeholder that fails closed with setup instructions.
- `.gitignore` covers: `google-services.json`, `*.jks`, `*.keystore`,
  `.env`, `wrangler` state, service-account JSON.

## 4. Network security

- All API traffic over HTTPS (Workers default). The app pins no certs in
  v1 (documented TODO: certificate pinning for api host).
- WebSocket sync requires a valid Firebase ID token in `?token=`; the
  Durable Object only relays — D1 is the source of truth.
- Authenticated endpoints reject missing/invalid bearer tokens with 401;
  unconfigured Firebase project fails **closed** with 501, never open.

## 5. Money movement — honest limits of v1

- **On-chain sends are testnet-first.** Mainnet broadcast is gated behind an
  explicit per-transaction confirmation screen and is OFF unless the user
  enables it in Settings → Wallet. Default network: Sepolia (ETH/USDC
  testnet) + Bitcoin testnet address format documented.
- **P2P escrow v1 is a state record, not an on-chain HTLC.** The trade
  lifecycle (awaiting_payment → paid → released / disputed) is enforced by
  the API state machine and reputation accrual. True non-custodial HTLC
  escrow is the explicit phase-2 upgrade (tracked in README TODO).
- **Flutterwave fiat on-ramp**: charges are created server-side with the
  secret key; every webhook is signature-checked AND the transaction is
  re-verified via Flutterwave `/verify` before any credit. No payment
  links are used anywhere.

## 6. KYC / identity data

- KYC status is a label (`none|pending|verified|rejected`) plus provider
  reference — we do not store ID document images in v1 (provider-hosted).
- Public profiles expose handle, display name, bio, avatar, trader score.
  Nothing else. Keystore data is never joined to public endpoints.

## 7. What "never leak" means operationally

- No logging of: PINs, mnemonics, private keys, ciphertext bundles,
  Firebase ID tokens, Flutterwave secrets.
- `console.error` on the Worker logs error *messages* only; request bodies
  are never logged.
- If you add logging, re-read this section first.

## 8. Backend hardening controls (v1)

- **Auth on every endpoint** except `/api/health`. Firebase ID tokens are
  verified against Google's JWKS on every call; unconfigured project id
  fails closed (501), never open. The app signs in anonymously when the
  user hasn't created an account, so logged-out browsing still carries a
  uid — there is no anonymous surface.
- **Rate limiting**: `RateLimit` Durable Object, per-key exact
  sliding-window counters. Per-IP 600 req/min globally; per-user
  240 req/min default, tighter on money/mutation paths (gifts 30/min,
  keystore 10/min, coin buy 20/min, KYC review 30/min per IP). 429s carry
  `Retry-After`.
- **Input validation**: every parameter validated (types, lengths, enums,
  numeric ranges) in `src/lib/validate.ts`. Unknown fields are ignored;
  oversized bodies rejected (413).
- **Error hygiene**: 4xx returns a stable machine code (`kyc_required`,
  `insufficient_coins`, …). 5xx returns generic `internal_error` to the
  client; details go to the Worker log only. Request bodies, tokens,
  ciphertext bundles, and secrets are never logged.
- **Webhooks**: `verif-hash` constant-time compared to
  `FLUTTERWAVE_SECRET_HASH`; every successful charge is re-verified via
  Flutterwave `/verify` and amount/currency/tx_ref matched before any
  credit; settlement is idempotent on `tx_ref` (ledger/webhook replays
  can't double-credit).
- **Money atomicity**: Nova Coin debit is a conditional
  `UPDATE ... WHERE balance >= ?` with `changes == 1` asserted before any
  credit is written (D1 serializes the writes; no double-spend).
- **Media**: no public R2 URLs. Playback/upload URLs are HMAC-signed with
  `MEDIA_SIGNING_SECRET`, 15-minute expiry.
- **KYC review**: manual-review endpoint requires `ADMIN_REVIEW_KEY`
  header; user auth tokens are not accepted there.
- **Secrets**: all five live in Workers secrets, never in code/env files.

## 9. Money separation (product rule)

- **Nova Coin** (in-app, bought with USD via Flutterwave): spent on LIVE
  gifts and creator tips. It is not crypto and never touches the wallet.
- **Crypto wallet** (BTC/ETH/USDT/USDC): on-chain send/receive ONLY. No
  fiat deposit, no on/off-ramp in the wallet UI. The two money systems
  never mix.

## 10. On-device nudity detection (real model, not a stub)

Content moderation runs a **real TFLite NSFW classifier on the device**,
pre-upload. Nothing is sent anywhere for scanning.

- **Model**: `app/assets/nsfw.tflite` — MobileNetV2-based binary NSFW
  classifier (23 MB, bundled in the APK). Input `[1,224,224,3]` float32,
  BGR order, ImageNet-mean centered (`B−104, G−117, R−123`; resize to 256,
  center-crop 224). Output `[1,2]` softmax — index 0 = SFW, index 1 = NSFW.
  Structure verified by parsing the model's flatbuffer (input/output tensor
  shapes); the preprocessing + output-index contract is pinned by
  `test/nudity_scanner_test.dart`.
- **What is scanned**: sampled video frames pre-upload (frames at ~0.5s,
  3s, 8s, 15s, 30s; max frame score wins — one bad frame flags the video).
  The image path (`scoreFile`) is implemented and will be wired when photo
  posts land (phase 2).
- **Tiered enforcement** (`lib/services/nudity_scanner.dart`):
  - score ≥ 0.85 → **BLOCK**: upload refused locally; a `nudity` report is
    filed so the review queue can issue a strike.
  - 0.60–0.85 → **QUARANTINE**: the video uploads with
    `visibility='quarantine'` (invisible in feeds) and an auto-filed
    `nudity` report; a strike is issued only if review confirms.
  - < 0.60 → **PASS**.
- **Honest limits**: the model is tuned for recall, so borderline content
  (e.g. swimwear-adjacent) can false-positive into quarantine — that is why
  borderline never auto-strikes and every report lands in the review queue
  (no auto-dismissal, per product rules). If the model fails to load, scans
  return `unavailable` and uploads proceed normally rather than bricking the
  app; the failure is logged on-device. LIVE video ingest (phase 2) will
  scan frames periodically; nudity on livestream = instant ban per the
  product rules.

## 11. Authentication: username login, TOTP 2FA, biometrics

- **Username or email login**: `POST /api/auth/resolve` maps a username to
  the Firebase email server-side (exact match, 10 req/min/IP — the standard
  username-enumeration tradeoff, documented). Passwords never touch our
  servers; Firebase Auth holds them.
- **TOTP 2FA** (Google Authenticator / iOS Passwords): RFC 6238, 6 digits,
  30s window, ±1 step skew tolerance. Secrets are AES-256-GCM encrypted
  server-side (key derived from `MEDIA_SIGNING_SECRET`) — never plaintext.
  Setup → verify → enable; login challenge after Firebase sign-in.
- **Biometric unlock**: platform fingerprint/face via `local_auth` gates
  wallet reveal on-device. Device-bound, not a synced WebAuthn passkey
  (full WebAuthn ceremony is phase 2).

## 12. Official account & promotions

- **@nova** (`nova_official`): seeded in `schema.sql`, `is_official=1`.
  Auto-verified badge (free — NOT the $25 subscription). Every new user
  auto-follows it at signup. It **cannot be blocked or reported**
  (enforced in `/api/blocks` and `/api/reports`).
- **#nova / #officialnova**: pinned top of `/api/hashtags/trending`;
  posts using them get +8 FYP score weight.
- **Promotions** (TikTok Promote-style): $7/1-day (~1k engagements),
  $25/3-day (~3.5k), $70/7-day (~10k). Paid via the hardened Flutterwave
  flow; webhook settlement is idempotent on `tx_ref`. Active promotions
  get +25 FYP score amplification and a **"Promoted" label** on the video.
  Reach is ESTIMATED, never guaranteed — stated in UI and API.

## 13. Fraud -> law enforcement pipeline

- **Report reasons** include `fraud` and `impersonation`. Fraud reports
  against users auto-create a `fraud_cases` row with jurisdiction routing:
  - reporter NG + target NG → **EFCC**
  - NG↔US (either direction) → **FBI/IC3**
  - same country (other) → **LOCAL**; otherwise **UNMAPPED**
- **Evidence**: fraud cases carry an evidence JSON blob (descriptions,
  references). Status flow: `open → investigating → filed → closed`
  with external `filed_ref` when the company files on the victim's behalf.
- **KYC access is audit-logged**: every admin fraud-case review writes to
  `kyc_access_log` (who, whose data, why, when). KYC data is
  access-controlled via `ADMIN_REVIEW_KEY`.
- **Authenticity**: agent-created bot accounts carry `is_bot=1` and are
  labeled **BOT** in the UI — never presented as real users.
  Impersonation reports go to the review queue like every other report.

## 14. Pre-push security audit gate (2026-10-16) — PASSED

Run before every push. Nothing ships until all checks pass.

- [x] **Auth**: Firebase ID token verified on every endpoint via `guard()`;
      `/api/health` is the only unauthenticated route (by design);
      `/media/*` uses HMAC-signed URLs; `/api/sync/ws` verifies the token
      from the query param; admin routes use `ADMIN_REVIEW_KEY`.
- [x] **Rate limiting**: per-IP + per-user via the RateLimit Durable Object
      on auth, signup, payments, uploads, messaging, and admin routes.
- [x] **Input validation**: strict schemas (`vStr`, `vInt`, `vEnum`, …) with
      max lengths on all inputs; file type + size limits on uploads.
- [x] **SQL injection**: all D1 queries use `?` placeholders. Two apparent
      interpolations verified safe: (1) static backtick query with `?`
      binding; (2) `r.${col}` where `col` is whitelisted by regex
      (`product`→`product_id`, `seller`→`seller_uid`).
- [x] **Secrets**: Workers secrets only. Repo grep clean (no keys/tokens in
      code). `.gitignore` covers keystores, `.env`, `google-services.json`
      (real), `wrangler` state.
- [x] **Webhooks**: Flutterwave `verif-hash` signature verified; idempotency
      via `tx_ref`. `FLUTTERWAVE_SECRET_HASH` is the remaining manual step
      (dashboard → Settings → Webhooks).
- [x] **Transport**: CORS locked to the app origin; security headers on
      Workers responses; R2 via short-lived signed URLs; private bucket.
- [x] **Logging**: zero secrets/tokens/PII/plaintext keys in logs; errors
      return generic codes (`httpError`), never stack traces.
- [x] **Admin**: `ADMIN_REVIEW_KEY` bearer; every admin action audit-logged.
- [x] **Abuse systems active**: VPN/proxy/Tor blacklist, device watch
      (3 suspensions → high-risk), strikes (3 → suspension), nudity scanner.
- [x] **Dependencies**: pinned in `package-lock.json` / `pubspec.lock`.
