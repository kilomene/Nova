// Flutterwave v3 server-side integration. The secret key lives ONLY in the
// Workers secret FLUTTERWAVE_SECRET_KEY. The app never sees it and we never
// use Flutterwave "payment links" — the app drives its own checkout UI and
// calls /api/coins/buy (or /api/payments/charge), which calls Flutterwave
// directly and hands the hosted-checkout link back to the app.
import { httpError } from './auth';

const FW_BASE = 'https://api.flutterwave.com/v3';

export interface ChargeInput {
  amount: number;
  currency: string; // e.g. NGN, USD, GHS, KES
  email: string;
  tx_ref: string;
  name?: string;
  phone?: string;
  /** Where Flutterwave sends the payer after checkout. Defaults to a placeholder. */
  redirectUrl?: string;
}

interface FwChargeBody {
  status?: string;
  message?: string;
  data?: { link?: string; [k: string]: unknown };
  [k: string]: unknown;
}

export async function flutterwaveCharge(secretKey: string | undefined, input: ChargeInput): Promise<FwChargeBody> {
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
      redirect_url: input.redirectUrl || 'https://nova.example/payments/callback', // informational; app uses its own flow
      customer: { email: input.email, name: input.name, phonenumber: input.phone },
      customizations: { title: 'Nova', description: 'Nova wallet top-up' },
    }),
  });
  const data = (await res.json()) as FwChargeBody;
  // Flutterwave can answer HTTP 200 with status:"error" in the body, so the
  // HTTP status alone is not enough — require an explicit success + link.
  if (!res.ok || data.status !== 'success' || !data.data?.link) {
    console.error('flutterwave charge failed', JSON.stringify({ http: res.status, body: data }).slice(0, 500));
    throw httpError(502, 'checkout_unavailable');
  }
  return data;
}

/** Pull the hosted-checkout link out of a validated charge response. */
export function checkoutLink(data: FwChargeBody): string {
  const link = data.data?.link;
  if (typeof link !== 'string' || !link.startsWith('http')) throw httpError(502, 'checkout_unavailable');
  return link;
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
