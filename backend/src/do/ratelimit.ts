// RateLimit Durable Object: per-key sliding-window counters.
// One instance per rate-limit key (idFromName). Single-threaded per key,
// so increments are exact. State expires with the bucket.
export class RateLimit implements DurableObject {
  private state: DurableObjectState;

  constructor(state: DurableObjectState) {
    this.state = state;
  }

  async fetch(request: Request): Promise<Response> {
    if (request.method !== 'POST') return new Response('method not allowed', { status: 405 });
    const { key, limit, windowSec } = (await request.json()) as {
      key: string;
      limit: number;
      windowSec: number;
    };
    if (!key || !Number.isInteger(limit) || !Number.isInteger(windowSec)) {
      return new Response('bad request', { status: 400 });
    }
    const bucket = Math.floor(Date.now() / 1000 / windowSec);
    const sk = `${key}:${bucket}`;
    const cur = (((await this.state.storage.get<number>(sk)) ?? 0) as number) + 1;
    await this.state.storage.put(sk, cur);
    // Keep storage bounded: drop the previous bucket (no expiration option
    // in this workers-types version; deleting old buckets is exact anyway).
    await this.state.storage.delete(`${key}:${bucket - 1}`);
    const allowed = cur <= limit;
    return Response.json({ allowed, remaining: Math.max(0, limit - cur) });
  }
}

export async function rateCheck(
  ns: DurableObjectNamespace,
  key: string,
  limit: number,
  windowSec: number,
): Promise<void> {
  const id = ns.idFromName(`rl:${key}`);
  const res = await ns.get(id).fetch('https://ratelimit/check', {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify({ key, limit, windowSec }),
  });
  const data = (await res.json()) as { allowed: boolean };
  if (!data.allowed) {
    const e = new Error('rate_limited') as Error & { status: number };
    e.status = 429;
    throw e;
  }
}
