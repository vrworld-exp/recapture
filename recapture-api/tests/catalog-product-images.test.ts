// tests/catalog-product-images.test.ts
//
// The product-image flow: presign → PUT to S3 → commit, and the image-only
// product create that depends on it (features 13, 16).
//
// The load-bearing property is CONTAINMENT. The client names the key at commit
// time, so everything that stops one business pointing a product at another
// business's object is: the strict parser, the catalogId comparison, and the
// env check. Those are asserted here through the routes as well as directly in
// tests/product-image-keys.test.ts.
//
// The other property worth pinning is the ORDER of the commit: the pointer flips
// before the sweep, so a crash between them leaves an orphaned object rather
// than a product pointing at nothing.
//
// Hermetic: ephemeral in-memory MongoDB, and the S3 seam is SCRIPTED via
// vi.spyOn(s3Client, 'send') — CI never calls AWS. Presigning is local SigV4 and
// needs no scripting; only Head/List/Delete do.
//
// ENV NOTE: vitest.config.ts injects env BEFORE the module graph loads, so every
// key prefix here is 'dev'.
import { describe, it, expect, beforeAll, afterAll, afterEach, vi } from 'vitest';
import request from 'supertest';
import mongoose, { Types } from 'mongoose';
import jwt from 'jsonwebtoken';
import { MongoMemoryServer } from 'mongodb-memory-server';
import {
  DeleteObjectCommand,
  HeadObjectCommand,
  ListObjectsV2Command,
  PutObjectCommand,
} from '@aws-sdk/client-s3';

import { createApp } from '@/app';
import { env } from '@/config/env';
import { s3Client } from '@/config/s3';
import { User } from '@/models/User';
import { Catalog } from '@/models/Catalog';
import { CatalogProduct } from '@/models/CatalogProduct';
import { RateWindow } from '@/models/RateWindow';
import { buildProductImageKey } from '@/utils/productImageKeys';

const app = createApp();
let mongod: MongoMemoryServer;

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

afterEach(async () => {
  vi.restoreAllMocks();
  await Promise.all([
    User.deleteMany({}),
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

async function createCatalogFor(auth: Auth, name = 'My Shop'): Promise<string> {
  const res = await request(app).post('/catalog').set(auth).send({ name });
  return res.body.catalog.id as string;
}

/**
 * A scripted S3 whose contents are a Map of key → size. HEAD answers from it,
 * LIST filters it by prefix, DELETE removes from it — so a test can assert on
 * the resulting bucket state rather than on call counts alone.
 */
function scriptS3(objects: Map<string, number>) {
  const deleted: string[] = [];
  vi.spyOn(s3Client, 'send').mockImplementation((command: unknown) => {
    if (command instanceof HeadObjectCommand) {
      const key = command.input.Key as string;
      if (!objects.has(key)) return Promise.reject(notFound());
      return Promise.resolve({
        ContentLength: objects.get(key),
        ContentType: 'image/jpeg',
      }) as never;
    }
    if (command instanceof ListObjectsV2Command) {
      const prefix = (command.input.Prefix as string) ?? '';
      return Promise.resolve({
        Contents: [...objects.entries()]
          .filter(([key]) => key.startsWith(prefix))
          .map(([Key, Size]) => ({ Key, Size })),
        IsTruncated: false,
      }) as never;
    }
    if (command instanceof PutObjectCommand) {
      const key = command.input.Key as string;
      const body = command.input.Body as Uint8Array;
      objects.set(key, body.length);
      return Promise.resolve({}) as never;
    }
    if (command instanceof DeleteObjectCommand) {
      const key = command.input.Key as string;
      deleted.push(key);
      objects.delete(key);
      return Promise.resolve({}) as never;
    }
    return Promise.reject(new Error(`unscripted S3 command: ${String(command)}`));
  });
  return { deleted, objects };
}

function notFound(): Error {
  const err = new Error('NotFound');
  err.name = 'NotFound';
  return err;
}

/** Presign a slot and pretend the client's PUT succeeded. */
async function uploadedSlot(
  auth: Auth,
  objects: Map<string, number>,
  body: Record<string, unknown> = { contentType: 'image/jpeg' },
  size = 1024
): Promise<string> {
  const res = await request(app)
    .post('/catalog/products/image/upload-url')
    .set(auth)
    .send(body)
    .expect(200);
  objects.set(res.body.key, size);
  return res.body.key as string;
}

describe('POST /catalog/products/image/bytes', () => {
  // The one-call upload the CLIENTS actually use. The presigned flow below
  // cannot work from the browser build — the PUT is cross-origin to a bucket
  // that serves no CORS policy — so this route is the only path that works on
  // web and native alike, and it has to land on the same key space with the
  // same containment as the presigned one.
  const jpeg = Buffer.from([0xff, 0xd8, 0xff, 0xe0, 0x00, 0x10, 0x4a, 0x46]);
  const png = Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 0x00]);
  const webp = Buffer.concat([
    Buffer.from('RIFF', 'ascii'),
    Buffer.from([0x00, 0x00, 0x00, 0x00]),
    Buffer.from('WEBP', 'ascii'),
    Buffer.from([0x00, 0x00, 0x00, 0x00]),
  ]);

  it('requires a token and a catalog', async () => {
    await request(app)
      .post('/catalog/products/image/bytes')
      .set('Content-Type', 'image/jpeg')
      .send(jpeg)
      .expect(401);

    const { auth } = await makeUser();
    await request(app)
      .post('/catalog/products/image/bytes')
      .set(auth)
      .set('Content-Type', 'image/jpeg')
      .send(jpeg)
      .expect(404);
  });

  it('stores the bytes and returns a key in the product key space', async () => {
    const { auth } = await makeUser();
    const catalogId = await createCatalogFor(auth);
    const objects = new Map<string, number>();
    scriptS3(objects);

    const res = await request(app)
      .post('/catalog/products/image/bytes')
      .set(auth)
      .set('Content-Type', 'image/jpeg')
      .send(jpeg)
      .expect(200);

    const key = res.body.key as string;
    expect(key.startsWith(`dev/catalog/${catalogId}/products/`)).toBe(true);
    expect(key.endsWith('.jpg')).toBe(true);
    // The bytes really landed — not just a key handed back.
    expect(objects.get(key)).toBe(jpeg.length);
  });

  it('derives the stored type from the BYTES, not the declared header', async () => {
    const { auth } = await makeUser();
    await createCatalogFor(auth);
    scriptS3(new Map());

    // A PNG body announced as JPEG. The extension follows the sniff, so the
    // stored object cannot lie about its content.
    const res = await request(app)
      .post('/catalog/products/image/bytes')
      .set(auth)
      .set('Content-Type', 'image/jpeg')
      .send(png)
      .expect(200);

    expect((res.body.key as string).endsWith('.png')).toBe(true);
  });

  it('accepts webp — a catalog grid loads dozens of these', async () => {
    const { auth } = await makeUser();
    await createCatalogFor(auth);
    scriptS3(new Map());

    const res = await request(app)
      .post('/catalog/products/image/bytes')
      .set(auth)
      .set('Content-Type', 'image/webp')
      .send(webp)
      .expect(200);

    expect((res.body.key as string).endsWith('.webp')).toBe(true);
  });

  it('refuses a body that is not an image we accept', async () => {
    const { auth } = await makeUser();
    await createCatalogFor(auth);
    scriptS3(new Map());

    // Parsed (the declared type is allowed) but the bytes are not an image.
    await request(app)
      .post('/catalog/products/image/bytes')
      .set(auth)
      .set('Content-Type', 'image/jpeg')
      .send(Buffer.from('this is not an image at all', 'ascii'))
      .expect(415);

    // Not parsed at all — the type never reaches the raw() filter.
    await request(app)
      .post('/catalog/products/image/bytes')
      .set(auth)
      .set('Content-Type', 'application/pdf')
      .send(jpeg)
      .expect(415);
  });

  it("404s on another business's product rather than saying it exists", async () => {
    const owner = await makeUser();
    await createCatalogFor(owner.auth);
    const stranger = await makeUser();
    await createCatalogFor(stranger.auth, 'Other Shop');
    scriptS3(new Map());

    const created = await request(app)
      .post('/catalog/products')
      .set(owner.auth)
      .send({ type: 'IMAGE_ONLY', name: 'Theirs', imageKey: await bytesKey(owner.auth, jpeg) })
      .expect(201);

    await request(app)
      .post('/catalog/products/image/bytes')
      .query({ productId: created.body.product.id })
      .set(stranger.auth)
      .set('Content-Type', 'image/jpeg')
      .send(jpeg)
      .expect(404);
  });

  it('produces a key the image-only create accepts', async () => {
    // The whole point of the route: upload, then create WITH the key, in the
    // order an image-only product requires.
    const { auth } = await makeUser();
    const objects = new Map<string, number>();
    scriptS3(objects);
    await createCatalogFor(auth);

    const key = await bytesKey(auth, jpeg);
    const res = await request(app)
      .post('/catalog/products')
      .set(auth)
      .send({ type: 'IMAGE_ONLY', name: 'Paneer Tikka', price: 249, imageKey: key })
      .expect(201);

    expect(res.body.product.type).toBe('IMAGE_ONLY');
    expect(res.body.product.name).toBe('Paneer Tikka');
  });

  /** Upload bytes through the route and return the key they landed on. */
  async function bytesKey(auth: Auth, body: Buffer): Promise<string> {
    const res = await request(app)
      .post('/catalog/products/image/bytes')
      .set(auth)
      .set('Content-Type', 'image/jpeg')
      .send(body)
      .expect(200);
    return res.body.key as string;
  }
});

describe('POST /catalog/products/image/upload-url', () => {
  it('requires a token and a catalog', async () => {
    await request(app)
      .post('/catalog/products/image/upload-url')
      .send({ contentType: 'image/jpeg' })
      .expect(401);

    const { auth } = await makeUser();
    const res = await request(app)
      .post('/catalog/products/image/upload-url')
      .set(auth)
      .send({ contentType: 'image/jpeg' })
      .expect(404);
    expect(res.body.code).toBe('CATALOG_NOT_FOUND');
  });

  it('mints a staging slot under the caller catalog when no product is named', async () => {
    // Feature 13: an image-only product is created WITH its committed key, so
    // the upload has to be able to come before the product exists.
    const { auth } = await makeUser();
    const catalogId = await createCatalogFor(auth);

    const res = await request(app)
      .post('/catalog/products/image/upload-url')
      .set(auth)
      .send({ contentType: 'image/webp' })
      .expect(200);

    expect(res.body.key).toMatch(
      new RegExp(`^dev/catalog/${catalogId}/products/[^/]+/[^/]+\\.webp$`)
    );
    expect(res.body.url).toContain('X-Amz-Signature');
    expect(Date.parse(res.body.expiresAt)).toBeGreaterThan(Date.now());
  });

  it('uses the product id as the slot when one is named', async () => {
    const { auth } = await makeUser();
    const catalogId = await createCatalogFor(auth);
    const objects = new Map<string, number>();
    scriptS3(objects);
    const staged = await uploadedSlot(auth, objects);
    const created = await request(app)
      .post('/catalog/products')
      .set(auth)
      .send({ type: 'IMAGE_ONLY', name: 'Mug', imageKey: staged })
      .expect(201);
    const productId = created.body.product.id as string;

    const res = await request(app)
      .post('/catalog/products/image/upload-url')
      .set(auth)
      .send({ contentType: 'image/png', productId })
      .expect(200);

    expect(res.body.key).toMatch(
      new RegExp(`^dev/catalog/${catalogId}/products/${productId}/[^/]+\\.png$`)
    );
  });

  it("will not mint a slot against another business's product", async () => {
    // A presigned URL is a write credential; minting one against a foreign
    // product would hand out write access to that product's prefix.
    const a = await makeUser();
    const b = await makeUser();
    await createCatalogFor(a.auth);
    await createCatalogFor(b.auth, 'B Shop');
    const objects = new Map<string, number>();
    scriptS3(objects);
    const staged = await uploadedSlot(a.auth, objects);
    const created = await request(app)
      .post('/catalog/products')
      .set(a.auth)
      .send({ type: 'IMAGE_ONLY', name: 'Mug', imageKey: staged })
      .expect(201);

    await request(app)
      .post('/catalog/products/image/upload-url')
      .set(b.auth)
      .send({ contentType: 'image/jpeg', productId: created.body.product.id })
      .expect(404);
  });

  it('rejects an unsupported content type and unknown fields', async () => {
    const { auth } = await makeUser();
    await createCatalogFor(auth);

    // The content type is baked into the signature, so the closed set here is
    // what fixes the set of things that can ever be stored.
    await request(app)
      .post('/catalog/products/image/upload-url')
      .set(auth)
      .send({ contentType: 'image/gif' })
      .expect(400);
    await request(app)
      .post('/catalog/products/image/upload-url')
      .set(auth)
      .send({ contentType: 'image/jpeg', catalogId: new Types.ObjectId().toHexString() })
      .expect(400);
  });
});

describe('image-only product create', () => {
  it('creates a product from a staged upload and derives its card image URL', async () => {
    const { auth } = await makeUser();
    await createCatalogFor(auth);
    const objects = new Map<string, number>();
    scriptS3(objects);
    const key = await uploadedSlot(auth, objects);

    const res = await request(app)
      .post('/catalog/products')
      .set(auth)
      .send({ type: 'IMAGE_ONLY', name: 'Ceramic Mug', price: 499, imageKey: key })
      .expect(201);

    expect(res.body.product.type).toBe('IMAGE_ONLY');
    // Derived from the stored key, not a second stored copy of the URL.
    expect(res.body.product.thumbnailUrl).toBe(`https://test.cloudfront.net/${key}`);
    expect(res.body.product.glbUrl).toBeNull();
    // The key itself is internal — the client gets a URL, never a bucket key.
    expect(res.body.product).not.toHaveProperty('imageKey');
  });

  it('refuses an image-only product with no image', async () => {
    // A card with nothing on it can never publish (the §7.7 gate rejects it), so
    // it is refused while the user is still looking at the form.
    const { auth } = await makeUser();
    await createCatalogFor(auth);

    const res = await request(app)
      .post('/catalog/products')
      .set(auth)
      .send({ type: 'IMAGE_ONLY', name: 'Mug' })
      .expect(400);
    expect(res.body.code).toBe('INVALID_REQUEST');
  });

  it('refuses an image on a 3D product', async () => {
    // A 3D product's card image is its model's generated preview; a second
    // source would leave two fields racing to be "the picture".
    const { auth } = await makeUser();
    await createCatalogFor(auth);

    await request(app)
      .post('/catalog/products')
      .set(auth)
      .send({
        type: 'THREE_D',
        name: 'Chair',
        sourceModelId: new Types.ObjectId().toHexString(),
        imageKey: 'dev/catalog/x/products/y/z.jpg',
      })
      .expect(400);
  });

  it("refuses a key from another business's catalog", async () => {
    // THE containment check. B holds a real, well-formed key — it just is not
    // theirs, and the catalogId segment is what proves it.
    const a = await makeUser();
    const b = await makeUser();
    await createCatalogFor(a.auth);
    await createCatalogFor(b.auth, 'B Shop');
    const objects = new Map<string, number>();
    scriptS3(objects);
    const aKey = await uploadedSlot(a.auth, objects);

    const res = await request(app)
      .post('/catalog/products')
      .set(b.auth)
      .send({ type: 'IMAGE_ONLY', name: 'Stolen', imageKey: aKey })
      .expect(403);
    expect(res.body.code).toBe('FORBIDDEN');
  });

  it('refuses a key whose object was never uploaded', async () => {
    const { auth } = await makeUser();
    const catalogId = await createCatalogFor(auth);
    scriptS3(new Map()); // empty bucket

    const key = buildProductImageKey(catalogId, 'slot-1', 'img-1', 'jpg');
    const res = await request(app)
      .post('/catalog/products')
      .set(auth)
      .send({ type: 'IMAGE_ONLY', name: 'Ghost', imageKey: key })
      .expect(409);
    expect(res.body.code).toBe('OBJECT_NOT_FOUND');
  });

  it('refuses and deletes an oversize object', async () => {
    // Presigning cannot enforce a size, so the cap is enforced here — and the
    // object is removed, because an over-cap object that is never committed
    // would otherwise sit in the bucket forever uncollected.
    const { auth } = await makeUser();
    await createCatalogFor(auth);
    const objects = new Map<string, number>();
    const { deleted } = scriptS3(objects);
    const key = await uploadedSlot(
      auth,
      objects,
      { contentType: 'image/jpeg' },
      env.CATALOG_PRODUCT_IMAGE_MAX_BYTES + 1
    );

    const res = await request(app)
      .post('/catalog/products')
      .set(auth)
      .send({ type: 'IMAGE_ONLY', name: 'Huge', imageKey: key })
      .expect(413);

    expect(res.body.code).toBe('PAYLOAD_TOO_LARGE');
    expect(deleted).toContain(key);
  });

  it('refuses a malformed key without touching S3', async () => {
    const { auth } = await makeUser();
    await createCatalogFor(auth);
    scriptS3(new Map());

    for (const key of [
      'dev/avatars/x/y.jpg',
      '../../etc/passwd',
      'dev/catalog/../products/s/i.jpg',
    ]) {
      const res = await request(app)
        .post('/catalog/products')
        .set(auth)
        .send({ type: 'IMAGE_ONLY', name: `P-${key.length}`, imageKey: key })
        .expect(422);
      expect(res.body.code).toBe('INVALID_KEY');
    }
  });

  it('refuses a key that claims a different environment', async () => {
    // A staging client must never commit a prod key.
    const { auth } = await makeUser();
    const catalogId = await createCatalogFor(auth);
    scriptS3(new Map());

    const res = await request(app)
      .post('/catalog/products')
      .set(auth)
      .send({
        type: 'IMAGE_ONLY',
        name: 'Wrong env',
        imageKey: `prod/catalog/${catalogId}/products/s/i.jpg`,
      })
      .expect(422);
    expect(res.body.code).toBe('INVALID_KEY');
  });
});

describe('PUT /catalog/products/:id/image', () => {
  /** An image-only product plus a live scripted bucket. */
  async function seedProduct(auth: Auth) {
    const objects = new Map<string, number>();
    const script = scriptS3(objects);
    const key = await uploadedSlot(auth, objects);
    const created = await request(app)
      .post('/catalog/products')
      .set(auth)
      .send({ type: 'IMAGE_ONLY', name: 'Mug', imageKey: key })
      .expect(201);
    return { productId: created.body.product.id as string, key, ...script };
  }

  it('replaces the image and sweeps what it superseded', async () => {
    const { auth } = await makeUser();
    await createCatalogFor(auth);
    const { productId, key: oldKey, objects, deleted } = await seedProduct(auth);

    const newKey = await uploadedSlot(auth, objects, {
      contentType: 'image/png',
      productId,
    });

    const res = await request(app)
      .put(`/catalog/products/${productId}/image`)
      .set(auth)
      .send({ key: newKey })
      .expect(200);

    expect(res.body.product.thumbnailUrl).toBe(`https://test.cloudfront.net/${newKey}`);
    // The old slot is swept too — otherwise the previous image would survive
    // forever under a prefix nothing points at any more.
    expect(deleted).toContain(oldKey);
    expect(objects.has(newKey)).toBe(true);
  });

  it('bumps the draft revision so the change shows as unpublished', async () => {
    const { auth, id: userId } = await makeUser();
    await createCatalogFor(auth);
    const { productId, objects } = await seedProduct(auth);
    await Catalog.updateOne(
      { userId: new Types.ObjectId(userId) },
      { $set: { publishedRevision: 999, draftRevision: 999 } }
    ).exec();

    const before = await request(app).get('/catalog').set(auth).expect(200);
    expect(before.body.catalog.hasUnpublishedChanges).toBe(false);

    const newKey = await uploadedSlot(auth, objects, { contentType: 'image/jpeg', productId });
    await request(app)
      .put(`/catalog/products/${productId}/image`)
      .set(auth)
      .send({ key: newKey })
      .expect(200);

    const after = await request(app).get('/catalog').set(auth).expect(200);
    expect(after.body.catalog.hasUnpublishedChanges).toBe(true);
  });

  it("refuses another business's key on an owned product", async () => {
    const a = await makeUser();
    const b = await makeUser();
    await createCatalogFor(a.auth);
    await createCatalogFor(b.auth, 'B Shop');

    const objects = new Map<string, number>();
    scriptS3(objects);
    const aKey = await uploadedSlot(a.auth, objects);
    const bKey = await uploadedSlot(b.auth, objects);

    const created = await request(app)
      .post('/catalog/products')
      .set(a.auth)
      .send({ type: 'IMAGE_ONLY', name: 'Mug', imageKey: aKey })
      .expect(201);

    const res = await request(app)
      .put(`/catalog/products/${created.body.product.id}/image`)
      .set(a.auth)
      .send({ key: bKey })
      .expect(403);
    expect(res.body.code).toBe('FORBIDDEN');
  });

  it("is an ordinary 404 for another business's product", async () => {
    // Not-owned and not-found stay indistinguishable at the boundary.
    const a = await makeUser();
    const b = await makeUser();
    await createCatalogFor(a.auth);
    await createCatalogFor(b.auth, 'B Shop');
    const objects = new Map<string, number>();
    scriptS3(objects);
    const aKey = await uploadedSlot(a.auth, objects);
    const created = await request(app)
      .post('/catalog/products')
      .set(a.auth)
      .send({ type: 'IMAGE_ONLY', name: 'Mug', imageKey: aKey })
      .expect(201);
    const bKey = await uploadedSlot(b.auth, objects);

    await request(app)
      .put(`/catalog/products/${created.body.product.id}/image`)
      .set(b.auth)
      .send({ key: bKey })
      .expect(404);
  });

  it('leaves the product untouched when the object is missing', async () => {
    // The pointer only flips once the object demonstrably exists.
    const { auth } = await makeUser();
    const catalogId = await createCatalogFor(auth);
    const { productId, key: oldKey } = await seedProduct(auth);

    await request(app)
      .put(`/catalog/products/${productId}/image`)
      .set(auth)
      .send({ key: buildProductImageKey(catalogId, productId, 'never-uploaded', 'jpg') })
      .expect(409);

    const after = await request(app).get(`/catalog/products/${productId}`).set(auth).expect(200);
    expect(after.body.product.thumbnailUrl).toBe(`https://test.cloudfront.net/${oldKey}`);
  });
});
