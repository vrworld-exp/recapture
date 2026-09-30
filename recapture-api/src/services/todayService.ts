// src/services/todayService.ts
//
// The "Today" screen (more-customization Stage 14.1–14.2): every dish in one
// dense list, stock switches and prices changed in ONE batch, bulk price
// changes with rounding and a 7-day undo, and "sold out until tomorrow".
//
// ONE WRITE PATH FOR OWNER, MANAGER AND STAFF. The caller passes the actor and
// its role; every change is checked against staffPermissions here, not only at
// the route, so no future route can forget. Each batch bumps draftRevision
// ONCE and, when asked, requests an ordinary publish — the planner diffs and
// pushes only the dishes that changed, which is what makes "sold out" live in
// seconds.
import { Types } from 'mongoose';

import { Catalog } from '@/models/Catalog';
import { CatalogCategory } from '@/models/CatalogCategory';
import { CatalogChangeLog, type ChangeKind } from '@/models/CatalogChangeLog';
import { CatalogProduct } from '@/models/CatalogProduct';
import { bumpDraftRevision } from '@/services/catalogService';
import { requestPublish } from '@/services/catalogPublishService';
import { can, type ActorRole } from '@/services/staff/staffPermissions';
import { withOutlet } from '@/services/catalog/outletScope';

export interface Actor {
  userId: string;
  name: string;
  role: ActorRole;
}

type CatalogRef = { _id: Types.ObjectId; userId: Types.ObjectId };

const DAY_MS = 86_400_000;
export const PRICE_UNDO_WINDOW_MS = 7 * DAY_MS;

// ── List ───────────────────────────────────────────────────────────────────

export interface TodayDishDto {
  id: string;
  name: string;
  price: number | null;
  availability: 'IN_STOCK' | 'OUT_OF_STOCK';
  /** When "sold out until tomorrow" puts it back. */
  backInStockAt: string | null;
  categoryId: string | null;
  foodType: string;
}

export interface TodayDto {
  categories: { id: string | null; name: string; dishes: TodayDishDto[] }[];
  /** The newest bulk price change that can still be undone, if any. */
  undoablePriceChange: { id: string; at: string; count: number; by: string } | null;
  lastChanges: { at: string; by: string; kind: ChangeKind; text: string }[];
}

export async function getToday(catalog: CatalogRef, now = new Date()): Promise<TodayDto> {
  const [categories, products, lastBulk, recent] = await Promise.all([
    CatalogCategory.find({ catalogId: catalog._id, deletedAt: null })
      .sort({ position: 1 })
      .lean()
      .exec(),
    CatalogProduct.find({ catalogId: catalog._id, deletedAt: null, archivedAt: null })
      .sort({ position: 1, _id: 1 })
      .select({
        _id: 1,
        name: 1,
        price: 1,
        availability: 1,
        availabilityResetAt: 1,
        categoryId: 1,
        foodType: 1,
      })
      .lean()
      .exec(),
    CatalogChangeLog.findOne({
      catalogId: catalog._id,
      kind: 'BULK_PRICE',
      undoneAt: null,
      at: { $gte: new Date(now.getTime() - PRICE_UNDO_WINDOW_MS) },
    })
      .sort({ at: -1 })
      .lean()
      .exec(),
    CatalogChangeLog.find({ catalogId: catalog._id }).sort({ at: -1 }).limit(20).lean().exec(),
  ]);

  const dto = (p: (typeof products)[number]): TodayDishDto => ({
    id: String(p._id),
    name: p.name,
    price: typeof p.price === 'number' ? p.price : null,
    availability: p.availability,
    backInStockAt: p.availabilityResetAt ? p.availabilityResetAt.toISOString() : null,
    categoryId: p.categoryId ? String(p.categoryId) : null,
    foodType: p.foodType,
  });
  const groups = categories.map((c) => ({
    id: String(c._id),
    name: c.name,
    dishes: products.filter((p) => String(p.categoryId ?? '') === String(c._id)).map(dto),
  }));
  const known = new Set(categories.map((c) => String(c._id)));
  const loose = products.filter((p) => !p.categoryId || !known.has(String(p.categoryId))).map(dto);
  if (loose.length)
    groups.push({ id: null as unknown as string, name: 'Other dishes', dishes: loose });

  return {
    categories: groups.filter((g) => g.dishes.length > 0),
    undoablePriceChange: lastBulk
      ? {
          id: String(lastBulk._id),
          at: lastBulk.at.toISOString(),
          count: lastBulk.changes.length,
          by: lastBulk.actorName,
        }
      : null,
    lastChanges: recent.map((r) => ({
      at: r.at.toISOString(),
      by: r.actorName,
      kind: r.kind,
      text: describeChange(r.kind, r.changes),
    })),
  };
}

const rupees = (v: unknown): string => (typeof v === 'number' ? `Rs ${v}` : 'no price');

function describeChange(
  kind: ChangeKind,
  changes: { productName: string; from: unknown; to: unknown }[]
): string {
  const first = changes[0];
  const name = (first?.productName ?? '').replace(/_/g, ' ');
  switch (kind) {
    case 'AVAILABILITY':
      return first?.to === 'OUT_OF_STOCK' ? `marked ${name} sold out` : `marked ${name} in stock`;
    case 'AUTO_BACK_IN_STOCK':
      return changes.length === 1
        ? `${name} back in stock`
        : `${changes.length} dishes back in stock`;
    case 'PRICE':
      return `changed ${name} from ${rupees(first?.from)} to ${rupees(first?.to)}`;
    case 'BULK_PRICE':
      return `changed ${changes.length} prices`;
    case 'UNDO_PRICE':
      return `undid a price change (${changes.length} dishes)`;
  }
}

// ── Batch of changes ───────────────────────────────────────────────────────

export interface TodayChange {
  productId: string;
  availability?: 'IN_STOCK' | 'OUT_OF_STOCK';
  /** With OUT_OF_STOCK: back in stock at 05:00 IST tomorrow. */
  untilTomorrow?: boolean;
  /** A new price; null clears it. */
  price?: number | null;
}

export type TodayRejection = 'FORBIDDEN' | 'NOT_FOUND' | 'NOTHING_TO_DO';

/** 05:00 in Asia/Kolkata on the day after `now`'s IST date. */
export function nextMorningIst(now: Date): Date {
  const ist = new Date(now.getTime() + 5.5 * 3_600_000);
  const next = Date.UTC(ist.getUTCFullYear(), ist.getUTCMonth(), ist.getUTCDate() + 1, 5, 0);
  return new Date(next - 5.5 * 3_600_000);
}

async function logChange(
  catalogId: Types.ObjectId,
  actor: Actor | null,
  kind: ChangeKind,
  changes: { productId: Types.ObjectId; productName: string; from: unknown; to: unknown }[]
) {
  if (changes.length === 0) return null;
  return CatalogChangeLog.create({
    catalogId,
    actorUserId: actor ? new Types.ObjectId(actor.userId) : null,
    actorName: actor?.name ?? 'ReCapture',
    kind,
    changes,
  });
}

/** Requests a publish of the owner's catalog; never throws (the draft is saved either way). */
async function publishQuietly(catalog: CatalogRef): Promise<string> {
  try {
    // Stage 16: publish THIS outlet — the sweep runs outside any request.
    const result = await withOutlet(catalog._id, () => requestPublish(String(catalog.userId)));
    return result.outcome;
  } catch {
    return 'FAILED';
  }
}

export async function applyTodayChanges(
  catalog: CatalogRef,
  actor: Actor,
  changes: TodayChange[],
  opts: { publish: boolean },
  now = new Date()
): Promise<
  | { outcome: 'REJECTED'; code: TodayRejection }
  | { outcome: 'OK'; changed: number; publish: string | null }
> {
  if (changes.length === 0) return { outcome: 'REJECTED', code: 'NOTHING_TO_DO' };
  // Every change is checked before anything is written: all or nothing.
  for (const c of changes) {
    if ((c.availability !== undefined || c.untilTomorrow) && !can(actor.role, 'availability')) {
      return { outcome: 'REJECTED', code: 'FORBIDDEN' };
    }
    if (c.price !== undefined && !can(actor.role, 'prices'))
      return { outcome: 'REJECTED', code: 'FORBIDDEN' };
  }
  if (opts.publish && !can(actor.role, 'publish'))
    return { outcome: 'REJECTED', code: 'FORBIDDEN' };

  const ids = changes
    .filter((c) => Types.ObjectId.isValid(c.productId))
    .map((c) => new Types.ObjectId(c.productId));
  const products = await CatalogProduct.find({
    _id: { $in: ids },
    catalogId: catalog._id,
    deletedAt: null,
  })
    .select({ _id: 1, name: 1, price: 1, availability: 1 })
    .lean()
    .exec();
  if (products.length !== new Set(ids.map(String)).size)
    return { outcome: 'REJECTED', code: 'NOT_FOUND' };
  const byId = new Map(products.map((p) => [String(p._id), p]));

  const ops: Parameters<typeof CatalogProduct.bulkWrite>[0] = [];
  const availabilityLog: Parameters<typeof logChange>[3] = [];
  const priceLog: Parameters<typeof logChange>[3] = [];
  for (const c of changes) {
    const p = byId.get(c.productId)!;
    const set: Record<string, unknown> = {};
    const unset: Record<string, 1> = {};
    if (c.availability) {
      set.availability = c.availability;
      if (c.availability === 'OUT_OF_STOCK' && c.untilTomorrow)
        set.availabilityResetAt = nextMorningIst(now);
      else unset.availabilityResetAt = 1;
      if (c.availability !== p.availability) {
        availabilityLog.push({
          productId: p._id,
          productName: p.name,
          from: p.availability,
          to: c.availability,
        });
      }
    }
    if (c.price !== undefined) {
      if (c.price === null) unset.price = 1;
      else set.price = Math.round(c.price * 100) / 100;
      const to = c.price === null ? null : Math.round(c.price * 100) / 100;
      if (to !== (p.price ?? null))
        priceLog.push({ productId: p._id, productName: p.name, from: p.price ?? null, to });
    }
    if (Object.keys(set).length || Object.keys(unset).length) {
      ops.push({
        updateOne: {
          filter: { _id: p._id, catalogId: catalog._id },
          update: {
            ...(Object.keys(set).length ? { $set: set } : {}),
            ...(Object.keys(unset).length ? { $unset: unset } : {}),
          },
        },
      });
    }
  }
  if (ops.length) await CatalogProduct.bulkWrite(ops);
  const changed = availabilityLog.length + priceLog.length;
  if (changed) await bumpDraftRevision(catalog._id);
  // One log row per dish so the list reads "Ravi marked X sold out".
  for (const entry of availabilityLog) await logChange(catalog._id, actor, 'AVAILABILITY', [entry]);
  for (const entry of priceLog) await logChange(catalog._id, actor, 'PRICE', [entry]);

  const publish = opts.publish && changed ? await publishQuietly(catalog) : null;
  return { outcome: 'OK', changed, publish };
}

// ── Bulk prices (14.2) ─────────────────────────────────────────────────────

export const ROUNDINGS = ['NONE', 'FIVE', 'NINE'] as const;
export type Rounding = (typeof ROUNDINGS)[number];

export interface BulkPriceInput {
  productIds?: string[];
  categoryIds?: string[];
  mode: 'PERCENT' | 'FLAT';
  /** +5 = up 5 % (or ₹5); -10 = down. */
  amount: number;
  rounding: Rounding;
}

/** The new price, or null when the result would not be a real price (≤ 0). */
export function bulkPrice(
  base: number,
  mode: 'PERCENT' | 'FLAT',
  amount: number,
  rounding: Rounding
): number | null {
  const raw = mode === 'PERCENT' ? base * (1 + amount / 100) : base + amount;
  let p: number;
  switch (rounding) {
    case 'FIVE':
      p = Math.round(raw / 5) * 5;
      break;
    case 'NINE':
      // Nearest price ending in 9: 262 → 259, 266 → 269, 12 → 9.
      p = Math.round((raw + 1) / 10) * 10 - 1;
      break;
    default:
      p = Math.round(raw);
  }
  return p > 0 ? p : null;
}

async function bulkTargets(catalog: CatalogRef, input: BulkPriceInput) {
  const ids = (input.productIds ?? [])
    .filter((id) => Types.ObjectId.isValid(id))
    .map((id) => new Types.ObjectId(id));
  const cats = (input.categoryIds ?? [])
    .filter((id) => Types.ObjectId.isValid(id))
    .map((id) => new Types.ObjectId(id));
  if (!ids.length && !cats.length) return [];
  return CatalogProduct.find({
    catalogId: catalog._id,
    deletedAt: null,
    archivedAt: null,
    price: { $gt: 0 },
    $or: [
      ...(ids.length ? [{ _id: { $in: ids } }] : []),
      ...(cats.length ? [{ categoryId: { $in: cats } }] : []),
    ],
  })
    .select({ _id: 1, name: 1, price: 1 })
    .lean()
    .exec();
}

export interface BulkPreviewRow {
  productId: string;
  name: string;
  from: number;
  to: number | null;
}

export async function previewBulkPrices(
  catalog: CatalogRef,
  input: BulkPriceInput
): Promise<BulkPreviewRow[]> {
  const products = await bulkTargets(catalog, input);
  return products.map((p) => ({
    productId: String(p._id),
    name: p.name,
    from: p.price as number,
    to: bulkPrice(p.price as number, input.mode, input.amount, input.rounding),
  }));
}

/** ONE bulkWrite, ONE draftRevision bump, ONE undoable log row. */
export async function applyBulkPrices(
  catalog: CatalogRef,
  actor: Actor,
  input: BulkPriceInput
): Promise<
  | { outcome: 'REJECTED'; code: TodayRejection }
  | { outcome: 'OK'; changed: number; batchId: string | null }
> {
  if (!can(actor.role, 'prices')) return { outcome: 'REJECTED', code: 'FORBIDDEN' };
  const rows = (await previewBulkPrices(catalog, input)).filter(
    (r) => r.to !== null && r.to !== r.from
  );
  if (rows.length === 0) return { outcome: 'OK', changed: 0, batchId: null };
  await CatalogProduct.bulkWrite(
    rows.map((r) => ({
      updateOne: {
        filter: { _id: new Types.ObjectId(r.productId), catalogId: catalog._id },
        update: { $set: { price: r.to as number } },
      },
    }))
  );
  await bumpDraftRevision(catalog._id);
  const log = await logChange(
    catalog._id,
    actor,
    'BULK_PRICE',
    rows.map((r) => ({
      productId: new Types.ObjectId(r.productId),
      productName: r.name,
      from: r.from,
      to: r.to,
    }))
  );
  return { outcome: 'OK', changed: rows.length, batchId: log ? String(log._id) : null };
}

/**
 * Undoes the newest bulk price change (≤ 7 days old): each dish goes back to
 * its exact old price — unless someone has changed that dish's price since,
 * in which case it is left alone and counted as `kept`.
 */
export async function undoLastBulkPrices(
  catalog: CatalogRef,
  actor: Actor,
  now = new Date()
): Promise<
  { outcome: 'REJECTED'; code: TodayRejection } | { outcome: 'OK'; restored: number; kept: number }
> {
  if (!can(actor.role, 'prices')) return { outcome: 'REJECTED', code: 'FORBIDDEN' };
  const batch = await CatalogChangeLog.findOne({
    catalogId: catalog._id,
    kind: 'BULK_PRICE',
    undoneAt: null,
    at: { $gte: new Date(now.getTime() - PRICE_UNDO_WINDOW_MS) },
  })
    .sort({ at: -1 })
    .exec();
  if (!batch) return { outcome: 'REJECTED', code: 'NOTHING_TO_DO' };

  const restoredRows: Parameters<typeof logChange>[3] = [];
  let kept = 0;
  for (const c of batch.changes) {
    const res = await CatalogProduct.updateOne(
      { _id: c.productId, catalogId: catalog._id, deletedAt: null, price: c.to as number },
      { $set: { price: c.from as number } }
    ).exec();
    if (res.modifiedCount)
      restoredRows.push({
        productId: c.productId,
        productName: c.productName,
        from: c.to,
        to: c.from,
      });
    else kept += 1;
  }
  batch.undoneAt = now;
  await batch.save();
  if (restoredRows.length) {
    await bumpDraftRevision(catalog._id);
    await logChange(catalog._id, actor, 'UNDO_PRICE', restoredRows);
  }
  return { outcome: 'OK', restored: restoredRows.length, kept };
}

// ── Publish (staff) ────────────────────────────────────────────────────────

export async function publishFromToday(
  catalog: CatalogRef,
  actor: Actor
): Promise<{ outcome: 'REJECTED'; code: TodayRejection } | { outcome: 'OK'; publish: string }> {
  if (!can(actor.role, 'publish')) return { outcome: 'REJECTED', code: 'FORBIDDEN' };
  return { outcome: 'OK', publish: await publishQuietly(catalog) };
}

// ── Sweep: sold out until tomorrow ─────────────────────────────────────────

/**
 * Periodic: dishes whose "sold out until" has come are put back in stock, one
 * draft bump per catalog, and published catalogs are re-published.
 */
export async function runAvailabilityResetSweep(
  now = new Date()
): Promise<{ dishes: number; catalogs: number }> {
  const due = await CatalogProduct.find({ availabilityResetAt: { $lte: now }, deletedAt: null })
    .select({ _id: 1, catalogId: 1, name: 1 })
    .limit(2000)
    .lean()
    .exec();
  if (due.length === 0) return { dishes: 0, catalogs: 0 };

  const byCatalog = new Map<string, typeof due>();
  for (const p of due) {
    const key = String(p.catalogId);
    byCatalog.set(key, [...(byCatalog.get(key) ?? []), p]);
  }
  for (const [catalogId, dishes] of byCatalog) {
    const cid = new Types.ObjectId(catalogId);
    await CatalogProduct.updateMany(
      { _id: { $in: dishes.map((d) => d._id) }, availabilityResetAt: { $lte: now } },
      { $set: { availability: 'IN_STOCK' }, $unset: { availabilityResetAt: 1 } }
    ).exec();
    await bumpDraftRevision(cid);
    await logChange(
      cid,
      null,
      'AUTO_BACK_IN_STOCK',
      dishes.map((d) => ({
        productId: d._id,
        productName: d.name,
        from: 'OUT_OF_STOCK',
        to: 'IN_STOCK',
      }))
    );
    const catalog = await Catalog.findOne({ _id: cid, deletedAt: null, status: 'PUBLISHED' })
      .select({ _id: 1, userId: 1 })
      .lean<CatalogRef>()
      .exec();
    if (catalog) await publishQuietly(catalog);
  }
  return { dishes: due.length, catalogs: byCatalog.size };
}
