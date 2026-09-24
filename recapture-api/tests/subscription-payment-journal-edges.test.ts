// tests/subscription-payment-journal-edges.test.ts
//
// The payment journal's edge cases, one block per case (numbered as in the
// Sept 2026 review):
//   1. an admin apply that never landed can be applied again (exactly once);
//   2. "Start plan" / a cash VERIFY cannot re-activate a payment already on
//      the ledger;
//   3. a duplicate says how many days an apply would forfeit, and is refundable
//      without the override;
//   4. a refused, unresolved payment does not cost the owner their trial;
//   5. an order priced differently from today (a testing price after
//      go-live) needs acceptQuotedPrice;
//   6. an authorized-but-uncaptured payment can be captured from the app;
//   7. a refund of the payment that bought the running period says so;
//   8. any order_/pay_ id can be looked up;
//   9. owners can be found by the end of their phone number or their email;
//  10. dates in the sentences are India dates.
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
import { day } from '@/services/subscription/paymentJournalService';
import { resetOnReadSettleState } from '@/services/subscription/reconcileService';
import { recordOnlinePayment } from '@/services/subscription/webhookService';
import { DAY_MS, delegated, fakeRazorpay, type Auth } from './helpers/subscriptionPayments';

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
const LONG_NOTE = 'Refunding: owner asked for the money back on the phone today.';

async function openOrder(auth: Auth): Promise<string> {
  const res = await request(app)
    .post('/catalog/subscription/order')
    .set(auth)
    .send({ planId: 'TASTE', interval: 'MONTHLY' });
  expect([200, 201]).toContain(res.status);
  return res.body.order.providerOrderId as string;
}

async function expireAllOrders(): Promise<void> {
  await PaymentRecord.updateMany(
    { kind: 'CHECKOUT_CREATED' },
    { $set: { expiresAt: new Date(Date.now() - 1000) } }
  );
}

function entry(auth: Auth, orderId: string) {
  return request(app).get(`/admin/subscriptions/payments/${orderId}`).set(auth);
}

describe('#1 an admin apply that never landed', () => {
  it('can be applied again, and then only once', async () => {
    const { owner, admin, catalogId } = await delegated();
    const orderId = await openOrder(owner.auth);
    await recordOnlinePayment({ orderId, paymentId: 'pay_short1', amountPaise: MONTHLY - 1, via: 'WEBHOOK' });
    // The claim landed; the process died before the apply did.
    await PaymentRecord.collection.updateOne(
      { kind: 'PAID', providerOrderId: orderId },
      {
        $set: {
          adminResolution: {
            action: 'APPLIED',
            by: { userId: admin.id, role: 'ADMIN' },
            at: new Date(Date.now() - 60_000),
            note: 'First try, the server crashed.',
          },
        },
      }
    );

    const stuck = (await entry(admin.auth, orderId)).body.attempt;
    expect(stuck.stage).toBe('NOT_REFLECTED');
    expect(stuck.needsAttention).toBe(true);
    expect(stuck.canForceApply).toBe(true);

    const res = await request(app)
      .post(`/admin/subscriptions/payments/${orderId}/apply`)
      .set(admin.auth)
      .send({ note: NOTE });
    expect(res.status).toBe(200);
    expect(res.body.attempt.stage).toBe('RESOLVED');
    expect(res.body.attempt.resolution.note).toBe(NOTE);
    expect((await CatalogSubscription.findOne({ catalogId }))?.status).toBe('ACTIVE');

    const again = await request(app)
      .post(`/admin/subscriptions/payments/${orderId}/apply`)
      .set(admin.auth)
      .send({ note: NOTE });
    expect(again.body.code).toBe('ALREADY_RESOLVED');
  });
});

describe('#2 a payment already on the ledger cannot be activated twice', () => {
  const startPlan = (auth: Auth, catalogId: string, reference: string) =>
    request(app)
      .post(`/admin/catalogs/${catalogId}/subscription/manual-payment`)
      .set(auth)
      .send({
        action: 'CREATE_AND_VERIFY',
        planId: 'TASTE',
        interval: 'MONTHLY',
        amountPaise: MONTHLY,
        method: 'UPI',
        reference,
      });

  it('Start plan with a pay_ id already recorded online is 409, and writes nothing', async () => {
    const { owner, admin, catalogId } = await delegated();
    const orderId = await openOrder(owner.auth);
    await recordOnlinePayment({ orderId, paymentId: 'pay_Twice1', amountPaise: MONTHLY, via: 'WEBHOOK' });

    const res = await startPlan(admin.auth, catalogId.toHexString(), 'pay_Twice1');
    expect(res.status).toBe(409);
    expect(res.body).toMatchObject({ code: 'ALREADY_RECORDED_ONLINE', orderId });
    expect(await PaymentRecord.countDocuments({ kind: 'MANUAL' })).toBe(0);
  });

  it('the same reference twice on one restaurant is 409 DUPLICATE_REFERENCE', async () => {
    const { admin, catalogId } = await delegated();
    expect((await startPlan(admin.auth, catalogId.toHexString(), 'rcpt-0042')).status).toBe(200);
    const again = await startPlan(admin.auth, catalogId.toHexString(), 'rcpt-0042');
    expect(again.status).toBe(409);
    expect(again.body.code).toBe('DUPLICATE_REFERENCE');
    expect(await PaymentRecord.countDocuments({ kind: 'MANUAL' })).toBe(1);
  });

  it("a rep's cash request carrying a recorded pay_ id cannot be verified", async () => {
    const { owner, rep, admin, catalogId } = await delegated();
    const orderId = await openOrder(owner.auth);
    await recordOnlinePayment({ orderId, paymentId: 'pay_RepDup1', amountPaise: MONTHLY, via: 'WEBHOOK' });
    const submitted = await request(app)
      .post(`/rep/catalogs/${catalogId.toHexString()}/subscription/manual-payment-request`)
      .set(rep.auth)
      .send({
        planId: 'TASTE',
        interval: 'MONTHLY',
        amountPaise: MONTHLY,
        method: 'UPI',
        reference: 'pay_RepDup1',
      });
    expect(submitted.status).toBe(201);

    const verify = await request(app)
      .post(`/admin/catalogs/${catalogId.toHexString()}/subscription/manual-payment`)
      .set(admin.auth)
      .send({ action: 'VERIFY', paymentRecordId: submitted.body.paymentRecord.id });
    expect(verify.status).toBe(409);
    expect(verify.body.code).toBe('ALREADY_RECORDED_ONLINE');
    const row = await PaymentRecord.findOne({ kind: 'MANUAL' });
    expect(row?.verificationStatus).toBe('PENDING_VERIFICATION');
  });
});

describe('#3 a likely duplicate', () => {
  it('says how many days an apply would forfeit, and refunds without the override', async () => {
    const { owner, admin } = await delegated();
    const first = await openOrder(owner.auth);
    await expireAllOrders();
    const second = await openOrder(owner.auth);
    await recordOnlinePayment({ orderId: second, paymentId: 'pay_Second', amountPaise: MONTHLY, via: 'WEBHOOK' });
    const { outcome } = await recordOnlinePayment({
      orderId: first,
      paymentId: 'pay_First1',
      amountPaise: MONTHLY,
      via: 'WEBHOOK',
    });
    expect(outcome).toBe('DUPLICATE_SUSPECTED');

    const dup = (await entry(admin.auth, first)).body.attempt;
    expect(dup.stage).toBe('FLAGGED');
    expect(dup.daysForfeitedOnApply).toBe(30);
    expect(dup.canRefund).toBe(true);
    expect(dup.refundNeedsOverride).toBe(false);
  });
});

describe('#4 a refused payment does not cost the owner their trial', () => {
  it('trial stays available until the payment is applied', async () => {
    const { owner, admin, catalogId } = await delegated();
    const orderId = await openOrder(owner.auth);
    await recordOnlinePayment({ orderId, paymentId: 'pay_Short4', amountPaise: MONTHLY - 1, via: 'WEBHOOK' });

    const panel = () =>
      request(app).get(`/admin/catalogs/${catalogId.toHexString()}/subscription`).set(admin.auth);
    expect((await panel()).body.subscription.trialAvailable).toBe(true);

    await request(app)
      .post(`/admin/subscriptions/payments/${orderId}/apply`)
      .set(admin.auth)
      .send({ note: NOTE })
      .expect(200);
    expect((await panel()).body.subscription.trialAvailable).toBe(false);
  });
});

describe('#5 an order priced differently from today', () => {
  it('is refused until the admin accepts the quoted price', async () => {
    const { owner, admin, catalogId } = await delegated();
    const orderId = await openOrder(owner.auth);
    // A ₹3 testing-price order, found after go-live, long past the late window.
    await PaymentRecord.collection.updateOne(
      { kind: 'CHECKOUT_CREATED', providerOrderId: orderId },
      {
        $set: {
          amountPaise: 300,
          'quote.totalPaise': 300,
          createdAt: new Date(Date.now() - 5 * DAY_MS),
          expiresAt: new Date(Date.now() - 4 * DAY_MS),
        },
      }
    );
    setRazorpayClient(
      fakeRazorpay({
        fetchOrder: vi.fn(async (id: string) => ({ id, status: 'paid' as const, amount: 300 })),
        fetchPaymentsForOrder: vi.fn(async () => [{ id: 'pay_Three', status: 'captured', amount: 300 }]),
      })
    );

    const shown = (await entry(admin.auth, orderId)).body.attempt;
    expect(shown.priceChange).toEqual({ quotedPaise: 300, currentPaise: MONTHLY });

    const refused = await request(app)
      .post(`/admin/subscriptions/payments/${orderId}/sync`)
      .set(admin.auth)
      .send({});
    expect(refused.status).toBe(409);
    expect(refused.body).toMatchObject({
      code: 'QUOTE_PRICE_CHANGED',
      quotedPaise: 300,
      currentPaise: MONTHLY,
    });
    expect(await PaymentRecord.countDocuments({ kind: 'PAID' })).toBe(0);

    const accepted = await request(app)
      .post(`/admin/subscriptions/payments/${orderId}/sync`)
      .set(admin.auth)
      .send({ acceptQuotedPrice: true });
    expect(accepted.body.result).toBe('APPLIED');
    expect((await CatalogSubscription.findOne({ catalogId }))?.planId).toBe('TASTE');
  });
});

describe('#6 an authorized but uncaptured payment', () => {
  it('Check offers it; Capture takes it at Razorpay and applies the plan', async () => {
    const { owner, admin, catalogId } = await delegated();
    const orderId = await openOrder(owner.auth);
    const client = fakeRazorpay({
      fetchOrder: vi.fn(async (id: string) => ({ id, status: 'attempted' as const, amount: MONTHLY })),
      fetchPaymentsForOrder: vi.fn(async () => [
        { id: 'pay_Auth6', status: 'authorized', amount: MONTHLY },
      ]),
    });
    setRazorpayClient(client);

    const sync = await request(app)
      .post(`/admin/subscriptions/payments/${orderId}/sync`)
      .set(admin.auth)
      .send({});
    expect(sync.body.result).toBe('NOT_CAPTURED');
    expect(sync.body.capturable).toEqual({ paymentId: 'pay_Auth6', amountPaise: MONTHLY });

    const capture = await request(app)
      .post(`/admin/subscriptions/payments/${orderId}/capture`)
      .set(admin.auth)
      .send({});
    expect(capture.status).toBe(200);
    expect(capture.body.result).toBe('APPLIED');
    expect(client.capturePayment).toHaveBeenCalledWith('pay_Auth6', MONTHLY);
    expect((await CatalogSubscription.findOne({ catalogId }))?.status).toBe('ACTIVE');

    const twice = await request(app)
      .post(`/admin/subscriptions/payments/${orderId}/capture`)
      .set(admin.auth)
      .send({});
    expect(twice.body.code).toBe('ALREADY_RECORDED');
  });

  it('refuses to capture an amount that is not the order amount', async () => {
    const { owner, admin } = await delegated();
    const orderId = await openOrder(owner.auth);
    const client = fakeRazorpay({
      fetchOrder: vi.fn(async (id: string) => ({ id, status: 'attempted' as const, amount: MONTHLY })),
      fetchPaymentsForOrder: vi.fn(async () => [
        { id: 'pay_Odd6', status: 'authorized', amount: MONTHLY - 5 },
      ]),
    });
    setRazorpayClient(client);
    const res = await request(app)
      .post(`/admin/subscriptions/payments/${orderId}/capture`)
      .set(admin.auth)
      .send({});
    expect(res.status).toBe(409);
    expect(res.body.code).toBe('CAPTURE_AMOUNT_MISMATCH');
    expect(client.capturePayment).not.toHaveBeenCalled();
  });
});

describe('#7 refunding the payment that bought the running period', () => {
  it('says the period is still running', async () => {
    const { owner, admin, catalogId } = await delegated();
    const orderId = await openOrder(owner.auth);
    await recordOnlinePayment({ orderId, paymentId: 'pay_Refund7', amountPaise: MONTHLY, via: 'WEBHOOK' });
    const paid = await PaymentRecord.findOne({ kind: 'PAID', providerOrderId: orderId });
    await request(app)
      .post(`/admin/catalogs/${catalogId.toHexString()}/subscription/refund`)
      .set(admin.auth)
      .send({ refundsPaymentId: String(paid!._id), note: LONG_NOTE, override: true })
      .expect(201);

    const refunded = (await entry(admin.auth, orderId)).body.attempt;
    expect(refunded.stage).toBe('REFUNDED');
    expect(refunded.canRefund).toBe(false);
    const catalogStep = refunded.steps.find((s: { key: string }) => s.key === 'CATALOG');
    expect(catalogStep.state).toBe('FAILED');
    expect(catalogStep.detail).toMatch(/still running/);
  });
});

describe('#8 look up any Razorpay id', () => {
  const lookup = (auth: Auth, id: string) =>
    request(app).get('/admin/subscriptions/payments/lookup').query({ id }).set(auth);

  it('finds a recorded payment, an order, an unrecorded payment on a known order', async () => {
    const { owner, admin } = await delegated();
    const recorded = await openOrder(owner.auth);
    await recordOnlinePayment({ orderId: recorded, paymentId: 'pay_Known8', amountPaise: MONTHLY, via: 'WEBHOOK' });
    await expireAllOrders();
    const pending = await openOrder(owner.auth);

    expect((await lookup(admin.auth, 'pay_Known8')).body).toMatchObject({
      outcome: 'ON_LEDGER',
      orderId: recorded,
    });
    expect((await lookup(admin.auth, pending)).body).toMatchObject({
      outcome: 'ON_LEDGER',
      orderId: pending,
    });

    setRazorpayClient(
      fakeRazorpay({
        fetchPayment: vi.fn(async (id: string) => ({
          id,
          status: 'captured',
          amount: MONTHLY,
          orderId: pending,
          notes: {},
        })),
      })
    );
    expect((await lookup(admin.auth, 'pay_OnPending')).body).toMatchObject({
      outcome: 'ON_LEDGER',
      orderId: pending,
    });
  });

  it('shows a payment our ledger never saw, with the catalog its notes name', async () => {
    const { admin, catalogId } = await delegated();
    await Catalog.updateOne({ _id: catalogId }, { $set: { name: 'green_bistro' } });
    setRazorpayClient(
      fakeRazorpay({
        fetchPayment: vi.fn(async (id: string) => ({
          id,
          status: 'captured',
          amount: MONTHLY,
          orderId: 'order_Stranger1',
          notes: { catalogId: catalogId.toHexString() },
        })),
      })
    );
    const res = await lookup(admin.auth, 'pay_Stranger1');
    expect(res.status).toBe(200);
    expect(res.body).toMatchObject({
      outcome: 'NOT_ON_LEDGER',
      provider: { id: 'pay_Stranger1', status: 'captured', amountPaise: MONTHLY },
      catalog: { id: catalogId.toHexString(), name: 'green bistro' },
    });
    // Nothing written by looking.
    expect(await PaymentRecord.countDocuments({})).toBe(0);
  });

  it('refuses a malformed id and is ADMIN-only', async () => {
    const { admin, rep } = await delegated();
    expect((await lookup(admin.auth, 'hello')).status).toBe(400);
    expect((await lookup(rep.auth, 'pay_Anything1')).status).toBe(403);
  });
});

describe('#9 find an owner by phone or email', () => {
  it('matches the end of the phone (4+ digits) and part of the email; never returns them', async () => {
    const { owner, admin, catalogId } = await delegated();
    await User.updateOne(
      { _id: owner.id },
      { $set: { phone: '+919264981073', email: 'asha@example.com' } }
    );
    await Catalog.updateOne({ _id: catalogId }, { $set: { name: 'blue_cafe' } });
    await CatalogSubscription.create({
      catalogId,
      userId: owner.id,
      status: 'ACTIVE',
      source: 'ONLINE',
      planId: 'TASTE',
      periodStart: new Date(Date.now() - DAY_MS),
      periodEnd: new Date(Date.now() + 29 * DAY_MS),
      threeDDishCap: 10,
    });
    const search = (q: string) =>
      request(app).get('/admin/subscriptions').query({ state: 'ALL', q }).set(admin.auth);

    const byPhone = await search('1073');
    expect(byPhone.body.items.map((i: { catalogName: string }) => i.catalogName)).toEqual(['blue cafe']);
    expect(JSON.stringify(byPhone.body)).not.toMatch(/9264981073|asha@/);
    expect((await search('asha@exam')).body.items).toHaveLength(1);
    // Too short to be a phone search, and no name matches.
    expect((await search('73')).body.items).toHaveLength(0);
  });
});

describe('#10 dates in the sentences are India dates', () => {
  it('20:00 UTC is already the next day in India', () => {
    expect(day(new Date('2026-09-23T20:00:00.000Z'))).toBe('24 Sep 2026');
    expect(day(new Date('2026-09-23T10:00:00.000Z'))).toBe('23 Sep 2026');
  });
});
