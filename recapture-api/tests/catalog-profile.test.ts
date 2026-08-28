// tests/catalog-profile.test.ts
//
// GET/PATCH /catalog/profile — the business profile (features 58, 60).
//
// The profile is a VIEW of the catalog document, so the properties worth
// pinning are the ones that would rot silently if the view and the root drifted:
//   • an edit here bumps draftRevision, because branding only reaches customers
//     at publish and the "draft changes not yet live" badge must light up;
//   • `publicFields` is served by the API, so the client's ReCapture-only
//     marking has ONE source of truth rather than a hardcoded copy of Mirage's
//     carried-field list;
//   • URLs are derived from stored KEYS, and an unset key is null — never a
//     `.../undefined` URL;
//   • ownership comes only from the token, and a stranger's profile is the same
//     404 as no catalog at all.
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

async function createCatalogFor(auth: Auth, name = 'My Shop'): Promise<string> {
  const res = await request(app).post('/catalog').set(auth).send({ name });
  return res.body.catalog.id as string;
}

describe('business profile', () => {
  it('requires a token', async () => {
    await request(app).get('/catalog/profile').expect(401);
    await request(app).patch('/catalog/profile').send({ name: 'X' }).expect(401);
  });

  it('404s before a catalog exists', async () => {
    const { auth } = await makeUser();

    const read = await request(app).get('/catalog/profile').set(auth).expect(404);
    expect(read.body.code).toBe('CATALOG_NOT_FOUND');

    await request(app).patch('/catalog/profile').set(auth).send({ name: 'X' }).expect(404);
  });

  it('reads the profile a create seeded, with null URLs before any upload', async () => {
    const { auth } = await makeUser();
    const id = await createCatalogFor(auth, 'Cafe Mocha');

    const res = await request(app).get('/catalog/profile').set(auth).expect(200);

    expect(res.body.profile.id).toBe(id);
    // Names are stored as the slug Mirage keeps — see utils/catalogNames.ts.
    expect(res.body.profile.name).toBe('cafe_mocha');
    expect(res.body.profile.businessName).toBeNull();
    expect(res.body.profile.contact).toBeNull();
    // The model stores keys; no key means no URL — not `<cdn>/undefined`.
    expect(res.body.profile.logoUrl).toBeNull();
    expect(res.body.profile.coverImageUrl).toBeNull();
  });

  it('derives logo and cover URLs from the stored keys', async () => {
    const { auth, id: userId } = await makeUser();
    await createCatalogFor(auth);
    await Catalog.updateOne(
      { userId: new Types.ObjectId(userId) },
      {
        $set: {
          logoKey: 'development/catalog/c1/logo/a.jpg',
          coverImageKey: 'development/catalog/c1/cover/b.jpg',
        },
      }
    ).exec();

    const res = await request(app).get('/catalog/profile').set(auth).expect(200);

    expect(res.body.profile.logoUrl).toBe(
      'https://test.cloudfront.net/development/catalog/c1/logo/a.jpg'
    );
    expect(res.body.profile.coverImageUrl).toBe(
      'https://test.cloudfront.net/development/catalog/c1/cover/b.jpg'
    );
  });

  it('serves publicFields so the client marks ReCapture-only fields from one source', async () => {
    const { auth } = await makeUser();
    await createCatalogFor(auth);

    const res = await request(app).get('/catalog/profile').set(auth).expect(200);

    expect(res.body.profile.publicFields).toEqual([...PUBLIC_PROFILE_FIELDS]);
    // Mirage's update-restaurant (M3) carries name/location/phoneNo/icon only —
    // everything else on the profile is ReCapture-only and must NOT be listed.
    for (const carried of ['name', 'contact.phone', 'contact.address', 'logoUrl']) {
      expect(res.body.profile.publicFields).toContain(carried);
    }
    for (const local of [
      'businessName',
      'contact.email',
      'contact.website',
      'contact.socials',
      'coverImageUrl',
    ]) {
      expect(res.body.profile.publicFields).not.toContain(local);
    }
  });

  it('round-trips a full profile patch', async () => {
    const { auth } = await makeUser();
    await createCatalogFor(auth);

    const contact = {
      phone: '+91 90000 00000',
      email: 'hello@shop.example',
      address: '12 Market Road, Pune',
      website: 'https://shop.example',
      socials: { instagram: 'shop', whatsapp: '+919000000000' },
    };

    const patched = await request(app)
      .patch('/catalog/profile')
      .set(auth)
      .send({ name: 'Cafe Mocha', businessName: 'Mocha Foods Pvt Ltd', contact })
      .expect(200);

    expect(patched.body.profile.name).toBe('cafe_mocha');
    expect(patched.body.profile.businessName).toBe('Mocha Foods Pvt Ltd');
    expect(patched.body.profile.contact).toMatchObject(contact);

    // Persisted, not just echoed.
    const reread = await request(app).get('/catalog/profile').set(auth).expect(200);
    expect(reread.body.profile.contact).toMatchObject(contact);
  });

  it('bumps draftRevision so a branding edit lights up the badge', async () => {
    const { auth, id: userId } = await makeUser();
    await createCatalogFor(auth);
    // Simulate a catalog that is fully published: draft == published, badge off.
    await Catalog.updateOne(
      { userId: new Types.ObjectId(userId) },
      { $set: { status: 'PUBLISHED', publishedRevision: 1, draftRevision: 1 } }
    ).exec();

    const before = await request(app).get('/catalog').set(auth).expect(200);
    expect(before.body.catalog.hasUnpublishedChanges).toBe(false);

    await request(app)
      .patch('/catalog/profile')
      .set(auth)
      .send({ businessName: 'Renamed Foods' })
      .expect(200);

    const after = await request(app).get('/catalog').set(auth).expect(200);
    expect(after.body.catalog.hasUnpublishedChanges).toBe(true);
  });

  it('rejects an empty patch and unknown fields', async () => {
    const { auth } = await makeUser();
    await createCatalogFor(auth);

    await request(app).patch('/catalog/profile').set(auth).send({}).expect(400);
    // `.strict()` — ownership comes from the token, so a userId in the body is
    // REJECTED rather than ignored: dropping it makes an escalation attempt look
    // like a success.
    await request(app)
      .patch('/catalog/profile')
      .set(auth)
      .send({ name: 'X', userId: new Types.ObjectId().toHexString() })
      .expect(400);
    // Bounds mirror the model's maxlength, so an over-long value is a 400 here
    // rather than a 500 out of Mongoose.
    await request(app)
      .patch('/catalog/profile')
      .set(auth)
      .send({ businessName: 'x'.repeat(121) })
      .expect(400);
  });

  it('never exposes internal mapping fields', async () => {
    const { auth } = await makeUser();
    await createCatalogFor(auth);

    const res = await request(app).get('/catalog/profile').set(auth).expect(200);

    for (const leaked of [
      'mirageRestaurantId',
      'activePublishRunId',
      'deletedAt',
      'logoKey',
      'coverImageKey',
      '_id',
      '__v',
    ]) {
      expect(res.body.profile).not.toHaveProperty(leaked);
    }
  });

  it("one user cannot read or write another user's profile", async () => {
    const a = await makeUser();
    const b = await makeUser();
    await createCatalogFor(a.auth, 'A Shop');

    // Identical to "no catalog at all" — not-found and not-owned must be
    // indistinguishable at the boundary.
    await request(app).get('/catalog/profile').set(b.auth).expect(404);
    await request(app).patch('/catalog/profile').set(b.auth).send({ name: 'Hijacked' }).expect(404);

    const untouched = await request(app).get('/catalog/profile').set(a.auth).expect(200);
    expect(untouched.body.profile.name).toBe('a_shop');
  });

  it('the profile view and the catalog root stay consistent', async () => {
    const { auth } = await makeUser();
    await createCatalogFor(auth);

    // A write through EITHER endpoint is visible from the other — they are one
    // document, and applyCatalogPatch is the single write path.
    await request(app).patch('/catalog').set(auth).send({ name: 'Via Root' }).expect(200);
    const viaProfile = await request(app).get('/catalog/profile').set(auth).expect(200);
    expect(viaProfile.body.profile.name).toBe('via_root');

    await request(app).patch('/catalog/profile').set(auth).send({ name: 'Via Profile' }).expect(200);
    const viaRoot = await request(app).get('/catalog').set(auth).expect(200);
    expect(viaRoot.body.catalog.name).toBe('via_profile');
  });
});
