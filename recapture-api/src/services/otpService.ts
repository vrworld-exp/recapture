// src/services/otpService.ts
import { env } from '@/config/env';
import { OtpCode } from '@/models/OtpCode';
import { generateNumericOtp, hashOtp, hashIdentifier } from '@/utils/otp';
import { trackEvent } from '@/utils/analytics';
import { sendSms } from '@/providers/sms';
import { sendEmail } from '@/providers/email';
import type { SendOtpInput } from '@/validation/authSchemas';

/** Outcome of a send attempt. The route maps each variant to an HTTP response. */
export type SendOtpResult =
  | { ok: true; expiresInSeconds: number }
  | { ok: false; kind: 'rate_limited'; retryAfter: number }
  | { ok: false; kind: 'dispatch_failed' };

/** Snapshot of the rate-limit/OTP fields, used to roll back a failed dispatch. */
interface OtpSnapshot {
  channel: SendOtpInput['channel'];
  otpHash: string;
  expiresAt: Date;
  attempts: number;
  lastSentAt: Date;
  windowStartedAt: Date;
  sendCount: number;
  purgeAt: Date;
}

/**
 * Generates, persists (hashed), and dispatches a one-time passcode.
 *
 * Resolution: cooldown check → window-cap check → generate+hash → overwrite the
 * identifier's record → dispatch → analytics. A dispatch failure rolls the
 * record back to its prior state so a failed send never burns the cooldown.
 *
 * Account-enumeration safe: the caller returns an identical success body whether
 * or not the identifier maps to a real account — this function does not look the
 * account up.
 */
export async function sendOtp(input: SendOtpInput): Promise<SendOtpResult> {
  const { channel } = input;
  const identifier = input.channel === 'sms' ? input.phone : input.email;
  const identifierHash = hashIdentifier(identifier);
  const now = Date.now();

  const existing = await OtpCode.findOne({ identifier }).exec();

  // ── 1) Resend cooldown ─────────────────────────────────────────────────────
  if (existing) {
    const secondsSinceLast = (now - existing.lastSentAt.getTime()) / 1000;
    if (secondsSinceLast < env.RESEND_COOLDOWN_SECONDS) {
      trackEvent('auth_otp_sent', {
        channel,
        identifier_hash: identifierHash,
        success: false,
        rate_limited: true,
      });
      return {
        ok: false,
        kind: 'rate_limited',
        retryAfter: Math.ceil(env.RESEND_COOLDOWN_SECONDS - secondsSinceLast),
      };
    }
  }

  // ── 2) Sliding-window send cap ─────────────────────────────────────────────
  let sendCount = 1;
  let windowStartedAt = new Date(now);
  if (existing) {
    const windowAgeSeconds = (now - existing.windowStartedAt.getTime()) / 1000;
    if (windowAgeSeconds < env.RATE_WINDOW_SECONDS) {
      if (existing.sendCount >= env.MAX_SENDS_PER_WINDOW) {
        trackEvent('auth_otp_sent', {
          channel,
          identifier_hash: identifierHash,
          success: false,
          rate_limited: true,
        });
        return {
          ok: false,
          kind: 'rate_limited',
          retryAfter: Math.ceil(env.RATE_WINDOW_SECONDS - windowAgeSeconds),
        };
      }
      // Still inside the window — carry the window forward, bump the count.
      sendCount = existing.sendCount + 1;
      windowStartedAt = existing.windowStartedAt;
    }
    // else: window elapsed → reset (sendCount=1, windowStartedAt=now).
  }

  // ── 3) Generate + hash ─────────────────────────────────────────────────────
  const code = generateNumericOtp();
  const otpHash = hashOtp(code);
  const expiresAt = new Date(now + env.OTP_TTL_SECONDS * 1000);
  // Outlast both the OTP and the rate window so TTL cleanup never drops a live
  // window counter.
  const purgeAt = new Date(
    now + Math.max(env.OTP_TTL_SECONDS, env.RATE_WINDOW_SECONDS) * 1000
  );

  // Capture the prior state for rollback before we overwrite it.
  const snapshot: OtpSnapshot | null = existing
    ? {
        channel: existing.channel,
        otpHash: existing.otpHash,
        expiresAt: existing.expiresAt,
        attempts: existing.attempts,
        lastSentAt: existing.lastSentAt,
        windowStartedAt: existing.windowStartedAt,
        sendCount: existing.sendCount,
        purgeAt: existing.purgeAt,
      }
    : null;

  // ── 4) Persist (overwrite prior unexpired OTP → only the newest verifies) ──
  await OtpCode.findOneAndUpdate(
    { identifier },
    {
      identifier,
      channel,
      otpHash,
      expiresAt,
      attempts: 0,
      lastSentAt: new Date(now),
      windowStartedAt,
      sendCount,
      purgeAt,
    },
    { upsert: true, new: true, setDefaultsOnInsert: true }
  ).exec();

  // ── 5) Dispatch (plaintext leaves memory only here) ────────────────────────
  try {
    if (input.channel === 'sms') {
      await sendSms(input.phone, code);
    } else {
      await sendEmail(input.email, code);
    }
  } catch {
    // Roll back so a failed send does not consume the cooldown/window.
    if (snapshot) {
      await OtpCode.findOneAndUpdate({ identifier }, snapshot).exec();
    } else {
      await OtpCode.deleteOne({ identifier }).exec();
    }
    trackEvent('auth_otp_sent', {
      channel,
      identifier_hash: identifierHash,
      success: false,
      rate_limited: false,
    });
    return { ok: false, kind: 'dispatch_failed' };
  }

  // ── 6) Analytics + success ─────────────────────────────────────────────────
  trackEvent('auth_otp_sent', {
    channel,
    identifier_hash: identifierHash,
    success: true,
    rate_limited: false,
  });
  return { ok: true, expiresInSeconds: env.OTP_TTL_SECONDS };
}
