// tests/subscription-receipt.test.ts
//
// G3 — the owner's receipt PDF (§7 rule 7). What this file pins:
//   • A valid one-page PDF for a PAID row: the receipt number, the plan, the
//     period, the amount in rupees and the no-GST sentence are in the text;
//     no phone number and no "invoice" anywhere; xref offsets walk back to
//     their objects; the same row renders the same bytes twice.
//   • 404 PAYMENT_NOT_FOUND — the same body — for a CHECKOUT_CREATED row, a
//     pending MANUAL row, a REFUNDED row, another owner's row, a garbage id.
//   • MANUAL(VERIFIED) and COMP have receipts; a flagged PAID row still has
//     one (the money was taken) and says no period was applied.
//   • Headers: application/pdf, attachment filename, Cache-Control: no-store.
import { describe, it, expect, beforeAll, afterAll, beforeEach, afterEach, vi } from 'vitest';
import request from 'supertest';
import mongoose, { Types } from 'mongoose';
import { MongoMemoryServer } from 'mongodb-memory-server';

import { createApp } from '@/app';
import { Catalog } from '@/models/Catalog';
import { CatalogDelegation } from '@/models/CatalogDelegation';
import { CatalogSubscription } from '@/models/CatalogSubscription';
import { PaymentRecord } from '@/models/PaymentRecord';
import { User } from '@/models/User';
import { DEFAULT_PLAN_CATALOG } from '@/config/subscriptionPlans';
import {
  RECEIPT_NO_GST_LINE,
  formatInrPaise,
  formatReceiptDate,
} from '@/services/subscription/receiptPdf';
import { delegated, emitted, makeUser, seedCatalog } from './helpers/subscriptionPayments';

const app = createApp();
let mongod: MongoMemoryServer;

beforeAll(async () => {
  mongod = await MongoMemoryServer.create();
  await mongoose.connect(mongod.getUri());
  await Promise.all([Catalog.syncIndexes(), CatalogDelegation.syncIndexes(), PaymentRecord.syncIndexes()]);
});

afterAll(async () => {
  await mongoose.disconnect();
  await mongod.stop();
});

beforeEach(() => {
  vi.spyOn(console, 'log').mockImplementation(() => {});
});

afterEach(async () => {
  vi.restoreAllMocks();
  await Promise.all([
    User.deleteMany({}),
    Catalog.deleteMany({}),
    CatalogDelegation.deleteMany({}),
    CatalogSubscription.deleteMany({}),
    PaymentRecord.deleteMany({}),
  ]);
});

const MONTHLY = DEFAULT_PLAN_CATALOG.plans.TASTE.priceMonthlyPaise;
const quote = {
  planId: 'TASTE',
  interval: 'MONTHLY',
  totalPaise: MONTHLY,
  planSnapshot: DEFAULT_PLAN_CATALOG.plans.TASTE,
};
const receiptPath = (id: unknown) => `/catalog/subscription/payments/${String(id)}/receipt`;

/** The PDF's text-showing strings, unescaped — what a reader would draw. */
function textOf(pdf: Buffer): string {
  return [...pdf.toString('latin1').matchAll(/\((.*?)\) Tj/g)]
    .map((m) => m[1]!.replace(/\\([()\\])/g, '$1'))
    .join('\n');
}

function fetchReceipt(auth: { Authorization: string }, id: unknown) {
  return request(app).get(receiptPath(id)).set(auth).buffer(true).parse((res, cb) => {
    const chunks: Buffer[] = [];
    res.on('data', (c: Buffer) => chunks.push(c));
    res.on('end', () => cb(null, Buffer.concat(chunks)));
  });
}

describe('GET /catalog/subscription/payments/:paymentId/receipt', () => {
  it('returns a one-page PDF receipt for a PAID row', async () => {
    const { owner, catalogId } = await delegated();
    // A fixed name: the random seed name is hex, and a hex run can look like a phone number.
    await Catalog.updateOne({ _id: catalogId }, { $set: { name: 'blue_lotus_cafe' } });
    const appliedAt = new Date('2026-09-19T08:00:00.000Z');
    const paid = await PaymentRecord.create({
      catalogId,
      userId: owner.id,
      kind: 'PAID',
      amountPaise: MONTHLY,
      quote,
      providerOrderId: 'order_r1',
      providerPaymentId: 'pay_r1',
      idempotencyKey: 'payment:pay_r1',
      initiatedBy: { userId: owner.id, role: 'USER' },
      appliedAt,
    });

    const res = await fetchReceipt(owner.auth, paid._id);
    expect(res.status).toBe(200);
    expect(res.headers['content-type']).toMatch(/^application\/pdf/);
    const receiptNo = `RC-${String(paid._id).slice(-8).toUpperCase()}`;
    expect(res.headers['content-disposition']).toBe(
      `attachment; filename="receipt-${receiptNo}.pdf"`
    );
    expect(res.headers['cache-control']).toBe('no-store');

    const pdf = res.body as Buffer;
    expect(pdf.subarray(0, 8).toString()).toBe('%PDF-1.4');
    expect(pdf.byteLength).toBeLessThan(100 * 1024);
    const raw = pdf.toString('latin1');
    expect(raw).toContain('/Count 1');
    expect([...raw.matchAll(/\/Type \/Page /g)]).toHaveLength(1);

    const text = textOf(pdf);
    expect(text).toContain('Payment receipt');
    expect(text).toContain(receiptNo);
    expect(text).toContain('Taste plan - monthly');
    expect(text).toContain(`${formatReceiptDate(appliedAt)} to 19 Oct 2026 (30 days)`);
    expect(text).toContain('Rs. 1,199.00');
    expect(text).toContain('Online');
    expect(text).toContain(RECEIPT_NO_GST_LINE);
    // The catalog's display name, never its slug.
    expect(text).toContain('blue lotus cafe');
    expect(text).not.toContain('blue_lotus_cafe');

    // Not a tax document (the word appears only inside the sentence that
    // says it is not one), and nothing to reach the owner by.
    expect(text.replace(RECEIPT_NO_GST_LINE, '').toLowerCase()).not.toContain('invoice');
    expect(text).not.toMatch(/GSTIN/);
    expect(text).not.toMatch(/\d{10}/);
    expect(text).not.toContain('@');
    expect(text).not.toContain('pay_r1');

    expect(emitted('subscription_receipt_downloaded')).toEqual([
      { catalog_id: catalogId.toHexString(), kind: 'PAID' },
    ]);
  });

  it('has a correct xref table and renders the same bytes twice', async () => {
    const { owner, catalogId } = await delegated();
    const paid = await PaymentRecord.create({
      catalogId,
      userId: owner.id,
      kind: 'PAID',
      amountPaise: MONTHLY,
      quote,
      providerOrderId: 'order_r2',
      providerPaymentId: 'pay_r2',
      idempotencyKey: 'payment:pay_r2',
      initiatedBy: { userId: owner.id, role: 'USER' },
      appliedAt: new Date(),
    });

    const first = (await fetchReceipt(owner.auth, paid._id)).body as Buffer;
    const second = (await fetchReceipt(owner.auth, paid._id)).body as Buffer;
    expect(first.equals(second)).toBe(true);

    const pdf = first.toString('latin1');
    const startxref = Number(pdf.slice(pdf.lastIndexOf('startxref') + 9).trim().split('\n')[0]);
    expect(pdf.slice(startxref, startxref + 4)).toBe('xref');
    const offsets = [...pdf.matchAll(/^(\d{10}) 00000 n $/gm)].map((m) => Number(m[1]));
    expect(offsets.length).toBeGreaterThan(0);
    offsets.forEach((offset, i) => {
      expect(pdf.slice(offset, offset + `${i + 1} 0 obj`.length)).toBe(`${i + 1} 0 obj`);
    });
  });

  it('a VERIFIED cash row and a COMP row have receipts with their method', async () => {
    const { owner, rep, admin, catalogId } = await delegated();
    const verifiedAt = new Date('2026-09-01T00:00:00.000Z');
    const cash = await PaymentRecord.create({
      catalogId,
      userId: owner.id,
      kind: 'MANUAL',
      amountPaise: MONTHLY,
      quote,
      method: 'CASH',
      reference: 'book-17',
      verificationStatus: 'VERIFIED',
      verifiedBy: { userId: admin.id, role: 'ADMIN' },
      verifiedAt,
      initiatedBy: { userId: rep.id, role: 'SALES_REP' },
    });
    const comp = await PaymentRecord.create({
      catalogId,
      userId: owner.id,
      kind: 'COMP',
      amountPaise: 0,
      initiatedBy: { userId: admin.id, role: 'ADMIN' },
      note: 'launch partner',
    });

    const cashText = textOf((await fetchReceipt(owner.auth, cash._id)).body as Buffer);
    expect(cashText).toContain('Cash');
    expect(cashText).toContain('book-17');
    expect(cashText).toContain('1 Sep 2026 to 1 Oct 2026 (30 days)');

    const compRes = await fetchReceipt(owner.auth, comp._id);
    expect(compRes.status).toBe(200);
    const compText = textOf(compRes.body as Buffer);
    expect(compText).toContain('Complimentary');
    expect(compText).toContain('Rs. 0.00');
    // The admin's note is not the owner's business.
    expect(compText).not.toContain('launch partner');

    expect(emitted('subscription_receipt_downloaded').map((e) => e.kind)).toEqual(['MANUAL', 'COMP']);
  });

  it('a flagged PAID row still has a receipt, and it says no period was applied', async () => {
    const { owner, catalogId } = await delegated();
    const paid = await PaymentRecord.create({
      catalogId,
      userId: owner.id,
      kind: 'PAID',
      amountPaise: MONTHLY,
      quote,
      providerOrderId: 'order_r3',
      providerPaymentId: 'pay_r3',
      idempotencyKey: 'payment:pay_r3',
      initiatedBy: { userId: owner.id, role: 'USER' },
      appliedAt: new Date(),
      note: 'DUPLICATE_SUSPECTED',
    });
    const res = await fetchReceipt(owner.auth, paid._id);
    expect(res.status).toBe(200);
    const text = textOf(res.body as Buffer);
    expect(text).toContain('Not applied to a plan period');
    expect(text).not.toContain('DUPLICATE_SUSPECTED');
  });

  it('404 PAYMENT_NOT_FOUND, one body, for every row that is not a receipt', async () => {
    const { owner, rep, catalogId } = await delegated();
    const base = { catalogId, userId: owner.id, amountPaise: MONTHLY };
    const open = await PaymentRecord.create({
      ...base,
      kind: 'CHECKOUT_CREATED',
      quote,
      providerOrderId: 'order_open',
      idempotencyKey: 'order:order_open',
      initiatedBy: { userId: owner.id, role: 'USER' },
      expiresAt: new Date(Date.now() + 3_600_000),
    });
    const pending = await PaymentRecord.create({
      ...base,
      kind: 'MANUAL',
      quote,
      method: 'CASH',
      reference: 'r',
      verificationStatus: 'PENDING_VERIFICATION',
      initiatedBy: { userId: rep.id, role: 'SALES_REP' },
    });
    const rejected = await PaymentRecord.create({
      ...base,
      kind: 'MANUAL',
      quote,
      method: 'CASH',
      reference: 'r',
      verificationStatus: 'REJECTED',
      initiatedBy: { userId: rep.id, role: 'SALES_REP' },
    });
    const refund = await PaymentRecord.create({
      ...base,
      kind: 'REFUNDED',
      providerRefundId: 'rfnd_1',
      idempotencyKey: 'refund:rfnd_1',
      initiatedBy: { userId: owner.id, role: 'USER' },
    });
    const disputed = await PaymentRecord.create({
      ...base,
      kind: 'DISPUTED',
      idempotencyKey: 'dispute:disp_1',
      initiatedBy: { userId: owner.id, role: 'USER' },
    });

    for (const id of [open._id, pending._id, rejected._id, refund._id, disputed._id, new Types.ObjectId(), 'garbage']) {
      const res = await request(app).get(receiptPath(id)).set(owner.auth);
      expect(res.status, String(id)).toBe(404);
      expect(res.body).toEqual({
        status: 'error',
        code: 'PAYMENT_NOT_FOUND',
        message: 'That payment was not found.',
      });
    }
    expect(emitted('subscription_receipt_downloaded')).toEqual([]);
  });

  it("another owner's PAID row is the same 404", async () => {
    const { owner, catalogId } = await delegated();
    const paid = await PaymentRecord.create({
      catalogId,
      userId: owner.id,
      kind: 'PAID',
      amountPaise: MONTHLY,
      quote,
      providerOrderId: 'order_o',
      providerPaymentId: 'pay_o',
      idempotencyKey: 'payment:pay_o',
      initiatedBy: { userId: owner.id, role: 'USER' },
      appliedAt: new Date(),
    });
    const other = await makeUser();
    await seedCatalog(other.id);

    const res = await request(app).get(receiptPath(paid._id)).set(other.auth);
    expect(res.status).toBe(404);
    expect(res.body).toMatchObject({ code: 'PAYMENT_NOT_FOUND' });
  });

  it('an owner with no catalog gets the no-catalog answer', async () => {
    const nobody = await makeUser();
    const res = await request(app).get(receiptPath(new Types.ObjectId())).set(nobody.auth);
    expect(res.status).toBe(404);
    expect(res.body.code).not.toBe('PAYMENT_NOT_FOUND');
  });
});

describe('formatInrPaise', () => {
  it('groups the Indian way and always shows paise', () => {
    expect(formatInrPaise(0)).toBe('Rs. 0.00');
    expect(formatInrPaise(99)).toBe('Rs. 0.99');
    expect(formatInrPaise(119900)).toBe('Rs. 1,199.00');
    expect(formatInrPaise(179950)).toBe('Rs. 1,799.50');
    expect(formatInrPaise(12345678)).toBe('Rs. 1,23,456.78');
    expect(formatInrPaise(2099160)).toBe('Rs. 20,991.60');
  });
});
