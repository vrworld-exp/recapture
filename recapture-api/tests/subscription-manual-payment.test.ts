// tests/subscription-manual-payment.test.ts
//
// Door 3. What this file most exists to pin:
//   • A REP SUBMITS, AN ADMIN DECIDES. The rep's route writes a PENDING row
//     and touches no subscription (AC-6.1); the rep gets 403 on the admin
//     route (AC-6.2); only VERIFIED applies a period (AC-6.3), once.
//   • BOTH ACTORS ARE STORED even when they are one person (AC-6.4).
//   • THE AMOUNT IS CHECKED AT VERIFY, not after activation (E12); a deleted
//     catalog auto-rejects the request (E37).
//   • The queue and the decision route are ADMIN, not MODEL_ARTIST (E39).
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
import { rejectPendingOnCatalogDelete } from '@/services/subscription/manualPaymentService';
import {
  DAY_MS,
  delegated,
  emitted,
  makeUser,
  seedSubscription,
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
});

afterEach(async () => {
  vi.restoreAllMocks();
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
const repPath = (id: Types.ObjectId | string) =>
  `/rep/catalogs/${id}/subscription/manual-payment-request`;
const adminPath = (id: Types.ObjectId | string) =>
  `/admin/catalogs/${id}/subscription/manual-payment`;
const QUEUE = '/admin/subscriptions/manual-payments';

const cashRequest = (overrides: Record<string, unknown> = {}) => ({
  planId: 'TASTE',
  interval: 'MONTHLY',
  amountPaise: MONTHLY,
  method: 'CASH',
  reference: 'receipt-book-0042',
  ...overrides,
});

async function submit(auth: Auth, catalogId: Types.ObjectId, overrides = {}) {
  const res = await request(app).post(repPath(catalogId)).set(auth).send(cashRequest(overrides));
  expect(res.status).toBe(201);
  return res.body.paymentRecord as { id: string };
}

describe('POST /rep/catalogs/:id/subscription/manual-payment-request', () => {
  it('writes a PENDING_VERIFICATION row and touches no subscription (AC-6.1)', async () => {
    const { rep, catalogId } = await delegated();

    const res = await request(app)
      .post(repPath(catalogId))
      .set(rep.auth)
      .send(cashRequest({ note: 'paid at the counter' }));

    expect(res.status).toBe(201);
    expect(res.body.status).toBe('success');
    expect(res.body.paymentRecord).toMatchObject({
      catalogId: catalogId.toHexString(),
      planId: 'TASTE',
      interval: 'MONTHLY',
      quotedPaise: MONTHLY,
      amountPaise: MONTHLY,
      amountMatchesQuote: true,
      method: 'CASH',
      reference: 'receipt-book-0042',
      note: 'paid at the counter',
      verificationStatus: 'PENDING_VERIFICATION',
      initiatedBy: { userId: String(rep.id), role: 'SALES_REP' },
      collectedBy: { userId: String(rep.id), role: 'SALES_REP' },
      verifiedBy: null,
      verifiedAt: null,
    });
    expect(res.body.paymentRecord.receiptNo).toMatch(/^RC-[0-9A-F]{8}$/);

    const row = await PaymentRecord.findOne({ catalogId }).lean().exec();
    expect(row).toMatchObject({ kind: 'MANUAL', verificationStatus: 'PENDING_VERIFICATION' });
    expect(row!.quote!.planSnapshot.includedStandeeCount).toBe(10);
    expect(await CatalogSubscription.countDocuments({ catalogId })).toBe(0);
    expect(emitted('subscription_manual_payment_submitted')).toEqual([
      expect.objectContaining({ method: 'CASH', amount_paise: MONTHLY }),
    ]);
  });

  it('returns the pending request unchanged on a second submit (existing: true)', async () => {
    const { rep, catalogId } = await delegated();
    const first = await submit(rep.auth, catalogId);

    const res = await request(app)
      .post(repPath(catalogId))
      .set(rep.auth)
      .send(cashRequest({ amountPaise: 1, method: 'UPI' }));

    expect(res.status).toBe(200);
    expect(res.body.existing).toBe(true);
    expect(res.body.paymentRecord.id).toBe(first.id);
    expect(res.body.paymentRecord.amountPaise).toBe(MONTHLY);
    expect(await PaymentRecord.countDocuments({ kind: 'MANUAL' })).toBe(1);
  });

  it('names another collector when told to, and refuses an unknown one', async () => {
    const { rep, catalogId } = await delegated();
    const colleague = await makeUser('SALES_REP');
    const res = await request(app)
      .post(repPath(catalogId))
      .set(rep.auth)
      .send(cashRequest({ collectedByUserId: colleague.id.toHexString() }));
    expect(res.status).toBe(201);
    expect(res.body.paymentRecord.collectedBy).toEqual({
      userId: String(colleague.id),
      role: 'SALES_REP',
    });

    const other = await delegated();
    const unknown = await request(app)
      .post(repPath(other.catalogId))
      .set(other.rep.auth)
      .send(cashRequest({ collectedByUserId: new Types.ObjectId().toHexString() }));
    expect(unknown.status).toBe(422);
    expect(unknown.body.code).toBe('COLLECTOR_NOT_FOUND');
  });

  it('is bounded by the delegation and strict about the body', async () => {
    const { rep, catalogId } = await delegated();
    const stranger = await makeUser('SALES_REP');
    expect(
      (await request(app).post(repPath(catalogId)).set(stranger.auth).send(cashRequest())).status
    ).toBe(404);

    for (const body of [
      cashRequest({ amountPaise: 0 }),
      cashRequest({ amountPaise: 10.5 }),
      cashRequest({ method: 'CARD' }),
      cashRequest({ reference: '' }),
      cashRequest({ verificationStatus: 'VERIFIED' }),
      cashRequest({ markPaid: true }),
    ]) {
      const res = await request(app).post(repPath(catalogId)).set(rep.auth).send(body);
      expect(res.status).toBe(400);
    }
    expect(await PaymentRecord.countDocuments({})).toBe(0);
  });

  it('GET answers the pending request, or null once it is decided', async () => {
    const { rep, admin, catalogId } = await delegated();
    const empty = await request(app).get(repPath(catalogId)).set(rep.auth);
    expect(empty.status).toBe(200);
    expect(empty.body.paymentRecord).toBeNull();

    const pending = await submit(rep.auth, catalogId);
    const withOne = await request(app).get(repPath(catalogId)).set(rep.auth);
    expect(withOne.body.paymentRecord).toMatchObject({
      id: pending.id,
      verificationStatus: 'PENDING_VERIFICATION',
    });

    await request(app)
      .post(adminPath(catalogId))
      .set(admin.auth)
      .send({ action: 'REJECT', paymentRecordId: pending.id, note: 'no' })
      .expect(200);
    expect(
      (await request(app).get(repPath(catalogId)).set(rep.auth)).body.paymentRecord
    ).toBeNull();

    const stranger = await makeUser('SALES_REP');
    expect((await request(app).get(repPath(catalogId)).set(stranger.auth)).status).toBe(404);
  });

  it('has no Pay, no refund and no mark-paid on /rep (AC-5.1, AC-6.5)', async () => {
    const { rep, catalogId } = await delegated();
    for (const path of [
      `/rep/catalogs/${catalogId}/subscription/manual-payment`,
      `/rep/catalogs/${catalogId}/subscription/refund`,
      `/rep/catalogs/${catalogId}/subscription/comp`,
      `/rep/catalogs/${catalogId}/subscription/order`,
    ]) {
      const res = await request(app).post(path).set(rep.auth).send({});
      expect(res.status).toBe(404);
    }
  });
});

describe('POST /admin/catalogs/:id/subscription/manual-payment', () => {
  it('VERIFY activates with source MANUAL and stores both actors (AC-6.3, AC-6.4)', async () => {
    const { rep, admin, catalogId } = await delegated();
    const pending = await submit(rep.auth, catalogId);

    const res = await request(app)
      .post(adminPath(catalogId))
      .set(admin.auth)
      .send({ action: 'VERIFY', paymentRecordId: pending.id });

    expect(res.status).toBe(200);
    expect(res.body.paymentRecord).toMatchObject({
      verificationStatus: 'VERIFIED',
      initiatedBy: { userId: String(rep.id), role: 'SALES_REP' },
      verifiedBy: { userId: String(admin.id), role: 'ADMIN' },
    });
    expect(res.body.paymentRecord.verifiedAt).not.toBeNull();
    expect(res.body.subscription).toMatchObject({
      status: 'ACTIVE',
      planId: 'TASTE',
      daysLeft: 30,
    });

    const row = await CatalogSubscription.findOne({ catalogId }).lean().exec();
    expect(row).toMatchObject({ status: 'ACTIVE', source: 'MANUAL', threeDDishCap: 10 });
    expect(row!.periodEnd.getTime() - row!.periodStart.getTime()).toBe(30 * DAY_MS);
    expect(row!.standeeAllocation.included).toBe(10);
    expect(emitted('subscription_manual_payment_decided')).toEqual([
      expect.objectContaining({ decision: 'VERIFIED', same_actor: false }),
    ]);
    expect(emitted('subscription_payment_recorded')).toEqual([
      expect.objectContaining({ source: 'MANUAL', via: 'ADMIN', previous_status: 'NONE' }),
    ]);
  });

  it('VERIFY twice: the second is 409 ALREADY_DECIDED and the period was applied once', async () => {
    const { rep, admin, catalogId } = await delegated();
    const pending = await submit(rep.auth, catalogId);
    const body = { action: 'VERIFY', paymentRecordId: pending.id };

    await request(app).post(adminPath(catalogId)).set(admin.auth).send(body).expect(200);
    const first = await CatalogSubscription.findOne({ catalogId }).lean().exec();
    await new Promise((r) => setTimeout(r, 5));
    const second = await request(app).post(adminPath(catalogId)).set(admin.auth).send(body);

    expect(second.status).toBe(409);
    expect(second.body.code).toBe('ALREADY_DECIDED');
    const again = await CatalogSubscription.findOne({ catalogId }).lean().exec();
    expect(again!.periodStart.getTime()).toBe(first!.periodStart.getTime());
    expect(emitted('subscription_payment_recorded')).toHaveLength(1);
  });

  it('a rep on the admin route is 403 FORBIDDEN, and so is a MODEL_ARTIST (AC-6.2, E39)', async () => {
    const { rep, catalogId } = await delegated();
    const pending = await submit(rep.auth, catalogId);
    const artist = await makeUser('MODEL_ARTIST');
    for (const auth of [rep.auth, artist.auth]) {
      const res = await request(app)
        .post(adminPath(catalogId))
        .set(auth)
        .send({ action: 'VERIFY', paymentRecordId: pending.id });
      expect(res.status).toBe(403);
      expect(res.body.code).toBe('FORBIDDEN');
    }
    const row = await PaymentRecord.findById(pending.id).lean().exec();
    expect(row!.verificationStatus).toBe('PENDING_VERIFICATION');
    expect(await CatalogSubscription.countDocuments({ catalogId })).toBe(0);
  });

  it('REJECT needs a note, writes no subscription, and stores who rejected', async () => {
    const { rep, admin, catalogId } = await delegated();
    const pending = await submit(rep.auth, catalogId);

    const noNote = await request(app)
      .post(adminPath(catalogId))
      .set(admin.auth)
      .send({ action: 'REJECT', paymentRecordId: pending.id });
    expect(noNote.status).toBe(400);

    const res = await request(app)
      .post(adminPath(catalogId))
      .set(admin.auth)
      .send({ action: 'REJECT', paymentRecordId: pending.id, note: 'cheque bounced' });
    expect(res.status).toBe(200);
    expect(res.body.paymentRecord).toMatchObject({
      verificationStatus: 'REJECTED',
      note: 'cheque bounced',
      verifiedBy: { userId: String(admin.id), role: 'ADMIN' },
    });
    expect(await CatalogSubscription.countDocuments({ catalogId })).toBe(0);

    // A rejected request is no longer "the pending one": the rep may submit again.
    const again = await request(app).post(repPath(catalogId)).set(rep.auth).send(cashRequest());
    expect(again.status).toBe(201);
  });

  it('amount ≠ quote: 422 AMOUNT_MISMATCH until an override with a real note (E12)', async () => {
    const { rep, admin, catalogId } = await delegated();
    const pending = await submit(rep.auth, catalogId, { amountPaise: 100_000 });

    const plain = await request(app)
      .post(adminPath(catalogId))
      .set(admin.auth)
      .send({ action: 'VERIFY', paymentRecordId: pending.id });
    expect(plain.status).toBe(422);
    expect(plain.body).toMatchObject({
      code: 'AMOUNT_MISMATCH',
      quotedPaise: MONTHLY,
      amountPaise: 100_000,
    });

    const shortNote = await request(app)
      .post(adminPath(catalogId))
      .set(admin.auth)
      .send({ action: 'VERIFY', paymentRecordId: pending.id, override: true, note: 'discount' });
    expect(shortNote.status).toBe(422);
    expect(await CatalogSubscription.countDocuments({ catalogId })).toBe(0);

    const explained = await request(app).post(adminPath(catalogId)).set(admin.auth).send({
      action: 'VERIFY',
      paymentRecordId: pending.id,
      override: true,
      note: 'Launch-week discount agreed by founder, ₹1,000 accepted for Taste.',
    });
    expect(explained.status).toBe(200);
    expect((await CatalogSubscription.findOne({ catalogId }).lean().exec())!.status).toBe('ACTIVE');
    expect(emitted('subscription_payment_recorded')[0]).toMatchObject({ amount_paise: 100_000 });
  });

  it('CREATE_AND_VERIFY: one call, both halves, both actors the admin (AC-6.4)', async () => {
    const { admin, catalogId } = await delegated();

    const res = await request(app)
      .post(adminPath(catalogId))
      .set(admin.auth)
      .send({ action: 'CREATE_AND_VERIFY', ...cashRequest({ method: 'BANK_TRANSFER' }) });

    expect(res.status).toBe(200);
    expect(res.body.paymentRecord).toMatchObject({
      verificationStatus: 'VERIFIED',
      method: 'BANK_TRANSFER',
      initiatedBy: { userId: String(admin.id), role: 'ADMIN' },
      verifiedBy: { userId: String(admin.id), role: 'ADMIN' },
    });
    expect(res.body.subscription.status).toBe('ACTIVE');
    expect(emitted('subscription_manual_payment_decided')).toEqual([
      expect.objectContaining({ decision: 'VERIFIED', same_actor: true }),
    ]);
  });

  it('a catalog that is gone: 409 CATALOG_DELETED and the request auto-rejected (E37)', async () => {
    const { rep, admin, catalogId } = await delegated();
    const pending = await submit(rep.auth, catalogId);
    await Catalog.deleteOne({ _id: catalogId });

    const res = await request(app)
      .post(adminPath(catalogId))
      .set(admin.auth)
      .send({ action: 'VERIFY', paymentRecordId: pending.id });

    expect(res.status).toBe(409);
    expect(res.body.code).toBe('CATALOG_DELETED');
    const row = await PaymentRecord.findById(pending.id).lean().exec();
    expect(row).toMatchObject({ verificationStatus: 'REJECTED', note: 'CATALOG_DELETED' });
    expect(await CatalogSubscription.countDocuments({ catalogId })).toBe(0);
  });

  it('DELETE /catalog rejects every pending request (E37, the service half)', async () => {
    const { rep, catalogId } = await delegated();
    const pending = await submit(rep.auth, catalogId);
    const other = await delegated();
    const otherPending = await submit(other.rep.auth, other.catalogId);

    expect(await rejectPendingOnCatalogDelete(catalogId)).toBe(1);

    expect((await PaymentRecord.findById(pending.id).lean().exec())!.verificationStatus).toBe(
      'REJECTED'
    );
    expect((await PaymentRecord.findById(otherPending.id).lean().exec())!.verificationStatus).toBe(
      'PENDING_VERIFICATION'
    );
  });

  it('a request from another catalog is 404 PAYMENT_NOT_FOUND', async () => {
    const { rep, admin, catalogId } = await delegated();
    const other = await delegated();
    const pending = await submit(other.rep.auth, other.catalogId);
    void rep;
    const res = await request(app)
      .post(adminPath(catalogId))
      .set(admin.auth)
      .send({ action: 'VERIFY', paymentRecordId: pending.id });
    expect(res.status).toBe(404);
    expect(res.body.code).toBe('PAYMENT_NOT_FOUND');
  });

  it('VERIFY on a paused restaurant reports the resume in the service result and clears pausedAt', async () => {
    const { rep, admin, catalogId, owner } = await delegated();
    await seedSubscription(catalogId, owner.id, 'PAUSED', { pausedAt: new Date() });
    const pending = await submit(rep.auth, catalogId);
    await request(app)
      .post(adminPath(catalogId))
      .set(admin.auth)
      .send({ action: 'VERIFY', paymentRecordId: pending.id })
      .expect(200);
    const row = await CatalogSubscription.findOne({ catalogId }).lean().exec();
    expect(row!.status).toBe('ACTIVE');
    expect(row!.pausedAt ?? null).toBeNull();
    expect(emitted('subscription_payment_recorded')[0]).toMatchObject({
      previous_status: 'PAUSED',
    });
  });
});

describe('GET /admin/subscriptions/manual-payments', () => {
  it('lists the pending queue newest first with a catalog name and no owner contact', async () => {
    const a = await delegated();
    const b = await delegated();
    await Catalog.updateOne({ _id: b.catalogId }, { $set: { name: 'cafe_mocha' } });
    await submit(a.rep.auth, a.catalogId);
    await new Promise((r) => setTimeout(r, 5));
    const bPending = await submit(b.rep.auth, b.catalogId);

    const res = await request(app).get(QUEUE).set(a.admin.auth);

    expect(res.status).toBe(200);
    expect(res.body.items).toHaveLength(2);
    expect(res.body.items[0]).toMatchObject({
      id: bPending.id,
      catalogId: b.catalogId.toHexString(),
      catalogName: 'cafe mocha',
      verificationStatus: 'PENDING_VERIFICATION',
    });
    expect(JSON.stringify(res.body)).not.toMatch(/phone|email|authUid/);

    const verified = await request(app).get(`${QUEUE}?status=VERIFIED`).set(a.admin.auth);
    expect(verified.body.items).toEqual([]);
  });

  it('is ADMIN only: a MODEL_ARTIST is 403 (E39)', async () => {
    const artist = await makeUser('MODEL_ARTIST');
    const res = await request(app).get(QUEUE).set(artist.auth);
    expect(res.status).toBe(403);
  });
});
