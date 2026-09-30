// src/services/customersService.ts
//
// The owner's WhatsApp-offers list (more-customization Stage 12.2).
//
// PULL, NOT PUSH — the same shape as the analytics proxy. Mirage stores each
// sign-up; `syncCustomers` reads the owner's own restaurant's rows (restaurant
// FORCED from the catalog mapping, never client-supplied) changed since the last
// pull and upserts them here. It runs when the owner opens the Customers screen,
// so there is no background job and nothing to schedule.
//
// SENDING IS OUT OF SCOPE. The owner gets the list, a CSV (opted-out excluded,
// every export audit-logged) and a copy-message helper; bulk WhatsApp needs the
// Business API and is a separate design.
import { Types } from 'mongoose';

import { Catalog } from '@/models/Catalog';
import { CustomerContact, type ICustomerContact } from '@/models/CustomerContact';
import { getMirageClient, isMirageConfigured, MirageError } from '@/services/mirage';
import { track, AnalyticsEvent } from '@/utils/analytics';

/** Contacts with no activity (sign-up / re-sign-up) for this long are deleted. */
export const CUSTOMER_RETENTION_MS = 24 * 30 * 24 * 60 * 60 * 1000;
/** Mirage's page size — a full page means "there may be more". */
const PULL_PAGE = 500;
/** Never loop forever on a misbehaving source. */
const MAX_PAGES = 20;

export interface CustomerDto {
  id: string;
  name: string | null;
  phone: string;
  birthday: { day: number; month: number } | null;
  consentAt: string;
  consentVersion: string;
  optedOut: boolean;
}

export interface CustomerListDto {
  customers: CustomerDto[];
  /** Everyone still subscribed. */
  subscribed: number;
  optedOut: number;
  /** Subscribed contacts whose birthday falls in the next 7 days (today included). */
  birthdaysThisWeek: CustomerDto[];
  /** False when Mirage could not be reached — the list is what we had. */
  fresh: boolean;
  optInEnabled: boolean;
}

const toDto = (c: ICustomerContact): CustomerDto => ({
  id: String(c._id),
  name: c.name || null,
  phone: c.phone,
  birthday: c.birthday ? { day: c.birthday.day, month: c.birthday.month } : null,
  consentAt: c.consentAt.toISOString(),
  consentVersion: c.consentVersion,
  optedOut: Boolean(c.optedOutAt),
});

// ── Pull ───────────────────────────────────────────────────────────────────

const str = (v: unknown): string => (typeof v === 'string' ? v : '');

/**
 * Pulls every opt-in changed since the catalog's cursor. Returns false when
 * Mirage could not be reached (the caller shows the stored list, marked stale).
 */
export async function syncCustomers(catalog: {
  _id: Types.ObjectId;
  mirageRestaurantId?: string;
  customersSyncedAt?: Date;
}): Promise<boolean> {
  if (!catalog.mirageRestaurantId || !isMirageConfigured()) return false;
  const client = getMirageClient();
  if (!client.listOptIns) return false;

  let since = catalog.customersSyncedAt ?? null;
  try {
    for (let page = 0; page < MAX_PAGES; page += 1) {
      const rows = await client.listOptIns(catalog.mirageRestaurantId, since);
      for (const r of rows) {
        // Second lock on the scope, as in the analytics proxy: a row naming
        // another restaurant is dropped, never stored on this catalog.
        if (str(r.restaurantId) !== catalog.mirageRestaurantId) continue;
        const b = r.birthday as { day?: unknown; month?: unknown } | null;
        await CustomerContact.updateOne(
          { catalogId: catalog._id, mirageOptInId: str(r.id) },
          {
            $set: {
              phone: str(r.phone),
              name: str(r.name) || undefined,
              ...(b && typeof b.day === 'number' && typeof b.month === 'number'
                ? { birthday: { day: b.day, month: b.month } }
                : {}),
              consentText: str(r.consentText),
              consentVersion: str(r.consentVersion),
              consentAt: new Date(str(r.consentAt)),
              optedOutAt: r.optedOutAt ? new Date(str(r.optedOutAt)) : null,
            },
          },
          { upsert: true, runValidators: true }
        ).exec();
      }
      const last = rows[rows.length - 1];
      if (last) since = new Date(str(last.updatedAt));
      if (rows.length < PULL_PAGE) break;
    }
  } catch (err) {
    if (!(err instanceof MirageError)) throw err;
    console.warn(`[customers] pull unavailable (${err.code})`);
    return false;
  } finally {
    if (since && since !== catalog.customersSyncedAt) {
      await Catalog.updateOne({ _id: catalog._id }, { $set: { customersSyncedAt: since } }).exec();
    }
  }

  // Retention: 24 months with no sign-up activity.
  await CustomerContact.deleteMany({
    catalogId: catalog._id,
    consentAt: { $lt: new Date(Date.now() - CUSTOMER_RETENTION_MS) },
  }).exec();
  return true;
}

// ── Owner reads / writes ───────────────────────────────────────────────────

async function ownedCatalog(userId: string) {
  return Catalog.findOne({ userId: new Types.ObjectId(userId), deletedAt: null })
    .select({ _id: 1, mirageRestaurantId: 1, customersSyncedAt: 1, customers: 1 })
    .lean<{
      _id: Types.ObjectId;
      mirageRestaurantId?: string;
      customersSyncedAt?: Date;
      customers?: { optInEnabled?: boolean };
    }>()
    .exec();
}

/** Birthdays (day, month) in the 7 days starting `now` (Asia/Kolkata calendar). */
export function isBirthdayWithinWeek(birthday: { day: number; month: number }, now: Date): boolean {
  const ist = new Date(now.getTime() + 5.5 * 60 * 60 * 1000);
  for (let i = 0; i < 7; i += 1) {
    const d = new Date(Date.UTC(ist.getUTCFullYear(), ist.getUTCMonth(), ist.getUTCDate() + i));
    if (d.getUTCDate() === birthday.day && d.getUTCMonth() + 1 === birthday.month) return true;
  }
  return false;
}

export async function listCustomers(
  userId: string,
  query: { q?: string; now?: Date } = {}
): Promise<{ outcome: 'NOT_FOUND' } | { outcome: 'OK'; list: CustomerListDto }> {
  const catalog = await ownedCatalog(userId);
  if (!catalog) return { outcome: 'NOT_FOUND' };
  const fresh = await syncCustomers(catalog);

  const rows = await CustomerContact.find({ catalogId: catalog._id }).sort({ consentAt: -1 }).exec();
  const all = rows.map(toDto);
  const q = (query.q ?? '').trim().toLowerCase();
  const digits = q.replace(/\D/g, '');
  const customers = q
    ? all.filter(
        (c) =>
          (c.name ?? '').toLowerCase().includes(q) || (digits.length >= 3 && c.phone.includes(digits))
      )
    : all;
  const now = query.now ?? new Date();
  const subscribed = all.filter((c) => !c.optedOut);
  return {
    outcome: 'OK',
    list: {
      customers,
      subscribed: subscribed.length,
      optedOut: all.length - subscribed.length,
      birthdaysThisWeek: subscribed.filter((c) => c.birthday && isBirthdayWithinWeek(c.birthday, now)),
      fresh,
      optInEnabled: catalog.customers?.optInEnabled === true,
    },
  };
}

const csvCell = (v: string): string => {
  // Neutralise spreadsheet formulas (CSV injection) and quote everything.
  const safe = /^[=+\-@]/.test(v) && !/^\+91\d{10}$/.test(v) ? `'${v}` : v;
  return `"${safe.replace(/"/g, '""')}"`;
};

/**
 * The CSV the owner downloads. OPTED-OUT CONTACTS ARE NEVER IN IT. Every export
 * is audit-logged (who, which catalog, how many rows) — never the numbers.
 */
export async function exportCustomersCsv(
  userId: string
): Promise<{ outcome: 'NOT_FOUND' } | { outcome: 'OK'; csv: string; count: number }> {
  const catalog = await ownedCatalog(userId);
  if (!catalog) return { outcome: 'NOT_FOUND' };
  await syncCustomers(catalog);
  const rows = await CustomerContact.find({ catalogId: catalog._id, optedOutAt: null })
    .sort({ consentAt: -1 })
    .exec();
  const lines = [
    ['Name', 'WhatsApp', 'Birthday', 'Agreed on'].map(csvCell).join(','),
    ...rows.map((c) =>
      [
        c.name ?? '',
        c.phone,
        c.birthday ? `${c.birthday.day}/${c.birthday.month}` : '',
        c.consentAt.toISOString().slice(0, 10),
      ]
        .map(csvCell)
        .join(',')
    ),
  ];
  track(AnalyticsEvent.CUSTOMERS_EXPORTED, {
    catalog_id: catalog._id.toHexString(),
    user_id: userId,
    count: rows.length,
  });
  console.info(`[customers] export by ${userId} of ${catalog._id.toHexString()}: ${rows.length} rows`);
  return { outcome: 'OK', csv: `${lines.join('\n')}\n`, count: rows.length };
}

/** The owner marks a contact opted out (they replied STOP). Kept, excluded from exports. */
export async function markCustomerOptedOut(
  userId: string,
  customerId: string
): Promise<{ outcome: 'NOT_FOUND' | 'OK' }> {
  const catalog = await ownedCatalog(userId);
  if (!catalog || !Types.ObjectId.isValid(customerId)) return { outcome: 'NOT_FOUND' };
  const res = await CustomerContact.updateOne(
    { _id: new Types.ObjectId(customerId), catalogId: catalog._id },
    { $set: { optedOutAt: new Date() } }
  ).exec();
  return { outcome: res.matchedCount ? 'OK' : 'NOT_FOUND' };
}

/** Deletes one contact here AND at Mirage, so the next pull does not bring it back. */
export async function deleteCustomer(
  userId: string,
  customerId: string
): Promise<{ outcome: 'NOT_FOUND' | 'OK' | 'UNAVAILABLE' }> {
  const catalog = await ownedCatalog(userId);
  if (!catalog || !Types.ObjectId.isValid(customerId)) return { outcome: 'NOT_FOUND' };
  const row = await CustomerContact.findOne({
    _id: new Types.ObjectId(customerId),
    catalogId: catalog._id,
  }).exec();
  if (!row) return { outcome: 'NOT_FOUND' };
  if (catalog.mirageRestaurantId && isMirageConfigured()) {
    const client = getMirageClient();
    try {
      await client.deleteOptIn?.(catalog.mirageRestaurantId, row.mirageOptInId);
    } catch (err) {
      if (!(err instanceof MirageError)) throw err;
      return { outcome: 'UNAVAILABLE' };
    }
  }
  await row.deleteOne();
  return { outcome: 'OK' };
}
