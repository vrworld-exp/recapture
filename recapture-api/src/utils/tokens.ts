// src/utils/tokens.ts
//
// Session-token helpers for the verify-otp flow. The access token reuses the
// existing `jsonwebtoken` setup and `JWT_SECRET` (the same key `requireAuth`
// verifies against); the refresh token is an opaque CSPRNG string stored only as
// a hash.
import { createHmac, randomBytes } from 'crypto';
import jwt from 'jsonwebtoken';
import { env } from '@/config/env';

const REFRESH_TOKEN_BYTES = 32; // 256 bits of entropy

/** Claims embedded in the access JWT. `sub` is the canonical subject; `userId`/
 *  `authUid` mirror the shape `requireAuth` already reads. */
export interface AccessTokenClaims {
  sub: string;
  userId: string;
  authUid: string;
}

/**
 * Signs a short-lived access JWT. `iat`/`exp` are added by `jsonwebtoken` from
 * `ACCESS_TOKEN_TTL_SECONDS`. May throw — callers MUST treat a throw as a 500
 * and avoid consuming the OTP so the user can retry.
 */
export function signAccessToken(claims: AccessTokenClaims): string {
  if (env.JWT_SIMULATE_SIGN_FAILURE) {
    throw new Error('Simulated token-signing failure');
  }
  return jwt.sign(claims, env.JWT_SECRET, {
    expiresIn: env.ACCESS_TOKEN_TTL_SECONDS,
  });
}

/** HMAC of a refresh token for at-rest storage. The raw token is never stored. */
export function hashRefreshToken(token: string): string {
  return createHmac('sha256', env.JWT_SECRET).update(token).digest('hex');
}

/**
 * Mints an opaque refresh token. Returns the plaintext (handed to the client
 * once) alongside its hash (the only form persisted).
 */
export function generateRefreshToken(): { token: string; tokenHash: string } {
  const token = randomBytes(REFRESH_TOKEN_BYTES).toString('hex');
  return { token, tokenHash: hashRefreshToken(token) };
}
