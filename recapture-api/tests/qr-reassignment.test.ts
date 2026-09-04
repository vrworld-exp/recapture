// tests/qr-reassignment.test.ts
//
// Stage 4: replacement standees, retirement, and the one repoint that is
// refused.
//
// THE PROPERTY UNDER TEST IS THAT `publicUrl` NEVER MOVES. A lost or damaged
// standee is replaced by attaching a SECOND code to the same catalog — not by
// repointing the URL — which is what makes feature 32 hold: the catalog's
// printed URL survives the swap, and the indirection absorbs it. The tests here
// are the ones that would catch a "simplification" that repointed the URL
// instead, which reads fine and breaks every sticker already in the world.
import { describe, it, expect, beforeAll, afterAll, beforeEach, afterEach, vi } from 'vitest';
import request from 'supertest';
import mongoose, { Types } from 'mongoose';
import jwt from 'jsonwebtoken';
import { MongoMemoryServer } from 'mongodb-memory-server';

import { createApp } from '@/app';
import { env } from '@/config/env';
import { User, type UserRole } from '@/models/User';
import { Catalog } from '@/models/Catalog';
import { CatalogDelegation } from '@/models/CatalogDelegation';
import { QrCode } from '@/models/QrCode';
import { QrCodeAssignment } from '@/models/QrCodeAssignment';
import { QrScanDaily } from '@/models/QrScanDaily';
import { RateWindow } from '@/models/RateWindow';

const app = createApp();
let mongod: MongoMemoryServer;

const RESOLVER_BASE = 'https://scan.test';
const MIRAGE_BASE = 'https://menu.test';

beforeAll(async () => {
  mongod = await MongoMemoryServer.create();
  await mongoose.connect(mongod.getUri());
  await QrCode.syncIndexes();
  await Catalog.syncIndexes();
  await CatalogDelegation.syncIndexes();
  await QrScanDaily.syncIndexes();
});

afterAll(async () => {
  await mongoose.disconnect();
  await mongod.stop();
});

beforeEach(() => {
  Object.assign(env, {
    PUBLIC_RESOLVER_BASE_URL: RESOLVER_BASE,
    MIRAGE_PUBLIC_BASE_URL: MIRAGE_BASE,
    WEB_APP_BASE_URL: undefined,
  });
  vi.spyOn(console, 'log').mockImplementation(() => {});
  vi.spyOn(console, 'warn').mockImplementation(() => {});
});

afterEach(async () => {
  vi.restoreAllMocks();
  await Promise.all([
    User.deleteMany({}),
    Catalog.deleteMany({}),
    CatalogDelegation.deleteMany({}),
    QrCode.deleteMany({}),
    QrCodeAssignment.deleteMany({}),
    QrScanDaily.deleteMany({}),
    RateWindow.deleteMany({}),
  ]);
});

async function makeUser(role: UserRole): Promise<{ id: string; auth: { Authorization: string } }> {
  const user = await User.create({
    authProvider: 'custom',
    authUid: `test|${new Types.ObjectId().toHexString()}`,
    role,
  });
  const id = user.id as string;
  const token = jwt.sign({ userId: id, authUid: user.authUid }, env.JWT_SECRET, {
    expiresIn: '15m',
  });
  return { id, auth: { Authorization: `Bearer ${token}` } };
}

async function mint(code: string): Promise<void> {
  await QrCode.create({
    code,
    batchId: new Types.ObjectId(),
    state: 'UNASSIGNED',
    deletedAt: null,
  });
}

async function activated(code: string, phone = '+919876543210') {
  const rep = await makeUser('SALES_REP');
  await mint(code);
  const res = await request(app)
    .post('/rep/activations')
    .set(rep.auth)
    .send({ code, restaurantName: 'Blue Cafe', restaurantPhone: phone });
  expect(res.status).toBe(201);
  return { rep, catalogId: res.body.catalogId as string, publicUrl: res.body.publicUrl as string };
}

describe('attaching a replacement standee', () => {
  it('leaves publicUrl untouched and points both codes at the same catalog', async () => {
    const { rep, catalogId, publicUrl } = await activated('ABCD2345');
    await mint('BBBB2222');

    const res = await request(app)
      .post(`/rep/catalogs/${catalogId}/qr-codes`)
      .set(rep.auth)
      .send({ code: 'BBBB2222' });

    expect(res.status).toBe(201);
    expect(res.body.outcome).toBe('ATTACHED');
    // THE ASSERTION THAT MATTERS. The catalog keeps advertising its FIRST code;
    // the replacement carries a different one; the resolver absorbs the
    // difference. Repointing the URL here would break every sticker already in
    // the world.
    expect(res.body.publicUrl).toBe(publicUrl);
    const catalog = await Catalog.findById(catalogId).exec();
    expect(catalog!.publicUrl).toBe(`${RESOLVER_BASE}/r/ABCD2345`);
    expect(catalog!.publicUrlScheme).toBe('RECAPTURE_SHORT_CODE');

    // Both codes resolve to this catalog until the old one is retired.
    for (const code of ['ABCD2345', 'BBBB2222']) {
      const qr = await QrCode.findOne({ code }).exec();
      expect(qr!.state).toBe('ACTIVE');
      expect(String(qr!.catalogId)).toBe(catalogId);
    }
  });

  it('closes the prior assignment and opens a new one', async () => {
    const { rep, catalogId } = await activated('CCCC3333');
    await mint('DDDD4444');

    await request(app)
      .post(`/rep/catalogs/${catalogId}/qr-codes`)
      .set(rep.auth)
      .send({ code: 'DDDD4444' });

    const rows = await QrCodeAssignment.find({ catalogId }).sort({ assignedAt: 1 }).lean().exec();
    expect(rows).toHaveLength(2);
    expect(rows[0].unassignedAt).toBeInstanceOf(Date);
    expect(rows[1].unassignedAt).toBeNull();

    const oldCode = await QrCode.findOne({ code: 'CCCC3333' }).exec();
    const newCode = await QrCode.findOne({ code: 'DDDD4444' }).exec();
    expect(String(oldCode!.currentAssignmentId)).toBe(String(rows[0]._id));
    expect(String(newCode!.currentAssignmentId)).toBe(String(rows[1]._id));
  });

  it('leaves the prior assignment’s scan rollups untouched', async () => {
    const { rep, catalogId } = await activated('EEEE5555');
    // The resolver only records a scan on a REDIRECT, so the catalog has to be
    // published for this test to exercise the rollup at all.
    await Catalog.updateOne(
      { _id: catalogId },
      { $set: { mirageRestaurantId: '507f1f77bcf86cd799439022' } }
    ).exec();
    // A real scan through the public resolver, before the swap.
    expect((await request(app).get('/r/EEEE5555')).status).toBe(302);
    const before = await QrScanDaily.find({}).lean().exec();
    expect(before).toHaveLength(1);
    expect(before[0].count).toBe(1);

    await mint('FFFF6666');
    await request(app)
      .post(`/rep/catalogs/${catalogId}/qr-codes`)
      .set(rep.auth)
      .send({ code: 'FFFF6666' });
    await request(app).get('/r/FFFF6666');

    const rows = await QrScanDaily.find({}).lean().exec();
    expect(rows).toHaveLength(2);
    // History splits at the swap: the old standee's count is frozen where it
    // was, and the replacement starts from zero.
    const old = rows.find((r) => String(r.assignmentId) === String(before[0].assignmentId));
    expect(old!.count).toBe(1);
    expect(rows.find((r) => String(r._id) !== String(old!._id))!.count).toBe(1);
  });

  it('is idempotent — re-attaching this catalog’s own code is a no-op', async () => {
    const { rep, catalogId } = await activated('GGGG7777');

    const res = await request(app)
      .post(`/rep/catalogs/${catalogId}/qr-codes`)
      .set(rep.auth)
      .send({ code: 'GGGG7777' });

    expect(res.status).toBe(200);
    expect(res.body.outcome).toBe('ALREADY_ATTACHED');
    expect(await QrCodeAssignment.countDocuments({ catalogId })).toBe(1);
  });

  it('refuses a code that does not exist, and one that is retired', async () => {
    const { rep, catalogId } = await activated('HHHH8888');
    await mint('JJJJ9999');
    await QrCode.updateOne({ code: 'JJJJ9999' }, { state: 'RETIRED' }).exec();

    const missing = await request(app)
      .post(`/rep/catalogs/${catalogId}/qr-codes`)
      .set(rep.auth)
      .send({ code: 'KKKK0000' });
    const retired = await request(app)
      .post(`/rep/catalogs/${catalogId}/qr-codes`)
      .set(rep.auth)
      .send({ code: 'JJJJ9999' });

    expect(missing.status).toBe(404);
    expect(retired.status).toBe(409);
    expect(retired.body.code).toBe('CODE_UNAVAILABLE');
  });
});

describe('cross-catalog repointing', () => {
  it('is refused once the source catalog has published', async () => {
    const source = await activated('MMMM2222', '+919000000001');
    const target = await activated('NNNN3333', '+919000000002');
    // The source has been live: its URL has been in the world.
    await Catalog.updateOne(
      { _id: source.catalogId },
      { $set: { status: 'PUBLISHED', publishedRevision: 0 } }
    ).exec();

    const res = await request(app)
      .post(`/rep/catalogs/${target.catalogId}/qr-codes`)
      .set(target.rep.auth)
      .send({ code: 'MMMM2222' });

    // Moving it would leave the source catalog's frozen publicUrl pointing at a
    // standee that no longer resolves to it — a dead link on printed material.
    expect(res.status).toBe(409);
    expect(res.body.code).toBe('SOURCE_CATALOG_PUBLISHED');
    const qr = await QrCode.findOne({ code: 'MMMM2222' }).exec();
    expect(String(qr!.catalogId)).toBe(source.catalogId);
  });

  it('is allowed while the source catalog is still DRAFT', async () => {
    const source = await activated('PPPP4444', '+919000000003');
    const target = await activated('QQQQ5555', '+919000000004');
    expect((await Catalog.findById(source.catalogId).exec())!.status).toBe('DRAFT');

    const res = await request(app)
      .post(`/rep/catalogs/${target.catalogId}/qr-codes`)
      .set(target.rep.auth)
      .send({ code: 'PPPP4444' });

    // Nothing has been printed or shared yet, so the move is safe.
    expect(res.status).toBe(201);
    const qr = await QrCode.findOne({ code: 'PPPP4444' }).exec();
    expect(String(qr!.catalogId)).toBe(target.catalogId);
    // The ledger never shows one code open against two catalogs.
    const open = await QrCodeAssignment.find({ qrCodeId: qr!._id, unassignedAt: null }).exec();
    expect(open).toHaveLength(1);
    expect(String(open[0].catalogId)).toBe(target.catalogId);
  });
});

describe('retiring a code', () => {
  it('makes the old standee render REPLACED while the new one still redirects', async () => {
    const { rep, catalogId } = await activated('RRRR6666');
    await mint('SSSS7777');
    await request(app)
      .post(`/rep/catalogs/${catalogId}/qr-codes`)
      .set(rep.auth)
      .send({ code: 'SSSS7777' });
    // Publish the catalog so the live code actually redirects.
    await Catalog.updateOne(
      { _id: catalogId },
      { $set: { mirageRestaurantId: '507f1f77bcf86cd799439011' } }
    ).exec();

    const retire = await request(app).post('/rep/qr-codes/RRRR6666/retire').set(rep.auth).send({});
    expect(retire.status).toBe(200);
    expect(retire.body.outcome).toBe('RETIRED');

    const old = await request(app).get('/r/RRRR6666');
    expect(old.status).toBe(200);
    expect(old.text).toContain('been replaced');

    const live = await request(app).get('/r/SSSS7777');
    expect(live.status).toBe(302);
    expect(live.headers.location).toBe(`${MIRAGE_BASE}/507f1f77bcf86cd799439011`);
  });

  it('closes the retired code’s open assignment', async () => {
    const { rep } = await activated('TTTT8888');

    await request(app).post('/rep/qr-codes/TTTT8888/retire').set(rep.auth).send({});

    const qr = await QrCode.findOne({ code: 'TTTT8888' }).exec();
    expect(qr!.state).toBe('RETIRED');
    const rows = await QrCodeAssignment.find({ qrCodeId: qr!._id }).lean().exec();
    expect(rows).toHaveLength(1);
    expect(rows[0].unassignedAt).toBeInstanceOf(Date);
  });

  it('refuses a rep who does not hold the code’s catalog', async () => {
    await activated('VVVV9999');
    const stranger = await makeUser('SALES_REP');

    const res = await request(app).post('/rep/qr-codes/VVVV9999/retire').set(stranger.auth).send({});

    expect(res.status).toBe(404);
    expect((await QrCode.findOne({ code: 'VVVV9999' }).exec())!.state).toBe('ACTIVE');
  });

  it('404s an unbound code — there is no catalog to authorise against', async () => {
    const rep = await makeUser('SALES_REP');
    await mint('WWWW0000');

    const res = await request(app).post('/rep/qr-codes/WWWW0000/retire').set(rep.auth).send({});

    expect(res.status).toBe(404);
    expect((await QrCode.findOne({ code: 'WWWW0000' }).exec())!.state).toBe('UNASSIGNED');
  });
});
