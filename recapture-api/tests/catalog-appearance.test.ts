// tests/catalog-appearance.test.ts
//
// PATCH /catalog/profile `appearance` — the menu look (more-customization Stage 2).
//
// What is pinned:
//   • it is an authoring write: it bumps draftRevision, so the look goes live
//     only at Publish (D6);
//   • it REPLACES the block and `null` resets it, so "Reset to default" and
//     "clear my accent" are both expressible;
//   • an unreadable colour is refused with its own code and the failing pair,
//     and a refused write changes nothing — not even the draft revision;
//   • a catalog that never set one reads `appearance: null`.
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
import { PUBLIC_PROFILE_FIELDS } from '@/services/catalogService';

const app = createApp();
let mongod: MongoMemoryServer;

beforeAll(async () => {
  mongod = await MongoMemoryServer.create();
  await mongoose.connect(mongod.getUri());
  await Catalog.syncIndexes();
});

afterAll(async () => {
  await mongoose.disconnect();
  await mongod.stop();
});

afterEach(async () => {
  await Promise.all([User.deleteMany({}), Catalog.deleteMany({})]);
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

async function draftRevisionOf(id: string): Promise<number> {
  return (await Catalog.findById(id).lean().exec())!.draftRevision;
}

describe('catalog appearance', () => {
  it('is null on a catalog that never chose one, and marked as public', async () => {
    const { auth } = await ownerWithCatalog();
    const res = await request(app).get('/catalog/profile').set(auth).expect(200);

    expect(res.body.profile.appearance).toBeNull();
    expect(PUBLIC_PROFILE_FIELDS).toContain('appearance');
    expect(res.body.profile.publicFields).toContain('appearance');
  });

  it('saves a preset with custom colours, upper-cased, and bumps the draft', async () => {
    const { auth, catalogId } = await ownerWithCatalog();
    const before = await draftRevisionOf(catalogId);

    const res = await request(app)
      .patch('/catalog/profile')
      .set(auth)
      .send({ appearance: { presetId: 'espresso', accent: '#e6c79c' } })
      .expect(200);

    expect(res.body.profile.appearance).toEqual({ presetId: 'espresso', accent: '#E6C79C' });
    expect(await draftRevisionOf(catalogId)).toBe(before + 1);
  });

  it('replaces the block: a key left out is a key cleared', async () => {
    const { auth } = await ownerWithCatalog();
    await request(app)
      .patch('/catalog/profile')
      .set(auth)
      .send({ appearance: { presetId: 'basalt', primary: '#1565C0' } })
      .expect(200);

    const res = await request(app)
      .patch('/catalog/profile')
      .set(auth)
      .send({ appearance: { presetId: 'basalt' } })
      .expect(200);

    expect(res.body.profile.appearance).toEqual({ presetId: 'basalt' });
  });

  it('resets to the default look on null', async () => {
    const { auth, catalogId } = await ownerWithCatalog();
    await request(app)
      .patch('/catalog/profile')
      .set(auth)
      .send({ appearance: { presetId: 'garden' } })
      .expect(200);

    const res = await request(app)
      .patch('/catalog/profile')
      .set(auth)
      .send({ appearance: null })
      .expect(200);

    expect(res.body.profile.appearance).toBeNull();
    expect((await Catalog.findById(catalogId).lean().exec())!.appearance).toBeUndefined();
  });

  it('leaves the appearance alone when a patch does not mention it', async () => {
    const { auth } = await ownerWithCatalog();
    await request(app)
      .patch('/catalog/profile')
      .set(auth)
      .send({ appearance: { presetId: 'royal' } })
      .expect(200);

    const res = await request(app)
      .patch('/catalog/profile')
      .set(auth)
      .send({ businessName: 'Blue Hospitality' })
      .expect(200);

    expect(res.body.profile.appearance).toEqual({ presetId: 'royal' });
  });

  it('refuses an unknown preset and a malformed colour as INVALID_REQUEST', async () => {
    const { auth } = await ownerWithCatalog();

    const preset = await request(app)
      .patch('/catalog/profile')
      .set(auth)
      .send({ appearance: { presetId: 'neon-dreams' } })
      .expect(400);
    expect(preset.body.code).toBe('INVALID_REQUEST');

    const colour = await request(app)
      .patch('/catalog/profile')
      .set(auth)
      .send({ appearance: { primary: 'red' } })
      .expect(400);
    expect(colour.body.code).toBe('INVALID_REQUEST');

    await request(app)
      .patch('/catalog/profile')
      .set(auth)
      .send({ appearance: { presetId: 'basalt', css: 'body{}' } })
      .expect(400);
  });

  it('refuses an unreadable colour with its own code and changes nothing', async () => {
    const { auth, catalogId } = await ownerWithCatalog();
    const before = await draftRevisionOf(catalogId);

    const res = await request(app)
      .patch('/catalog/profile')
      .set(auth)
      .send({ appearance: { presetId: 'garden', primary: '#FFF59D' } })
      .expect(400);

    expect(res.body.code).toBe('APPEARANCE_LOW_CONTRAST');
    expect(res.body.fields).toHaveProperty(['appearance.primary']);
    expect(res.body.message).toContain('#FFF59D');
    expect(await draftRevisionOf(catalogId)).toBe(before);
  });

  it('is refused the same way on PATCH /catalog', async () => {
    const { auth } = await ownerWithCatalog();
    const res = await request(app)
      .patch('/catalog')
      .set(auth)
      .send({ appearance: { presetId: 'garden', accent: '#EEEEEE' } })
      .expect(400);
    expect(res.body.code).toBe('APPEARANCE_LOW_CONTRAST');
  });
});
