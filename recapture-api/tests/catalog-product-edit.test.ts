// tests/catalog-product-edit.test.ts
//
// Product edit beyond plain fields (features 15, 16, 17, 18) and catalog
// branding uploads (feature 2).
//
// The properties worth pinning here are the ones that leave a product in a state
// its assets do not match:
//   • a conversion must arrive WITH the asset its new type needs, in the same
//     request — the safety property that lets `type` be patchable at all;
//   • converting away from 3D must drop the model refs, or the product still
//     renders in a viewer it no longer has a model for;
//   • a duplicate must NOT carry `mirageItemId` or sync state, or two ReCapture
//     products would claim one Mirage item and overwrite each other on publish.
//
// Hermetic: in-memory MongoDB and a scripted S3 — CI never calls AWS.
import { describe, it, expect, beforeAll, afterAll, afterEach, beforeEach, vi } from 'vitest';
import request from 'supertest';
import mongoose, { Types } from 'mongoose';
import jwt from 'jsonwebtoken';
import { MongoMemoryServer } from 'mongodb-memory-server';
import {
  DeleteObjectCommand,
  HeadObjectCommand,
  ListObjectsV2Command,
} from '@aws-sdk/client-s3';

import { createApp } from '@/app';
import { env } from '@/config/env';
import { s3Client } from '@/config/s3';
import { User } from '@/models/User';
import { Project } from '@/models/Project';
import { ProjectModel } from '@/models/ProjectModel';
import { Catalog } from '@/models/Catalog';
import { CatalogProduct } from '@/models/CatalogProduct';
import { RateWindow } from '@/models/RateWindow';

const app = createApp();
let mongod: MongoMemoryServer;
const s3Objects = new Map<string, number>();

beforeAll(async () => {
  mongod = await MongoMemoryServer.create();
  await mongoose.connect(mongod.getUri());
  await Catalog.syncIndexes();
  await CatalogProduct.syncIndexes();
});

afterAll(async () => {
  await mongoose.disconnect();
  await mongod.stop();
});

beforeEach(() => {
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
    if (command instanceof ListObjectsV2Command) {
      const prefix = (command.input.Prefix as string) ?? '';
      return Promise.resolve({
        Contents: [...s3Objects.entries()]
          .filter(([key]) => key.startsWith(prefix))
          .map(([Key, Size]) => ({ Key, Size })),
        IsTruncated: false,
      }) as never;
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
    Project.deleteMany({}),
    ProjectModel.deleteMany({}),
    Catalog.deleteMany({}),
    CatalogProduct.deleteMany({}),
    RateWindow.deleteMany({}),
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

async function makeSucceededModel(userId: string, name = 'Chair capture'): Promise<string> {
  const project = await Project.create({
    userId: new Types.ObjectId(userId),
    name,
    objectSize: 'MEDIUM',
    mode: 'GUIDED',
  });
  const model = await ProjectModel.create({
    projectId: project._id,
    jobId: new Types.ObjectId(),
    source: 'meshy',
    status: 'SUCCEEDED',
    selectedKeys: ['a.jpg', 'b.jpg', 'c.jpg'],
    createdByUserId: new Types.ObjectId(),
    createdByRole: 'ADMIN',
    artifacts: {
      glbKey: 'dev/x/y/models/m/model.glb',
      cdnUrls: {
        glb: `https://cdn.example.com/${name}.glb`,
        usdz: `https://cdn.example.com/${name}.usdz`,
        preview: `https://cdn.example.com/${name}.jpg`,
      },
    },
  });
  return model.id as string;
}

async function createCatalogFor(auth: Auth, name = 'My Shop'): Promise<string> {
  const res = await request(app).post('/catalog').set(auth).send({ name });
  return res.body.catalog.id as string;
}

/** Presign a product-image slot and pretend the client's PUT succeeded. */
async function uploadedKey(auth: Auth, size = 1024): Promise<string> {
  const res = await request(app)
    .post('/catalog/products/image/upload-url')
    .set(auth)
    .send({ contentType: 'image/jpeg' })
    .expect(200);
  s3Objects.set(res.body.key, size);
  return res.body.key as string;
}

async function createImageOnly(auth: Auth, name: string, extra = {}) {
  return request(app)
    .post('/catalog/products')
    .set(auth)
    .send({ type: 'IMAGE_ONLY', name, imageKey: await uploadedKey(auth), ...extra })
    .expect(201);
}

describe('replace the backing model (feature 15)', () => {
  it('swaps every asset URL to the new model', async () => {
    const { auth, id: userId } = await makeUser();
    await createCatalogFor(auth);
    const first = await makeSucceededModel(userId, 'first');
    const second = await makeSucceededModel(userId, 'second');

    const created = await request(app)
      .post('/catalog/products')
      .set(auth)
      .send({ type: 'THREE_D', name: 'Chair', sourceModelId: first })
      .expect(201);
    expect(created.body.product.glbUrl).toContain('first.glb');

    const res = await request(app)
      .patch(`/catalog/products/${created.body.product.id}`)
      .set(auth)
      .send({ sourceModelId: second })
      .expect(200);

    expect(res.body.product.glbUrl).toContain('second.glb');
    expect(res.body.product.usdzUrl).toContain('second.usdz');
    expect(res.body.product.thumbnailUrl).toContain('second.jpg');
    expect(res.body.product.type).toBe('THREE_D');
    // The pointers move with the assets. A client editor opens the model
    // picker on these, so a stale sourceModelId would have it preselect the
    // model the product no longer uses.
    expect(res.body.product.sourceModelId).toBe(second);
    expect(created.body.product.sourceModelId).toBe(first);
    expect(res.body.product.sourceProjectId).toEqual(expect.any(String));
  });

  it('exposes both model pointers on a 3D product, and neither on an image-only one', async () => {
    const { auth, id: userId } = await makeUser();
    await createCatalogFor(auth);
    const modelId = await makeSucceededModel(userId);

    const threeD = await request(app)
      .post('/catalog/products')
      .set(auth)
      .send({ type: 'THREE_D', name: 'Chair', sourceModelId: modelId })
      .expect(201);

    expect(threeD.body.product.sourceModelId).toBe(modelId);
    expect(threeD.body.product.sourceProjectId).toEqual(expect.any(String));

    // An image-only product has no capture behind it, and null is the honest
    // answer — not an omitted field the client has to guess about.
    const imageOnly = await createImageOnly(auth, 'Mug');
    expect(imageOnly.body.product.sourceProjectId).toBeNull();
    expect(imageOnly.body.product.sourceModelId).toBeNull();
  });

  it("refuses another user's model, indistinguishably from a missing one", async () => {
    const a = await makeUser();
    const b = await makeUser();
    await createCatalogFor(a.auth);
    const mine = await makeSucceededModel(a.id);
    const theirs = await makeSucceededModel(b.id);

    const created = await request(app)
      .post('/catalog/products')
      .set(a.auth)
      .send({ type: 'THREE_D', name: 'Chair', sourceModelId: mine })
      .expect(201);

    const res = await request(app)
      .patch(`/catalog/products/${created.body.product.id}`)
      .set(a.auth)
      .send({ sourceModelId: theirs })
      .expect(404);
    expect(res.body.code).toBe('MODEL_NOT_FOUND');
  });
});

describe('convert a product type (feature 17)', () => {
  it('image-only → 3D keeps the id and takes the model preview as its image', async () => {
    // mirage-be re-derives imgOnly on update now, so a conversion is a plain
    // update and the product keeps its Mirage item id and its view counter.
    const { auth, id: userId } = await makeUser();
    await createCatalogFor(auth);
    const modelId = await makeSucceededModel(userId, 'converted');
    const created = await createImageOnly(auth, 'Mug');
    const productId = created.body.product.id as string;

    const res = await request(app)
      .patch(`/catalog/products/${productId}`)
      .set(auth)
      .send({ type: 'THREE_D', sourceModelId: modelId })
      .expect(200);

    expect(res.body.product.id).toBe(productId);
    expect(res.body.product.type).toBe('THREE_D');
    expect(res.body.product.glbUrl).toContain('converted.glb');
    // The model's generated preview becomes the card image; the uploaded one is
    // gone, so two sources cannot compete to be "the picture".
    expect(res.body.product.thumbnailUrl).toContain('converted.jpg');
  });

  it('3D → image-only drops the model refs', async () => {
    const { auth, id: userId } = await makeUser();
    await createCatalogFor(auth);
    const modelId = await makeSucceededModel(userId);
    const created = await request(app)
      .post('/catalog/products')
      .set(auth)
      .send({ type: 'THREE_D', name: 'Chair', sourceModelId: modelId })
      .expect(201);

    const key = await uploadedKey(auth);
    const res = await request(app)
      .patch(`/catalog/products/${created.body.product.id}`)
      .set(auth)
      .send({ type: 'IMAGE_ONLY', imageKey: key })
      .expect(200);

    expect(res.body.product.type).toBe('IMAGE_ONLY');
    // Otherwise the product would still render in a viewer it has no model for.
    expect(res.body.product.glbUrl).toBeNull();
    expect(res.body.product.usdzUrl).toBeNull();
    expect(res.body.product.thumbnailUrl).toBe(`https://test.cloudfront.net/${key}`);
    // The pointers go with them, or the picker would still claim a capture.
    expect(res.body.product.sourceProjectId).toBeNull();
    expect(res.body.product.sourceModelId).toBeNull();
  });

  it('refuses a conversion that does not carry its asset', async () => {
    // THE safety property that lets `type` be patchable: a one-word body cannot
    // leave a product typed for an asset it does not have.
    const { auth } = await makeUser();
    await createCatalogFor(auth);
    const created = await createImageOnly(auth, 'Mug');

    await request(app)
      .patch(`/catalog/products/${created.body.product.id}`)
      .set(auth)
      .send({ type: 'THREE_D' })
      .expect(400);

    const unchanged = await request(app)
      .get(`/catalog/products/${created.body.product.id}`)
      .set(auth)
      .expect(200);
    expect(unchanged.body.product.type).toBe('IMAGE_ONLY');
  });

  it('refuses a model and an image in the same request', async () => {
    const { auth, id: userId } = await makeUser();
    await createCatalogFor(auth);
    const modelId = await makeSucceededModel(userId);
    const created = await createImageOnly(auth, 'Mug');

    await request(app)
      .patch(`/catalog/products/${created.body.product.id}`)
      .set(auth)
      .send({ sourceModelId: modelId, imageKey: await uploadedKey(auth) })
      .expect(400);
  });

  it('leaves the publish planner able to see the conversion', async () => {
    // No extra marker field: publishedSnapshot already records the type that was
    // last pushed, so a conversion is simply another field that differs.
    const { auth, id: userId } = await makeUser();
    await createCatalogFor(auth);
    const modelId = await makeSucceededModel(userId);
    const created = await createImageOnly(auth, 'Mug');
    const productId = created.body.product.id as string;

    await CatalogProduct.updateOne(
      { _id: new Types.ObjectId(productId) },
      { $set: { publishedSnapshot: { type: 'IMAGE_ONLY', name: 'Mug' } } }
    ).exec();

    await request(app)
      .patch(`/catalog/products/${productId}`)
      .set(auth)
      .send({ type: 'THREE_D', sourceModelId: modelId })
      .expect(200);

    const row = await CatalogProduct.findById(productId).exec();
    expect(row?.type).toBe('THREE_D');
    expect((row?.publishedSnapshot as { type?: string } | undefined)?.type).toBe('IMAGE_ONLY');
  });
});

describe('duplicate a product (feature 18)', () => {
  it('copies the authoring fields and auto-renames', async () => {
    const { auth } = await makeUser();
    await createCatalogFor(auth);
    const created = await createImageOnly(auth, 'Latte', {
      price: 250,
      tags: ['hot'],
      featured: true,
    });

    const res = await request(app)
      .post(`/catalog/products/${created.body.product.id}/duplicate`)
      .set(auth)
      .send({})
      .expect(201);

    expect(res.body.product.id).not.toBe(created.body.product.id);
    // Mirage keys items by name within a restaurant, so a shared name would
    // collide at publish — long after the user pressed Duplicate.
    // The copy suffix is slugged too, so a duplicate cannot be the one name in
    // the catalog that Mirage rewrites on arrival.
    expect(res.body.product.name).toBe('latte_copy');
    expect(res.body.product.price).toBe(250);
    expect(res.body.product.tags).toEqual(['hot']);
    expect(res.body.product.featured).toBe(true);
    expect(res.body.product.thumbnailUrl).toBe(created.body.product.thumbnailUrl);
  });

  it('never copies the Mirage mapping or the sync state', async () => {
    // Two ReCapture products claiming one Mirage item would overwrite each other
    // on the next publish.
    const { auth } = await makeUser();
    await createCatalogFor(auth);
    const created = await createImageOnly(auth, 'Latte');
    await CatalogProduct.updateOne(
      { _id: new Types.ObjectId(created.body.product.id) },
      {
        $set: {
          mirageItemId: 'mirage-item-1',
          syncStatus: 'SYNCED',
          publishedSnapshot: { name: 'Latte' },
        },
      }
    ).exec();

    const res = await request(app)
      .post(`/catalog/products/${created.body.product.id}/duplicate`)
      .set(auth)
      .send({})
      .expect(201);

    const copy = await CatalogProduct.findById(res.body.product.id).exec();
    expect(copy?.mirageItemId).toBeUndefined();
    expect(copy?.syncStatus).toBe('NEVER');
    expect(copy?.publishedSnapshot).toBeUndefined();
    expect(res.body.product.syncStatus).toBe('NEVER');
  });

  it('walks the copy suffix rather than colliding', async () => {
    const { auth } = await makeUser();
    await createCatalogFor(auth);
    const created = await createImageOnly(auth, 'Latte');

    const first = await request(app)
      .post(`/catalog/products/${created.body.product.id}/duplicate`)
      .set(auth)
      .send({})
      .expect(201);
    const second = await request(app)
      .post(`/catalog/products/${created.body.product.id}/duplicate`)
      .set(auth)
      .send({})
      .expect(201);

    expect(first.body.product.name).toBe('latte_copy');
    expect(second.body.product.name).toBe('latte_copy_2');
  });

  it('accepts a caller-chosen name and rejects one already taken', async () => {
    const { auth } = await makeUser();
    await createCatalogFor(auth);
    const created = await createImageOnly(auth, 'Latte');
    await createImageOnly(auth, 'Taken');

    const ok = await request(app)
      .post(`/catalog/products/${created.body.product.id}/duplicate`)
      .set(auth)
      .send({ name: 'Latte Large' })
      .expect(201);
    expect(ok.body.product.name).toBe('latte_large');

    const clash = await request(app)
      .post(`/catalog/products/${created.body.product.id}/duplicate`)
      .set(auth)
      .send({ name: 'Taken' })
      .expect(409);
    expect(clash.body.code).toBe('DUPLICATE_NAME');
  });

  it("is an ordinary 404 for another business's product", async () => {
    const a = await makeUser();
    const b = await makeUser();
    await createCatalogFor(a.auth);
    await createCatalogFor(b.auth, 'B Shop');
    const created = await createImageOnly(a.auth, 'Latte');

    await request(app)
      .post(`/catalog/products/${created.body.product.id}/duplicate`)
      .set(b.auth)
      .send({})
      .expect(404);
  });
});

describe('catalog branding (feature 2)', () => {
  async function brandingKey(auth: Auth, slot: 'logo' | 'cover', size = 1024) {
    const res = await request(app)
      .post('/catalog/logo/upload-url')
      .set(auth)
      .send({ slot, contentType: 'image/png' })
      .expect(200);
    s3Objects.set(res.body.key, size);
    return res.body.key as string;
  }

  it('mints a slot under the reserved branding name', async () => {
    const { auth } = await makeUser();
    const catalogId = await createCatalogFor(auth);

    const res = await request(app)
      .post('/catalog/logo/upload-url')
      .set(auth)
      .send({ slot: 'logo', contentType: 'image/png' })
      .expect(200);

    expect(res.body.key).toMatch(
      new RegExp(`^dev/catalog/${catalogId}/products/logo/[^/]+\\.png$`)
    );
  });

  it('commits the logo and the cover independently', async () => {
    const { auth } = await makeUser();
    await createCatalogFor(auth);

    const logo = await brandingKey(auth, 'logo');
    const afterLogo = await request(app)
      .put('/catalog/logo')
      .set(auth)
      .send({ slot: 'logo', key: logo })
      .expect(200);
    expect(afterLogo.body.profile.logoUrl).toBe(`https://test.cloudfront.net/${logo}`);
    expect(afterLogo.body.profile.coverImageUrl).toBeNull();

    const cover = await brandingKey(auth, 'cover');
    const afterCover = await request(app)
      .put('/catalog/logo')
      .set(auth)
      .send({ slot: 'cover', key: cover })
      .expect(200);
    expect(afterCover.body.profile.logoUrl).toBe(`https://test.cloudfront.net/${logo}`);
    expect(afterCover.body.profile.coverImageUrl).toBe(`https://test.cloudfront.net/${cover}`);
  });

  it('bumps the draft revision — branding only reaches customers at publish', async () => {
    const { auth, id: userId } = await makeUser();
    await createCatalogFor(auth);
    await Catalog.updateOne(
      { userId: new Types.ObjectId(userId) },
      { $set: { publishedRevision: 5, draftRevision: 5 } }
    ).exec();

    const key = await brandingKey(auth, 'logo');
    await request(app)
      .put('/catalog/logo')
      .set(auth)
      .send({ slot: 'logo', key })
      .expect(200);

    const after = await request(app).get('/catalog').set(auth).expect(200);
    expect(after.body.catalog.hasUnpublishedChanges).toBe(true);
  });

  it("refuses another business's key", async () => {
    const a = await makeUser();
    const b = await makeUser();
    await createCatalogFor(a.auth);
    await createCatalogFor(b.auth, 'B Shop');
    const aKey = await brandingKey(a.auth, 'logo');

    const res = await request(app)
      .put('/catalog/logo')
      .set(b.auth)
      .send({ slot: 'logo', key: aKey })
      .expect(403);
    expect(res.body.code).toBe('FORBIDDEN');
  });

  it('refuses an oversize object', async () => {
    const { auth } = await makeUser();
    await createCatalogFor(auth);
    const key = await brandingKey(auth, 'logo', env.CATALOG_PRODUCT_IMAGE_MAX_BYTES + 1);

    await request(app)
      .put('/catalog/logo')
      .set(auth)
      .send({ slot: 'logo', key })
      .expect(413);
  });

  it('rejects an unknown slot', async () => {
    const { auth } = await makeUser();
    await createCatalogFor(auth);

    await request(app)
      .post('/catalog/logo/upload-url')
      .set(auth)
      .send({ slot: 'banner', contentType: 'image/png' })
      .expect(400);
  });
});
