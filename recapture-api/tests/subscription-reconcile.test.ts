// tests/subscription-reconcile.test.ts
//
// The safety net under the webhook. What this file most exists to pin:
//   • A PAID row whose Phase 2 died is finished on the next run, with no
//     provider call (E2).
//   • An open order Razorpay says is paid gets recorded as if the webhook
//     had delivered — and a webhook that then arrives late converges on the
//     same idempotency key: one row, one activation.
//   • An order that expired but settled late (a UPI collect) is honoured for
//     48 h (E7).
//   • Two consecutive runs that rescue payments raise WEBHOOKS_SILENT (E4).
//   • Without RAZORPAY_*, nothing is scanned.
import { describe, it, expect, beforeAll, afterAll, beforeEach, afterEach, vi } from 'vitest';
import request from 'supertest';
import mongoose from 'mongoose';
import { MongoMemoryServer } from 'mongodb-memory-server';

import { createApp } from '@/app';
import { Catalog } from '@/models/Catalog';
import { CatalogDelegation } from '@/models/CatalogDelegation';
import { CatalogSubscription } from '@/models/CatalogSubscription';
import { Notification } from '@/models/Notification';
import { PaymentRecord } from '@/models/PaymentRecord';
import { RateWindow } from '@/models/RateWindow';
import { User } from '@/models/User';
import { DEFAULT_PLAN_CATALOG } from '@/config/subscriptionPlans';
import {
  resetRazorpayClient,
  setRazorpayClient,
  setRazorpayConfiguredForTests,
} from '@/providers/razorpay';
import {
  HALF_APPLIED_AFTER_MS,
  OPEN_ORDER_CHECK_AFTER_MS,
  reconcileOpenOrders,
  resetOnReadSettleState,
  resetReconcileState,
} from '@/services/subscription/reconcileService';
import {
  DAY_MS,
  delegated,
  emitted,
  fakeRazorpay,
  paymentCaptured,
  signedWebhook,
  type Auth,
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
  vi.spyOn(console, 'error').mockImplementation(() => {});
  resetReconcileState();
  resetOnReadSettleState();
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
    Notification.deleteMany({}),
  ]);
});

const MONTHLY = DEFAULT_PLAN_CATALOG.plans.TASTE.priceMonthlyPaise;

async function openOrder(auth: Auth): Promise<string> {
  const res = await request(app)
    .post('/catalog/subscription/order')
    .set(auth)
    .send({ planId: 'TASTE', interval: 'MONTHLY' });
  expect([200, 201]).toContain(res.status);
  return res.body.order.providerOrderId as string;
}

/** Ages a checkout row so it is old enough for the reconciler to look at. */
async function ageOrder(orderId: string, ageMs: number, expiresAt?: Date): Promise<void> {
  // Straight to the driver: `createdAt` is immutable through Mongoose.
  await PaymentRecord.collection.updateOne(
    { kind: 'CHECKOUT_CREATED', providerOrderId: orderId },
    { $set: { createdAt: new Date(Date.now() - ageMs), ...(expiresAt ? { expiresAt } : {}) } }
  );
}

/** A provider that reports these orders as paid, by one captured payment each. */
function providerWithPaid(paid: Record<string, { paymentId: string; amount: number }>) {
  return fakeRazorpay({
    fetchOrder: vi.fn(async (orderId: string) => ({
      id: orderId,
      status: orderId in paid ? ('paid' as const) : ('created' as const),
      amount: paid[orderId]?.amount ?? 0,
    })),
    fetchPaymentsForOrder: vi.fn(async (orderId: string) =>
      orderId in paid
        ? [
            { id: 'pay_failed_first', status: 'failed', amount: paid[orderId].amount },
            { id: paid[orderId].paymentId, status: 'captured', amount: paid[orderId].amount },
          ]
        : []
    ),
  });
}

describe('reconcileOpenOrders', () => {
  it('does nothing without RAZORPAY_*', async () => {
    setRazorpayConfiguredForTests(false);
    const client = fakeRazorpay();
    setRazorpayClient(client);
    const report = await reconcileOpenOrders();
    expect(report.skipped).toBe(true);
    expect(client.fetchOrder).not.toHaveBeenCalled();
  });

  it('scan 1: finishes a PAID row whose apply died, without a provider call (E2)', async () => {
    const client = fakeRazorpay();
    setRazorpayClient(client);
    const { owner, catalogId } = await delegated();
    const orderId = await openOrder(owner.auth);
    // Phase 1 landed, Phase 2 never ran — and it is older than the grace window.
    await PaymentRecord.create({
      catalogId,
      userId: owner.id,
      kind: 'PAID',
      amountPaise: MONTHLY,
      quote: {
        planId: 'TASTE',
        interval: 'MONTHLY',
        totalPaise: MONTHLY,
        planSnapshot: DEFAULT_PLAN_CATALOG.plans.TASTE,
      },
      providerOrderId: orderId,
      providerPaymentId: 'pay_half',
      idempotencyKey: 'payment:pay_half',
      initiatedBy: { userId: owner.id, role: 'USER' },
      appliedAt: null,
      createdAt: new Date(Date.now() - HALF_APPLIED_AFTER_MS - 1000),
    });
    // A fresh half-applied row (a request in flight right now) is left alone.
    await PaymentRecord.create({
      catalogId,
      userId: owner.id,
      kind: 'PAID',
      amountPaise: MONTHLY,
      providerPaymentId: 'pay_fresh',
      idempotencyKey: 'payment:pay_fresh',
      initiatedBy: { userId: owner.id, role: 'USER' },
      appliedAt: null,
    });

    const report = await reconcileOpenOrders();

    expect(report.reapplied).toBe(1);
    expect(report.rescuedByReconcile).toBe(0);
    expect(client.fetchOrder).not.toHaveBeenCalled();
    const row = await CatalogSubscription.findOne({ catalogId }).lean().exec();
    expect(row).toMatchObject({ status: 'ACTIVE', planId: 'TASTE' });
    const half = await PaymentRecord.findOne({ providerPaymentId: 'pay_half' }).lean().exec();
    expect(half!.appliedAt).toBeInstanceOf(Date);
    const fresh = await PaymentRecord.findOne({ providerPaymentId: 'pay_fresh' }).lean().exec();
    expect(fresh!.appliedAt).toBeNull();
    expect(emitted('subscription_payment_recorded')).toEqual([
      expect.objectContaining({ via: 'RECONCILE' }),
    ]);
  });

  it('scan 2: records an open order Razorpay says is paid, and a late webhook converges on it', async () => {
    const { owner, catalogId } = await delegated();
    const orderId = await openOrder(owner.auth);
    await ageOrder(orderId, OPEN_ORDER_CHECK_AFTER_MS + 1000);
    setRazorpayClient(
      providerWithPaid({ [orderId]: { paymentId: 'pay_rescued', amount: MONTHLY } })
    );

    const report = await reconcileOpenOrders();

    expect(report.checkedAtProvider).toBe(1);
    expect(report.rescuedByReconcile).toBe(1);
    const row = await CatalogSubscription.findOne({ catalogId }).lean().exec();
    expect(row!.status).toBe('ACTIVE');
    const paid = await PaymentRecord.findOne({ kind: 'PAID' }).lean().exec();
    expect(paid).toMatchObject({
      providerPaymentId: 'pay_rescued',
      idempotencyKey: 'payment:pay_rescued',
    });
    // The failed attempt on the same order was not recorded.
    expect(await PaymentRecord.countDocuments({ kind: 'PAID' })).toBe(1);

    // The webhook shows up afterwards — same payment id, same key, no change.
    const signed = signedWebhook(
      paymentCaptured({ orderId, paymentId: 'pay_rescued', amountPaise: MONTHLY })
    );
    await request(app)
      .post('/webhooks/razorpay')
      .set('Content-Type', 'application/json')
      .set('X-Razorpay-Signature', signed.signature)
      .send(signed.body)
      .expect(200);
    expect(await PaymentRecord.countDocuments({ kind: 'PAID' })).toBe(1);
    const again = await CatalogSubscription.findOne({ catalogId }).lean().exec();
    expect(again!.periodStart.getTime()).toBe(row!.periodStart.getTime());
    expect(emitted('subscription_payment_recorded')).toHaveLength(1);
  });

  it('leaves an order younger than five minutes alone', async () => {
    const { owner } = await delegated();
    const orderId = await openOrder(owner.auth);
    const client = providerWithPaid({ [orderId]: { paymentId: 'pay_young', amount: MONTHLY } });
    setRazorpayClient(client);

    const report = await reconcileOpenOrders();

    expect(report.checkedAtProvider).toBe(0);
    expect(client.fetchOrder).not.toHaveBeenCalled();
  });

  it('scan 3: an order that expired but settled late within 48 h is honoured (E7)', async () => {
    const { owner, catalogId } = await delegated();
    const orderId = await openOrder(owner.auth);
    await ageOrder(orderId, 30 * 3_600_000, new Date(Date.now() - 6 * 3_600_000));
    setRazorpayClient(providerWithPaid({ [orderId]: { paymentId: 'pay_late', amount: MONTHLY } }));

    const report = await reconcileOpenOrders();

    expect(report.rescuedByReconcile).toBe(1);
    expect((await CatalogSubscription.findOne({ catalogId }).lean().exec())!.status).toBe('ACTIVE');

    // Once settled it is not asked about again.
    const client = providerWithPaid({ [orderId]: { paymentId: 'pay_late', amount: MONTHLY } });
    setRazorpayClient(client);
    const second = await reconcileOpenOrders();
    expect(second.checkedAtProvider).toBe(0);
    expect(client.fetchOrder).not.toHaveBeenCalled();
  });

  it('ignores an order that expired more than 48 h ago', async () => {
    const { owner } = await delegated();
    const orderId = await openOrder(owner.auth);
    await ageOrder(orderId, 4 * DAY_MS, new Date(Date.now() - 3 * DAY_MS));
    const client = providerWithPaid({ [orderId]: { paymentId: 'pay_old', amount: MONTHLY } });
    setRazorpayClient(client);

    const report = await reconcileOpenOrders();
    expect(report.checkedAtProvider).toBe(0);
    expect(client.fetchOrder).not.toHaveBeenCalled();
  });

  it('a provider error on one order does not stop the others', async () => {
    const a = await delegated();
    const b = await delegated();
    const orderA = await openOrder(a.owner.auth);
    const orderB = await openOrder(b.owner.auth);
    await ageOrder(orderA, OPEN_ORDER_CHECK_AFTER_MS + 1000);
    await ageOrder(orderB, OPEN_ORDER_CHECK_AFTER_MS + 1000);
    const good = providerWithPaid({ [orderB]: { paymentId: 'pay_b', amount: MONTHLY } });
    setRazorpayClient(
      fakeRazorpay({
        fetchOrder: async (orderId) => {
          if (orderId === orderA) throw new Error('503 from Razorpay');
          return good.fetchOrder(orderId);
        },
        fetchPaymentsForOrder: good.fetchPaymentsForOrder,
      })
    );

    const report = await reconcileOpenOrders();
    expect(report.errors).toBe(1);
    expect(report.rescuedByReconcile).toBe(1);
    expect(
      (await CatalogSubscription.findOne({ catalogId: b.catalogId }).lean().exec())!.status
    ).toBe('ACTIVE');
    expect(await CatalogSubscription.countDocuments({ catalogId: a.catalogId })).toBe(0);
  });

  it('alerts WEBHOOKS_SILENT after two consecutive runs that rescued payments (E4)', async () => {
    const one = await delegated();
    const orderOne = await openOrder(one.owner.auth);
    await ageOrder(orderOne, OPEN_ORDER_CHECK_AFTER_MS + 1000);
    setRazorpayClient(providerWithPaid({ [orderOne]: { paymentId: 'pay_1', amount: MONTHLY } }));
    await reconcileOpenOrders();
    expect(await Notification.countDocuments({ title: /webhooks may be disabled/i })).toBe(0);

    const two = await delegated();
    const orderTwo = await openOrder(two.owner.auth);
    await ageOrder(orderTwo, OPEN_ORDER_CHECK_AFTER_MS + 1000);
    setRazorpayClient(providerWithPaid({ [orderTwo]: { paymentId: 'pay_2', amount: MONTHLY } }));
    await reconcileOpenOrders();

    await vi.waitFor(async () => {
      const alert = await Notification.findOne({ title: /webhooks may be disabled/i })
        .lean()
        .exec();
      expect(alert).not.toBeNull();
      expect(alert!.audienceType).toBe('USERS');
      // Every ADMIN, and only admins.
      expect(alert!.audienceUserIds.map(String).sort()).toEqual(
        [String(one.admin.id), String(two.admin.id)].sort()
      );
    });
  });
});

describe('settle on read: the owner read activates a paid order', () => {
  it('GET /catalog/subscription records a paid order at once, with no webhook and no worker', async () => {
    const { owner, catalogId } = await delegated();
    const orderId = await openOrder(owner.auth);
    // Seconds old — the worker's pass would still leave it alone.
    setRazorpayClient(
      providerWithPaid({ [orderId]: { paymentId: 'pay_on_read', amount: MONTHLY } })
    );

    const res = await request(app).get('/catalog/subscription').set(owner.auth).expect(200);

    expect(res.body.subscription.status).toBe('ACTIVE');
    expect(res.body.subscription.planId).toBe('TASTE');
    const row = await CatalogSubscription.findOne({ catalogId }).lean().exec();
    expect(row!.status).toBe('ACTIVE');
    expect(await PaymentRecord.countDocuments({ kind: 'PAID' })).toBe(1);
  });

  it('GET /catalog carries the ACTIVE summary on the first load after paying (sign-in)', async () => {
    const { owner } = await delegated();
    const orderId = await openOrder(owner.auth);
    setRazorpayClient(
      providerWithPaid({ [orderId]: { paymentId: 'pay_signin', amount: MONTHLY } })
    );

    const res = await request(app).get('/catalog').set(owner.auth).expect(200);

    expect(res.body.catalog.subscription.status).toBe('ACTIVE');
    expect(res.body.catalog.subscription.isEntitledTo3D).toBe(true);
  });

  it('a fresh process (tab reload, killed activity, cold start) activates on its first GET /catalog', async () => {
    const { owner, catalogId } = await delegated();
    const orderId = await openOrder(owner.auth);
    // The read before paying found nothing and armed this process's throttle.
    const unpaid = fakeRazorpay();
    setRazorpayClient(unpaid);
    const before = await request(app).get('/catalog').set(owner.auth).expect(200);
    expect(before.body.catalog.subscription.status).not.toBe('ACTIVE');

    // Paid at Razorpay; the app never called verify, no webhook, no worker —
    // and the process restarted, so its throttle is gone.
    const paid = providerWithPaid({ [orderId]: { paymentId: 'pay_cold', amount: MONTHLY } });
    setRazorpayClient(paid);
    resetOnReadSettleState();

    const res = await request(app).get('/catalog').set(owner.auth).expect(200);

    expect(res.body.catalog.subscription.status).toBe('ACTIVE');
    expect(res.body.catalog.subscription.planId).toBe('TASTE');
    expect(await PaymentRecord.countDocuments({ kind: 'PAID', catalogId })).toBe(1);
    expect(await PaymentRecord.countDocuments({ kind: 'CHECKOUT_CREATED', catalogId })).toBe(1);
  });

  it('asks the provider at most once per catalog per throttle window', async () => {
    const { owner } = await delegated();
    await openOrder(owner.auth);
    const client = fakeRazorpay();
    setRazorpayClient(client);

    await request(app).get('/catalog/subscription').set(owner.auth).expect(200);
    await request(app).get('/catalog/subscription').set(owner.auth).expect(200);
    await request(app).get('/catalog').set(owner.auth).expect(200);

    expect(client.fetchOrder).toHaveBeenCalledTimes(1);
  });

  it('fails open: a provider outage still answers the read, unchanged', async () => {
    const { owner } = await delegated();
    await openOrder(owner.auth);
    setRazorpayClient(
      fakeRazorpay({
        fetchOrder: vi.fn(async () => {
          throw new Error('razorpay down');
        }),
      })
    );

    const res = await request(app).get('/catalog/subscription').set(owner.auth).expect(200);
    expect(res.body.subscription.status).not.toBe('ACTIVE');
    expect(await PaymentRecord.countDocuments({ kind: 'PAID' })).toBe(0);
  });
});
