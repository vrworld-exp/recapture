// tests/env-razorpay-keys.test.ts
//
// B8: the env loader refuses a half-configured Razorpay (keys must be
// present-or-absent together) and a key whose mode contradicts NODE_ENV — a
// live key in a dev shell (unless RAZORPAY_ALLOW_LIVE_KEY_OUTSIDE_PRODUCTION
// opts in), a test key in production. Exercised against the
// exported schema with hand-built objects, because the module itself parses
// the REAL process.env once and exits on failure.
import { describe, it, expect } from 'vitest';

import { ENV_SCHEMA } from '@/config/env';

const BASE = {
  MONGODB_URI: 'mongodb://127.0.0.1:27017/x',
  JWT_SECRET: 'test-jwt-secret-at-least-32-characters-long-000',
  AWS_REGION: 'us-east-1',
  AWS_ACCESS_KEY_ID: 'k',
  AWS_SECRET_ACCESS_KEY: 's',
  S3_BUCKET_RAW: 'raw',
  S3_BUCKET_ARTIFACTS: 'artifacts',
  CLOUDFRONT_BASE_URL: 'https://cdn.example.com',
};

function issuesOn(input: Record<string, unknown>): Record<string, string[]> {
  const parsed = ENV_SCHEMA.safeParse(input);
  if (parsed.success) return {};
  const out: Record<string, string[]> = {};
  for (const issue of parsed.error.issues) {
    const key = String(issue.path[0]);
    (out[key] ??= []).push(issue.message);
  }
  return out;
}

describe('RAZORPAY_* env rules', () => {
  it('boots with none of the three set', () => {
    expect(issuesOn({ ...BASE })).toEqual({});
  });

  it('boots with all three set and a test key outside production', () => {
    expect(
      issuesOn({
        ...BASE,
        NODE_ENV: 'development',
        RAZORPAY_KEY_ID: 'rzp_test_abc',
        RAZORPAY_KEY_SECRET: 'x',
        RAZORPAY_WEBHOOK_SECRET: 'y',
      })
    ).toEqual({});
  });

  it('refuses only the key id set, naming the missing variables', () => {
    const issues = issuesOn({ ...BASE, RAZORPAY_KEY_ID: 'rzp_test_abc' });
    expect(Object.keys(issues).sort()).toEqual(['RAZORPAY_KEY_SECRET', 'RAZORPAY_WEBHOOK_SECRET']);
    expect(issues.RAZORPAY_KEY_SECRET[0]).toMatch(/RAZORPAY_KEY_SECRET, RAZORPAY_WEBHOOK_SECRET/);
  });

  it('refuses a live key outside production (B8)', () => {
    const issues = issuesOn({
      ...BASE,
      NODE_ENV: 'development',
      RAZORPAY_KEY_ID: 'rzp_live_abc',
      RAZORPAY_KEY_SECRET: 'x',
      RAZORPAY_WEBHOOK_SECRET: 'y',
    });
    expect(issues.RAZORPAY_KEY_ID?.[0]).toMatch(/LIVE key but NODE_ENV=development/);
  });

  it('accepts a live key outside production when the override is set', () => {
    expect(
      issuesOn({
        ...BASE,
        NODE_ENV: 'development',
        RAZORPAY_KEY_ID: 'rzp_live_abc',
        RAZORPAY_KEY_SECRET: 'x',
        RAZORPAY_WEBHOOK_SECRET: 'y',
        RAZORPAY_ALLOW_LIVE_KEY_OUTSIDE_PRODUCTION: 'true',
      })
    ).toEqual({});
  });

  it('still refuses a test key in production despite the override', () => {
    const issues = issuesOn({
      ...BASE,
      NODE_ENV: 'production',
      RAZORPAY_KEY_ID: 'rzp_test_abc',
      RAZORPAY_KEY_SECRET: 'x',
      RAZORPAY_WEBHOOK_SECRET: 'y',
      RAZORPAY_ALLOW_LIVE_KEY_OUTSIDE_PRODUCTION: 'true',
    });
    expect(issues.RAZORPAY_KEY_ID?.[0]).toMatch(/must be a live key/);
  });

  it('refuses a test key in production (B8, the other way)', () => {
    const issues = issuesOn({
      ...BASE,
      NODE_ENV: 'production',
      RAZORPAY_KEY_ID: 'rzp_test_abc',
      RAZORPAY_KEY_SECRET: 'x',
      RAZORPAY_WEBHOOK_SECRET: 'y',
    });
    expect(issues.RAZORPAY_KEY_ID?.[0]).toMatch(/must be a live key/);
  });

  it('accepts a live key in production', () => {
    expect(
      issuesOn({
        ...BASE,
        NODE_ENV: 'production',
        RAZORPAY_KEY_ID: 'rzp_live_abc',
        RAZORPAY_KEY_SECRET: 'x',
        RAZORPAY_WEBHOOK_SECRET: 'y',
      })
    ).toEqual({});
  });

  it('defaults the reconcile interval and the refund meter', () => {
    const parsed = ENV_SCHEMA.safeParse({ ...BASE });
    expect(parsed.success).toBe(true);
    if (!parsed.success) return;
    expect(parsed.data.SUBSCRIPTION_ORDER_RECONCILE_INTERVAL_MS).toBe(300_000);
    expect(parsed.data.ADMIN_REFUND_MAX_PER_WINDOW).toBe(5);
    expect(parsed.data.ADMIN_REFUND_WINDOW_SECONDS).toBe(3600);
  });
});
