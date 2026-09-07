// tests/rep-restaurant-editing.test.ts
//
// The rep's EDITING surface: the restaurant's own details, and one dish.
//
// Three things are being protected here, in the order they would hurt:
//
//   • THE GATE STILL HOLDS. Every route added for this feature is behind the
//     same `resolveDelegatedCatalog` as the ones before it, and a rep without a
//     grant must get the SAME 404 a nonexistent catalog gives — byte-identical,
//     so the new routes cannot be used to enumerate catalogs the older ones
//     protect.
//   • THE WRITE LANDS ON THE RESTAURANT. A rep's edit must produce a row owned
//     by the restaurant and identical to one the owner would have made. The
//     assertion that catches the whole class of ownership bugs is reading the
//     result back through the OWNER's own route.
//   • IT IS STILL A DRAFT. Every write bumps `draftRevision`. If it did not,
//     the "not live yet" line a rep reads before publishing would be a lie in
//     the direction that matters — telling them the page is current when their
//     edit has not reached it.
import { describe, it, expect, beforeAll, afterAll, beforeEach, afterEach, vi } from 'vitest';
import request from 'supertest';
import mongoose, { Types } from 'mongoose';
import jwt from 'jsonwebtoken';
import { MongoMemoryServer } from 'mongodb-memory-server';

import { HeadObjectCommand, DeleteObjectCommand } from '@aws-sdk/client-s3';

import { createApp } from '@/app';
import { env } from '@/config/env';
import { s3Client } from '@/config/s3';
import { buildProductImageKey } from '@/utils/productImageKeys';
// Names are stored SLUGGED — `catalogSchemas.slugName` normalises every name to
// the form Mirage keys items by. Asserting through the same function rather
// than against a hand-written 'masala_dosa' keeps these tests honest if the
// slug rule ever changes, and documents that the transform is deliberate.
import { toCatalogSlug } from '@/utils/catalogNames';
import { User, type UserRole } from '@/models/User';
import { Catalog } from '@/models/Catalog';
import { CatalogCategory } from '@/models/CatalogCategory';
import { CatalogDelegation } from '@/models/CatalogDelegation';
import { CatalogProduct } from '@/models/CatalogProduct';
import { QrCode } from '@/models/QrCode';
import { QrCodeAssignment } from '@/models/QrCodeAssignment';
import { RateWindow } from '@/models/RateWindow';

const app = createApp();
let mongod: MongoMemoryServer;

beforeAll(async () => {
  mongod = await MongoMemoryServer.create();
  await mongoose.connect(mongod.getUri());
  await QrCode.syncIndexes();
  await Catalog.syncIndexes();
  await CatalogDelegation.syncIndexes();
});

afterAll(async () => {
  await mongoose.disconnect();
  await mongod.stop();
});

/** Keys the scripted S3 believes exist, and their sizes. */
const s3Objects = new Map<string, number>();

beforeEach(() => {
  Object.assign(env, { PUBLIC_RESOLVER_BASE_URL: 'https://scan.test' });
  vi.spyOn(console, 'log').mockImplementation(() => {});
  vi.spyOn(console, 'warn').mockImplementation(() => {});

  // Image keys are HEADed rather than trusted, both on create and on the
  // replacement this suite exercises. Scripted so the rep path runs the real
  // containment guard instead of a stub of it.
  s3Objects.clear();
  vi.spyOn(s3Client, 'send').mockImplementation((command: unknown) => {
    if (command instanceof HeadObjectCommand) {
      const key = command.input.Key as string;
      if (!s3Objects.has(key)) {
        const err = new Error('NotFound');
        err.name = 'NotFound';
        return Promise.reject(err);
      }
      return Promise.resolve({ ContentLength: s3Objects.get(key) }) as never;
    }
    if (command instanceof DeleteObjectCommand) {
      s3Objects.delete(command.input.Key as string);
      return Promise.resolve({}) as never;
    }
    return Promise.reject(new Error(`unscripted S3 command: ${String(command)}`));
  });
});

afterEach(async () => {
  vi.restoreAllMocks();
  await Promise.all([
    User.deleteMany({}),
    Catalog.deleteMany({}),
    CatalogCategory.deleteMany({}),
    CatalogDelegation.deleteMany({}),
    CatalogProduct.deleteMany({}),
    QrCode.deleteMany({}),
    QrCodeAssignment.deleteMany({}),
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

/** A rep who has activated one standee, and the catalog they now hold. */
async function activated(code: string, phone = '+919876543210') {
  const rep = await makeUser('SALES_REP');
  await QrCode.create({
    code,
    batchId: new Types.ObjectId(),
    state: 'UNASSIGNED',
    deletedAt: null,
  });
  const res = await request(app)
    .post('/rep/activations')
    .set(rep.auth)
    .send({ code, restaurantName: 'Blue Cafe', restaurantPhone: phone });
  expect(res.status).toBe(201);

  const catalogId: string = res.body.catalogId;
  const owner = await User.findOne({ phone }).exec();
  const ownerId = String(owner!._id);

  // The restaurant signs in on their own phone in real life; here they just
  // need a token, so the assertions can read their catalog through the OWNER
  // routes and prove the rep's writes landed on the restaurant's own row.
  const ownerToken = jwt.sign(
    { userId: ownerId, authUid: owner!.authUid },
    env.JWT_SECRET,
    { expiresIn: '15m' }
  );

  return {
    rep,
    catalogId,
    ownerId,
    ownerAuth: { Authorization: `Bearer ${ownerToken}` },
  };
}

/** An image key that exists in the scripted S3 and is scoped to [catalogId]. */
function imageKey(catalogId: string): string {
  const key = buildProductImageKey(
    catalogId,
    new Types.ObjectId().toHexString(),
    new Types.ObjectId().toHexString(),
    'jpg'
  );
  s3Objects.set(key, 1024);
  return key;
}

async function addDish(
  catalogId: string,
  auth: { Authorization: string },
  name: string
): Promise<string> {
  const res = await request(app)
    .post(`/rep/catalogs/${catalogId}/products`)
    .set(auth)
    .send({ type: 'IMAGE_ONLY', name, imageKey: imageKey(catalogId) });
  expect(res.status).toBe(201);
  return res.body.product.id as string;
}

async function draftRevisionOf(catalogId: string): Promise<number> {
  const catalog = await Catalog.findById(catalogId).exec();
  return catalog!.draftRevision as number;
}

describe('the gate covers every new route', () => {
  it('answers a stranger exactly as it answers a catalog that does not exist', async () => {
    const { catalogId } = await activated('ABCD2345');
    const stranger = await makeUser('SALES_REP');
    const ghostId = new Types.ObjectId().toHexString();

    // Every route this feature added, in one sweep. A route that forgot the
    // gate would answer 200 here, and a route that used a DIFFERENT 404 would
    // let a stranger tell a real catalog from an imaginary one.
    const paths = (id: string) => [
      `/rep/catalogs/${id}`,
      `/rep/catalogs/${id}/categories`,
      `/rep/catalogs/${id}/profile`,
    ];

    for (const [real, ghost] of paths(catalogId).map(
      (p, i) => [p, paths(ghostId)[i]] as const
    )) {
      const notDelegated = await request(app).get(real).set(stranger.auth);
      const nonexistent = await request(app).get(ghost).set(stranger.auth);

      expect(notDelegated.status, real).toBe(404);
      expect(nonexistent.status, ghost).toBe(404);
      expect(notDelegated.body, real).toEqual(nonexistent.body);
    }
  });

  it('refuses a stranger the profile write and the dish write alike', async () => {
    const { catalogId, rep } = await activated('ABCD2345');
    const dishId = await addDish(catalogId, rep.auth, 'Dosa');
    const stranger = await makeUser('SALES_REP');

    const profile = await request(app)
      .patch(`/rep/catalogs/${catalogId}/profile`)
      .set(stranger.auth)
      .send({ name: 'Not Their Cafe' });
    const dish = await request(app)
      .patch(`/rep/catalogs/${catalogId}/products/${dishId}`)
      .set(stranger.auth)
      .send({ name: 'Not Their Dosa' });

    expect(profile.status).toBe(404);
    expect(dish.status).toBe(404);

    // And nothing moved.
    const catalog = await Catalog.findById(catalogId).exec();
    expect(catalog!.name).toBe(toCatalogSlug('Blue Cafe'));
    const product = await CatalogProduct.findById(dishId).exec();
    expect(product!.name).toBe(toCatalogSlug('Dosa'));
  });

  it('is closed to a plain USER even with a real catalog id', async () => {
    const { catalogId } = await activated('ABCD2345');
    const user = await makeUser('USER');

    const res = await request(app)
      .get(`/rep/catalogs/${catalogId}/profile`)
      .set(user.auth);

    // The ROUTER-level role gate, before any of this feature's code runs.
    expect(res.status).toBe(403);
  });
});

describe("the restaurant's details, edited by the rep", () => {
  it('writes the contact block onto the RESTAURANT and the owner reads it back', async () => {
    const { catalogId, rep, ownerAuth } = await activated('ABCD2345');

    const patch = await request(app)
      .patch(`/rep/catalogs/${catalogId}/profile`)
      .set(rep.auth)
      .send({
        name: 'Blue Cafe',
        businessName: 'Blue Hospitality LLP',
        contact: {
          phone: '+919876543210',
          address: '14 MG Road, Bengaluru',
          website: 'https://bluecafe.example',
          socials: { instagram: '@bluecafe' },
        },
      });

    expect(patch.status).toBe(200);
    expect(patch.body.profile.businessName).toBe('Blue Hospitality LLP');
    expect(patch.body.profile.contact.address).toBe('14 MG Road, Bengaluru');

    // THE ASSERTION THAT MATTERS. Read through the OWNER's own route: if the
    // rep's write had landed anywhere but the restaurant's catalog, this is
    // where it would show.
    const owned = await request(app).get('/catalog/profile').set(ownerAuth);
    expect(owned.status).toBe(200);
    expect(owned.body.profile.contact.website).toBe('https://bluecafe.example');
    expect(owned.body.profile.contact.socials.instagram).toBe('@bluecafe');
  });

  it('replaces the contact block rather than merging into it', async () => {
    const { catalogId, rep } = await activated('ABCD2345');

    await request(app)
      .patch(`/rep/catalogs/${catalogId}/profile`)
      .set(rep.auth)
      .send({ contact: { phone: '+911111111111', website: 'https://a.example' } });

    const second = await request(app)
      .patch(`/rep/catalogs/${catalogId}/profile`)
      .set(rep.auth)
      .send({ contact: { phone: '+911111111111' } });

    // The whole point of replace-not-merge: it is the only way "clear the
    // website" is expressible at all, and the rep form sends the full block for
    // exactly this reason.
    expect(second.status).toBe(200);
    expect(second.body.profile.contact.website).toBeUndefined();
  });

  it('bumps the draft revision, so nothing is claimed to be live', async () => {
    const { catalogId, rep } = await activated('ABCD2345');
    const before = await draftRevisionOf(catalogId);

    await request(app)
      .patch(`/rep/catalogs/${catalogId}/profile`)
      .set(rep.auth)
      .send({ contact: { phone: '+912222222222' } });

    expect(await draftRevisionOf(catalogId)).toBeGreaterThan(before);
  });

  it('rejects an empty patch instead of bumping the revision for nothing', async () => {
    const { catalogId, rep } = await activated('ABCD2345');
    const before = await draftRevisionOf(catalogId);

    const res = await request(app)
      .patch(`/rep/catalogs/${catalogId}/profile`)
      .set(rep.auth)
      .send({});

    expect(res.status).toBe(400);
    expect(res.body.code).toBe('INVALID_REQUEST');
    // A 200 here would light up "draft changes not yet live" for an edit
    // nobody made.
    expect(await draftRevisionOf(catalogId)).toBe(before);
  });

  it('refuses a smuggled ownership field rather than ignoring it', async () => {
    const { catalogId, rep, ownerId } = await activated('ABCD2345');

    const res = await request(app)
      .patch(`/rep/catalogs/${catalogId}/profile`)
      .set(rep.auth)
      .send({ name: 'Blue Cafe', userId: new Types.ObjectId().toHexString() });

    // `.strict()`. Silently dropping the key would make a privilege-escalation
    // attempt look like a success.
    expect(res.status).toBe(400);
    const catalog = await Catalog.findById(catalogId).exec();
    expect(String(catalog!.userId)).toBe(ownerId);
  });

  it('serves the catalog document and its sections', async () => {
    const { catalogId, rep, ownerId } = await activated('ABCD2345');
    await CatalogCategory.create({
      catalogId: new Types.ObjectId(catalogId),
      userId: new Types.ObjectId(ownerId),
      name: 'Starters',
      position: 0,
      deletedAt: null,
    });

    const catalog = await request(app)
      .get(`/rep/catalogs/${catalogId}`)
      .set(rep.auth);
    const categories = await request(app)
      .get(`/rep/catalogs/${catalogId}/categories`)
      .set(rep.auth);

    expect(catalog.status).toBe(200);
    expect(catalog.body.catalog.id).toBe(catalogId);
    expect(categories.status).toBe(200);
    expect(categories.body.categories.map((c: { name: string }) => c.name)).toEqual([
      'Starters',
    ]);
    // (Category rows are written directly here, so this one is NOT slugged —
    // the slug rule lives in the route schema, and this test bypassed it.)
  });
});

describe('one dish, edited by the rep', () => {
  it('reads a dish back by id, which is what a browser reload needs', async () => {
    const { catalogId, rep } = await activated('ABCD2345');
    const dishId = await addDish(catalogId, rep.auth, 'Masala Dosa');

    const res = await request(app)
      .get(`/rep/catalogs/${catalogId}/products/${dishId}`)
      .set(rep.auth);

    expect(res.status).toBe(200);
    expect(res.body.product.name).toBe(toCatalogSlug('Masala Dosa'));
  });

  it('does not swallow the literal `image` segment as a product id', async () => {
    const { catalogId, rep } = await activated('ABCD2345');

    // The route-ordering guard. If `:productId` were declared above the image
    // routes, this would answer the dish reader's 404 instead of doing the
    // upload's own validation — and every photo upload would break.
    const res = await request(app)
      .post(`/rep/catalogs/${catalogId}/products/image/upload-url`)
      .set(rep.auth)
      .send({ contentType: 'image/jpeg' });

    expect(res.status).toBe(201);
    expect(res.body.slot.key).toContain(catalogId);
  });

  it('edits name, price and description, and the owner sees the result', async () => {
    const { catalogId, rep, ownerAuth } = await activated('ABCD2345');
    const dishId = await addDish(catalogId, rep.auth, 'Masala Dosa');

    const res = await request(app)
      .patch(`/rep/catalogs/${catalogId}/products/${dishId}`)
      .set(rep.auth)
      .send({ name: 'Mysore Masala Dosa', price: 180, description: 'With red chutney' });

    expect(res.status).toBe(200);
    expect(res.body.product.name).toBe(toCatalogSlug('Mysore Masala Dosa'));
    expect(res.body.product.price).toBe(180);

    const owned = await request(app).get(`/catalog/products/${dishId}`).set(ownerAuth);
    expect(owned.status).toBe(200);
    expect(owned.body.product.description).toBe('With red chutney');
  });

  it('clears a price with an explicit null, which is not the same as omitting it', async () => {
    const { catalogId, rep } = await activated('ABCD2345');
    const dishId = await addDish(catalogId, rep.auth, 'Masala Dosa');

    await request(app)
      .patch(`/rep/catalogs/${catalogId}/products/${dishId}`)
      .set(rep.auth)
      .send({ price: 180 });

    const cleared = await request(app)
      .patch(`/rep/catalogs/${catalogId}/products/${dishId}`)
      .set(rep.auth)
      .send({ price: null });

    // A dish with no price set and a dish that costs nothing are different
    // claims, and the client's sentinel exists to keep them apart.
    expect(cleared.status).toBe(200);
    expect(cleared.body.product.price).toBeNull();
  });

  it('replaces the photo with a key the containment guard accepts', async () => {
    const { catalogId, rep } = await activated('ABCD2345');
    const dishId = await addDish(catalogId, rep.auth, 'Masala Dosa');
    const replacement = imageKey(catalogId);

    const res = await request(app)
      .patch(`/rep/catalogs/${catalogId}/products/${dishId}`)
      .set(rep.auth)
      .send({ imageKey: replacement });

    expect(res.status).toBe(200);
    expect(res.body.product.imageUrl ?? res.body.product.thumbnailUrl).toContain(
      replacement
    );
  });

  it("refuses a key scoped to somebody else's catalog", async () => {
    const { catalogId, rep } = await activated('ABCD2345');
    const dishId = await addDish(catalogId, rep.auth, 'Masala Dosa');
    const otherCatalogId = new Types.ObjectId().toHexString();
    const foreign = buildProductImageKey(
      otherCatalogId,
      new Types.ObjectId().toHexString(),
      new Types.ObjectId().toHexString(),
      'jpg'
    );
    s3Objects.set(foreign, 1024);

    const res = await request(app)
      .patch(`/rep/catalogs/${catalogId}/products/${dishId}`)
      .set(rep.auth)
      .send({ imageKey: foreign });

    // The object EXISTS — that is the point. Containment, not existence, is
    // what stops a rep binding another restaurant's photo onto this dish.
    expect(res.status).toBe(400);
  });

  it('refuses a dish id belonging to another catalog with the dish 404', async () => {
    const first = await activated('ABCD2345', '+919876543210');
    const second = await activated('EFGH6789', '+919812345678');
    const dishId = await addDish(second.catalogId, second.rep.auth, 'Idli');

    const res = await request(app)
      .patch(`/rep/catalogs/${first.catalogId}/products/${dishId}`)
      .set(first.rep.auth)
      .send({ name: 'Stolen Idli' });

    expect(res.status).toBe(404);
    const untouched = await CatalogProduct.findById(dishId).exec();
    expect(untouched!.name).toBe(toCatalogSlug('Idli'));
  });

  it('bumps the draft revision, so the edit is not claimed to be live', async () => {
    const { catalogId, rep } = await activated('ABCD2345');
    const dishId = await addDish(catalogId, rep.auth, 'Masala Dosa');
    const before = await draftRevisionOf(catalogId);

    await request(app)
      .patch(`/rep/catalogs/${catalogId}/products/${dishId}`)
      .set(rep.auth)
      .send({ name: 'Mysore Masala Dosa' });

    expect(await draftRevisionOf(catalogId)).toBeGreaterThan(before);
  });
});
