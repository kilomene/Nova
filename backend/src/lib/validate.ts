// Input validation helpers. Every endpoint validates every input.
// Throws 400 httpError on violation.
import { httpError } from './auth';

export function vStr(v: unknown, name: string, min = 0, max = 500): string {
  if (typeof v !== 'string') throw httpError(400, `${name}_must_be_string`);
  const s = v.trim();
  if (s.length < min) throw httpError(400, `${name}_too_short`);
  if (s.length > max) throw httpError(400, `${name}_too_long`);
  return s;
}

export function vOptStr(v: unknown, name: string, max = 500): string {
  if (v === undefined || v === null) return '';
  return vStr(v, name, 0, max);
}

export function vEnum<T extends string>(v: unknown, allowed: readonly T[], name: string): T {
  if (typeof v !== 'string' || !(allowed as readonly string[]).includes(v)) {
    throw httpError(400, `${name}_invalid`);
  }
  return v as T;
}

export function vNum(v: unknown, name: string, min = -Infinity, max = Infinity): number {
  const n = typeof v === 'number' ? v : Number(v);
  if (!Number.isFinite(n)) throw httpError(400, `${name}_must_be_number`);
  if (n < min || n > max) throw httpError(400, `${name}_out_of_range`);
  return n;
}

export function vInt(v: unknown, name: string, min = -Infinity, max = Infinity): number {
  const n = vNum(v, name, min, max);
  if (!Number.isInteger(n)) throw httpError(400, `${name}_must_be_integer`);
  return n;
}

export function vStrList(v: unknown, name: string, maxItems = 20, maxLen = 40): string[] {
  if (v === undefined || v === null) return [];
  if (!Array.isArray(v)) throw httpError(400, `${name}_must_be_array`);
  if (v.length > maxItems) throw httpError(400, `${name}_too_many`);
  return v.map((e) => vStr(e, `${name}_item`, 0, maxLen));
}

export function vHandle(v: unknown): string {
  const s = vStr(v, 'handle', 3, 24).toLowerCase();
  if (!/^[a-z0-9_]+$/.test(s)) throw httpError(400, 'handle_invalid_chars');
  return s;
}

export const ASSETS = ['BTC', 'ETH', 'USDT', 'USDC'] as const;
export const FIATS = ['USD', 'NGN', 'GHS', 'KES', 'EUR', 'GBP'] as const;
