// tests/customers-links.test.ts
//
// more-customization Stage 12:
//   • 12.1 the review link must be Google's.
//   • 12.2 the WhatsApp-offers list: pulled from Mirage scoped to the owner's
//     restaurant, opted-out contacts never exported, every export audit-logged,
//     24-month retention, delete reaches Mirage, birthdays this week.
//   • 12.3 delivery links only on each platform's own domain.
import { describe, it, expect, beforeAll, afterAll, afterEach, vi } from 'vitest';
import mongoose, { Types } from 'mongoose';
import { MongoMemoryServer } from 'mongodb-memory-server';

import { Catalog } from '@/models/Catalog';
import { CustomerContact } from '@/models/CustomerContact';
import {
  CUSTOMER_RETENTION_MS,
  deleteCustomer,
  exportCustomersCsv,
  isBirthdayWithinWeek,
  listCustomers,
} from '@/services/customersService';
import { resetMirageClient, setMirageClient } from '@/services/mirage';
import * as analytics from '@/utils/analytics';
import { engagementSchema, linksSchema } from '@/validation/catalogSchemas';
import { FakeMirage } from './fixtures/mirageFake';

// ── Validation ──────────────────────────────────────────────────────────────

describe('review link (12.1)', () => {
  it('accepts Google review links only', () => {
    for (const url of [
      'https://search.google.com/local/writereview?placeid=ChIJabc',
      'https://g.page/r/abc/review',
      'https://maps.app.goo.gl/xyz',
    ]) {
      expect(engagementSchema.safeParse({ reviewUrl: url }).success).toBe(true);
    }
    for (const url of ['https://www.zomato.com/cafe/reviews', 'http://g.page/r/abc', 'https://google.com.evil.io/x']) {
      expect(engagementSchema.safeParse({ reviewUrl: url }).success).toBe(false);
    }
  });
});

describe('delivery & booking links (12.3)', () => {
  it('accepts each platform only on its own domain, https', () => {
    expect(linksSchema.safeParse({ zomato: 'https://www.zomato.com/pune/cafe' }).success).toBe(true);
    expect(linksSchema.safeParse({ swiggy: 'https://www.swiggy.com/restaurants/cafe-1' }).success).toBe(true);
    expect(linksSchema.safeParse({ zomato: 'http://www.zomato.com/pune/cafe' }).success).toBe(false);
    expect(linksSchema.safeParse({ zomato: 'https://www.swiggy.com/x' }).success).toBe(false);
    expect(linksSchema.safeParse({ zomato: 'https://zomato.com.evil.io/x' }).success).toBe(false);
  });

  it('validates the booking target by type', () => {
    expect(linksSchema.safeParse({ booking: { type: 'WHATSAPP', value: '98765 43210' } }).success).toBe(true);
    expect(linksSchema.safeParse({ booking: { type: 'PHONE', value: '123' } }).success).toBe(false);
    expect(linksSchema.safeParse({ booking: { type: 'URL', value: 'http://book.me' } }).success).toBe(false);
  });
});

// ── Customer list (12.2) ────────────────────────────────────────────────────

class OptInMirage extends FakeMirage {
  rows: Record<string, unknown>[] = [];
  deleted: string[] = [];
  async listOptIns(_restaurantId: string, since: Date | null) {
    return this.rows.filter((r) => !since || new Date(String(r.updatedAt)) > since);
  }
  async deleteOptIn(_restaurantId: string, id: string) {
    this.deleted.push(id);
  }
}

let mongod: MongoMemoryServer;
let mirage: OptInMirage;

beforeAll(async () => {
  mongod = await MongoMemoryServer.create();
  await mongoose.connect(mongod.getUri());
  await CustomerContact.syncIndexes();
});

afterAll(async () => {
  await mongoose.disconnect();
  await mongod.stop();
});

afterEach(async () => {
  resetMirageClient();
  vi.restoreAllMocks();
  await Promise.all([Catalog.deleteMany({}), CustomerContact.deleteMany({})]);
});

async function seed() {
  const userId = new Types.ObjectId();
  const restaurantId = new Types.ObjectId().toHexString();
  await Catalog.create({
    userId,
    name: 'Cafe',
    status: 'PUBLISHED',
    draftRevision: 1,
    publishedRevision: 1,
    mirageRestaurantId: restaurantId,
    publicUrl: `https://menu.test/${restaurantId}`,
    publicUrlScheme: 'MIRAGE_OBJECT_ID',
    customers: { optInEnabled: true },
  });
  const row = (id: string, phone: string, extra: Record<string, unknown> = {}) => ({
    id,
    restaurantId,
    phone,
    name: `Name ${id}`,
    birthday: null,
    consentText: 'I agree to receive offers from Cafe on WhatsApp. I can opt out anytime.',
    consentVersion: 'v1',
    consentAt: new Date().toISOString(),
    optedOutAt: null,
    updatedAt: new Date().toISOString(),
    ...extra,
  });
  mirage = new OptInMirage();
  mirage.rows = [
    row('a', '+919876543210'),
    row('b', '+919876543211', { optedOutAt: new Date().toISOString() }),
    // Another restaurant's row leaking through must never land here.
    row('x', '+919876543212', { restaurantId: 'someone-else' }),
    row('c', '+919876543213', { name: '=HYPERLINK("evil")' }),
  ];
  setMirageClient(mirage);
  return { userId: String(userId) };
}

describe('customer list (12.2)', () => {
  it('pulls this restaurant only, and counts subscribed vs opted out', async () => {
    const { userId } = await seed();
    const result = await listCustomers(userId);
    if (result.outcome !== 'OK') throw new Error('expected OK');
    expect(result.list.fresh).toBe(true);
    expect(result.list.customers.map((c) => c.phone).sort()).toEqual([
      '+919876543210',
      '+919876543211',
      '+919876543213',
    ]);
    expect(result.list.subscribed).toBe(2);
    expect(result.list.optedOut).toBe(1);
    expect(result.list.optInEnabled).toBe(true);
  });

  it('never exports opted-out contacts, neutralises formulas, and audit-logs the export', async () => {
    const { userId } = await seed();
    const spy = vi.spyOn(analytics, 'track');
    const result = await exportCustomersCsv(userId);
    if (result.outcome !== 'OK') throw new Error('expected OK');
    expect(result.count).toBe(2);
    expect(result.csv).toContain('+919876543210');
    expect(result.csv).not.toContain('+919876543211');
    expect(result.csv).toContain(`"'=HYPERLINK(""evil"")"`);
    expect(spy).toHaveBeenCalledWith('customers_exported', expect.objectContaining({ count: 2 }));
  });

  it('deletes at Mirage too, so the next pull does not bring it back', async () => {
    const { userId } = await seed();
    const list = await listCustomers(userId);
    if (list.outcome !== 'OK') throw new Error('expected OK');
    const target = list.list.customers.find((c) => c.phone === '+919876543210')!;
    expect(await deleteCustomer(userId, target.id)).toEqual({ outcome: 'OK' });
    expect(mirage.deleted).toEqual(['a']);
  });

  it('deletes contacts with no activity for 24 months', async () => {
    const { userId } = await seed();
    const old = new Date(Date.now() - CUSTOMER_RETENTION_MS - 86_400_000).toISOString();
    mirage.rows = mirage.rows.map((r) => (r.id === 'a' ? { ...r, consentAt: old } : r));
    const result = await listCustomers(userId);
    if (result.outcome !== 'OK') throw new Error('expected OK');
    expect(result.list.customers.some((c) => c.phone === '+919876543210')).toBe(false);
  });

  it('finds birthdays in the next seven days (IST)', () => {
    const now = new Date('2026-09-28T12:00:00+05:30');
    expect(isBirthdayWithinWeek({ day: 28, month: 9 }, now)).toBe(true);
    expect(isBirthdayWithinWeek({ day: 4, month: 10 }, now)).toBe(true);
    expect(isBirthdayWithinWeek({ day: 5, month: 10 }, now)).toBe(false);
  });
});
