// tests/auth-dev-code-prod.test.ts
//
// Production counterpart of auth-dev-code.test.ts: with NODE_ENV=production
// the send-otp response must NOT carry `devCode` — the plaintext OTP never
// leaves the dispatch boundary in prod. env is validated + frozen at import
// (@/config/env), so this file mocks the module rather than mutating
// process.env; the mock keeps every other var from the real loader.
import { describe, it, expect, beforeAll, afterAll, vi } from 'vitest';
import request from 'supertest';
import mongoose from 'mongoose';
import { MongoMemoryServer } from 'mongodb-memory-server';

vi.mock('@/config/env', async (importOriginal) => {
  const actual = await importOriginal<typeof import('@/config/env')>();
  return { env: { ...actual.env, NODE_ENV: 'production' as const } };
});

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

describe('POST /auth/send-otp devCode gate (production)', () => {
  it('the response does NOT carry devCode', async () => {
    const send = await request(app)
      .post('/auth/send-otp')
      .send({ channel: 'sms', phone: '+15550002222' });

    expect(send.status).toBe(200);
    expect(send.body.status).toBe('success');
    expect(send.body).not.toHaveProperty('devCode');
  });
});
