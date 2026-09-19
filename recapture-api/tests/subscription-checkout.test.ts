// tests/subscription-checkout.test.ts
//
// Door 2, the order half. What this file most exists to pin:
//   • ONE OPEN ORDER PER CATALOG: a second call within the TTL returns the
//     same providerOrderId (a double-tap is one order), and only a FRESH order
//     spends the rate window (E8).
//   • THE BODY IS IDS AND AMOUNTS, NO URL (AC-7.1); the yearly quote is the
//     AC-8.1 formula; the price never comes from the client.
//   • NO ROUTE ON /rep. A rep collects cash; a rep does not tap Pay.
//   • Without RAZORPAY_* (or with Razorpay down) the answer is 503, never 500 (D7).
import { describe, it, expect, beforeAll, afterAll, beforeEach, afterEach, vi } from 'vitest';
import request from 'supertest';
import mongoose from 'mongoose';
import { MongoMemoryServer } from 'mongodb-memory-server';

import { createApp } from '@/app';
import { env } from '@/config/env';
import { Catalog } from '@/models/Catalog';
import { CatalogDelegation } from '@/models/CatalogDelegation';
import { CatalogSubscription } from '@/models/CatalogSubscription';
import { PaymentRecord } from '@/models/PaymentRecord';
import { RateWindow } from '@/models/RateWindow';
import { User } from '@/models/User';
import { PLAN_IDS, yearlyPricePaise } from '@/models/types/subscription.types';
import { DEFAULT_PLAN_CATALOG } from '@/config/subscriptionPlans';
import {
  resetRazorpayClient,
  setRazorpayClient,
  setRazorpayConfiguredForTests,
} from '@/providers/razorpay';
import {
  DAY_MS,
  delegated,
  emitted,
  fakeRazorpay,
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
  setRazorpayConfiguredForTests(null);
  await Promise.all([
    User.deleteMany({}),
    Catalog.deleteMany({}),
    CatalogDelegation.deleteMany({}),
    CatalogSubscription.deleteMany({}),
    PaymentRecord.deleteMany({}),
    RateWindow.deleteMany({}),
  ]);
});

const ORDER = '/catalog/subscription/order';

describe('POST /catalog/subscription/order', () => {
  it('mints one order, freezes the quote for 24 h, and returns ids only (AC-7.1)', async () => {
    const { owner, catalogId } = await delegated();

    const res = await request(app)
      .post(ORDER)
      .set(owner.auth)
      .send({ planId: 'SIGNATURE', interval: 'MONTHLY' });

    expect(res.status).toBe(201);
    expect(res.body.status).toBe('success');
    const order = res.body.order;
    expect(order).toMatchObject({
      providerOrderId: expect.stringMatching(/^order_test_\d+$/),
      amountPaise: 179_900,
      currency: 'INR',
      keyId: env.RAZORPAY_KEY_ID,
      quote: { planId: 'SIGNATURE', interval: 'MONTHLY', totalPaise: 179_900 },
      currentPeriodEnd: null,
      daysForfeited: 0,
    });
    expect(order.quote.planSnapshot.includedStandeeCount).toBe(15);
    // No URL anywhere in the body: the SDK opens in-app from the ids.
    expect(JSON.stringify(res.body)).not.toMatch(/https?:\/\//);
    expect(JSON.stringify(res.body)).not.toContain(env.RAZORPAY_KEY_SECRET);

    const row = await PaymentRecord.findOne({ catalogId }).lean().exec();
    expect(row).toMatchObject({
      kind: 'CHECKOUT_CREATED',
      providerOrderId: order.providerOrderId,
      idempotencyKey: `order:${order.providerOrderId}`,
      amountPaise: 179_900,
    });
    const ttlMs = row!.expiresAt!.getTime() - row!.createdAt.getTime();
    expect(Math.abs(ttlMs - 24 * 3_600_000)).toBeLessThan(5_000);
    expect(String(row!.initiatedBy.userId)).toBe(String(owner.id));

    expect(emitted('subscription_order_created')).toEqual([
      expect.objectContaining({ plan_id: 'SIGNATURE', interval: 'MONTHLY', reused: false }),
    ]);
  });

  it('hands the open order back on a second call — even for a different plan (A1)', async () => {
    const { owner } = await delegated();
    const first = await request(app)
      .post(ORDER)
      .set(owner.auth)
      .send({ planId: 'TASTE', interval: 'MONTHLY' })
      .expect(201);

    const second = await request(app)
      .post(ORDER)
      .set(owner.auth)
      .send({ planId: 'MASTERCHEF', interval: 'YEARLY' });

    expect(second.status).toBe(200);
    expect(second.headers['x-order-reused']).toBe('1');
    expect(second.body.order.providerOrderId).toBe(first.body.order.providerOrderId);
    expect(second.body.order.quote.planId).toBe('TASTE');
    expect(await PaymentRecord.countDocuments({ kind: 'CHECKOUT_CREATED' })).toBe(1);
    expect(emitted('subscription_order_created').map((e) => e.reused)).toEqual([false, true]);
  });

  it('spends the rate window only on a FRESH order, never on a reuse (E8)', async () => {
    const { owner } = await delegated();
    for (let i = 0; i < 12; i++) {
      const res = await request(app)
        .post(ORDER)
        .set(owner.auth)
        .send({ planId: 'TASTE', interval: 'MONTHLY' });
      expect(res.status).toBe(i === 0 ? 201 : 200);
    }
    const window = await RateWindow.findOne({ key: /^checkout:/ })
      .lean()
      .exec();
    expect(window?.count).toBe(1);
  });

  it('quotes the yearly price as round(monthly × 12 × 0.70) for every plan (AC-8.1)', async () => {
    for (const planId of PLAN_IDS) {
      const { owner } = await delegated();
      const res = await request(app)
        .post(ORDER)
        .set(owner.auth)
        .send({ planId, interval: 'YEARLY' })
        .expect(201);
      const plan = DEFAULT_PLAN_CATALOG.plans[planId];
      const expected = Math.round(plan.priceMonthlyPaise * 12 * 0.7);
      expect(res.body.order.quote.totalPaise).toBe(expected);
      expect(res.body.order.amountPaise).toBe(yearlyPricePaise(plan));
    }
  });

  it('tells the owner how many days a payment now would forfeit (E9)', async () => {
    const { owner, catalogId } = await delegated();
    await seedSubscription(catalogId, owner.id, 'ACTIVE', {
      periodEnd: new Date(Date.now() + 10 * DAY_MS),
    });
    const res = await request(app)
      .post(ORDER)
      .set(owner.auth)
      .send({ planId: 'TASTE', interval: 'MONTHLY' })
      .expect(201);
    expect(res.body.order.daysForfeited).toBe(10);
    expect(res.body.order.currentPeriodEnd).not.toBeNull();

    // GRACE forfeits nothing.
    await CatalogSubscription.updateOne({ catalogId }, { $set: { status: 'GRACE' } });
    await PaymentRecord.deleteMany({});
    const grace = await request(app)
      .post(ORDER)
      .set(owner.auth)
      .send({ planId: 'TASTE', interval: 'MONTHLY' })
      .expect(201);
    expect(grace.body.order.daysForfeited).toBe(0);
  });

  it('answers 503 PAYMENTS_UNAVAILABLE without RAZORPAY_* — and writes nothing', async () => {
    setRazorpayConfiguredForTests(false);
    const { owner } = await delegated();
    const res = await request(app)
      .post(ORDER)
      .set(owner.auth)
      .send({ planId: 'TASTE', interval: 'MONTHLY' });
    expect(res.status).toBe(503);
    expect(res.body).toMatchObject({ status: 'error', code: 'PAYMENTS_UNAVAILABLE' });
    expect(await PaymentRecord.countDocuments({})).toBe(0);
  });

  it('answers 503, never 500, when Razorpay is unreachable (D7)', async () => {
    setRazorpayClient(
      fakeRazorpay({
        createOrder: async () => {
          throw new Error('ECONNRESET');
        },
      })
    );
    const { owner } = await delegated();
    const res = await request(app)
      .post(ORDER)
      .set(owner.auth)
      .send({ planId: 'TASTE', interval: 'MONTHLY' });
    expect(res.status).toBe(503);
    expect(res.body.code).toBe('PAYMENTS_UNAVAILABLE');
    expect(await PaymentRecord.countDocuments({})).toBe(0);
  });

  it('refuses a price, an unknown plan, or an extra key in the body', async () => {
    const { owner } = await delegated();
    for (const body of [
      { planId: 'TASTE', interval: 'MONTHLY', amountPaise: 1 },
      { planId: 'FREE', interval: 'MONTHLY' },
      { planId: 'TASTE' },
    ]) {
      const res = await request(app).post(ORDER).set(owner.auth).send(body);
      expect(res.status).toBe(400);
      expect(res.body.code).toBe('INVALID_REQUEST');
    }
  });

  it('404s for a user with no catalog, and has no twin on /rep (AC-6.5)', async () => {
    const { rep, catalogId } = await delegated();
    const noCatalog = await request(app)
      .post(ORDER)
      .set(rep.auth)
      .send({ planId: 'TASTE', interval: 'MONTHLY' });
    expect(noCatalog.status).toBe(404);

    const viaRep = await request(app)
      .post(`/rep/catalogs/${catalogId}/subscription/order`)
      .set(rep.auth)
      .send({ planId: 'TASTE', interval: 'MONTHLY' });
    expect(viaRep.status).toBe(404);
    expect(await PaymentRecord.countDocuments({})).toBe(0);
  });
});

describe('GET /catalog/subscription/payments', () => {
  it('lists the ledger newest first with a receipt number, refunds included', async () => {
    const { owner, catalogId } = await delegated();
    const opened = await request(app)
      .post(ORDER)
      .set(owner.auth)
      .send({ planId: 'TASTE', interval: 'MONTHLY' })
      .expect(201);
    const paid = await PaymentRecord.create({
      catalogId,
      userId: owner.id,
      kind: 'PAID',
      amountPaise: 119_900,
      providerOrderId: opened.body.order.providerOrderId,
      providerPaymentId: 'pay_1',
      quote: {
        planId: 'TASTE',
        interval: 'MONTHLY',
        totalPaise: 119_900,
        planSnapshot: DEFAULT_PLAN_CATALOG.plans.TASTE,
      },
      initiatedBy: { userId: owner.id, role: 'USER' },
      appliedAt: new Date(),
      createdAt: new Date(Date.now() + 1000),
    });
    await PaymentRecord.create({
      catalogId,
      userId: owner.id,
      kind: 'REFUNDED',
      amountPaise: 119_900,
      providerPaymentId: 'pay_1',
      providerRefundId: 'rfnd_1',
      refundsPaymentId: paid._id,
      initiatedBy: { userId: owner.id, role: 'ADMIN' },
      note: 'duplicate',
      createdAt: new Date(Date.now() + 2000),
    });

    const res = await request(app).get('/catalog/subscription/payments').set(owner.auth);
    expect(res.status).toBe(200);
    expect(res.body.payments.map((p: { kind: string }) => p.kind)).toEqual([
      'REFUNDED',
      'PAID',
      'CHECKOUT_CREATED',
    ]);
    const paidDto = res.body.payments[1];
    expect(paidDto).toMatchObject({
      amountPaise: 119_900,
      currency: 'INR',
      planId: 'TASTE',
      interval: 'MONTHLY',
      method: null,
      verificationStatus: null,
    });
    expect(paidDto.receiptNo).toBe(`RC-${String(paid._id).slice(-8).toUpperCase()}`);
    // Nothing internal leaks: no provider ids, no snapshot, no admin note.
    expect(JSON.stringify(res.body)).not.toMatch(/pay_1|rfnd_1|planSnapshot|"note"/);
  });
});
