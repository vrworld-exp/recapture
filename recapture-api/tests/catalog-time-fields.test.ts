// tests/catalog-time-fields.test.ts
//
// Opening hours, the announcement strip and category availability windows
// (more-customization Stage 4).
//
// Pinned: all three are authoring writes (draftRevision moves), all three
// REPLACE what was stored and `null` removes them, and the validation that the
// public page relies on — no overlapping slots, at most three a day, an end
// after its start — is a 400 here rather than a surprise on a diner's phone.
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
import { PUBLIC_PROFILE_FIELDS } from '@/services/catalogService';

const app = createApp();
let mongod: MongoMemoryServer;

beforeAll(async () => {
  mongod = await MongoMemoryServer.create();
  await mongoose.connect(mongod.getUri());
  await Catalog.syncIndexes();
  await CatalogCategory.syncIndexes();
});

afterAll(async () => {
  await mongoose.disconnect();
  await mongod.stop();
});

afterEach(async () => {
  await Promise.all([User.deleteMany({}), Catalog.deleteMany({}), CatalogCategory.deleteMany({})]);
});

type Auth = { Authorization: string };

async function ownerWithCatalog(): Promise<{ auth: Auth; catalogId: string }> {
  const user = await User.create({
    authProvider: 'custom',
    authUid: `test|${new Types.ObjectId().toHexString()}`,
  });
  const token = jwt.sign({ userId: user.id, authUid: user.authUid }, env.JWT_SECRET, {
    expiresIn: '15m',
  });
  const auth = { Authorization: `Bearer ${token}` };
  const res = await request(app).post('/catalog').set(auth).send({ name: 'Blue Cafe' });
  return { auth, catalogId: res.body.catalog.id as string };
}

const draftRevisionOf = async (id: string) =>
  (await Catalog.findById(id).lean().exec())!.draftRevision;

const lunchAndDinner = {
  weekly: [
    { day: 1, open: '12:00', close: '15:00' },
    { day: 1, open: '19:00', close: '01:00' },
  ],
  closedDates: ['2099-10-20', '2099-10-20'],
};

describe('opening hours', () => {
  it('saves two slots, defaults the zone and the badge, and bumps the draft', async () => {
    const { auth, catalogId } = await ownerWithCatalog();
    const before = await draftRevisionOf(catalogId);

    const res = await request(app)
      .patch('/catalog/profile')
      .set(auth)
      .send({ hours: lunchAndDinner })
      .expect(200);

    expect(res.body.profile.hours).toEqual({
      timezone: 'Asia/Kolkata',
      weekly: lunchAndDinner.weekly,
      closedDates: ['2099-10-20'],
      showOpenBadge: true,
    });
    expect(await draftRevisionOf(catalogId)).toBe(before + 1);
    expect(PUBLIC_PROFILE_FIELDS).toEqual(expect.arrayContaining(['hours', 'announcement']));
  });

  it('refuses overlapping slots, a fourth slot, bad times and an unknown zone', async () => {
    const { auth } = await ownerWithCatalog();
    const bad = [
      { weekly: [{ day: 1, open: '12:00', close: '15:00' }, { day: 1, open: '14:00', close: '16:00' }] },
      // A past-midnight slot overlaps the next one it runs into.
      { weekly: [{ day: 1, open: '19:00', close: '02:00' }, { day: 1, open: '20:00', close: '21:00' }] },
      { weekly: [1, 2, 3, 4].map((i) => ({ day: 2, open: `0${i}:00`, close: `0${i}:30` })) },
      { weekly: [{ day: 1, open: '9:00', close: '11:00' }] },
      { timezone: 'Mars/Olympus', weekly: [] },
    ];
    for (const hours of bad) {
      const res = await request(app).patch('/catalog/profile').set(auth).send({ hours });
      expect(res.status, JSON.stringify(hours)).toBe(400);
    }
  });

  it('removes the hours on null', async () => {
    const { auth } = await ownerWithCatalog();
    await request(app).patch('/catalog/profile').set(auth).send({ hours: lunchAndDinner });
    const res = await request(app)
      .patch('/catalog/profile')
      .set(auth)
      .send({ hours: null })
      .expect(200);
    expect(res.body.profile.hours).toBeNull();
  });
});

describe('announcement', () => {
  it('saves a dated announcement with its dates as ISO strings', async () => {
    const { auth } = await ownerWithCatalog();
    const res = await request(app)
      .patch('/catalog/profile')
      .set(auth)
      .send({
        announcement: {
          text: 'Diwali special — 20% off thalis',
          style: 'offer',
          startsAt: '2026-10-18T00:00:00+05:30',
          endsAt: '2026-10-22T00:00:00+05:30',
        },
      })
      .expect(200);

    expect(res.body.profile.announcement).toMatchObject({
      text: 'Diwali special — 20% off thalis',
      style: 'offer',
      startsAt: '2026-10-17T18:30:00.000Z',
      endsAt: '2026-10-21T18:30:00.000Z',
    });
  });

  it('refuses an empty or over-long text, an end before its start, a non-http link', async () => {
    const { auth } = await ownerWithCatalog();
    for (const announcement of [
      { text: '' },
      { text: 'x'.repeat(121) },
      { text: 'Hi', startsAt: '2026-10-22', endsAt: '2026-10-18' },
      { text: 'Hi', link: 'javascript:alert(1)' },
      { text: 'Hi', style: 'party' },
    ]) {
      const res = await request(app).patch('/catalog/profile').set(auth).send({ announcement });
      expect(res.status, JSON.stringify(announcement)).toBe(400);
    }
  });

  it('clears on null', async () => {
    const { auth } = await ownerWithCatalog();
    await request(app).patch('/catalog/profile').set(auth).send({ announcement: { text: 'Hi' } });
    const res = await request(app)
      .patch('/catalog/profile')
      .set(auth)
      .send({ announcement: null })
      .expect(200);
    expect(res.body.profile.announcement).toBeNull();
  });
});

describe('category availability window', () => {
  it('creates a breakfast section, dims by default, and can be made always-on again', async () => {
    const { auth, catalogId } = await ownerWithCatalog();

    const created = await request(app)
      .post('/catalog/categories')
      .set(auth)
      .send({ name: 'Breakfast', schedule: { days: [5, 1, 1], from: '07:00', to: '11:00' } })
      .expect(201);
    expect(created.body.category.schedule).toEqual({ days: [1, 5], from: '07:00', to: '11:00' });
    expect(created.body.category.outsideWindow).toBe('dim');

    const before = await draftRevisionOf(catalogId);
    const updated = await request(app)
      .patch(`/catalog/categories/${created.body.category.id}`)
      .set(auth)
      .send({ schedule: null, outsideWindow: 'hide' })
      .expect(200);
    expect(updated.body.category.schedule).toBeNull();
    expect(updated.body.category.outsideWindow).toBe('hide');
    expect(await draftRevisionOf(catalogId)).toBeGreaterThan(before);
  });

  it('refuses an empty day list or a zero-length window', async () => {
    const { auth } = await ownerWithCatalog();
    for (const schedule of [
      { days: [], from: '07:00', to: '11:00' },
      { days: [1], from: '07:00', to: '07:00' },
    ]) {
      await request(app)
        .post('/catalog/categories')
        .set(auth)
        .send({ name: 'Breakfast', schedule })
        .expect(400);
    }
  });
});
