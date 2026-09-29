// tests/catalog-badges-dietary.test.ts
//
// Badges and dietary / allergen detail (more-customization Stage 5).
//
// Pinned:
//   • the badge library REPLACES, new badges get ids, and a badge removed from
//     the library comes off every product in the same request;
//   • a product may only carry its own catalog's badges;
//   • a vegan or Jain dish cannot be non-veg — judged on the END state, so a
//     patch that only adds VEGAN to a non-veg dish is refused too;
//   • the publish key denormalises badges, so renaming one changes the key of
//     every dish that carries it, while an untouched dish keeps an equal key.
//
// Hermetic: in-memory MongoDB, no network.
import { describe, it, expect, beforeAll, afterAll, afterEach } from 'vitest';
import request from 'supertest';
import mongoose, { Types } from 'mongoose';
import jwt from 'jsonwebtoken';
import { MongoMemoryServer } from 'mongodb-memory-server';

import { createApp } from '@/app';
import { env } from '@/config/env';
import { User } from '@/models/User';
import { Catalog } from '@/models/Catalog';
import { CatalogCategory } from '@/models/CatalogCategory';
import { CatalogProduct } from '@/models/CatalogProduct';
import {
  dishDetailsKey,
  dishDetailsOf,
  EMPTY_DISH_DETAILS_KEY,
  mirageDishFields,
} from '@/services/catalog/dishDetails';

const app = createApp();
let mongod: MongoMemoryServer;

beforeAll(async () => {
  mongod = await MongoMemoryServer.create();
  await mongoose.connect(mongod.getUri());
  await Promise.all([Catalog.syncIndexes(), CatalogCategory.syncIndexes(), CatalogProduct.syncIndexes()]);
});

afterAll(async () => {
  await mongoose.disconnect();
  await mongod.stop();
});

afterEach(async () => {
  await Promise.all([
    User.deleteMany({}),
    Catalog.deleteMany({}),
    CatalogCategory.deleteMany({}),
    CatalogProduct.deleteMany({}),
  ]);
});

type Auth = { Authorization: string };

async function owner(): Promise<{ auth: Auth; catalogId: string; userId: string }> {
  const user = await User.create({
    authProvider: 'custom',
    authUid: `test|${new Types.ObjectId().toHexString()}`,
  });
  const token = jwt.sign({ userId: user.id, authUid: user.authUid }, env.JWT_SECRET, {
    expiresIn: '15m',
  });
  const auth = { Authorization: `Bearer ${token}` };
  const res = await request(app).post('/catalog').set(auth).send({ name: 'Blue Cafe' });
  return { auth, catalogId: res.body.catalog.id as string, userId: user.id as string };
}

/** An image-only product written straight to the store — the asset flow is not what is under test. */
async function seedProduct(catalogId: string, userId: string, over: Record<string, unknown> = {}) {
  return CatalogProduct.create({
    catalogId: new Types.ObjectId(catalogId),
    userId: new Types.ObjectId(userId),
    type: 'IMAGE_ONLY',
    name: `dish_${new Types.ObjectId().toHexString().slice(-6)}`,
    categoryId: null,
    assets: { imageKey: 'catalogs/x/products/y/img.jpg' },
    ...over,
  });
}

const CHEF = { label: "Chef's special", icon: 'chef-hat', color: 'accent' } as const;
const NEW = { label: 'New', icon: 'sparkles', color: 'green' } as const;

describe('badge library', () => {
  it('assigns ids to new badges and returns the library on the profile', async () => {
    const { auth } = await owner();
    const res = await request(app)
      .patch('/catalog/profile')
      .set(auth)
      .send({ badges: [CHEF, NEW] })
      .expect(200);

    const badges = res.body.profile.badges as { id: string; label: string }[];
    expect(badges.map((b) => b.label)).toEqual(["Chef's special", 'New']);
    expect(badges.every((b) => typeof b.id === 'string' && b.id.length > 0)).toBe(true);
    expect(res.body.profile.publicFields).toContain('badges');
  });

  it('refuses unknown icons and colours, long labels and more than twelve', async () => {
    const { auth } = await owner();
    for (const badges of [
      [{ ...CHEF, icon: 'rocket' }],
      [{ ...CHEF, color: 'pink' }],
      [{ ...CHEF, label: 'x'.repeat(19) }],
      Array.from({ length: 13 }, () => NEW),
    ]) {
      await request(app).patch('/catalog/profile').set(auth).send({ badges }).expect(400);
    }
  });

  it('pulls a deleted badge from every product in the same request', async () => {
    const { auth, catalogId, userId } = await owner();
    const lib = (
      await request(app).patch('/catalog/profile').set(auth).send({ badges: [CHEF, NEW] })
    ).body.profile.badges as { id: string }[];
    const [chefId, newId] = [lib[0]!.id, lib[1]!.id];
    const dish = await seedProduct(catalogId, userId, { badgeIds: [chefId, newId] });

    await request(app)
      .patch('/catalog/profile')
      .set(auth)
      .send({ badges: [{ id: newId, ...NEW }] })
      .expect(200);

    const after = await CatalogProduct.findById(dish._id).lean().exec();
    expect(after!.badgeIds).toEqual([newId]);
  });
});

describe('product detail', () => {
  it('saves badges and diet detail on a product, refusing a stranger badge', async () => {
    const { auth, catalogId, userId } = await owner();
    const lib = (
      await request(app).patch('/catalog/profile').set(auth).send({ badges: [CHEF] })
    ).body.profile.badges as { id: string }[];
    const dish = await seedProduct(catalogId, userId);

    const ok = await request(app)
      .patch(`/catalog/products/${dish.id}`)
      .set(auth)
      .send({
        badgeIds: [lib[0]!.id],
        dietary: ['JAIN', 'JAIN'],
        allergens: ['DAIRY'],
        spiceLevel: 2,
        servesCount: 2,
      })
      .expect(200);
    expect(ok.body.product).toMatchObject({
      badgeIds: [lib[0]!.id],
      dietary: ['JAIN'],
      allergens: ['DAIRY'],
      spiceLevel: 2,
      servesCount: 2,
      calories: null,
    });

    const stranger = await request(app)
      .patch(`/catalog/products/${dish.id}`)
      .set(auth)
      .send({ badgeIds: ['not-mine'] })
      .expect(400);
    expect(stranger.body.code).toBe('UNKNOWN_BADGE');

    const cleared = await request(app)
      .patch(`/catalog/products/${dish.id}`)
      .set(auth)
      .send({ spiceLevel: null })
      .expect(200);
    expect(cleared.body.product.spiceLevel).toBeNull();
  });

  it('refuses a vegan or Jain dish that is non-veg — on the end state', async () => {
    const { auth, catalogId, userId } = await owner();
    const dish = await seedProduct(catalogId, userId, { foodType: 'NON_VEG' });

    const res = await request(app)
      .patch(`/catalog/products/${dish.id}`)
      .set(auth)
      .send({ dietary: ['VEGAN'] })
      .expect(400);
    expect(res.body.code).toBe('DIET_CONFLICT');

    // Fixing both together is fine.
    await request(app)
      .patch(`/catalog/products/${dish.id}`)
      .set(auth)
      .send({ foodType: 'VEG', dietary: ['VEGAN'] })
      .expect(200);
  });

  it('refuses out-of-range facts and unknown codes', async () => {
    const { auth, catalogId, userId } = await owner();
    const dish = await seedProduct(catalogId, userId);
    for (const body of [
      { spiceLevel: 4 },
      { servesCount: 0 },
      { dietary: ['PALEO'] },
      { allergens: ['GLITTER'] },
    ]) {
      await request(app).patch(`/catalog/products/${dish.id}`).set(auth).send(body).expect(400);
    }
  });
});

describe('publish key', () => {
  const lib = [{ id: 'b1', label: "Chef's special", icon: 'chef-hat', color: 'accent' }] as const;

  it('denormalises badges, so a rename changes the key; nothing set = the empty key', () => {
    const before = dishDetailsKey(dishDetailsOf({ badgeIds: ['b1'] }, [...lib]));
    const renamed = dishDetailsKey(
      dishDetailsOf({ badgeIds: ['b1'] }, [{ ...lib[0], label: 'House special' }])
    );
    expect(renamed).not.toBe(before);
    expect(dishDetailsKey(dishDetailsOf({}, [...lib]))).toBe(EMPTY_DISH_DETAILS_KEY);
    // A badge id no longer in the library simply drops out.
    expect(dishDetailsKey(dishDetailsOf({ badgeIds: ['gone'] }, [...lib]))).toBe(
      EMPTY_DISH_DETAILS_KEY
    );
  });

  it('sends every Mirage field, empty strings to clear', () => {
    expect(mirageDishFields(EMPTY_DISH_DETAILS_KEY)).toEqual({
      badges: '',
      dietary: '',
      allergens: '',
      spiceLevel: '',
      calories: '',
      servesCount: '',
      prepMinutes: '',
    });
    const fields = mirageDishFields(
      dishDetailsKey(dishDetailsOf({ badgeIds: ['b1'], spiceLevel: 3 }, [...lib]))
    );
    expect(JSON.parse(fields.badges)).toEqual([
      { label: "Chef's special", icon: 'chef-hat', color: 'accent' },
    ]);
    expect(fields.spiceLevel).toBe('3');
  });
});
