// tests/admin-all-catalogs.test.ts
//
// The ADMIN's "All catalogs" screen (Oct 2026): a grid of every live catalog,
// each one openable and editable through the /rep surface.
//
// What this suite pins, in order of how much a mistake would cost:
//   • ONLY an ADMIN gets the override. A rep or model artist with no grant
//     still gets the identical 404 a nonexistent catalog gives.
//   • The override GRANTS NOTHING: no delegation row, nothing on the admin's
//     "My restaurants", and no raw account number (that bound rests on "a rep
//     typed this number", which is not true of an admin browsing).
//   • An admin publish does not open a pending-payment window — fixing a typo
//     must not start a pay-or-go-dark clock on someone else's live page.
//   • The list: PUBLISHED only, never deleted, name order, stable keyset
//     paging, slug-agnostic search, ADMIN-only.
import { describe, it, expect, beforeAll, afterAll, beforeEach, afterEach, vi } from 'vitest';
import request from 'supertest';
import mongoose, { Types } from 'mongoose';
import { MongoMemoryServer } from 'mongodb-memory-server';

import { createApp } from '@/app';
import { Catalog } from '@/models/Catalog';
import { CatalogDelegation } from '@/models/CatalogDelegation';
import { CatalogSubscription } from '@/models/CatalogSubscription';
import { RateWindow } from '@/models/RateWindow';
import { User } from '@/models/User';
import { requestPublish } from '@/services/catalogPublishService';
import { makeUser } from './helpers/subscriptionPayments';

const app = createApp();
let mongod: MongoMemoryServer;

beforeAll(async () => {
  mongod = await MongoMemoryServer.create();
  await mongoose.connect(mongod.getUri());
  await Promise.all([
    Catalog.syncIndexes(),
    CatalogDelegation.syncIndexes(),
    CatalogSubscription.syncIndexes(),
  ]);
});

afterAll(async () => {
  await mongoose.disconnect();
  await mongod.stop();
});

beforeEach(() => {
  vi.spyOn(console, 'log').mockImplementation(() => {});
  vi.spyOn(console, 'warn').mockImplementation(() => {});
  vi.spyOn(console, 'error').mockImplementation(() => {});
});

afterEach(async () => {
  vi.restoreAllMocks();
  await Promise.all([
    User.deleteMany({}),
    Catalog.deleteMany({}),
    CatalogDelegation.deleteMany({}),
    CatalogSubscription.deleteMany({}),
    RateWindow.deleteMany({}),
  ]);
});

/** A restaurant owner (with a sign-in number) and one catalog of theirs. */
async function restaurant(
  name: string,
  extra: Record<string, unknown> = {}
): Promise<{ ownerId: Types.ObjectId; catalogId: string }> {
  const owner = await User.create({
    authProvider: 'custom',
    authUid: `test|${new Types.ObjectId().toHexString()}`,
    phone: `+9198${Math.floor(10000000 + Math.random() * 89999999)}`,
  });
  const catalog = await Catalog.create({
    userId: owner._id,
    name,
    status: 'PUBLISHED',
    ...extra,
  });
  return { ownerId: owner._id as Types.ObjectId, catalogId: String(catalog._id) };
}

// ── The override ────────────────────────────────────────────────────────────

describe('the /rep gate — the ADMIN override', () => {
  it('lets an ADMIN with no grant read and edit any live catalog', async () => {
    const admin = await makeUser('ADMIN');
    const { catalogId } = await restaurant('blue_cafe');

    const read = await request(app).get(`/rep/catalogs/${catalogId}/profile`).set(admin.auth);
    expect(read.status).toBe(200);
    expect(read.body.profile.id).toBe(catalogId);

    const write = await request(app)
      .patch(`/rep/catalogs/${catalogId}/profile`)
      .set(admin.auth)
      .send({ businessName: 'Blue Cafe Pvt Ltd' });
    expect(write.status).toBe(200);
    const stored = await Catalog.findById(catalogId).lean().exec();
    expect(stored?.businessName).toBe('Blue Cafe Pvt Ltd');
  });

  it('still answers a rep or model artist with no grant like a catalog that does not exist', async () => {
    const { catalogId } = await restaurant('blue_cafe');
    const ghostId = new Types.ObjectId().toHexString();

    for (const role of ['SALES_REP', 'MODEL_ARTIST'] as const) {
      const actor = await makeUser(role);
      const real = await request(app).get(`/rep/catalogs/${catalogId}/profile`).set(actor.auth);
      const ghost = await request(app).get(`/rep/catalogs/${ghostId}/profile`).set(actor.auth);
      expect(real.status).toBe(404);
      expect(real.body).toEqual(ghost.body);
    }
  });

  it('gives an ADMIN the same 404 for a deleted catalog, a ghost and a malformed id', async () => {
    const admin = await makeUser('ADMIN');
    const { catalogId } = await restaurant('gone_cafe', { deletedAt: new Date() });

    const deleted = await request(app).get(`/rep/catalogs/${catalogId}/profile`).set(admin.auth);
    const ghost = await request(app)
      .get(`/rep/catalogs/${new Types.ObjectId().toHexString()}/profile`)
      .set(admin.auth);
    const malformed = await request(app).get('/rep/catalogs/not-an-id/profile').set(admin.auth);

    expect(deleted.status).toBe(404);
    expect(deleted.body).toEqual(ghost.body);
    expect(malformed.body).toEqual(ghost.body);
  });

  it('loses the override the moment the role is taken away', async () => {
    const admin = await makeUser('ADMIN');
    const { catalogId } = await restaurant('blue_cafe');
    await User.updateOne({ _id: admin.id }, { $set: { role: 'SALES_REP' } });

    const res = await request(app).get(`/rep/catalogs/${catalogId}/profile`).set(admin.auth);
    expect(res.status).toBe(404);
  });

  it('grants nothing: no delegation row, nothing on "My restaurants"', async () => {
    const admin = await makeUser('ADMIN');
    const { catalogId } = await restaurant('blue_cafe');

    await request(app).get(`/rep/catalogs/${catalogId}/profile`).set(admin.auth);
    await request(app)
      .patch(`/rep/catalogs/${catalogId}/profile`)
      .set(admin.auth)
      .send({ businessName: 'X' });

    expect(await CatalogDelegation.countDocuments({})).toBe(0);
    const mine = await request(app).get('/rep/catalogs').set(admin.auth);
    expect(mine.status).toBe(200);
    expect(mine.body.catalogs).toEqual([]);
  });

  it('withholds the raw account number on every profile-returning route', async () => {
    const admin = await makeUser('ADMIN');
    const { catalogId } = await restaurant('blue_cafe');

    const read = await request(app).get(`/rep/catalogs/${catalogId}/profile`).set(admin.auth);
    const write = await request(app)
      .patch(`/rep/catalogs/${catalogId}/profile`)
      .set(admin.auth)
      .send({ businessName: 'Blue' });

    for (const res of [read, write]) {
      expect(res.body.profile.accountPhone).toBeNull();
      expect(JSON.stringify(res.body)).not.toMatch(/\+9198\d{8}/);
    }
  });

  it('an ADMIN who DOES hold a grant still sees the number they typed', async () => {
    const admin = await makeUser('ADMIN');
    const { catalogId } = await restaurant('blue_cafe');
    await CatalogDelegation.create({
      repUserId: admin.id,
      catalogId: new Types.ObjectId(catalogId),
      grantedAt: new Date(),
      revokedAt: null,
    });

    const res = await request(app).get(`/rep/catalogs/${catalogId}/profile`).set(admin.auth);
    expect(res.body.profile.accountPhone).toMatch(/^\+9198\d{8}$/);
  });
});

describe('an admin publish', () => {
  it('does not open a pending-payment window', async () => {
    const admin = await makeUser('ADMIN');
    const { ownerId, catalogId } = await restaurant('blue_cafe');

    // No products, so the gates refuse it — but the window, if it were going
    // to open, opens BEFORE the gates. Its absence is the assertion.
    const result = await requestPublish(String(ownerId), {
      publishedBy: { userId: admin.id, role: 'ADMIN' },
      openPendingPaymentWindow: false,
    });
    expect(result.outcome).toBe('BLOCKED');
    expect(await CatalogSubscription.findOne({ catalogId }).lean().exec()).toBeNull();
  });

  it('a rep publish of the same restaurant still does (the control)', async () => {
    const rep = await makeUser('SALES_REP');
    const { ownerId, catalogId } = await restaurant('blue_cafe');

    await requestPublish(String(ownerId), {
      publishedBy: { userId: rep.id, role: 'SALES_REP' },
    });
    const row = await CatalogSubscription.findOne({ catalogId }).lean().exec();
    expect(row?.status).toBe('PENDING_PAYMENT');
  });
});

// ── The list ────────────────────────────────────────────────────────────────

describe('GET /admin/catalogs', () => {
  it('lists live AND offline catalogs (never drafts or deleted), in name order, with status', async () => {
    const admin = await makeUser('ADMIN');
    await restaurant('zebra_grill');
    const { catalogId: blue } = await restaurant('blue_cafe', {
      businessName: 'Blue Hospitality',
      logoKey: 'dev/catalogs/x/logo.jpg',
      draftRevision: 3,
      publishedRevision: 2,
    });
    await restaurant('draft_only', { status: 'DRAFT' });
    await restaurant('taken_down', { status: 'UNPUBLISHED' });
    await restaurant('deleted_one', { deletedAt: new Date() });

    const res = await request(app).get('/admin/catalogs').set(admin.auth);
    expect(res.status).toBe(200);
    expect(res.body.items.map((i: { name: string }) => i.name)).toEqual([
      'blue_cafe',
      'taken_down',
      'zebra_grill',
    ]);
    expect(res.body.items.map((i: { status: string }) => i.status)).toEqual([
      'PUBLISHED',
      'UNPUBLISHED',
      'PUBLISHED',
    ]);
    expect(res.body.nextCursor).toBeNull();

    const card = res.body.items[0];
    expect(card).toMatchObject({
      id: blue,
      businessName: 'Blue Hospitality',
      isBranch: false,
      hasDraftChanges: true,
      isPublishing: false,
    });
    expect(card.logoUrl).toMatch(/\/dev\/catalogs\/x\/logo\.jpg$/);
    // No contact of any kind rides on a card.
    expect(JSON.stringify(res.body)).not.toMatch(/phone|email|\+91/i);
  });

  it('pages with a stable keyset, even across an edit', async () => {
    const admin = await makeUser('ADMIN');
    for (const n of ['a_cafe', 'b_cafe', 'c_cafe', 'd_cafe', 'e_cafe']) await restaurant(n);

    const first = await request(app).get('/admin/catalogs?limit=2').set(admin.auth);
    expect(first.body.items.map((i: { name: string }) => i.name)).toEqual(['a_cafe', 'b_cafe']);

    // An edit between pages must not shift anything (name order, not updatedAt).
    await Catalog.updateOne({ name: 'e_cafe' }, { $inc: { draftRevision: 1 } });

    const second = await request(app)
      .get(`/admin/catalogs?limit=2&cursor=${first.body.nextCursor}`)
      .set(admin.auth);
    const third = await request(app)
      .get(`/admin/catalogs?limit=2&cursor=${second.body.nextCursor}`)
      .set(admin.auth);
    expect(second.body.items.map((i: { name: string }) => i.name)).toEqual(['c_cafe', 'd_cafe']);
    expect(third.body.items.map((i: { name: string }) => i.name)).toEqual(['e_cafe']);
    expect(third.body.nextCursor).toBeNull();
  });

  it('searches names whatever separator was typed, and business names', async () => {
    const admin = await makeUser('ADMIN');
    await restaurant('blue_cafe');
    await restaurant('red_fort', { businessName: 'Royal Foods' });
    await restaurant('green_leaf');

    const spaced = await request(app).get('/admin/catalogs?q=blue%20cafe').set(admin.auth);
    expect(spaced.body.items.map((i: { name: string }) => i.name)).toEqual(['blue_cafe']);

    const business = await request(app).get('/admin/catalogs?q=royal').set(admin.auth);
    expect(business.body.items.map((i: { name: string }) => i.name)).toEqual(['red_fort']);

    // Regex metacharacters are text, and an all-separator query matches nothing.
    const meta = await request(app).get('/admin/catalogs?q=.*').set(admin.auth);
    expect(meta.status).toBe(200);
    expect(meta.body.items).toEqual([]);
  });

  it('marks a branch outlet', async () => {
    const admin = await makeUser('ADMIN');
    await restaurant('main_cafe');
    const { ownerId } = await restaurant('other_cafe');
    await Catalog.create({
      userId: ownerId,
      name: 'other_cafe_mg_road',
      status: 'PUBLISHED',
      branchKey: 'mg road',
    });

    const res = await request(app).get('/admin/catalogs').set(admin.auth);
    const branch = res.body.items.find((i: { name: string }) => i.name === 'other_cafe_mg_road');
    expect(branch.isBranch).toBe(true);
  });

  it('is ADMIN-only', async () => {
    for (const role of ['USER', 'SALES_REP', 'MODEL_ARTIST'] as const) {
      const actor = await makeUser(role);
      const res = await request(app).get('/admin/catalogs').set(actor.auth);
      expect(res.status).toBe(403);
    }
    const anon = await request(app).get('/admin/catalogs');
    expect(anon.status).toBe(401);
  });

  it('answers a tampered cursor and a bad query with 400, never 500', async () => {
    const admin = await makeUser('ADMIN');
    const badCursor = await request(app).get('/admin/catalogs?cursor=garbage').set(admin.auth);
    expect(badCursor.status).toBe(400);
    expect(badCursor.body.code).toBe('INVALID_CURSOR');

    const otherListsCursor = Buffer.from(
      JSON.stringify({ u: Date.now(), i: new Types.ObjectId().toHexString() })
    ).toString('base64url');
    const foreign = await request(app)
      .get(`/admin/catalogs?cursor=${otherListsCursor}`)
      .set(admin.auth);
    expect(foreign.status).toBe(400);

    const tooBig = await request(app).get('/admin/catalogs?limit=500').set(admin.auth);
    expect(tooBig.status).toBe(400);
    const unknown = await request(app).get('/admin/catalogs?owner=x').set(admin.auth);
    expect(unknown.status).toBe(400);
  });
});
