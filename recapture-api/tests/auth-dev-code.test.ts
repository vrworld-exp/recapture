// tests/auth-dev-code.test.ts
//
// Non-production devCode echo on POST /auth/send-otp: the response carries the
// plaintext OTP (`devCode`) so dev tooling (the client's upload smoke probe)
// can complete the handshake against the stubbed SMS provider. Asserts the
// echoed code IS the dispatched code (verify succeeds with it) and that it
// never reaches the logs. The production-absence counterpart lives in
// auth-dev-code-prod.test.ts (env is frozen at import, so the prod variant
// needs its own module graph).
import { describe, it, expect, beforeAll, afterAll, afterEach, vi } from 'vitest';
import request from 'supertest';
import mongoose from 'mongoose';
import { MongoMemoryServer } from 'mongodb-memory-server';

import { createApp } from '@/app';

const app = createApp();
let mongod: MongoMemoryServer;

beforeAll(async () => {
  mongod = await MongoMemoryServer.create();
  await mongoose.connect(mongod.getUri());
});

afterAll(async () => {
  await mongoose.disconnect();
  await mongod.stop();
});

afterEach(async () => {
  const { collections } = mongoose.connection;
  await Promise.all(Object.values(collections).map((c) => c.deleteMany({})));
  vi.restoreAllMocks();
});

describe('POST /auth/send-otp devCode echo (non-production)', () => {
  it('carries devCode and the echoed code verifies successfully', async () => {
    const logSpy = vi.spyOn(console, 'log').mockImplementation(() => {});

    const send = await request(app)
      .post('/auth/send-otp')
      .send({ channel: 'sms', phone: '+15550001111' });
    expect(send.status).toBe(200);
    expect(send.body.status).toBe('success');
    expect(send.body.devCode).toMatch(/^\d{6}$/);

    // The echo IS the dispatched code — the full handshake closes with it.
    const verify = await request(app)
      .post('/auth/verify-otp')
      .send({ channel: 'sms', phone: '+15550001111', code: send.body.devCode });
    expect(verify.status).toBe(200);
    expect(verify.body.status).toBe('success');
    expect(typeof verify.body.accessToken).toBe('string');

    // The plaintext code never reaches any log line (PII/logging rules hold).
    for (const call of logSpy.mock.calls) {
      const line = call.map((a) => (typeof a === 'string' ? a : JSON.stringify(a))).join(' ');
      expect(line).not.toContain(send.body.devCode);
    }
  });
});
