// src/services/catalogOffersService.ts
//
// Offers, combos and happy-hour pricing (more-customization Stage 10): the
// owner's CRUD, the save-time price checks, the editor's preview, the product
// editor's "On offer" line, and the block the publish sends to Mirage.
//
// EVERY WRITE BUMPS `draftRevision` (D6). An offer goes live on Publish, and
// from then on its time window runs by itself on the public page — the owner
// never republishes to start or stop a happy hour.
//
// PUBLISHED BY NAME (see menuExtras.ts for why): `mirageOffersField` resolves
// every target to the dishes' CURRENT published names at sync time (that
// builder lives in services/catalog/offersBlock.ts), expanding a
// category target to its dishes, and drops anything archived or deleted.
import { Types } from 'mongoose';

import { CatalogCategory } from '@/models/CatalogCategory';
import { CatalogOffer, type ICatalogOffer } from '@/models/CatalogOffer';
import { CatalogProduct } from '@/models/CatalogProduct';
import {
  MAX_ACTIVE_OFFERS,
  type OfferKind,
  type OfferSchedule,
  type OfferTargetType,
} from '@/models/types/offer.types';
import { bumpDraftRevision, findOwnedCatalog } from '@/services/catalogService';
import {
  discountedPrice,
  isOfferLive,
  offerStatus,
  priceFor,
  type OfferStatus,
  type PricedOffer,
} from '@/services/offers/offerPricing';

// ── Input / DTO ────────────────────────────────────────────────────────────

export interface OfferInput {
  name: string;
  kind: OfferKind;
  value?: number;
  target?: { type: OfferTargetType; ids: string[] };
  combo?: { productIds: string[]; price: number; title?: string };
  schedule?: {
    startsAt?: string | null;
    endsAt?: string | null;
    days?: number[];
    from?: string | null;
    to?: string | null;
  };
  active?: boolean;
  priority?: number;
}

export interface OfferDto {
  id: string;
  name: string;
  kind: OfferKind;
  value: number | null;
  target: { type: OfferTargetType; ids: string[] };
  combo: { productIds: string[]; price: number; title: string } | null;
  schedule: {
    startsAt: string | null;
    endsAt: string | null;
    days: number[];
    from: string | null;
    to: string | null;
  };
  active: boolean;
  priority: number;
  status: OfferStatus;
  updatedAt: string;
}

const iso = (d: Date | string | undefined | null): string | null =>
  d ? new Date(d).toISOString() : null;

export function toOfferDto(offer: ICatalogOffer, now = new Date()): OfferDto {
  const s = offer.schedule ?? {};
  return {
    id: String(offer._id),
    name: offer.name,
    kind: offer.kind,
    value: typeof offer.value === 'number' ? offer.value : null,
    target: {
      type: offer.target?.type ?? 'PRODUCTS',
      ids: (offer.target?.ids ?? []).map(String),
    },
    combo: offer.combo
      ? {
          productIds: offer.combo.productIds.map(String),
          price: offer.combo.price,
          title: offer.combo.title ?? offer.name,
        }
      : null,
    schedule: {
      startsAt: iso(s.startsAt),
      endsAt: iso(s.endsAt),
      days: s.days ?? [],
      from: s.from ?? null,
      to: s.to ?? null,
    },
    active: offer.active,
    priority: offer.priority,
    status: offerStatus(offer, now),
    updatedAt: offer.updatedAt.toISOString(),
  };
}

const toPriced = (o: ICatalogOffer): PricedOffer => ({
  id: String(o._id),
  name: o.name,
  kind: o.kind,
  value: o.value,
  priority: o.priority,
  schedule: o.schedule ?? {},
});

// ── Validation ─────────────────────────────────────────────────────────────

export type OfferRejection =
  | 'TARGET_NOT_FOUND'
  | 'OFFER_PRICE_INVALID'
  | 'PRODUCT_HAS_NO_PRICE'
  | 'COMBO_PRICE_INVALID'
  | 'TOO_MANY_OFFERS';

interface ProductLite {
  _id: Types.ObjectId;
  name: string;
  price?: number;
  categoryId?: Types.ObjectId | null;
}

const oid = (id: string): Types.ObjectId => new Types.ObjectId(id);

async function productsIn(catalogId: Types.ObjectId, ids: string[]): Promise<ProductLite[]> {
  const valid = ids.filter((id) => Types.ObjectId.isValid(id));
  if (valid.length !== ids.length) return [];
  return CatalogProduct.find({
    _id: { $in: valid.map(oid) },
    catalogId,
    deletedAt: null,
  })
    .select({ _id: 1, name: 1, price: 1, categoryId: 1 })
    .lean<ProductLite[]>()
    .exec();
}

/** Every live product an offer would touch (schedule ignored). */
async function affectedProducts(
  catalogId: Types.ObjectId,
  input: Pick<OfferInput, 'kind' | 'target' | 'combo'>
): Promise<ProductLite[] | null> {
  if (input.kind === 'COMBO') {
    const ids = input.combo?.productIds ?? [];
    const rows = await productsIn(catalogId, ids);
    return rows.length === new Set(ids).size ? rows : null;
  }
  const target = input.target ?? { type: 'ALL' as const, ids: [] };
  const base = { catalogId, deletedAt: null, archivedAt: null };
  if (target.type === 'ALL') {
    return CatalogProduct.find(base)
      .select({ _id: 1, name: 1, price: 1, categoryId: 1 })
      .lean<ProductLite[]>()
      .exec();
  }
  if (target.type === 'PRODUCTS') {
    const rows = await productsIn(catalogId, target.ids);
    return rows.length === new Set(target.ids).size ? rows : null;
  }
  // CATEGORIES
  if (!target.ids.every((id) => Types.ObjectId.isValid(id))) return null;
  const cats = await CatalogCategory.countDocuments({
    _id: { $in: target.ids.map(oid) },
    catalogId,
    deletedAt: null,
  }).exec();
  if (cats !== new Set(target.ids).size) return null;
  return CatalogProduct.find({ ...base, categoryId: { $in: target.ids.map(oid) } })
    .select({ _id: 1, name: 1, price: 1, categoryId: 1 })
    .lean<ProductLite[]>()
    .exec();
}

/**
 * The save-time price rules. Explicitly chosen dishes must all get a real
 * discount; a category / whole-menu offer simply skips a dish it cannot
 * discount (a ₹50-off offer on a ₹40 chai), which the public page does too.
 */
function checkPrices(
  input: OfferInput,
  products: ProductLite[]
): { ok: true } | { ok: false; code: OfferRejection; message: string } {
  if (input.kind === 'COMBO') {
    const unpriced = products.find((p) => !(typeof p.price === 'number' && p.price > 0));
    if (unpriced) {
      return {
        ok: false,
        code: 'PRODUCT_HAS_NO_PRICE',
        message: `“${unpriced.name}” has no price, so it cannot be in a combo.`,
      };
    }
    const full = products.reduce((sum, p) => sum + (p.price ?? 0), 0);
    const price = input.combo?.price ?? 0;
    if (!(price > 0 && price < full)) {
      return {
        ok: false,
        code: 'COMBO_PRICE_INVALID',
        message: `The combo price must be above zero and below ₹${full} (the dishes' own total).`,
      };
    }
    return { ok: true };
  }

  if (input.target?.type !== 'PRODUCTS') return { ok: true };
  for (const p of products) {
    if (!(typeof p.price === 'number' && p.price > 0)) {
      return {
        ok: false,
        code: 'PRODUCT_HAS_NO_PRICE',
        message: `“${p.name}” has no price, so it cannot be discounted.`,
      };
    }
    if (discountedPrice({ kind: input.kind, value: input.value }, p.price) === null) {
      return {
        ok: false,
        code: 'OFFER_PRICE_INVALID',
        message: `The offer price for “${p.name}” must be above zero and below ₹${p.price}.`,
      };
    }
  }
  return { ok: true };
}

function toSchedule(s: OfferInput['schedule']): OfferSchedule {
  if (!s) return {};
  return {
    ...(s.startsAt ? { startsAt: new Date(s.startsAt) } : {}),
    ...(s.endsAt ? { endsAt: new Date(s.endsAt) } : {}),
    ...(s.days && s.days.length ? { days: [...new Set(s.days)].sort() } : {}),
    ...(s.from && s.to ? { from: s.from, to: s.to } : {}),
  };
}

function toDoc(input: OfferInput): Partial<ICatalogOffer> {
  const combo = input.kind === 'COMBO' && input.combo;
  return {
    name: input.name,
    kind: input.kind,
    ...(input.kind === 'COMBO' ? { value: undefined } : { value: input.value }),
    target:
      input.kind === 'COMBO'
        ? { type: 'PRODUCTS', ids: [] }
        : {
            type: input.target?.type ?? 'ALL',
            ids: (input.target?.type === 'ALL' ? [] : (input.target?.ids ?? [])).map(oid),
          },
    ...(combo
      ? {
          combo: {
            productIds: combo.productIds.map(oid),
            price: combo.price,
            title: combo.title?.trim() || input.name,
          },
        }
      : { combo: undefined }),
    schedule: toSchedule(input.schedule),
    ...(input.active !== undefined ? { active: input.active } : {}),
    ...(input.priority !== undefined ? { priority: input.priority } : {}),
  };
}

async function activeCount(catalogId: Types.ObjectId, exceptId?: Types.ObjectId): Promise<number> {
  return CatalogOffer.countDocuments({
    catalogId,
    deletedAt: null,
    active: true,
    ...(exceptId ? { _id: { $ne: exceptId } } : {}),
  }).exec();
}

// ── CRUD ───────────────────────────────────────────────────────────────────

export type OfferWriteResult =
  | { outcome: 'NO_CATALOG' }
  | { outcome: 'NOT_FOUND' }
  | { outcome: 'REJECTED'; code: OfferRejection; message: string }
  | { outcome: 'OK'; offer: OfferDto };

export async function listOffers(
  userId: string
): Promise<{ outcome: 'NO_CATALOG' } | { outcome: 'OK'; offers: OfferDto[]; maxActive: number }> {
  const catalog = await findOwnedCatalog(userId);
  if (!catalog) return { outcome: 'NO_CATALOG' };
  const rows = await CatalogOffer.find({ catalogId: catalog._id, deletedAt: null })
    .sort({ priority: 1, createdAt: 1 })
    .exec();
  const now = new Date();
  return {
    outcome: 'OK',
    offers: rows.map((r) => toOfferDto(r, now)),
    maxActive: MAX_ACTIVE_OFFERS,
  };
}

async function validate(
  catalogId: Types.ObjectId,
  input: OfferInput,
  exceptId?: Types.ObjectId
): Promise<{ ok: true } | { ok: false; code: OfferRejection; message: string }> {
  const products = await affectedProducts(catalogId, input);
  if (!products) {
    return {
      ok: false,
      code: 'TARGET_NOT_FOUND',
      message: 'One of the chosen dishes or sections no longer exists.',
    };
  }
  const prices = checkPrices(input, products);
  if (!prices.ok) return prices;
  if (input.active !== false && (await activeCount(catalogId, exceptId)) >= MAX_ACTIVE_OFFERS) {
    return {
      ok: false,
      code: 'TOO_MANY_OFFERS',
      message: `You can have up to ${MAX_ACTIVE_OFFERS} offers switched on. Pause or delete one first.`,
    };
  }
  return { ok: true };
}

export async function createOffer(userId: string, input: OfferInput): Promise<OfferWriteResult> {
  const catalog = await findOwnedCatalog(userId);
  if (!catalog) return { outcome: 'NO_CATALOG' };
  const catalogId = catalog._id as Types.ObjectId;
  const check = await validate(catalogId, input);
  if (!check.ok) return { outcome: 'REJECTED', code: check.code, message: check.message };

  const offer = await CatalogOffer.create({ catalogId, ...toDoc(input) });
  await bumpDraftRevision(catalogId);
  return { outcome: 'OK', offer: toOfferDto(offer) };
}

/** Full replace of the editable fields — the editor always sends the whole offer. */
export async function updateOffer(
  userId: string,
  offerId: string,
  input: OfferInput
): Promise<OfferWriteResult> {
  const catalog = await findOwnedCatalog(userId);
  if (!catalog) return { outcome: 'NO_CATALOG' };
  if (!Types.ObjectId.isValid(offerId)) return { outcome: 'NOT_FOUND' };
  const catalogId = catalog._id as Types.ObjectId;
  const existing = await CatalogOffer.findOne({
    _id: oid(offerId),
    catalogId,
    deletedAt: null,
  }).exec();
  if (!existing) return { outcome: 'NOT_FOUND' };

  const check = await validate(catalogId, input, existing._id as Types.ObjectId);
  if (!check.ok) return { outcome: 'REJECTED', code: check.code, message: check.message };

  existing.set(toDoc(input));
  await existing.save();
  await bumpDraftRevision(catalogId);
  return { outcome: 'OK', offer: toOfferDto(existing) };
}

/** The list's toggle: pause / resume without opening the editor. */
export async function setOfferActive(
  userId: string,
  offerId: string,
  active: boolean
): Promise<OfferWriteResult> {
  const catalog = await findOwnedCatalog(userId);
  if (!catalog) return { outcome: 'NO_CATALOG' };
  if (!Types.ObjectId.isValid(offerId)) return { outcome: 'NOT_FOUND' };
  const catalogId = catalog._id as Types.ObjectId;
  const offer = await CatalogOffer.findOne({
    _id: oid(offerId),
    catalogId,
    deletedAt: null,
  }).exec();
  if (!offer) return { outcome: 'NOT_FOUND' };
  if (offer.active === active) return { outcome: 'OK', offer: toOfferDto(offer) };
  if (active && (await activeCount(catalogId, offer._id as Types.ObjectId)) >= MAX_ACTIVE_OFFERS) {
    return {
      outcome: 'REJECTED',
      code: 'TOO_MANY_OFFERS',
      message: `You can have up to ${MAX_ACTIVE_OFFERS} offers switched on. Pause or delete one first.`,
    };
  }
  offer.active = active;
  await offer.save();
  await bumpDraftRevision(catalogId);
  return { outcome: 'OK', offer: toOfferDto(offer) };
}

export async function deleteOffer(
  userId: string,
  offerId: string
): Promise<{ outcome: 'NO_CATALOG' | 'NOT_FOUND' | 'DELETED' }> {
  const catalog = await findOwnedCatalog(userId);
  if (!catalog) return { outcome: 'NO_CATALOG' };
  if (!Types.ObjectId.isValid(offerId)) return { outcome: 'NOT_FOUND' };
  const catalogId = catalog._id as Types.ObjectId;
  const res = await CatalogOffer.updateOne(
    { _id: oid(offerId), catalogId, deletedAt: null },
    { $set: { deletedAt: new Date() } }
  ).exec();
  if (res.modifiedCount === 0) return { outcome: 'NOT_FOUND' };
  await bumpDraftRevision(catalogId);
  return { outcome: 'DELETED' };
}

// ── Preview + "On offer" ───────────────────────────────────────────────────

export interface OfferPreviewDto {
  /** Dishes the offer would touch (explicit, or in its sections / the whole menu). */
  affectedCount: number;
  /** Up to three, old → new; `final` null = this dish would stay full price. */
  samples: { productId: string; name: string; price: number | null; final: number | null }[];
  combo: { fullPrice: number; price: number; saves: number } | null;
}

export async function previewOffer(
  userId: string,
  input: OfferInput
): Promise<
  | { outcome: 'NO_CATALOG' }
  | { outcome: 'REJECTED'; code: OfferRejection; message: string }
  | { outcome: 'OK'; preview: OfferPreviewDto }
> {
  const catalog = await findOwnedCatalog(userId);
  if (!catalog) return { outcome: 'NO_CATALOG' };
  const products = await affectedProducts(catalog._id as Types.ObjectId, input);
  if (!products) {
    return {
      outcome: 'REJECTED',
      code: 'TARGET_NOT_FOUND',
      message: 'One of the chosen dishes or sections no longer exists.',
    };
  }
  if (input.kind === 'COMBO') {
    const full = products.reduce((sum, p) => sum + (p.price ?? 0), 0);
    const price = input.combo?.price ?? 0;
    return {
      outcome: 'OK',
      preview: {
        affectedCount: products.length,
        samples: products.map((p) => ({
          productId: String(p._id),
          name: p.name,
          price: p.price ?? null,
          final: null,
        })),
        combo: { fullPrice: full, price, saves: full - price },
      },
    };
  }
  return {
    outcome: 'OK',
    preview: {
      affectedCount: products.length,
      samples: products.slice(0, 3).map((p) => ({
        productId: String(p._id),
        name: p.name,
        price: p.price ?? null,
        final:
          typeof p.price === 'number'
            ? discountedPrice({ kind: input.kind, value: input.value }, p.price)
            : null,
      })),
      combo: null,
    },
  };
}

export interface ProductOfferDto {
  offerId: string;
  name: string;
  kind: OfferKind;
  value: number | null;
  status: OfferStatus;
  /** The dish's price under this offer; null = it would not discount this dish. */
  final: number | null;
  /** True for the one offer that wins when several are live at once. */
  wins: boolean;
}

/** The product editor's "On offer: Happy hour (−20%)" — every switched-on offer on this dish. */
export async function offersForProduct(
  userId: string,
  productId: string
): Promise<
  | { outcome: 'NO_CATALOG' }
  | { outcome: 'NOT_FOUND' }
  | { outcome: 'OK'; offers: ProductOfferDto[] }
> {
  const catalog = await findOwnedCatalog(userId);
  if (!catalog) return { outcome: 'NO_CATALOG' };
  if (!Types.ObjectId.isValid(productId)) return { outcome: 'NOT_FOUND' };
  const catalogId = catalog._id as Types.ObjectId;
  const product = await CatalogProduct.findOne({ _id: oid(productId), catalogId, deletedAt: null })
    .select({ _id: 1, price: 1, categoryId: 1 })
    .lean<ProductLite>()
    .exec();
  if (!product) return { outcome: 'NOT_FOUND' };

  const rows = await CatalogOffer.find({
    catalogId,
    deletedAt: null,
    active: true,
    kind: { $ne: 'COMBO' },
    $or: [
      { 'target.type': 'ALL' },
      { 'target.type': 'PRODUCTS', 'target.ids': product._id },
      ...(product.categoryId
        ? [{ 'target.type': 'CATEGORIES', 'target.ids': product.categoryId }]
        : []),
    ],
  }).exec();

  const now = new Date();
  const priced = rows.filter((r) => offerStatus(r, now) !== 'ENDED');
  const live = priced.filter((r) => isOfferLive(r, now)).map(toPriced);
  const winner =
    typeof product.price === 'number' ? (priceFor(product.price, live)?.offerId ?? null) : null;
  return {
    outcome: 'OK',
    offers: priced.map((r) => ({
      offerId: String(r._id),
      name: r.name,
      kind: r.kind,
      value: typeof r.value === 'number' ? r.value : null,
      status: offerStatus(r, now),
      final: typeof product.price === 'number' ? discountedPrice(r, product.price) : null,
      wins: winner === String(r._id),
    })),
  };
}
