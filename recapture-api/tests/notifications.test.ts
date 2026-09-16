// tests/notifications.test.ts
//
// In-app notifications: the per-user feed, read receipts, the ADMIN send /
// retract surface, and the seeded welcome greeting.
//
// The load-bearing cases:
//   - the greeting reaches a user who existed BEFORE the seed and one created
//     AFTER it, unread for both, and seeding twice inserts once;
//   - a targeted notification is invisible to everyone but its recipients, and
//     marking it read from outside the audience is the SAME 404 as a bogus id;
//   - marking read is idempotent (first readAt wins) and the badge count
//     tracks it; retraction removes a row from every feed at once.
//
// Hermetic: in-memory Mongo, tokens minted with the app's JWT_SECRET. ENV is
// injected by vitest.config.ts before the module graph loads.
import { describe, it, expect, beforeAll, afterAll, afterEach } from 'vitest';
import request from 'supertest';
import mongoose, { Types } from 'mongoose';
import { MongoMemoryServer } from 'mongodb-memory-server';

import { createApp } from '@/app';
import { Notification } from '@/models/Notification';
import { NotificationReceipt } from '@/models/NotificationReceipt';
import {
  ensureWelcomeNotification,
  WELCOME_NOTIFICATION,
  WELCOME_NOTIFICATION_KEY,
} from '@/services/notificationsService';
import { makeUser, type TestUser } from './helpers/photoUpload';

const app = createApp();
let mongod: MongoMemoryServer;

beforeAll(async () => {
  mongod = await MongoMemoryServer.create();
  await mongoose.connect(mongod.getUri());
  // The partial unique index on `key` is what makes the seed idempotent under
  // a race; build it so the test exercises the real constraint.
  await Notification.syncIndexes();
  await NotificationReceipt.syncIndexes();
});

afterAll(async () => {
  await mongoose.disconnect();
  await mongod.stop();
});

afterEach(async () => {
  const { collections } = mongoose.connection;
  await Promise.all(Object.values(collections).map((c) => c.deleteMany({})));
});

/** A broadcast inserted straight through the model (no admin round trip). */
async function seedBroadcast(title: string, extra: Record<string, unknown> = {}) {
  return Notification.create({
    kind: 'INFO',
    title,
    message: `${title} body`,
    audienceType: 'ALL',
    audienceUserIds: [],
    deletedAt: null,
    ...extra,
  });
}

async function seedTargeted(title: string, userIds: string[]) {
  return Notification.create({
    kind: 'PAYMENT_DUE',
    title,
    message: `${title} body`,
    audienceType: 'USERS',
    audienceUserIds: userIds.map((id) => new Types.ObjectId(id)),
    deletedAt: null,
  });
}

const feed = (u: TestUser) => request(app).get('/notifications').set(u.auth);
const read = (u: TestUser, id: string) =>
  request(app).post(`/notifications/${id}/read`).set(u.auth);

describe('the welcome greeting', () => {
  it('reaches a user created BEFORE the seed and one created AFTER it, unread for both', async () => {
    const early = await makeUser();
    expect(await ensureWelcomeNotification()).toBe(true);
    const late = await makeUser();

    for (const user of [early, late]) {
      const res = await feed(user);
      expect(res.status).toBe(200);
      expect(res.body.status).toBe('success');
      expect(res.body.unreadCount).toBe(1);
      expect(res.body.notifications).toHaveLength(1);
      expect(res.body.notifications[0]).toMatchObject({
        kind: 'WELCOME',
        title: WELCOME_NOTIFICATION.title,
        message: WELCOME_NOTIFICATION.message,
        detail: WELCOME_NOTIFICATION.detail,
        action: null,
        isRead: false,
        readAt: null,
      });
      expect(typeof res.body.notifications[0].id).toBe('string');
      expect(typeof res.body.notifications[0].createdAt).toBe('string');
    }
  });

  it('seeds exactly once, however many times it is asked', async () => {
    expect(await ensureWelcomeNotification()).toBe(true);
    expect(await ensureWelcomeNotification()).toBe(false);
    expect(await ensureWelcomeNotification()).toBe(false);
    expect(await Notification.countDocuments({ key: WELCOME_NOTIFICATION_KEY })).toBe(1);
  });

  it('is unread per USER, not globally — one reading it does not read it for another', async () => {
    await ensureWelcomeNotification();
    const a = await makeUser();
    const b = await makeUser();
    const { body } = await feed(a);

    await read(a, body.notifications[0].id).expect(200);

    expect((await feed(a)).body.unreadCount).toBe(0);
    expect((await feed(b)).body.unreadCount).toBe(1);
  });
});

describe('GET /notifications — the feed', () => {
  it('requires auth', async () => {
    await request(app).get('/notifications').expect(401);
  });

  it('is empty (not an error) for a user with nothing to see', async () => {
    const u = await makeUser();
    const res = await feed(u);
    expect(res.status).toBe(200);
    expect(res.body).toEqual({ status: 'success', notifications: [], unreadCount: 0 });
  });

  it('shows broadcasts to everyone and targeted rows only to their recipients', async () => {
    const alice = await makeUser();
    const bob = await makeUser();
    await seedBroadcast('Everyone');
    await seedTargeted('Alice only', [alice.id]);

    const a = await feed(alice);
    expect(a.body.notifications.map((n: { title: string }) => n.title)).toEqual([
      'Alice only',
      'Everyone',
    ]);
    expect(a.body.unreadCount).toBe(2);

    const b = await feed(bob);
    expect(b.body.notifications.map((n: { title: string }) => n.title)).toEqual(['Everyone']);
    expect(b.body.unreadCount).toBe(1);
  });

  it('is newest first', async () => {
    const u = await makeUser();
    await seedBroadcast('first', { createdAt: new Date('2026-01-01T00:00:00Z') });
    await seedBroadcast('second', { createdAt: new Date('2026-02-01T00:00:00Z') });
    await seedBroadcast('third', { createdAt: new Date('2026-03-01T00:00:00Z') });

    const res = await feed(u);
    expect(res.body.notifications.map((n: { title: string }) => n.title)).toEqual([
      'third',
      'second',
      'first',
    ]);
  });

  it('hides retracted and expired rows; a future expiry still shows', async () => {
    const u = await makeUser();
    await seedBroadcast('retracted', { deletedAt: new Date() });
    await seedBroadcast('expired', { expiresAt: new Date(Date.now() - 60_000) });
    await seedBroadcast('still live', { expiresAt: new Date(Date.now() + 60 * 60_000) });
    await seedBroadcast('never expires');

    const res = await feed(u);
    expect(res.body.notifications.map((n: { title: string }) => n.title).sort()).toEqual([
      'never expires',
      'still live',
    ]);
    expect(res.body.unreadCount).toBe(2);
  });

  it('ships the action and detail exactly as stored, and null when absent', async () => {
    const u = await makeUser();
    await seedBroadcast('with cta', {
      detail: 'Long form text.',
      action: { label: 'Open analytics', url: '/catalog/analytics' },
    });

    const res = await feed(u);
    expect(res.body.notifications[0]).toMatchObject({
      detail: 'Long form text.',
      action: { label: 'Open analytics', url: '/catalog/analytics' },
    });
  });
});

describe('POST /notifications/:id/read', () => {
  it('marks one read, decrements the count, and is idempotent on readAt', async () => {
    const u = await makeUser();
    const n1 = await seedBroadcast('one');
    await seedBroadcast('two');

    const first = await read(u, n1.id as string);
    expect(first.status).toBe(200);
    expect(first.body).toEqual({ status: 'success', unreadCount: 1 });

    const after = await feed(u);
    const row = after.body.notifications.find((n: { id: string }) => n.id === n1.id);
    expect(row.isRead).toBe(true);
    expect(typeof row.readAt).toBe('string');

    // Second tap: same count, same readAt, still ONE receipt.
    const second = await read(u, n1.id as string);
    expect(second.body.unreadCount).toBe(1);
    const again = await feed(u);
    expect(again.body.notifications.find((n: { id: string }) => n.id === n1.id).readAt).toBe(
      row.readAt
    );
    expect(await NotificationReceipt.countDocuments({})).toBe(1);
  });

  it('answers the SAME 404 for a bogus id, a retracted row, and someone else’s targeted row', async () => {
    const alice = await makeUser();
    const bob = await makeUser();
    const forAlice = await seedTargeted('Alice only', [alice.id]);
    const gone = await seedBroadcast('retracted', { deletedAt: new Date() });

    const bogus = await read(bob, new Types.ObjectId().toHexString());
    const notMine = await read(bob, forAlice.id as string);
    const retracted = await read(bob, gone.id as string);

    for (const res of [bogus, notMine, retracted]) {
      expect(res.status).toBe(404);
      expect(res.body).toEqual(bogus.body);
    }
    expect(bogus.body.code).toBe('NOTIFICATION_NOT_FOUND');
    // And no receipt was written for the ones that exist.
    expect(await NotificationReceipt.countDocuments({})).toBe(0);
  });

  it('rejects a malformed id with 400', async () => {
    const u = await makeUser();
    const res = await read(u, 'not-an-id');
    expect(res.status).toBe(400);
    expect(res.body.code).toBe('INVALID_REQUEST');
  });
});

describe('POST /notifications/read-all', () => {
  it('clears everything visible and reports how many were newly marked', async () => {
    const u = await makeUser();
    const other = await makeUser();
    const n1 = await seedBroadcast('one');
    await seedBroadcast('two');
    await seedTargeted('not for u', [other.id]);
    await read(u, n1.id as string); // already read → not re-marked

    const res = await request(app).post('/notifications/read-all').set(u.auth);
    expect(res.status).toBe(200);
    expect(res.body).toEqual({ status: 'success', marked: 1, unreadCount: 0 });

    const after = await feed(u);
    expect(after.body.unreadCount).toBe(0);
    expect(after.body.notifications.every((n: { isRead: boolean }) => n.isRead)).toBe(true);
    // Only u's receipts, and none for the row u cannot see.
    expect(await NotificationReceipt.countDocuments({})).toBe(2);
    // `other` sees both broadcasts AND their own targeted row — all untouched.
    expect((await feed(other)).body.unreadCount).toBe(3);
  });

  it('is a no-op success on an empty feed', async () => {
    const u = await makeUser();
    const res = await request(app).post('/notifications/read-all').set(u.auth);
    expect(res.body).toEqual({ status: 'success', marked: 0, unreadCount: 0 });
  });
});

describe('/admin/notifications — the send surface', () => {
  const validBody = {
    kind: 'PAYMENT_DUE',
    title: 'Payment due',
    message: 'Your subscription renews on Friday.',
    detail: 'Renew from the billing page to keep your catalog live.',
    action: { label: 'Pay now', url: 'https://example.com/pay' },
    audience: { type: 'ALL' },
  };

  it('is ADMIN-only: USER and MODEL_ARTIST are refused, ADMIN passes', async () => {
    const user = await makeUser();
    const artist = await makeUser('MODEL_ARTIST');
    const admin = await makeUser('ADMIN');

    expect((await request(app).post('/admin/notifications').set(user.auth).send(validBody)).status).toBe(403);
    expect((await request(app).post('/admin/notifications').set(artist.auth).send(validBody)).status).toBe(403);
    expect((await request(app).get('/admin/notifications').set(artist.auth)).status).toBe(403);

    const res = await request(app).post('/admin/notifications').set(admin.auth).send(validBody);
    expect(res.status).toBe(201);
    expect(res.body.status).toBe('success');
    expect(res.body.notification).toMatchObject({
      kind: 'PAYMENT_DUE',
      title: 'Payment due',
      message: 'Your subscription renews on Friday.',
      detail: 'Renew from the billing page to keep your catalog live.',
      action: { label: 'Pay now', url: 'https://example.com/pay' },
      audience: { type: 'ALL' },
      expiresAt: null,
      readCount: 0,
    });
  });

  it('a broadcast lands in every user’s feed, unread', async () => {
    const admin = await makeUser('ADMIN');
    const a = await makeUser();
    const b = await makeUser();
    await request(app).post('/admin/notifications').set(admin.auth).send(validBody).expect(201);

    for (const u of [a, b, admin]) {
      const res = await feed(u);
      expect(res.body.unreadCount).toBe(1);
      expect(res.body.notifications[0].title).toBe('Payment due');
    }
  });

  it('a targeted send reaches only the named users, and the admin list carries opaque ids', async () => {
    const admin = await makeUser('ADMIN');
    const target = await makeUser();
    const bystander = await makeUser();

    const res = await request(app)
      .post('/admin/notifications')
      .set(admin.auth)
      .send({ ...validBody, action: undefined, audience: { type: 'USERS', userIds: [target.id] } });
    expect(res.status).toBe(201);
    expect(res.body.notification.audience).toEqual({ type: 'USERS', userIds: [target.id] });
    expect(res.body.notification.action).toBeNull();

    expect((await feed(target)).body.unreadCount).toBe(1);
    expect((await feed(bystander)).body.unreadCount).toBe(0);
  });

  it('validates strictly: unknown fields, a bad action url, an empty title and a past expiry are 400s', async () => {
    const admin = await makeUser('ADMIN');
    const send = (body: unknown) =>
      request(app).post('/admin/notifications').set(admin.auth).send(body);

    const cases: unknown[] = [
      { ...validBody, surprise: 1 },
      { ...validBody, title: '' },
      { ...validBody, action: { label: 'Go', url: 'http://plain.example' } },
      { ...validBody, action: { label: 'Go', url: 'javascript:alert(1)' } },
      { ...validBody, audience: { type: 'USERS', userIds: [] } },
      { ...validBody, audience: { type: 'USERS', userIds: ['nope'] } },
      { ...validBody, expiresAt: '2020-01-01T00:00:00Z' },
      { ...validBody, kind: 'SHOUT' },
    ];
    for (const body of cases) {
      const res = await send(body);
      expect(res.status, JSON.stringify(body)).toBe(400);
      expect(res.body.code).toBe('INVALID_REQUEST');
    }
    expect(await Notification.countDocuments({})).toBe(0);

    // The two url shapes that ARE allowed.
    await send({ ...validBody, action: { label: 'Go', url: '/catalog/analytics' } }).expect(201);
    await send({ ...validBody, action: { label: 'Go', url: 'https://example.com/x' } }).expect(201);
  });

  it('GET lists live rows newest first with a read count; DELETE retracts from every feed', async () => {
    const admin = await makeUser('ADMIN');
    const a = await makeUser();
    const b = await makeUser();
    const created = await request(app)
      .post('/admin/notifications')
      .set(admin.auth)
      .send(validBody)
      .expect(201);
    const id = created.body.notification.id as string;
    await read(a, id).expect(200);

    const list = await request(app).get('/admin/notifications').set(admin.auth);
    expect(list.status).toBe(200);
    expect(list.body.notifications).toHaveLength(1);
    expect(list.body.notifications[0]).toMatchObject({ id, readCount: 1 });
    // No PII anywhere on the admin list, even by accident.
    expect(JSON.stringify(list.body)).not.toMatch(/phone|email/);

    await request(app).delete(`/admin/notifications/${id}`).set(admin.auth).expect(200);

    expect((await feed(a)).body.notifications).toHaveLength(0);
    expect((await feed(b)).body.notifications).toHaveLength(0);
    expect((await request(app).get('/admin/notifications').set(admin.auth)).body.notifications).toHaveLength(0);
    // The receipt survives the retraction — it is history.
    expect(await NotificationReceipt.countDocuments({})).toBe(1);

    // A second retraction is the same 404 as a bogus id.
    const twice = await request(app).delete(`/admin/notifications/${id}`).set(admin.auth);
    const bogus = await request(app)
      .delete(`/admin/notifications/${new Types.ObjectId().toHexString()}`)
      .set(admin.auth);
    expect(twice.status).toBe(404);
    expect(bogus.status).toBe(404);
    expect(twice.body).toEqual(bogus.body);
  });
});
