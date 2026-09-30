// tests/catalog-offers.test.ts
//
// more-customization Stage 10 — offers, combos, happy hour.
//
//   • The pricing copy passes the SAME vectors as mirage-fe's offers.ts
//     (tests/fixtures/offer-vectors.json) — owner preview and diner price agree.
//   • Save-time rules: fixed price on an unpriced dish, a "discount" that is
//     not one, the 20-active cap, and every write bumping draftRevision.
//   • The publish block: dishes by published name, a category expanded to its
//     dishes, archived dishes and ended / paused offers dropped.
import { describe, it, expect, beforeAll, afterAll, afterEach } from 'vitest';
import mongoose, { Types } from 'mongoose';
import { MongoMemoryServer } from 'mongodb-memory-server';

import { Catalog } from '@/models/Catalog';
import { CatalogCategory } from '@/models/CatalogCategory';
import { CatalogOffer } from '@/models/CatalogOffer';
import { CatalogProduct } from '@/models/CatalogProduct';
import { mirageOffersField } from '@/services/catalog/offersBlock';
import { createOffer, setOfferActive, type OfferInput } from '@/services/catalogOffersService';
import {
  isOfferLive,
  offerStatus,
  priceFor,
  type PricedOffer,
} from '@/services/offers/offerPricing';
import vectors from './fixtures/offer-vectors.json';
import { entitledView } from '@/services/catalog/entitledView';
import {
  DEFAULT_PLAN_ENTITLEMENTS,
  FULL_CUSTOMIZATION,
  entitlementsKey,
  heldBackFor,
} from '@/services/subscription/customizationEntitlements';

// ── Shared vectors ──────────────────────────────────────────────────────────

type VectorOffer = PricedOffer & { all?: boolean; items?: string[] };
const library = vectors.offers as unknown as Record<string, VectorOffer>;

describe('shared offer vectors (same file as mirage-fe)', () => {
  for (const c of vectors.cases) {
    it(c.name, () => {
      const now = new Date(c.now);
      const candidates = c.offers
        .map((key) => library[key])
        .filter((o) => isOfferLive(o, now))
        .filter(
          (o) =>
            o.all === true ||
            (o.items ?? []).some((n) => n.toLowerCase() === c.dish.name.toLowerCase())
        );
      const result = priceFor(c.dish.price, candidates);
      if (c.expect === null) expect(result).toBeNull();
      else expect(result).toMatchObject({ final: c.expect.final, offerId: c.expect.offerId });
    });
  }
});

describe('offerStatus', () => {
  const at = new Date('2026-09-28T18:00:00+05:30');
  it('reads Paused / Ended / Live now / Scheduled', () => {
    expect(offerStatus({ active: false, schedule: {} }, at)).toBe('PAUSED');
    expect(offerStatus({ active: true, schedule: { endsAt: '2026-09-01T00:00:00Z' } }, at)).toBe(
      'ENDED'
    );
    expect(offerStatus({ active: true, schedule: { from: '17:00', to: '19:00' } }, at)).toBe(
      'LIVE'
    );
    expect(offerStatus({ active: true, schedule: { from: '12:00', to: '15:00' } }, at)).toBe(
      'SCHEDULED'
    );
  });
});

// ── Service + publish block ─────────────────────────────────────────────────

let mongod: MongoMemoryServer;

beforeAll(async () => {
  mongod = await MongoMemoryServer.create();
  await mongoose.connect(mongod.getUri());
});

afterAll(async () => {
  await mongoose.disconnect();
  await mongod.stop();
});

afterEach(async () => {
  await Promise.all([
    Catalog.deleteMany({}),
    CatalogCategory.deleteMany({}),
    CatalogProduct.deleteMany({}),
    CatalogOffer.deleteMany({}),
  ]);
});

async function seed() {
  const userId = new Types.ObjectId();
  const catalog = await Catalog.create({
    userId,
    name: 'Cafe',
    status: 'PUBLISHED',
    draftRevision: 3,
    publishedRevision: 3,
  });
  const catalogId = catalog._id as Types.ObjectId;
  const drinks = await CatalogCategory.create({ catalogId, userId, name: 'Drinks', position: 0 });
  const product = (name: string, price: number | undefined, extra: Record<string, unknown> = {}) =>
    CatalogProduct.create({
      catalogId,
      userId,
      type: 'IMAGE_ONLY',
      name,
      ...(price !== undefined ? { price } : {}),
      currency: 'INR',
      position: 0,
      assets: { imageKey: `catalogs/${String(catalogId)}/images/${name}.jpg` },
      ...extra,
    });
  const coffee = await product('Cold Coffee', 250, { categoryId: drinks._id });
  const mojito = await product('Mojito', 180, { categoryId: drinks._id });
  const oldDrink = await product('Old Drink', 120, {
    categoryId: drinks._id,
    archivedAt: new Date(),
  });
  const water = await product('Water', undefined);
  const burger = await product('Burger', 199);
  return { userId: String(userId), catalogId, drinks, coffee, mojito, oldDrink, water, burger };
}

const draftOf = async (catalogId: Types.ObjectId) =>
  (await Catalog.findById(catalogId).lean())!.draftRevision;

describe('save-time rules', () => {
  it('rejects a fixed price on a dish with no price', async () => {
    const s = await seed();
    const input: OfferInput = {
      name: 'Deal',
      kind: 'FIXED_PRICE',
      value: 10,
      target: { type: 'PRODUCTS', ids: [String(s.water._id)] },
    };
    expect(await createOffer(s.userId, input)).toMatchObject({
      outcome: 'REJECTED',
      code: 'PRODUCT_HAS_NO_PRICE',
    });
  });

  it('rejects a "discount" that is not below the base price', async () => {
    const s = await seed();
    expect(
      await createOffer(s.userId, {
        name: 'Deal',
        kind: 'FIXED_PRICE',
        value: 300,
        target: { type: 'PRODUCTS', ids: [String(s.coffee._id)] },
      })
    ).toMatchObject({ outcome: 'REJECTED', code: 'OFFER_PRICE_INVALID' });
  });

  it('rejects a combo priced at or above its dishes', async () => {
    const s = await seed();
    expect(
      await createOffer(s.userId, {
        name: 'Combo',
        kind: 'COMBO',
        combo: { productIds: [String(s.burger._id), String(s.mojito._id)], price: 379 },
      })
    ).toMatchObject({ outcome: 'REJECTED', code: 'COMBO_PRICE_INVALID' });
  });

  it('caps switched-on offers at 20, and every write bumps draftRevision', async () => {
    const s = await seed();
    const before = await draftOf(s.catalogId);
    const input: OfferInput = {
      name: 'Flat',
      kind: 'FLAT',
      value: 5,
      target: { type: 'ALL', ids: [] },
    };
    for (let i = 0; i < 20; i++) {
      expect(await createOffer(s.userId, input)).toMatchObject({ outcome: 'OK' });
    }
    expect(await draftOf(s.catalogId)).toBe(before + 20);
    expect(await createOffer(s.userId, input)).toMatchObject({
      outcome: 'REJECTED',
      code: 'TOO_MANY_OFFERS',
    });
    // A paused one does not count.
    expect(await createOffer(s.userId, { ...input, active: false })).toMatchObject({
      outcome: 'OK',
    });
  });
});

describe('publish block (restaurant.offers)', () => {
  it('is empty with no offers — a catalog without offers is unchanged', async () => {
    const s = await seed();
    expect(await mirageOffersField({ _id: s.catalogId })).toBe('');
  });

  it('expands a category to its live dishes by published name and labels it', async () => {
    const s = await seed();
    await createOffer(s.userId, {
      name: 'Happy hour',
      kind: 'PERCENT',
      value: 20,
      target: { type: 'CATEGORIES', ids: [String(s.drinks._id)] },
      schedule: { from: '17:00', to: '19:00' },
    });
    const [offer] = JSON.parse(await mirageOffersField({ _id: s.catalogId }));
    expect(offer).toMatchObject({
      name: 'Happy hour',
      kind: 'PERCENT',
      value: 20,
      targetLabel: 'Drinks',
      schedule: { from: '17:00', to: '19:00' },
    });
    // The archived dish is not on the menu, so it is not in the offer.
    expect(offer.items).toHaveLength(2);
    expect(offer.items).toEqual(['cold_coffee', 'mojito']);
  });

  it('drops paused and ended offers, and a combo missing a dish', async () => {
    const s = await seed();
    const paused = await createOffer(s.userId, {
      name: 'P',
      kind: 'FLAT',
      value: 5,
      target: { type: 'ALL', ids: [] },
    });
    await setOfferActive(s.userId, (paused as { offer: { id: string } }).offer.id, false);
    await createOffer(s.userId, {
      name: 'Old',
      kind: 'FLAT',
      value: 5,
      target: { type: 'ALL', ids: [] },
      schedule: { startsAt: '2026-01-01T00:00:00Z', endsAt: '2026-02-01T00:00:00Z' },
    });
    await createOffer(s.userId, {
      name: 'Combo',
      kind: 'COMBO',
      combo: { productIds: [String(s.burger._id), String(s.mojito._id)], price: 299 },
    });
    await CatalogProduct.updateOne({ _id: s.mojito._id }, { $set: { archivedAt: new Date() } });

    expect(await mirageOffersField({ _id: s.catalogId }, new Date('2026-09-28T12:00:00Z'))).toBe(
      ''
    );
  });
});

// ── Plan gating (decided 2026-09-30: offers and My plate are Signature and above) ──

describe('plan gating for offers and My plate', () => {
  it('Taste sends the plate as off; Signature keeps the owner choice', () => {
    const catalog = {
      appearance: undefined,
      badges: [],
      languages: undefined,
      arBranding: undefined,
      spotlight: undefined,
      engagement: undefined,
      slug: undefined,
      plate: { enabled: true, showTotal: false },
    };
    expect(entitledView(catalog, DEFAULT_PLAN_ENTITLEMENTS.TASTE).plate).toEqual({
      enabled: false,
      showTotal: false,
    });
    expect(entitledView(catalog, DEFAULT_PLAN_ENTITLEMENTS.SIGNATURE).plate).toEqual(catalog.plate);
  });

  it('lists offers and an owner-enabled plate as held back on Taste only', () => {
    const catalog = { plate: { enabled: true, showTotal: true } } as never;
    const extras = { hasCategorySchedules: false, hasPairings: false, hasOffers: true };
    expect(
      heldBackFor(catalog, DEFAULT_PLAN_ENTITLEMENTS.TASTE, extras).map((h) => h.feature)
    ).toEqual(['offers', 'plate']);
    expect(heldBackFor(catalog, DEFAULT_PLAN_ENTITLEMENTS.SIGNATURE, extras)).toEqual([]);
  });

  it('keeps the fully covered entitlements key unchanged (no fleet-wide re-push)', () => {
    expect(entitlementsKey(FULL_CUSTOMIZATION)).toBe(
      JSON.stringify([true, true, true, 12, 3, true, 'all', true, true])
    );
    expect(entitlementsKey(DEFAULT_PLAN_ENTITLEMENTS.TASTE)).not.toBe(
      JSON.stringify([false, false, false, 3, 0, false, 'review', false, false])
    );
  });
});
