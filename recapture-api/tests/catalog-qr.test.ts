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
import { CatalogCategory } from '@/models/CatalogCategory';
import { CatalogPublishRun } from '@/models/CatalogPublishRun';
import { CatalogSubscription } from '@/models/CatalogSubscription';
import { Job } from '@/models/Job';
import { User } from '@/models/User';
import {
  clampQrSize,
  QR_DEFAULT_SIZE,
  QR_MAX_SIZE,
  QR_MIN_SIZE,
} from '@/services/catalogQrService';
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
    CatalogSubscription.deleteMany({}),
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
  // A category, because a catalog with products and none no longer publishes
  // (CATALOG_NO_CATEGORIES) — this suite is about what happens after the gates.
  const category = await CatalogCategory.create({
    catalogId,
    userId: new Types.ObjectId(userId),
    name: 'menu',
    position: 0,
  });
  await CatalogProduct.create({
    catalogId,
    userId: new Types.ObjectId(userId),
    type: 'IMAGE_ONLY',
    name: 'Chair',
    position: 0,
    categoryId: category._id,
    assets: { imageKey: 'dev/catalog/x/products/p/0.jpg' },
  });
  return catalogId;
}

/**
 * Publishes once, so the catalog has a real minted URL, and returns the link
 * the QR ENCODES: the one the catalog DTO shows — `customerUrl`, the Mirage
 * page by name — which is not the stored ObjectId form. The square and the
 * text under it must agree with what the screen shows, so the test reads the
 * same DTO the screen does.
 */
async function publish(auth: Auth): Promise<string> {
  await request(app).post('/catalog/publish').set(auth).send({});
  const res = await request(app).get('/catalog').set(auth);
  return res.body.catalog.publicUrl as string;
}

/** Decodes a PNG back to the string it encodes. */
async function decodeQr(png: Buffer): Promise<string | null> {
  const image = await Jimp.read(png);
  const { width, height, data } = image.bitmap;
  const result = jsQR(new Uint8ClampedArray(data), width, height);
  return result?.data ?? null;
}

/**
 * A plan's standee allowance on the caller's catalog. `issued` is the shared
 * pool — owner downloads and the admin's hand count draw from one number.
 */
async function grantStandees(
  userId: string,
  { included = 10, issued = 0, status = 'ACTIVE' }: { included?: number; issued?: number; status?: string } = {}
): Promise<void> {
  const catalog = await Catalog.findOne({ userId: new Types.ObjectId(userId) }).lean().exec();
  // `publish()` only queues the run; the processor is another suite's subject.
  // Live is what the standee door checks, so set it the way the run would.
  if (catalog!.publicUrl) {
    await Catalog.updateOne({ _id: catalog!._id }, { $set: { status: 'PUBLISHED' } }).exec();
  }
  const now = Date.now();
  await CatalogSubscription.create({
    catalogId: catalog!._id,
    userId: new Types.ObjectId(userId),
    status,
    planId: 'TASTE',
    source: 'ONLINE',
    periodStart: new Date(now),
    periodEnd: new Date(now + 30 * 86_400_000),
    threeDDishCap: 10,
    standeeAllocation: { included, issued },
  });
}

async function issuedOf(userId: string): Promise<number> {
  const catalog = await Catalog.findOne({ userId: new Types.ObjectId(userId) }).lean().exec();
  const row = await CatalogSubscription.findOne({ catalogId: catalog!._id }).lean().exec();
  return row?.standeeAllocation?.issued ?? -1;
}

/** The owner's print file: the counted standee download. */
function downloadStandees(auth: Auth, copies: number) {
  return request(app)
    .post('/catalog/standees/download')
    .set(auth)
    .send({ copies })
    .buffer(true)
    .parse((res, done) => {
      const chunks: Buffer[] = [];
      res.on('data', (c: Buffer) => chunks.push(c));
      res.on('end', () => done(null, Buffer.concat(chunks)));
    });
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
    // The link is the NAME, so the longest link is the longest name the
    // schema allows (CATALOG_NAME_SLUG_MAX).
    const { id, auth } = await makeUser();
    const name = 'a'.repeat(120);
    await seed(id, {
      name,
      status: 'PUBLISHED',
      mirageRestaurantId: 'b'.repeat(24),
      publicUrl: `https://menu.test/${'b'.repeat(24)}`,
      publicUrlScheme: 'MIRAGE_OBJECT_ID',
    });

    const res = await request(app).get('/catalog/qr?format=png').set(auth).buffer(true);

    expect(res.status).toBe(200);
    expect(await decodeQr(res.body)).toBe(`https://menu.test/${name}`);
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

  it('survives a republish and product add/delete', async () => {
    const { id, auth } = await makeUser();
    const catalogId = await seed(id);
    const publicUrl = await publish(auth);
    const before = (await request(app).get('/catalog/qr?format=png').set(auth).buffer(true)).body;

    await CatalogProduct.create({
      catalogId,
      userId: new Types.ObjectId(id),
      type: 'IMAGE_ONLY',
      name: 'Stool',
      position: 1,
      // Filed, or the republish below is refused as PRODUCT_UNCATEGORIZED.
      categoryId: (await CatalogCategory.findOne({ catalogId }).lean().exec())!._id,
      assets: { imageKey: 'dev/x.jpg' },
    });
    await CatalogProduct.deleteOne({ catalogId, name: 'Chair' }).exec();
    await Catalog.updateOne({ _id: catalogId }, { $set: { activePublishRunId: null } }).exec();
    await request(app).post('/catalog/publish').set(auth).send({});

    const after = await request(app).get('/catalog/qr?format=png').set(auth).buffer(true);

    // The IMAGE is identical, and so is what it decodes to.
    expect(Buffer.compare(before, after.body)).toBe(0);
    expect(await decodeQr(after.body)).toBe(publicUrl);
  });

  it('FOLLOWS a rename — the link is the name, and the stored URL does not move', async () => {
    // The one edit that changes the square, accepted knowingly when the link
    // became `{host}/{name}` (services/customerUrl.ts): the QR screens tell the
    // user to reprint after a rename. What must NOT move is the stored
    // `publicUrl` — the ObjectId form the resolver redirects printed standees
    // through — and the assertion below is what keeps a rename from ever
    // being taken as licence to rewrite it.
    const { id, auth } = await makeUser();
    const catalogId = await seed(id);
    const publicUrl = await publish(auth);
    const storedBefore = (await Catalog.findById(catalogId).lean().exec())?.publicUrl;
    const before = (await request(app).get('/catalog/qr?format=png').set(auth).buffer(true)).body;

    await request(app).patch('/catalog').set(auth).send({ name: 'Green Cafe' });

    const after = await request(app).get('/catalog/qr?format=png').set(auth).buffer(true);
    const stored = await Catalog.findById(catalogId).lean().exec();

    expect(Buffer.compare(before, after.body)).not.toBe(0);
    expect(await decodeQr(after.body)).toBe(`https://menu.test/${stored!.name}`);
    expect(await decodeQr(after.body)).not.toBe(publicUrl);
    expect(stored?.publicUrl).toBe(storedBefore);
  });

  it('FOLLOWS a later change of MIRAGE_PUBLIC_BASE_URL — the stored URL does not', async () => {
    // The second consequence of the name form: the displayed link is read
    // from the environment, so moving the public host moves every square
    // rendered after the move. The stored ObjectId URL stays as issued.
    const { id, auth } = await makeUser();
    const catalogId = await seed(id);
    const publicUrl = await publish(auth);
    const storedBefore = (await Catalog.findById(catalogId).lean().exec())?.publicUrl;
    const before = (await request(app).get('/catalog/qr?format=png').set(auth).buffer(true)).body;

    Object.assign(env, { MIRAGE_PUBLIC_BASE_URL: 'https://elsewhere.test' });

    const after = await request(app).get('/catalog/qr?format=png').set(auth).buffer(true);

    expect(Buffer.compare(before, after.body)).not.toBe(0);
    expect(await decodeQr(after.body)).toBe(
      publicUrl.replace('https://menu.test/', 'https://elsewhere.test/')
    );
    expect((await Catalog.findById(catalogId).lean().exec())?.publicUrl).toBe(storedBefore);
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

describe('the printable PDF (POST /catalog/standees/download)', () => {
  it('renders one page carrying the code, the name and the URL as text', async () => {
    const { id, auth } = await makeUser();
    await seed(id);
    const publicUrl = await publish(auth);
    await grantStandees(id);

    const res = await downloadStandees(auth, 1);

    expect(res.status).toBe(200);
    expect(res.headers['content-type']).toBe('application/pdf');
    expect(res.headers['content-disposition']).toBe(
      'attachment; filename="blue-cafe-standees-x1.pdf"'
    );

    const pdf = res.body.toString('latin1');
    expect(pdf.startsWith('%PDF-')).toBe(true);
    expect(pdf.endsWith('%%EOF')).toBe(true);
    expect(pdf).toContain('/Count 1');
    // A smudged code is unreadable; the link written out keeps the sheet usable.
    expect(pdf).toContain(publicUrl);
    expect(pdf).toContain('Blue Cafe');
    expect(pdf).toContain('/Subtype /Image');
  });

  it('carries the Mayasabha mark, the same square a standee prints', async () => {
    const { id, auth } = await makeUser();
    await seed(id);
    const publicUrl = await publish(auth);
    await grantStandees(id);

    const pdf = await downloadStandees(auth, 1);
    const png = await request(app).get('/catalog/qr?format=png').set(auth).buffer(true);

    // The PDF draws the mark as its own RGB XObject over the well, once, the
    // way the standee sheet does — the code itself stays the 1-bit image.
    const text = pdf.body.toString('latin1');
    expect(text.match(/\/Logo Do/g)).toHaveLength(1);
    expect(text).toContain('/ColorSpace /DeviceRGB /BitsPerComponent 8');
    expect(text).toContain('/BitsPerComponent 1');
    expect(text).not.toContain('/DCTDecode');

    // The PNG is no longer black and white: the artwork is in the middle, and
    // the code around it still reads — the well is paid for by level H.
    const image = await Jimp.read(png.body);
    const { width, height, data } = image.bitmap;
    let coloured = false;
    for (let y = Math.floor(height * 0.4); y < height * 0.6 && !coloured; y++) {
      for (let x = Math.floor(width * 0.4); x < width * 0.6; x++) {
        const at = (y * width + x) * 4;
        if (data[at] !== data[at + 1] || data[at + 1] !== data[at + 2]) {
          coloured = true;
          break;
        }
      }
    }
    expect(coloured).toBe(true);
    expect(await decodeQr(png.body)).toBe(publicUrl);
  });

  it('is byte-identical across calls — no embedded creation date', async () => {
    const { id, auth } = await makeUser();
    await seed(id);
    await publish(auth);
    await grantStandees(id);

    const a = await downloadStandees(auth, 1);
    const b = await downloadStandees(auth, 1);

    expect(Buffer.compare(a.body, b.body)).toBe(0);
  });

  it('declares xref offsets that point at the real objects', async () => {
    const { id, auth } = await makeUser();
    await seed(id);
    await publish(auth);
    await grantStandees(id);

    const res = await downloadStandees(auth, 1);
    const pdf = res.body.toString('latin1');

    // The fiddly part of writing a PDF by hand: every offset in the xref table
    // must be the true byte position of `<n> 0 obj`. A reader that follows a
    // wrong one shows a blank page rather than an error.
    const startxref = Number(
      pdf
        .slice(pdf.lastIndexOf('startxref') + 9)
        .trim()
        .split('\n')[0]
    );
    expect(pdf.slice(startxref, startxref + 4)).toBe('xref');

    const offsets = [...pdf.matchAll(/^(\d{10}) 00000 n $/gm)].map((m) => Number(m[1]));
    // EIGHT: catalog, pages, page, contents, the code, two base fonts
    // (Helvetica-Bold carries the standee code on that sheet), and — last, so
    // nothing before it moved — the Mayasabha mark as its own RGB image.
    expect(offsets).toHaveLength(8);
    offsets.forEach((offset, index) => {
      expect(pdf.slice(offset, offset + `${index + 1} 0 obj`.length)).toBe(`${index + 1} 0 obj`);
    });
  });
});

// ── Standee allowance ───────────────────────────────────────────────────────

describe('owner standee download spends the plan allowance', () => {
  it('refuses a free PDF from GET /catalog/qr — printing goes through the count', async () => {
    const { id, auth } = await makeUser();
    await seed(id);
    await publish(auth);
    await grantStandees(id);

    const res = await request(app).get('/catalog/qr?format=pdf').set(auth);

    expect(res.status).toBe(409);
    expect(res.body.code).toBe('STANDEE_DOWNLOAD_REQUIRED');
    expect(await issuedOf(id)).toBe(0);
  });

  it('prints N pages, spends N, and says what is left', async () => {
    const { id, auth } = await makeUser();
    await seed(id);
    await publish(auth);
    await grantStandees(id, { included: 10, issued: 2 });

    const res = await downloadStandees(auth, 3);

    expect(res.status).toBe(200);
    expect(res.body.toString('latin1')).toContain('/Count 3');
    expect(res.headers['x-standees-remaining']).toBe('5');
    expect(res.headers['x-standees-included']).toBe('10');
    expect(res.headers['cache-control']).toBe('no-store');
    expect(await issuedOf(id)).toBe(5);

    const quota = await request(app).get('/catalog/standees').set(auth);
    expect(quota.body).toMatchObject({
      status: 'success',
      included: 10,
      issued: 5,
      remaining: 5,
      canDownload: true,
      isLive: true,
    });
  });

  it('refuses more than is left and spends nothing', async () => {
    const { id, auth } = await makeUser();
    await seed(id);
    await publish(auth);
    await grantStandees(id, { included: 10, issued: 8 });

    const res = await request(app).post('/catalog/standees/download').set(auth).send({ copies: 3 });

    expect(res.status).toBe(409);
    expect(res.body).toMatchObject({ code: 'STANDEE_LIMIT_REACHED', remaining: 2 });
    expect(await issuedOf(id)).toBe(8);
  });

  it('two downloads racing for the last standees cannot both win', async () => {
    const { id, auth } = await makeUser();
    await seed(id);
    await publish(auth);
    await grantStandees(id, { included: 10, issued: 7 });

    const [a, b] = await Promise.all([
      request(app).post('/catalog/standees/download').set(auth).send({ copies: 2 }),
      request(app).post('/catalog/standees/download').set(auth).send({ copies: 2 }),
    ]);

    expect([a.status, b.status].sort()).toEqual([200, 409]);
    expect(await issuedOf(id)).toBe(9);
  });

  it('has nothing to print with no plan, or on a stopped plan', async () => {
    const { id, auth } = await makeUser();
    await seed(id);
    await publish(auth);
    await Catalog.updateOne({ userId: new Types.ObjectId(id) }, { $set: { status: 'PUBLISHED' } }).exec();

    const none = await request(app).post('/catalog/standees/download').set(auth).send({ copies: 1 });
    expect(none.status).toBe(409);
    expect(none.body).toMatchObject({ code: 'STANDEE_LIMIT_REACHED', remaining: 0 });

    await grantStandees(id, { status: 'CANCELLED' });
    const stopped = await request(app)
      .post('/catalog/standees/download')
      .set(auth)
      .send({ copies: 1 });
    expect(stopped.status).toBe(409);
    expect(await issuedOf(id)).toBe(0);

    const quota = await request(app).get('/catalog/standees').set(auth);
    expect(quota.body).toMatchObject({ remaining: 10, canDownload: false });
  });

  it('only while the catalog is live', async () => {
    const { id, auth } = await makeUser();
    await seed(id);
    await grantStandees(id);

    const res = await request(app).post('/catalog/standees/download').set(auth).send({ copies: 1 });

    expect(res.status).toBe(409);
    expect(res.body.code).toBe('CATALOG_NOT_LIVE');
    expect(await issuedOf(id)).toBe(0);
  });

  it('rejects a count outside 1..50', async () => {
    const { id, auth } = await makeUser();
    await seed(id);
    await publish(auth);
    await grantStandees(id);

    for (const copies of [0, 51, 1.5]) {
      const res = await request(app).post('/catalog/standees/download').set(auth).send({ copies });
      expect(res.status).toBe(400);
    }
    expect(await issuedOf(id)).toBe(0);
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
