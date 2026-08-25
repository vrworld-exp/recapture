// tests/auth-happy-path.test.ts
//
// End-to-end happy path for the OTP auth flow, fully hermetic:
//   - ephemeral in-memory MongoDB (mongodb-memory-server), wiped per test
//   - SMS/email providers mocked so no real message is sent and the dispatched
//     6-digit code can be captured at the dispatch boundary (black-box: exercises
//     real generation + hashing; the API never returns the code)
//   - analytics asserted by spying the console sink (no real destination call)
//
// Chain: send-otp → capture OTP → verify-otp → GET /projects (access token)
//        → refresh → GET /projects (rotated token), plus the documented side
//        effects (OTP consumed, refresh rotated, old token dead, analytics fired,
//        no PII in logs).
import { describe, it, expect, beforeAll, afterAll, afterEach, vi } from 'vitest';
import request from 'supertest';
import mongoose from 'mongoose';
import jwt from 'jsonwebtoken';
import { MongoMemoryServer } from 'mongodb-memory-server';

// Capture store must be hoisted so the (hoisted) vi.mock factories can close over
// it. The mocks replace the provider seam and record the plaintext code.
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

// Imported after the mocks (vi.mock is hoisted above all imports regardless).
import { createApp } from '@/app';
import { env } from '@/config/env';
import { OtpCode } from '@/models/OtpCode';

const app = createApp();
let mongod: MongoMemoryServer;

// ── Console capture (analytics spy + "no PII in logs" assertion) ─────────────
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

interface AccessClaims {
  sub: string;
  userId: string;
  authUid: string;
  iat: number;
  exp: number;
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
  stopLogCapture(); // restore even if a test threw mid-capture
  // Wipe every collection so each run starts clean and tests are order-independent.
  const { collections } = mongoose.connection;
  await Promise.all(Object.values(collections).map((c) => c.deleteMany({})));
  captured.sms.length = 0;
  captured.email.length = 0;
  vi.clearAllMocks();
});

// Parameterized over both channels; each case drives the entire chain.
const cases = [
  {
    channel: 'sms' as const,
    field: 'phone' as const,
    identifier: '+15551234567',
    store: (): { to: string; code: string }[] => captured.sms,
  },
  {
    channel: 'email' as const,
    field: 'email' as const,
    identifier: 'newuser@example.com',
    store: (): { to: string; code: string }[] => captured.email,
  },
];

describe('auth happy path (OTP flow E2E)', () => {
  it.each(cases)('send → verify → protected → refresh → protected ($channel)', async (c) => {
    startLogCapture();

    // 1) send-otp → generic success, no real message sent.
    const send = await request(app)
      .post('/auth/send-otp')
      .send({ channel: c.channel, [c.field]: c.identifier });
    expect(send.status).toBe(200);
    expect(send.body.status).toBe('success');

    // 2) capture the dispatched OTP from the provider mock.
    const store = c.store();
    expect(store).toHaveLength(1);
    expect(store[0].to).toBe(c.identifier);
    const code = store[0].code;
    expect(code).toMatch(/^\d{6}$/);
    // The other channel's provider was never touched.
    const otherStore = c.channel === 'sms' ? captured.email : captured.sms;
    expect(otherStore).toHaveLength(0);

    // 3) verify-otp → session issued, new identifier creates the user.
    const verify = await request(app)
      .post('/auth/verify-otp')
      .send({ channel: c.channel, [c.field]: c.identifier, code });
    expect(verify.status).toBe(200);
    expect(verify.body).toMatchObject({ status: 'success', isNewUser: true });
    const accessToken: string = verify.body.accessToken;
    const refreshToken: string = verify.body.refreshToken;
    expect(typeof accessToken).toBe('string');
    expect(typeof refreshToken).toBe('string');

    // 4) the access token is a valid JWT with the expected claims.
    const claims = jwt.verify(accessToken, env.JWT_SECRET) as AccessClaims;
    expect(claims.sub.length).toBeGreaterThan(0);
    expect(claims.userId).toBe(claims.sub);
    expect(typeof claims.authUid).toBe('string');
    expect(claims.exp).toBeGreaterThan(Math.floor(Date.now() / 1000));

    // 5) protected route authorizes with the access token (empty list for a new user).
    const list = await request(app).get('/projects').set('Authorization', `Bearer ${accessToken}`);
    expect(list.status).toBe(200);
    expect(list.body.status).toBe('success');
    expect(list.body.items).toEqual([]);

    // ...and rejects without a token.
    const noAuth = await request(app).get('/projects');
    expect(noAuth.status).toBe(401);

    // 6) refresh → brand-new access + refresh tokens (rotation).
    const r1 = await request(app).post('/auth/refresh').send({ refreshToken });
    expect(r1.status).toBe(200);
    const access2: string = r1.body.accessToken;
    const refresh2: string = r1.body.refreshToken;
    // The refresh token is CSPRNG-random, so rotation always yields a new value.
    expect(refresh2).not.toBe(refreshToken);
    // The access token is a freshly-signed JWT. It may be byte-identical to the
    // previous one when minted within the same wall-clock second (same claims +
    // same second-resolution `iat`) — expected JWT behavior — so assert it is a
    // valid token for the same subject rather than asserting inequality.
    const claims2 = jwt.verify(access2, env.JWT_SECRET) as AccessClaims;
    expect(claims2.sub).toBe(claims.sub);

    // the rotated access token also authorizes the protected route.
    const list2 = await request(app).get('/projects').set('Authorization', `Bearer ${access2}`);
    expect(list2.status).toBe(200);

    // the rotated refresh token is live (can rotate again).
    const r2 = await request(app).post('/auth/refresh').send({ refreshToken: refresh2 });
    expect(r2.status).toBe(200);

    // ── Side effects ──────────────────────────────────────────────────────────
    // OTP single-use: re-verifying the consumed code is rejected, and the record
    // is gone from the DB.
    const reverify = await request(app)
      .post('/auth/verify-otp')
      .send({ channel: c.channel, [c.field]: c.identifier, code });
    expect(reverify.status).toBe(401);
    expect(reverify.body.code).toBe('INVALID_OTP');
    expect(await OtpCode.findOne({ identifier: c.identifier })).toBeNull();

    // The original refresh token is dead after rotation (replay → 401). This is
    // reuse-detection: replaying a rotated token revokes the whole family, which
    // is the intended security behavior (so no live tokens remain afterward).
    const rOld = await request(app).post('/auth/refresh').send({ refreshToken });
    expect(rOld.status).toBe(401);

    stopLogCapture();

    // Analytics: auth_otp_sent on dispatch + auth_otp_verified on success, both
    // carrying a hashed identifier (never raw PII).
    const analytics = logLines.filter((l) => l.includes('[analytics]'));
    const sent = analytics.find((l) => l.includes('auth_otp_sent'));
    const verified = analytics.find((l) => l.includes('auth_otp_verified'));
    expect(sent).toBeDefined();
    expect(verified).toBeDefined();
    expect(sent).toContain('identifier_hash');
    expect(verified).toContain('identifier_hash');

    // No raw PII or secret appears in ANY captured log line.
    for (const line of logLines) {
      expect(line).not.toContain(c.identifier); // raw phone/email
      expect(line).not.toContain(code); // OTP plaintext
      expect(line).not.toContain(accessToken); // JWT
      expect(line).not.toContain(refreshToken); // refresh token
    }
  });
});
