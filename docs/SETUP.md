# Nova Setup Guide

Everything the cloud side needs, step by step. The APK runs in **demo
mode** without any of this (local wallet, seeded feed); each section below
upgrades one subsystem to production.

## 1. Firebase (auth + push)

1. Create a project at https://console.firebase.google.com → "Nova".
2. Add an Android app, package name **`com.nova.app`**.
3. Download `google-services.json` and copy it to
   `app/android/app/google-services.json` (replacing the placeholder).
4. Enable **Authentication → Sign-in method → Email/Password**
   (and Phone if you want SMS login).
5. Enable **Cloud Messaging**. For server-side sends (backend `/api/notify`),
   create a service account (Project settings → Service accounts →
   Generate new private key) and store the JSON as a Workers secret:
   `wrangler secret put FIREBASE_SERVICE_ACCOUNT` (paste the whole JSON).
6. Rebuild the APK after adding the real `google-services.json`.

## 2. Cloudflare (API + database + storage + realtime)

```bash
cd backend
npm install
wrangler login
wrangler d1 create nova-db        # paste database_id into wrangler.toml
wrangler r2 bucket create nova-media
wrangler d1 execute nova-db --file=./schema.sql
# point FIREBASE_PROJECT_ID at your Firebase project id in wrangler.toml
wrangler secret put FLUTTERWAVE_SECRET_KEY
wrangler secret put FLUTTERWAVE_SECRET_HASH   # from Flutterwave dashboard → Settings → Webhooks
wrangler secret put FIREBASE_SERVICE_ACCOUNT  # JSON from step 1.5
wrangler secret put MEDIA_SIGNING_SECRET      # `openssl rand -hex 32`
wrangler secret put ADMIN_REVIEW_KEY          # `openssl rand -hex 32` — protects the manual KYC review endpoint
wrangler deploy
```

7. Copy the deployed Worker URL (e.g.
   `https://nova-api.<you>.workers.dev`) into `app/lib/config.dart`
   (`apiBaseUrl`), rebuild the APK.

## 3. Flutterwave (fiat payments)

1. https://flutterwave.com → get **live** secret key (test key for sandbox).
2. Dashboard → Settings → Webhooks: set webhook URL to
   `https://<your-worker>/api/payments/webhook`, copy the **secret hash**.
3. `wrangler secret put FLUTTERWAVE_SECRET_KEY` / `FLUTTERWAVE_SECRET_HASH`.
4. We never use Flutterwave payment links: the app calls
   `POST /api/payments/charge`, which calls Flutterwave v3 server-side.

## 4. KYC review (manual in v1)

KYC verification is a manual-review stub in v1: users upload ID front/back
+ selfie in the app (stored in R2), status goes to `pending`, and a
reviewer approves via:

```bash
curl -X POST https://<your-worker>/api/kyc/review \
  -H "x-admin-key: $ADMIN_REVIEW_KEY" \
  -H "content-type: application/json" \
  -d '{"uid":"<firebase-uid>","decision":"verified"}'
```

Only `verified` users can create a wallet (the keystore endpoint rejects
everyone else). Plug a real KYC provider (Smile Identity, Dojah,
Onfido…) here when ready — the status field and gating stay the same.

## 5. Build the APK

```bash
# one-time: Android SDK + Flutter SDK (see README for paths used here)
export PATH=~/workspace/.flutter-sdk/flutter/bin:$PATH
export ANDROID_HOME=~/workspace/android-sdk
cd app
flutter pub get
flutter analyze
flutter build apk --debug
# APK: build/app/outputs/flutter-apk/app-debug.apk
```

For a release build you sign yourself:
```bash
keytool -genkey -v -keystore ~/nova-release.jks -alias nova -keyalg RSA -keysize 2048 -validity 10000
flutter build apk --release \
  --target-platform android-arm64
```
(plus the standard `android/key.properties` wiring — documented in
`app/android/app/build.gradle` comments.)

## 6. Checklist before inviting real users

- [ ] Real `google-services.json` in place, Firebase Auth providers enabled
      (Email + Anonymous — anonymous keeps logged-out browsing authed)
- [ ] Worker deployed, D1 schema applied, `FIREBASE_PROJECT_ID` set
- [ ] All five Worker secrets set (Flutterwave key+hash, FCM service
      account, media signing secret, admin review key)
- [ ] `apiBaseUrl` in `app/lib/config.dart` points at the Worker
- [ ] Flutterwave live keys in Worker secrets (or test keys for sandbox);
      webhook URL set in the Flutterwave dashboard
- [ ] KYC review process defined (who holds `ADMIN_REVIEW_KEY`)
- [ ] TOTP 2FA: no extra setup (server-side, uses `MEDIA_SIGNING_SECRET`)
- [ ] Official @nova account: seeded by `schema.sql`; transfer its Firebase
      credentials to him + the agent
- [ ] Fraud pipeline: define who investigates and files (EFCC/FBI-IC3);
      KYC access is audit-logged (`kyc_access_log`)
- [ ] Read SECURITY.md §5 (testnet-first money movement) and decide your
      mainnet policy
- [ ] `flutter build apk --release` signed with your keystore
