// tests/auth-negative.test.ts
//
// NEGATIVE / ABUSE suite for the OTP auth lifecycle and the protected-route
// guard — the security counterpart to auth-happy-path.test.ts. Fully hermetic:
//   - ephemeral in-memory MongoDB (mongodb-memory-server), wiped per test
//   - SMS/email providers mocked so the dispatched 6-digit code is captured at
//     the boundary (real generation + hashing exercised; the API never returns it)
//   - analytics asserted by spying the console sink (no real destination)
//   - TIME is never slept on: expiry / sliding-window states are produced by
//     editing the persisted record directly (the deterministic equivalent of
//     "time passed"), so the suite is fast and order-independent.
//
// Covers: wrong code, expired code, no record, per-record lockout, the
// verify-attempt rate limit, the send cooldown + send-window cap, refresh of an
// unknown / missing / expired token, refresh REUSE detection (family revoke),
// the enumeration-safe uniformity of every failure body, and the JWT guard on a
// protected route (missing / malformed / wrong-secret token).
import { describe, it, expect, beforeAll, afterAll, afterEach, vi } from 'vitest';
import request from 'supertest';
import mongoose from 'mongoose';
import jwt from 'jsonwebtoken';
import { MongoMemoryServer } from 'mongodb-memory-server';

const captured = vi.hoisted(() => ({
  sms: [] as { to: string; code: string }[],
  email: [] as { to: string; code: string }[],
}));

vi.mock('@/providers/sms', () => ({
  sendSms: vi.fn(async (phone: string, code: string) => {
    captured.sms.push({ to: phone, code });
    return { providerMessageId: 'test-sms' };
  }),
}));
vi.mock('@/providers/email', () => ({
  sendEmail: vi.fn(async (email: string, code: string) => {
    captured.email.push({ to: email, code });
    return { providerMessageId: 'test-email' };
  }),
}));

import { createApp } from '@/app';
import { env } from '@/config/env';
import { OtpCode } from '@/models/OtpCode';
import { RefreshToken } from '@/models/RefreshToken';

const app = createApp();
let mongod: MongoMemoryServer;

// ── Console capture (analytics spy) ──────────────────────────────────────────
let logLines: string[] = [];
const realConsole = {
  log: console.log.bind(console),
  info: console.info.bind(console),
  warn: console.warn.bind(console),
  error: console.error.bind(console),
};
function startLogCapture(): void {
  logLines = [];
  const cap = (...args: unknown[]): void => {
    logLines.push(args.map((a) => (typeof a === 'string' ? a : JSON.stringify(a))).join(' '));
  };
  console.log = cap;
  console.info = cap;
  console.warn = cap;
  console.error = cap;
}
function stopLogCapture(): void {
  Object.assign(console, realConsole);
}

beforeAll(async () => {
  mongod = await MongoMemoryServer.create();
  await mongoose.connect(mongod.getUri());
});

afterAll(async () => {
  await mongoose.disconnect();
  await mongod.stop();
});

afterEach(async () => {
  stopLogCapture();
  const { collections } = mongoose.connection;
  await Promise.all(Object.values(collections).map((c) => c.deleteMany({})));
  captured.sms.length = 0;
  captured.email.length = 0;
  vi.clearAllMocks();
});

// ── Helpers ──────────────────────────────────────────────────────────────────

const sendOtp = (phone: string) =>
  request(app).post('/auth/send-otp').send({ channel: 'sms', phone });

const verifyOtp = (phone: string, code: string) =>
  request(app).post('/auth/verify-otp').send({ channel: 'sms', phone, code });

const refresh = (refreshToken: unknown) =>
  request(app).post('/auth/refresh').send(refreshToken === undefined ? {} : { refreshToken });

/** The plaintext code dispatched for [phone], captured at the provider mock. */
function codeFor(phone: string): string {
  const hit = captured.sms.find((s) => s.to === phone);
  if (!hit) throw new Error(`no OTP captured for ${phone}`);
  return hit.code;
}

/** Drive send→verify to a live session; returns the issued tokens. */
async function establishSession(
  phone: string
): Promise<{ accessToken: string; refreshToken: string }> {
  await sendOtp(phone);
  const verify = await verifyOtp(phone, codeFor(phone));
  expect(verify.status).toBe(200);
  return { accessToken: verify.body.accessToken, refreshToken: verify.body.refreshToken };
}

// The two canonical generic failure bodies (one per surface). Every cause must
// collapse to these — that is the enumeration-safety contract.
const INVALID_OTP_BODY = {
  status: 'error',
  code: 'INVALID_OTP',
  message: 'The code is invalid or has expired.',
};
const INVALID_REFRESH_BODY = {
  status: 'error',
  code: 'INVALID_REFRESH_TOKEN',
  message: 'Session expired. Please sign in again.',
};

// ── OTP verify: failure paths ─────────────────────────────────────────────────
describe('verify-otp — failure paths (all enumeration-safe 401s)', () => {
  it('no OTP record → generic 401', async () => {
    const res = await verifyOtp('+15550000001', '123456');
    expect(res.status).toBe(401);
    expect(res.body).toEqual(INVALID_OTP_BODY);
  });

  it('wrong code → 401, burns an attempt, leaves the (single-use) code unconsumed',
    async () => {
      const phone = '+15550000002';
      await sendOtp(phone);
      const correct = codeFor(phone);
      const wrong = correct === '000000' ? '111111' : '000000';

      const res = await verifyOtp(phone, wrong);
      expect(res.status).toBe(401);
      expect(res.body).toEqual(INVALID_OTP_BODY);

      // The record survives (still usable until lockout/expiry) with one attempt burned.
      const rec = await OtpCode.findOne({ identifier: phone }).exec();
      expect(rec).not.toBeNull();
      expect(rec!.attempts).toBe(1);

      // ...and the correct code still verifies afterwards (the wrong guess did not consume it).
      const ok = await verifyOtp(phone, correct);
      expect(ok.status).toBe(200);
    });

  it('expired code → generic 401 and the record is purged', async () => {
    const phone = '+15550000003';
    await sendOtp(phone);
    const correct = codeFor(phone);

    // "Time passed": push expiry into the past deterministically.
    await OtpCode.updateOne({ identifier: phone }, { expiresAt: new Date(Date.now() - 1000) }).exec();

    const res = await verifyOtp(phone, correct); // correct code, but expired
    expect(res.status).toBe(401);
    expect(res.body).toEqual(INVALID_OTP_BODY);
    expect(await OtpCode.findOne({ identifier: phone }).exec()).toBeNull();
  });

  it('lockout: after MAX_OTP_ATTEMPTS wrong guesses the correct code is rejected '
    + 'and the record is destroyed', async () => {
    const phone = '+15550000004';
    await sendOtp(phone);
    const correct = codeFor(phone);
    const wrong = correct === '000000' ? '111111' : '000000';

    for (let i = 1; i <= env.MAX_OTP_ATTEMPTS; i++) {
      const res = await verifyOtp(phone, wrong);
      expect(res.status).toBe(401);
      const rec = await OtpCode.findOne({ identifier: phone }).exec();
      expect(rec!.attempts).toBe(i); // each wrong guess increments
    }

    // Now at the cap: even the CORRECT code is refused, and the record is gone.
    const locked = await verifyOtp(phone, correct);
    expect(locked.status).toBe(401);
    expect(locked.body).toEqual(INVALID_OTP_BODY);
    expect(await OtpCode.findOne({ identifier: phone }).exec()).toBeNull();
  });

  it('no-record / wrong-code / expired / locked are BYTE-IDENTICAL at the boundary',
    async () => {
      // Each cause on its own identifier so their throttle/record state is independent.
      const noRecord = (await verifyOtp('+15550000010', '123456')).body;

      const wrongPhone = '+15550000011';
      await sendOtp(wrongPhone);
      const wrongBody = (await verifyOtp(wrongPhone,
        codeFor(wrongPhone) === '000000' ? '111111' : '000000')).body;

      const expPhone = '+15550000012';
      await sendOtp(expPhone);
      const expCode = codeFor(expPhone);
      await OtpCode.updateOne({ identifier: expPhone }, { expiresAt: new Date(Date.now() - 1000) }).exec();
      const expiredBody = (await verifyOtp(expPhone, expCode)).body;

      const lockPhone = '+15550000013';
      await sendOtp(lockPhone);
      const lockCode = codeFor(lockPhone);
      await OtpCode.updateOne({ identifier: lockPhone }, { attempts: env.MAX_OTP_ATTEMPTS }).exec();
      const lockedBody = (await verifyOtp(lockPhone, lockCode)).body;

      // Indistinguishable — the only place the cause is recorded is analytics.
      expect(noRecord).toEqual(INVALID_OTP_BODY);
      expect(wrongBody).toEqual(noRecord);
      expect(expiredBody).toEqual(noRecord);
      expect(lockedBody).toEqual(noRecord);
    });
});

// ── OTP send + verify: rate limiting / abuse ─────────────────────────────────
describe('send-otp / verify-otp — rate limiting', () => {
  it('resend within the cooldown → 429 RATE_LIMITED, and NO second message is sent',
    async () => {
      const phone = '+15550000020';
      const first = await sendOtp(phone);
      expect(first.status).toBe(200);

      const second = await sendOtp(phone); // immediate resend → inside cooldown
      expect(second.status).toBe(429);
      expect(second.body.code).toBe('RATE_LIMITED');
      expect(typeof second.body.retryAfter).toBe('number');
      expect(second.body.retryAfter).toBeGreaterThan(0);

      // The throttled resend never reached the provider.
      expect(captured.sms.filter((s) => s.to === phone)).toHaveLength(1);
    });

  it('send-window cap → 429 once MAX_SENDS_PER_WINDOW is reached in-window',
    async () => {
      const phone = '+15550000021';
      await sendOtp(phone);

      // Deterministic "window state": cooldown already elapsed, but the window
      // send-count is already at the cap and the window is still open.
      await OtpCode.updateOne(
        { identifier: phone },
        {
          sendCount: env.MAX_SENDS_PER_WINDOW,
          lastSentAt: new Date(Date.now() - (env.RESEND_COOLDOWN_SECONDS + 5) * 1000),
          windowStartedAt: new Date(),
        }
      ).exec();

      const capped = await sendOtp(phone);
      expect(capped.status).toBe(429);
      expect(capped.body.code).toBe('RATE_LIMITED');
    });

  it('verify-attempt rate limit: the (MAX+1)th attempt in-window → 429', async () => {
    const phone = '+15550000022'; // no OTP sent — the limiter runs before record lookup
    for (let i = 0; i < env.MAX_VERIFY_ATTEMPTS_PER_WINDOW; i++) {
      const res = await verifyOtp(phone, '123456');
      expect(res.status).toBe(401); // no record → generic 401, but the attempt is counted
    }
    const limited = await verifyOtp(phone, '123456');
    expect(limited.status).toBe(429);
    expect(limited.body.code).toBe('RATE_LIMITED');
    expect(limited.body.retryAfter).toBeGreaterThan(0);
  });
});

// ── Refresh: failure paths + reuse detection ─────────────────────────────────
describe('refresh — failure paths (all enumeration-safe 401s)', () => {
  it('unknown token → generic 401', async () => {
    const res = await refresh('a'.repeat(64));
    expect(res.status).toBe(401);
    expect(res.body).toEqual(INVALID_REFRESH_BODY);
  });

  it('missing token → 401 (a uniform surface, NOT a 400 schema error)', async () => {
    const res = await refresh(undefined); // empty body
    expect(res.status).toBe(401);
    expect(res.body).toEqual(INVALID_REFRESH_BODY);
  });

  it('expired token → generic 401', async () => {
    const { refreshToken } = await establishSession('+15550000030');
    await RefreshToken.updateMany({}, { expiresAt: new Date(Date.now() - 1000) }).exec();

    const res = await refresh(refreshToken);
    expect(res.status).toBe(401);
    expect(res.body).toEqual(INVALID_REFRESH_BODY);
  });

  it('REUSE detection: replaying a rotated token revokes the WHOLE family', async () => {
    const { refreshToken: tokenA } = await establishSession('+15550000031');

    // Legitimate rotation A → B.
    const rotate = await refresh(tokenA);
    expect(rotate.status).toBe(200);
    const tokenB: string = rotate.body.refreshToken;

    // Replaying the already-rotated A is the theft signal.
    startLogCapture();
    const replay = await refresh(tokenA);
    stopLogCapture();
    expect(replay.status).toBe(401);
    expect(replay.body).toEqual(INVALID_REFRESH_BODY);
    expect(logLines.some((l) => l.includes('auth_refresh_reuse_detected'))).toBe(true);

    // The family is burned: the otherwise-valid successor B is now dead too.
    const afterBurn = await refresh(tokenB);
    expect(afterBurn.status).toBe(401);
    expect(afterBurn.body).toEqual(INVALID_REFRESH_BODY);
  });

  it('unknown / missing / expired refresh failures are BYTE-IDENTICAL', async () => {
    const unknown = (await refresh('b'.repeat(64))).body;
    const missing = (await refresh(undefined)).body;

    const { refreshToken } = await establishSession('+15550000032');
    await RefreshToken.updateMany({}, { expiresAt: new Date(Date.now() - 1000) }).exec();
    const expired = (await refresh(refreshToken)).body;

    expect(unknown).toEqual(INVALID_REFRESH_BODY);
    expect(missing).toEqual(unknown);
    expect(expired).toEqual(unknown);
  });
});

// ── Protected-route JWT guard (covers the standardized requireAuth envelope) ──
describe('protected route — JWT guard', () => {
  const UNAUTH = { status: 'error', code: 'UNAUTHENTICATED' };

  it('no Authorization header → 401 standard envelope', async () => {
    const res = await request(app).get('/projects');
    expect(res.status).toBe(401);
    expect(res.body).toMatchObject(UNAUTH);
    expect(res.body.message).toBe('Authentication required.');
  });

  it('malformed (non-Bearer) header → 401', async () => {
    const res = await request(app).get('/projects').set('Authorization', 'Basic abc');
    expect(res.status).toBe(401);
    expect(res.body).toMatchObject(UNAUTH);
  });

  it('garbage bearer token → 401', async () => {
    const res = await request(app).get('/projects').set('Authorization', 'Bearer not.a.jwt');
    expect(res.status).toBe(401);
    expect(res.body).toMatchObject(UNAUTH);
    expect(res.body.message).toBe('Invalid or expired token.');
  });

  it('token signed with the WRONG secret → 401', async () => {
    const forged = jwt.sign(
      { userId: 'x', authUid: 'y' },
      'totally-different-secret-at-least-32-characters-xx'
    );
    const res = await request(app).get('/projects').set('Authorization', `Bearer ${forged}`);
    expect(res.status).toBe(401);
    expect(res.body).toMatchObject(UNAUTH);
  });
});

// ── Input validation (malformed bodies → 400, before any business logic) ─────
describe('input validation — malformed bodies → 400', () => {
  it('send-otp with an invalid channel → 400 INVALID_REQUEST', async () => {
    const res = await request(app).post('/auth/send-otp').send({ channel: 'carrier-pigeon', phone: '+15550000040' });
    expect(res.status).toBe(400);
    expect(res.body.code).toBe('INVALID_REQUEST');
  });

  it('send-otp missing the identifier → 400', async () => {
    const res = await request(app).post('/auth/send-otp').send({ channel: 'sms' });
    expect(res.status).toBe(400);
    expect(res.body.code).toBe('INVALID_REQUEST');
  });
});
