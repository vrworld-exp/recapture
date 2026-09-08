// tests/admin-qr-inventory.test.ts
//
// The admin standee surface: listing batches, paging their codes, and rendering
// one code as a printable standee.
//
// THE ASSERTION THAT CARRIES THIS SUITE is "the rendered standee and the vendor
// CSV encode the same URL". Those two strings reaching a print shop out of step
// is the single unrecoverable failure in this whole pipeline — it is discovered
// after the codes are on paper and on tables — and they only agree because both
// go through `resolverUrlFor`. A refactor that reintroduced a second composer
// would pass every other test in the repo and fail this one.
//
// Second most important: a RETIRED code is refused. Retirement means a standee
// was replaced, so reprinting one hands somebody a sheet that resolves to the
// fallback page.
import {
  describe,
  it,
  expect,
  beforeAll,
  afterAll,
  beforeEach,
  afterEach,
  vi,
} from 'vitest';
import request from 'supertest';
import mongoose, { Types } from 'mongoose';
import jwt from 'jsonwebtoken';
import { MongoMemoryServer } from 'mongodb-memory-server';
import { Jimp } from 'jimp';
import jsQR from 'jsqr';

import { createApp } from '@/app';
import { env } from '@/config/env';
import { User, type UserRole } from '@/models/User';
import { QrBatch } from '@/models/QrBatch';
import { QrCode } from '@/models/QrCode';
import { exportBatchCsv, mintBatch, resolverUrlFor } from '@/services/qrCodeService';

const app = createApp();
let mongod: MongoMemoryServer;

const RESOLVER_BASE = 'https://scan.test';

beforeAll(async () => {
  mongod = await MongoMemoryServer.create();
  await mongoose.connect(mongod.getUri());
  await QrCode.syncIndexes();
});

afterAll(async () => {
  await mongoose.disconnect();
  await mongod.stop();
});

beforeEach(() => {
  Object.assign(env, { PUBLIC_RESOLVER_BASE_URL: RESOLVER_BASE });
  vi.spyOn(console, 'log').mockImplementation(() => {});
});

afterEach(async () => {
  await User.deleteMany({});
  await QrCode.deleteMany({});
  await QrBatch.deleteMany({});
  vi.restoreAllMocks();
});

/** Decodes a PNG back to the string it encodes — the same helper catalog-qr uses. */
async function decodeQr(png: Buffer): Promise<string | null> {
  const image = await Jimp.read(png);
  const { width, height, data } = image.bitmap;
  const result = jsQR(new Uint8ClampedArray(data), width, height);
  return result?.data ?? null;
}

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

describe('GET /admin/qr-batches', () => {
  it('is ADMIN-only — a MODEL_ARTIST does not pass', async () => {
    const artist = await makeUser('MODEL_ARTIST');
    const res = await request(app).get('/admin/qr-batches').set(artist.auth);
    // The stricter gate is the point: MODEL_ARTIST clears the router-level check
    // and must still be stopped here.
    expect(res.status).toBe(403);
  });

  it('reports each batch with a live breakdown of what is left in it', async () => {
    const admin = await makeUser('ADMIN');
    const { batchId } = await mintBatch({
      count: 5,
      label: 'Vendor A — run 1',
      createdByUserId: new Types.ObjectId(admin.id),
    });

    // Two codes leave the box: one activated, one retired.
    const codes = await QrCode.find({ batchId }).sort({ code: 1 }).lean().exec();
    await QrCode.updateOne({ _id: codes[0]!._id }, { $set: { state: 'ACTIVE' } });
    await QrCode.updateOne({ _id: codes[1]!._id }, { $set: { state: 'RETIRED' } });

    const res = await request(app).get('/admin/qr-batches').set(admin.auth);

    expect(res.status).toBe(200);
    expect(res.body.batches).toHaveLength(1);
    const batch = res.body.batches[0];
    expect(batch.label).toBe('Vendor A — run 1');
    // `count` is what was REQUESTED; the three totals are what is there now.
    // Reported separately on purpose — see listBatches.
    expect(batch.count).toBe(5);
    expect(batch.unassigned).toBe(3);
    expect(batch.active).toBe(1);
    expect(batch.retired).toBe(1);
  });

  it('puts the newest mint first', async () => {
    const admin = await makeUser('ADMIN');
    const createdByUserId = new Types.ObjectId(admin.id);
    await mintBatch({ count: 1, label: 'older', createdByUserId });
    await mintBatch({ count: 1, label: 'newer', createdByUserId });

    const res = await request(app).get('/admin/qr-batches').set(admin.auth);

    expect(res.body.batches.map((b: { label: string }) => b.label)).toEqual([
      'newer',
      'older',
    ]);
  });
});

describe('GET /admin/qr-batches/:batchId/codes', () => {
  it('pages by keyset without repeating or dropping a row', async () => {
    const admin = await makeUser('ADMIN');
    const { batchId } = await mintBatch({
      count: 25,
      label: 'paging',
      createdByUserId: new Types.ObjectId(admin.id),
    });

    const seen: string[] = [];
    let after: string | undefined;
    // Deliberately more rounds than pages, so the final "no cursor" answer is
    // exercised rather than assumed.
    for (let round = 0; round < 5; round++) {
      const res: { status: number; body: { codes: { code: string }[]; nextAfter: string | null } } =
        await request(app)
          .get(`/admin/qr-batches/${batchId.toHexString()}/codes`)
          .query({ limit: 10, ...(after ? { after } : {}) })
          .set(admin.auth);

      expect(res.status).toBe(200);
      seen.push(...res.body.codes.map((c) => c.code));
      if (!res.body.nextAfter) break;
      after = res.body.nextAfter;
    }

    expect(seen).toHaveLength(25);
    expect(new Set(seen).size).toBe(25);
    // Sorted by code, the same order the CSV emits — a row on screen and a line
    // in the print file are the same row.
    expect([...seen].sort()).toEqual(seen);
  });

  it('carries the URL the standee encodes, matching the vendor CSV exactly', async () => {
    const admin = await makeUser('ADMIN');
    const { batchId } = await mintBatch({
      count: 3,
      label: 'csv parity',
      createdByUserId: new Types.ObjectId(admin.id),
    });

    const res = await request(app)
      .get(`/admin/qr-batches/${batchId.toHexString()}/codes`)
      .set(admin.auth);
    const csv = await exportBatchCsv(batchId);

    // Row for row, the screen and the print file agree. This is the invariant
    // `resolverUrlFor` exists to make structural rather than remembered.
    const fromApi = res.body.codes.map(
      (c: { code: string; url: string }) => `${c.code},${c.url}`
    );
    expect(fromApi).toEqual(csv!.split('\n'));
  });

  it('404s for a batch that does not exist', async () => {
    const admin = await makeUser('ADMIN');
    const res = await request(app)
      .get(`/admin/qr-batches/${new Types.ObjectId().toHexString()}/codes`)
      .set(admin.auth);

    expect(res.status).toBe(404);
    expect(res.body.code).toBe('NOT_FOUND');
  });

  it('refuses to emit URLs when the resolver origin is unset', async () => {
    const admin = await makeUser('ADMIN');
    const { batchId } = await mintBatch({
      count: 1,
      label: 'unconfigured',
      createdByUserId: new Types.ObjectId(admin.id),
    });

    Object.assign(env, { PUBLIC_RESOLVER_BASE_URL: undefined });
    const res = await request(app)
      .get(`/admin/qr-batches/${batchId.toHexString()}/codes`)
      .set(admin.auth);

    // Same refusal as the CSV, and for the same reason: these URLs get printed.
    expect(res.status).toBe(409);
    expect(res.body.code).toBe('RESOLVER_NOT_CONFIGURED');
  });
});

describe('GET /admin/qr-codes/:code/qr', () => {
  async function oneCode(adminId: string): Promise<string> {
    const { batchId } = await mintBatch({
      count: 1,
      label: 'render',
      createdByUserId: new Types.ObjectId(adminId),
    });
    const code = await QrCode.findOne({ batchId }).lean().exec();
    return code!.code;
  }

  it('renders a PNG for an unassigned code', async () => {
    const admin = await makeUser('ADMIN');
    const code = await oneCode(admin.id);

    const res = await request(app)
      .get(`/admin/qr-codes/${code}/qr`)
      .query({ format: 'png' })
      .set(admin.auth);

    expect(res.status).toBe(200);
    expect(res.headers['content-type']).toContain('image/png');
    // The filename carries the code, so an admin with several of these in a
    // downloads folder can tell them apart without opening them.
    expect(res.headers['content-disposition']).toContain(code.toLowerCase());
  });

  it('accepts the printed form a human would type', async () => {
    const admin = await makeUser('ADMIN');
    const code = await oneCode(admin.id);
    const printed = `${code.slice(0, 4)}-${code.slice(4)}`.toLowerCase();

    const res = await request(app)
      .get(`/admin/qr-codes/${printed}/qr`)
      .set(admin.auth);

    expect(res.status).toBe(200);
  });

  it('ENCODES the same url the vendor CSV carries', async () => {
    const admin = await makeUser('ADMIN');
    const code = await oneCode(admin.id);

    const res = await request(app)
      .get(`/admin/qr-codes/${code}/qr`)
      .query({ format: 'png' })
      .set(admin.auth)
      .buffer(true);

    expect(res.status).toBe(200);
    // DECODED, not string-matched. This used to grep the PDF bytes for the URL,
    // which worked only because the sheet printed it as text — and the standee
    // caption is now the code and the tagline instead, so that check would pass
    // vacuously on a sheet with no QR on it at all. Decoding asserts the
    // stronger thing regardless: what a phone camera actually reads is
    // byte-identical to the CSV line the print vendor receives.
    expect(await decodeQr(res.body)).toBe(resolverUrlFor(code));
  });

  it('refuses a retired code rather than handing back a sheet that resolves to nothing', async () => {
    const admin = await makeUser('ADMIN');
    const code = await oneCode(admin.id);
    await QrCode.updateOne({ code }, { $set: { state: 'RETIRED' } });

    const res = await request(app).get(`/admin/qr-codes/${code}/qr`).set(admin.auth);

    expect(res.status).toBe(409);
    expect(res.body.code).toBe('CODE_RETIRED');
  });

  it('still renders an ACTIVE code — a damaged standee keeps its code', async () => {
    const admin = await makeUser('ADMIN');
    const code = await oneCode(admin.id);
    await QrCode.updateOne({ code }, { $set: { state: 'ACTIVE' } });

    const res = await request(app).get(`/admin/qr-codes/${code}/qr`).set(admin.auth);

    // Reprinting a live restaurant's standee is legitimate and is the whole
    // reason the mapping lives on the QrCode row rather than in publicUrl.
    expect(res.status).toBe(200);
  });

  it('404s for a code that is not ours', async () => {
    const admin = await makeUser('ADMIN');
    const res = await request(app).get('/admin/qr-codes/ZZZZ9999/qr').set(admin.auth);

    expect(res.status).toBe(404);
    expect(res.body.code).toBe('NOT_FOUND');
  });

  it('is ADMIN-only', async () => {
    const artist = await makeUser('MODEL_ARTIST');
    const admin = await makeUser('ADMIN');
    const code = await oneCode(admin.id);

    const res = await request(app).get(`/admin/qr-codes/${code}/qr`).set(artist.auth);

    expect(res.status).toBe(403);
  });
});

describe('what the printed standee sheet actually says', () => {
  async function sheet(adminAuth: { Authorization: string }, code: string) {
    const res = await request(app)
      .get(`/admin/qr-codes/${code}/qr`)
      .query({ format: 'pdf' })
      .set(adminAuth)
      .responseType('blob');
    expect(res.status).toBe(200);
    return res.body.toString('latin1');
  }

  it('prints the code and the tagline under the square', async () => {
    const admin = await makeUser('ADMIN');
    const { batchId } = await mintBatch({
      count: 1,
      label: 'caption',
      createdByUserId: new Types.ObjectId(admin.id),
    });
    const code = (await QrCode.findOne({ batchId }).lean().exec())!.code;

    const pdf = await sheet(admin.auth, code);

    // The eight characters a rep reads off the sheet and types.
    expect(pdf).toContain(`(${code}) Tj`);
    expect(pdf).toContain('(Created for mirage menu) Tj');
  });

  it('is PURE BLACK AND WHITE — one bit, losslessly compressed', async () => {
    const admin = await makeUser('ADMIN');
    const { batchId } = await mintBatch({
      count: 1,
      label: 'monochrome',
      createdByUserId: new Types.ObjectId(admin.id),
    });
    const code = (await QrCode.findOne({ batchId }).lean().exec())!.code;

    const pdf = await sheet(admin.auth, code);

    // THE REGRESSION THIS GUARDS. The sheet used to embed the QR as a JPEG,
    // which is a frequency-domain codec applied to an image made entirely of
    // hard black/white edges: every module picked up a grey ring and the print
    // looked washed out. One bit per pixel cannot represent a value between
    // black and white, so the fuzz is not merely reduced, it is unrepresentable.
    expect(pdf).toContain('/BitsPerComponent 1');
    expect(pdf).toContain('/Filter /FlateDecode');
    expect(pdf).not.toContain('/DCTDecode');
    // A hint only — but a reader that honours it will not smooth the modules.
    expect(pdf).toContain('/Interpolate false');
  });

  it('keeps the square square', async () => {
    const admin = await makeUser('ADMIN');
    const { batchId } = await mintBatch({
      count: 1,
      label: 'square',
      createdByUserId: new Types.ObjectId(admin.id),
    });
    const code = (await QrCode.findOne({ batchId }).lean().exec())!.code;

    const pdf = await sheet(admin.auth, code);

    const dims = pdf.match(/\/Width (\d+) \/Height (\d+)/);
    expect(dims).not.toBeNull();
    // Equal in the image dictionary...
    expect(dims![1]).toBe(dims![2]);
    // ...and equal again in the placement matrix, so a non-uniform scale cannot
    // stretch it on the page.
    expect(pdf).toContain('360 0 0 360 ');
  });

  it('renders the same bytes twice — a code is a fixed object', async () => {
    const admin = await makeUser('ADMIN');
    const { batchId } = await mintBatch({
      count: 1,
      label: 'stable',
      createdByUserId: new Types.ObjectId(admin.id),
    });
    const code = (await QrCode.findOne({ batchId }).lean().exec())!.code;

    const a = await sheet(admin.auth, code);
    const b = await sheet(admin.auth, code);

    // Deflate is deterministic at a fixed level, and there is no /Info dict and
    // therefore no CreationDate. Two prints of one standee are one object.
    expect(a).toBe(b);
  });
});

describe('bulk assignment at mint time', () => {
  it('hands the whole run to one rep in a single call', async () => {
    const admin = await makeUser('ADMIN');
    const rep = await makeUser('SALES_REP');

    const res = await request(app)
      .post('/admin/qr-batches')
      .set(admin.auth)
      .send({ count: 12, label: 'Ravi — Oct run', assignToUserId: rep.id });

    expect(res.status).toBe(201);
    expect(res.body.minted).toBe(12);
    expect(res.body.assignedTo.id).toBe(rep.id);

    // EVERY code, not most of them. The point of the feature is that the admin
    // does not go back and catch stragglers by hand.
    const held = await QrCode.countDocuments({
      batchId: new Types.ObjectId(res.body.batchId as string),
      assignedToUserId: new Types.ObjectId(rep.id),
    }).exec();
    expect(held).toBe(12);
  });

  it('records who did the assigning, and when', async () => {
    const admin = await makeUser('ADMIN');
    const rep = await makeUser('SALES_REP');

    const res = await request(app)
      .post('/admin/qr-batches')
      .set(admin.auth)
      .send({ count: 2, label: 'audit', assignToUserId: rep.id });

    const code = await QrCode.findOne({
      batchId: new Types.ObjectId(res.body.batchId as string),
    })
      .lean()
      .exec();
    expect(String(code!.assignedByUserId)).toBe(admin.id);
    expect(code!.assignedAt).toBeInstanceOf(Date);
  });

  it('still mints unassigned stock when nobody is named', async () => {
    const admin = await makeUser('ADMIN');

    const res = await request(app)
      .post('/admin/qr-batches')
      .set(admin.auth)
      .send({ count: 3, label: 'unassigned' });

    expect(res.status).toBe(201);
    expect(res.body.assignedTo).toBeNull();
    // An admin who has not decided who is carrying a batch must still be able
    // to get codes to a printer.
    const held = await QrCode.countDocuments({
      batchId: new Types.ObjectId(res.body.batchId as string),
      assignedToUserId: { $exists: true },
    }).exec();
    expect(held).toBe(0);
  });

  it('MINTS NOTHING when the named staff member does not exist', async () => {
    const admin = await makeUser('ADMIN');
    const before = await QrBatch.countDocuments({}).exec();

    const res = await request(app)
      .post('/admin/qr-batches')
      .set(admin.auth)
      .send({
        count: 50,
        label: 'stale picker',
        assignToUserId: new Types.ObjectId().toHexString(),
      });

    expect(res.status).toBe(404);
    expect(res.body.code).toBe('REP_NOT_FOUND');
    // THE ORDERING GUARANTEE, and the reason mint and assign live in one
    // endpoint. Discovering a stale picker selection AFTER minting would leave
    // an admin looking at an error over a batch that does exist — and the
    // obvious reaction, pressing Mint again, commits a second print run.
    expect(await QrBatch.countDocuments({}).exec()).toBe(before);
    expect(await QrCode.countDocuments({}).exec()).toBe(0);
  });

  it('refuses a plain USER as the holder, and mints nothing', async () => {
    const admin = await makeUser('ADMIN');
    const nobody = await makeUser('USER');

    const res = await request(app)
      .post('/admin/qr-batches')
      .set(admin.auth)
      .send({ count: 5, label: 'wrong role', assignToUserId: nobody.id });

    // /rep is closed to a plain USER, so this would be a folder of standees on
    // a screen they can never open.
    expect(res.status).toBe(404);
    expect(res.body.code).toBe('REP_NOT_FOUND');
    expect(await QrCode.countDocuments({}).exec()).toBe(0);
  });

  it('accepts a MODEL_ARTIST or an ADMIN, who can both use /rep', async () => {
    const admin = await makeUser('ADMIN');
    const artist = await makeUser('MODEL_ARTIST');

    const res = await request(app)
      .post('/admin/qr-batches')
      .set(admin.auth)
      .send({ count: 1, label: 'inclusive', assignToUserId: artist.id });

    // requireRole is inclusive upward, so the picker must not be an
    // exact-equality role check — an admin who also does field visits has to be
    // able to hold their own stock.
    expect(res.status).toBe(201);
    expect(res.body.assignedTo.id).toBe(artist.id);
  });

  it('rejects a malformed id without touching the database', async () => {
    const admin = await makeUser('ADMIN');

    const res = await request(app)
      .post('/admin/qr-batches')
      .set(admin.auth)
      .send({ count: 5, label: 'bad id', assignToUserId: 'not-an-id' });

    expect(res.status).toBe(400);
    expect(res.body.code).toBe('INVALID_REQUEST');
    expect(await QrCode.countDocuments({}).exec()).toBe(0);
  });

  it('puts the whole run on the rep own standee list', async () => {
    const admin = await makeUser('ADMIN');
    const rep = await makeUser('SALES_REP');

    await request(app)
      .post('/admin/qr-batches')
      .set(admin.auth)
      .send({ count: 4, label: 'visible', assignToUserId: rep.id });

    const mine = await request(app).get('/rep/standees').set(rep.auth);

    // The end of the chain: bulk assignment is only worth anything if the rep
    // can see the folder they were handed.
    expect(mine.status).toBe(200);
    expect(mine.body.standees).toHaveLength(4);
  });

  it('stays ADVISORY — a bulk-assigned code still activates for another rep', async () => {
    const admin = await makeUser('ADMIN');
    const holder = await makeUser('SALES_REP');
    const other = await makeUser('SALES_REP');

    const minted = await request(app)
      .post('/admin/qr-batches')
      .set(admin.auth)
      .send({ count: 1, label: 'advisory', assignToUserId: holder.id });
    const code = (await QrCode.findOne({
      batchId: new Types.ObjectId(minted.body.batchId as string),
    })
      .lean()
      .exec())!.code;

    const res = await request(app)
      .post('/rep/activations')
      .set(other.auth)
      .send({ code, restaurantName: 'Walk Up Cafe', restaurantPhone: '+919000000111' });

    // DELIBERATE, not an oversight. Assignment makes "who is carrying this"
    // VISIBLE; it does not lock activation. Bulk assignment must not smuggle in
    // the enforcement that was considered and declined for the single-code path
    // — see standeeAssignmentService's header.
    expect(res.status).toBe(201);
  });
});

describe('assigning a whole batch after the fact', () => {
  async function batchOf(adminId: string, count: number): Promise<Types.ObjectId> {
    const { batchId } = await mintBatch({
      count,
      label: 'later',
      createdByUserId: new Types.ObjectId(adminId),
    });
    return batchId;
  }

  it('hands every usable code to the named rep', async () => {
    const admin = await makeUser('ADMIN');
    const rep = await makeUser('SALES_REP');
    const batchId = await batchOf(admin.id, 6);

    const res = await request(app)
      .post(`/admin/qr-batches/${batchId.toHexString()}/assignment`)
      .set(admin.auth)
      .send({ repUserId: rep.id });

    expect(res.status).toBe(200);
    expect(res.body.assigned).toBe(6);
    expect(res.body.assignedTo.id).toBe(rep.id);
    expect(
      await QrCode.countDocuments({
        batchId,
        assignedToUserId: new Types.ObjectId(rep.id),
      }).exec()
    ).toBe(6);
  });

  it('moves a batch between reps — the later holder wins', async () => {
    const admin = await makeUser('ADMIN');
    const first = await makeUser('SALES_REP');
    const second = await makeUser('SALES_REP');
    const batchId = await batchOf(admin.id, 3);
    const url = `/admin/qr-batches/${batchId.toHexString()}/assignment`;

    await request(app).post(url).set(admin.auth).send({ repUserId: first.id });
    await request(app).post(url).set(admin.auth).send({ repUserId: second.id });

    // A rep left, a territory changed: the batch moved, and the truth is
    // whoever holds it now. There is no ledger to close, because nothing
    // downstream reads the history of who carried a standee.
    expect(
      await QrCode.countDocuments({
        batchId,
        assignedToUserId: new Types.ObjectId(first.id),
      }).exec()
    ).toBe(0);
    expect(
      await QrCode.countDocuments({
        batchId,
        assignedToUserId: new Types.ObjectId(second.id),
      }).exec()
    ).toBe(3);
  });

  it('SKIPS retired codes and says how many it skipped', async () => {
    const admin = await makeUser('ADMIN');
    const rep = await makeUser('SALES_REP');
    const batchId = await batchOf(admin.id, 5);
    const dead = await QrCode.find({ batchId }).limit(2).lean().exec();
    await QrCode.updateMany(
      { _id: { $in: dead.map((d) => d._id) } },
      { $set: { state: 'RETIRED' } }
    );

    const res = await request(app)
      .post(`/admin/qr-batches/${batchId.toHexString()}/assignment`)
      .set(admin.auth)
      .send({ repUserId: rep.id });

    // A retired sheet cannot be printed or activated, so assigning one gives a
    // rep a row they can do nothing with. Reported rather than hidden:
    // "assigned 3" against a batch of 5 looks like a bug unless the screen can
    // say why the other two were left alone.
    expect(res.body.assigned).toBe(3);
    expect(res.body.skippedRetired).toBe(2);
  });

  it('writes nothing when the rep does not exist', async () => {
    const admin = await makeUser('ADMIN');
    const batchId = await batchOf(admin.id, 4);

    const res = await request(app)
      .post(`/admin/qr-batches/${batchId.toHexString()}/assignment`)
      .set(admin.auth)
      .send({ repUserId: new Types.ObjectId().toHexString() });

    expect(res.status).toBe(404);
    expect(res.body.code).toBe('REP_NOT_FOUND');
    // A PARTIAL assignment is worse than none: an admin who saw an error would
    // not know how much of the batch had already moved.
    expect(
      await QrCode.countDocuments({ batchId, assignedToUserId: { $exists: true } }).exec()
    ).toBe(0);
  });

  it('404s an unknown batch', async () => {
    const admin = await makeUser('ADMIN');
    const rep = await makeUser('SALES_REP');

    const res = await request(app)
      .post(`/admin/qr-batches/${new Types.ObjectId().toHexString()}/assignment`)
      .set(admin.auth)
      .send({ repUserId: rep.id });

    expect(res.status).toBe(404);
    expect(res.body.code).toBe('NOT_FOUND');
  });

  it('is ADMIN-only', async () => {
    const admin = await makeUser('ADMIN');
    const artist = await makeUser('MODEL_ARTIST');
    const rep = await makeUser('SALES_REP');
    const batchId = await batchOf(admin.id, 1);

    const res = await request(app)
      .post(`/admin/qr-batches/${batchId.toHexString()}/assignment`)
      .set(artist.auth)
      .send({ repUserId: rep.id });

    expect(res.status).toBe(403);
  });
});

describe('emptying a batch back into stock', () => {
  it('clears every holder in the batch', async () => {
    const admin = await makeUser('ADMIN');
    const rep = await makeUser('SALES_REP');
    const { batchId } = await mintBatch({
      count: 4,
      label: 'return',
      createdByUserId: new Types.ObjectId(admin.id),
    });
    const url = `/admin/qr-batches/${batchId.toHexString()}/assignment`;
    await request(app).post(url).set(admin.auth).send({ repUserId: rep.id });

    const res = await request(app).delete(url).set(admin.auth);

    expect(res.status).toBe(200);
    expect(res.body.unassigned).toBe(4);
    expect(
      await QrCode.countDocuments({ batchId, assignedToUserId: { $exists: true } }).exec()
    ).toBe(0);
  });

  it('clears a RETIRED code too', async () => {
    const admin = await makeUser('ADMIN');
    const rep = await makeUser('SALES_REP');
    const { batchId } = await mintBatch({
      count: 2,
      label: 'tidy',
      createdByUserId: new Types.ObjectId(admin.id),
    });
    const url = `/admin/qr-batches/${batchId.toHexString()}/assignment`;
    await request(app).post(url).set(admin.auth).send({ repUserId: rep.id });
    await QrCode.updateMany({ batchId }, { $set: { state: 'RETIRED' } });

    await request(app).delete(url).set(admin.auth);

    // The asymmetry with assign is deliberate. Clearing a stale holder off a
    // sheet nobody can use is exactly the tidy-up somebody emptying a batch is
    // doing; leaving it behind would make the batch read half-assigned forever.
    expect(
      await QrCode.countDocuments({ batchId, assignedToUserId: { $exists: true } }).exec()
    ).toBe(0);
  });

  it('succeeds on a batch nobody holds', async () => {
    const admin = await makeUser('ADMIN');
    const { batchId } = await mintBatch({
      count: 3,
      label: 'already empty',
      createdByUserId: new Types.ObjectId(admin.id),
    });

    const res = await request(app)
      .delete(`/admin/qr-batches/${batchId.toHexString()}/assignment`)
      .set(admin.auth);

    // Idempotent: the intent is that none of these are on anybody list, and
    // that is already true. A 409 would only ever be shown to someone who
    // already has what they asked for.
    expect(res.status).toBe(200);
    expect(res.body.unassigned).toBe(0);
  });

  it('404s an unknown batch', async () => {
    const admin = await makeUser('ADMIN');

    const res = await request(app)
      .delete(`/admin/qr-batches/${new Types.ObjectId().toHexString()}/assignment`)
      .set(admin.auth);

    expect(res.status).toBe(404);
  });
});
