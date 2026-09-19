// tests/subscription-nudge.test.ts
//
// Door 2's one on-demand tool: the rep's "Notify owner to pay" nudge
// (docs/subscription/stage-04-rep-tools.md).
//
// What this file most exists to pin:
//   • A NUDGE IS NOT A PAYMENT (AC-7.3). `CatalogSubscription` and
//     `PaymentRecord` are hashed before and after a send and must not move
//     by a byte — the route reads the subscription and writes ONE
//     Notification row and one stub SMS, nothing else.
//   • THE PHONE NEVER LEAVES THE SERVER. Not in the response, not in the
//     stub's log line, not in analytics — hashed ids only.
//   • THE WINDOW IS PER CATALOG. Two reps share it; an admin does not skip it;
//     the cooldown the GET reports is the same instant the 429 reports.
//   • A PAID-UP OWNER CANNOT BE NAGGED. ACTIVE with more than a week left is a
//     409 whatever the client sends.
import { describe, it, expect, beforeAll, afterAll, beforeEach, afterEach, vi } from 'vitest';
import request from 'supertest';
import mongoose, { Types } from 'mongoose';
import { MongoMemoryServer } from 'mongodb-memory-server';
import { createHash } from 'crypto';

import { createApp } from '@/app';
import { Catalog } from '@/models/Catalog';
import { CatalogDelegation } from '@/models/CatalogDelegation';
import { CatalogSubscription } from '@/models/CatalogSubscription';
import { ClientConfig } from '@/models/ClientConfig';
import { Notification } from '@/models/Notification';
import { PaymentRecord } from '@/models/PaymentRecord';
import { RateWindow } from '@/models/RateWindow';
import { User } from '@/models/User';
import { sendTemplatedSms } from '@/providers/sms';
import { hashIdentifier } from '@/utils/otp';
import {
  DAY_MS,
  delegated as delegatedFixture,
  emitted,
  makeUser,
  seedSubscription,
} from './helpers/subscriptionPayments';

// The seam, with the ORIGINAL body underneath: the stub's log line is part of
// what this file checks, and one test re-scripts a single call to throw.
vi.mock('@/providers/sms', async (importOriginal) => {
  const actual = await importOriginal<typeof import('@/providers/sms')>();
  return { ...actual, sendTemplatedSms: vi.fn(actual.sendTemplatedSms) };
});

const app = createApp();
let mongod: MongoMemoryServer;

beforeAll(async () => {
  mongod = await MongoMemoryServer.create();
  await mongoose.connect(mongod.getUri());
  await Catalog.syncIndexes();
  await CatalogSubscription.syncIndexes();
  await CatalogDelegation.syncIndexes();
  await Notification.syncIndexes();
});

afterAll(async () => {
  await mongoose.disconnect();
  await mongod.stop();
});

beforeEach(() => {
  vi.spyOn(console, 'log').mockImplementation(() => {});
  vi.spyOn(console, 'warn').mockImplementation(() => {});
});

afterEach(async () => {
  vi.restoreAllMocks();
  vi.mocked(sendTemplatedSms).mockClear();
  await Promise.all([
    User.deleteMany({}),
    Catalog.deleteMany({}),
    CatalogDelegation.deleteMany({}),
    CatalogSubscription.deleteMany({}),
    ClientConfig.deleteMany({}),
    PaymentRecord.deleteMany({}),
    RateWindow.deleteMany({}),
    Notification.deleteMany({}),
  ]);
});

const OWNER_PHONE = '+919876543210';

/** The shared fixture, plus a phone on the owner — the thing a nudge needs. */
async function delegated(phone: string | null = OWNER_PHONE) {
  const fx = await delegatedFixture();
  if (phone) await User.updateOne({ _id: fx.owner.id }, { $set: { phone } }).exec();
  await Catalog.updateOne({ _id: fx.catalogId }, { $set: { businessName: 'Blue Cafe' } }).exec();
  return fx;
}

const nudgePath = (id: Types.ObjectId | string) =>
  `/rep/catalogs/${id}/subscription/notify-owner`;
const subscriptionPath = (id: Types.ObjectId | string) => `/rep/catalogs/${id}/subscription`;

/** Every line the SMS stub logged, flattened — the haystack for "no digits of the phone". */
function smsLogLines(): string[] {
  return vi
    .mocked(console.log)
    .mock.calls.filter((c) => String(c[0]).startsWith('[sms]'))
    .map((c) =>
      c.map((part) => (typeof part === 'string' ? part : JSON.stringify(part))).join(' ')
    );
}

/** A stable digest of every row in the two money collections (AC-7.3). */
async function moneyDigest(): Promise<{ subscriptions: number; payments: number; hash: string }> {
  const [subs, pays] = await Promise.all([
    CatalogSubscription.find({}).sort({ _id: 1 }).lean().exec(),
    PaymentRecord.find({}).sort({ _id: 1 }).lean().exec(),
  ]);
  const hash = createHash('sha256').update(JSON.stringify({ subs, pays })).digest('hex');
  return { subscriptions: subs.length, payments: pays.length, hash };
}

describe('POST /rep/catalogs/:id/subscription/notify-owner', () => {
  it('sends by SMS and in-app, writes ONE Notification for the owner, and leaks no phone', async () => {
    const { owner, rep, catalogId } = await delegated();
    await seedSubscription(catalogId, owner.id, 'TRIAL', {
      periodEnd: new Date(Date.now() + 5 * DAY_MS),
    });

    const res = await request(app).post(nudgePath(catalogId)).set(rep.auth);

    expect(res.status).toBe(200);
    expect(res.body).toEqual({
      status: 'success',
      nudge: { channels: ['SMS', 'IN_APP'], nextAllowedAt: null },
    });
    expect(JSON.stringify(res.body)).not.toContain('9876543210');

    // One row, for the owner alone, pointing the bell at the subscription screen.
    const rows = await Notification.find({}).lean().exec();
    expect(rows).toHaveLength(1);
    expect(rows[0]).toMatchObject({
      kind: 'PAYMENT_DUE',
      title: 'Keep your 3D menu live',
      message:
        'Blue Cafe: your Mirage Menu trial ends in 5 days — open the ReCapture app to pay ' +
        'and keep your 3D menu live.',
      action: { label: 'Pay now', url: '/catalog/subscription' },
      audienceType: 'USERS',
    });
    expect(rows[0].audienceUserIds.map(String)).toEqual([String(owner.id)]);
    expect(String(rows[0].createdByUserId)).toBe(String(rep.id));

    // The stub was handed the owner's number and the template, and logged the
    // template name — not one digit of the phone.
    expect(vi.mocked(sendTemplatedSms)).toHaveBeenCalledWith(
      OWNER_PHONE,
      'SUBSCRIPTION_PAY_NUDGE',
      { restaurant: 'Blue Cafe', what: 'trial ends in 5 days' }
    );
    const lines = smsLogLines();
    expect(lines).toHaveLength(1);
    expect(lines[0]).toContain('SUBSCRIPTION_PAY_NUDGE');
    // No four consecutive digits of the number anywhere in the line (the stub
    // id is a UUID, so "no digits at all" would be the wrong assertion).
    const digits = OWNER_PHONE.replace(/\D/g, '');
    for (let i = 0; i + 4 <= digits.length; i += 1) {
      expect(lines[0]).not.toContain(digits.slice(i, i + 4));
    }

    expect(emitted('subscription_nudge_sent')).toEqual([
      {
        catalog_id: catalogId.toHexString(),
        actor_id_hash: hashIdentifier(rep.id.toHexString()),
        owner_id_hash: hashIdentifier(owner.id.toHexString()),
        subscription_status: 'TRIAL',
        channels: ['SMS', 'IN_APP'],
      },
    ]);
    expect(emitted('subscription_nudge_refused')).toEqual([]);
  });

  it('never touches CatalogSubscription or PaymentRecord (AC-7.3)', async () => {
    const { owner, rep, catalogId } = await delegated();
    const sub = await seedSubscription(catalogId, owner.id, 'GRACE', {
      periodEnd: new Date(Date.now() - 2 * DAY_MS),
      graceEndsAt: new Date(Date.now() + 5 * DAY_MS),
      planId: 'TASTE',
    });
    await PaymentRecord.create({
      catalogId,
      userId: owner.id,
      subscriptionId: sub._id,
      kind: 'PAID',
      amountPaise: 119_900,
      initiatedBy: { userId: owner.id, role: 'USER' },
    });
    const before = await moneyDigest();
    expect(before).toMatchObject({ subscriptions: 1, payments: 1 });

    const res = await request(app).post(nudgePath(catalogId)).set(rep.auth);
    expect(res.status).toBe(200);

    expect(await moneyDigest()).toEqual(before);
    const [row] = await Notification.find({}).lean().exec();
    expect(row.message).toContain('your Mirage Menu payment is overdue');
  });

  it('chooses the clause from the status: PAUSED, no row, ACTIVE inside a week', async () => {
    const paused = await delegated();
    await seedSubscription(paused.catalogId, paused.owner.id, 'PAUSED');
    let res = await request(app).post(nudgePath(paused.catalogId)).set(paused.rep.auth);
    expect(res.status).toBe(200);

    const none = await delegated();
    res = await request(app).post(nudgePath(none.catalogId)).set(none.rep.auth);
    expect(res.status).toBe(200);

    const soon = await delegated();
    // Just under a day: the server rounds UP to whole days, so this is "1 day".
    await seedSubscription(soon.catalogId, soon.owner.id, 'ACTIVE', {
      periodEnd: new Date(Date.now() + DAY_MS - 60_000),
    });
    res = await request(app).post(nudgePath(soon.catalogId)).set(soon.rep.auth);
    expect(res.status).toBe(200);

    const messages = (
      await Notification.find({}).sort({ createdAt: 1, _id: 1 }).lean().exec()
    ).map((n) => n.message);
    expect(messages).toEqual([
      expect.stringContaining('your Mirage Menu 3D menu is paused'),
      expect.stringContaining('your Mirage Menu has no plan yet'),
      expect.stringContaining('your Mirage Menu plan expires in 1 day —'),
    ]);
    expect(emitted('subscription_nudge_sent').map((e) => e.subscription_status)).toEqual([
      'PAUSED',
      'NONE',
      'ACTIVE',
    ]);
  });

  it('refuses a paid-up owner — ACTIVE with 20 days left, or a comp — with 409 NUDGE_NOT_NEEDED', async () => {
    const { owner, rep, catalogId } = await delegated();
    await seedSubscription(catalogId, owner.id, 'ACTIVE', {
      periodEnd: new Date(Date.now() + 20 * DAY_MS),
    });

    const res = await request(app).post(nudgePath(catalogId)).set(rep.auth);
    expect(res.status).toBe(409);
    expect(res.body).toMatchObject({ status: 'error', code: 'NUDGE_NOT_NEEDED' });
    expect(await Notification.countDocuments({})).toBe(0);
    expect(vi.mocked(sendTemplatedSms)).not.toHaveBeenCalled();

    const comped = await delegated();
    await seedSubscription(comped.catalogId, comped.owner.id, 'COMPED', {
      source: 'COMP',
      threeDDishCap: -1,
    });
    const res2 = await request(app).post(nudgePath(comped.catalogId)).set(comped.rep.auth);
    expect(res2.status).toBe(409);
    expect(res2.body.code).toBe('NUDGE_NOT_NEEDED');

    expect(emitted('subscription_nudge_refused')).toEqual([
      { catalog_id: catalogId.toHexString(), reason: 'NOT_NEEDED' },
      { catalog_id: comped.catalogId.toHexString(), reason: 'NOT_NEEDED' },
    ]);
  });

  it('answers 409 OWNER_UNREACHABLE for a legacy owner with no phone', async () => {
    const { owner, rep, catalogId } = await delegated(null);
    await seedSubscription(catalogId, owner.id, 'GRACE');

    const res = await request(app).post(nudgePath(catalogId)).set(rep.auth);
    expect(res.status).toBe(409);
    expect(res.body).toMatchObject({
      status: 'error',
      code: 'OWNER_UNREACHABLE',
      message: 'This owner has no phone number on file — ask an admin.',
    });
    expect(await Notification.countDocuments({})).toBe(0);
    expect(emitted('subscription_nudge_refused')).toEqual([
      { catalog_id: catalogId.toHexString(), reason: 'NO_PHONE' },
    ]);
  });

  it('still lands in-app when the SMS stub throws — 200 with channels [IN_APP]', async () => {
    const { owner, rep, catalogId } = await delegated();
    await seedSubscription(catalogId, owner.id, 'GRACE');
    vi.mocked(sendTemplatedSms).mockRejectedValueOnce(
      new Error('Simulated SMS dispatch failure')
    );

    const res = await request(app).post(nudgePath(catalogId)).set(rep.auth);

    expect(res.status).toBe(200);
    expect(res.body.nudge.channels).toEqual(['IN_APP']);
    expect(await Notification.countDocuments({ audienceUserIds: owner.id })).toBe(1);
    expect(emitted('subscription_nudge_sent')[0]).toMatchObject({ channels: ['IN_APP'] });
  });

  it('is rate-limited PER CATALOG: the window is shared by every rep and reported by the GET', async () => {
    const { owner, rep, catalogId } = await delegated();
    await seedSubscription(catalogId, owner.id, 'GRACE');
    // A second rep holding the same restaurant.
    const other = await makeUser('SALES_REP');
    await CatalogDelegation.create({
      repUserId: other.id,
      catalogId,
      grantedAt: new Date(),
      revokedAt: null,
    });

    // Before anything: no cooldown, and the owner's DTO is untouched.
    let get = await request(app).get(subscriptionPath(catalogId)).set(rep.auth);
    expect(get.status).toBe(200);
    expect(get.body.nudge).toEqual({ nextAllowedAt: null });
    expect(get.body.subscription.status).toBe('GRACE');

    // Two a day (the default): the first is free, the second spends the window.
    const first = await request(app).post(nudgePath(catalogId)).set(rep.auth);
    expect(first.status).toBe(200);
    expect(first.body.nudge.nextAllowedAt).toBeNull();
    const second = await request(app).post(nudgePath(catalogId)).set(rep.auth);
    expect(second.status).toBe(200);
    expect(typeof second.body.nudge.nextAllowedAt).toBe('string');
    const resetsAt = new Date(second.body.nudge.nextAllowedAt).getTime();
    expect(resetsAt - Date.now()).toBeGreaterThan(23 * 3600 * 1000);
    expect(resetsAt - Date.now()).toBeLessThanOrEqual(24 * 3600 * 1000);

    // The OTHER rep is inside the same window.
    const third = await request(app).post(nudgePath(catalogId)).set(other.auth);
    expect(third.status).toBe(429);
    expect(third.body).toMatchObject({ status: 'error', code: 'RATE_LIMITED' });
    expect(third.body.retryAfter).toBeGreaterThan(23 * 3600);
    expect(third.body.retryAfter).toBeLessThanOrEqual(24 * 3600);
    // Same instant, to the second, as the successful send reported…
    expect(
      Math.abs(new Date(third.body.nextAllowedAt).getTime() - resetsAt)
    ).toBeLessThanOrEqual(1000);
    // …and exactly what the GET now reports.
    get = await request(app).get(subscriptionPath(catalogId)).set(other.auth);
    expect(new Date(get.body.nudge.nextAllowedAt).getTime()).toBe(resetsAt);

    expect(await Notification.countDocuments({})).toBe(2);
    expect(emitted('subscription_nudge_refused')).toEqual([
      { catalog_id: catalogId.toHexString(), reason: 'RATE_LIMITED' },
    ]);
    const windows = await RateWindow.find({}).lean().exec();
    expect(windows.map((w) => w.key)).toEqual([`sub-nudge:${catalogId.toHexString()}`]);
  });

  it('gives an ADMIN no bypass of the window', async () => {
    const { owner, rep, admin, catalogId } = await delegated();
    await seedSubscription(catalogId, owner.id, 'GRACE');
    await CatalogDelegation.create({
      repUserId: admin.id,
      catalogId,
      grantedAt: new Date(),
      revokedAt: null,
    });
    expect((await request(app).post(nudgePath(catalogId)).set(rep.auth)).status).toBe(200);
    expect((await request(app).post(nudgePath(catalogId)).set(rep.auth)).status).toBe(200);
    expect((await request(app).post(nudgePath(catalogId)).set(admin.auth)).status).toBe(429);
  });

  it('refuses a body, a catalog the rep does not hold, and a caller who is not a rep', async () => {
    const { owner, rep, catalogId } = await delegated();
    await seedSubscription(catalogId, owner.id, 'GRACE');

    const withBody = await request(app)
      .post(nudgePath(catalogId))
      .set(rep.auth)
      .send({ message: 'pay up', phone: '+911234567890' });
    expect(withBody.status).toBe(400);
    expect(withBody.body.code).toBe('INVALID_REQUEST');

    const stranger = await makeUser('SALES_REP');
    const notHeld = await request(app).post(nudgePath(catalogId)).set(stranger.auth);
    expect(notHeld.status).toBe(404);
    expect(notHeld.body.code).toBe('CATALOG_NOT_FOUND');

    const missing = await request(app).post(nudgePath(new Types.ObjectId())).set(rep.auth);
    expect(missing.status).toBe(404);
    expect(missing.body.code).toBe('CATALOG_NOT_FOUND');

    const asOwner = await request(app).post(nudgePath(catalogId)).set(owner.auth);
    expect(asOwner.status).toBe(403);

    expect(await Notification.countDocuments({})).toBe(0);
    expect(await RateWindow.countDocuments({})).toBe(0);
  });
});
