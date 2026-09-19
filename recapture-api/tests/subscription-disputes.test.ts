// tests/subscription-disputes.test.ts
//
// B9 — chargebacks (gaps-addendum G1). What this file most exists to pin:
//   • A dispute on an ACTIVE catalog → GRACE (never PAUSED), `graceEndsAt =
//     now + graceDays`, ONE DISPUTED row, one alert per ADMIN — and NO refund
//     row, because a dispute is not the B3 exception.
//   • A replayed delivery writes nothing twice.
//   • `won` while still in the dispute's own grace → ACTIVE, `graceEndsAt`
//     cleared. `lost` → still GRACE (the sweep will pause it).
//   • A dispute on a catalog that is already GRACE, TRIAL or COMPED leaves
//     the status alone — the ledger row and the alert still land.
//   • A dispute naming no PAID row (a MANUAL row can never be disputed) is a
//     warn and a 200, nothing written.
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
import { User } from '@/models/User';
import { DEFAULT_PLAN_CATALOG } from '@/config/subscriptionPlans';
import { resetRazorpayClient, setRazorpayClient } from '@/providers/razorpay';
import {
  DAY_MS,
  delegated,
  emitted,
  fakeRazorpay,
  makeUser,
  seedSubscription,
  signedWebhook,
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
    CatalogDelegation.deleteMany({}),
    CatalogSubscription.deleteMany({}),
    PaymentRecord.deleteMany({}),
    Notification.deleteMany({}),
  ]);
});

const MONTHLY = DEFAULT_PLAN_CATALOG.plans.TASTE.priceMonthlyPaise;
const GRACE_DAYS = DEFAULT_PLAN_CATALOG.graceDays;

function deliver(event: Record<string, unknown>) {
  const signed = signedWebhook(event);
  return request(app)
    .post('/webhooks/razorpay')
    .set('Content-Type', 'application/json')
    .set('X-Razorpay-Signature', signed.signature)
    .send(signed.body);
}

function disputeEvent(
  name: 'payment.dispute.created' | 'payment.dispute.closed' | 'payment.dispute.won' | 'payment.dispute.lost',
  dispute: { id: string; paymentId: string; amountPaise?: number; status?: string; reason?: string }
): Record<string, unknown> {
  return {
    entity: 'event',
    event: name,
    payload: {
      dispute: {
        entity: {
          id: dispute.id,
          entity: 'dispute',
          payment_id: dispute.paymentId,
          amount: dispute.amountPaise ?? MONTHLY,
          currency: 'INR',
          reason_code: dispute.reason ?? 'fraudulent',
          status: dispute.status ?? 'open',
          phase: 'chargeback',
        },
      },
    },
  };
}

/** An ACTIVE Taste-monthly catalog with the PAID row that bought it. */
async function activeWithPayment(paymentId = 'pay_disp_1') {
  const { owner, admin, catalogId } = await delegated();
  await seedSubscription(catalogId, owner.id, 'ACTIVE', {
    planId: 'TASTE',
    planSnapshot: DEFAULT_PLAN_CATALOG.plans.TASTE,
    billingInterval: 'MONTHLY',
    threeDDishCap: 10,
    standeeAllocation: { included: 10, issued: 0 },
  });
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
    providerOrderId: `order_${paymentId}`,
    providerPaymentId: paymentId,
    idempotencyKey: `payment:${paymentId}`,
    initiatedBy: { userId: owner.id, role: 'USER' },
    appliedAt: new Date(),
  });
  return { owner, admin, catalogId, paymentId };
}

async function flush(): Promise<void> {
  // alertAdmins is fire-and-forget behind the 200.
  await new Promise((r) => setTimeout(r, 30));
}

describe('payment.dispute.created', () => {
  it('moves ACTIVE → GRACE with graceEndsAt = now + graceDays, one DISPUTED row, no refund, one alert per admin', async () => {
    const { catalogId, paymentId } = await activeWithPayment();
    await makeUser('ADMIN'); // a second admin

    const before = Date.now();
    const res = await deliver(
      disputeEvent('payment.dispute.created', { id: 'disp_1', paymentId })
    );
    expect(res.status).toBe(200);
    await flush();

    const row = await CatalogSubscription.findOne({ catalogId }).lean().exec();
    expect(row!.status).toBe('GRACE');
    expect(row!.disputeGraceAt).toBeInstanceOf(Date);
    const graceMs = row!.graceEndsAt!.getTime() - before;
    expect(graceMs).toBeGreaterThanOrEqual(GRACE_DAYS * DAY_MS - 5_000);
    expect(graceMs).toBeLessThanOrEqual(GRACE_DAYS * DAY_MS + 5_000);

    const disputed = await PaymentRecord.find({ kind: 'DISPUTED' }).lean().exec();
    expect(disputed).toHaveLength(1);
    expect(disputed[0]).toMatchObject({
      catalogId,
      amountPaise: MONTHLY,
      providerPaymentId: paymentId,
      idempotencyKey: 'dispute:disp_1',
      reference: 'disp_1',
      note: 'fraudulent',
    });
    expect(await PaymentRecord.countDocuments({ kind: 'REFUNDED' })).toBe(0);

    const alerts = await Notification.find({}).lean().exec();
    expect(alerts).toHaveLength(1);
    expect(alerts[0]!.audienceType).toBe('USERS');
    expect(alerts[0]!.audienceUserIds).toHaveLength(2);
    expect(alerts[0]!.title).toMatch(/chargeback/i);
    expect(alerts[0]!.message).toMatch(/No refund/);

    expect(emitted('subscription_dispute_received')).toEqual([
      { catalog_id: catalogId.toHexString(), amount_paise: MONTHLY, previous_status: 'ACTIVE' },
    ]);
    expect(emitted('subscription_state_changed')).toEqual([
      { catalog_id: catalogId.toHexString(), from: 'ACTIVE', to: 'GRACE', by: 'DISPUTE' },
    ]);
  });

  it('is idempotent: a replay writes no second row and does not move the grace clock', async () => {
    const { catalogId, paymentId } = await activeWithPayment();
    const event = disputeEvent('payment.dispute.created', { id: 'disp_2', paymentId });

    await deliver(event);
    await flush();
    const first = await CatalogSubscription.findOne({ catalogId }).lean().exec();
    // Push the clock on the row so a second write would be visible.
    await CatalogSubscription.updateOne(
      { catalogId },
      { $set: { graceEndsAt: new Date(first!.graceEndsAt!.getTime() + DAY_MS) } }
    );

    const replay = await deliver(event);
    expect(replay.status).toBe(200);
    await flush();

    expect(await PaymentRecord.countDocuments({ kind: 'DISPUTED' })).toBe(1);
    const after = await CatalogSubscription.findOne({ catalogId }).lean().exec();
    expect(after!.graceEndsAt!.getTime()).toBe(first!.graceEndsAt!.getTime() + DAY_MS);
    expect(await Notification.countDocuments({})).toBe(1);
  });

  it.each(['GRACE', 'TRIAL', 'COMPED', 'PAUSED'] as const)(
    'leaves a %s row untouched but still writes the ledger row and the alert',
    async (status) => {
      const { owner, catalogId } = await delegated();
      const graceEndsAt = new Date(Date.now() + 2 * DAY_MS);
      await seedSubscription(catalogId, owner.id, status, {
        ...(status === 'GRACE' ? { graceEndsAt } : {}),
      });
      await PaymentRecord.create({
        catalogId,
        userId: owner.id,
        kind: 'PAID',
        amountPaise: MONTHLY,
        providerOrderId: 'order_x',
        providerPaymentId: 'pay_x',
        idempotencyKey: 'payment:pay_x',
        initiatedBy: { userId: owner.id, role: 'USER' },
      });

      const res = await deliver(
        disputeEvent('payment.dispute.created', { id: 'disp_3', paymentId: 'pay_x' })
      );
      expect(res.status).toBe(200);
      await flush();

      const row = await CatalogSubscription.findOne({ catalogId }).lean().exec();
      expect(row!.status).toBe(status);
      expect(row!.disputeGraceAt).toBeUndefined();
      if (status === 'GRACE') expect(row!.graceEndsAt!.getTime()).toBe(graceEndsAt.getTime());
      expect(await PaymentRecord.countDocuments({ kind: 'DISPUTED' })).toBe(1);
      expect(await Notification.countDocuments({})).toBe(1);
      expect(emitted('subscription_dispute_received')[0]).toMatchObject({
        previous_status: status,
      });
      expect(emitted('subscription_state_changed')).toEqual([]);
    }
  );

  it('acknowledges a dispute that names no PAID row (a cash row cannot be disputed) and writes nothing', async () => {
    const { owner, catalogId } = await delegated();
    await seedSubscription(catalogId, owner.id, 'ACTIVE');
    await PaymentRecord.create({
      catalogId,
      userId: owner.id,
      kind: 'MANUAL',
      amountPaise: MONTHLY,
      method: 'CASH',
      reference: 'book-1',
      verificationStatus: 'VERIFIED',
      initiatedBy: { userId: owner.id, role: 'SALES_REP' },
    });

    const res = await deliver(
      disputeEvent('payment.dispute.created', { id: 'disp_4', paymentId: 'pay_nope' })
    );
    expect(res.status).toBe(200);
    await flush();

    expect(await PaymentRecord.countDocuments({ kind: 'DISPUTED' })).toBe(0);
    expect((await CatalogSubscription.findOne({ catalogId }).lean().exec())!.status).toBe('ACTIVE');
    expect(console.warn).toHaveBeenCalledWith(expect.stringContaining('disp_4'));
  });

  it('still answers 200 with no ADMIN users in the database', async () => {
    const { catalogId, paymentId, admin } = await activeWithPayment();
    await User.deleteOne({ _id: admin.id });

    const res = await deliver(
      disputeEvent('payment.dispute.created', { id: 'disp_5', paymentId })
    );
    expect(res.status).toBe(200);
    await flush();

    expect((await CatalogSubscription.findOne({ catalogId }).lean().exec())!.status).toBe('GRACE');
    expect(await Notification.countDocuments({})).toBe(0);
    expect(console.error).toHaveBeenCalledWith(expect.stringContaining('no ADMIN users'));
  });
});

describe('payment.dispute.closed', () => {
  async function disputed(paymentId = 'pay_disp_c') {
    const ctx = await activeWithPayment(paymentId);
    await deliver(disputeEvent('payment.dispute.created', { id: 'disp_c', paymentId }));
    await flush();
    return ctx;
  }

  it('won before graceEndsAt → ACTIVE again, graceEndsAt cleared, CLOSED_WON row', async () => {
    const { catalogId, paymentId } = await disputed();

    const res = await deliver(
      disputeEvent('payment.dispute.closed', { id: 'disp_c', paymentId, status: 'won' })
    );
    expect(res.status).toBe(200);
    await flush();

    const row = await CatalogSubscription.findOne({ catalogId }).lean().exec();
    expect(row!.status).toBe('ACTIVE');
    expect(row!.graceEndsAt).toBeNull();
    expect(row!.disputeGraceAt).toBeNull();

    const closed = await PaymentRecord.findOne({ idempotencyKey: 'dispute-closed:disp_c' })
      .lean()
      .exec();
    expect(closed).toMatchObject({ kind: 'DISPUTED', note: 'CLOSED_WON' });
    expect(emitted('subscription_dispute_closed')).toEqual([
      { catalog_id: catalogId.toHexString(), result: 'won' },
    ]);
    expect(emitted('subscription_state_changed').at(-1)).toEqual({
      catalog_id: catalogId.toHexString(),
      from: 'GRACE',
      to: 'ACTIVE',
      by: 'DISPUTE',
    });
    expect(await Notification.countDocuments({})).toBe(2);
  });

  it('payment.dispute.won is the same fact under another name', async () => {
    const { catalogId, paymentId } = await disputed();
    await deliver(disputeEvent('payment.dispute.won', { id: 'disp_c', paymentId, status: 'won' }));
    await flush();
    expect((await CatalogSubscription.findOne({ catalogId }).lean().exec())!.status).toBe('ACTIVE');
  });

  it('lost → still GRACE with the same clock; the sweep pauses it', async () => {
    const { catalogId, paymentId } = await disputed();
    const before = await CatalogSubscription.findOne({ catalogId }).lean().exec();

    const res = await deliver(
      disputeEvent('payment.dispute.closed', { id: 'disp_c', paymentId, status: 'lost' })
    );
    expect(res.status).toBe(200);
    await flush();

    const row = await CatalogSubscription.findOne({ catalogId }).lean().exec();
    expect(row!.status).toBe('GRACE');
    expect(row!.graceEndsAt!.getTime()).toBe(before!.graceEndsAt!.getTime());
    expect(
      (await PaymentRecord.findOne({ idempotencyKey: 'dispute-closed:disp_c' }).lean().exec())!
        .note
    ).toBe('CLOSED_LOST');
    expect(emitted('subscription_dispute_closed')).toEqual([
      { catalog_id: catalogId.toHexString(), result: 'lost' },
    ]);
  });

  it('won after the sweep already paused the row → stays PAUSED; the alert says to comp', async () => {
    const { catalogId, paymentId } = await disputed();
    await CatalogSubscription.updateOne(
      { catalogId },
      { $set: { status: 'PAUSED', pausedAt: new Date() } }
    );

    await deliver(
      disputeEvent('payment.dispute.closed', { id: 'disp_c', paymentId, status: 'won' })
    );
    await flush();

    expect((await CatalogSubscription.findOne({ catalogId }).lean().exec())!.status).toBe('PAUSED');
    const last = (await Notification.find({}).sort({ createdAt: -1 }).lean().exec())[0]!;
    expect(last.message).toMatch(/PAUSED/);
    expect(last.message).toMatch(/comp it/);
  });

  it('won on a grace the PERIOD started (not the dispute) does not restore ACTIVE', async () => {
    const { owner, catalogId } = await delegated();
    // Period already over: an ordinary lapse grace, no disputeGraceAt.
    await seedSubscription(catalogId, owner.id, 'GRACE', {
      periodEnd: new Date(Date.now() - DAY_MS),
      graceEndsAt: new Date(Date.now() + 3 * DAY_MS),
    });
    await PaymentRecord.create({
      catalogId,
      userId: owner.id,
      kind: 'PAID',
      amountPaise: MONTHLY,
      providerOrderId: 'order_g',
      providerPaymentId: 'pay_g',
      idempotencyKey: 'payment:pay_g',
      initiatedBy: { userId: owner.id, role: 'USER' },
    });

    await deliver(
      disputeEvent('payment.dispute.closed', { id: 'disp_g', paymentId: 'pay_g', status: 'won' })
    );
    await flush();

    expect((await CatalogSubscription.findOne({ catalogId }).lean().exec())!.status).toBe('GRACE');
  });

  it('a replayed close writes nothing twice', async () => {
    const { paymentId } = await disputed();
    const event = disputeEvent('payment.dispute.closed', { id: 'disp_c', paymentId, status: 'lost' });
    await deliver(event);
    await deliver(event);
    await flush();
    expect(await PaymentRecord.countDocuments({ idempotencyKey: 'dispute-closed:disp_c' })).toBe(1);
    expect(emitted('subscription_dispute_closed')).toHaveLength(1);
  });
});

describe('a new period clears the dispute marker', () => {
  it('applyPaidPeriod after a dispute-grace leaves disputeGraceAt null', async () => {
    const { catalogId, paymentId, owner } = await activeWithPayment();
    await deliver(disputeEvent('payment.dispute.created', { id: 'disp_p', paymentId }));
    await flush();
    expect(
      (await CatalogSubscription.findOne({ catalogId }).lean().exec())!.disputeGraceAt
    ).toBeInstanceOf(Date);

    const { applyPaidPeriod } = await import('@/services/subscription/subscriptionService');
    await applyPaidPeriod({
      catalogId,
      ownerUserId: owner.id,
      planId: 'TASTE',
      interval: 'MONTHLY',
      source: 'ONLINE',
      paidAt: new Date(),
      planSnapshot: DEFAULT_PLAN_CATALOG.plans.TASTE,
      standeeIncluded: 10,
      amountPaise: MONTHLY,
      via: 'WEBHOOK',
    });

    const row = await CatalogSubscription.findOne({ catalogId }).lean().exec();
    expect(row!.status).toBe('ACTIVE');
    expect(row!.disputeGraceAt).toBeNull();
    expect(row!.graceEndsAt).toBeNull();
  });
});
