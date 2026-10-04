// tests/multi-branch.test.ts
//
// more-customization Stage 16 — multi-branch restaurants.
//
//   16a  one main catalog per owner + uniquely-named branches; the index
//        migration (dry run, apply, idempotent, duplicate report); delete guard.
//   16b  add branch clones the menu with links and its own image keys; main
//        outlet edits copy down except a branch override; archive copies down as
//        archive; brand-wide look copied, per-outlet hours kept; reset-to-main.
//   16c  X-Outlet-Id scopes every owner route; a foreign outlet is a 404; brand-
//        wide fields refused on a branch; rep activates a branch
//        standee with its own delegation; the weekly report's brand line.
import { describe, it, expect, beforeAll, afterAll, afterEach, beforeEach, vi } from 'vitest';
import request from 'supertest';
import mongoose, { Types } from 'mongoose';
import jwt from 'jsonwebtoken';
import { MongoMemoryServer } from 'mongodb-memory-server';

vi.mock('@/services/s3ObjectStore', async (importOriginal) => {
  const actual = await importOriginal<typeof import('@/services/s3ObjectStore')>();
  return { ...actual, copyObject: vi.fn(async () => undefined) };
});

import { createApp } from '@/app';
import { env } from '@/config/env';
import { User, type UserRole } from '@/models/User';
import { Catalog } from '@/models/Catalog';
import { CatalogCategory } from '@/models/CatalogCategory';
import { CatalogProduct } from '@/models/CatalogProduct';
import { CatalogDelegation } from '@/models/CatalogDelegation';
import { QrCode } from '@/models/QrCode';
import { QrCodeAssignment } from '@/models/QrCodeAssignment';
import { RateWindow } from '@/models/RateWindow';
import { WeeklyReport } from '@/models/WeeklyReport';
import { copyObject } from '@/services/s3ObjectStore';
import { bumpDraftRevision, findOwnedCatalog } from '@/services/catalogService';
import { addBranch, listOutlets, resetProductToMain } from '@/services/brand/branchService';
import { migrateCatalogIndex } from '@/services/brand/catalogIndexMigration';
import { withOutlet } from '@/services/catalog/outletScope';
import { getWeeklyReport } from '@/services/weeklyReportService';
import { buildProductImageKey } from '@/utils/productImageKeys';

const app = createApp();
let mongod: MongoMemoryServer;

beforeAll(async () => {
  mongod = await MongoMemoryServer.create();
  await mongoose.connect(mongod.getUri());
  await Promise.all([
    Catalog.syncIndexes(),
    CatalogCategory.syncIndexes(),
    CatalogProduct.syncIndexes(),
    QrCode.syncIndexes(),
    CatalogDelegation.syncIndexes(),
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
    CatalogCategory.deleteMany({}),
    CatalogProduct.deleteMany({}),
    CatalogDelegation.deleteMany({}),
    QrCode.deleteMany({}),
    QrCodeAssignment.deleteMany({}),
    RateWindow.deleteMany({}),
    WeeklyReport.deleteMany({}),
  ]);
});

async function makeUser(
  role: UserRole = 'USER',
  phone?: string
): Promise<{ id: string; auth: { Authorization: string } }> {
  const user = await User.create({
    authProvider: 'custom',
    authUid: `test|${new Types.ObjectId().toHexString()}`,
    role,
    ...(phone ? { phone } : {}),
  });
  const id = user.id as string;
  const token = jwt.sign({ userId: id, authUid: user.authUid }, env.JWT_SECRET, { expiresIn: '15m' });
  return { id, auth: { Authorization: `Bearer ${token}` } };
}

/** A main catalog with one section and two dishes (one with a photo). */
async function seedMain(ownerId: string) {
  const main = await Catalog.create({
    userId: new Types.ObjectId(ownerId),
    name: 'Blue Cafe',
    hours: { timezone: 'Asia/Kolkata', weekly: [], closedDates: [], showOpenBadge: true },
    appearance: { presetId: 'basalt' },
  });
  const cat = await CatalogCategory.create({ catalogId: main._id, userId: main.userId, name: 'Mains' });
  const withPhoto = new Types.ObjectId();
  const imageKey = buildProductImageKey(
    String(main._id),
    withPhoto.toHexString(),
    new Types.ObjectId().toHexString(),
    'jpg'
  );
  const paneer = await CatalogProduct.create({
    _id: withPhoto,
    catalogId: main._id,
    userId: main.userId,
    type: 'IMAGE_ONLY',
    name: 'Paneer Tikka',
    price: 250,
    categoryId: cat._id,
    assets: { imageKey },
  });
  const dal = await CatalogProduct.create({
    catalogId: main._id,
    userId: main.userId,
    type: 'IMAGE_ONLY',
    name: 'Dal Makhani',
    price: 200,
    categoryId: cat._id,
  });
  return { main, cat, paneer, dal, imageKey };
}

async function branchRow(branchId: unknown, masterProductId: unknown) {
  return CatalogProduct.findOne({ catalogId: branchId, masterProductId }).lean().exec();
}

// ── 16a ─────────────────────────────────────────────────────────────────────

describe('16a — indexes and migration', () => {
  it('allows one main catalog plus uniquely named branches per owner', async () => {
    const owner = new Types.ObjectId();
    const main = await Catalog.create({ userId: owner, name: 'A' });
    await expect(Catalog.create({ userId: owner, name: 'B' })).rejects.toMatchObject({ code: 11000 });
    await Catalog.create({
      userId: owner,
      name: 'A · KP',
      brandRole: 'BRANCH',
      masterCatalogId: main._id,
      outletName: 'KP',
      branchKey: 'kp',
    });
    await Catalog.create({
      userId: owner,
      name: 'A · Baner',
      brandRole: 'BRANCH',
      masterCatalogId: main._id,
      outletName: 'Baner',
      branchKey: 'baner',
    });
    await expect(
      Catalog.create({
        userId: owner,
        name: 'A · kp again',
        brandRole: 'BRANCH',
        masterCatalogId: main._id,
        outletName: 'KP',
        branchKey: 'kp',
      })
    ).rejects.toMatchObject({ code: 11000 });
  });

  it('migrates userId_1 → userId_1_branchKey_1, idempotently, and reports duplicates', async () => {
    const db = mongoose.connection.db!;
    const coll = db.collection('legacycatalogs_test');
    await coll.deleteMany({});
    // The real collection name is fixed, so rehearse on the real one: drop the
    // new index, add the legacy one, then migrate.
    const catalogs = db.collection('catalogs');
    await catalogs.dropIndex('userId_1_branchKey_1');
    await catalogs.createIndex({ userId: 1 }, { unique: true, name: 'userId_1' });
    await catalogs.insertOne({ userId: new Types.ObjectId(), name: 'x' });

    const dry = await migrateCatalogIndex({ apply: false });
    expect(dry.duplicateOwners).toEqual([]);
    expect(dry.created).toBe(false);
    expect(dry.indexes).toContain('userId_1');

    const applied = await migrateCatalogIndex({ apply: true });
    expect(applied).toMatchObject({ created: true, dropped: true });
    expect(applied.indexes).toContain('userId_1_branchKey_1');
    expect(applied.indexes).not.toContain('userId_1');

    const again = await migrateCatalogIndex({ apply: true });
    expect(again).toMatchObject({ created: false, dropped: false });
    expect(again.indexes.sort()).toEqual(applied.indexes.sort());

    // Duplicates (possible only without the unique index) are reported, not applied.
    await catalogs.dropIndex('userId_1_branchKey_1');
    const dup = new Types.ObjectId();
    await catalogs.insertMany([
      { userId: dup, name: 'one' },
      { userId: dup, name: 'two' },
    ]);
    const refused = await migrateCatalogIndex({ apply: true });
    expect(refused.duplicateOwners).toEqual([dup.toHexString()]);
    expect(refused.created).toBe(false);
    await catalogs.deleteMany({ userId: dup });
    await Catalog.syncIndexes();
  });

  it('refuses to delete a main outlet that still has branches', async () => {
    const owner = await makeUser();
    await seedMain(owner.id);
    await addBranch(owner.id, { outletName: 'Koregaon Park' });
    const res = await request(app).delete('/catalog').set(owner.auth);
    expect(res.status).toBe(409);
    expect(res.body.code).toBe('HAS_BRANCHES');
  });
});

// ── 16b ─────────────────────────────────────────────────────────────────────

describe('16b — add branch and copy-down', () => {
  it('clones the menu with links, its own image key and the brand-wide look', async () => {
    const owner = await makeUser();
    const { main, cat, paneer, imageKey } = await seedMain(owner.id);

    const added = await addBranch(owner.id, { outletName: 'Koregaon Park', phone: '+919000000001' });
    expect(added.outcome).toBe('CREATED');
    const branchId = new Types.ObjectId((added as { outlet: { id: string } }).outlet.id);

    const [mainNow, branch] = await Promise.all([Catalog.findById(main._id), Catalog.findById(branchId)]);
    expect(mainNow!.brandRole).toBe('MASTER');
    expect(branch).toMatchObject({ brandRole: 'BRANCH', outletName: 'Koregaon Park', branchKey: 'koregaon park' });
    expect(branch!.name).toBe('Blue Cafe · Koregaon Park');
    expect(branch!.contact?.phone).toBe('+919000000001');
    expect(branch!.appearance?.presetId).toBe('basalt');

    const bCat = await CatalogCategory.findOne({ catalogId: branchId, masterCategoryId: cat._id }).lean();
    expect(bCat?.name).toBe('Mains');
    const bPaneer = await branchRow(branchId, paneer._id);
    expect(bPaneer).toMatchObject({ name: 'Paneer Tikka', price: 250, syncStatus: 'NEVER' });
    expect(String(bPaneer!.categoryId)).toBe(String(bCat!._id));
    // Its own S3 object, copied server-side — never the master's key.
    expect(bPaneer!.assets?.imageKey).toContain(`/catalog/${String(branchId)}/products/`);
    expect(bPaneer!.assets?.imageKey).not.toBe(imageKey);
    expect(vi.mocked(copyObject)).toHaveBeenCalledWith(
      expect.any(String),
      imageKey,
      bPaneer!.assets!.imageKey
    );

    const outlets = await listOutlets(owner.id);
    expect(outlets!.map((o) => o.role)).toEqual(['MAIN', 'BRANCH']);
  });

  it('copies a main price change to every branch except one that set its own', async () => {
    const owner = await makeUser();
    const { main, paneer } = await seedMain(owner.id);
    const a = await addBranch(owner.id, { outletName: 'Baner' });
    const b = await addBranch(owner.id, { outletName: 'Wakad' });
    const aId = (a as { outlet: { id: string } }).outlet.id;
    const bId = (b as { outlet: { id: string } }).outlet.id;

    // Wakad sets its own price (a direct branch edit).
    await CatalogProduct.updateOne({ catalogId: bId, masterProductId: paneer._id }, { $set: { price: 280 } });

    await CatalogProduct.updateOne({ _id: paneer._id }, { $set: { price: 260, description: 'Smoky' } });
    const before = (await Catalog.findById(aId))!.draftRevision;
    await bumpDraftRevision(main._id as Types.ObjectId);

    expect(await branchRow(aId, paneer._id)).toMatchObject({ price: 260, description: 'Smoky' });
    // Override kept; the untouched field still follows.
    expect(await branchRow(bId, paneer._id)).toMatchObject({ price: 280, description: 'Smoky' });
    expect((await Catalog.findById(aId))!.draftRevision).toBeGreaterThan(before);

    // The editor learns which field Wakad owns.
    const res = await request(app)
      .get(`/catalog/products/${String((await branchRow(bId, paneer._id))!._id)}`)
      .set({ ...(await tokenFor(owner.id)), 'X-Outlet-Id': bId });
    expect(res.status).toBe(200);
    expect(res.body.product.branch).toEqual({ followsMain: true, overriddenFields: ['price'] });

    // Reset to main outlet: back to 260, and follows again.
    expect(await resetProductToMain(owner.id, bId, String((await branchRow(bId, paneer._id))!._id))).toBe('OK');
    expect(await branchRow(bId, paneer._id)).toMatchObject({ price: 260 });
    await CatalogProduct.updateOne({ _id: paneer._id }, { $set: { price: 270 } });
    await bumpDraftRevision(main._id as Types.ObjectId);
    expect(await branchRow(bId, paneer._id)).toMatchObject({ price: 270 });
  });

  it('archives on branches what the main outlet archives; stock and hours stay per outlet', async () => {
    const owner = await makeUser();
    const { main, dal, paneer } = await seedMain(owner.id);
    const a = await addBranch(owner.id, { outletName: 'Baner' });
    const aId = (a as { outlet: { id: string } }).outlet.id;
    await Catalog.updateOne(
      { _id: aId },
      { $set: { hours: { timezone: 'Asia/Kolkata', weekly: [], closedDates: ['2026-10-02'], showOpenBadge: false } } }
    );

    await CatalogProduct.updateOne({ catalogId: aId, masterProductId: paneer._id }, { $set: { availability: 'OUT_OF_STOCK' } });
    await CatalogProduct.updateOne({ _id: dal._id }, { $set: { archivedAt: new Date() } });
    await Catalog.updateOne({ _id: main._id }, { $set: { appearance: { presetId: 'espresso' } } });
    await bumpDraftRevision(main._id as Types.ObjectId);

    const bDal = await branchRow(aId, dal._id);
    expect(bDal!.archivedAt).toBeTruthy();
    expect(await CatalogProduct.countDocuments({ catalogId: aId, deletedAt: { $ne: null } })).toBe(0);
    expect((await branchRow(aId, paneer._id))!.availability).toBe('OUT_OF_STOCK');
    const branch = await Catalog.findById(aId).lean();
    expect(branch!.appearance?.presetId).toBe('espresso');
    expect(branch!.hours?.closedDates).toEqual(['2026-10-02']);

    // A new dish on the main outlet appears on the branch.
    await CatalogProduct.create({
      catalogId: main._id,
      userId: main.userId,
      type: 'IMAGE_ONLY',
      name: 'Lassi',
      price: 90,
    });
    await bumpDraftRevision(main._id as Types.ObjectId);
    expect(await CatalogProduct.countDocuments({ catalogId: aId, name: 'Lassi' })).toBe(1);
  });
});

// ── 16c ─────────────────────────────────────────────────────────────────────

async function tokenFor(userId: string): Promise<{ Authorization: string }> {
  const user = await User.findById(userId).lean();
  const token = jwt.sign({ userId, authUid: user!.authUid }, env.JWT_SECRET, { expiresIn: '15m' });
  return { Authorization: `Bearer ${token}` };
}

describe('16c — outlet scope', () => {
  it('no header = main; header = that branch; foreign or malformed = 404', async () => {
    const owner = await makeUser();
    const other = await makeUser();
    const { main } = await seedMain(owner.id);
    const a = await addBranch(owner.id, { outletName: 'Baner' });
    const aId = (a as { outlet: { id: string } }).outlet.id;
    const theirs = await seedMain(other.id);

    const plain = await request(app).get('/catalog').set(owner.auth);
    expect(plain.body.catalog.id).toBe(String(main._id));
    expect(plain.body.catalog.outlet).toEqual({ role: 'MAIN', outletName: null, mainCatalogId: null });

    const scoped = await request(app).get('/catalog').set({ ...owner.auth, 'X-Outlet-Id': aId });
    expect(scoped.body.catalog.id).toBe(aId);
    expect(scoped.body.catalog.outlet).toMatchObject({ role: 'BRANCH', outletName: 'Baner' });
    const products = await request(app).get('/catalog/products').set({ ...owner.auth, 'X-Outlet-Id': aId });
    expect(products.status).toBe(200);
    expect(JSON.stringify(products.body)).toContain('Paneer Tikka');

    for (const bad of [String(theirs.main._id), 'not-an-id', new Types.ObjectId().toHexString()]) {
      const res = await request(app).get('/catalog').set({ ...owner.auth, 'X-Outlet-Id': bad });
      expect(res.status).toBe(404);
      expect(res.body.code).toBe('OUTLET_NOT_FOUND');
    }

    // Services outside a request (worker jobs) scope with withOutlet.
    const inJob = await withOutlet(aId, () => findOwnedCatalog(owner.id));
    expect(String(inJob!._id)).toBe(aId);
    expect(await withOutlet(String(theirs.main._id), () => findOwnedCatalog(owner.id))).toBeNull();
    expect(String((await findOwnedCatalog(owner.id))!._id)).toBe(String(main._id));
  });

  it('adds branches over HTTP and refuses brand-wide edits on a branch', async () => {
    const owner = await makeUser();
    await seedMain(owner.id);
    const created = await request(app)
      .post('/catalog/outlets')
      .set(owner.auth)
      .send({ outletName: 'Hinjewadi', address: 'Phase 1' });
    expect(created.status).toBe(201);
    const id = created.body.outlet.id as string;
    const dup = await request(app).post('/catalog/outlets').set(owner.auth).send({ outletName: 'hinjewadi' });
    expect(dup.body.code).toBe('DUPLICATE_OUTLET');

    const list = await request(app).get('/catalog/outlets').set(owner.auth);
    expect(list.body.outlets).toHaveLength(2);

    const look = await request(app)
      .patch('/catalog/profile')
      .set({ ...owner.auth, 'X-Outlet-Id': id })
      .send({ appearance: { presetId: 'espresso' } });
    expect(look.status).toBe(409);
    expect(look.body.code).toBe('BRAND_WIDE_FIELD');

    // Per-outlet fields are fine on a branch.
    const phone = await request(app)
      .patch('/catalog/profile')
      .set({ ...owner.auth, 'X-Outlet-Id': id })
      .send({ contact: { phone: '+919000000009' } });
    expect(phone.status).toBe(200);
    expect((await Catalog.findById(id))!.contact?.phone).toBe('+919000000009');
  });

  it('a rep activates a standee as a new branch with its own delegation', async () => {
    Object.assign(env, { PUBLIC_RESOLVER_BASE_URL: 'https://scan.test' });
    const rep = await makeUser('SALES_REP');
    const owner = await makeUser('USER', '+919876543210');
    const { main } = await seedMain(owner.id);
    for (const code of ['ABCD2345', 'BCDE3456']) {
      await QrCode.create({ code, batchId: new Types.ObjectId(), state: 'UNASSIGNED', deletedAt: null });
    }
    const first = await request(app)
      .post('/rep/activations')
      .set(rep.auth)
      .send({ code: 'ABCD2345', restaurantName: 'Blue Cafe', restaurantPhone: '+919876543210' });
    expect([200, 201]).toContain(first.status);

    const res = await request(app).post('/rep/activations').set(rep.auth).send({
      code: 'BCDE3456',
      restaurantName: 'Blue Cafe',
      restaurantPhone: '+919876543210',
      branchName: 'Viman Nagar',
    });
    expect(res.status).toBe(201);
    const branch = await Catalog.findOne({ userId: main.userId, branchKey: 'viman nagar' }).lean();
    expect(branch).toBeTruthy();
    const qr = await QrCode.findOne({ code: 'BCDE3456' }).lean();
    expect(String(qr!.catalogId)).toBe(String(branch!._id));
    expect(String((await QrCode.findOne({ code: 'ABCD2345' }).lean())!.catalogId)).toBe(String(main._id));
    expect(
      await CatalogDelegation.countDocuments({ catalogId: branch!._id, repUserId: new Types.ObjectId(rep.id) })
    ).toBe(1);
    // The branch got the menu.
    expect(await CatalogProduct.countDocuments({ catalogId: branch!._id })).toBe(2);
  });

  it("adds an 'All outlets' line to the main outlet's weekly report", async () => {
    const owner = await makeUser();
    const { main } = await seedMain(owner.id);
    const a = await addBranch(owner.id, { outletName: 'Baner' });
    const aId = new Types.ObjectId((a as { outlet: { id: string } }).outlet.id);
    const metrics = (menuViews: number) => ({
      menuViews,
      uniqueVisitors: 0,
      qrScans: 0,
      arViews: 0,
      productViews: 0,
      deltaPct: { menuViews: null, uniqueVisitors: null, arViews: null },
      topDishes: [],
      busiestSlot: null,
      daily: [],
      hourly: [],
    });
    await WeeklyReport.create([
      { catalogId: main._id, weekStart: '2026-09-21', metrics: metrics(100), tips: [] },
      { catalogId: aId, weekStart: '2026-09-21', metrics: metrics(50), tips: [] },
      { catalogId: main._id, weekStart: '2026-09-14', metrics: metrics(100), tips: [] },
      { catalogId: aId, weekStart: '2026-09-14', metrics: metrics(20), tips: [] },
    ]);
    const res = await getWeeklyReport(owner.id, '2026-09-21');
    expect(res.outcome).toBe('OK');
    expect((res as { report: { allOutlets?: unknown } }).report.allOutlets).toEqual({
      outlets: 2,
      menuViews: 150,
      deltaPct: 25,
    });
    const branchOnly = await withOutlet(aId, () => getWeeklyReport(owner.id, '2026-09-21'));
    expect((branchOnly as { report: { allOutlets?: unknown } }).report.allOutlets).toBeUndefined();
  });
});
