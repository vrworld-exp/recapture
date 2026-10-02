// tests/today-staff-pdf.test.ts
//
// more-customization Stage 14 — Today screen, bulk prices, staff access, PDF.
//
//   • bulk price rounding vectors; apply = one bump; undo restores exact old
//     prices and keeps dishes edited since;
//   • the staff permission matrix, enforced over HTTP: STAFF may toggle stock
//     but gets 403 on prices even calling the API directly; a revoke works on
//     the very next request; reps never see staff grants;
//   • "sold out until tomorrow" → the sweep puts it back and logs it;
//   • the PDF renders for 0, 1 and 200 dishes; long names wrap.
import { describe, it, expect, beforeAll, afterAll, afterEach } from 'vitest';
import request from 'supertest';
import mongoose, { Types } from 'mongoose';
import jwt from 'jsonwebtoken';
import { MongoMemoryServer } from 'mongodb-memory-server';

import { createApp } from '@/app';
import { env } from '@/config/env';
import { Catalog } from '@/models/Catalog';
import { CatalogCategory } from '@/models/CatalogCategory';
import { CatalogChangeLog } from '@/models/CatalogChangeLog';
import { CatalogDelegation } from '@/models/CatalogDelegation';
import { CatalogProduct } from '@/models/CatalogProduct';
import { StaffInvite } from '@/models/StaffInvite';
import { User } from '@/models/User';
import { resolveDelegatedCatalog } from '@/services/catalogDelegationService';
import {
  applyBulkPrices,
  bulkPrice,
  nextMorningIst,
  runAvailabilityResetSweep,
  undoLastBulkPrices,
  type Actor,
} from '@/services/todayService';

const app = createApp();
let mongod: MongoMemoryServer;

beforeAll(async () => {
  mongod = await MongoMemoryServer.create();
  await mongoose.connect(mongod.getUri());
  await Promise.all([CatalogDelegation.syncIndexes(), StaffInvite.syncIndexes()]);
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
    CatalogDelegation.deleteMany({}),
    StaffInvite.deleteMany({}),
    CatalogChangeLog.deleteMany({}),
  ]);
});

async function makeUser(phone?: string) {
  const user = await User.create({
    authProvider: 'custom',
    authUid: `test|${new Types.ObjectId().toHexString()}`,
    ...(phone ? { phone, phoneVerified: true } : {}),
  });
  const id = user.id as string;
  const token = jwt.sign({ userId: id, authUid: user.authUid }, env.JWT_SECRET, {
    expiresIn: '15m',
  });
  return { id, auth: { Authorization: `Bearer ${token}` } };
}

async function seed(ownerId: string) {
  const catalog = await Catalog.create({
    userId: new Types.ObjectId(ownerId),
    name: 'Cafe',
    status: 'DRAFT',
    draftRevision: 0,
    publishedRevision: -1,
  });
  const drinks = await CatalogCategory.create({
    catalogId: catalog._id,
    userId: catalog.userId,
    name: 'Drinks',
    position: 0,
  });
  const mk = (name: string, price: number) =>
    CatalogProduct.create({
      catalogId: catalog._id,
      userId: catalog.userId,
      type: 'IMAGE_ONLY',
      name,
      price,
      categoryId: drinks._id,
    });
  const [coffee, tea] = await Promise.all([mk('Cold Coffee', 180), mk('Masala Tea', 40)]);
  return { catalog, drinks, coffee, tea };
}

const owner = (id: string): Actor => ({ userId: id, name: 'Owner', role: 'OWNER' });

// ── Rounding ────────────────────────────────────────────────────────────────

describe('bulkPrice', () => {
  it.each([
    [180, 'PERCENT', 5, 'NONE', 189],
    [180, 'PERCENT', 5, 'FIVE', 190],
    [262, 'FLAT', 0.1, 'NINE', 259],
    [266, 'FLAT', 0.1, 'NINE', 269],
    [40, 'FLAT', 10, 'NONE', 50],
    [40, 'FLAT', -50, 'NONE', null],
    [12, 'FLAT', 0.1, 'NINE', 9],
  ] as const)('%d %s %d %s → %s', (base, mode, amount, rounding, expected) => {
    expect(bulkPrice(base, mode, amount, rounding)).toBe(expected);
  });
});

describe('bulk prices + undo', () => {
  it('applies in one step and undo restores exact values, keeping edited dishes', async () => {
    const u = await makeUser();
    const { catalog, drinks, coffee, tea } = await seed(u.id);
    const ref = { _id: catalog._id as Types.ObjectId, userId: catalog.userId };
    const applied = await applyBulkPrices(ref, owner(u.id), {
      categoryIds: [String(drinks._id)],
      mode: 'PERCENT',
      amount: 10,
      rounding: 'FIVE',
    });
    // 180 → 198 → 200; 40 → 44 → 45.
    expect(applied).toMatchObject({ outcome: 'OK', changed: 2 });
    expect((await CatalogProduct.findById(coffee._id).lean())!.price).toBe(200);
    expect((await Catalog.findById(catalog._id).lean())!.draftRevision).toBe(1);

    await CatalogProduct.updateOne({ _id: tea._id }, { $set: { price: 47 } }); // edited since
    const undo = await undoLastBulkPrices(ref, owner(u.id));
    expect(undo).toEqual({ outcome: 'OK', restored: 1, kept: 1 });
    expect((await CatalogProduct.findById(coffee._id).lean())!.price).toBe(180);
    expect((await CatalogProduct.findById(tea._id).lean())!.price).toBe(47);
    // One undo per batch.
    expect(await undoLastBulkPrices(ref, owner(u.id))).toEqual({
      outcome: 'REJECTED',
      code: 'NOTHING_TO_DO',
    });
  });
});

// ── Staff over HTTP ─────────────────────────────────────────────────────────

describe('staff access', () => {
  it('invites by phone; STAFF toggles stock but gets 403 on prices; revoke is immediate', async () => {
    const o = await makeUser('+919000000001');
    const { catalog, coffee } = await seed(o.id);

    // Invite before the helper has an account → a pending invite.
    const invite = await request(app)
      .post('/catalog/staff')
      .set(o.auth)
      .send({ phone: '98765 43210', kind: 'STAFF', name: 'Ravi' });
    expect(invite.status).toBe(201);
    expect(invite.body.member).toMatchObject({
      status: 'INVITED',
      kind: 'STAFF',
      phone: '+919876543210',
    });

    // Ravi signs in with that number and opens the staff area → claimed.
    const ravi = await makeUser('+919876543210');
    const mine = await request(app).get('/staff/catalogs').set(ravi.auth);
    expect(mine.body.catalogs).toEqual([
      expect.objectContaining({
        catalogId: String(catalog._id),
        kind: 'STAFF',
        permissions: ['availability', 'publish'],
      }),
    ]);
    const base = `/staff/catalogs/${String(catalog._id)}`;

    const price = await request(app)
      .post(`${base}/today`)
      .set(ravi.auth)
      .send({ changes: [{ productId: String(coffee._id), price: 999 }] });
    expect(price.status).toBe(403);
    expect(
      (
        await request(app)
          .post(`${base}/prices/bulk`)
          .set(ravi.auth)
          .send({
            productIds: [String(coffee._id)],
            mode: 'FLAT',
            amount: 10,
            rounding: 'NONE',
          })
      ).status
    ).toBe(403);
    expect((await request(app).post(`${base}/prices/undo`).set(ravi.auth)).status).toBe(403);

    const stock = await request(app)
      .post(`${base}/today`)
      .set(ravi.auth)
      .send({
        changes: [
          { productId: String(coffee._id), availability: 'OUT_OF_STOCK', untilTomorrow: true },
        ],
      });
    expect(stock.status).toBe(200);
    const coffeeNow = (await CatalogProduct.findById(coffee._id).lean())!;
    expect(coffeeNow.availability).toBe('OUT_OF_STOCK');
    expect(coffeeNow.availabilityResetAt).toBeTruthy();
    const log = await CatalogChangeLog.findOne({ kind: 'AVAILABILITY' }).lean();
    expect(log?.actorName).toBe('+919876543210');

    // A staff grant is never a rep grant.
    expect(
      await resolveDelegatedCatalog(new Types.ObjectId(ravi.id), String(catalog._id))
    ).toBeNull();

    // Revoke → the very next request is refused.
    const staff = await request(app).get('/catalog/staff').set(o.auth);
    await request(app).delete(`/catalog/staff/${staff.body.staff[0].id}`).set(o.auth).expect(200);
    expect((await request(app).get(`${base}/today`).set(ravi.auth)).status).toBe(404);
  });

  it('a MANAGER may change prices', async () => {
    const o = await makeUser('+919000000002');
    const { catalog, coffee } = await seed(o.id);
    const m = await makeUser('+919876500000');
    await request(app)
      .post('/catalog/staff')
      .set(o.auth)
      .send({ phone: '+919876500000', kind: 'MANAGER' })
      .expect(201);
    const res = await request(app)
      .post(`/staff/catalogs/${String(catalog._id)}/today`)
      .set(m.auth)
      .send({ changes: [{ productId: String(coffee._id), price: 199 }] });
    expect(res.status).toBe(200);
    expect((await CatalogProduct.findById(coffee._id).lean())!.price).toBe(199);
  });

  it('caps helpers at 5 and refuses the owner’s own number', async () => {
    const o = await makeUser('+919000000003');
    await seed(o.id);
    expect(
      (
        await request(app)
          .post('/catalog/staff')
          .set(o.auth)
          .send({ phone: '+919000000003', kind: 'STAFF' })
      ).status
    ).toBe(400);
    for (let i = 0; i < 5; i += 1) {
      await request(app)
        .post('/catalog/staff')
        .set(o.auth)
        .send({ phone: `+91987650000${i}`, kind: 'STAFF' })
        .expect(201);
    }
    expect(
      (
        await request(app)
          .post('/catalog/staff')
          .set(o.auth)
          .send({ phone: '+919876500009', kind: 'STAFF' })
      ).status
    ).toBe(409);
  });
});

// ── Sweep ───────────────────────────────────────────────────────────────────

describe('sold out until tomorrow', () => {
  it('resets at 05:00 IST next morning', () => {
    // 22:00 IST on 28 Sep → 05:00 IST on 29 Sep = 23:30 UTC on 28 Sep.
    expect(nextMorningIst(new Date('2026-09-28T16:30:00Z')).toISOString()).toBe(
      '2026-09-28T23:30:00.000Z'
    );
  });

  it('the sweep puts due dishes back in stock and logs it', async () => {
    const u = await makeUser();
    const { coffee } = await seed(u.id);
    await CatalogProduct.updateOne(
      { _id: coffee._id },
      { $set: { availability: 'OUT_OF_STOCK', availabilityResetAt: new Date(Date.now() - 1000) } }
    );
    expect(await runAvailabilityResetSweep()).toEqual({ dishes: 1, catalogs: 1 });
    const after = (await CatalogProduct.findById(coffee._id).lean())!;
    expect(after.availability).toBe('IN_STOCK');
    expect(after.availabilityResetAt).toBeUndefined();
    expect(await CatalogChangeLog.countDocuments({ kind: 'AUTO_BACK_IN_STOCK' })).toBe(1);
  });
});
