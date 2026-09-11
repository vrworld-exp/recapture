// tests/admin-batch-sheet.test.ts
//
// GET /admin/qr-batches/:batchId/sheet — a whole run of standees on A4, several
// to a page, ready for a printer.
//
// THE ASSERTION THAT CARRIES THIS SUITE is "a square cut off this sheet scans to
// the same URL the vendor CSV carries". It is checked by INFLATING the embedded
// image out of the PDF and decoding it, not by grepping the bytes for a string:
// a URL can appear in a content stream while the image beside it encodes
// something else, and the difference is only discovered by a diner pointing a
// phone at a printed standee. That is the failure this whole pipeline exists to
// make impossible, and it is unrecoverable — the paper is already on tables.
//
// Second: THE SQUARE IS A FIXED PHYSICAL SIZE. 1.67in, whatever else changes.
// Every layout knob may trade rows and columns away; none of them may shrink the
// code, because a QR smaller than the distance it is scanned from does not work.
// `does not scale the square to fit more on a page` is that rule as a test.
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
import zlib from 'zlib';
import { MongoMemoryServer } from 'mongodb-memory-server';
import jsQR from 'jsqr';

import { createApp } from '@/app';
import { env } from '@/config/env';
import { User, type UserRole } from '@/models/User';
import { QrBatch } from '@/models/QrBatch';
import { QrCode } from '@/models/QrCode';
import { exportBatchCsv, mintBatch } from '@/services/qrCodeService';
import { STANDEE_TAGLINE } from '@/services/standeeSheetService';

const app = createApp();
let mongod: MongoMemoryServer;

const RESOLVER_BASE = 'https://scan.test';

/** The defaults every test starts from, restored in afterEach. */
const SHEET_DEFAULTS = {
  STANDEE_SHEET_QR_INCHES: 1.67,
  STANDEE_SHEET_QR_DPI: 300,
  STANDEE_SHEET_COLUMNS: 3,
  STANDEE_SHEET_ROWS: 3,
  STANDEE_SHEET_MAX_CODES: 500,
} as const;

/** 1.67in × 72pt/in, as the `cm` matrix writes it. */
const QR_SIDE_PT = '120.24';
/** Nine to a page at the shipped 3 × 3 — the most A4 holds at 1.67in. */
const PER_PAGE = 9;

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
  Object.assign(env, { PUBLIC_RESOLVER_BASE_URL: RESOLVER_BASE }, SHEET_DEFAULTS);
  vi.spyOn(console, 'log').mockImplementation(() => {});
});

afterEach(async () => {
  Object.assign(env, SHEET_DEFAULTS);
  await User.deleteMany({});
  await QrCode.deleteMany({});
  await QrBatch.deleteMany({});
  vi.restoreAllMocks();
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

async function seedBatch(adminId: string, count: number, label = 'Vendor A — run 1') {
  return mintBatch({ count, label, createdByUserId: new Types.ObjectId(adminId) });
}

function fetchSheet(auth: { Authorization: string }, batchId: string) {
  return request(app)
    .get(`/admin/qr-batches/${batchId}/sheet`)
    .set(auth)
    .responseType('blob');
}

/**
 * The error envelope out of a blob-mode response.
 *
 * `responseType('blob')` applies to FAILURES too, so a 409 arrives as a Buffer
 * of JSON rather than a parsed body — the same trap the Flutter repository
 * documents on its own bytes-mode GET, and the reason a refusal that carries an
 * actionable code would otherwise read as a generic one on both sides.
 */
function envelope(res: { body: Buffer }): { code: string; message: string } {
  return JSON.parse(res.body.toString('utf8'));
}

// ── Reading the PDF back ────────────────────────────────────────────────────

/**
 * Every embedded QR image, inflated back to its 1-bit rows.
 *
 * `latin1` is one byte per character, so an index into the decoded string is a
 * byte offset into the buffer — which is what makes it safe to find a stream
 * header by regex and then slice the BINARY payload out of the Buffer.
 *
 * Matched on `/BitsPerComponent 1` so the MARK — the one 8-bit RGB image the
 * sheet also carries — is not mistaken for a code. It is not one, and decoding
 * it as one would put a null in the list below.
 */
function extractImages(pdf: Buffer): { side: number; raw: Buffer }[] {
  const text = pdf.toString('latin1');
  const header =
    /<< \/Type \/XObject \/Subtype \/Image \/Width (\d+) \/Height (\d+) \/ColorSpace \/DeviceGray \/BitsPerComponent 1 [^>]*?\/Length (\d+) >>\nstream\n/g;

  const images: { side: number; raw: Buffer }[] = [];
  for (let match = header.exec(text); match; match = header.exec(text)) {
    const start = match.index + match[0].length;
    const length = Number(match[3]);
    images.push({
      side: Number(match[1]),
      raw: zlib.inflateSync(pdf.subarray(start, start + length)),
    });
  }
  return images;
}

/**
 * Expands a 1-bit DeviceGray bitmap to RGBA and decodes it as a QR.
 *
 * A set bit is WHITE and a clear bit is BLACK — the convention `qrBitmap1Bit`
 * writes and the one a PDF reader applies. Getting it backwards would produce an
 * inverted image that jsQR refuses, so a decode that succeeds also confirms the
 * polarity is right.
 */
function decodeImage(image: { side: number; raw: Buffer }): string | null {
  const rowBytes = Math.ceil(image.side / 8);
  const rgba = new Uint8ClampedArray(image.side * image.side * 4);

  for (let y = 0; y < image.side; y++) {
    for (let x = 0; x < image.side; x++) {
      const bit = (image.raw[y * rowBytes + (x >> 3)]! >> (7 - (x & 7))) & 1;
      const value = bit ? 255 : 0;
      const at = (y * image.side + x) * 4;
      rgba[at] = value;
      rgba[at + 1] = value;
      rgba[at + 2] = value;
      rgba[at + 3] = 255;
    }
  }

  return jsQR(rgba, image.side, image.side)?.data ?? null;
}

/**
 * Every `cm` matrix that places a CODE on the page: `a 0 0 d x y cm` followed
 * by the code's own `Do`. The mark inside each code is placed the same way but
 * draws `/Logo`, so a count of these is a count of squares, not of pictures.
 */
function codePlacements(pdf: string): RegExpMatchArray[] {
  return [...pdf.matchAll(/([\d.]+) 0 0 ([\d.]+) [\d.]+ [\d.]+ cm\n\/Im\d+ Do/g)];
}

/** The same, for the mark. */
function markPlacements(pdf: string): RegExpMatchArray[] {
  return [...pdf.matchAll(/([\d.]+) 0 0 ([\d.]+) [\d.]+ [\d.]+ cm\n\/Logo Do/g)];
}

// ── The load-bearing assertion ──────────────────────────────────────────────

describe('what a square cut off the sheet actually encodes', () => {
  it('decodes to the SAME urls the vendor CSV carries, in the same order', async () => {
    const admin = await makeUser('ADMIN');
    const { batchId } = await seedBatch(admin.id, 3);

    const res = await fetchSheet(admin.auth, batchId.toString());
    expect(res.status).toBe(200);

    const decoded = extractImages(res.body).map(decodeImage);
    const csvUrls = (await exportBatchCsv(batchId))!
      .split('\n')
      .map((line) => line.split(',')[1]);

    // Not "contains the same set" — the SAME ORDER. Card 3 of the sheet, line 3
    // of the CSV and row 3 of the admin screen are one standee, and a reshuffle
    // is how a rep ends up scanning a code they think is a different one.
    expect(decoded).toEqual(csvUrls);
    expect(decoded[0]).toMatch(/^https:\/\/scan\.test\/r\/[A-Z0-9]{8}$/);
  });

  it('rasters the square at print density, not screen density', async () => {
    const admin = await makeUser('ADMIN');
    const { batchId } = await seedBatch(admin.id, 1);

    const res = await fetchSheet(admin.auth, batchId.toString());
    const [image] = extractImages(res.body);

    // 1.67in × 300dpi ≈ 501px. Below this the module edges land between printer
    // dots and the square goes soft — the failure that only shows up on paper.
    expect(image!.side).toBeGreaterThanOrEqual(501);
  });
});

// ── The physical size ───────────────────────────────────────────────────────

describe('the printed size of the square', () => {
  it('is 1.67in, written as an equal-axis cm matrix', async () => {
    const admin = await makeUser('ADMIN');
    const { batchId } = await seedBatch(admin.id, 2);

    const res = await fetchSheet(admin.auth, batchId.toString());
    const pdf = res.body.toString('latin1');

    // Equal width and height by construction: one number, twice, so nothing
    // downstream can stretch the code into a rectangle.
    expect(pdf).toContain(`${QR_SIDE_PT} 0 0 ${QR_SIDE_PT} `);
    const squares = codePlacements(pdf);
    expect(squares).toHaveLength(2);
    for (const square of squares) expect(square[1]).toBe(square[2]);
    // The mark inside each code is placed the same way, so it cannot be
    // stretched any more than the code can.
    const marks = markPlacements(pdf);
    expect(marks).toHaveLength(2);
    for (const mark of marks) expect(mark[1]).toBe(mark[2]);
  });

  it('does not scale the square to fit more on a page — the GRID gives way', async () => {
    const admin = await makeUser('ADMIN');
    const { batchId } = await seedBatch(admin.id, 4);

    // A 4in card cannot go two-up on A4 (portrait width is ~8.27in less
    // margins), so the configured 3 × 3 has to collapse to 1 × 2. What must NOT
    // happen is the square shrinking to keep nine on the page.
    Object.assign(env, { STANDEE_SHEET_QR_INCHES: 4 });

    const res = await fetchSheet(admin.auth, batchId.toString());
    expect(res.status).toBe(200);
    const pdf = res.body.toString('latin1');

    expect(pdf).toContain('288.00 0 0 288.00 '); // 4in × 72, undiminished
    // Two per page now, so four codes need two sheets instead of one.
    expect(pdf).toContain('/Count 2');
    expect(res.headers['x-standee-sheet-pages']).toBe('2');
  });

  it('follows STANDEE_SHEET_QR_INCHES without any other change', async () => {
    const admin = await makeUser('ADMIN');
    const { batchId } = await seedBatch(admin.id, 1);

    Object.assign(env, { STANDEE_SHEET_QR_INCHES: 2 });
    const res = await fetchSheet(admin.auth, batchId.toString());

    expect(res.body.toString('latin1')).toContain('144.00 0 0 144.00 ');
  });

  it('follows STANDEE_SHEET_QR_DPI for how finely the square is rastered', async () => {
    const admin = await makeUser('ADMIN');
    const { batchId } = await seedBatch(admin.id, 1);

    Object.assign(env, { STANDEE_SHEET_QR_DPI: 600 });
    const res = await fetchSheet(admin.auth, batchId.toString());
    const [image] = extractImages(res.body);

    // 1.67in × 600dpi ≈ 1002px. The printed size is unchanged — only the raster.
    expect(image!.side).toBeGreaterThanOrEqual(1002);
    expect(res.body.toString('latin1')).toContain(`${QR_SIDE_PT} 0 0 ${QR_SIDE_PT} `);
  });
});

// ── Pagination ──────────────────────────────────────────────────────────────

describe('paging a batch across A4 sheets', () => {
  it('adds pages as the batch grows, nine to a page', async () => {
    const admin = await makeUser('ADMIN');

    for (const [codes, pages] of [
      [1, 1],
      [PER_PAGE, 1],
      [PER_PAGE + 1, 2],
      [50, Math.ceil(50 / PER_PAGE)],
    ] as const) {
      const { batchId } = await seedBatch(admin.id, codes, `run of ${codes}`);
      const res = await fetchSheet(admin.auth, batchId.toString());
      const pdf = res.body.toString('latin1');

      expect(res.status).toBe(200);
      expect(pdf).toContain(`/Count ${pages}`);
      expect(res.headers['x-standee-sheet-pages']).toBe(String(pages));
      expect(res.headers['x-standee-sheet-standees']).toBe(String(codes));
      // Every code is on the paper exactly once, however many pages that took.
      expect(codePlacements(pdf)).toHaveLength(codes);

      await QrCode.deleteMany({ batchId });
      await QrBatch.deleteOne({ _id: batchId });
    }
  });

  it('puts NINE on a page by default, at the undiminished square', async () => {
    const admin = await makeUser('ADMIN');
    const { batchId } = await seedBatch(admin.id, 9);

    // The shipped grid, asserted on the PAPER rather than on the env default:
    // nine cards, one page, and every square still 1.67in. Nine-up is only worth
    // having because it came out of the margins — the moment it comes out of the
    // code size instead, this is the test that says so.
    const res = await fetchSheet(admin.auth, batchId.toString());
    const pdf = res.body.toString('latin1');

    expect(res.status).toBe(200);
    expect(res.headers['x-standee-sheet-pages']).toBe('1');
    expect(pdf).toContain('/Count 1');

    const squares = codePlacements(pdf);
    expect(squares).toHaveLength(9);
    for (const square of squares) expect(square[1]).toBe(QR_SIDE_PT);

    // Nine cut guides too: a card the grid cannot fit is a card that is not
    // drawn, and a page of nine squares with eight boxes would be the tell.
    expect([...pdf.matchAll(/[\d.]+ [\d.]+ [\d.]+ [\d.]+ re\nS/g)]).toHaveLength(9);
  });

  it('follows the configured grid', async () => {
    const admin = await makeUser('ADMIN');
    const { batchId } = await seedBatch(admin.id, 8);

    Object.assign(env, { STANDEE_SHEET_COLUMNS: 2, STANDEE_SHEET_ROWS: 2 });
    const res = await fetchSheet(admin.auth, batchId.toString());

    // Four to a page → eight codes is two pages, not the default's single one.
    expect(res.body.toString('latin1')).toContain('/Count 2');
    expect(res.headers['x-standee-sheet-pages']).toBe('2');
  });

  it('keeps every page a valid A4 page with a correct xref', async () => {
    const admin = await makeUser('ADMIN');
    // TWENTY: three pages at nine-up, with a part-full last one. The point of
    // the test is a sheet whose xref spans several pages, so the count follows
    // the grid rather than staying at the number that used to make three.
    const { batchId } = await seedBatch(admin.id, 20);

    const res = await fetchSheet(admin.auth, batchId.toString());
    const pdf = res.body.toString('latin1');

    expect(pdf.startsWith('%PDF-')).toBe(true);
    expect(pdf.endsWith('%%EOF')).toBe(true);
    expect([...pdf.matchAll(/\/MediaBox \[0 0 595\.28 841\.89\]/g)]).toHaveLength(3);

    // The fiddly part of writing a PDF by hand, and the part multi-page makes
    // fiddlier: every offset in the xref must be the exact byte position of its
    // object. Twenty codes over three pages is 4 + 1 (the mark) + 6 + 20 = 31.
    const startxref = Number(
      pdf.slice(pdf.lastIndexOf('startxref') + 9).trim().split('\n')[0]
    );
    expect(pdf.slice(startxref, startxref + 4)).toBe('xref');

    const offsets = [...pdf.matchAll(/^(\d{10}) 00000 n $/gm)].map((m) => Number(m[1]));
    expect(offsets).toHaveLength(31);
    offsets.forEach((offset, index) => {
      expect(pdf.slice(offset, offset + `${index + 1} 0 obj`.length)).toBe(
        `${index + 1} 0 obj`
      );
    });
  });
});

// ── What is printed on a card ───────────────────────────────────────────────

describe('what the card says', () => {
  it('prints every code and the SAME tagline the one-up sheet uses', async () => {
    const admin = await makeUser('ADMIN');
    const { batchId } = await seedBatch(admin.id, 3);
    const codes = await QrCode.find({ batchId }).sort({ code: 1 }).lean().exec();

    const res = await fetchSheet(admin.auth, batchId.toString());
    const pdf = res.body.toString('latin1');

    for (const row of codes) expect(pdf).toContain(`(${row.code}) Tj`);
    // One constant, two layouts. A standee cut off a batch sheet and one printed
    // one-up are the same physical object and must not say different things.
    expect([...pdf.matchAll(/\(Created for mirage menu\) Tj/g)]).toHaveLength(3);
    expect(STANDEE_TAGLINE).toBe('Created for mirage menu');
  });

  it('names the batch and the page on every footer', async () => {
    const admin = await makeUser('ADMIN');
    // AN EM DASH ON PURPOSE. It is the house shape the mint dialog suggests
    // ("Vendor A — Oct 2026, run 3"), so the very first real batch carries one.
    // The base-14 fonts are single-byte and nothing declares an /Encoding, so an
    // unfolded caption would print `â€"` across the footer of every page.
    // TEN, so the run spills onto a second page at the shipped nine-up grid —
    // a one-page sheet would assert nothing about the "Page n of m" counter.
    const { batchId } = await seedBatch(admin.id, 10, 'Vendor B — Oct run');

    const res = await fetchSheet(admin.auth, batchId.toString());
    const pdf = res.body.toString('latin1');

    expect(pdf).toContain('(Vendor B - Oct run   |   Page 1 of 2   |   10 standees) Tj');
    expect(pdf).toContain('(Vendor B - Oct run   |   Page 2 of 2   |   10 standees) Tj');
    // Nothing outside printable ASCII survived into the drawn text.
    for (const [, drawn] of pdf.matchAll(/\((.*?)\) Tj/g)) {
      expect(drawn).toMatch(/^[\x20-\x7e]*$/);
    }
  });

  it('carries the mark in the middle of every square, from ONE object', async () => {
    const admin = await makeUser('ADMIN');
    const { batchId } = await seedBatch(admin.id, 11);

    const res = await fetchSheet(admin.auth, batchId.toString());
    const pdf = res.body.toString('latin1');

    // Drawn once per card, across both pages...
    expect(pdf.match(/\/Logo Do/g)).toHaveLength(11);
    // ...from a single RGB image, however many cards there are. Five hundred
    // cards must not mean five hundred copies of the artwork.
    expect(pdf.match(/\/ColorSpace \/DeviceRGB/g)).toHaveLength(1);
    // And never as a JPEG — flat colour with hard edges, like the code itself.
    expect(pdf).not.toContain('/DCTDecode');
  });

  it('draws a cut guide around each card', async () => {
    const admin = await makeUser('ADMIN');
    const { batchId } = await seedBatch(admin.id, 2);

    const res = await fetchSheet(admin.auth, batchId.toString());
    const pdf = res.body.toString('latin1');

    // The whole reason the sheet has margins worth the name: somebody cuts it up.
    expect([...pdf.matchAll(/[\d.]+ [\d.]+ [\d.]+ [\d.]+ re\nS/g)]).toHaveLength(2);
  });

  it('names the file after the batch, like the vendor CSV beside it', async () => {
    const admin = await makeUser('ADMIN');
    const { batchId } = await seedBatch(admin.id, 1, 'Vendor A — Oct 2026, run 3');

    const res = await fetchSheet(admin.auth, batchId.toString());

    expect(res.headers['content-type']).toBe('application/pdf');
    expect(res.headers['content-disposition']).toBe(
      'attachment; filename="standee-sheet-vendor-a-oct-2026-run-3.pdf"'
    );
  });
});

// ── Retired codes ───────────────────────────────────────────────────────────

describe('retired codes', () => {
  it('are left off the sheet, and the count is REPORTED rather than swallowed', async () => {
    const admin = await makeUser('ADMIN');
    const { batchId } = await seedBatch(admin.id, 5);
    const codes = await QrCode.find({ batchId }).sort({ code: 1 }).lean().exec();
    await QrCode.updateOne({ _id: codes[0]!._id }, { $set: { state: 'RETIRED' } });

    const res = await fetchSheet(admin.auth, batchId.toString());
    const pdf = res.body.toString('latin1');

    expect(res.status).toBe(200);
    expect(pdf).not.toContain(`(${codes[0]!.code}) Tj`);
    expect(codePlacements(pdf)).toHaveLength(4);
    // "I asked for 5 and got 4" reads as a bug unless something says why, and by
    // the time the PDF is open there is nowhere left to say it.
    expect(res.headers['x-standee-sheet-skipped-retired']).toBe('1');
    expect(res.headers['x-standee-sheet-standees']).toBe('4');
  });

  it('do not block a batch — only an ENTIRELY retired one is refused', async () => {
    const admin = await makeUser('ADMIN');
    const { batchId } = await seedBatch(admin.id, 2);
    await QrCode.updateMany({ batchId }, { $set: { state: 'RETIRED' } });

    const res = await fetchSheet(admin.auth, batchId.toString());

    // Blank paper is worse than a refusal an admin can act on.
    expect(res.status).toBe(409);
    expect(envelope(res).code).toBe('NOTHING_TO_PRINT');
  });
});

// ── Refusals ────────────────────────────────────────────────────────────────

describe('what the endpoint refuses', () => {
  it('is ADMIN-only — a MODEL_ARTIST does not pass', async () => {
    const admin = await makeUser('ADMIN');
    const artist = await makeUser('MODEL_ARTIST');
    const { batchId } = await seedBatch(admin.id, 1);

    const res = await fetchSheet(artist.auth, batchId.toString());
    expect(res.status).toBe(403);
  });

  it('refuses a batch past STANDEE_SHEET_MAX_CODES, naming the number', async () => {
    const admin = await makeUser('ADMIN');
    const { batchId } = await seedBatch(admin.id, 3);

    Object.assign(env, { STANDEE_SHEET_MAX_CODES: 2 });
    const res = await fetchSheet(admin.auth, batchId.toString());

    expect(res.status).toBe(409);
    expect(envelope(res).code).toBe('BATCH_TOO_LARGE');
    // The admin has to be able to read what to do next off the message.
    expect(envelope(res).message).toContain('3');
    expect(envelope(res).message).toContain('2');
  });

  it('refuses rather than printing urls against a guessed host', async () => {
    const admin = await makeUser('ADMIN');
    const { batchId } = await seedBatch(admin.id, 1);

    Object.assign(env, { PUBLIC_RESOLVER_BASE_URL: undefined });
    const res = await fetchSheet(admin.auth, batchId.toString());

    // The whole cost of a wrong origin lands after the codes are on paper.
    expect(res.status).toBe(409);
    expect(envelope(res).code).toBe('RESOLVER_NOT_CONFIGURED');
  });

  it('404s an unknown batch and 400s a malformed id', async () => {
    const admin = await makeUser('ADMIN');

    const missing = await fetchSheet(admin.auth, new Types.ObjectId().toHexString());
    expect(missing.status).toBe(404);

    const malformed = await fetchSheet(admin.auth, 'not-an-id');
    expect(malformed.status).toBe(400);
  });
});

// ── Caching and determinism ─────────────────────────────────────────────────

describe('caching', () => {
  it('renders byte-identical bytes twice', async () => {
    const admin = await makeUser('ADMIN');
    const { batchId } = await seedBatch(admin.id, 7);

    const a = await fetchSheet(admin.auth, batchId.toString());
    const b = await fetchSheet(admin.auth, batchId.toString());

    // Nothing timestamped, nothing locale-dependent — the same premise the
    // single-code sheet is built on, which is what makes the ETag meaningful.
    expect(a.body.equals(b.body)).toBe(true);
    expect(a.headers.etag).toBe(b.headers.etag);
  });

  it('answers 304 to a matching If-None-Match', async () => {
    const admin = await makeUser('ADMIN');
    const { batchId } = await seedBatch(admin.id, 3);

    const first = await fetchSheet(admin.auth, batchId.toString());
    const second = await request(app)
      .get(`/admin/qr-batches/${batchId.toString()}/sheet`)
      .set(admin.auth)
      .set('If-None-Match', first.headers.etag);

    expect(second.status).toBe(304);
  });

  it('changes the ETag when the layout settings change', async () => {
    const admin = await makeUser('ADMIN');
    const { batchId } = await seedBatch(admin.id, 3);

    const before = await fetchSheet(admin.auth, batchId.toString());
    Object.assign(env, { STANDEE_SHEET_QR_INCHES: 2 });
    const after = await fetchSheet(admin.auth, batchId.toString());

    // A cached sheet at the old size would be the one thing nobody would think
    // to check after changing the setting to fix exactly that.
    expect(after.headers.etag).not.toBe(before.headers.etag);
  });

  it('retiring a code invalidates the sheet', async () => {
    const admin = await makeUser('ADMIN');
    const { batchId } = await seedBatch(admin.id, 3);

    const before = await fetchSheet(admin.auth, batchId.toString());
    const codes = await QrCode.find({ batchId }).sort({ code: 1 }).lean().exec();
    await QrCode.updateOne({ _id: codes[0]!._id }, { $set: { state: 'RETIRED' } });
    const after = await fetchSheet(admin.auth, batchId.toString());

    // Not because state is in the key — it deliberately is not — but because a
    // retirement takes a card off, and the code list is.
    expect(after.headers.etag).not.toBe(before.headers.etag);
  });
});
