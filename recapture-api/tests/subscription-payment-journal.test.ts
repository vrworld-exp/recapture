// tests/subscription-payment-journal.test.ts
//
// The admin payment journal and its two fixes. What this file most exists to pin:
//   • Every order is an entry, with WHO started it and whose catalog it is —
//     names only, never contact.
//   • The five steps tell the truth: a clean payment ends CURRENT on the
//     catalog; a recorded-but-unapplied one, a flagged one and one the
//     subscription row does not show are all ATTENTION.
//   • "Check with Razorpay" runs the webhook's own functions: it records a
//     captured payment the webhook and the reconciler both missed (an order
//     expired beyond the 48 h late window), finishes a half-applied one, and
//     writes NOTHING for an order Razorpay has not captured.
//   • "Apply to catalog" is the one override: a 20-char note, flagged or
//     unreflected payments only, exactly once, and the catalog becomes ACTIVE.
//   • The collections list gains ALL, a name search, and the owner's name.
//   • Everything is ADMIN-only.
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
import { resetOnReadSettleState } from '@/services/subscription/reconcileService';
import { recordOnlinePayment } from '@/services/subscription/webhookService';
import {
  DAY_MS,
  delegated,
  emitted,
  fakeRazorpay,
  makeUser,
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
const NOTE = 'Owner paid on Razorpay, confirmed on the dashboard.';

async function openOrder(auth: Auth): Promise<string> {
  const res = await request(app)
    .post('/catalog/subscription/order')
    .set(auth)
    .send({ planId: 'TASTE', interval: 'MONTHLY' });
  expect([200, 201]).toContain(res.status);
  return res.body.order.providerOrderId as string;
}

/** A named owner, so the journal has a name to show. */
async function named() {
  const ctx = await delegated();
  await User.updateOne({ _id: ctx.owner.id }, { $set: { displayName: 'Asha Rao' } });
  await Catalog.updateOne({ _id: ctx.catalogId }, { $set: { name: 'blue_cafe' } });
  return ctx;
}

function journal(auth: Auth, filter?: string, cursor?: string) {
  return request(app)
    .get('/admin/subscriptions/payments')
    .query({ ...(filter ? { filter } : {}), ...(cursor ? { cursor } : {}) })
    .set(auth);
}

function step(attempt: { steps: { key: string; state: string }[] }, key: string) {
  return attempt.steps.find((s) => s.key === key)!;
}

describe('the journal', () => {
  it('lists an open order with who started it and whose catalog it is', async () => {
    const { owner, admin, catalogId } = await named();
    const orderId = await openOrder(owner.auth);

    const res = await journal(admin.auth, 'ALL');
    expect(res.status).toBe(200);
    expect(res.body.items).toHaveLength(1);
    const [entry] = res.body.items;
    expect(entry.orderId).toBe(orderId);
    expect(entry.catalog).toEqual({ id: catalogId.toHexString(), name: 'blue cafe', deleted: false });
    expect(entry.owner).toMatchObject({ id: owner.id.toHexString(), displayName: 'Asha Rao' });
    expect(entry.initiatedBy).toMatchObject({ role: 'USER', displayName: 'Asha Rao' });
    expect(entry.quotedPaise).toBe(MONTHLY);
    expect(entry.stage).toBe('IN_PROGRESS');
    expect(entry.needsAttention).toBe(false);
    expect(entry.canSync).toBe(true);
    expect(step(entry, 'STARTED').state).toBe('DONE');
    expect(step(entry, 'PROVIDER').state).toBe('WAITING');
    // Names only — no contact anywhere in the entry.
    expect(JSON.stringify(entry)).not.toMatch(/phone|email|@/i);

    // Not money on the ledger, so not ATTENTION.
    expect((await journal(admin.auth)).body.items).toHaveLength(0);
  });

  it('a clean payment ends CURRENT on the catalog, recorded via the webhook', async () => {
    const { owner, admin } = await named();
    const orderId = await openOrder(owner.auth);
    await recordOnlinePayment({ orderId, paymentId: 'pay_ok', amountPaise: MONTHLY, via: 'WEBHOOK' });

    const res = await request(app).get(`/admin/subscriptions/payments/${orderId}`).set(admin.auth);
    expect(res.status).toBe(200);
    const { attempt } = res.body;
    expect(attempt.stage).toBe('COMPLETED');
    expect(attempt.recordedVia).toBe('WEBHOOK');
    expect(attempt.providerPaymentId).toBe('pay_ok');
    expect(attempt.catalogReflects).toBe('CURRENT');
    expect(attempt.steps.map((s: { state: string }) => s.state)).toEqual([
      'DONE',
      'DONE',
      'DONE',
      'DONE',
      'DONE',
    ]);
    expect(attempt.canSync).toBe(false);
    expect(attempt.canForceApply).toBe(false);

    expect((await journal(admin.auth, 'SUCCEEDED')).body.items).toHaveLength(1);
    expect((await journal(admin.auth, 'ATTENTION')).body.items).toHaveLength(0);
    expect((await journal(admin.auth, 'NOT_COMPLETED')).body.items).toHaveLength(0);
  });

  it('a recorded-but-unapplied payment is ATTENTION, and Check finishes it', async () => {
    const { owner, admin, catalogId } = await named();
    const orderId = await openOrder(owner.auth);
    const checkout = await PaymentRecord.findOne({ kind: 'CHECKOUT_CREATED', providerOrderId: orderId });
    await PaymentRecord.create({
      catalogId,
      userId: owner.id,
      kind: 'PAID',
      amountPaise: MONTHLY,
      currency: 'INR',
      quote: checkout!.quote,
      providerOrderId: orderId,
      providerPaymentId: 'pay_half',
      idempotencyKey: 'payment:pay_half',
      initiatedBy: { userId: owner.id, role: 'USER' },
      recordedVia: 'WEBHOOK',
      appliedAt: null,
    });
    await PaymentRecord.collection.updateOne(
      { kind: 'PAID', providerOrderId: orderId },
      { $set: { createdAt: new Date(Date.now() - 10 * 60_000) } }
    );

    const attention = await journal(admin.auth);
    expect(attention.body.items).toHaveLength(1);
    expect(attention.body.items[0].stage).toBe('PAID_NOT_APPLIED');
    expect(step(attention.body.items[0], 'APPLIED').state).toBe('FAILED');
    expect(attention.body.items[0].canSync).toBe(true);

    const client = fakeRazorpay();
    setRazorpayClient(client);
    const sync = await request(app)
      .post(`/admin/subscriptions/payments/${orderId}/sync`)
      .set(admin.auth)
      .send({});
    expect(sync.status).toBe(200);
    expect(sync.body.result).toBe('APPLIED');
    expect(sync.body.attempt.stage).toBe('COMPLETED');
    expect(sync.body.attempt.catalogReflects).toBe('CURRENT');
    // The row already said how it came in; the sync does not rewrite it.
    expect(sync.body.attempt.recordedVia).toBe('WEBHOOK');

    const row = await CatalogSubscription.findOne({ catalogId });
    expect(row?.status).toBe('ACTIVE');
    expect((await journal(admin.auth)).body.items).toHaveLength(0);
    expect(emitted('subscription_admin_payment_fixed')[0]).toMatchObject({
      action: 'SYNC',
      outcome: 'APPLIED',
    });
  });

  it('Check records a payment everyone missed, long after the late window', async () => {
    const { owner, admin, catalogId } = await named();
    const orderId = await openOrder(owner.auth);
    // Expired a week ago — past the reconciler's 48 h window, so nothing
    // automatic will ever look at this order again.
    await PaymentRecord.collection.updateOne(
      { kind: 'CHECKOUT_CREATED', providerOrderId: orderId },
      {
        $set: {
          createdAt: new Date(Date.now() - 8 * DAY_MS),
          expiresAt: new Date(Date.now() - 7 * DAY_MS),
        },
      }
    );

    const before = (await journal(admin.auth, 'NOT_COMPLETED')).body.items;
    expect(before).toHaveLength(1);
    expect(before[0].stage).toBe('NOT_COMPLETED');
    expect(step(before[0], 'PROVIDER').state).toBe('UNKNOWN');

    setRazorpayClient(
      fakeRazorpay({
        fetchOrder: vi.fn(async (id: string) => ({ id, status: 'paid' as const, amount: MONTHLY })),
        fetchPaymentsForOrder: vi.fn(async () => [
          { id: 'pay_missed', status: 'captured', amount: MONTHLY },
        ]),
      })
    );
    const sync = await request(app)
      .post(`/admin/subscriptions/payments/${orderId}/sync`)
      .set(admin.auth)
      .send({});
    expect(sync.status).toBe(200);
    expect(sync.body.result).toBe('APPLIED');
    expect(sync.body.provider).toMatchObject({
      orderStatus: 'paid',
      payments: [{ id: 'pay_missed', status: 'captured', amountPaise: MONTHLY }],
    });
    expect(sync.body.attempt.recordedVia).toBe('ADMIN');
    expect(sync.body.attempt.stage).toBe('COMPLETED');
    expect((await CatalogSubscription.findOne({ catalogId }))?.status).toBe('ACTIVE');

    // Pressing it again changes nothing: one PAID row, one period.
    const again = await request(app)
      .post(`/admin/subscriptions/payments/${orderId}/sync`)
      .set(admin.auth)
      .send({});
    expect(again.body.result).toBe('ALREADY_DONE');
    expect(await PaymentRecord.countDocuments({ kind: 'PAID', providerOrderId: orderId })).toBe(1);
  });

  it('Check writes nothing for an order Razorpay has not captured', async () => {
    const { owner, admin, catalogId } = await named();
    const orderId = await openOrder(owner.auth);

    const unpaid = await request(app)
      .post(`/admin/subscriptions/payments/${orderId}/sync`)
      .set(admin.auth)
      .send({});
    expect(unpaid.body.result).toBe('NOT_PAID');

    setRazorpayClient(
      fakeRazorpay({
        fetchOrder: vi.fn(async (id: string) => ({ id, status: 'attempted' as const, amount: MONTHLY })),
        fetchPaymentsForOrder: vi.fn(async () => [
          { id: 'pay_auth', status: 'authorized', amount: MONTHLY },
        ]),
      })
    );
    const authorized = await request(app)
      .post(`/admin/subscriptions/payments/${orderId}/sync`)
      .set(admin.auth)
      .send({});
    expect(authorized.body.result).toBe('NOT_CAPTURED');
    expect(await PaymentRecord.countDocuments({ kind: 'PAID' })).toBe(0);
    expect(await CatalogSubscription.countDocuments({ catalogId })).toBe(0);
  });

  it('Check answers 503 when Razorpay cannot be asked and the answer is needed', async () => {
    const { owner, admin } = await named();
    const orderId = await openOrder(owner.auth);
    setRazorpayClient(
      fakeRazorpay({
        fetchOrder: vi.fn(async () => {
          throw new Error('down');
        }),
      })
    );
    const res = await request(app)
      .post(`/admin/subscriptions/payments/${orderId}/sync`)
      .set(admin.auth)
      .send({});
    expect(res.status).toBe(503);
    expect(res.body.code).toBe('PAYMENTS_UNAVAILABLE');
  });
});

describe('Apply to catalog', () => {
  async function mismatched() {
    const ctx = await named();
    const orderId = await openOrder(ctx.owner.auth);
    const { outcome } = await recordOnlinePayment({
      orderId,
      paymentId: 'pay_short',
      amountPaise: MONTHLY - 100,
      via: 'WEBHOOK',
    });
    expect(outcome).toBe('AMOUNT_MISMATCH');
    return { ...ctx, orderId };
  }

  it('a flagged payment is ATTENTION; applying it needs 20 characters', async () => {
    const { admin, orderId, catalogId } = await mismatched();
    const [entry] = (await journal(admin.auth)).body.items;
    expect(entry.stage).toBe('FLAGGED');
    expect(entry.outcomeNote).toBe('AMOUNT_MISMATCH');
    expect(entry.canForceApply).toBe(true);
    expect(step(entry, 'APPLIED').state).toBe('FAILED');

    const short = await request(app)
      .post(`/admin/subscriptions/payments/${orderId}/apply`)
      .set(admin.auth)
      .send({ note: 'ok' });
    expect(short.status).toBe(400);
    expect(await CatalogSubscription.countDocuments({ catalogId })).toBe(0);
  });

  it('applies the quoted plan once, and the entry leaves ATTENTION as RESOLVED', async () => {
    const { admin, owner, orderId, catalogId } = await mismatched();
    const res = await request(app)
      .post(`/admin/subscriptions/payments/${orderId}/apply`)
      .set(admin.auth)
      .send({ note: NOTE });
    expect(res.status).toBe(200);
    expect(res.body.attempt.stage).toBe('RESOLVED');
    expect(res.body.attempt.catalogReflects).toBe('CURRENT');
    expect(res.body.attempt.resolution).toMatchObject({ note: NOTE, by: { role: 'ADMIN' } });
    // The machine's verdict is kept beside the human's.
    expect(res.body.attempt.outcomeNote).toBe('AMOUNT_MISMATCH');

    const row = await CatalogSubscription.findOne({ catalogId });
    expect(row?.status).toBe('ACTIVE');
    expect(row?.planId).toBe('TASTE');
    expect(String(row?.userId)).toBe(owner.id.toHexString());
    expect((await journal(admin.auth)).body.items).toHaveLength(0);

    const twice = await request(app)
      .post(`/admin/subscriptions/payments/${orderId}/apply`)
      .set(admin.auth)
      .send({ note: NOTE });
    expect(twice.status).toBe(409);
    expect(twice.body.code).toBe('ALREADY_RESOLVED');
    expect(emitted('subscription_admin_payment_fixed')[0]).toMatchObject({
      action: 'FORCE_APPLY',
      outcome: 'AMOUNT_MISMATCH',
    });
  });

  it('catches a payment the subscription row does not show, and fixes it', async () => {
    const { owner, admin, catalogId } = await named();
    const orderId = await openOrder(owner.auth);
    await recordOnlinePayment({ orderId, paymentId: 'pay_lost', amountPaise: MONTHLY, via: 'CLIENT' });
    // "By any reason": the row lost the period this payment bought.
    await CatalogSubscription.collection.updateOne(
      { catalogId },
      {
        $set: {
          status: 'PAUSED',
          periodStart: new Date(Date.now() - 60 * DAY_MS),
          periodEnd: new Date(Date.now() - 30 * DAY_MS),
        },
      }
    );

    const [entry] = (await journal(admin.auth)).body.items;
    expect(entry.stage).toBe('NOT_REFLECTED');
    expect(entry.catalogReflects).toBe('NOT_REFLECTED');
    expect(step(entry, 'CATALOG').state).toBe('FAILED');
    expect(entry.canForceApply).toBe(true);

    const res = await request(app)
      .post(`/admin/subscriptions/payments/${orderId}/apply`)
      .set(admin.auth)
      .send({ note: NOTE });
    expect(res.status).toBe(200);
    expect(res.body.attempt.stage).toBe('RESOLVED');
    expect((await CatalogSubscription.findOne({ catalogId }))?.status).toBe('ACTIVE');
  });

  it('refuses a payment that was applied and is shown (NOT_NEEDED)', async () => {
    const { owner, admin } = await named();
    const orderId = await openOrder(owner.auth);
    await recordOnlinePayment({ orderId, paymentId: 'pay_fine', amountPaise: MONTHLY, via: 'WEBHOOK' });
    const res = await request(app)
      .post(`/admin/subscriptions/payments/${orderId}/apply`)
      .set(admin.auth)
      .send({ note: NOTE });
    expect(res.status).toBe(409);
    expect(res.body.code).toBe('NOT_NEEDED');
  });

  it('a refunded flagged payment is no longer ATTENTION and cannot be applied', async () => {
    const { admin, orderId, catalogId } = await mismatched();
    const paid = await PaymentRecord.findOne({ kind: 'PAID', providerOrderId: orderId });
    const refund = await request(app)
      .post(`/admin/catalogs/${catalogId.toHexString()}/subscription/refund`)
      .set(admin.auth)
      .send({ refundsPaymentId: String(paid!._id), note: NOTE, override: true });
    expect(refund.status).toBe(201);

    expect((await journal(admin.auth)).body.items).toHaveLength(0);
    const res = await request(app)
      .post(`/admin/subscriptions/payments/${orderId}/apply`)
      .set(admin.auth)
      .send({ note: NOTE });
    expect(res.body.code).toBe('ALREADY_REFUNDED');
  });

  it('an unknown order is a 404 on every route', async () => {
    const { admin } = await named();
    const base = '/admin/subscriptions/payments';
    expect((await request(app).get(`${base}/order_nope`).set(admin.auth)).status).toBe(404);
    expect((await request(app).get(`${base}/bad%20id`).set(admin.auth)).status).toBe(404);
    expect(
      (await request(app).post(`${base}/order_nope/sync`).set(admin.auth).send({})).status
    ).toBe(404);
    expect(
      (await request(app).post(`${base}/order_nope/apply`).set(admin.auth).send({ note: NOTE }))
        .status
    ).toBe(404);
  });
});

describe('the fix gives exactly the plan and days that were paid for', () => {
  /** An order for any plan; answers the id and the amount Razorpay was asked for. */
  async function orderFor(auth: Auth, planId: string, interval: string) {
    const res = await request(app)
      .post('/catalog/subscription/order')
      .set(auth)
      .send({ planId, interval });
    expect([200, 201]).toContain(res.status);
    return {
      orderId: res.body.order.providerOrderId as string,
      amountPaise: res.body.order.amountPaise as number,
    };
  }

  /** The catalog is already on TASTE monthly, started well before the new order. */
  async function onTaste(catalogId: unknown, ownerId: unknown) {
    const now = Date.now();
    await CatalogSubscription.create({
      catalogId,
      userId: ownerId,
      status: 'ACTIVE',
      source: 'ONLINE',
      planId: 'TASTE',
      planSnapshot: DEFAULT_PLAN_CATALOG.plans.TASTE,
      billingInterval: 'MONTHLY',
      periodStart: new Date(now - 20 * DAY_MS),
      periodEnd: new Date(now + 10 * DAY_MS),
      threeDDishCap: DEFAULT_PLAN_CATALOG.plans.TASTE.threeDDishCap,
      standeeAllocation: { included: 0, issued: 0 },
    });
  }

  async function expectPlan(catalogId: unknown, planId: 'SIGNATURE' | 'MASTERCHEF', interval: string) {
    const plan = DEFAULT_PLAN_CATALOG.plans[planId];
    const row = await CatalogSubscription.findOne({ catalogId }).lean().exec();
    expect(row).toMatchObject({
      status: 'ACTIVE',
      planId,
      billingInterval: interval,
      threeDDishCap: plan.threeDDishCap,
    });
    expect(row!.planSnapshot?.displayName).toBe(plan.displayName);
    expect(row!.standeeAllocation.included).toBe(plan.includedStandeeCount);
    const days = (row!.periodEnd.getTime() - row!.periodStart.getTime()) / DAY_MS;
    expect(days).toBe(interval === 'YEARLY' ? 365 : 30);
    // The period starts at the fix, so the owner loses none of the days paid for.
    expect(Math.abs(row!.periodStart.getTime() - Date.now())).toBeLessThan(60_000);
  }

  it('Check with Razorpay: paid SIGNATURE yearly on a TASTE catalog → SIGNATURE, 365 days', async () => {
    const { owner, admin, catalogId } = await named();
    await onTaste(catalogId, owner.id);
    const { orderId, amountPaise } = await orderFor(owner.auth, 'SIGNATURE', 'YEARLY');
    // Past the reconciler's window: only the admin's check will ever find it.
    await PaymentRecord.collection.updateOne(
      { kind: 'CHECKOUT_CREATED', providerOrderId: orderId },
      {
        $set: {
          createdAt: new Date(Date.now() - 5 * DAY_MS),
          expiresAt: new Date(Date.now() - 4 * DAY_MS),
        },
      }
    );
    setRazorpayClient(
      fakeRazorpay({
        fetchOrder: vi.fn(async (id: string) => ({ id, status: 'paid' as const, amount: amountPaise })),
        fetchPaymentsForOrder: vi.fn(async () => [
          { id: 'pay_sig', status: 'captured', amount: amountPaise },
        ]),
      })
    );

    const res = await request(app)
      .post(`/admin/subscriptions/payments/${orderId}/sync`)
      .set(admin.auth)
      .send({});
    expect(res.body.result).toBe('APPLIED');
    await expectPlan(catalogId, 'SIGNATURE', 'YEARLY');
  });

  it('Apply to catalog: paid MASTERCHEF monthly (flagged) on a TASTE catalog → MASTERCHEF, 30 days', async () => {
    const { owner, admin, catalogId } = await named();
    await onTaste(catalogId, owner.id);
    const { orderId, amountPaise } = await orderFor(owner.auth, 'MASTERCHEF', 'MONTHLY');
    const { outcome } = await recordOnlinePayment({
      orderId,
      paymentId: 'pay_mc',
      amountPaise: amountPaise - 100,
      via: 'WEBHOOK',
    });
    expect(outcome).toBe('AMOUNT_MISMATCH');
    // Held back: the catalog is still on TASTE.
    expect((await CatalogSubscription.findOne({ catalogId }))?.planId).toBe('TASTE');

    const res = await request(app)
      .post(`/admin/subscriptions/payments/${orderId}/apply`)
      .set(admin.auth)
      .send({ note: NOTE });
    expect(res.status).toBe(200);
    await expectPlan(catalogId, 'MASTERCHEF', 'MONTHLY');
  });

  it('a later price change does not change what an old payment buys', async () => {
    const { owner, admin, catalogId } = await named();
    const { orderId, amountPaise } = await orderFor(owner.auth, 'SIGNATURE', 'MONTHLY');
    await recordOnlinePayment({ orderId, paymentId: 'pay_old', amountPaise, via: 'WEBHOOK' });
    // The quote on the ledger is the plan as it was sold; tamper the live
    // row so the payment is "not reflected" and must be applied by hand.
    await CatalogSubscription.collection.updateOne(
      { catalogId },
      { $set: { periodStart: new Date(Date.now() - 40 * DAY_MS), planId: 'TASTE' } }
    );
    const paid = await PaymentRecord.findOne({ kind: 'PAID', providerOrderId: orderId }).lean();
    expect(paid!.quote!.planId).toBe('SIGNATURE');
    expect(paid!.quote!.totalPaise).toBe(amountPaise);

    const res = await request(app)
      .post(`/admin/subscriptions/payments/${orderId}/apply`)
      .set(admin.auth)
      .send({ note: NOTE });
    expect(res.status).toBe(200);
    await expectPlan(catalogId, 'SIGNATURE', 'MONTHLY');
  });
});

describe('the gate', () => {
  it('every journal route is ADMIN-only', async () => {
    const { owner, rep, catalogId } = await named();
    const orderId = await openOrder(owner.auth);
    const artist = await makeUser('MODEL_ARTIST');
    for (const auth of [owner.auth, rep.auth, artist.auth]) {
      expect((await journal(auth, 'ALL')).status).toBe(403);
      expect(
        (await request(app).get(`/admin/subscriptions/payments/${orderId}`).set(auth)).status
      ).toBe(403);
      expect(
        (await request(app).post(`/admin/subscriptions/payments/${orderId}/sync`).set(auth).send({}))
          .status
      ).toBe(403);
      expect(
        (
          await request(app)
            .post(`/admin/subscriptions/payments/${orderId}/apply`)
            .set(auth)
            .send({ note: NOTE })
        ).status
      ).toBe(403);
    }
    expect(await CatalogSubscription.countDocuments({ catalogId })).toBe(0);
  });
});

describe('the journal pages', () => {
  it('paginates newest first with a cursor, and rejects a tampered one', async () => {
    const { owner, admin } = await named();
    const ids: string[] = [];
    for (let i = 0; i < 3; i++) {
      ids.push(await openOrder(owner.auth));
      // Retire the open order so the next call mints a new one.
      await PaymentRecord.updateMany(
        { kind: 'CHECKOUT_CREATED' },
        { $set: { expiresAt: new Date(Date.now() - 1000) } }
      );
    }
    const first = await request(app)
      .get('/admin/subscriptions/payments')
      .query({ filter: 'ALL', limit: 2 })
      .set(admin.auth);
    expect(first.body.items.map((i: { orderId: string }) => i.orderId)).toEqual([ids[2], ids[1]]);
    expect(first.body.nextCursor).toBeTruthy();
    const second = await journal(admin.auth, 'ALL', first.body.nextCursor);
    expect(second.body.items.map((i: { orderId: string }) => i.orderId)).toEqual([ids[0]]);
    expect(second.body.nextCursor).toBeNull();

    const bad = await journal(admin.auth, 'ALL', 'not-a-cursor');
    expect(bad.status).toBe(400);
  });
});

describe('the collections list and the panel', () => {
  it('ALL lists every row with the owner name, and q narrows by name', async () => {
    const a = await named();
    const b = await delegated();
    await Catalog.updateOne({ _id: b.catalogId }, { $set: { name: 'red_diner' } });
    const now = Date.now();
    for (const [ctx, status] of [
      [a, 'ACTIVE'],
      [b, 'PAUSED'],
    ] as const) {
      await CatalogSubscription.create({
        catalogId: ctx.catalogId,
        userId: ctx.owner.id,
        status,
        source: 'ONLINE',
        planId: 'TASTE',
        billingInterval: 'MONTHLY',
        periodStart: new Date(now - 5 * DAY_MS),
        periodEnd: new Date(now + 25 * DAY_MS),
        threeDDishCap: 10,
      });
    }

    const all = await request(app)
      .get('/admin/subscriptions')
      .query({ state: 'ALL' })
      .set(a.admin.auth);
    expect(all.status).toBe(200);
    expect(all.body.items).toHaveLength(2);
    const blue = all.body.items.find((i: { catalogName: string }) => i.catalogName === 'blue cafe');
    expect(blue.owner).toMatchObject({ displayName: 'Asha Rao' });
    expect(blue.billingInterval).toBe('MONTHLY');

    const byName = await request(app)
      .get('/admin/subscriptions')
      .query({ state: 'ALL', q: 'red diner' })
      .set(a.admin.auth);
    expect(byName.body.items.map((i: { catalogName: string }) => i.catalogName)).toEqual([
      'red diner',
    ]);
    const byOwner = await request(app)
      .get('/admin/subscriptions')
      .query({ state: 'ALL', q: 'asha' })
      .set(a.admin.auth);
    expect(byOwner.body.items.map((i: { catalogName: string }) => i.catalogName)).toEqual([
      'blue cafe',
    ]);
    const none = await request(app)
      .get('/admin/subscriptions')
      .query({ state: 'ALL', q: 'nobody' })
      .set(a.admin.auth);
    expect(none.body.items).toEqual([]);
  });

  it('the panel carries the owner, catalog details and the attempts', async () => {
    const { owner, admin, catalogId } = await named();
    const orderId = await openOrder(owner.auth);
    const res = await request(app)
      .get(`/admin/catalogs/${catalogId.toHexString()}/subscription`)
      .set(admin.auth);
    expect(res.status).toBe(200);
    expect(res.body.owner).toMatchObject({ displayName: 'Asha Rao' });
    expect(res.body.catalog).toMatchObject({ name: 'blue cafe', deleted: false, onMirage: false });
    expect(res.body.attempts.map((a: { orderId: string }) => a.orderId)).toEqual([orderId]);
    expect(JSON.stringify(res.body.owner)).not.toMatch(/phone|email/i);
  });
});
