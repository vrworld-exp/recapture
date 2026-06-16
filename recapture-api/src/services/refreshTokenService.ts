// src/services/refreshTokenService.ts
import { env } from '@/config/env';
import { User } from '@/models/User';
import { RefreshToken } from '@/models/RefreshToken';
import { hashIdentifier } from '@/utils/otp';
import { signAccessToken, generateRefreshToken, hashRefreshToken } from '@/utils/tokens';
import { consumeRateWindow } from '@/utils/rateLimit';
import { track, AnalyticsEvent } from '@/utils/analytics';

/** Outcome of a refresh attempt. The route maps each variant to an HTTP response. */
export type RefreshResult =
  | {
      ok: true;
      accessToken: string;
      accessTokenExpiresIn: number;
      refreshToken: string;
      refreshTokenExpiresIn: number;
    }
  | { ok: false; kind: 'rate_limited'; retryAfter: number }
  // `invalid` is the single enumeration-safe failure: unknown, expired, reused,
  // revoked, lost-race, and dead-user all collapse to it at the API boundary.
  | { ok: false; kind: 'invalid' }
  | { ok: false; kind: 'server_error' };

/**
 * Exchanges a refresh token for a new access token + rotated refresh token,
 * implementing rotation with reuse detection.
 *
 * Resolution: rate limit → hash + lookup → reuse/revoked check (theft signal →
 * burn the whole family) → expiry → user validity → atomic conditional rotate →
 * issue successor. Every failure returns the same generic `invalid` so unknown /
 * expired / reused / revoked are indistinguishable at the boundary; distinctions
 * live only in analytics.
 *
 * @param rawToken  the presented plaintext refresh token
 * @param clientKey a stable, PII-free client signal (e.g. IP) for throttling
 */
export async function refreshSession(
  rawToken: string,
  clientKey: string
): Promise<RefreshResult> {
  const now = Date.now();

  // Canonical failure telemetry for this stage. Refresh has no phone/email
  // identifier, so channel/identifier_hash are intentionally omitted.
  const trackRefreshFailure = (reason: 'invalid_token' | 'rate_limited'): void =>
    track(AnalyticsEvent.AUTH_FAILED, { stage: 'refresh', reason });

  // ── 2) Throttle (before any lookup) ────────────────────────────────────────
  const limit = await consumeRateWindow(
    `refresh:${clientKey}`,
    env.MAX_REFRESH_PER_WINDOW,
    env.REFRESH_WINDOW_SECONDS,
    now
  );
  if (limit.limited) {
    trackRefreshFailure('rate_limited');
    return { ok: false, kind: 'rate_limited', retryAfter: limit.retryAfter };
  }

  // ── 3) Look up the record by hash ──────────────────────────────────────────
  const tokenHash = hashRefreshToken(rawToken);
  const record = await RefreshToken.findOne({ tokenHash }).exec();
  if (!record) {
    trackRefreshFailure('invalid_token');
    return { ok: false, kind: 'invalid' };
  }

  const familyId = record.family;
  const userIdHash = hashIdentifier(record.userId.toString());

  // ── 4) Reuse detection (theft signal) ──────────────────────────────────────
  // An already-rotated or already-revoked token presented again means the chain
  // leaked: burn the entire family so every descendant stops working.
  if (record.rotatedAt !== null || record.revokedAt !== null) {
    await revokeFamily(familyId, now);
    // Rich security signal + the canonical failure event.
    track(AnalyticsEvent.AUTH_REFRESH_REUSE_DETECTED, {
      family_id: familyId,
      user_id_hash: userIdHash,
    });
    trackRefreshFailure('invalid_token');
    return { ok: false, kind: 'invalid' };
  }

  // ── 5) Expiry ───────────────────────────────────────────────────────────────
  if (record.expiresAt.getTime() < now) {
    trackRefreshFailure('invalid_token');
    return { ok: false, kind: 'invalid' };
  }

  // ── 6) User validity ───────────────────────────────────────────────────────
  const user = await User.findById(record.userId).exec();
  if (!user) {
    await revokeFamily(familyId, now);
    trackRefreshFailure('invalid_token');
    return { ok: false, kind: 'invalid' };
  }

  // ── 7) Rotate atomically ───────────────────────────────────────────────────
  // Sign first so a signing failure changes no state (→ 500, token still valid).
  let accessToken: string;
  try {
    accessToken = signAccessToken({
      sub: user.id as string,
      userId: user.id as string,
      authUid: user.authUid,
    });
  } catch {
    return { ok: false, kind: 'server_error' };
  }

  // Conditional update: only the request that flips rotatedAt from null wins.
  // Concurrent refreshes with the same token race here — exactly one matches.
  const claimed = await RefreshToken.findOneAndUpdate(
    { _id: record._id, rotatedAt: null, revokedAt: null },
    { rotatedAt: new Date(now) },
    { new: true }
  ).exec();

  if (!claimed) {
    // Lost the race to a concurrent refresh (or it was rotated/revoked in the
    // meantime). Benign — do NOT revoke the family; just reject this loser.
    return { ok: false, kind: 'invalid' };
  }

  // Sliding expiry: the successor gets a fresh full TTL from now.
  const { token: newRefreshToken, tokenHash: newTokenHash } = generateRefreshToken();
  await RefreshToken.create({
    tokenHash: newTokenHash,
    userId: record.userId,
    family: familyId,
    rotatedFrom: record.id as string,
    expiresAt: new Date(now + env.REFRESH_TOKEN_TTL_SECONDS * 1000),
  });

  // ── 8) Analytics + respond ─────────────────────────────────────────────────
  track(AnalyticsEvent.AUTH_TOKEN_REFRESHED, {
    family_id: familyId,
    user_id_hash: userIdHash,
  });

  return {
    ok: true,
    accessToken,
    accessTokenExpiresIn: env.ACCESS_TOKEN_TTL_SECONDS,
    refreshToken: newRefreshToken,
    refreshTokenExpiresIn: env.REFRESH_TOKEN_TTL_SECONDS,
  };
}

/** Revokes every still-live token in a family (idempotent). */
async function revokeFamily(family: string, now: number): Promise<void> {
  await RefreshToken.updateMany(
    { family, revokedAt: null },
    { revokedAt: new Date(now) }
  ).exec();
}
