// tests/catalog-languages.test.ts
//
// Multi-language menus (more-customization Stage 6).
//
// Pinned:
//   • `languages` replaces its block; an extra language may not repeat the
//     primary one, and more than three extras is refused;
//   • translations MERGE per language — saving Hindi never disturbs Tamil —
//     `null` or an all-blank entry removes a language, and unknown codes 400;
//   • text for a language that is switched OFF is kept, but never published:
//     the publish key only carries enabled languages, and a dish with no
//     published text has the empty key (so no menu-wide republish on deploy);
//   • badge labels ride inside the dish's `details`, but a badge with no
//     translation leaves that key exactly as it was before Stage 6;
//   • switching languages touches every category, so the planner re-pushes them.
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
import { dishDetailsKey, dishDetailsOf } from '@/services/catalog/dishDetails';
import {
  announcementTranslations,
  badgeTranslations,
  EMPTY_TRANSLATIONS_KEY,
  mirageLanguagesField,
  mirageTranslationsField,
  productTranslationsKey,
  publishedLanguages,
  translationWrites,
} from '@/services/catalog/menuTranslations';
import { diffProduct } from '@/services/catalog/publishPlanner';
import type { CatalogSnapshotProduct } from '@/services/catalog/publishSnapshot';

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

describe('menu languages', () => {
  it('defaults to English only and replaces the block', async () => {
    const { auth } = await owner();
    const before = await request(app).get('/catalog/profile').set(auth).expect(200);
    expect(before.body.profile.languages).toEqual({ primary: 'en', extra: [] });
    expect(before.body.profile.i18n).toEqual({});

    const res = await request(app)
      .patch('/catalog/profile')
      .set(auth)
      .send({ languages: { extra: ['hi', 'ta', 'hi'] } })
      .expect(200);
    expect(res.body.profile.languages).toEqual({ primary: 'en', extra: ['hi', 'ta'] });
    expect(res.body.profile.publicFields).toEqual(expect.arrayContaining(['languages', 'i18n']));
  });

  it('refuses a repeated primary, more than three extras and unknown codes', async () => {
    const { auth } = await owner();
    for (const languages of [
      { primary: 'hi', extra: ['hi'] },
      { extra: ['hi', 'ta', 'te', 'kn'] },
      { extra: ['fr'] },
    ]) {
      await request(app).patch('/catalog/profile').set(auth).send({ languages }).expect(400);
    }
  });

  it('touches every category when the languages change', async () => {
    const { auth, catalogId, userId } = await owner();
    const cat = await CatalogCategory.create({
      catalogId: new Types.ObjectId(catalogId),
      userId: new Types.ObjectId(userId),
      name: 'starters',
      lastSyncedAt: new Date(Date.now() + 60_000),
    });
    await CatalogCategory.updateOne(
      { _id: cat._id },
      { $set: { updatedAt: new Date(Date.now() - 60_000) } },
      { timestamps: false }
    );

    await request(app)
      .patch('/catalog/profile')
      .set(auth)
      .send({ languages: { extra: ['hi'] } })
      .expect(200);

    const after = await CatalogCategory.findById(cat._id).lean().exec();
    expect(after!.updatedAt.getTime()).toBeGreaterThan(Date.now() - 10_000);
  });
});

describe('translations merge per language', () => {
  it('on a product: Hindi then Tamil, null removes, blanks remove', async () => {
    const { auth, catalogId, userId } = await owner();
    const dish = await seedProduct(catalogId, userId);

    await request(app)
      .patch(`/catalog/products/${dish.id}`)
      .set(auth)
      .send({ i18n: { hi: { name: ' पनीर टिक्का ', description: 'मसालेदार' } } })
      .expect(200);
    const both = await request(app)
      .patch(`/catalog/products/${dish.id}`)
      .set(auth)
      .send({ i18n: { ta: { name: 'பனீர் டிக்கா' } } })
      .expect(200);
    expect(both.body.product.i18n).toEqual({
      hi: { name: 'पनीर टिक्का', description: 'मसालेदार' },
      ta: { name: 'பனீர் டிக்கா' },
    });

    const removed = await request(app)
      .patch(`/catalog/products/${dish.id}`)
      .set(auth)
      .send({ i18n: { hi: null, ta: { name: '   ' } } })
      .expect(200);
    expect(removed.body.product.i18n).toEqual({});
  });

  it('refuses unknown language codes and over-long text', async () => {
    const { auth, catalogId, userId } = await owner();
    const dish = await seedProduct(catalogId, userId);
    for (const i18n of [{ fr: { name: 'x' } }, { hi: { name: 'x'.repeat(121) } }, {}]) {
      await request(app).patch(`/catalog/products/${dish.id}`).set(auth).send({ i18n }).expect(400);
    }
  });

  it('on a category, and on the catalog (announcement + badge labels)', async () => {
    const { auth } = await owner();
    const created = await request(app)
      .post('/catalog/categories')
      .set(auth)
      .send({ name: 'Starters', i18n: { hi: { name: 'स्टार्टर' } } })
      .expect(201);
    expect(created.body.category.i18n).toEqual({ hi: { name: 'स्टार्टर' } });

    await request(app)
      .patch('/catalog/profile')
      .set(auth)
      .send({ i18n: { hi: { announcement: 'आज 20% छूट', badges: { b1: 'शेफ़ स्पेशल' } } } })
      .expect(200);
    const ta = await request(app)
      .patch('/catalog/profile')
      .set(auth)
      .send({ i18n: { ta: { announcement: 'இன்று 20% தள்ளுபடி' } } })
      .expect(200);
    expect(ta.body.profile.i18n).toEqual({
      hi: { announcement: 'आज 20% छूट', badges: { b1: 'शेफ़ स्पेशल' } },
      ta: { announcement: 'இன்று 20% தள்ளுபடி' },
    });
  });

  it('write helper: dotted paths, null and blank entries unset', () => {
    expect(translationWrites({ hi: { name: ' a ', description: '' }, ta: null, te: { name: ' ' } })).toEqual({
      set: { 'i18n.hi': { name: 'a' } },
      unset: { 'i18n.ta': 1, 'i18n.te': 1 },
    });
  });
});

describe('publishing', () => {
  const enabled = { languages: { primary: 'en' as const, extra: ['hi' as const] } };

  it('publishes only enabled languages; a removed language is kept but not sent', () => {
    const product = { i18n: { hi: { name: 'पनीर' }, ta: { name: 'பனீர்' } } };
    expect(publishedLanguages(enabled)).toEqual(['hi']);
    expect(JSON.parse(productTranslationsKey(product, publishedLanguages(enabled)))).toEqual({
      hi: { name: 'पनीर' },
    });
    // No extra languages → nothing published, the empty key, which Mirage gets as ''.
    const none = productTranslationsKey(product, publishedLanguages({}));
    expect(none).toBe(EMPTY_TRANSLATIONS_KEY);
    expect(mirageTranslationsField(none)).toBe('');
    expect(JSON.parse(mirageLanguagesField(enabled))).toEqual({ primary: 'en', extra: ['hi'] });
  });

  it('a snapshot from before Stage 6 reads as "no translations" — no republish', () => {
    const product = {
      name: 'paneer',
      i18n: EMPTY_TRANSLATIONS_KEY,
    } as unknown as CatalogSnapshotProduct;
    expect(diffProduct(product, { name: 'paneer' })).not.toContain('i18n');

    const translated = {
      name: 'paneer',
      i18n: productTranslationsKey({ i18n: { hi: { name: 'पनीर' } } }, ['hi']),
    } as unknown as CatalogSnapshotProduct;
    expect(diffProduct(translated, { name: 'paneer' })).toContain('i18n');
  });

  it('badge labels: translated badges carry i18n; untranslated keep the old key', () => {
    const lib = [{ id: 'b1', label: "Chef's special", icon: 'chef-hat', color: 'accent' }] as const;
    const i18n = { hi: { badges: { b1: 'शेफ़ स्पेशल' } }, ta: { badges: { b1: 'x' } } };

    const plain = dishDetailsKey(dishDetailsOf({ badgeIds: ['b1'] }, [...lib]));
    const noText = dishDetailsKey(
      dishDetailsOf({ badgeIds: ['b1'] }, [...lib], badgeTranslations({}, ['hi']))
    );
    expect(noText).toBe(plain);

    const labelled = JSON.parse(
      dishDetailsKey(dishDetailsOf({ badgeIds: ['b1'] }, [...lib], badgeTranslations(i18n, ['hi'])))
    );
    expect(labelled.badges[0].i18n).toEqual({ hi: 'शेफ़ स्पेशल' });

    expect(announcementTranslations({ hi: { announcement: ' आज ' } }, ['hi'])).toEqual({ hi: 'आज' });
    expect(announcementTranslations({ hi: { announcement: 'आज' } }, [])).toEqual({});
  });
});
