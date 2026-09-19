// tests/subscription-manual-refund.test.ts
//
// Prompt B / E13 — recording a CASH refund the admin already handed back.
//
// What this file exists to pin:
//   • `manual: true` on a VERIFIED MANUAL row writes exactly ONE REFUNDED row
//     with `reference`, no provider ids, and never calls Razorpay.
//   • The subscription period is untouched (AC-5.4) — on success AND on
//     every refusal.
//   • `manual: true` on a PAID (online) row is 422 USE_PROVIDER_REFUND; on a
//     PENDING or REJECTED cash row 422 NOT_REFUNDABLE.
//   • It is always an override: `override: true` + a note ≥ 30 chars, and
//     `reference` is required at the schema (400 INVALID_REQUEST).
//   • A second attempt is 409 ALREADY_REFUNDED; the audit event says manual.
//   • The plain (online) path is unchanged: it still reaches Razorpay.
import { describe, it, expect, beforeAll, afterAll, beforeEach, afterEach, vi } from 'vitest';
import request from 'supertest';
import mongoose, { Types } from 'mongoose';
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
import { resetRazorpayClient, setRazorpayClient } from '@/providers/razorpay';
import {
  delegated,
  emitted,
  fakeRazorpay,
  seedSubscription,
} from './helpers/subscriptionPayments';

const app = createApp();
let mongod: MongoMemoryServer;
let razorpay: ReturnType<typeof fakeRazorpay>;

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
    RateWindow.deleteMany({}),
    Notification.deleteMany({}),
  ]);
});

const MONTHLY = DEFAULT_PLAN_CATALOG.plans.TASTE.priceMonthlyPaise;
const refundPath = (id: Types.ObjectId) => `/admin/catalogs/${id}/subscription/refund`;
const LONG_NOTE = 'Owner paid cash and online for September; cash handed back at the counter.';

/** A cash row as the rep submitted it and (by default) the admin verified it. */
async function cashRow(
  catalogId: Types.ObjectId,
  ownerId: Types.ObjectId,
  repId: Types.ObjectId,
  adminId: Types.ObjectId,
  overrides: Record<string, unknown> = {}
) {
  return PaymentRecord.create({
    catalogId,
    userId: ownerId,
    kind: 'MANUAL',
    amountPaise: MONTHLY,
    method: 'CASH',
    reference: 'RCPT-0091',
    quote: {
      planId: 'TASTE',
      interval: 'MONTHLY',
      totalPaise: MONTHLY,
      planSnapshot: DEFAULT_PLAN_CATALOG.plans.TASTE,
    },
    verificationStatus: 'VERIFIED',
    verifiedBy: { userId: adminId, role: 'ADMIN' },
    verifiedAt: new Date(),
    initiatedBy: { userId: repId, role: 'SALES_REP' },
    ...overrides,
  });
}

async function onlineRow(catalogId: Types.ObjectId, ownerId: Types.ObjectId) {
  return PaymentRecord.create({
    catalogId,
    userId: ownerId,
    kind: 'PAID',
    amountPaise: MONTHLY,
    providerOrderId: `order_${new Types.ObjectId().toHexString()}`,
    providerPaymentId: `pay_${new Types.ObjectId().toHexString()}`,
    initiatedBy: { userId: ownerId, role: 'USER' },
    appliedAt: new Date(),
    note: 'DUPLICATE_SUSPECTED',
  });
}

const manualBody = (id: Types.ObjectId, extra: Record<string, unknown> = {}) => ({
  refundsPaymentId: String(id),
  note: LONG_NOTE,
  override: true,
  manual: true,
  reference: 'UPI-TXN-77120',
  ...extra,
});

describe('POST /admin/catalogs/:id/subscription/refund — manual: true', () => {
  it('records one REFUNDED row with reference and no provider id; Razorpay untouched; period unchanged', async () => {
    const { admin, rep, owner, catalogId } = await delegated();
    const sub = await seedSubscription(catalogId, owner.id, 'ACTIVE', { source: 'MANUAL' });
    const cash = await cashRow(catalogId, owner.id, rep.id, admin.id, {
      subscriptionId: sub._id,
    });

    const res = await request(app).post(refundPath(catalogId)).set(admin.auth).send(manualBody(cash._id));
    expect(res.status).toBe(201);
    expect(res.body.paymentRecord).toMatchObject({ kind: 'REFUNDED', amountPaise: MONTHLY });

    const refunded = await PaymentRecord.find({ kind: 'REFUNDED' }).lean().exec();
    expect(refunded).toHaveLength(1);
    expect(refunded[0]).toMatchObject({
      amountPaise: MONTHLY,
      currency: 'INR',
      reference: 'UPI-TXN-77120',
      note: LONG_NOTE,
      idempotencyKey: `refund:manual:${String(cash._id)}`,
    });
    expect(refunded[0].providerRefundId).toBeUndefined();
    expect(refunded[0].providerPaymentId).toBeUndefined();
    expect(String(refunded[0].refundsPaymentId)).toBe(String(cash._id));
    expect(String(refunded[0].subscriptionId)).toBe(String(sub._id));
    expect(String(refunded[0].initiatedBy.userId)).toBe(String(admin.id));
    expect(razorpay.createRefund).not.toHaveBeenCalled();

    // The cash row itself is not edited — the ledger is append-only.
    const original = await PaymentRecord.findById(cash._id).lean().exec();
    expect(original!.verificationStatus).toBe('VERIFIED');

    const after = await CatalogSubscription.findOne({ catalogId }).lean().exec();
    expect(after!.status).toBe('ACTIVE');
    expect(after!.periodEnd.getTime()).toBe(sub.periodEnd.getTime());

    expect(emitted('subscription_refund_issued')).toEqual([
      expect.objectContaining({ amount_paise: MONTHLY, override: true, manual: true }),
    ]);
  });

  it('a second attempt is 409 ALREADY_REFUNDED and writes nothing more', async () => {
    const { admin, rep, owner, catalogId } = await delegated();
    const cash = await cashRow(catalogId, owner.id, rep.id, admin.id);
    await request(app).post(refundPath(catalogId)).set(admin.auth).send(manualBody(cash._id)).expect(201);
    const again = await request(app)
      .post(refundPath(catalogId))
      .set(admin.auth)
      .send(manualBody(cash._id, { reference: 'UPI-TXN-OTHER' }));
    expect(again.status).toBe(409);
    expect(again.body.code).toBe('ALREADY_REFUNDED');
    expect(await PaymentRecord.countDocuments({ kind: 'REFUNDED' })).toBe(1);
  });

  it('an online (PAID) row under manual is 422 USE_PROVIDER_REFUND; the period is unchanged', async () => {
    const { admin, owner, catalogId } = await delegated();
    const sub = await seedSubscription(catalogId, owner.id, 'ACTIVE');
    const paid = await onlineRow(catalogId, owner.id);

    const res = await request(app).post(refundPath(catalogId)).set(admin.auth).send(manualBody(paid._id));
    expect(res.status).toBe(422);
    expect(res.body.code).toBe('USE_PROVIDER_REFUND');
    expect(await PaymentRecord.countDocuments({ kind: 'REFUNDED' })).toBe(0);
    expect(razorpay.createRefund).not.toHaveBeenCalled();

    const after = await CatalogSubscription.findOne({ catalogId }).lean().exec();
    expect(after!.periodEnd.getTime()).toBe(sub.periodEnd.getTime());

    // The same row WITHOUT manual takes the provider path as before.
    const online = await request(app)
      .post(refundPath(catalogId))
      .set(admin.auth)
      .send({ refundsPaymentId: String(paid._id), note: 'Charged twice on 12 Sep' });
    expect(online.status).toBe(201);
    expect(razorpay.createRefund).toHaveBeenCalledTimes(1);
    expect(emitted('subscription_refund_issued')).toEqual([
      expect.objectContaining({ manual: false }),
    ]);
  });

  it('a PENDING or REJECTED cash row is 422 NOT_REFUNDABLE', async () => {
    const { admin, rep, owner, catalogId } = await delegated();
    for (const verificationStatus of ['PENDING_VERIFICATION', 'REJECTED'] as const) {
      const row = await cashRow(catalogId, owner.id, rep.id, admin.id, {
        verificationStatus,
        verifiedBy: undefined,
        verifiedAt: undefined,
      });
      const res = await request(app).post(refundPath(catalogId)).set(admin.auth).send(manualBody(row._id));
      expect(res.status).toBe(422);
      expect(res.body.code).toBe('NOT_REFUNDABLE');
    }
    expect(await PaymentRecord.countDocuments({ kind: 'REFUNDED' })).toBe(0);
  });

  it('needs override + a long note (422 OVERRIDE_REQUIRED) and a reference (400 INVALID_REQUEST)', async () => {
    const { admin, rep, owner, catalogId } = await delegated();
    const cash = await cashRow(catalogId, owner.id, rep.id, admin.id);

    const noOverride = await request(app)
      .post(refundPath(catalogId))
      .set(admin.auth)
      .send(manualBody(cash._id, { override: undefined }));
    expect(noOverride.status).toBe(422);
    expect(noOverride.body.code).toBe('OVERRIDE_REQUIRED');

    const shortNote = await request(app)
      .post(refundPath(catalogId))
      .set(admin.auth)
      .send(manualBody(cash._id, { note: 'Cash returned.' }));
    expect(shortNote.status).toBe(422);
    expect(shortNote.body.code).toBe('OVERRIDE_REQUIRED');

    const noReference = await request(app)
      .post(refundPath(catalogId))
      .set(admin.auth)
      .send(manualBody(cash._id, { reference: undefined }));
    expect(noReference.status).toBe(400);
    expect(noReference.body.code).toBe('INVALID_REQUEST');

    expect(await PaymentRecord.countDocuments({ kind: 'REFUNDED' })).toBe(0);
  });

  it('is ADMIN-only', async () => {
    const { admin, rep, owner, catalogId } = await delegated();
    const cash = await cashRow(catalogId, owner.id, rep.id, admin.id);
    for (const who of [rep, owner]) {
      const res = await request(app).post(refundPath(catalogId)).set(who.auth).send(manualBody(cash._id));
      expect(res.status).toBe(403);
    }
    expect(await PaymentRecord.countDocuments({ kind: 'REFUNDED' })).toBe(0);
  });
});
