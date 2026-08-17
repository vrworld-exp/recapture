// tests/catalog-crud.test.ts
//
// The /catalog authoring surface: catalog root, categories and products.
//
// The load-bearing properties under test are the ones that are expensive to get
// wrong later:
//   • OWNERSHIP comes only from the token, and a foreign row is an ordinary 404
//     (the enumeration-safe rule) — never a 403 that confirms it exists.
//   • Every authoring write bumps draftRevision, which IS the "you have
//     unpublished changes" signal. A write that forgets to bump makes a change
//     permanently invisible to the publish screen.
//   • Route order: /products/reorder and /products/bulk must not be swallowed
//     by /products/:id.
//
// Hermetic: in-memory MongoDB, no network. Indexes are synced explicitly
// because the category name-uniqueness rule IS a partial unique index, and
// mongodb-memory-server starts with an empty collection and no indexes.
import { describe, it, expect, beforeAll, afterAll, afterEach } from 'vitest';
import request from 'supertest';
import mongoose, { Types } from 'mongoose';
import jwt from 'jsonwebtoken';
import { MongoMemoryServer } from 'mongodb-memory-server';

import { createApp } from '@/app';
import { env } from '@/config/env';
import { User } from '@/models/User';
import { Project } from '@/models/Project';
import { ProjectModel } from '@/models/ProjectModel';
import { Catalog } from '@/models/Catalog';
import { CatalogCategory } from '@/models/CatalogCategory';
import { CatalogProduct } from '@/models/CatalogProduct';

const app = createApp();
let mongod: MongoMemoryServer;

beforeAll(async () => {
  mongod = await MongoMemoryServer.create();
  await mongoose.connect(mongod.getUri());
  await Catalog.syncIndexes();
  await CatalogCategory.syncIndexes();
  await CatalogProduct.syncIndexes();
});

afterAll(async () => {
  await mongoose.disconnect();
  await mongod.stop();
});

afterEach(async () => {
  await Promise.all([
    User.deleteMany({}),
    Project.deleteMany({}),
    ProjectModel.deleteMany({}),
    Catalog.deleteMany({}),
    CatalogCategory.deleteMany({}),
    CatalogProduct.deleteMany({}),
  ]);
});

type Auth = { Authorization: string };

async function makeUser(): Promise<{ id: string; auth: Auth }> {
  const user = await User.create({
    authProvider: 'custom',
    authUid: `test|${new Types.ObjectId().toHexString()}`,
  });
  const id = user.id as string;
  const token = jwt.sign({ userId: id, authUid: user.authUid }, env.JWT_SECRET, {
    expiresIn: '15m',
  });
  return { id, auth: { Authorization: `Bearer ${token}` } };
}

/** A SUCCEEDED model the given user owns — the only thing a THREE_D product
 *  can be built from. */
async function makeSucceededModel(userId: string): Promise<string> {
  const project = await Project.create({
    userId: new Types.ObjectId(userId),
    name: 'Chair capture',
    objectSize: 'MEDIUM',
    mode: 'GUIDED',
  });
  const model = await ProjectModel.create({
    projectId: project._id,
    jobId: new Types.ObjectId(),
    source: 'meshy',
    status: 'SUCCEEDED',
    selectedKeys: ['a.jpg', 'b.jpg', 'c.jpg'],
    // Required audit fields — a generation is always attributable to the staff
    // user who requested it.
    createdByUserId: new Types.ObjectId(),
    createdByRole: 'ADMIN',
    artifacts: {
      glbKey: 'dev/x/y/models/m/model.glb',
      cdnUrls: { glb: 'https://cdn.example.com/model.glb', usdz: 'https://cdn.example.com/m.usdz' },
    },
  });
  return model.id as string;
}

async function createCatalogFor(auth: Auth, name = 'My Shop'): Promise<string> {
  const res = await request(app).post('/catalog').set(auth).send({ name });
  return res.body.catalog.id as string;
}

// ── Catalog root ────────────────────────────────────────────────────────────

describe('catalog root', () => {
  it('requires a token', async () => {
    await request(app).get('/catalog').expect(401);
  });

  it('404s before a catalog exists, then returns it after create', async () => {
    const { auth } = await makeUser();

    const before = await request(app).get('/catalog').set(auth).expect(404);
    expect(before.body.code).toBe('CATALOG_NOT_FOUND');

    const created = await request(app)
      .post('/catalog')
      .set(auth)
      .send({ name: 'Cafe Mocha' })
      .expect(201);

    expect(created.body.catalog.name).toBe('Cafe Mocha');
    expect(created.body.catalog.status).toBe('DRAFT');
    expect(created.body.catalog.publicUrl).toBeNull();
    expect(created.body.catalog.isProvisioned).toBe(false);

    await request(app).get('/catalog').set(auth).expect(200);
  });

  it('a brand-new catalog already reads as having unpublished changes', async () => {
    // publishedRevision starts at -1 against draftRevision 0, so the badge is on
    // from the moment the catalog exists — no special-casing needed.
    const { auth } = await makeUser();
    const res = await request(app).post('/catalog').set(auth).send({ name: 'S' }).expect(201);
    expect(res.body.catalog.hasUnpublishedChanges).toBe(true);
  });

  it('a second create replays the first instead of erroring', async () => {
    const { auth } = await makeUser();
    const first = await request(app).post('/catalog').set(auth).send({ name: 'A' }).expect(201);
    const second = await request(app).post('/catalog').set(auth).send({ name: 'B' }).expect(200);

    // Same catalog, and the replay did NOT overwrite the name.
    expect(second.body.catalog.id).toBe(first.body.catalog.id);
    expect(second.body.catalog.name).toBe('A');
  });

  it('never exposes internal mapping fields', async () => {
    const { auth } = await makeUser();
    const res = await request(app).post('/catalog').set(auth).send({ name: 'A' }).expect(201);

    // The DTO is built field by field; a spread would leak these the next time
    // the schema grows.
    for (const leaked of ['mirageRestaurantId', 'activePublishRunId', 'deletedAt', '_id', '__v']) {
      expect(res.body.catalog).not.toHaveProperty(leaked);
    }
  });

  it('one user cannot see another user\'s catalog', async () => {
    const a = await makeUser();
    const b = await makeUser();
    await createCatalogFor(a.auth);

    await request(app).get('/catalog').set(b.auth).expect(404);
  });

  it('rejects an empty patch and unknown fields', async () => {
    const { auth } = await makeUser();
    await createCatalogFor(auth);

    await request(app).patch('/catalog').set(auth).send({}).expect(400);
    // `.strict()` — a userId in the body must be REJECTED, not ignored.
    await request(app)
      .patch('/catalog')
      .set(auth)
      .send({ name: 'X', userId: new Types.ObjectId().toHexString() })
      .expect(400);
  });

  it('a metadata patch bumps draftRevision', async () => {
    const { auth } = await makeUser();
    const id = await createCatalogFor(auth);

    const before = await Catalog.findById(id).exec();
    await request(app).patch('/catalog').set(auth).send({ businessName: 'Ltd' }).expect(200);
    const after = await Catalog.findById(id).exec();

    expect(after!.draftRevision).toBe(before!.draftRevision + 1);
  });
});

// ── Categories ──────────────────────────────────────────────────────────────

describe('catalog categories', () => {
  it('creates, lists in position order, and rejects a duplicate name', async () => {
    const { auth } = await makeUser();
    await createCatalogFor(auth);

    await request(app).post('/catalog/categories').set(auth).send({ name: 'Drinks' }).expect(201);
    await request(app).post('/catalog/categories').set(auth).send({ name: 'Food' }).expect(201);

    // Mirage rejects a duplicate (name, restaurant) outright, so it is caught
    // here rather than deferred to publish time.
    const dup = await request(app)
      .post('/catalog/categories')
      .set(auth)
      .send({ name: 'Drinks' })
      .expect(409);
    expect(dup.body.code).toBe('DUPLICATE_NAME');

    const list = await request(app).get('/catalog/categories').set(auth).expect(200);
    expect(list.body.categories.map((c: { name: string }) => c.name)).toEqual(['Drinks', 'Food']);
    expect(list.body.categories[0].position).toBe(0);
    expect(list.body.categories[1].position).toBe(1);
  });

  it('reorder is not swallowed by the :id route', async () => {
    // Route-order regression guard: declared after /categories/:id, the literal
    // "reorder" would be parsed as an id and 400 on the ObjectId regex.
    const { auth } = await makeUser();
    await createCatalogFor(auth);

    const a = await request(app).post('/catalog/categories').set(auth).send({ name: 'A' });
    const b = await request(app).post('/catalog/categories').set(auth).send({ name: 'B' });

    const res = await request(app)
      .post('/catalog/categories/reorder')
      .set(auth)
      .send({ ids: [b.body.category.id, a.body.category.id] })
      .expect(200);

    expect(res.body.categories.map((c: { name: string }) => c.name)).toEqual(['B', 'A']);
  });

  it('reorder rejects a partial id set', async () => {
    const { auth } = await makeUser();
    await createCatalogFor(auth);
    const a = await request(app).post('/catalog/categories').set(auth).send({ name: 'A' });
    await request(app).post('/catalog/categories').set(auth).send({ name: 'B' });

    // A partial list would silently leave B at a stale position.
    const res = await request(app)
      .post('/catalog/categories/reorder')
      .set(auth)
      .send({ ids: [a.body.category.id] })
      .expect(400);
    expect(res.body.code).toBe('ID_SET_MISMATCH');
  });

  it('deleting a category moves its products to Uncategorized, never deletes them', async () => {
    const { auth } = await makeUser();
    await createCatalogFor(auth);

    const cat = await request(app).post('/catalog/categories').set(auth).send({ name: 'Drinks' });
    const categoryId = cat.body.category.id as string;

    await request(app)
      .post('/catalog/products')
      .set(auth)
      .send({ type: 'IMAGE_ONLY', name: 'Latte', categoryId })
      .expect(201);

    const del = await request(app)
      .delete(`/catalog/categories/${categoryId}`)
      .set(auth)
      .expect(200);
    expect(del.body.movedProductCount).toBe(1);

    const list = await request(app).get('/catalog/products').set(auth).expect(200);
    expect(list.body.items).toHaveLength(1);
    expect(list.body.items[0].categoryId).toBeNull();

    const cats = await request(app).get('/catalog/categories').set(auth).expect(200);
    expect(cats.body.categories).toHaveLength(0);
    expect(cats.body.uncategorizedCount).toBe(1);
  });

  it('a foreign category id is a 404, not a 403', async () => {
    const a = await makeUser();
    const b = await makeUser();
    await createCatalogFor(a.auth);
    await createCatalogFor(b.auth);

    const cat = await request(app).post('/catalog/categories').set(a.auth).send({ name: 'X' });

    const res = await request(app)
      .patch(`/catalog/categories/${cat.body.category.id}`)
      .set(b.auth)
      .send({ name: 'Y' })
      .expect(404);
    expect(res.body.code).toBe('NOT_FOUND');
  });
});

// ── Products ────────────────────────────────────────────────────────────────

describe('catalog products', () => {
  it('creates an image-only product', async () => {
    const { auth } = await makeUser();
    await createCatalogFor(auth);

    const res = await request(app)
      .post('/catalog/products')
      .set(auth)
      .send({ type: 'IMAGE_ONLY', name: 'Latte', price: 250, tags: ['Hot', 'hot', 'NEW'] })
      .expect(201);

    expect(res.body.product.type).toBe('IMAGE_ONLY');
    expect(res.body.product.price).toBe(250);
    // Tags normalise to lowercase and de-duplicate in the schema.
    expect(res.body.product.tags).toEqual(['hot', 'new']);
    expect(res.body.product.glbUrl).toBeNull();
    expect(res.body.product.syncStatus).toBe('NEVER');
  });

  it('a 3D product copies the model artifact URLs onto itself', async () => {
    const { id, auth } = await makeUser();
    await createCatalogFor(auth);
    const modelId = await makeSucceededModel(id);

    const res = await request(app)
      .post('/catalog/products')
      .set(auth)
      .send({ type: 'THREE_D', name: 'Chair', sourceModelId: modelId })
      .expect(201);

    // Copied, not resolved on read: a later regeneration must not silently
    // change what an already-published product points at.
    expect(res.body.product.glbUrl).toBe('https://cdn.example.com/model.glb');
    expect(res.body.product.usdzUrl).toBe('https://cdn.example.com/m.usdz');
  });

  it('rejects a 3D product with no sourceModelId', async () => {
    const { auth } = await makeUser();
    await createCatalogFor(auth);

    await request(app)
      .post('/catalog/products')
      .set(auth)
      .send({ type: 'THREE_D', name: 'Chair' })
      .expect(400);
  });

  it('refuses a model that is not finished', async () => {
    const { id, auth } = await makeUser();
    await createCatalogFor(auth);

    const project = await Project.create({
      userId: new Types.ObjectId(id),
      name: 'p',
      objectSize: 'SMALL',
      mode: 'GUIDED',
    });
    const pending = await ProjectModel.create({
      projectId: project._id,
      jobId: new Types.ObjectId(),
      source: 'meshy',
      status: 'PROCESSING',
      selectedKeys: [],
      createdByUserId: new Types.ObjectId(),
      createdByRole: 'ADMIN',
    });

    const res = await request(app)
      .post('/catalog/products')
      .set(auth)
      .send({ type: 'THREE_D', name: 'Chair', sourceModelId: pending.id })
      .expect(409);
    expect(res.body.code).toBe('MODEL_NOT_READY');
  });

  it("another user's model reads as not found, not forbidden", async () => {
    const a = await makeUser();
    const b = await makeUser();
    await createCatalogFor(b.auth);
    const modelId = await makeSucceededModel(a.id); // owned by A

    const res = await request(app)
      .post('/catalog/products')
      .set(b.auth)
      .send({ type: 'THREE_D', name: 'Chair', sourceModelId: modelId })
      .expect(404);
    // Never confirm someone else's model exists.
    expect(res.body.code).toBe('MODEL_NOT_FOUND');
  });

  it('rejects a duplicate product name (mirrors Mirage\'s constraint)', async () => {
    const { auth } = await makeUser();
    await createCatalogFor(auth);

    await request(app)
      .post('/catalog/products')
      .set(auth)
      .send({ type: 'IMAGE_ONLY', name: 'Latte' })
      .expect(201);

    const res = await request(app)
      .post('/catalog/products')
      .set(auth)
      .send({ type: 'IMAGE_ONLY', name: 'Latte' })
      .expect(409);
    expect(res.body.code).toBe('DUPLICATE_NAME');
  });

  it('patch distinguishes "not sent" from an explicit null', async () => {
    const { auth } = await makeUser();
    await createCatalogFor(auth);
    const created = await request(app)
      .post('/catalog/products')
      .set(auth)
      .send({ type: 'IMAGE_ONLY', name: 'Latte', price: 250 });
    const productId = created.body.product.id as string;

    // Not sent → untouched.
    const renamed = await request(app)
      .patch(`/catalog/products/${productId}`)
      .set(auth)
      .send({ name: 'Flat White' })
      .expect(200);
    expect(renamed.body.product.price).toBe(250);

    // Explicit null → cleared. Collapsing the two is how "remove the price"
    // silently becomes a no-op.
    const cleared = await request(app)
      .patch(`/catalog/products/${productId}`)
      .set(auth)
      .send({ price: null })
      .expect(200);
    expect(cleared.body.product.price).toBeNull();
  });

  it('filters by category, type and search text', async () => {
    const { auth } = await makeUser();
    await createCatalogFor(auth);
    const cat = await request(app).post('/catalog/categories').set(auth).send({ name: 'Drinks' });
    const categoryId = cat.body.category.id as string;

    await request(app)
      .post('/catalog/products')
      .set(auth)
      .send({ type: 'IMAGE_ONLY', name: 'Latte', categoryId });
    await request(app)
      .post('/catalog/products')
      .set(auth)
      .send({ type: 'IMAGE_ONLY', name: 'Muffin' });

    const inCat = await request(app)
      .get('/catalog/products')
      .query({ categoryId })
      .set(auth)
      .expect(200);
    expect(inCat.body.items.map((p: { name: string }) => p.name)).toEqual(['Latte']);

    const uncategorized = await request(app)
      .get('/catalog/products')
      .query({ categoryId: 'none' })
      .set(auth)
      .expect(200);
    expect(uncategorized.body.items.map((p: { name: string }) => p.name)).toEqual(['Muffin']);

    const search = await request(app)
      .get('/catalog/products')
      .query({ q: 'lat' })
      .set(auth)
      .expect(200);
    expect(search.body.items).toHaveLength(1);
  });

  it('search treats regex metacharacters literally', async () => {
    const { auth } = await makeUser();
    await createCatalogFor(auth);
    await request(app)
      .post('/catalog/products')
      .set(auth)
      .send({ type: 'IMAGE_ONLY', name: 'Latte' });

    // Unescaped, `.*` would match everything.
    const res = await request(app)
      .get('/catalog/products')
      .query({ q: '.*' })
      .set(auth)
      .expect(200);
    expect(res.body.items).toHaveLength(0);
  });

  it('paginates deterministically by position', async () => {
    const { auth } = await makeUser();
    await createCatalogFor(auth);
    for (const name of ['A', 'B', 'C']) {
      await request(app)
        .post('/catalog/products')
        .set(auth)
        .send({ type: 'IMAGE_ONLY', name });
    }

    const first = await request(app)
      .get('/catalog/products')
      .query({ limit: 2 })
      .set(auth)
      .expect(200);
    expect(first.body.items.map((p: { name: string }) => p.name)).toEqual(['A', 'B']);
    expect(first.body.nextCursor).toBeTruthy();

    const second = await request(app)
      .get('/catalog/products')
      .query({ limit: 2, cursor: first.body.nextCursor })
      .set(auth)
      .expect(200);
    expect(second.body.items.map((p: { name: string }) => p.name)).toEqual(['C']);
    expect(second.body.nextCursor).toBeNull();
  });

  it('rejects a tampered or cross-list cursor with 400', async () => {
    const { auth } = await makeUser();
    await createCatalogFor(auth);

    await request(app)
      .get('/catalog/products')
      .query({ cursor: 'not-a-cursor' })
      .set(auth)
      .expect(400);
  });

  it('archives and restores, and archived rows are hidden by default', async () => {
    const { auth } = await makeUser();
    await createCatalogFor(auth);
    const created = await request(app)
      .post('/catalog/products')
      .set(auth)
      .send({ type: 'IMAGE_ONLY', name: 'Latte' });
    const productId = created.body.product.id as string;

    await request(app).post(`/catalog/products/${productId}/archive`).set(auth).expect(200);

    const hidden = await request(app).get('/catalog/products').set(auth).expect(200);
    expect(hidden.body.items).toHaveLength(0);

    const shown = await request(app)
      .get('/catalog/products')
      .query({ includeArchived: 'true' })
      .set(auth)
      .expect(200);
    expect(shown.body.items).toHaveLength(1);
    expect(shown.body.items[0].isArchived).toBe(true);

    await request(app).post(`/catalog/products/${productId}/restore`).set(auth).expect(200);
    const back = await request(app).get('/catalog/products').set(auth).expect(200);
    expect(back.body.items).toHaveLength(1);
  });

  it('delete is idempotent and keeps the row for the publish worker', async () => {
    const { auth } = await makeUser();
    await createCatalogFor(auth);
    const created = await request(app)
      .post('/catalog/products')
      .set(auth)
      .send({ type: 'IMAGE_ONLY', name: 'Latte' });
    const productId = created.body.product.id as string;

    await request(app).delete(`/catalog/products/${productId}`).set(auth).expect(200);
    // A repeat is a success, not a confusing 404.
    await request(app).delete(`/catalog/products/${productId}`).set(auth).expect(200);

    // Soft-deleted, not removed: mirageItemId lives on this row and the worker
    // still needs to know which Mirage item to delete.
    const row = await CatalogProduct.findById(productId).exec();
    expect(row).not.toBeNull();
    expect(row!.deletedAt).toBeTruthy();
  });

  it('bulk actions apply, and are rejected wholesale on an unknown id', async () => {
    const { auth } = await makeUser();
    await createCatalogFor(auth);
    const ids: string[] = [];
    for (const name of ['A', 'B']) {
      const r = await request(app)
        .post('/catalog/products')
        .set(auth)
        .send({ type: 'IMAGE_ONLY', name });
      ids.push(r.body.product.id);
    }

    // /products/bulk must not be captured by /products/:id either.
    const ok = await request(app)
      .post('/catalog/products/bulk')
      .set(auth)
      .send({ action: 'ARCHIVE', ids })
      .expect(200);
    expect(ok.body.affected).toBe(2);

    const bad = await request(app)
      .post('/catalog/products/bulk')
      .set(auth)
      .send({ action: 'ARCHIVE', ids: [...ids, new Types.ObjectId().toHexString()] })
      .expect(400);
    expect(bad.body.code).toBe('ID_SET_MISMATCH');
  });

  it('every product write bumps draftRevision', async () => {
    // This counter is the entire "unpublished changes" signal — a write that
    // forgets to bump makes the change invisible to the publish screen.
    const { auth } = await makeUser();
    const catalogId = await createCatalogFor(auth);

    const revision = async (): Promise<number> =>
      (await Catalog.findById(catalogId).exec())!.draftRevision;

    const start = await revision();

    const created = await request(app)
      .post('/catalog/products')
      .set(auth)
      .send({ type: 'IMAGE_ONLY', name: 'Latte' });
    expect(await revision()).toBe(start + 1);

    const productId = created.body.product.id as string;

    await request(app).patch(`/catalog/products/${productId}`).set(auth).send({ name: 'L2' });
    expect(await revision()).toBe(start + 2);

    await request(app).post(`/catalog/products/${productId}/archive`).set(auth);
    expect(await revision()).toBe(start + 3);

    await request(app).delete(`/catalog/products/${productId}`).set(auth);
    expect(await revision()).toBe(start + 4);
  });

  it('never exposes projection bookkeeping on a product', async () => {
    const { auth } = await makeUser();
    await createCatalogFor(auth);
    const res = await request(app)
      .post('/catalog/products')
      .set(auth)
      .send({ type: 'IMAGE_ONLY', name: 'Latte' })
      .expect(201);

    for (const leaked of [
      'mirageItemId',
      'mirageCategoryIdAtSync',
      'publishedSnapshot',
      'userId',
      'catalogId',
      '_id',
      '__v',
    ]) {
      expect(res.body.product).not.toHaveProperty(leaked);
    }
  });
});
