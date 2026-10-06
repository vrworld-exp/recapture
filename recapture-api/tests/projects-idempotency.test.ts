// tests/projects-idempotency.test.ts
//
// POST /projects `Idempotency-Key` (offline capture, Stage D1) — the POST /jobs
// mechanism applied to projects. The client's offline outbox flushes an
// offline-created project with a key derived from its temp id, so a retry after
// a lost response (or a create re-made after a logout) replays the ONE project
// instead of creating a second.
import { describe, it, expect, beforeAll, afterAll, afterEach } from 'vitest';
import request from 'supertest';
import mongoose, { Types } from 'mongoose';
import jwt from 'jsonwebtoken';
import { MongoMemoryServer } from 'mongodb-memory-server';

import { createApp } from '@/app';
import { env } from '@/config/env';
import { Project } from '@/models/Project';
import { User } from '@/models/User';

const app = createApp();
let mongod: MongoMemoryServer;

type Auth = { Authorization: string };

async function makeUser(): Promise<{ id: string; auth: Auth }> {
  const user = await User.create({
    authProvider: 'custom',
    authUid: `test|${new Types.ObjectId().toHexString()}`,
  });
  const id = user.id as string;
  const token = jwt.sign({ userId: id, authUid: user.authUid }, env.JWT_SECRET, {
    expiresIn: '15m',
  });
  return { id, auth: { Authorization: `Bearer ${token}` } };
}

const body = { name: 'Brass lamp', size: 'medium', mode: 'guided' };
const KEY = 'project-pending_1727600000000000';

beforeAll(async () => {
  mongod = await MongoMemoryServer.create();
  await mongoose.connect(mongod.getUri());
  // The unique partial index is the race authority — build it, or a concurrent
  // duplicate would be inserted happily and the race test would prove nothing.
  await Project.syncIndexes();
});

afterAll(async () => {
  await mongoose.disconnect();
  await mongod.stop();
});

afterEach(async () => {
  await Project.deleteMany({});
  await User.deleteMany({});
});

describe('POST /projects Idempotency-Key', () => {
  it('same key + same user → 200 replay of the SAME project', async () => {
    const { auth } = await makeUser();
    const first = await request(app)
      .post('/projects')
      .set(auth)
      .set('Idempotency-Key', KEY)
      .send(body);
    expect(first.status).toBe(201);

    const again = await request(app)
      .post('/projects')
      .set(auth)
      .set('Idempotency-Key', KEY)
      .send(body);
    expect(again.status).toBe(200);
    expect(again.body.status).toBe('success');
    expect(again.body.idempotentReplay).toBe(true);
    expect(again.body.project.id).toBe(first.body.project.id);
    expect(await Project.countDocuments({})).toBe(1);
  });

  it('same key with a DIFFERENT body → 409 IDEMPOTENCY_CONFLICT', async () => {
    const { auth } = await makeUser();
    await request(app).post('/projects').set(auth).set('Idempotency-Key', KEY).send(body);

    const res = await request(app)
      .post('/projects')
      .set(auth)
      .set('Idempotency-Key', KEY)
      .send({ ...body, name: 'Something else' });
    expect(res.status).toBe(409);
    expect(res.body).toMatchObject({ status: 'error', code: 'IDEMPOTENCY_CONFLICT' });
    expect(await Project.countDocuments({})).toBe(1);
  });

  it('same key from a DIFFERENT user → a new project (keys are per user)', async () => {
    const a = await makeUser();
    const b = await makeUser();
    const ra = await request(app).post('/projects').set(a.auth).set('Idempotency-Key', KEY).send(body);
    const rb = await request(app).post('/projects').set(b.auth).set('Idempotency-Key', KEY).send(body);
    expect(ra.status).toBe(201);
    expect(rb.status).toBe(201);
    expect(rb.body.project.id).not.toBe(ra.body.project.id);
    expect(await Project.countDocuments({})).toBe(2);
  });

  it('no key → unchanged behaviour (every call creates)', async () => {
    const { auth } = await makeUser();
    const r1 = await request(app).post('/projects').set(auth).send(body);
    const r2 = await request(app).post('/projects').set(auth).send(body);
    expect(r1.status).toBe(201);
    expect(r2.status).toBe(201);
    expect(r1.body.idempotentReplay).toBeUndefined();
    expect(r2.body.project.id).not.toBe(r1.body.project.id);
  });

  it('concurrent duplicates resolve to ONE project', async () => {
    const { auth } = await makeUser();
    const results = await Promise.all(
      [0, 1, 2].map(() =>
        request(app).post('/projects').set(auth).set('Idempotency-Key', KEY).send(body)
      )
    );
    const ids = new Set(results.map((r) => r.body.project.id));
    expect(ids.size).toBe(1);
    expect(await Project.countDocuments({})).toBe(1);
  });

  it('a malformed key is a 400, not a silently ignored guard', async () => {
    const { auth } = await makeUser();
    const res = await request(app)
      .post('/projects')
      .set(auth)
      .set('Idempotency-Key', 'x'.repeat(129))
      .send(body);
    expect(res.status).toBe(400);
    expect(res.body.code).toBe('INVALID_REQUEST');
  });

  it('the key is never returned in the project DTO', async () => {
    const { auth } = await makeUser();
    const res = await request(app).post('/projects').set(auth).set('Idempotency-Key', KEY).send(body);
    expect(JSON.stringify(res.body)).not.toContain(KEY);
  });
});
