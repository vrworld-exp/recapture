// tests/subscription-client-verify.test.ts
//
// POST /catalog/subscription/verify — the app's signed checkout response as a
// way in, beside the webhook and the reconciler. What this file pins:
//   • A valid signature + a CAPTURED payment at Razorpay → ACTIVE in the same
//     response, with no webhook.
//   • The amount recorded is Razorpay's, never anything the app sent.
//   • A forged signature, or another catalog's order, activates nothing.
//   • Authorized-but-not-captured, or Razorpay down → 202, nothing recorded.
//   • The webhook arriving afterwards converges on the same PAID row.
import { describe, it, expect, beforeAll, afterAll, beforeEach, afterEach, vi } from 'vitest';
import request from 'supertest';
import mongoose from 'mongoose';
import { MongoMemoryServer } from 'mongodb-memory-server';

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
import {
  resetRazorpayClient,
  setRazorpayClient,
  setRazorpayConfiguredForTests,
  signCheckoutResponse,
} from '@/providers/razorpay';
import { resetOnReadSettleState } from '@/services/subscription/reconcileService';
import {
  delegated,
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

async function openOrder(auth: Auth): Promise<{ orderId: string; amount: number }> {
  const res = await request(app)
    .post('/catalog/subscription/order')
    .set(auth)
    .send({ planId: 'TASTE', interval: 'MONTHLY' });
  expect([200, 201]).toContain(res.status);
  return {
    orderId: res.body.order.providerOrderId as string,
    amount: res.body.order.amountPaise as number,
  };
}

function providerWith(orderId: string, payment: { id: string; status: string; amount: number }) {
  return fakeRazorpay({
    fetchPaymentsForOrder: vi.fn(async (id: string) => (id === orderId ? [payment] : [])),
  });
}

function body(orderId: string, paymentId: string, signature?: string) {
  return {
    orderId,
    paymentId,
    signature: signature ?? signCheckoutResponse(orderId, paymentId, env.RAZORPAY_KEY_SECRET!),
  };
}

describe('POST /catalog/subscription/verify', () => {
  it('activates at once on a valid signature and a captured payment — no webhook', async () => {
    const { owner, catalogId } = await delegated();
    const { orderId, amount } = await openOrder(owner.auth);
    setRazorpayClient(providerWith(orderId, { id: 'pay_ok', status: 'captured', amount }));

    const res = await request(app)
      .post('/catalog/subscription/verify')
      .set(owner.auth)
      .send(body(orderId, 'pay_ok'))
      .expect(200);

    expect(res.body.recorded).toBe(true);
    expect(res.body.subscription.status).toBe('ACTIVE');
    expect(res.body.subscription.planId).toBe('TASTE');
    const paid = await PaymentRecord.findOne({ kind: 'PAID', catalogId }).lean().exec();
    expect(paid).toMatchObject({ providerPaymentId: 'pay_ok', amountPaise: amount });
  });

  it("records Razorpay's amount, not a number the app could have chosen", async () => {
    const { owner } = await delegated();
    const { orderId } = await openOrder(owner.auth);
    const short = DEFAULT_PLAN_CATALOG.plans.TASTE.priceMonthlyPaise - 100;
    setRazorpayClient(providerWith(orderId, { id: 'pay_short', status: 'captured', amount: short }));

    const res = await request(app)
      .post('/catalog/subscription/verify')
      .set(owner.auth)
      .send(body(orderId, 'pay_short'))
      .expect(200);

    // Recorded as what Razorpay captured — and a short payment does not activate.
    const paid = await PaymentRecord.findOne({ kind: 'PAID' }).lean().exec();
    expect(paid!.amountPaise).toBe(short);
    expect(res.body.subscription.status).not.toBe('ACTIVE');
  });

  it('refuses a forged signature and records nothing', async () => {
    const { owner } = await delegated();
    const { orderId, amount } = await openOrder(owner.auth);
    const client = providerWith(orderId, { id: 'pay_x', status: 'captured', amount });
    setRazorpayClient(client);

    const res = await request(app)
      .post('/catalog/subscription/verify')
      .set(owner.auth)
      .send(body(orderId, 'pay_x', signCheckoutResponse(orderId, 'pay_x', 'not-the-secret')))
      .expect(400);

    expect(res.body.code).toBe('INVALID_PAYMENT_SIGNATURE');
    expect(client.fetchPaymentsForOrder).not.toHaveBeenCalled();
    expect(await PaymentRecord.countDocuments({ kind: 'PAID' })).toBe(0);
  });

  it("will not settle another catalog's order", async () => {
    const a = await delegated();
    const b = await delegated();
    const { orderId, amount } = await openOrder(a.owner.auth);
    setRazorpayClient(providerWith(orderId, { id: 'pay_a', status: 'captured', amount }));

    const res = await request(app)
      .post('/catalog/subscription/verify')
      .set(b.owner.auth)
      .send(body(orderId, 'pay_a'))
      .expect(404);

    expect(res.body.code).toBe('ORDER_NOT_FOUND');
    expect(await PaymentRecord.countDocuments({ kind: 'PAID' })).toBe(0);
  });

  it('answers 202 for a payment Razorpay has authorized but not captured yet', async () => {
    const { owner } = await delegated();
    const { orderId, amount } = await openOrder(owner.auth);
    setRazorpayClient(providerWith(orderId, { id: 'pay_auth', status: 'authorized', amount }));

    const res = await request(app)
      .post('/catalog/subscription/verify')
      .set(owner.auth)
      .send(body(orderId, 'pay_auth'))
      .expect(202);

    expect(res.body.recorded).toBe(false);
    expect(await PaymentRecord.countDocuments({ kind: 'PAID' })).toBe(0);
  });

  it('answers 202 when Razorpay cannot be reached — pending, not unpaid', async () => {
    const { owner } = await delegated();
    const { orderId } = await openOrder(owner.auth);
    setRazorpayClient(
      fakeRazorpay({
        fetchOrder: vi.fn(async () => {
          throw new Error('down');
        }),
        fetchPaymentsForOrder: vi.fn(async () => {
          throw new Error('down');
        }),
      })
    );

    const res = await request(app)
      .post('/catalog/subscription/verify')
      .set(owner.auth)
      .send(body(orderId, 'pay_later'))
      .expect(202);
    expect(res.body.recorded).toBe(false);
  });

  it('a webhook arriving afterwards converges on the same PAID row', async () => {
    const { owner, catalogId } = await delegated();
    const { orderId, amount } = await openOrder(owner.auth);
    setRazorpayClient(providerWith(orderId, { id: 'pay_both', status: 'captured', amount }));

    await request(app)
      .post('/catalog/subscription/verify')
      .set(owner.auth)
      .send(body(orderId, 'pay_both'))
      .expect(200);
    const first = await CatalogSubscription.findOne({ catalogId }).lean().exec();

    const signed = signedWebhook(
      paymentCaptured({ orderId, paymentId: 'pay_both', amountPaise: amount })
    );
    await request(app)
      .post('/webhooks/razorpay')
      .set('Content-Type', 'application/json')
      .set('X-Razorpay-Signature', signed.signature)
      .send(signed.body)
      .expect(200);

    expect(await PaymentRecord.countDocuments({ kind: 'PAID' })).toBe(1);
    const after = await CatalogSubscription.findOne({ catalogId }).lean().exec();
    expect(after!.periodEnd!.getTime()).toBe(first!.periodEnd!.getTime());
  });

  it('rejects a body with extra fields (no amount, no plan from the app)', async () => {
    const { owner } = await delegated();
    const { orderId } = await openOrder(owner.auth);
    await request(app)
      .post('/catalog/subscription/verify')
      .set(owner.auth)
      .send({ ...body(orderId, 'pay_extra'), amountPaise: 1 })
      .expect(400);
  });
});
