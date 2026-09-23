// tests/subscription-webhook.test.ts
//
// Door 2, the money half. What this file most exists to pin:
//   • THE HMAC IS THE DOOR: a tampered signature is a 401 and writes nothing;
//     a good one is ALWAYS a 200, whatever happened next.
//   • ONE PAYMENT, ONE ROW, ONE PERIOD: a replayed delivery and the
//     `order.paid` twin of a `payment.captured` both land on the same
//     idempotency key (B2).
//   • FRESH PERIOD FROM paidAt (AC-3.5): out of GRACE, out of PAUSED (with
//     the AR-resume flag), out of a running period (unused days forfeited).
//   • THE FLAGGED OUTCOMES record and do NOT activate: amount mismatch,
//     duplicate, orphan (deleted catalog), and an order we never wrote (E3).
import { describe, it, expect, beforeAll, afterAll, beforeEach, afterEach, vi } from 'vitest';
import request from 'supertest';
import mongoose, { Types } from 'mongoose';
import { MongoMemoryServer } from 'mongodb-memory-server';

import { createApp } from '@/app';
import { env } from '@/config/env';
import { Catalog } from '@/models/Catalog';
import { CatalogCategory } from '@/models/CatalogCategory';
import { CatalogDelegation } from '@/models/CatalogDelegation';
import { CatalogProduct } from '@/models/CatalogProduct';
import { CatalogSubscription } from '@/models/CatalogSubscription';
import { Notification } from '@/models/Notification';
import { PaymentRecord } from '@/models/PaymentRecord';
import { RateWindow } from '@/models/RateWindow';
import { User } from '@/models/User';
import { DEFAULT_PLAN_CATALOG } from '@/config/subscriptionPlans';
import { resetRazorpayClient, setRazorpayClient, signWebhookBody } from '@/providers/razorpay';
import { applyPaidPeriod } from '@/services/subscription/subscriptionService';
import {
  DAY_MS,
  delegated,
  emitted,
  fakeRazorpay,
  paymentCaptured,
  seedSubscription,
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
  setRazorpayClient(fakeRazorpay());
});

afterEach(async () => {
  vi.restoreAllMocks();
  resetRazorpayClient();
  await Promise.all([
    User.deleteMany({}),
    Catalog.deleteMany({}),
    CatalogCategory.deleteMany({}),
    CatalogProduct.deleteMany({}),
    CatalogDelegation.deleteMany({}),
    CatalogSubscription.deleteMany({}),
    PaymentRecord.deleteMany({}),
    RateWindow.deleteMany({}),
    Notification.deleteMany({}),
  ]);
});

const WEBHOOK = '/webhooks/razorpay';

/** Opens an order for the owner through the real route; returns its provider id. */
async function openOrder(
  auth: Auth,
  planId = 'TASTE',
  interval = 'MONTHLY'
): Promise<{ orderId: string; amountPaise: number }> {
  const res = await request(app)
    .post('/catalog/subscription/order')
    .set(auth)
    .send({ planId, interval });
  expect([200, 201]).toContain(res.status);
  return { orderId: res.body.order.providerOrderId, amountPaise: res.body.order.amountPaise };
}

function deliver(event: Record<string, unknown>, signature?: string) {
  const signed = signedWebhook(event);
  return request(app)
    .post(WEBHOOK)
    .set('Content-Type', 'application/json')
    .set('X-Razorpay-Signature', signature ?? signed.signature)
    .send(signed.body);
}

describe('POST /webhooks/razorpay — the door', () => {
  it('rejects a tampered signature with 401 and writes nothing', async () => {
    const { owner, catalogId } = await delegated();
    const { orderId, amountPaise } = await openOrder(owner.auth);

    const res = await deliver(
      paymentCaptured({ orderId, paymentId: 'pay_1', amountPaise }),
      'deadbeef'.repeat(8)
    );

    expect(res.status).toBe(401);
    expect(res.body).toMatchObject({ status: 'error', code: 'INVALID_SIGNATURE' });
    expect(await PaymentRecord.countDocuments({ kind: 'PAID' })).toBe(0);
    expect(await CatalogSubscription.countDocuments({ catalogId })).toBe(0);
    expect(emitted('razorpay_webhook_rejected')).toEqual([{ reason: 'SIGNATURE' }]);
  });

  it('rejects a missing signature and a signature under another secret', async () => {
    const event = paymentCaptured({ orderId: 'order_x', paymentId: 'pay_x', amountPaise: 1 });
    const none = await request(app)
      .post(WEBHOOK)
      .set('Content-Type', 'application/json')
      .send(JSON.stringify(event));
    expect(none.status).toBe(401);

    const other = signedWebhook(event, 'some-other-secret');
    const wrong = await request(app)
      .post(WEBHOOK)
      .set('Content-Type', 'application/json')
      .set('X-Razorpay-Signature', other.signature)
      .send(other.body);
    expect(wrong.status).toBe(401);
  });

  it('acknowledges an unrelated event with 200 ignored', async () => {
    const res = await deliver({ event: 'settlement.processed', payload: {} });
    expect(res.status).toBe(200);
    expect(res.body).toEqual({ status: 'success', ignored: true });
  });

  it('verifies the EXACT bytes, not a re-serialisation', async () => {
    // Oddly spaced JSON, signed as sent: verifies. The same JSON signed in
    // its canonical form but sent with the odd spacing: does not. A JSON
    // parser in front of the route would make the two indistinguishable.
    const raw = '{ "event" :  "something.else" ,"payload":{} }';
    const asSent = await request(app)
      .post(WEBHOOK)
      .set('Content-Type', 'application/json')
      .set('X-Razorpay-Signature', signWebhookBody(raw, env.RAZORPAY_WEBHOOK_SECRET!))
      .send(raw);
    expect(asSent.status).toBe(200);

    const { signature } = signedWebhook(JSON.parse(raw));
    const reserialised = await request(app)
      .post(WEBHOOK)
      .set('Content-Type', 'application/json')
      .set('X-Razorpay-Signature', signature)
      .send(raw);
    expect(reserialised.status).toBe(401);
  });
});

describe('payment.captured — activation', () => {
  it('activates: ACTIVE, periodStart = paidAt, +30 d, snapshot and standees set (AC-1.1, AC-1.2)', async () => {
    const { owner, catalogId } = await delegated();
    const { orderId, amountPaise } = await openOrder(owner.auth, 'SIGNATURE', 'MONTHLY');
    const before = Date.now();

    const res = await deliver(paymentCaptured({ orderId, paymentId: 'pay_1', amountPaise }));
    expect(res.status).toBe(200);
    expect(res.body).toEqual({ status: 'success' });

    const row = await CatalogSubscription.findOne({ catalogId }).lean().exec();
    expect(row).toMatchObject({
      status: 'ACTIVE',
      source: 'ONLINE',
      planId: 'SIGNATURE',
      billingInterval: 'MONTHLY',
      threeDDishCap: 15,
      standeeAllocation: { included: 15, issued: 0 },
    });
    expect(row!.planSnapshot!.includedStandeeCount).toBe(15);
    expect(row!.periodStart.getTime()).toBeGreaterThanOrEqual(before - 1000);
    expect(row!.periodEnd.getTime() - row!.periodStart.getTime()).toBe(30 * DAY_MS);
    expect(String(row!.userId)).toBe(String(owner.id));

    const paid = await PaymentRecord.findOne({ kind: 'PAID' }).lean().exec();
    expect(paid).toMatchObject({
      providerOrderId: orderId,
      providerPaymentId: 'pay_1',
      idempotencyKey: 'payment:pay_1',
      amountPaise,
    });
    expect(paid!.appliedAt).toBeInstanceOf(Date);
    expect(paid!.note).toBeUndefined();
    // The checkout row is closed.
    const checkout = await PaymentRecord.findOne({ kind: 'CHECKOUT_CREATED' }).lean().exec();
    expect(checkout!.expiresAt!.getTime()).toBeLessThanOrEqual(Date.now());

    expect(emitted('subscription_payment_recorded')).toEqual([
      expect.objectContaining({
        source: 'ONLINE',
        plan_id: 'SIGNATURE',
        previous_status: 'NONE',
        via: 'WEBHOOK',
      }),
    ]);
  });

  it('a yearly order gives 365 days at the discounted total', async () => {
    const { owner, catalogId } = await delegated();
    const { orderId, amountPaise } = await openOrder(owner.auth, 'MASTERCHEF', 'YEARLY');
    expect(amountPaise).toBe(Math.round(249_900 * 12 * 0.7));

    await deliver(paymentCaptured({ orderId, paymentId: 'pay_y', amountPaise })).expect(200);

    const row = await CatalogSubscription.findOne({ catalogId }).lean().exec();
    expect(row!.billingInterval).toBe('YEARLY');
    expect(row!.periodEnd.getTime() - row!.periodStart.getTime()).toBe(365 * DAY_MS);
    expect(row!.standeeAllocation.included).toBe(30);
  });

  it('a replayed delivery inserts nothing and answers 200 (B2)', async () => {
    const { owner, catalogId } = await delegated();
    const { orderId, amountPaise } = await openOrder(owner.auth);
    const event = paymentCaptured({ orderId, paymentId: 'pay_1', amountPaise });

    await deliver(event).expect(200);
    const first = await CatalogSubscription.findOne({ catalogId }).lean().exec();
    await new Promise((r) => setTimeout(r, 5));
    await deliver(event).expect(200);
    await deliver(event).expect(200);

    expect(await PaymentRecord.countDocuments({ kind: 'PAID' })).toBe(1);
    const again = await CatalogSubscription.findOne({ catalogId }).lean().exec();
    expect(again!.periodStart.getTime()).toBe(first!.periodStart.getTime());
    expect(emitted('subscription_payment_recorded')).toHaveLength(1);
  });

  it('payment.captured and order.paid for one payment are one row', async () => {
    const { owner } = await delegated();
    const { orderId, amountPaise } = await openOrder(owner.auth);

    await deliver(
      paymentCaptured({ orderId, paymentId: 'pay_1', amountPaise, event: 'order.paid' })
    ).expect(200);
    await deliver(paymentCaptured({ orderId, paymentId: 'pay_1', amountPaise })).expect(200);

    expect(await PaymentRecord.countDocuments({ kind: 'PAID' })).toBe(1);
    expect(emitted('subscription_payment_recorded')).toHaveLength(1);
  });

  it('out of GRACE: ACTIVE, graceEndsAt cleared, fresh period from paidAt (AC-3.3, AC-3.5)', async () => {
    const { owner, catalogId } = await delegated();
    const oldEnd = new Date(Date.now() - 3 * DAY_MS);
    await seedSubscription(catalogId, owner.id, 'GRACE', {
      planId: 'TASTE',
      planSnapshot: DEFAULT_PLAN_CATALOG.plans.TASTE,
      billingInterval: 'MONTHLY',
      periodEnd: oldEnd,
      graceEndsAt: new Date(Date.now() + 4 * DAY_MS),
      threeDDishCap: 10,
    });
    const { orderId, amountPaise } = await openOrder(owner.auth, 'TASTE', 'MONTHLY');

    await deliver(paymentCaptured({ orderId, paymentId: 'pay_g', amountPaise })).expect(200);

    const row = await CatalogSubscription.findOne({ catalogId }).lean().exec();
    expect(row!.status).toBe('ACTIVE');
    expect(row!.graceEndsAt ?? null).toBeNull();
    // Anchored on the payment, not on the old periodEnd.
    expect(row!.periodStart.getTime()).toBeGreaterThan(oldEnd.getTime());
    expect(row!.periodEnd.getTime() - row!.periodStart.getTime()).toBe(30 * DAY_MS);
    expect(emitted('subscription_payment_recorded')[0]).toMatchObject({ previous_status: 'GRACE' });
  });

  it('out of PAUSED: ACTIVE and needsArResume (AC-4.4 groundwork)', async () => {
    const { owner, catalogId } = await delegated();
    await seedSubscription(catalogId, owner.id, 'PAUSED', {
      pausedAt: new Date(),
      periodEnd: new Date(Date.now() - 10 * DAY_MS),
    });

    const result = await applyPaidPeriod({
      catalogId,
      ownerUserId: owner.id,
      planId: 'TASTE',
      interval: 'MONTHLY',
      source: 'ONLINE',
      paidAt: new Date(),
      planSnapshot: DEFAULT_PLAN_CATALOG.plans.TASTE,
      standeeIncluded: 10,
      amountPaise: 119_900,
      // The ledger row the owner's "payment received" message is keyed on.
      paymentRecordId: new Types.ObjectId(),
      via: 'WEBHOOK',
    });

    expect(result.previousStatus).toBe('PAUSED');
    expect(result.needsArResume).toBe(true);
    expect(result.subscription.status).toBe('ACTIVE');
    expect(result.subscription.pausedAt ?? null).toBeNull();
  });

  it('paying while ACTIVE (early renewal) starts a fresh period — unused days forfeited (A2)', async () => {
    const { owner, catalogId } = await delegated();
    const oldEnd = new Date(Date.now() + 10 * DAY_MS);
    await seedSubscription(catalogId, owner.id, 'ACTIVE', {
      planId: 'TASTE',
      planSnapshot: DEFAULT_PLAN_CATALOG.plans.TASTE,
      billingInterval: 'MONTHLY',
      periodStart: new Date(Date.now() - 20 * DAY_MS),
      periodEnd: oldEnd,
      threeDDishCap: 10,
    });
    const { orderId, amountPaise } = await openOrder(owner.auth, 'SIGNATURE', 'MONTHLY');

    await deliver(paymentCaptured({ orderId, paymentId: 'pay_e', amountPaise })).expect(200);

    const row = await CatalogSubscription.findOne({ catalogId }).lean().exec();
    expect(row!.planId).toBe('SIGNATURE');
    expect(row!.periodEnd.getTime() - row!.periodStart.getTime()).toBe(30 * DAY_MS);
    expect(row!.periodEnd.getTime()).toBeGreaterThan(oldEnd.getTime());
    const paid = await PaymentRecord.findOne({ kind: 'PAID' }).lean().exec();
    expect(paid!.note).toBeUndefined();
  });

  it('paying out of TRIAL ends the trial early and keeps trialUsedAt (E10)', async () => {
    const { owner, catalogId } = await delegated();
    const trialUsedAt = new Date(Date.now() - 5 * DAY_MS);
    await seedSubscription(catalogId, owner.id, 'TRIAL', { trialUsedAt, threeDDishCap: 10 });
    const { orderId, amountPaise } = await openOrder(owner.auth);

    await deliver(paymentCaptured({ orderId, paymentId: 'pay_t', amountPaise })).expect(200);

    const row = await CatalogSubscription.findOne({ catalogId }).lean().exec();
    expect(row!.status).toBe('ACTIVE');
    expect(row!.source).toBe('ONLINE');
    expect(row!.trialUsedAt!.getTime()).toBe(trialUsedAt.getTime());
  });

  it('over the cap on activation: activates anyway and nudges the owner (E11)', async () => {
    const { owner, catalogId } = await delegated();
    const category = await CatalogCategory.create({
      catalogId,
      userId: owner.id,
      name: 'menu',
      position: 0,
    });
    // Twelve PUBLISHED 3D dishes on a menu buying the ten-dish plan.
    await CatalogProduct.create(
      Array.from({ length: 12 }, (_, i) => ({
        catalogId,
        userId: owner.id,
        categoryId: category._id,
        name: `dish_${i}`,
        position: i,
        type: 'THREE_D',
        modelStatus: 'READY',
        assets: { glbUrl: 'https://cdn/x.glb', thumbnailUrl: 't' },
        mirageItemId: `mi_${i}`,
      }))
    );
    const { orderId, amountPaise } = await openOrder(owner.auth, 'TASTE', 'MONTHLY');

    await deliver(paymentCaptured({ orderId, paymentId: 'pay_c', amountPaise })).expect(200);

    expect((await CatalogSubscription.findOne({ catalogId }).lean().exec())!.status).toBe('ACTIVE');
    // TWO messages now reach this owner — the activation ("payment received,
    // next payment due on…") and this nudge — so the over-cap one is asked for
    // by name rather than by "the first notification addressed to them".
    const notices = await Notification.find({ audienceUserIds: owner.id }).lean().exec();
    expect(notices.map((n) => n.title).sort()).toEqual([
      'Payment received — your plan is active',
      'Your menu has more 3D dishes than your plan covers',
    ]);
    const notice = notices.find((n) => n.title.startsWith('Your menu has more'));
    expect(notice?.message).toMatch(/12 3D dishes; Taste plan covers 10/);
    expect(emitted('subscription_over_cap_on_activate')).toEqual([
      expect.objectContaining({ three_d_dish_count: 12, three_d_dish_cap: 10, plan_id: 'TASTE' }),
    ]);
  });
});

describe('payment.captured — the flagged outcomes', () => {
  it('amount ≠ quote: recorded, not activated, admins alerted', async () => {
    const { owner, catalogId, admin } = await delegated();
    const { orderId, amountPaise } = await openOrder(owner.auth);

    const res = await deliver(
      paymentCaptured({ orderId, paymentId: 'pay_m', amountPaise: amountPaise - 100 })
    );
    expect(res.status).toBe(200);

    expect(await CatalogSubscription.countDocuments({ catalogId })).toBe(0);
    const paid = await PaymentRecord.findOne({ kind: 'PAID' }).lean().exec();
    expect(paid).toMatchObject({ note: 'AMOUNT_MISMATCH', amountPaise: amountPaise - 100 });
    expect(paid!.appliedAt).toBeInstanceOf(Date);
    expect(emitted('razorpay_webhook_rejected')).toEqual([{ reason: 'AMOUNT_MISMATCH' }]);
    // The alert reaches every ADMIN and nobody else.
    await vi.waitFor(async () => {
      const alert = await Notification.findOne({ audienceType: 'USERS' }).lean().exec();
      expect(alert).not.toBeNull();
      expect(alert!.audienceUserIds.map(String)).toEqual([String(admin.id)]);
    });
  });

  it('a second payment for an already-paid checkout: DUPLICATE_SUSPECTED, period untouched', async () => {
    const { owner, catalogId } = await delegated();
    // Two orders opened before any payment (the first expired unpaid).
    const first = await openOrder(owner.auth);
    await PaymentRecord.updateOne(
      { providerOrderId: first.orderId },
      { $set: { expiresAt: new Date(Date.now() - 1000) } }
    );
    const second = await openOrder(owner.auth);
    expect(second.orderId).not.toBe(first.orderId);

    await deliver(
      paymentCaptured({
        orderId: second.orderId,
        paymentId: 'pay_a',
        amountPaise: second.amountPaise,
      })
    ).expect(200);
    const after1 = await CatalogSubscription.findOne({ catalogId }).lean().exec();
    expect(after1!.status).toBe('ACTIVE');

    // The stale first order settles too (a UPI collect approved late).
    await deliver(
      paymentCaptured({
        orderId: first.orderId,
        paymentId: 'pay_b',
        amountPaise: first.amountPaise,
      })
    ).expect(200);

    const after2 = await CatalogSubscription.findOne({ catalogId }).lean().exec();
    expect(after2!.periodStart.getTime()).toBe(after1!.periodStart.getTime());
    expect(after2!.periodEnd.getTime()).toBe(after1!.periodEnd.getTime());
    const dup = await PaymentRecord.findOne({ providerPaymentId: 'pay_b' }).lean().exec();
    expect(dup!.note).toBe('DUPLICATE_SUSPECTED');
    expect(emitted('subscription_duplicate_payment_flagged')).toHaveLength(1);
    expect(emitted('subscription_payment_recorded')).toHaveLength(1);
  });

  it('a deleted catalog: ORPHAN_PAYMENT, recorded, not activated (E5)', async () => {
    const { owner, catalogId } = await delegated();
    const { orderId, amountPaise } = await openOrder(owner.auth);
    await Catalog.deleteOne({ _id: catalogId });

    await deliver(paymentCaptured({ orderId, paymentId: 'pay_o', amountPaise })).expect(200);

    expect(await CatalogSubscription.countDocuments({ catalogId })).toBe(0);
    const paid = await PaymentRecord.findOne({ kind: 'PAID' }).lean().exec();
    expect(paid!.note).toBe('ORPHAN_PAYMENT');
    expect(String(paid!.catalogId)).toBe(String(catalogId));
  });

  it('an order we never wrote, with our notes: rebuilt and activated (E3)', async () => {
    const { owner, catalogId } = await delegated();
    const amountPaise = DEFAULT_PLAN_CATALOG.plans.TASTE.priceMonthlyPaise;

    await deliver(
      paymentCaptured({
        orderId: 'order_lost',
        paymentId: 'pay_lost',
        amountPaise,
        notes: { catalogId: catalogId.toHexString(), planId: 'TASTE', interval: 'MONTHLY' },
      })
    ).expect(200);

    const row = await CatalogSubscription.findOne({ catalogId }).lean().exec();
    expect(row).toMatchObject({ status: 'ACTIVE', planId: 'TASTE' });
    const paid = await PaymentRecord.findOne({ kind: 'PAID' }).lean().exec();
    expect(paid).toMatchObject({ providerOrderId: 'order_lost', amountPaise });
    expect(String(paid!.userId)).toBe(String(owner.id));
  });

  it('an order we never wrote, without notes: 200, warned, nothing written', async () => {
    await delegated();
    const res = await deliver(
      paymentCaptured({ orderId: 'order_testmode', paymentId: 'pay_tm', amountPaise: 119_900 })
    );
    expect(res.status).toBe(200);
    expect(await PaymentRecord.countDocuments({})).toBe(0);
    expect(await CatalogSubscription.countDocuments({})).toBe(0);
    expect(emitted('razorpay_webhook_rejected')).toEqual([{ reason: 'UNKNOWN_ORDER' }]);
  });

  it('never stores the payer contact Razorpay sends', async () => {
    const { owner } = await delegated();
    const { orderId, amountPaise } = await openOrder(owner.auth);
    const event = paymentCaptured({ orderId, paymentId: 'pay_p', amountPaise });
    const entity = (event.payload as { payment: { entity: Record<string, unknown> } }).payment
      .entity;
    entity.contact = '+919999999999';
    entity.email = 'owner@example.com';
    entity.vpa = 'owner@upi';

    await deliver(event).expect(200);

    const rows = await PaymentRecord.find({}).lean().exec();
    expect(JSON.stringify(rows)).not.toMatch(/9999999999|owner@example|owner@upi/);
  });
});

describe('the other events', () => {
  it('payment.failed: an analytics trace, no row, the order stays open', async () => {
    const { owner, catalogId } = await delegated();
    const { orderId } = await openOrder(owner.auth);

    await deliver({
      event: 'payment.failed',
      payload: {
        payment: {
          entity: { id: 'pay_f', order_id: orderId, error_code: 'BAD_REQUEST_ERROR' },
        },
      },
    }).expect(200);

    expect(await PaymentRecord.countDocuments({ kind: 'PAID' })).toBe(0);
    const open = await PaymentRecord.findOne({ kind: 'CHECKOUT_CREATED' }).lean().exec();
    expect(open!.expiresAt!.getTime()).toBeGreaterThan(Date.now());
    expect(emitted('subscription_payment_failed')).toEqual([
      { catalog_id: catalogId.toHexString(), failure_reason: 'BAD_REQUEST_ERROR' },
    ]);
  });

  it('refund.processed for a refund we issued: the row is marked; for one we did not: EXTERNAL_REFUND row (E38)', async () => {
    const { owner, catalogId } = await delegated();
    const { orderId, amountPaise } = await openOrder(owner.auth);
    await deliver(paymentCaptured({ orderId, paymentId: 'pay_r', amountPaise })).expect(200);
    const paid = await PaymentRecord.findOne({ kind: 'PAID' }).exec();

    // Ours.
    await PaymentRecord.create({
      catalogId,
      userId: owner.id,
      kind: 'REFUNDED',
      amountPaise,
      providerPaymentId: 'pay_r',
      providerRefundId: 'rfnd_ours',
      refundsPaymentId: paid!._id,
      initiatedBy: { userId: owner.id, role: 'ADMIN' },
      note: 'duplicate refund',
    });
    await deliver({
      event: 'refund.processed',
      payload: {
        refund: { entity: { id: 'rfnd_ours', payment_id: 'pay_r', amount: amountPaise } },
      },
    }).expect(200);
    const ours = await PaymentRecord.findOne({ providerRefundId: 'rfnd_ours' }).lean().exec();
    expect(ours!.note).toBe('REFUND_PROCESSED');

    // Theirs (Razorpay dashboard).
    await deliver({
      event: 'refund.processed',
      payload: {
        refund: { entity: { id: 'rfnd_dashboard', payment_id: 'pay_r', amount: amountPaise } },
      },
    }).expect(200);
    const external = await PaymentRecord.findOne({ providerRefundId: 'rfnd_dashboard' })
      .lean()
      .exec();
    expect(external).toMatchObject({ kind: 'REFUNDED', note: 'EXTERNAL_REFUND', amountPaise });
    expect(String(external!.refundsPaymentId)).toBe(String(paid!._id));
    // A replay of the same refund adds nothing.
    await deliver({
      event: 'refund.processed',
      payload: {
        refund: { entity: { id: 'rfnd_dashboard', payment_id: 'pay_r', amount: amountPaise } },
      },
    }).expect(200);
    expect(await PaymentRecord.countDocuments({ kind: 'REFUNDED' })).toBe(2);
    // The period was never touched by any of it.
    expect((await CatalogSubscription.findOne({ catalogId }).lean().exec())!.status).toBe('ACTIVE');
  });

  it('refund.failed marks our row and alerts', async () => {
    const { owner, catalogId } = await delegated();
    await PaymentRecord.create({
      catalogId,
      userId: owner.id,
      kind: 'REFUNDED',
      amountPaise: 1,
      providerPaymentId: 'pay_z',
      providerRefundId: 'rfnd_fail',
      refundsPaymentId: new Types.ObjectId(),
      initiatedBy: { userId: owner.id, role: 'ADMIN' },
    });
    await deliver({
      event: 'refund.failed',
      payload: { refund: { entity: { id: 'rfnd_fail', status: 'failed' } } },
    }).expect(200);
    const row = await PaymentRecord.findOne({ providerRefundId: 'rfnd_fail' }).lean().exec();
    expect(row!.note).toBe('REFUND_FAILED:failed');
  });
});
