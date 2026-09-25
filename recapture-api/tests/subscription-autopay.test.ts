// tests/subscription-autopay.test.ts
//
// AUTOPAY (Razorpay Subscriptions). What this file exists to pin:
//   • START mints a mandate and charges nothing; a double tap is one mandate;
//     one Razorpay plan per price.
//   • MONEY COMES FROM INVOICES. A paid invoice is a PAID row (keyed on the
//     payment, like every online payment) applied through the one primitive;
//     a mandate merely going ACTIVE is not a payment.
//   • THE PERIOD ENDS ON RAZORPAY'S CALENDAR (billing_end), starts at paidAt.
//   • NO DOUBLE CHARGE when an owner inside a paid period of the same plan
//     turns autopay on: the first charge is deferred to that period's end.
//   • RENEWALS by webhook converge on one row per payment; the order-based
//     `payment.captured` for an invoice is ignored, not rebuilt as one-time.
//   • ONE LIVE MANDATE: a plan change cancels the old one at Razorpay.
//   • OFF cancels at Razorpay and leaves the paid period alone.
//   • THE SWEEP holds a healthy autopay catalog out of GRACE while the renewal
//     lands; the reconciler finds what no webhook brought.
import { describe, it, expect, beforeAll, afterAll, beforeEach, afterEach, vi } from 'vitest';
import request from 'supertest';
import mongoose, { Types } from 'mongoose';
import { MongoMemoryServer } from 'mongodb-memory-server';

import { createApp } from '@/app';
import { env } from '@/config/env';
import { DEFAULT_PLAN_CATALOG } from '@/config/subscriptionPlans';
import { AutopayMandate } from '@/models/AutopayMandate';
import { Catalog } from '@/models/Catalog';
import { CatalogDelegation } from '@/models/CatalogDelegation';
import { CatalogSubscription } from '@/models/CatalogSubscription';
import { Notification } from '@/models/Notification';
import { PaymentRecord } from '@/models/PaymentRecord';
import { RateWindow } from '@/models/RateWindow';
import { RazorpayPlan } from '@/models/RazorpayPlan';
import { User } from '@/models/User';
import {
  resetRazorpayClient,
  setRazorpayClient,
  signSubscriptionResponse,
} from '@/providers/razorpay';
import { reconcileOpenOrders, resetOnReadSettleState, resetReconcileState } from '@/services/subscription/reconcileService';
import { runSubscriptionSweep } from '@/services/subscription/lifecycleSweep';
import {
  DAY_MS,
  delegated,
  fakeRazorpay,
  fakeSubscriptions,
  paymentCaptured,
  seedSubscription,
  signedWebhook,
  subscriptionEvent,
  type Auth,
} from './helpers/subscriptionPayments';

const app = createApp();
let mongod: MongoMemoryServer;
let razorpay: ReturnType<typeof fakeRazorpay>;

const TASTE_MONTHLY = DEFAULT_PLAN_CATALOG.plans.TASTE.priceMonthlyPaise;
const HOUR_MS = 3_600_000;

beforeAll(async () => {
  mongod = await MongoMemoryServer.create();
  await mongoose.connect(mongod.getUri());
  await Promise.all([
    Catalog.syncIndexes(),
    CatalogSubscription.syncIndexes(),
    CatalogDelegation.syncIndexes(),
    PaymentRecord.syncIndexes(),
    AutopayMandate.syncIndexes(),
    RazorpayPlan.syncIndexes(),
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
  resetReconcileState();
  fakeSubscriptions.reset();
  razorpay = fakeRazorpay();
  setRazorpayClient(razorpay);
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
    AutopayMandate.deleteMany({}),
    RazorpayPlan.deleteMany({}),
    RateWindow.deleteMany({}),
    Notification.deleteMany({}),
  ]);
});

async function start(auth: Auth, planId = 'TASTE', interval = 'MONTHLY') {
  return request(app).post('/catalog/subscription/autopay').set(auth).send({ planId, interval });
}

function verify(auth: Auth, subscriptionId: string, paymentId = 'pay_auth_1') {
  return request(app)
    .post('/catalog/subscription/autopay/verify')
    .set(auth)
    .send({
      subscriptionId,
      paymentId,
      signature: signSubscriptionResponse(subscriptionId, paymentId, env.RAZORPAY_KEY_SECRET!),
    });
}

function deliver(event: Record<string, unknown>) {
  const signed = signedWebhook(event);
  return request(app)
    .post('/webhooks/razorpay')
    .set('Content-Type', 'application/json')
    .set('X-Razorpay-Signature', signed.signature)
    .send(signed.body);
}

/** Start autopay and have Razorpay take the first cycle right away. */
async function startAndCharge(auth: Auth, now = new Date()) {
  const res = await start(auth);
  expect(res.status).toBe(201);
  const subId: string = res.body.autopay.providerSubscriptionId;
  const end = new Date(now.getTime() + 31 * DAY_MS);
  const paymentId = fakeSubscriptions.charge(subId, { amountPaise: TASTE_MONTHLY, start: now, end });
  return { subId, paymentId, end };
}

describe('POST /catalog/subscription/autopay — start', () => {
  it('mints a CREATED mandate on a Razorpay plan and charges nothing', async () => {
    const { owner, catalogId } = await delegated();
    const res = await start(owner.auth);

    expect(res.status).toBe(201);
    expect(res.body.autopay).toMatchObject({
      keyId: env.RAZORPAY_KEY_ID,
      amountPaise: TASTE_MONTHLY,
      firstChargeAt: null,
      daysForfeited: 0,
      quote: { planId: 'TASTE', interval: 'MONTHLY', totalPaise: TASTE_MONTHLY },
    });
    expect(res.body.autopay.providerSubscriptionId).toMatch(/^sub_test_/);
    expect(razorpay.createPlan).toHaveBeenCalledWith(
      expect.objectContaining({ period: 'monthly', amountPaise: TASTE_MONTHLY })
    );
    expect(razorpay.createSubscription).toHaveBeenCalledWith(
      expect.objectContaining({ totalCount: env.AUTOPAY_TOTAL_CYCLES_MONTHLY })
    );
    // No start_at: charged at approval.
    expect(razorpay.createSubscription.mock.calls[0]![0]).not.toHaveProperty('startAt');

    const mandate = await AutopayMandate.findOne({ catalogId }).lean().exec();
    expect(mandate).toMatchObject({ status: 'CREATED', startAt: null });
    expect(await PaymentRecord.countDocuments({})).toBe(0);
    expect(await CatalogSubscription.countDocuments({})).toBe(0);
  });

  it('a double tap returns the same mandate; a second price point reuses the Razorpay plan', async () => {
    const { owner } = await delegated();
    const first = await start(owner.auth);
    const again = await start(owner.auth);
    expect(again.status).toBe(200);
    expect(again.headers['x-autopay-reused']).toBe('1');
    expect(again.body.autopay.providerSubscriptionId).toBe(first.body.autopay.providerSubscriptionId);

    const other = await delegated();
    await start(other.owner.auth);
    expect(razorpay.createPlan).toHaveBeenCalledTimes(1);
    expect(razorpay.createSubscription).toHaveBeenCalledTimes(2);
  });

  it('a yearly plan is a yearly Razorpay plan at the discounted total', async () => {
    const { owner } = await delegated();
    const res = await start(owner.auth, 'TASTE', 'YEARLY');
    expect(res.status).toBe(201);
    expect(razorpay.createPlan).toHaveBeenCalledWith(expect.objectContaining({ period: 'yearly' }));
    expect(razorpay.createSubscription).toHaveBeenCalledWith(
      expect.objectContaining({ totalCount: env.AUTOPAY_TOTAL_CYCLES_YEARLY })
    );
    expect(res.body.autopay.amountPaise).toBe(res.body.autopay.quote.totalPaise);
    expect(res.body.autopay.amountPaise).toBeLessThan(TASTE_MONTHLY * 12);
  });

  it('inside a paid period of the SAME plan: the first charge waits for that period to end', async () => {
    const { owner, catalogId } = await delegated();
    const periodEnd = new Date(Date.now() + 10 * DAY_MS);
    await seedSubscription(catalogId, owner.id, 'ACTIVE', {
      planId: 'TASTE',
      billingInterval: 'MONTHLY',
      periodEnd,
    });

    const res = await start(owner.auth);
    expect(res.status).toBe(201);
    expect(res.body.autopay.firstChargeAt).toBe(periodEnd.toISOString());
    expect(res.body.autopay.daysForfeited).toBe(0);
    expect(razorpay.createSubscription).toHaveBeenCalledWith(
      expect.objectContaining({ startAt: Math.floor(periodEnd.getTime() / 1000) })
    );
  });

  it('a DIFFERENT plan starts now and reports the forfeited days, like a one-time payment', async () => {
    const { owner, catalogId } = await delegated();
    await seedSubscription(catalogId, owner.id, 'ACTIVE', {
      planId: 'SIGNATURE',
      billingInterval: 'MONTHLY',
      periodEnd: new Date(Date.now() + 10 * DAY_MS),
    });
    const res = await start(owner.auth, 'TASTE');
    expect(res.body.autopay.firstChargeAt).toBeNull();
    expect(res.body.autopay.daysForfeited).toBe(10);
  });

  it('409 AUTOPAY_ALREADY_ON when a healthy mandate already charges this plan', async () => {
    const { owner } = await delegated();
    const { subId } = await startAndCharge(owner.auth);
    await verify(owner.auth, subId);
    const res = await start(owner.auth);
    expect(res.status).toBe(409);
    expect(res.body.code).toBe('AUTOPAY_ALREADY_ON');
  });

  it('503 when Razorpay refuses the subscription — no mandate written', async () => {
    const { owner } = await delegated();
    razorpay.createSubscription.mockRejectedValueOnce(new Error('down'));
    const res = await start(owner.auth);
    expect(res.status).toBe(503);
    expect(await AutopayMandate.countDocuments({})).toBe(0);
  });
});

describe('POST /catalog/subscription/autopay/verify', () => {
  it('records the first charge and activates: period ends on Razorpay\'s billing end', async () => {
    const { owner, catalogId } = await delegated();
    const { subId, paymentId, end } = await startAndCharge(owner.auth);

    const res = await verify(owner.auth, subId);
    expect(res.status).toBe(200);
    expect(res.body.recorded).toBe(true);
    expect(res.body.subscription).toMatchObject({
      status: 'ACTIVE',
      planId: 'TASTE',
      autopay: { status: 'ACTIVE', planId: 'TASTE', interval: 'MONTHLY', amountPaise: TASTE_MONTHLY },
    });

    const row = await CatalogSubscription.findOne({ catalogId }).lean().exec();
    expect(row).toMatchObject({ status: 'ACTIVE', source: 'ONLINE' });
    // 31 days, not the one-time 30: the period follows Razorpay's cycle.
    expect(row!.periodEnd.getTime()).toBe(Math.floor(end.getTime() / 1000) * 1000);

    const paid = await PaymentRecord.findOne({ kind: 'PAID' }).lean().exec();
    expect(paid).toMatchObject({
      providerPaymentId: paymentId,
      providerSubscriptionId: subId,
      idempotencyKey: `payment:${paymentId}`,
      amountPaise: TASTE_MONTHLY,
      recordedVia: 'CLIENT',
    });
    expect(paid!.appliedAt).toBeInstanceOf(Date);
    expect(paid!.note).toBeUndefined();

    const note = await Notification.findOne({ kind: 'PAYMENT_ACTIVATE' }).lean().exec();
    expect(note!.message).toContain('renews automatically');
  });

  it('202 while the mandate is approved but the charge has not landed; the poll then finds it', async () => {
    const { owner, catalogId } = await delegated();
    const res = await start(owner.auth);
    const subId: string = res.body.autopay.providerSubscriptionId;
    fakeSubscriptions.set(subId, { status: 'authenticated', chargeAt: Math.floor(Date.now() / 1000) - 5 });

    const verified = await verify(owner.auth, subId);
    expect(verified.status).toBe(202);
    expect(await PaymentRecord.countDocuments({ kind: 'PAID' })).toBe(0);

    fakeSubscriptions.charge(subId, {
      amountPaise: TASTE_MONTHLY,
      start: new Date(),
      end: new Date(Date.now() + 30 * DAY_MS),
    });
    resetOnReadSettleState();
    const read = await request(app).get('/catalog/subscription').set(owner.auth);
    expect(read.body.subscription.status).toBe('ACTIVE');
    expect(await PaymentRecord.countDocuments({ kind: 'PAID', catalogId })).toBe(1);
  });

  it('a deferred mandate goes AUTHENTICATED with no charge, and the owner is told when it starts', async () => {
    const { owner, catalogId } = await delegated();
    const periodEnd = new Date(Date.now() + 10 * DAY_MS);
    await seedSubscription(catalogId, owner.id, 'ACTIVE', {
      planId: 'TASTE',
      billingInterval: 'MONTHLY',
      periodEnd,
    });
    const res = await start(owner.auth);
    const subId: string = res.body.autopay.providerSubscriptionId;
    fakeSubscriptions.set(subId, { status: 'authenticated' });

    const verified = await verify(owner.auth, subId);
    expect(verified.status).toBe(202);
    // Razorpay keeps whole seconds; the charge is at the period's end.
    expect(verified.body.subscription.autopay).toMatchObject({
      status: 'AUTHENTICATED',
      nextChargeAt: new Date(Math.floor(periodEnd.getTime() / 1000) * 1000).toISOString(),
    });
    // The paid period is untouched.
    const row = await CatalogSubscription.findOne({ catalogId }).lean().exec();
    expect(row!.periodEnd.getTime()).toBe(periodEnd.getTime());
    expect(await Notification.countDocuments({ title: 'Autopay is on' })).toBe(1);
  });

  it('refuses a forged signature and records nothing', async () => {
    const { owner } = await delegated();
    const { subId } = await startAndCharge(owner.auth);
    const res = await request(app)
      .post('/catalog/subscription/autopay/verify')
      .set(owner.auth)
      .send({ subscriptionId: subId, paymentId: 'pay_x', signature: 'ab'.repeat(32) });
    expect(res.status).toBe(400);
    expect(res.body.code).toBe('INVALID_PAYMENT_SIGNATURE');
    expect(await PaymentRecord.countDocuments({})).toBe(0);
  });

  it("will not sync another catalog's mandate", async () => {
    const a = await delegated();
    const b = await delegated();
    const { subId } = await startAndCharge(a.owner.auth);
    const res = await verify(b.owner.auth, subId);
    expect(res.status).toBe(404);
    expect(res.body.code).toBe('AUTOPAY_NOT_FOUND');
  });
});

describe('renewals and the webhook', () => {
  it('subscription.charged records the next cycle once; replays are no-ops', async () => {
    const { owner, catalogId } = await delegated();
    const now = new Date();
    const { subId } = await startAndCharge(owner.auth, now);
    await verify(owner.auth, subId);

    const secondEnd = new Date(now.getTime() + 61 * DAY_MS);
    const renewal = fakeSubscriptions.charge(subId, {
      amountPaise: TASTE_MONTHLY,
      start: new Date(now.getTime() + 31 * DAY_MS),
      end: secondEnd,
    });
    const event = subscriptionEvent('subscription.charged', subId, renewal);
    await deliver(event).expect(200);
    await deliver(event).expect(200);

    expect(await PaymentRecord.countDocuments({ kind: 'PAID', catalogId })).toBe(2);
    const row = await CatalogSubscription.findOne({ catalogId }).lean().exec();
    expect(row!.periodEnd.getTime()).toBe(Math.floor(secondEnd.getTime() / 1000) * 1000);
    const renewed = await PaymentRecord.findOne({ providerPaymentId: renewal }).lean().exec();
    expect(renewed).toMatchObject({ recordedVia: 'WEBHOOK', providerSubscriptionId: subId });
  });

  it("payment.captured for an autopay invoice is left to the mandate — not rebuilt as one-time", async () => {
    const { owner } = await delegated();
    const { subId } = await startAndCharge(owner.auth);
    const event = paymentCaptured({ orderId: 'order_inv_x', paymentId: 'pay_inv_x', amountPaise: TASTE_MONTHLY });
    (event.payload as { payment: { entity: Record<string, unknown> } }).payment.entity.invoice_id = 'inv_1';
    const res = await deliver(event);
    expect(res.status).toBe(200);
    expect(res.body.ignored).toBe(true);
    expect(await PaymentRecord.countDocuments({ kind: 'PAID' })).toBe(0);
    expect(await Notification.countDocuments({ title: 'Payment for an unknown order' })).toBe(0);
    expect(subId).toBeTruthy();
  });

  it('a subscription we never created is acknowledged and ignored', async () => {
    await delegated();
    const res = await deliver(subscriptionEvent('subscription.activated', 'sub_from_dashboard'));
    expect(res.status).toBe(200);
    expect(res.body.ignored).toBe(true);
  });

  it('a failing renewal (PENDING) and a halt each tell the owner once', async () => {
    const { owner } = await delegated();
    const { subId } = await startAndCharge(owner.auth);
    await verify(owner.auth, subId);

    fakeSubscriptions.set(subId, { status: 'pending' });
    await deliver(subscriptionEvent('subscription.pending', subId)).expect(200);
    await deliver(subscriptionEvent('subscription.pending', subId)).expect(200);
    expect(await Notification.countDocuments({ title: 'Autopay could not take this payment' })).toBe(1);

    fakeSubscriptions.set(subId, { status: 'halted' });
    await deliver(subscriptionEvent('subscription.halted', subId)).expect(200);
    expect(await Notification.countDocuments({ title: 'Autopay has stopped' })).toBe(1);

    const read = await request(app).get('/catalog/subscription').set(owner.auth);
    expect(read.body.subscription.autopay).toMatchObject({ status: 'HALTED', nextChargeAt: null });
  });

  it('cancelled from the payer\'s bank: the owner is told; the paid period stands', async () => {
    const { owner, catalogId } = await delegated();
    const { subId } = await startAndCharge(owner.auth);
    await verify(owner.auth, subId);
    const before = await CatalogSubscription.findOne({ catalogId }).lean().exec();

    fakeSubscriptions.set(subId, { status: 'cancelled' });
    await deliver(subscriptionEvent('subscription.cancelled', subId)).expect(200);

    const note = await Notification.findOne({ title: 'Autopay has stopped' }).lean().exec();
    expect(note!.message).toContain('bank or UPI app');
    const after = await CatalogSubscription.findOne({ catalogId }).lean().exec();
    expect(after!.periodEnd.getTime()).toBe(before!.periodEnd.getTime());
    expect(after!.status).toBe('ACTIVE');
  });
});

describe('plan change — one live mandate', () => {
  it('the new mandate going live cancels the old one at Razorpay', async () => {
    const { owner, catalogId } = await delegated();
    const { subId: oldId } = await startAndCharge(owner.auth);
    await verify(owner.auth, oldId);

    const res = await start(owner.auth, 'SIGNATURE');
    expect(res.status).toBe(201);
    const newId: string = res.body.autopay.providerSubscriptionId;
    fakeSubscriptions.charge(newId, {
      amountPaise: DEFAULT_PLAN_CATALOG.plans.SIGNATURE.priceMonthlyPaise,
      start: new Date(),
      end: new Date(Date.now() + 30 * DAY_MS),
    });
    await verify(owner.auth, newId, 'pay_auth_2');

    expect(razorpay.cancelSubscription).toHaveBeenCalledWith(oldId, false);
    const old = await AutopayMandate.findOne({ providerSubscriptionId: oldId }).lean().exec();
    expect(old).toMatchObject({ status: 'CANCELLED', endReason: 'SUPERSEDED' });
    const row = await CatalogSubscription.findOne({ catalogId }).lean().exec();
    expect(row!.planId).toBe('SIGNATURE');
    // Superseded is ours — not "stopped from your bank".
    expect(await Notification.countDocuments({ title: 'Autopay has stopped' })).toBe(0);
  });
});

describe('POST /catalog/subscription/autopay/cancel', () => {
  it('cancels at Razorpay now and leaves the paid period alone', async () => {
    const { owner, catalogId } = await delegated();
    const { subId } = await startAndCharge(owner.auth);
    await verify(owner.auth, subId);
    const before = await CatalogSubscription.findOne({ catalogId }).lean().exec();

    const res = await request(app).post('/catalog/subscription/autopay/cancel').set(owner.auth);
    expect(res.status).toBe(200);
    expect(res.body.subscription.autopay).toBeNull();
    expect(res.body.subscription.status).toBe('ACTIVE');
    expect(razorpay.cancelSubscription).toHaveBeenCalledWith(subId, false);

    const mandate = await AutopayMandate.findOne({ providerSubscriptionId: subId }).lean().exec();
    expect(mandate).toMatchObject({ status: 'CANCELLED', endReason: 'OWNER_CANCELLED' });
    const after = await CatalogSubscription.findOne({ catalogId }).lean().exec();
    expect(after!.periodEnd.getTime()).toBe(before!.periodEnd.getTime());
    expect(await Notification.countDocuments({ title: 'Autopay turned off' })).toBe(1);

    // Razorpay's own cancelled webhook afterwards is not "stopped from your bank".
    await deliver(subscriptionEvent('subscription.cancelled', subId)).expect(200);
    expect(await Notification.countDocuments({ title: 'Autopay has stopped' })).toBe(0);

    const again = await request(app).post('/catalog/subscription/autopay/cancel').set(owner.auth);
    expect(again.status).toBe(404);
    expect(again.body.code).toBe('AUTOPAY_NOT_ON');
  });

  it('turning it back on after turning it off defers to the end of the paid period', async () => {
    const { owner, catalogId } = await delegated();
    const { subId } = await startAndCharge(owner.auth);
    await verify(owner.auth, subId);
    await request(app).post('/catalog/subscription/autopay/cancel').set(owner.auth).expect(200);
    const row = await CatalogSubscription.findOne({ catalogId }).lean().exec();

    const res = await start(owner.auth);
    expect(res.status).toBe(201);
    expect(res.body.autopay.firstChargeAt).toBe(row!.periodEnd.toISOString());
  });
});

describe('the lifecycle sweep — autopay hold', () => {
  async function lapsedRow(catalogId: Types.ObjectId, ownerId: Types.ObjectId, endedAgoMs: number) {
    return seedSubscription(catalogId, ownerId, 'ACTIVE', {
      planId: 'TASTE',
      billingInterval: 'MONTHLY',
      periodEnd: new Date(Date.now() - endedAgoMs),
    });
  }

  it('a healthy mandate holds the catalog out of GRACE while the renewal lands', async () => {
    const held = await delegated();
    const plain = await delegated();
    await lapsedRow(held.catalogId, held.owner.id, 2 * HOUR_MS);
    await lapsedRow(plain.catalogId, plain.owner.id, 2 * HOUR_MS);
    await AutopayMandate.create({
      catalogId: held.catalogId,
      userId: held.owner.id,
      providerSubscriptionId: 'sub_hold',
      providerPlanId: 'plan_x',
      quote: {
        planId: 'TASTE',
        planSnapshot: DEFAULT_PLAN_CATALOG.plans.TASTE,
        interval: 'MONTHLY',
        totalPaise: TASTE_MONTHLY,
      },
      status: 'ACTIVE',
      expiresAt: new Date(),
      initiatedBy: { userId: held.owner.id, role: 'USER' },
    });

    await runSubscriptionSweep(new Date());
    expect((await CatalogSubscription.findOne({ catalogId: held.catalogId }).lean().exec())!.status).toBe('ACTIVE');
    expect((await CatalogSubscription.findOne({ catalogId: plain.catalogId }).lean().exec())!.status).toBe('GRACE');
  });

  it('past the wait, even a healthy mandate lapses — a charge that never came is real', async () => {
    const { owner, catalogId } = await delegated();
    await lapsedRow(catalogId, owner.id, (env.AUTOPAY_RENEWAL_WAIT_HOURS + 1) * HOUR_MS);
    await AutopayMandate.create({
      catalogId,
      userId: owner.id,
      providerSubscriptionId: 'sub_late',
      providerPlanId: 'plan_x',
      quote: {
        planId: 'TASTE',
        planSnapshot: DEFAULT_PLAN_CATALOG.plans.TASTE,
        interval: 'MONTHLY',
        totalPaise: TASTE_MONTHLY,
      },
      status: 'ACTIVE',
      expiresAt: new Date(),
      initiatedBy: { userId: owner.id, role: 'USER' },
    });
    await runSubscriptionSweep(new Date());
    expect((await CatalogSubscription.findOne({ catalogId }).lean().exec())!.status).toBe('GRACE');
  });
});

describe('the reconciler', () => {
  it('finds an approval and a charge no webhook or verify brought', async () => {
    const { owner, catalogId } = await delegated();
    const res = await start(owner.auth);
    const subId: string = res.body.autopay.providerSubscriptionId;
    // Back-date the mandate past the "still on the phone" window.
    await AutopayMandate.collection.updateOne(
      { providerSubscriptionId: subId },
      { $set: { createdAt: new Date(Date.now() - 10 * 60_000) } }
    );
    fakeSubscriptions.charge(subId, {
      amountPaise: TASTE_MONTHLY,
      start: new Date(),
      end: new Date(Date.now() + 30 * DAY_MS),
    });

    const report = await reconcileOpenOrders(new Date());
    expect(report.rescuedByReconcile).toBe(1);
    const row = await CatalogSubscription.findOne({ catalogId }).lean().exec();
    expect(row).toMatchObject({ status: 'ACTIVE', source: 'ONLINE' });
    const paid = await PaymentRecord.findOne({ kind: 'PAID' }).lean().exec();
    expect(paid!.recordedVia).toBe('RECONCILE');
  });
});
