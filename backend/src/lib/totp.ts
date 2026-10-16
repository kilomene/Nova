// TOTP (RFC 6238) for 2FA: HMAC-SHA1, 30s window, 6 digits.
// Secrets are stored encrypted (AES-GCM with a server-side key); the
// plaintext secret only exists transiently during setup/verification.

const B32 = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ234567';

export function randomBase32(len = 20): string {
  const b = new Uint8Array(len);
  crypto.getRandomValues(b);
  return [...b].map((x) => B32[x % 32]).join('');
}

function base32Decode(s: string): Uint8Array {
  const clean = s.toUpperCase().replace(/[^A-Z2-7]/g, '');
  const out: number[] = [];
  let bits = 0, val = 0;
  for (const c of clean) {
    val = (val << 5) | B32.indexOf(c);
    bits += 5;
    if (bits >= 8) { out.push((val >>> (bits - 8)) & 0xff); bits -= 8; }
  }
  return new Uint8Array(out);
}

async function hotp(secret: Uint8Array, counter: number): Promise<string> {
  const msg = new DataView(new ArrayBuffer(8));
  msg.setUint32(0, Math.floor(counter / 0x100000000));
  msg.setUint32(4, counter >>> 0);
  const key = await crypto.subtle.importKey('raw', secret.buffer as ArrayBuffer, { name: 'HMAC', hash: 'SHA-1' }, false, ['sign']);
  const mac = new Uint8Array(await crypto.subtle.sign('HMAC', key, msg.buffer));
  const off = mac[mac.length - 1] & 0x0f;
  const code = ((mac[off] & 0x7f) << 24) | (mac[off + 1] << 16) | (mac[off + 2] << 8) | mac[off + 3];
  return (code % 1000000).toString().padStart(6, '0');
}

/** Verify a 6-digit code with ±1 window (clock skew tolerance). */
export async function verifyTotp(secretB32: string, code: string, atMs = Date.now()): Promise<boolean> {
  if (!/^\d{6}$/.test(code)) return false;
  const secret = base32Decode(secretB32);
  const counter = Math.floor(atMs / 30000);
  for (const c of [counter - 1, counter, counter + 1]) {
    const expect = await hotp(secret, c);
    let diff = 0;
    for (let i = 0; i < 6; i++) diff |= expect.charCodeAt(i) ^ code.charCodeAt(i);
    if (diff === 0) return true;
  }
  return false;
}

/** otpauth:// URI for QR codes (Google Authenticator / iOS Passwords). */
export function otpauthUri(secretB32: string, account: string): string {
  return `otpauth://totp/Nova:${encodeURIComponent(account)}?secret=${secretB32}&issuer=Nova&digits=6&period=30`;
}

// ---- server-side encryption for stored TOTP secrets (AES-GCM) ----

async function encKey(serverSecret: string): Promise<CryptoKey> {
  const raw = await crypto.subtle.digest('SHA-256', new TextEncoder().encode(`totp-enc:${serverSecret}`));
  return crypto.subtle.importKey('raw', raw, { name: 'AES-GCM' }, false, ['encrypt', 'decrypt']);
}

export async function encryptSecret(plain: string, serverSecret: string): Promise<string> {
  const iv = new Uint8Array(12);
  crypto.getRandomValues(iv);
  const ct = await crypto.subtle.encrypt({ name: 'AES-GCM', iv }, await encKey(serverSecret), new TextEncoder().encode(plain));
  const b = new Uint8Array(12 + ct.byteLength);
  b.set(iv, 0); b.set(new Uint8Array(ct), 12);
  return btoa(String.fromCharCode(...b));
}

export async function decryptSecret(enc: string, serverSecret: string): Promise<string> {
  const b = Uint8Array.from(atob(enc), (c) => c.charCodeAt(0));
  const pt = await crypto.subtle.decrypt({ name: 'AES-GCM', iv: b.slice(0, 12) }, await encKey(serverSecret), b.slice(12));
  return new TextDecoder().decode(pt);
}
