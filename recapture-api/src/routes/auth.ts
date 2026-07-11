// src/routes/auth.ts
import { Router } from 'express';
import { asyncHandler } from '@/utils/asyncHandler';
import { validateBody } from '@/middleware/validate';
import {
  sendOtpSchema,
  verifyOtpSchema,
  refreshSchema,
  type SendOtpInput,
  type VerifyOtpInput,
} from '@/validation/authSchemas';
import { sendOtp } from '@/services/otpService';
import { verifyOtp } from '@/services/verifyOtpService';
import { refreshSession } from '@/services/refreshTokenService';

const router = Router();

/**
 * POST /auth/send-otp — generate and dispatch an OTP via SMS or email.
 *
 * Verification is a separate endpoint and is intentionally not handled here.
 * The success body is identical regardless of whether the identifier maps to a
 * real account (no account enumeration).
 */
router.post(
  '/send-otp',
  validateBody(sendOtpSchema),
  asyncHandler(async (req, res) => {
    const result = await sendOtp(req.body as SendOtpInput);

    if (result.ok) {
      res.status(200).json({
        status: 'success',
        message: 'If the account exists, an OTP has been sent.',
        expiresInSeconds: result.expiresInSeconds,
        // Present only when the service's non-production gate exposed it
        // (dev tooling handshake — the providers are stubs).
        ...(result.devCode !== undefined ? { devCode: result.devCode } : {}),
      });
      return;
    }

    if (result.kind === 'rate_limited') {
      res.status(429).json({
        status: 'error',
        code: 'RATE_LIMITED',
        retryAfter: result.retryAfter,
      });
      return;
    }

    res.status(502).json({
      status: 'error',
      code: 'DISPATCH_FAILED',
      message: 'Could not send OTP. Please try again.',
    });
  })
);

/**
 * POST /auth/verify-otp — validate a submitted OTP and, on success, issue a JWT
 * access token + a rotating refresh token.
 *
 * Enumeration-safe: no-record, expired, wrong-code, and locked all return the
 * SAME generic 401 body — the distinction lives only in analytics.
 */
router.post(
  '/verify-otp',
  validateBody(verifyOtpSchema),
  asyncHandler(async (req, res) => {
    const result = await verifyOtp(req.body as VerifyOtpInput);

    if (result.ok) {
      res.status(200).json({
        status: 'success',
        accessToken: result.accessToken,
        accessTokenExpiresIn: result.accessTokenExpiresIn,
        refreshToken: result.refreshToken,
        refreshTokenExpiresIn: result.refreshTokenExpiresIn,
        isNewUser: result.isNewUser,
      });
      return;
    }

    if (result.kind === 'rate_limited') {
      res.status(429).json({
        status: 'error',
        code: 'RATE_LIMITED',
        retryAfter: result.retryAfter,
      });
      return;
    }

    if (result.kind === 'server_error') {
      res.status(500).json({
        status: 'error',
        code: 'INTERNAL_ERROR',
        message: 'Could not complete verification. Please try again.',
      });
      return;
    }

    // Generic invalid/expired/locked — identical for every cause (no enumeration).
    res.status(401).json({
      status: 'error',
      code: 'INVALID_OTP',
      message: 'The code is invalid or has expired.',
    });
  })
);

/**
 * POST /auth/refresh — exchange a refresh token for a new access token + a
 * rotated refresh token (rotation with reuse detection).
 *
 * Enumeration-safe: missing/unknown/expired/reused/revoked tokens all return the
 * SAME generic 401. A missing token is intentionally a 401 (not a 400 schema
 * error) so the failure surface stays uniform.
 */
router.post(
  '/refresh',
  asyncHandler(async (req, res) => {
    const parsed = refreshSchema.safeParse(req.body);
    if (!parsed.success) {
      res.status(401).json(invalidRefreshBody());
      return;
    }

    const clientKey = req.ip ?? 'unknown';
    const result = await refreshSession(parsed.data.refreshToken, clientKey);

    if (result.ok) {
      res.status(200).json({
        status: 'success',
        accessToken: result.accessToken,
        accessTokenExpiresIn: result.accessTokenExpiresIn,
        refreshToken: result.refreshToken,
        refreshTokenExpiresIn: result.refreshTokenExpiresIn,
      });
      return;
    }

    if (result.kind === 'rate_limited') {
      res.status(429).json({
        status: 'error',
        code: 'RATE_LIMITED',
        retryAfter: result.retryAfter,
      });
      return;
    }

    if (result.kind === 'server_error') {
      res.status(500).json({
        status: 'error',
        code: 'INTERNAL_ERROR',
        message: 'Could not refresh the session. Please try again.',
      });
      return;
    }

    res.status(401).json(invalidRefreshBody());
  })
);

/** The single generic refresh-failure body, shared so every cause is identical. */
function invalidRefreshBody() {
  return {
    status: 'error',
    code: 'INVALID_REFRESH_TOKEN',
    message: 'Session expired. Please sign in again.',
  };
}

export default router;
