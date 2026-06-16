// src/services/verifyOtpService.ts
import { randomUUID } from 'crypto';
import { env } from '@/config/env';
import { OtpCode } from '@/models/OtpCode';
import { User, type IUser } from '@/models/User';
import { RefreshToken } from '@/models/RefreshToken';
import { VerifyThrottle } from '@/models/VerifyThrottle';
import { verifyOtpHash, hashIdentifier } from '@/utils/otp';
import { signAccessToken, generateRefreshToken } from '@/utils/tokens';
import { track, AnalyticsEvent } from '@/utils/analytics';
import type { VerifyOtpInput } from '@/validation/authSchemas';

/** Outcome of a verify attempt. The route maps each variant to an HTTP response. */
export type VerifyOtpResult =
  | {
      ok: true;
      accessToken: string;
      accessTokenExpiresIn: number;
      refreshToken: string;
      refreshTokenExpiresIn: number;
      isNewUser: boolean;
    }
  | { ok: false; kind: 'rate_limited'; retryAfter: number }
  // `invalid` is the single enumeration-safe failure: no-record, expired,
  // wrong-code, and locked all collapse to it at the API boundary.
  | { ok: false; kind: 'invalid' }
  | { ok: false; kind: 'server_error' };

type FailReason = 'no_record' | 'expired' | 'wrong_code' | 'locked';

/**
 * Verifies a submitted OTP and, on success, establishes a session by issuing a
 * signed JWT access token plus a persisted (hash-only) refresh token.
 *
 * Resolution: verify-attempt rate limit → load record → expiry → lockout →
 * constant-time compare → resolve-or-create user → issue tokens → consume OTP.
 * Every failure path returns the *same* generic `invalid` so the client cannot
 * distinguish no-record / expired / wrong / locked; the distinction lives only
 * in analytics.
 */
export async function verifyOtp(input: VerifyOtpInput): Promise<VerifyOtpResult> {
  const { channel } = input;
  const identifier = input.channel === 'sms' ? input.phone : input.email;
  const identifierHash = hashIdentifier(identifier);
  const now = Date.now();

  // ── 1) Verify-attempt rate limit (before any record lookup) ────────────────
  const limit = await checkVerifyRateLimit(identifierHash, now);
  if (limit.limited) {
    track(AnalyticsEvent.AUTH_FAILED, {
      stage: 'verify_otp',
      reason: 'rate_limited',
      channel,
      identifier_hash: identifierHash,
    });
    return { ok: false, kind: 'rate_limited', retryAfter: limit.retryAfter };
  }

  // ── 2) Load the record ─────────────────────────────────────────────────────
  const record = await OtpCode.findOne({ identifier }).exec();
  if (!record) {
    return fail(channel, identifierHash, 'no_record');
  }

  // ── 3) Expiry ───────────────────────────────────────────────────────────────
  if (record.expiresAt.getTime() < now) {
    await OtpCode.deleteOne({ identifier }).exec();
    return fail(channel, identifierHash, 'expired');
  }

  // ── 4) Lockout (per-record attempt cap) ────────────────────────────────────
  if (record.attempts >= env.MAX_OTP_ATTEMPTS) {
    await OtpCode.deleteOne({ identifier }).exec();
    return fail(channel, identifierHash, 'locked');
  }

  // ── 5) Constant-time compare ───────────────────────────────────────────────
  if (!verifyOtpHash(input.code, record.otpHash)) {
    // Wrong guess: burn an attempt but keep the record until lockout/expiry.
    record.attempts += 1;
    await record.save();
    return fail(channel, identifierHash, 'wrong_code');
  }

  // ── 6) Resolve or create the user (first-time verify == signup) ────────────
  const { user, isNewUser } = await resolveUser(input.channel, identifier);

  // ── 7) Issue tokens. Signing may throw → 500 WITHOUT consuming the OTP, so
  //        the user can retry with the same still-valid code. ─────────────────
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

  const { token: refreshToken, tokenHash } = generateRefreshToken();
  await RefreshToken.create({
    tokenHash,
    userId: user._id,
    family: randomUUID(),
    rotatedFrom: null,
    expiresAt: new Date(now + env.REFRESH_TOKEN_TTL_SECONDS * 1000),
  });

  // ── 8) Consume the OTP (single-use) + analytics ────────────────────────────
  await OtpCode.deleteOne({ identifier }).exec();

  track(AnalyticsEvent.AUTH_OTP_VERIFIED, {
    channel,
    identifier_hash: identifierHash,
    is_new_user: isNewUser,
  });

  return {
    ok: true,
    accessToken,
    accessTokenExpiresIn: env.ACCESS_TOKEN_TTL_SECONDS,
    refreshToken,
    refreshTokenExpiresIn: env.REFRESH_TOKEN_TTL_SECONDS,
    isNewUser,
  };
}

/**
 * Emits the canonical failure analytics event and returns the generic `invalid`
 * result. Reconciliation: this replaces the former `auth_otp_verify_failed`
 * event with `auth_failed` (stage: 'verify_otp') so all auth failures live under
 * one event name. The local `FailReason` values are a subset of the shared
 * `AUTH_FAIL_REASONS` vocabulary.
 */
function fail(
  channel: VerifyOtpInput['channel'],
  identifierHash: string,
  reason: FailReason
): VerifyOtpResult {
  track(AnalyticsEvent.AUTH_FAILED, {
    stage: 'verify_otp',
    reason,
    channel,
    identifier_hash: identifierHash,
  });
  return { ok: false, kind: 'invalid' };
}

/**
 * DB-backed sliding-window cap on verify attempts per identifier. Independent of
 * the per-record `attempts` counter so it still throttles an attacker who keeps
 * requesting fresh codes. Counts the current attempt as it records it.
 */
async function checkVerifyRateLimit(
  identifierHash: string,
  now: number
): Promise<{ limited: true; retryAfter: number } | { limited: false }> {
  const existing = await VerifyThrottle.findOne({ identifierHash }).exec();

  let attemptCount = 1;
  let windowStartedAt = new Date(now);

  if (existing) {
    const windowAgeSeconds = (now - existing.windowStartedAt.getTime()) / 1000;
    if (windowAgeSeconds < env.VERIFY_WINDOW_SECONDS) {
      if (existing.attemptCount >= env.MAX_VERIFY_ATTEMPTS_PER_WINDOW) {
        return {
          limited: true,
          retryAfter: Math.ceil(env.VERIFY_WINDOW_SECONDS - windowAgeSeconds),
        };
      }
      attemptCount = existing.attemptCount + 1;
      windowStartedAt = existing.windowStartedAt;
    }
    // else: window elapsed → reset.
  }

  await VerifyThrottle.findOneAndUpdate(
    { identifierHash },
    {
      identifierHash,
      windowStartedAt,
      attemptCount,
      purgeAt: new Date(now + env.VERIFY_WINDOW_SECONDS * 1000),
    },
    { upsert: true, new: true, setDefaultsOnInsert: true }
  ).exec();

  return { limited: false };
}

/**
 * Looks up the user by the verified identifier, creating one on first login.
 * Either way the matching identifier is marked verified.
 */
async function resolveUser(
  channel: VerifyOtpInput['channel'],
  identifier: string
): Promise<{ user: IUser; isNewUser: boolean }> {
  const query = channel === 'sms' ? { phone: identifier } : { email: identifier };
  const existing = await User.findOne(query).exec();

  if (existing) {
    const verifiedField = channel === 'sms' ? 'phoneVerified' : 'emailVerified';
    if (!existing[verifiedField]) {
      existing[verifiedField] = true;
      await existing.save();
    }
    return { user: existing, isNewUser: false };
  }

  const user = await User.create({
    authProvider: 'custom',
    authUid: randomUUID(),
    ...(channel === 'sms'
      ? { phone: identifier, phoneVerified: true }
      : { email: identifier, emailVerified: true }),
  });

  return { user, isNewUser: true };
}
