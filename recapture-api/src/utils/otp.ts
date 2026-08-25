// src/utils/otp.ts
//
// Pure crypto helpers for the OTP flow. No DB, no Express. The codebase already
// signs secrets with HMAC (JWT via jsonwebtoken), so OTPs use the same family —
// an HMAC-SHA256 keyed by a server-side secret — rather than pulling in bcrypt.
import { createHmac, randomInt, timingSafeEqual } from 'crypto';
import { env } from '@/config/env';

const OTP_DIGITS = 6;

/** The HMAC key. Dedicated secret if provided, else the JWT secret. */
function hashSecret(): string {
  return env.OTP_HASH_SECRET ?? env.JWT_SECRET;
}

/**
 * A cryptographically-random 6-digit numeric code, zero-padded. Uses
 * `crypto.randomInt` (CSPRNG) — never `Math.random()`.
 */
export function generateNumericOtp(): string {
  const upperExclusive = 10 ** OTP_DIGITS; // 1_000_000
  return randomInt(0, upperExclusive).toString().padStart(OTP_DIGITS, '0');
}

/** Deterministic, non-reversible hash of the OTP for at-rest storage. */
export function hashOtp(code: string): string {
  return createHmac('sha256', hashSecret()).update(code).digest('hex');
}

/**
 * Constant-time check of a submitted code against a stored OTP hash. Re-hashes
 * the submission and compares digests with `timingSafeEqual` — never a plain
 * `===`, which would leak match progress through its early-exit timing.
 */
export function verifyOtpHash(code: string, storedHash: string): boolean {
  const candidate = Buffer.from(hashOtp(code), 'hex');
  let stored: Buffer;
  try {
    stored = Buffer.from(storedHash, 'hex');
  } catch {
    return false;
  }
  // Unequal lengths can't be fed to timingSafeEqual; a length mismatch is also
  // an unambiguous non-match.
  if (candidate.length !== stored.length) {
    return false;
  }
  return timingSafeEqual(candidate, stored);
}

/**
 * Stable pseudonymous id for an identifier, safe to put in analytics/logs.
 * Never reveals the raw phone/email. Truncated — collision risk is irrelevant
 * for analytics grouping.
 */
export function hashIdentifier(identifier: string): string {
  return createHmac('sha256', hashSecret()).update(identifier).digest('hex').slice(0, 32);
}
