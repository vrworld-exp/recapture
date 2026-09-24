// tests/subscription-admin-actions.test.ts
//
// Door 4 and the admin's other money actions. What this file most exists to pin:
//   • COMP: COMPED, uncapped, a zero-amount ledger row naming the admin.
//   • EXTEND GRACE only while in GRACE; anything else is a 409.
//   • REFUND is ADMIN-only, needs a flagged duplicate or an explained
//     override, writes exactly ONE REFUNDED row, never touches the period
//     (AC-5.1, AC-5.3, AC-5.4), refuses a second attempt and a MANUAL row,
//     and is metered per admin (E43).
//   • The collections list filters by state, sorts soonest first, paginates,
//     and is ADMIN-only (E39).
//   • applyPaidPeriod has exactly the callers the design allows.
import { describe, it, expect, beforeAll, afterAll, beforeEach, afterEach, vi } from 'vitest';
import request from 'supertest';
import mongoose, { Types } from 'mongoose';
import { MongoMemoryServer } from 'mongodb-memory-server';
import { readFileSync, readdirSync, statSync } from 'node:fs';
import path from 'node:path';

import { createApp } from '@/app';
import { env } from '@/config/env';
import { Catalog } from '@/models/Catalog';
import { CatalogDelegation } from '@/models/CatalogDelegation';
import { CatalogSubscription } from '@/models/CatalogSubscription';
import { Notification } from '@/models/Notification';
import { PaymentRecord } from '@/models/PaymentRecord';
import { RateWindow } from '@/models/RateWindow';
import { User } from '@/models/User';
import { DEFAULT_PLAN_CATALOG } from '@/config/subscriptionPlans';
import { resetRazorpayClient, setRazorpayClient } from '@/providers/razorpay';
import {
  DAY_MS,
  delegated,
  emitted,
  fakeRazorpay,
  makeUser,
  seedCatalog,
  seedSubscription,
} from './helpers/subscriptionPayments';

const app = createApp();
let mongod: MongoMemoryServer;

beforeAll(async () => {
  mongod = await MongoMemoryServer.create();
  await mongoose.connect(mongod.getUri());
  await Promise.all([
    Catalog.syncIndexes(),
    CatalogSubscription.syncIndexes(),
    CatalogDelegation.syncIndexes(),
    PaymentRecord.syncIndexes(),
  ]);
});

afterAll(async () => {
  await mongoose.disconnect();
  await mongod.stop();
});

beforeEach(() => {
  vi.spyOn(console, 'log').mockImplementation(() => {});
  vi.spyOn(console, 'warn').mockImplementation(() => {});
  setRazorpayClient(fakeRazorpay());
});

afterEach(async () => {
  vi.restoreAllMocks();
  resetRazorpayClient();
  await Promise.all([
    User.deleteMany({}),
    Catalog.deleteMany({}),
    CatalogDelegation.deleteMany({}),
    CatalogSubscription.deleteMany({}),
    PaymentRecord.deleteMany({}),
    RateWindow.deleteMany({}),
    Notification.deleteMany({}),
  ]);
});

const MONTHLY = DEFAULT_PLAN_CATALOG.plans.TASTE.priceMonthlyPaise;
const compPath = (id: Types.ObjectId) => `/admin/catalogs/${id}/subscription/comp`;
const gracePath = (id: Types.ObjectId) => `/admin/catalogs/${id}/subscription/extend-grace`;
const refundPath = (id: Types.ObjectId) => `/admin/catalogs/${id}/subscription/refund`;

/** A PAID row as the webhook would have left it. */
async function paidRow(
  catalogId: Types.ObjectId,
  ownerId: Types.ObjectId,
  overrides: Record<string, unknown> = {}
) {
  return PaymentRecord.create({
    catalogId,
    userId: ownerId,
    kind: 'PAID',
    amountPaise: MONTHLY,
    quote: {
      planId: 'TASTE',
      interval: 'MONTHLY',
      totalPaise: MONTHLY,
      planSnapshot: DEFAULT_PLAN_CATALOG.plans.TASTE,
    },
    providerOrderId: `order_${new Types.ObjectId().toHexString()}`,
    providerPaymentId: `pay_${new Types.ObjectId().toHexString()}`,
    initiatedBy: { userId: ownerId, role: 'USER' },
    appliedAt: new Date(),
    ...overrides,
  });
}

describe('POST /admin/catalogs/:id/subscription/comp', () => {
  it('comps until a date: COMPED, uncapped, and a zero-amount COMP row naming the admin', async () => {
    const { admin, owner, catalogId } = await delegated();
    await seedSubscription(catalogId, owner.id, 'PAUSED', { pausedAt: new Date() });
    const until = new Date(Date.now() + 90 * DAY_MS);

    const res = await request(app)
      .post(compPath(catalogId))
      .set(admin.auth)
      .send({ until: until.toISOString(), note: 'Launch partner' });

    expect(res.status).toBe(200);
    expect(res.body.subscription).toMatchObject({
      status: 'COMPED',
      planId: null,
      threeDDishCap: null,
      daysLeft: 90,
      isEntitledTo3D: true,
    });
    const row = await CatalogSubscription.findOne({ catalogId }).lean().exec();
    expect(row).toMatchObject({ status: 'COMPED', source: 'COMP', threeDDishCap: -1 });
    expect(row!.periodEnd.getTime()).toBe(until.getTime());
    expect(row!.pausedAt ?? null).toBeNull();

    const ledger = await PaymentRecord.findOne({ catalogId }).lean().exec();
    expect(ledger).toMatchObject({ kind: 'COMP', amountPaise: 0, note: 'Launch partner' });
    expect(String(ledger!.initiatedBy.userId)).toBe(String(admin.id));
    expect(String(ledger!.subscriptionId)).toBe(String(row!._id));
    expect(emitted('subscription_payment_recorded')).toEqual([
      expect.objectContaining({
        source: 'COMP',
        plan_id: null,
        previous_status: 'PAUSED',
        via: 'ADMIN',
      }),
    ]);
  });

  it('creates the row for a catalog that never had one, and refuses a past date', async () => {
    const { admin, catalogId } = await delegated();
    const past = await request(app)
      .post(compPath(catalogId))
      .set(admin.auth)
      .send({ until: new Date(Date.now() - 1000).toISOString(), note: 'x' });
    expect(past.status).toBe(400);

    const res = await request(app)
      .post(compPath(catalogId))
      .set(admin.auth)
      .send({ until: new Date(Date.now() + DAY_MS).toISOString(), note: 'demo' });
    expect(res.status).toBe(200);
    expect(await CatalogSubscription.countDocuments({ catalogId, status: 'COMPED' })).toBe(1);
  });

  it('is ADMIN only, and 404 for an unknown catalog', async () => {
    const { rep, catalogId } = await delegated();
    const artist = await makeUser('MODEL_ARTIST');
    const admin = await makeUser('ADMIN');
    const body = { until: new Date(Date.now() + DAY_MS).toISOString(), note: 'x' };
    expect((await request(app).post(compPath(catalogId)).set(rep.auth).send(body)).status).toBe(
      403
    );
    expect((await request(app).post(compPath(catalogId)).set(artist.auth).send(body)).status).toBe(
      403
    );
    expect(
      (await request(app).post(compPath(new Types.ObjectId())).set(admin.auth).send(body)).status
    ).toBe(404);
  });
});

describe('POST /admin/catalogs/:id/subscription/extend-grace', () => {
  it('adds days to graceEndsAt while in GRACE', async () => {
    const { admin, owner, catalogId } = await delegated();
    const graceEndsAt = new Date(Date.now() + 2 * DAY_MS);
    await seedSubscription(catalogId, owner.id, 'GRACE', {
      periodEnd: new Date(Date.now() - 5 * DAY_MS),
      graceEndsAt,
    });

    const res = await request(app)
      .post(gracePath(catalogId))
      .set(admin.auth)
      .send({ days: 7, note: 'Owner travelling' });

    expect(res.status).toBe(200);
    expect(res.body.subscription.status).toBe('GRACE');
    expect(res.body.subscription.daysLeft).toBe(9);
    const row = await CatalogSubscription.findOne({ catalogId }).lean().exec();
    expect(row!.graceEndsAt!.getTime()).toBe(graceEndsAt.getTime() + 7 * DAY_MS);
    expect(emitted('subscription_grace_extended')).toEqual([expect.objectContaining({ days: 7 })]);
  });

  it('is 409 NOT_IN_GRACE for any other status, and bounds days to 1..30', async () => {
    const { admin, owner, catalogId } = await delegated();
    await seedSubscription(catalogId, owner.id, 'ACTIVE');
    const res = await request(app)
      .post(gracePath(catalogId))
      .set(admin.auth)
      .send({ days: 7, note: 'x' });
    expect(res.status).toBe(409);
    expect(res.body.code).toBe('NOT_IN_GRACE');

    await CatalogSubscription.updateOne(
      { catalogId },
      { $set: { status: 'GRACE', graceEndsAt: new Date(Date.now() + DAY_MS) } }
    );
    for (const days of [0, 31, 2.5]) {
      const bad = await request(app)
        .post(gracePath(catalogId))
        .set(admin.auth)
        .send({ days, note: 'x' });
      expect(bad.status).toBe(400);
    }
  });
});

describe('POST /admin/catalogs/:id/subscription/refund', () => {
  it('refunds a flagged duplicate: one REFUNDED row, period untouched (AC-5.3, AC-5.4)', async () => {
    const { admin, owner, catalogId } = await delegated();
    const sub = await seedSubscription(catalogId, owner.id, 'ACTIVE');
    const dup = await paidRow(catalogId, owner.id, { note: 'DUPLICATE_SUSPECTED' });
    const client = fakeRazorpay();
    setRazorpayClient(client);

    const res = await request(app)
      .post(refundPath(catalogId))
      .set(admin.auth)
      .send({ refundsPaymentId: String(dup._id), note: 'Charged twice on 12 Sep' });

    expect(res.status).toBe(201);
    expect(res.body.paymentRecord).toMatchObject({ kind: 'REFUNDED', amountPaise: MONTHLY });
    expect(client.createRefund).toHaveBeenCalledWith(
      dup.providerPaymentId,
      expect.objectContaining({ amountPaise: MONTHLY })
    );
    const refunded = await PaymentRecord.find({ kind: 'REFUNDED' }).lean().exec();
    expect(refunded).toHaveLength(1);
    expect(refunded[0]).toMatchObject({
      providerRefundId: expect.stringMatching(/^rfnd_test_\d+$/),
      note: 'Charged twice on 12 Sep',
    });
    expect(refunded[0].idempotencyKey).toBe(`refund:${refunded[0].providerRefundId}`);
    expect(String(refunded[0].refundsPaymentId)).toBe(String(dup._id));
    expect(String(refunded[0].initiatedBy.userId)).toBe(String(admin.id));

    const after = await CatalogSubscription.findOne({ catalogId }).lean().exec();
    expect(after!.status).toBe('ACTIVE');
    expect(after!.periodEnd.getTime()).toBe(sub.periodEnd.getTime());
    expect(emitted('subscription_refund_issued')).toEqual([
      expect.objectContaining({ amount_paise: MONTHLY, override: false }),
    ]);
  });

  it('a second refund of the same row is 409 ALREADY_REFUNDED', async () => {
    const { admin, owner, catalogId } = await delegated();
    const dup = await paidRow(catalogId, owner.id, { note: 'DUPLICATE_SUSPECTED' });
    const body = { refundsPaymentId: String(dup._id), note: 'Charged twice on 12 Sep' };
    await request(app).post(refundPath(catalogId)).set(admin.auth).send(body).expect(201);
    const again = await request(app).post(refundPath(catalogId)).set(admin.auth).send(body);
    expect(again.status).toBe(409);
    expect(again.body.code).toBe('ALREADY_REFUNDED');
    expect(await PaymentRecord.countDocuments({ kind: 'REFUNDED' })).toBe(1);
  });

  it('an unflagged row needs override + a 30-char note (the E5 escape hatch)', async () => {
    const { admin, owner, catalogId } = await delegated();
    const paid = await paidRow(catalogId, owner.id, { note: 'ORPHAN_PAYMENT' });

    const plain = await request(app)
      .post(refundPath(catalogId))
      .set(admin.auth)
      .send({ refundsPaymentId: String(paid._id), note: 'Refund please now' });
    expect(plain.status).toBe(422);
    expect(plain.body.code).toBe('OVERRIDE_REQUIRED');

    const shortNote = await request(app)
      .post(refundPath(catalogId))
      .set(admin.auth)
      .send({ refundsPaymentId: String(paid._id), note: 'Orphan payment', override: true });
    expect(shortNote.status).toBe(422);

    const explained = await request(app)
      .post(refundPath(catalogId))
      .set(admin.auth)
      .send({
        refundsPaymentId: String(paid._id),
        note: 'Catalog deleted before payment landed; refunding the orphan in full.',
        override: true,
      });
    expect(explained.status).toBe(201);
    expect(emitted('subscription_refund_issued')).toEqual([
      expect.objectContaining({ override: true }),
    ]);
  });

  it('a MANUAL row is 422 NOT_REFUNDABLE; a row on another catalog is 404', async () => {
    const { admin, owner, catalogId } = await delegated();
    const manual = await PaymentRecord.create({
      catalogId,
      userId: owner.id,
      kind: 'MANUAL',
      amountPaise: MONTHLY,
      method: 'CASH',
      reference: 'r',
      verificationStatus: 'VERIFIED',
      initiatedBy: { userId: owner.id, role: 'SALES_REP' },
      note: 'DUPLICATE_SUSPECTED',
    });
    const res = await request(app)
      .post(refundPath(catalogId))
      .set(admin.auth)
      .send({ refundsPaymentId: String(manual._id), note: 'Charged twice on 12 Sep' });
    expect(res.status).toBe(422);
    expect(res.body.code).toBe('NOT_REFUNDABLE');

    const other = await delegated();
    const elsewhere = await paidRow(other.catalogId, other.owner.id, {
      note: 'DUPLICATE_SUSPECTED',
    });
    const wrong = await request(app)
      .post(refundPath(catalogId))
      .set(admin.auth)
      .send({ refundsPaymentId: String(elsewhere._id), note: 'Charged twice on 12 Sep' });
    expect(wrong.status).toBe(404);
    expect(await PaymentRecord.countDocuments({ kind: 'REFUNDED' })).toBe(0);
  });

  it('requires refundsPaymentId and ADMIN; a short note is 400 (AC-5.1)', async () => {
    const { admin, rep, owner, catalogId } = await delegated();
    const dup = await paidRow(catalogId, owner.id, { note: 'DUPLICATE_SUSPECTED' });
    expect(
      (
        await request(app)
          .post(refundPath(catalogId))
          .set(admin.auth)
          .send({ note: 'Charged twice on 12 Sep' })
      ).status
    ).toBe(400);
    expect(
      (
        await request(app)
          .post(refundPath(catalogId))
          .set(admin.auth)
          .send({ refundsPaymentId: String(dup._id), note: 'short' })
      ).status
    ).toBe(400);
    const asRep = await request(app)
      .post(refundPath(catalogId))
      .set(rep.auth)
      .send({ refundsPaymentId: String(dup._id), note: 'Charged twice on 12 Sep' });
    expect(asRep.status).toBe(403);
    expect(await PaymentRecord.countDocuments({ kind: 'REFUNDED' })).toBe(0);
  });

  it('is metered per admin (E43)', async () => {
    const { admin, owner, catalogId } = await delegated();
    const rows = await Promise.all(
      Array.from({ length: env.ADMIN_REFUND_MAX_PER_WINDOW + 1 }, () =>
        paidRow(catalogId, owner.id, { note: 'DUPLICATE_SUSPECTED' })
      )
    );
    for (let i = 0; i < env.ADMIN_REFUND_MAX_PER_WINDOW; i++) {
      await request(app)
        .post(refundPath(catalogId))
        .set(admin.auth)
        .send({ refundsPaymentId: String(rows[i]._id), note: 'Charged twice on 12 Sep' })
        .expect(201);
    }
    const over = await request(app)
      .post(refundPath(catalogId))
      .set(admin.auth)
      .send({
        refundsPaymentId: String(rows[rows.length - 1]._id),
        note: 'Charged twice on 12 Sep',
      });
    expect(over.status).toBe(429);
    expect(over.body.code).toBe('RATE_LIMITED');
    expect(await PaymentRecord.countDocuments({ kind: 'REFUNDED' })).toBe(
      env.ADMIN_REFUND_MAX_PER_WINDOW
    );
  });

  it('answers 503 when Razorpay refuses, and writes no row', async () => {
    setRazorpayClient(
      fakeRazorpay({
        createRefund: async () => {
          throw new Error('BAD_GATEWAY');
        },
      })
    );
    const { admin, owner, catalogId } = await delegated();
    const dup = await paidRow(catalogId, owner.id, { note: 'DUPLICATE_SUSPECTED' });
    const res = await request(app)
      .post(refundPath(catalogId))
      .set(admin.auth)
      .send({ refundsPaymentId: String(dup._id), note: 'Charged twice on 12 Sep' });
    expect(res.status).toBe(503);
    expect(await PaymentRecord.countDocuments({ kind: 'REFUNDED' })).toBe(0);
  });
});

describe('GET /admin/subscriptions', () => {
  it('lists only the requested state, soonest first, paginated', async () => {
    const admin = await makeUser('ADMIN');
    const now = Date.now();
    const grace: Types.ObjectId[] = [];
    for (let i = 0; i < 5; i++) {
      const owner = await makeUser();
      const catalogId = await seedCatalog(owner.id);
      await Catalog.updateOne({ _id: catalogId }, { $set: { name: `grace_cafe_${i}` } });
      await seedSubscription(catalogId, owner.id, 'GRACE', {
        planId: 'TASTE',
        periodEnd: new Date(now - (i + 1) * DAY_MS),
        graceEndsAt: new Date(now + (5 - i) * DAY_MS),
      });
      grace.push(catalogId);
    }
    const active = await makeUser();
    await seedSubscription(await seedCatalog(active.id), active.id, 'ACTIVE');
    const paused = await makeUser();
    await seedSubscription(await seedCatalog(paused.id), paused.id, 'PAUSED');

    const page1 = await request(app)
      .get('/admin/subscriptions?state=GRACE&limit=3')
      .set(admin.auth);
    expect(page1.status).toBe(200);
    expect(page1.body.items).toHaveLength(3);
    expect(page1.body.nextCursor).toBeTypeOf('string');
    // periodEnd ascending: the oldest lapse first.
    expect(page1.body.items.map((i: { catalogName: string }) => i.catalogName)).toEqual([
      'grace cafe 4',
      'grace cafe 3',
      'grace cafe 2',
    ]);
    expect(page1.body.items[0]).toMatchObject({
      catalogId: grace[4].toHexString(),
      status: 'GRACE',
      planId: 'TASTE',
      daysLeft: 1,
    });
    expect(page1.body.items[0].graceEndsAt).not.toBeNull();

    const page2 = await request(app)
      .get(`/admin/subscriptions?state=GRACE&limit=3&cursor=${page1.body.nextCursor}`)
      .set(admin.auth);
    expect(page2.body.items.map((i: { catalogName: string }) => i.catalogName)).toEqual([
      'grace cafe 1',
      'grace cafe 0',
    ]);
    expect(page2.body.nextCursor).toBeNull();

    const pausedList = await request(app).get('/admin/subscriptions?state=PAUSED').set(admin.auth);
    expect(pausedList.body.items).toHaveLength(1);
    expect(pausedList.body.items[0].daysLeft).toBeNull();
    expect(JSON.stringify(page1.body)).not.toMatch(/phone|email/);
  });

  it('EXPIRING_7D is anything about to lapse within a week', async () => {
    const admin = await makeUser('ADMIN');
    const soon = await makeUser();
    await seedSubscription(await seedCatalog(soon.id), soon.id, 'ACTIVE', {
      periodEnd: new Date(Date.now() + 3 * DAY_MS),
    });
    const later = await makeUser();
    await seedSubscription(await seedCatalog(later.id), later.id, 'ACTIVE', {
      periodEnd: new Date(Date.now() + 20 * DAY_MS),
    });
    const res = await request(app).get('/admin/subscriptions?state=EXPIRING_7D').set(admin.auth);
    expect(res.body.items).toHaveLength(1);
    expect(res.body.items[0].daysLeft).toBe(3);
  });

  it('is ADMIN only and strict about the query', async () => {
    const artist = await makeUser('MODEL_ARTIST');
    expect(
      (await request(app).get('/admin/subscriptions?state=GRACE').set(artist.auth)).status
    ).toBe(403);
    const admin = await makeUser('ADMIN');
    expect((await request(app).get('/admin/subscriptions').set(admin.auth)).status).toBe(400);
    // An unknown state is refused. (ALL became a real segment in Sept 2026 —
    // tests/subscription-payment-journal.test.ts covers it.)
    expect(
      (await request(app).get('/admin/subscriptions?state=EVERYTHING').set(admin.auth)).status
    ).toBe(400);
    expect(
      (await request(app).get('/admin/subscriptions?state=GRACE&cursor=nope').set(admin.auth))
        .status
    ).toBe(400);
  });
});

describe('GET /admin/catalogs/:id/subscription', () => {
  it('answers the status DTO plus the ledger with admin columns, ADMIN only', async () => {
    const { admin, rep, owner, catalogId } = await delegated();
    await seedSubscription(catalogId, owner.id, 'ACTIVE', { planId: 'TASTE' });
    const dup = await paidRow(catalogId, owner.id, { note: 'DUPLICATE_SUSPECTED' });
    const paid = await paidRow(catalogId, owner.id);

    const res = await request(app).get(`/admin/catalogs/${catalogId}/subscription`).set(admin.auth);
    expect(res.status).toBe(200);
    expect(res.body.catalog).toMatchObject({ id: catalogId.toHexString(), deleted: false });
    expect(res.body.subscription).toMatchObject({ status: 'ACTIVE', planId: 'TASTE' });
    const byId = new Map(
      (res.body.payments as { id: string }[]).map((p) => [p.id, p as Record<string, unknown>])
    );
    expect(byId.get(String(dup._id))).toMatchObject({
      kind: 'PAID',
      note: 'DUPLICATE_SUSPECTED',
      isRefundable: true,
      initiatedBy: { userId: String(owner.id), role: 'USER' },
    });
    expect(byId.get(String(paid._id))).toMatchObject({ note: null, isRefundable: true });
    expect(JSON.stringify(res.body)).not.toMatch(/phone|email|authUid/);

    expect(
      (await request(app).get(`/admin/catalogs/${catalogId}/subscription`).set(rep.auth)).status
    ).toBe(403);
  });

  it('after a refund the PAID row is no longer refundable; a gone catalog still shows its ledger', async () => {
    const { admin, owner, catalogId } = await delegated();
    const dup = await paidRow(catalogId, owner.id, { note: 'DUPLICATE_SUSPECTED' });
    await request(app)
      .post(refundPath(catalogId))
      .set(admin.auth)
      .send({ refundsPaymentId: String(dup._id), note: 'Charged twice on 12 Sep' })
      .expect(201);
    await Catalog.deleteOne({ _id: catalogId });

    const res = await request(app).get(`/admin/catalogs/${catalogId}/subscription`).set(admin.auth);
    expect(res.status).toBe(200);
    expect(res.body.catalog.deleted).toBe(true);
    expect(res.body.subscription).toBeNull();
    const rows = res.body.payments as {
      id: string;
      kind: string;
      isRefundable: boolean;
      refundsPaymentId: string | null;
    }[];
    expect(rows.find((r) => r.id === String(dup._id))!.isRefundable).toBe(false);
    expect(rows.find((r) => r.kind === 'REFUNDED')!.refundsPaymentId).toBe(String(dup._id));

    const unknown = await request(app)
      .get(`/admin/catalogs/${new Types.ObjectId()}/subscription`)
      .set(admin.auth);
    expect(unknown.status).toBe(404);
  });
});

describe('applyPaidPeriod — who may call it', () => {
  it('is imported only by the webhook service and the manual-payment service', () => {
    const src = path.resolve(__dirname, '..', 'src');
    const callers: string[] = [];
    const walk = (dir: string): void => {
      for (const entry of readdirSync(dir)) {
        const full = path.join(dir, entry);
        if (statSync(full).isDirectory()) walk(full);
        else if (full.endsWith('.ts') && /\bapplyPaidPeriod\b/.test(readFileSync(full, 'utf8'))) {
          callers.push(path.relative(src, full).split(path.sep).join('/'));
        }
      }
    };
    walk(src);
    expect(callers.sort()).toEqual([
      'services/subscription/manualPaymentService.ts',
      'services/subscription/subscriptionService.ts',
      'services/subscription/webhookService.ts',
    ]);
  });
});
