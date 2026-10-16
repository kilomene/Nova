// Flutterwave v3 server-side integration. The secret key lives ONLY in the
// Workers secret FLUTTERWAVE_SECRET_KEY. The app never sees it and we never
// use Flutterwave "payment links" — the app drives its own checkout UI and
// calls /api/payments/charge, which calls Flutterwave directly.
import { httpError } from './auth';

const FW_BASE = 'https://api.flutterwave.com/v3';

export interface ChargeInput {
  amount: number;
  currency: string; // e.g. NGN, USD, GHS, KES
  email: string;
  tx_ref: string;
  name?: string;
  phone?: string;
}

export async function flutterwaveCharge(secretKey: string | undefined, input: ChargeInput) {
  if (!secretKey) throw httpError(501, 'payments_not_configured: set FLUTTERWAVE_SECRET_KEY (see docs/SETUP.md)');
  const res = await fetch(`${FW_BASE}/payments`, {
    method: 'POST',
    headers: {
      Authorization: `Bearer ${secretKey}`,
      'Content-Type': 'application/json',
    },
    body: JSON.stringify({
      tx_ref: input.tx_ref,
      amount: input.amount,
      currency: input.currency,
      redirect_url: 'https://nova.example/payments/callback', // informational; app uses its own flow
      customer: { email: input.email, name: input.name, phonenumber: input.phone },
      customizations: { title: 'Nova', description: 'Nova wallet top-up' },
    }),
  });
  const data = (await res.json()) as Record<string, unknown>;
  if (!res.ok) throw httpError(502, `flutterwave_error: ${JSON.stringify(data).slice(0, 300)}`);
  return data;
}

export async function flutterwaveVerify(secretKey: string | undefined, txId: string | number) {
  if (!secretKey) throw httpError(501, 'payments_not_configured');
  const res = await fetch(`${FW_BASE}/transactions/${txId}/verify`, {
    headers: { Authorization: `Bearer ${secretKey}` },
  });
  const data = (await res.json()) as Record<string, unknown>;
  if (!res.ok) throw httpError(502, `flutterwave_verify_error`);
  return data;
}

// Webhook authenticity: Flutterwave sends `verif-hash`. We compare against
// the secret hash configured in the Flutterwave dashboard (stored as
// FLUTTERWAVE_SECRET_HASH). Constant-time-ish compare to avoid timing leaks.
export function verifyWebhookSignature(verifHash: string | null, secretHash: string | undefined): boolean {
  if (!verifHash || !secretHash) return false;
  if (verifHash.length !== secretHash.length) return false;
  let diff = 0;
  for (let i = 0; i < verifHash.length; i++) diff |= verifHash.charCodeAt(i) ^ secretHash.charCodeAt(i);
  return diff === 0;
}
