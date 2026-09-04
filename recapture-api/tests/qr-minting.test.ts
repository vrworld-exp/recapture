// tests/qr-minting.test.ts
//
// Stage 2: pre-printed standee inventory — the code alphabet, the mint, and the
// print vendor's CSV.
//
// TWO ASSERTIONS HERE CARRY THE SUITE. The first is the collision retry: at 8
// characters over a 32-symbol alphabet a real collision is vanishingly
// unlikely, so that path would otherwise never run until the day the inventory
// is large and a short print run is already in a box. The second is that the
// export REFUSES to emit URLs when PUBLIC_RESOLVER_BASE_URL is unset — a CSV of
// `undefined/r/ABCD2345` gets printed onto thousands of physical standees
// before anyone notices.
import { describe, it, expect, beforeAll, afterAll, beforeEach, afterEach, vi } from 'vitest';
import request from 'supertest';
import mongoose, { Types } from 'mongoose';
import jwt from 'jsonwebtoken';
import { MongoMemoryServer } from 'mongodb-memory-server';

import { createApp } from '@/app';
import { env } from '@/config/env';
import { User, type UserRole } from '@/models/User';
import { QrBatch } from '@/models/QrBatch';
import { QrCode } from '@/models/QrCode';
import {
  exportBatchCsv,
  mintBatch,
  findByCode,
  slugifyBatchLabel,
  QrResolverNotConfiguredError,
} from '@/services/qrCodeService';
import { generateQrCode, normalizeQrCode, QR_CODE_LENGTH } from '@/utils/qrCodes';

// The service draws codes through this module, so the collision test needs to
// steer it. Everything else delegates to the real implementation — the alphabet
// assertions below are about the REAL generator, not a stub of it.
vi.mock('@/utils/qrCodes', async (importOriginal) => {
  const actual = await importOriginal<typeof import('@/utils/qrCodes')>();
  return { ...actual, generateQrCode: vi.fn(actual.generateQrCode) };
});

const app = createApp();
let mongod: MongoMemoryServer;
let realGenerate: () => string;

const RESOLVER_BASE = 'https://scan.test';

beforeAll(async () => {
  mongod = await MongoMemoryServer.create();
  await mongoose.connect(mongod.getUri());
  // The unique index on `code` is the thing under test in one case below and
  // the thing the retry path depends on in another, so it must actually exist.
  await QrCode.syncIndexes();
  const actual = await vi.importActual<typeof import('@/utils/qrCodes')>('@/utils/qrCodes');
  realGenerate = actual.generateQrCode;
});

afterAll(async () => {
  await mongoose.disconnect();
  await mongod.stop();
});

beforeEach(() => {
  vi.mocked(generateQrCode).mockReset();
  vi.mocked(generateQrCode).mockImplementation(() => realGenerate());
  Object.assign(env, { PUBLIC_RESOLVER_BASE_URL: RESOLVER_BASE });
  vi.spyOn(console, 'log').mockImplementation(() => {});
});

afterEach(async () => {
  await User.deleteMany({});
  await QrCode.deleteMany({});
  await QrBatch.deleteMany({});
});

/** Creates a real user doc (requireRole reads the DB) + its Bearer header. */
async function makeUser(
  role: UserRole | undefined
): Promise<{ id: string; auth: { Authorization: string } }> {
  const user = await User.create({
    authProvider: 'custom',
    authUid: `test|${new Types.ObjectId().toHexString()}`,
    ...(role ? { role } : {}),
  });
  const id = user.id as string;
  const token = jwt.sign({ userId: id, authUid: user.authUid }, env.JWT_SECRET, {
    expiresIn: '15m',
  });
  return { id, auth: { Authorization: `Bearer ${token}` } };
}

describe('the code alphabet', () => {
  it('draws 8 characters from the reduced alphabet, never I/L/O/U', () => {
    const allowed = /^[0-9ABCDEFGHJKMNPQRSTVWXYZ]{8}$/;
    for (let i = 0; i < 3000; i++) {
      const code = realGenerate();
      expect(code).toHaveLength(QR_CODE_LENGTH);
      // One assertion covering both rules: the class excludes I, L, O and U, so
      // a regression that reintroduced any of them fails here by name.
      expect(code).toMatch(allowed);
    }
  });

  it('does not repeat itself over a large draw (the codes are random, not a counter)', () => {
    const seen = new Set<string>();
    for (let i = 0; i < 3000; i++) seen.add(realGenerate());
    // A counter or a seeded-but-stuck RNG would collapse this to a handful.
    expect(seen.size).toBe(3000);
  });
});

describe('normalisation', () => {
  it('accepts the printed forms a human might type', () => {
    expect(normalizeQrCode('abcd-2345')).toBe('ABCD2345');
    expect(normalizeQrCode('ABCD 2345')).toBe('ABCD2345');
    expect(normalizeQrCode('abcd2345')).toBe('ABCD2345');
  });

  it('rejects wrong lengths and excluded glyphs', () => {
    expect(normalizeQrCode('ABCD234')).toBeNull();
    expect(normalizeQrCode('ABCD23456')).toBeNull();
    // `I` is not in the alphabet — and is deliberately NOT mapped to `1`, which
    // would make two different printed codes normalise to the same stored one.
    expect(normalizeQrCode('ABCDI234')).toBeNull();
    expect(normalizeQrCode('')).toBeNull();
  });
});

describe('the unique index', () => {
  it('is enforced by the database, not by application code', async () => {
    const batchId = new Types.ObjectId();
    await QrCode.create({ code: 'ABCD2345', batchId, state: 'UNASSIGNED', deletedAt: null });

    // Straight to the collection: no service, no read-then-write check. If this
    // resolves, two physical standees can carry the same code.
    await expect(
      QrCode.create({ code: 'ABCD2345', batchId, state: 'UNASSIGNED', deletedAt: null })
    ).rejects.toMatchObject({ code: 11000 });
  });

  it('insertMany({ordered:false}) lands the non-colliding codes anyway', async () => {
    const batchId = new Types.ObjectId();
    await QrCode.create({ code: 'AAAA1111', batchId, state: 'UNASSIGNED', deletedAt: null });

    // An ORDERED insert would stop at the duplicate and silently drop BBBB2222
    // and CCCC3333 — the short-CSV failure this option exists to prevent.
    await QrCode.insertMany(
      ['BBBB2222', 'AAAA1111', 'CCCC3333'].map((code) => ({
        code,
        batchId,
        state: 'UNASSIGNED' as const,
        deletedAt: null,
      })),
      { ordered: false }
    ).catch(() => undefined);

    const codes = (await QrCode.find({ batchId }).lean()).map((c) => c.code).sort();
    expect(codes).toEqual(['AAAA1111', 'BBBB2222', 'CCCC3333']);
  });
});

describe('minting', () => {
  it('mints the requested count as UNASSIGNED codes', async () => {
    const { id } = await makeUser('ADMIN');
    const { batchId, minted } = await mintBatch({
      count: 50,
      label: 'smoke',
      createdByUserId: new Types.ObjectId(id),
    });

    expect(minted).toBe(50);
    expect(await QrCode.countDocuments({ batchId })).toBe(50);
    expect(await QrCode.countDocuments({ batchId, state: 'UNASSIGNED' })).toBe(50);
    // Inventory only: nothing points anywhere yet.
    expect(await QrCode.countDocuments({ batchId, catalogId: { $ne: null } })).toBe(0);
  });

  it('retries ONLY the collided slots and still delivers the full count', async () => {
    // THE TEST THAT MATTERS. A code already in the collection, and a generator
    // rigged to draw it first, forces the duplicate-key path to run for real.
    const taken = 'ZZZZ9999';
    await QrCode.create({
      code: taken,
      batchId: new Types.ObjectId(),
      state: 'UNASSIGNED',
      deletedAt: null,
    });

    vi.mocked(generateQrCode)
      .mockImplementationOnce(() => taken)
      .mockImplementationOnce(() => taken)
      .mockImplementation(() => realGenerate());

    const { id } = await makeUser('ADMIN');
    const { batchId, minted } = await mintBatch({
      count: 5,
      label: 'collision',
      createdByUserId: new Types.ObjectId(id),
    });

    expect(minted).toBe(5);

    const codes = (await QrCode.find({ batchId }).lean()).map((c) => c.code);
    expect(codes).toHaveLength(5);
    expect(new Set(codes).size).toBe(5);
    // The pre-existing code belongs to the OTHER batch and was not stolen into
    // this one — the retry redrew around it rather than repointing it.
    expect(codes).not.toContain(taken);
  });

  it('leaves no partial batch behind when it cannot reach the count', async () => {
    // A generator stuck on one value can never fill a batch of 3. The batch must
    // not survive half-filled: a batch whose `count` disagrees with its row
    // count IS the short-print-run hazard.
    vi.mocked(generateQrCode).mockImplementation(() => 'STUCK123');

    const { id } = await makeUser('ADMIN');
    await expect(
      mintBatch({ count: 3, label: 'stuck', createdByUserId: new Types.ObjectId(id) })
    ).rejects.toThrow(/Minted only/);

    expect(await QrCode.countDocuments({})).toBe(0);
    expect(await QrBatch.countDocuments({})).toBe(0);
  });
});

describe('the export CSV', () => {
  it('refuses to emit URLs when PUBLIC_RESOLVER_BASE_URL is unset', async () => {
    const { id } = await makeUser('ADMIN');
    const { batchId } = await mintBatch({
      count: 3,
      label: 'no-config',
      createdByUserId: new Types.ObjectId(id),
    });

    Object.assign(env, { PUBLIC_RESOLVER_BASE_URL: undefined });

    await expect(exportBatchCsv(batchId)).rejects.toBeInstanceOf(QrResolverNotConfiguredError);
  });

  it('emits one code,url row per standee against the configured origin', async () => {
    const { id } = await makeUser('ADMIN');
    const { batchId } = await mintBatch({
      count: 12,
      label: 'vendor a',
      createdByUserId: new Types.ObjectId(id),
    });

    const csv = await exportBatchCsv(batchId);
    const rows = csv!.split('\n');

    // No header: the line count IS the batch count, so a short run is visible.
    expect(rows).toHaveLength(12);
    for (const row of rows) {
      const [code, url] = row.split(',');
      expect(code).toMatch(/^[0-9ABCDEFGHJKMNPQRSTVWXYZ]{8}$/);
      expect(url).toBe(`${RESOLVER_BASE}/r/${code}`);
    }
  });

  it('is byte-identical across re-exports (a vendor diffing two downloads sees nothing)', async () => {
    const { id } = await makeUser('ADMIN');
    const { batchId } = await mintBatch({
      count: 20,
      label: 'stable',
      createdByUserId: new Types.ObjectId(id),
    });

    expect(await exportBatchCsv(batchId)).toBe(await exportBatchCsv(batchId));
  });

  it('returns null for a batch that does not exist', async () => {
    expect(await exportBatchCsv(new Types.ObjectId())).toBeNull();
  });

  it('slugifies a label into a safe filename stem', () => {
    expect(slugifyBatchLabel('Vendor A — Oct 2026, run 3')).toBe('vendor-a-oct-2026-run-3');
    expect(slugifyBatchLabel('///')).toBe('batch');
  });
});

describe('findByCode', () => {
  it('normalises before querying, and misses cost no query at all', async () => {
    const { id } = await makeUser('ADMIN');
    const { batchId } = await mintBatch({
      count: 1,
      label: 'lookup',
      createdByUserId: new Types.ObjectId(id),
    });
    const stored = (await QrCode.findOne({ batchId }).lean())!.code;

    const hyphenated = `${stored.slice(0, 4)}-${stored.slice(4)}`.toLowerCase();
    expect((await findByCode(hyphenated))?.code).toBe(stored);

    const spy = vi.spyOn(QrCode, 'findOne');
    expect(await findByCode('not-a-code')).toBeNull();
    expect(spy).not.toHaveBeenCalled();
    spy.mockRestore();
  });
});

describe('POST /admin/qr-batches — role gate and bounds', () => {
  it('ADMIN mints; MODEL_ARTIST and USER are both 403', async () => {
    const admin = await makeUser('ADMIN');
    const artist = await makeUser('MODEL_ARTIST');
    const plain = await makeUser('USER');

    const ok = await request(app)
      .post('/admin/qr-batches')
      .set(admin.auth)
      .send({ count: 50, label: 'smoke' });
    expect(ok.status).toBe(201);
    expect(ok.body.status).toBe('success');
    expect(ok.body.minted).toBe(50);

    // ADMIN-only despite the router-level MODEL_ARTIST mount: a mint commits the
    // business to a physical print run.
    for (const actor of [artist, plain]) {
      const res = await request(app)
        .post('/admin/qr-batches')
        .set(actor.auth)
        .send({ count: 5, label: 'nope' });
      expect(res.status).toBe(403);
      expect(res.body.code).toBe('FORBIDDEN');
    }
  });

  it('rejects a count over QR_BATCH_MAX_SIZE before touching the database', async () => {
    const admin = await makeUser('ADMIN');

    const res = await request(app)
      .post('/admin/qr-batches')
      .set(admin.auth)
      .send({ count: env.QR_BATCH_MAX_SIZE + 1, label: 'too big' });

    expect(res.status).toBe(400);
    expect(res.body.code).toBe('INVALID_REQUEST');
    // Validation, not a half-finished mint that was rolled back.
    expect(await QrCode.countDocuments({})).toBe(0);
    expect(await QrBatch.countDocuments({})).toBe(0);
  });

  it('rejects a body carrying anything else (strict)', async () => {
    const admin = await makeUser('ADMIN');
    const res = await request(app)
      .post('/admin/qr-batches')
      .set(admin.auth)
      .send({ count: 5, label: 'x', catalogId: new Types.ObjectId().toHexString() });
    expect(res.status).toBe(400);
  });
});

describe('GET /admin/qr-batches/:batchId/export — role gate and headers', () => {
  it('ADMIN downloads a named CSV of the whole batch', async () => {
    const admin = await makeUser('ADMIN');
    const minted = await request(app)
      .post('/admin/qr-batches')
      .set(admin.auth)
      .send({ count: 50, label: 'Vendor A — Oct 2026, run 3' });

    const res = await request(app)
      .get(`/admin/qr-batches/${minted.body.batchId}/export`)
      .set(admin.auth);

    expect(res.status).toBe(200);
    expect(res.headers['content-type']).toContain('text/csv');
    expect(res.headers['content-disposition']).toBe(
      'attachment; filename="qr-batch-vendor-a-oct-2026-run-3.csv"'
    );
    expect(res.text.split('\n')).toHaveLength(50);
  });

  it('MODEL_ARTIST and USER are both 403', async () => {
    const admin = await makeUser('ADMIN');
    const minted = await request(app)
      .post('/admin/qr-batches')
      .set(admin.auth)
      .send({ count: 2, label: 'gated' });

    for (const role of ['MODEL_ARTIST', 'USER'] as const) {
      const actor = await makeUser(role);
      const res = await request(app)
        .get(`/admin/qr-batches/${minted.body.batchId}/export`)
        .set(actor.auth);
      expect(res.status).toBe(403);
    }
  });

  it('409s rather than emitting URLs against a guessed host', async () => {
    const admin = await makeUser('ADMIN');
    const minted = await request(app)
      .post('/admin/qr-batches')
      .set(admin.auth)
      .send({ count: 2, label: 'unconfigured' });

    Object.assign(env, { PUBLIC_RESOLVER_BASE_URL: undefined });

    const res = await request(app)
      .get(`/admin/qr-batches/${minted.body.batchId}/export`)
      .set(admin.auth);

    expect(res.status).toBe(409);
    expect(res.body.code).toBe('RESOLVER_NOT_CONFIGURED');
    expect(res.text).not.toContain('undefined/r/');
  });

  it('404s for a batch that does not exist, 400s for a malformed id', async () => {
    const admin = await makeUser('ADMIN');

    const missing = await request(app)
      .get(`/admin/qr-batches/${new Types.ObjectId().toHexString()}/export`)
      .set(admin.auth);
    expect(missing.status).toBe(404);

    const malformed = await request(app).get('/admin/qr-batches/not-an-id/export').set(admin.auth);
    expect(malformed.status).toBe(400);
  });
});
