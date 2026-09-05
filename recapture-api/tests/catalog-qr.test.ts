// tests/catalog-qr.test.ts
//
// GET /catalog/qr — features 31–35.
//
// THE DECODE ROUND TRIP IS THE TEST. Every other assertion here is about
// stability; this one is about correctness, and it is the only one that would
// catch the failure that actually matters — a code that renders, looks
// plausible, gets printed on two hundred stickers, and scans to the wrong
// string (or to nothing).
//
// The stability assertions exist because `publicUrl` is PRINTED. Once a sticker
// is on a table a change is not a bug that can be fixed forward, so the suite
// pins the code across a rename, a republish, product churn, and a change to
// MIRAGE_PUBLIC_BASE_URL itself.
import { describe, it, expect, beforeAll, afterAll, beforeEach, afterEach, vi } from 'vitest';
import request from 'supertest';
import mongoose, { Types } from 'mongoose';
import jwt from 'jsonwebtoken';
import { MongoMemoryServer } from 'mongodb-memory-server';
import { Jimp } from 'jimp';
import jsQR from 'jsqr';

import { createApp } from '@/app';
import { env } from '@/config/env';
import { Catalog } from '@/models/Catalog';
import { CatalogProduct } from '@/models/CatalogProduct';
import { CatalogPublishRun } from '@/models/CatalogPublishRun';
import { Job } from '@/models/Job';
import { User } from '@/models/User';
import { clampQrSize, QR_DEFAULT_SIZE, QR_MAX_SIZE, QR_MIN_SIZE } from '@/services/catalogQrService';
import { resetMirageClient, setMirageClient } from '@/services/mirage';
import { FakeMirage } from './fixtures/mirageFake';

const app = createApp();
let mongod: MongoMemoryServer;
const mirage = new FakeMirage();

beforeAll(async () => {
  mongod = await MongoMemoryServer.create();
  await mongoose.connect(mongod.getUri());
  await Catalog.syncIndexes();
});

afterAll(async () => {
  await mongoose.disconnect();
  await mongod.stop();
});

beforeEach(() => {
  mirage.reset();
  setMirageClient(mirage);
  Object.assign(env, {
    MIRAGE_BASE_URL: 'https://mirage.test',
    MIRAGE_API_KEY: 'test-api-key',
    MIRAGE_ADMIN_TOKEN: 'test-admin-token',
    MIRAGE_PUBLIC_BASE_URL: 'https://menu.test',
  });
  vi.spyOn(console, 'log').mockImplementation(() => {});
});

afterEach(async () => {
  vi.restoreAllMocks();
  resetMirageClient();
  await Promise.all([
    User.deleteMany({}),
    Catalog.deleteMany({}),
    CatalogProduct.deleteMany({}),
    CatalogPublishRun.deleteMany({}),
    Job.deleteMany({}),
    mongoose.connection.collection('ratewindows').deleteMany({}),
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

async function seed(
  userId: string,
  overrides: Record<string, unknown> = {}
): Promise<Types.ObjectId> {
  const catalog = await Catalog.create({
    userId: new Types.ObjectId(userId),
    name: 'Blue Cafe',
    status: 'DRAFT',
    draftRevision: 1,
    publishedRevision: -1,
    ...overrides,
  });
  const catalogId = catalog._id as Types.ObjectId;
  await CatalogProduct.create({
    catalogId,
    userId: new Types.ObjectId(userId),
    type: 'IMAGE_ONLY',
    name: 'Chair',
    position: 0,
    assets: { imageKey: 'dev/catalog/x/products/p/0.jpg' },
  });
  return catalogId;
}

/** Publishes once, so the catalog has a real minted URL. */
async function publish(auth: Auth): Promise<string> {
  await request(app).post('/catalog/publish').set(auth).send({});
  const catalog = await Catalog.findOne({}).lean().exec();
  return catalog?.publicUrl as string;
}

/** Decodes a PNG back to the string it encodes. */
async function decodeQr(png: Buffer): Promise<string | null> {
  const image = await Jimp.read(png);
  const { width, height, data } = image.bitmap;
  const result = jsQR(new Uint8ClampedArray(data), width, height);
  return result?.data ?? null;
}

// ── Correctness ─────────────────────────────────────────────────────────────

describe('GET /catalog/qr?format=png', () => {
  it('returns a PNG that decodes back to publicUrl EXACTLY', async () => {
    const { id, auth } = await makeUser();
    await seed(id);
    const publicUrl = await publish(auth);

    const res = await request(app).get('/catalog/qr?format=png').set(auth).buffer(true);

    expect(res.status).toBe(200);
    expect(res.headers['content-type']).toBe('image/png');
    expect(await decodeQr(res.body)).toBe(publicUrl);
  });

  it('still decodes at the smallest allowed size', async () => {
    const { id, auth } = await makeUser();
    await seed(id);
    const publicUrl = await publish(auth);

    const res = await request(app)
      .get(`/catalog/qr?format=png&size=${QR_MIN_SIZE}`)
      .set(auth)
      .buffer(true);

    expect(await decodeQr(res.body)).toBe(publicUrl);
  });

  it('encodes a long URL without losing error correction', async () => {
    const { id, auth } = await makeUser();
    const long = `https://menu.test/${'a'.repeat(180)}`;
    await seed(id, {
      status: 'PUBLISHED',
      mirageRestaurantId: 'a'.repeat(24),
      publicUrl: long,
      publicUrlScheme: 'MIRAGE_OBJECT_ID',
    });

    const res = await request(app).get('/catalog/qr?format=png').set(auth).buffer(true);

    expect(res.status).toBe(200);
    expect(await decodeQr(res.body)).toBe(long);
  });

  it('sets a download filename and a strong ETag, both readable cross-origin', async () => {
    const { id, auth } = await makeUser();
    await seed(id);
    await publish(auth);

    const res = await request(app)
      .get('/catalog/qr?format=png')
      .set(auth)
      .set('Origin', env.CORS_ALLOWED_ORIGINS[0] ?? 'http://localhost:3000')
      .buffer(true);

    expect(res.headers['content-disposition']).toBe('attachment; filename="blue-cafe-qr.png"');
    expect(res.headers.etag).toMatch(/^"/);
    // A browser cannot read either header unless it is exposed.
    const exposed = (res.headers['access-control-expose-headers'] ?? '').toLowerCase();
    expect(exposed).toContain('content-disposition');
    expect(exposed).toContain('etag');
  });

  it('answers 304 to a matching If-None-Match', async () => {
    const { id, auth } = await makeUser();
    await seed(id);
    await publish(auth);

    const first = await request(app).get('/catalog/qr?format=png').set(auth).buffer(true);
    const second = await request(app)
      .get('/catalog/qr?format=png')
      .set(auth)
      .set('If-None-Match', first.headers.etag);

    expect(second.status).toBe(304);
  });
});

// ── Determinism and stability ───────────────────────────────────────────────

describe('the code never changes', () => {
  it('two calls return byte-identical PNGs', async () => {
    const { id, auth } = await makeUser();
    await seed(id);
    await publish(auth);

    const a = await request(app).get('/catalog/qr?format=png').set(auth).buffer(true);
    const b = await request(app).get('/catalog/qr?format=png').set(auth).buffer(true);

    expect(Buffer.compare(a.body, b.body)).toBe(0);
  });

  it('survives a rename, a republish and product add/delete', async () => {
    const { id, auth } = await makeUser();
    const catalogId = await seed(id);
    const publicUrl = await publish(auth);
    const before = (await request(app).get('/catalog/qr?format=png').set(auth).buffer(true)).body;

    await request(app).patch('/catalog').set(auth).send({ name: 'Green Cafe' });
    await CatalogProduct.create({
      catalogId,
      userId: new Types.ObjectId(id),
      type: 'IMAGE_ONLY',
      name: 'Stool',
      position: 1,
      assets: { imageKey: 'dev/x.jpg' },
    });
    await CatalogProduct.deleteOne({ catalogId, name: 'Chair' }).exec();
    await Catalog.updateOne({ _id: catalogId }, { $set: { activePublishRunId: null } }).exec();
    await request(app).post('/catalog/publish').set(auth).send({});

    const after = await request(app).get('/catalog/qr?format=png').set(auth).buffer(true);

    // The IMAGE is identical, and so is what it decodes to. (The download
    // filename follows the new name — that is a header, not the code.)
    expect(Buffer.compare(before, after.body)).toBe(0);
    expect(await decodeQr(after.body)).toBe(publicUrl);
  });

  it('is immune to a later change of MIRAGE_PUBLIC_BASE_URL', async () => {
    const { id, auth } = await makeUser();
    await seed(id);
    const publicUrl = await publish(auth);
    const before = (await request(app).get('/catalog/qr?format=png').set(auth).buffer(true)).body;

    // The host moves. A catalog already carrying a printed sticker is
    // grandfathered onto the URL it was issued.
    Object.assign(env, { MIRAGE_PUBLIC_BASE_URL: 'https://elsewhere.test' });

    const after = await request(app).get('/catalog/qr?format=png').set(auth).buffer(true);

    expect(Buffer.compare(before, after.body)).toBe(0);
    expect(await decodeQr(after.body)).toBe(publicUrl);
    expect(publicUrl).toContain('https://menu.test/');
  });
});

// ── Sizes ───────────────────────────────────────────────────────────────────

describe('size handling', () => {
  it('clamps rather than errors', () => {
    expect(clampQrSize(10)).toBe(QR_MIN_SIZE);
    expect(clampQrSize(999_999)).toBe(QR_MAX_SIZE);
    expect(clampQrSize(undefined)).toBe(QR_DEFAULT_SIZE);
    expect(clampQrSize(800)).toBe(800);
  });

  it('accepts an out-of-range size on the wire without a 400', async () => {
    const { id, auth } = await makeUser();
    await seed(id);
    await publish(auth);

    const res = await request(app).get('/catalog/qr?size=99999').set(auth).buffer(true);

    expect(res.status).toBe(200);
  });

  it('rejects a size that is not a number', async () => {
    const { id, auth } = await makeUser();
    await seed(id);
    await publish(auth);

    const res = await request(app).get('/catalog/qr?size=huge').set(auth);

    expect(res.status).toBe(400);
    expect(res.body.code).toBe('INVALID_REQUEST');
  });
});

// ── PDF ─────────────────────────────────────────────────────────────────────

describe('GET /catalog/qr?format=pdf', () => {
  it('renders one page carrying the code, the name and the URL as text', async () => {
    const { id, auth } = await makeUser();
    await seed(id);
    const publicUrl = await publish(auth);

    const res = await request(app).get('/catalog/qr?format=pdf').set(auth).buffer(true);

    expect(res.status).toBe(200);
    expect(res.headers['content-type']).toBe('application/pdf');
    expect(res.headers['content-disposition']).toBe('attachment; filename="blue-cafe-qr.pdf"');

    const pdf = res.body.toString('latin1');
    expect(pdf.startsWith('%PDF-')).toBe(true);
    expect(pdf.endsWith('%%EOF')).toBe(true);
    expect(pdf).toContain('/Count 1');
    // A smudged code is unreadable; the link written out keeps the sheet usable.
    expect(pdf).toContain(publicUrl);
    expect(pdf).toContain('Blue Cafe');
    expect(pdf).toContain('/Subtype /Image');
  });

  it('is byte-identical across calls — no embedded creation date', async () => {
    const { id, auth } = await makeUser();
    await seed(id);
    await publish(auth);

    const a = await request(app).get('/catalog/qr?format=pdf').set(auth).buffer(true);
    const b = await request(app).get('/catalog/qr?format=pdf').set(auth).buffer(true);

    expect(Buffer.compare(a.body, b.body)).toBe(0);
  });

  it('declares xref offsets that point at the real objects', async () => {
    const { id, auth } = await makeUser();
    await seed(id);
    await publish(auth);

    const res = await request(app).get('/catalog/qr?format=pdf').set(auth).buffer(true);
    const pdf = res.body.toString('latin1');

    // The fiddly part of writing a PDF by hand: every offset in the xref table
    // must be the true byte position of `<n> 0 obj`. A reader that follows a
    // wrong one shows a blank page rather than an error.
    const startxref = Number(pdf.slice(pdf.lastIndexOf('startxref') + 9).trim().split('\n')[0]);
    expect(pdf.slice(startxref, startxref + 4)).toBe('xref');

    const offsets = [...pdf.matchAll(/^(\d{10}) 00000 n $/gm)].map((m) => Number(m[1]));
    expect(offsets).toHaveLength(6);
    offsets.forEach((offset, index) => {
      expect(pdf.slice(offset, offset + `${index + 1} 0 obj`.length)).toBe(`${index + 1} 0 obj`);
    });
  });
});

// ── Guards ──────────────────────────────────────────────────────────────────

describe('guards', () => {
  it('409s an unpublished catalog rather than inventing a URL', async () => {
    const { id, auth } = await makeUser();
    await seed(id);

    const res = await request(app).get('/catalog/qr').set(auth);

    expect(res.status).toBe(409);
    expect(res.body).toMatchObject({
      status: 'error',
      code: 'CATALOG_NOT_PUBLISHED',
    });
  });

  it('gives another user’s catalog the same 404 as a nonexistent one', async () => {
    const { auth } = await makeUser();
    const stranger = await makeUser();
    await seed(stranger.id);
    await publish(stranger.auth);

    const res = await request(app).get('/catalog/qr').set(auth);

    expect(res.status).toBe(404);
    expect(res.body.code).toBe('CATALOG_NOT_FOUND');
  });

  it('rejects an unauthenticated call', async () => {
    const res = await request(app).get('/catalog/qr');
    expect(res.status).toBe(401);
  });
});
