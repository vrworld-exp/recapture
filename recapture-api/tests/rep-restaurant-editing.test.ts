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

describe('the menu sections, built by the rep', () => {
  // WHAT WAS BROKEN. These routes were read-only, on the reasoning that a
  // category outlives the visit and so belongs to the owner. But `activate`
  // seeds NO categories, so a rep-signed restaurant had zero of them and the
  // rule reduced to "the rep may choose among nothing": every dish landed
  // uncategorized and the public page rendered one flat heap. The first test
  // is the whole feature.
  it('starts with no sections at all — the state that made this necessary', async () => {
    const { catalogId, rep } = await activated('ABCD2345');

    const res = await request(app)
      .get(`/rep/catalogs/${catalogId}/categories`)
      .set(rep.auth);

    expect(res.status).toBe(200);
    expect(res.body.categories).toEqual([]);
  });

  it('creates one, and the OWNER reads it back through their own route', async () => {
    const { catalogId, rep, ownerAuth } = await activated('ABCD2345');

    const created = await request(app)
      .post(`/rep/catalogs/${catalogId}/categories`)
      .set(rep.auth)
      .send({ name: 'Starters' });

    expect(created.status).toBe(201);
    expect(created.body.category.name).toBe(toCatalogSlug('Starters'));

    // THE ASSERTION THAT CATCHES THE OWNERSHIP BUG. Reading back through the
    // owner's route proves the row landed on the RESTAURANT's catalog and not
    // on some catalog of the rep's own.
    const owned = await request(app).get('/catalog/categories').set(ownerAuth);
    expect(owned.status).toBe(200);
    expect(owned.body.categories.map((c: { name: string }) => c.name)).toEqual([
      toCatalogSlug('Starters'),
    ]);
  });

  it('refuses a second section with the same name', async () => {
    const { catalogId, rep } = await activated('ABCD2345');
    await request(app)
      .post(`/rep/catalogs/${catalogId}/categories`)
      .set(rep.auth)
      .send({ name: 'Starters' })
      .expect(201);

    const again = await request(app)
      .post(`/rep/catalogs/${catalogId}/categories`)
      .set(rep.auth)
      .send({ name: 'Starters' });

    // Mirage rejects a duplicate (name, restaurant) outright, so catching it
    // here — while the rep is still looking at the menu — is the whole point.
    expect(again.status).toBe(409);
    expect(again.body.code).toBe('DUPLICATE_NAME');
  });

  it('files a dish into a section at CREATE time', async () => {
    const { catalogId, rep } = await activated('ABCD2345');
    const section = await request(app)
      .post(`/rep/catalogs/${catalogId}/categories`)
      .set(rep.auth)
      .send({ name: 'Starters' })
      .expect(201);

    const dish = await request(app)
      .post(`/rep/catalogs/${catalogId}/products`)
      .set(rep.auth)
      .send({
        type: 'IMAGE_ONLY',
        name: 'Papad',
        imageKey: imageKey(catalogId),
        categoryId: section.body.category.id,
      });

    expect(dish.status).toBe(201);
    // The dish carries the section from the moment it exists — no second trip
    // through the editor, which is the trip nobody made.
    const stored = await CatalogProduct.findById(dish.body.product.id).exec();
    expect(String(stored!.categoryId)).toBe(section.body.category.id);
  });

  it('renames one', async () => {
    const { catalogId, rep } = await activated('ABCD2345');
    const created = await request(app)
      .post(`/rep/catalogs/${catalogId}/categories`)
      .set(rep.auth)
      .send({ name: 'Startrs' })
      .expect(201);

    const renamed = await request(app)
      .patch(`/rep/catalogs/${catalogId}/categories/${created.body.category.id}`)
      .set(rep.auth)
      .send({ name: 'Starters' });

    expect(renamed.status).toBe(200);
    expect(renamed.body.category.name).toBe(toCatalogSlug('Starters'));
  });

  it('reorders them, and /categories reads back in the new order', async () => {
    const { catalogId, rep } = await activated('ABCD2345');
    const ids: string[] = [];
    for (const name of ['Starters', 'Mains', 'Drinks']) {
      const res = await request(app)
        .post(`/rep/catalogs/${catalogId}/categories`)
        .set(rep.auth)
        .send({ name })
        .expect(201);
      ids.push(res.body.category.id);
    }

    const reordered = await request(app)
      .post(`/rep/catalogs/${catalogId}/categories/reorder`)
      .set(rep.auth)
      .send({ ids: [ids[2], ids[0], ids[1]] });

    expect(reordered.status).toBe(200);

    const list = await request(app)
      .get(`/rep/catalogs/${catalogId}/categories`)
      .set(rep.auth);
    expect(list.body.categories.map((c: { id: string }) => c.id)).toEqual([
      ids[2],
      ids[0],
      ids[1],
    ]);
  });

  it('routes /reorder to reorder and not to the :categoryId handler', async () => {
    // STATIC BEFORE PARAMETERISED. If the PATCH/DELETE routes were declared
    // first, `reorder` would arrive as a categoryId — this is the test that
    // fails if somebody moves them.
    const { catalogId, rep } = await activated('ABCD2345');
    const created = await request(app)
      .post(`/rep/catalogs/${catalogId}/categories`)
      .set(rep.auth)
      .send({ name: 'Starters' })
      .expect(201);

    const res = await request(app)
      .post(`/rep/catalogs/${catalogId}/categories/reorder`)
      .set(rep.auth)
      .send({ ids: [created.body.category.id] });

    expect(res.status).toBe(200);
  });

  it('deletes one and MOVES its dishes rather than deleting them', async () => {
    const { catalogId, rep } = await activated('ABCD2345');
    const section = await request(app)
      .post(`/rep/catalogs/${catalogId}/categories`)
      .set(rep.auth)
      .send({ name: 'Starters' })
      .expect(201);
    const categoryId = section.body.category.id;

    const dish = await request(app)
      .post(`/rep/catalogs/${catalogId}/products`)
      .set(rep.auth)
      .send({
        type: 'IMAGE_ONLY',
        name: 'Papad',
        imageKey: imageKey(catalogId),
        categoryId,
      })
      .expect(201);

    const deleted = await request(app)
      .delete(`/rep/catalogs/${catalogId}/categories/${categoryId}`)
      .set(rep.auth);

    expect(deleted.status).toBe(200);
    // The count the rep's confirmation reads back.
    expect(deleted.body.movedProductCount).toBe(1);

    // THE DISH SURVIVES, uncategorized. Deleting a grouping must never delete
    // the things inside it — least of all on somebody else's menu.
    const stored = await CatalogProduct.findById(dish.body.product.id).exec();
    expect(stored).not.toBeNull();
    expect(stored!.categoryId).toBeNull();
    // Absent or null both mean "not soft-deleted"; the schema leaves the field
    // unset rather than writing an explicit null, and either is the answer this
    // test is about.
    expect(stored!.deletedAt ?? null).toBeNull();
  });

  it('bumps draftRevision on every section write', async () => {
    const { catalogId, rep } = await activated('ABCD2345');
    const before = await draftRevisionOf(catalogId);

    await request(app)
      .post(`/rep/catalogs/${catalogId}/categories`)
      .set(rep.auth)
      .send({ name: 'Starters' })
      .expect(201);

    // Still a DRAFT. If this did not move, the "nothing is live yet" line the
    // rep reads before publishing would be wrong in the direction that matters.
    expect(await draftRevisionOf(catalogId)).toBeGreaterThan(before);
  });

  it('refuses a stranger every one of the five', async () => {
    const { catalogId, rep } = await activated('ABCD2345');
    const created = await request(app)
      .post(`/rep/catalogs/${catalogId}/categories`)
      .set(rep.auth)
      .send({ name: 'Starters' })
      .expect(201);
    const categoryId = created.body.category.id;
    const stranger = await makeUser('SALES_REP');

    const responses = [
      await request(app)
        .get(`/rep/catalogs/${catalogId}/categories`)
        .set(stranger.auth),
      await request(app)
        .post(`/rep/catalogs/${catalogId}/categories`)
        .set(stranger.auth)
        .send({ name: 'Theirs' }),
      await request(app)
        .post(`/rep/catalogs/${catalogId}/categories/reorder`)
        .set(stranger.auth)
        .send({ ids: [categoryId] }),
      await request(app)
        .patch(`/rep/catalogs/${catalogId}/categories/${categoryId}`)
        .set(stranger.auth)
        .send({ name: 'Theirs' }),
      await request(app)
        .delete(`/rep/catalogs/${catalogId}/categories/${categoryId}`)
        .set(stranger.auth),
    ];

    for (const res of responses) expect(res.status).toBe(404);

    // And nothing moved.
    const rows = await CatalogCategory.find({
      catalogId: new Types.ObjectId(catalogId),
      deletedAt: null,
    }).exec();
    expect(rows).toHaveLength(1);
    expect(rows[0]!.name).toBe(toCatalogSlug('Starters'));
  });

  it('loses all five the moment the delegation is revoked', async () => {
    const { catalogId, rep } = await activated('ABCD2345');
    await CatalogDelegation.updateMany(
      { catalogId: new Types.ObjectId(catalogId) },
      { $set: { revokedAt: new Date() } }
    );

    const res = await request(app)
      .post(`/rep/catalogs/${catalogId}/categories`)
      .set(rep.auth)
      .send({ name: 'Starters' });

    // The grant is read per request, so a revoke is effective at once.
    expect(res.status).toBe(404);
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

describe('the dish order and bulk moves, by the rep', () => {
  // THE GAP THIS CLOSES. The rep could build sections and file dishes into
  // them, and could not put one dish above another — creation order, forever,
  // until the owner signed in. And the rep's category manager needs the same
  // "move these / empty this section into that one" the owner's has, which is
  // one bulk call and not N patches.

  it('reorders the dishes, and the rep list reads back in the new order', async () => {
    const { catalogId, rep } = await activated('ABCD2345');
    const ids: string[] = [];
    for (const name of ['Dal', 'Butter Chicken', 'Naan']) {
      ids.push(await addDish(catalogId, rep.auth, name));
    }

    const reordered = await request(app)
      .post(`/rep/catalogs/${catalogId}/products/reorder`)
      .set(rep.auth)
      .send({ ids: [ids[1], ids[2], ids[0]] });

    expect(reordered.status).toBe(200);
    expect(reordered.body.reordered).toBe(3);

    const list = await request(app)
      .get(`/rep/catalogs/${catalogId}/products`)
      .set(rep.auth);
    expect(list.body.items.map((p: { id: string }) => p.id)).toEqual([
      ids[1],
      ids[2],
      ids[0],
    ]);
  });

  it('routes /reorder and /bulk to their handlers and not to :productId', async () => {
    // STATIC BEFORE PARAMETERISED. If the GET/PATCH `:productId` routes were
    // declared first, `reorder` and `bulk` would arrive as product ids — this
    // is the test that fails if somebody moves them.
    const { catalogId, rep } = await activated('ABCD2345');
    const dishId = await addDish(catalogId, rep.auth, 'Dal');

    const reorder = await request(app)
      .post(`/rep/catalogs/${catalogId}/products/reorder`)
      .set(rep.auth)
      .send({ ids: [dishId] });
    expect(reorder.status).toBe(200);

    const bulk = await request(app)
      .post(`/rep/catalogs/${catalogId}/products/bulk`)
      .set(rep.auth)
      .send({ action: 'SET_CATEGORY', ids: [dishId], categoryId: null });
    expect(bulk.status).toBe(200);
    expect(bulk.body.affected).toBe(1);
  });

  it("refuses a dish id from another rep's restaurant in the order", async () => {
    const first = await activated('ABCD2345', '+919876543210');
    const second = await activated('EFGH6789', '+919812345678');
    const mine = await addDish(first.catalogId, first.rep.auth, 'Dal');
    const theirs = await addDish(second.catalogId, second.rep.auth, 'Idli');

    const res = await request(app)
      .post(`/rep/catalogs/${first.catalogId}/products/reorder`)
      .set(first.rep.auth)
      .send({ ids: [theirs, mine] });

    // Rejected wholesale, without naming which id was the problem.
    expect(res.status).toBe(400);
    expect(res.body.code).toBe('ID_SET_MISMATCH');
  });

  it('moves many dishes into a section in one call, and the owner sees it', async () => {
    const { catalogId, rep, ownerAuth } = await activated('ABCD2345');
    const section = await request(app)
      .post(`/rep/catalogs/${catalogId}/categories`)
      .set(rep.auth)
      .send({ name: 'Mains' })
      .expect(201);
    const categoryId: string = section.body.category.id;
    const ids = [
      await addDish(catalogId, rep.auth, 'Dal'),
      await addDish(catalogId, rep.auth, 'Naan'),
    ];

    const res = await request(app)
      .post(`/rep/catalogs/${catalogId}/products/bulk`)
      .set(rep.auth)
      .send({ action: 'SET_CATEGORY', ids, categoryId });

    expect(res.status).toBe(200);
    expect(res.body.affected).toBe(2);

    // Landed on the RESTAURANT's rows, readable through the owner's own door.
    const owner = await request(app)
      .get(`/catalog/products?categoryId=${categoryId}`)
      .set(ownerAuth);
    expect(owner.status).toBe(200);
    expect(owner.body.items.map((p: { id: string }) => p.id).sort()).toEqual(
      [...ids].sort()
    );
  });

  it('refuses a section that is not on this menu', async () => {
    const { catalogId, rep } = await activated('ABCD2345');
    const dishId = await addDish(catalogId, rep.auth, 'Dal');

    const res = await request(app)
      .post(`/rep/catalogs/${catalogId}/products/bulk`)
      .set(rep.auth)
      .send({
        action: 'SET_CATEGORY',
        ids: [dishId],
        categoryId: new Types.ObjectId().toHexString(),
      });

    expect(res.status).toBe(404);
    expect(res.body.code).toBe('CATEGORY_NOT_FOUND');
  });

  it('bumps the draft revision on a reorder, so the order is not claimed live', async () => {
    const { catalogId, rep } = await activated('ABCD2345');
    const ids = [
      await addDish(catalogId, rep.auth, 'Dal'),
      await addDish(catalogId, rep.auth, 'Naan'),
    ];
    const before = await draftRevisionOf(catalogId);

    await request(app)
      .post(`/rep/catalogs/${catalogId}/products/reorder`)
      .set(rep.auth)
      .send({ ids: [ids[1], ids[0]] })
      .expect(200);

    expect(await draftRevisionOf(catalogId)).toBeGreaterThan(before);
  });

  it('refuses a stranger both, with the same 404 as a missing catalog', async () => {
    const { catalogId, rep } = await activated('ABCD2345');
    const dishId = await addDish(catalogId, rep.auth, 'Dal');
    const stranger = await makeUser('SALES_REP');

    const responses = [
      await request(app)
        .post(`/rep/catalogs/${catalogId}/products/reorder`)
        .set(stranger.auth)
        .send({ ids: [dishId] }),
      await request(app)
        .post(`/rep/catalogs/${catalogId}/products/bulk`)
        .set(stranger.auth)
        .send({ action: 'SET_CATEGORY', ids: [dishId], categoryId: null }),
    ];

    for (const res of responses) {
      expect(res.status).toBe(404);
      expect(res.body.code).toBe('CATALOG_NOT_FOUND');
    }
  });
});
