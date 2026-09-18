// tests/standee-sheet-copies.test.ts
//
// ONE code, several times over — `?copies=` and `?layout=` on the single-standee
// sheet, through both doors (`/admin/qr-codes/:code/qr` and
// `/rep/standees/:code/qr`), and the `/qr/plan` read the dialog makes first.
//
// THE ASSERTION THAT CARRIES THIS SUITE: every copy is the SAME square. Ten
// pages one-up are ten references to ONE image and ONE content stream; ten
// cards on the grid are ten placements of ONE image at the fixed 1.67in edge.
// A "copies" feature that re-encoded the code per copy would be the one place a
// diner's phone could see a different pattern on table 7 than on table 3.
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
import { QrCodeAssignment } from '@/models/QrCodeAssignment';
import { mintBatch } from '@/services/qrCodeService';

const app = createApp();
let mongod: MongoMemoryServer;

const SHEET_DEFAULTS = {
  STANDEE_SHEET_QR_INCHES: 1.67,
  STANDEE_SHEET_QR_DPI: 300,
  STANDEE_SHEET_COLUMNS: 3,
  STANDEE_SHEET_ROWS: 3,
} as const;

/** 1.67in × 72pt/in, as the grid's `cm` matrix writes it. */
const GRID_QR_SIDE_PT = '120.24';
/** The one-up sheet's square, as `catalogQrService.buildPdf` writes it. */
const ONE_UP_QR_SIDE_PT = '360';

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
  Object.assign(env, { PUBLIC_RESOLVER_BASE_URL: 'https://scan.test' }, SHEET_DEFAULTS);
  vi.spyOn(console, 'log').mockImplementation(() => {});
});

afterEach(async () => {
  Object.assign(env, SHEET_DEFAULTS);
  await User.deleteMany({});
  await QrCode.deleteMany({});
  await QrBatch.deleteMany({});
  await QrCodeAssignment.deleteMany({});
  vi.restoreAllMocks();
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

async function mintOne(): Promise<string> {
  const { batchId } = await mintBatch({
    count: 1,
    label: 'copies suite',
    createdByUserId: new Types.ObjectId(),
  });
  const [row] = await QrCode.find({ batchId }, { code: 1 }).lean().exec();
  return row!.code;
}

type Auth = { Authorization: string };

function adminSheet(auth: Auth, code: string, query: Record<string, string | number>) {
  return request(app).get(`/admin/qr-codes/${code}/qr`).query(query).set(auth).responseType('blob');
}

function repSheet(auth: Auth, code: string, query: Record<string, string | number>) {
  return request(app).get(`/rep/standees/${code}/qr`).query(query).set(auth).responseType('blob');
}

function envelope(res: { body: Buffer }): { code: string; message: string } {
  return JSON.parse(res.body.toString('utf8'));
}

/** Every `cm` that places a code square, one per drawn card/page. */
function codePlacements(pdf: string): RegExpMatchArray[] {
  return [...pdf.matchAll(/([\d.]+) 0 0 ([\d.]+) [\d.]+ [\d.]+ cm\n\/Im\d+ Do/g)];
}

async function assignTo(admin: Auth, code: string, repUserId: string): Promise<void> {
  await request(app).post(`/admin/qr-codes/${code}/assignment`).set(admin).send({ repUserId });
}

// ── One-up, several pages ───────────────────────────────────────────────────

describe('layout=single (the default): one big square per page, `copies` pages', () => {
  it('defaults to one copy and is byte-identical to the plain sheet', async () => {
    const admin = await makeUser('ADMIN');
    const code = await mintOne();

    const plain = await adminSheet(admin.auth, code, { format: 'pdf' });
    const explicit = await adminSheet(admin.auth, code, {
      format: 'pdf',
      copies: 1,
      layout: 'single',
    });

    expect(plain.status).toBe(200);
    expect(explicit.body.equals(plain.body)).toBe(true);
    expect(explicit.headers.etag).toBe(plain.headers.etag);
    expect(plain.headers['x-standee-sheet-copies']).toBe('1');
    expect(plain.headers['x-standee-sheet-pages']).toBe('1');
    // The numbering the one-up sheet always had: 1 catalog, 2 pages, 3 page,
    // 4 contents, 5 the code, 6 and 7 the fonts, 8 the mark.
    expect(plain.body.toString('latin1')).toContain('/Kids [3 0 R] /Count 1');
    expect(plain.body.toString('latin1')).toContain('/Contents 4 0 R');
  });

  it('prints ten pages that all draw ONE image through ONE content stream', async () => {
    const admin = await makeUser('ADMIN');
    const code = await mintOne();

    const res = await adminSheet(admin.auth, code, { format: 'pdf', copies: 10 });
    expect(res.status).toBe(200);
    const pdf = res.body.toString('latin1');

    expect(pdf).toContain('/Count 10');
    expect([...pdf.matchAll(/\/Type \/Page /g)]).toHaveLength(10);
    // Ten page objects, every one naming the same /Contents and the same
    // /Im0 — so the square on page 10 IS the square on page 1, by reference.
    const contents = new Set([...pdf.matchAll(/\/Contents (\d+) 0 R/g)].map((m) => m[1]));
    expect(contents.size).toBe(1);
    expect(pdf.match(/\/BitsPerComponent 1/g)).toHaveLength(1);
    expect(pdf.match(/\/DeviceRGB/g)).toHaveLength(1);
    // The content stream is stored once, so it draws the square once — at
    // the one-up sheet's size, undiminished.
    const squares = codePlacements(pdf);
    expect(squares).toHaveLength(1);
    expect(squares[0]![1]).toBe(ONE_UP_QR_SIDE_PT);

    expect(res.headers['x-standee-sheet-copies']).toBe('10');
    expect(res.headers['x-standee-sheet-pages']).toBe('10');
    expect(res.headers['content-disposition']).toBe(
      `attachment; filename="standee-${code.toLowerCase()}-qr-x10.pdf"`
    );
  });

  it('keeps a valid xref across the extra page objects', async () => {
    const admin = await makeUser('ADMIN');
    const code = await mintOne();

    const res = await adminSheet(admin.auth, code, { format: 'pdf', copies: 3 });
    const pdf = res.body.toString('latin1');

    // 1 catalog, 2 pages, 3–5 the three page objects, 6 contents, 7 the code,
    // 8 and 9 the fonts, 10 the mark: ten objects, each at its stated offset.
    const startxref = Number(
      pdf
        .slice(pdf.lastIndexOf('startxref') + 9)
        .trim()
        .split('\n')[0]
    );
    expect(pdf.slice(startxref, startxref + 4)).toBe('xref');
    const offsets = [...pdf.matchAll(/^(\d{10}) 00000 n $/gm)].map((m) => Number(m[1]));
    expect(offsets).toHaveLength(10);
    offsets.forEach((offset, index) => {
      expect(pdf.slice(offset, offset + `${index + 1} 0 obj`.length)).toBe(`${index + 1} 0 obj`);
    });
    expect(pdf).toContain('/Kids [3 0 R 4 0 R 5 0 R] /Count 3');
  });
});

// ── The grid ────────────────────────────────────────────────────────────────

describe('layout=grid: the batch grid with just this code on it', () => {
  it('draws `copies` cards of one image at the fixed 1.67in edge, with cut guides', async () => {
    const admin = await makeUser('ADMIN');
    const code = await mintOne();

    const res = await adminSheet(admin.auth, code, { format: 'pdf', copies: 10, layout: 'grid' });
    expect(res.status).toBe(200);
    const pdf = res.body.toString('latin1');

    // Nine to a page → ten cards is two pages.
    expect(pdf).toContain('/Count 2');
    expect(res.headers['x-standee-sheet-pages']).toBe('2');
    expect(res.headers['x-standee-sheet-copies']).toBe('10');

    const squares = codePlacements(pdf);
    expect(squares).toHaveLength(10);
    for (const square of squares) {
      expect(square[1]).toBe(GRID_QR_SIDE_PT);
      expect(square[2]).toBe(GRID_QR_SIDE_PT);
    }
    expect([...pdf.matchAll(/[\d.]+ [\d.]+ [\d.]+ [\d.]+ re\nS/g)]).toHaveLength(10);
    expect([...pdf.matchAll(new RegExp(`\\(${code}\\) Tj`, 'g'))]).toHaveLength(10);
    // One code image behind all ten cards, one mark behind all ten marks.
    expect(pdf.match(/\/BitsPerComponent 1/g)).toHaveLength(1);
    expect(pdf.match(/\/DeviceRGB/g)).toHaveLength(1);
    expect(pdf.match(/\/Logo Do/g)).toHaveLength(10);

    // The footer names the code — the only thing that tells two of these
    // apart in a pile — and does not say "1 standees".
    expect(pdf).toContain(`(Standee ${code}   |   Page 1 of 2   |   1 standee, 10 copies each) Tj`);
    expect(res.headers['content-disposition']).toBe(
      `attachment; filename="standee-${code.toLowerCase()}-qr-grid-x10.pdf"`
    );
  });

  it('one copy on the grid is one card on one page, named without a suffix', async () => {
    const admin = await makeUser('ADMIN');
    const code = await mintOne();

    const res = await adminSheet(admin.auth, code, { format: 'pdf', layout: 'grid' });
    const pdf = res.body.toString('latin1');

    expect(codePlacements(pdf)).toHaveLength(1);
    expect(pdf).toContain(`   |   1 standee) Tj`);
    expect(res.headers['content-disposition']).toBe(
      `attachment; filename="standee-${code.toLowerCase()}-qr-grid.pdf"`
    );
  });

  it('follows the configured grid, like the batch sheet does', async () => {
    const admin = await makeUser('ADMIN');
    const code = await mintOne();

    Object.assign(env, { STANDEE_SHEET_COLUMNS: 2, STANDEE_SHEET_ROWS: 2 });
    const res = await adminSheet(admin.auth, code, { format: 'pdf', copies: 5, layout: 'grid' });

    // Four to a page → five cards is two pages, not one.
    expect(res.body.toString('latin1')).toContain('/Count 2');
    expect(res.headers['x-standee-sheet-pages']).toBe('2');
  });
});

// ── Caching and refusals ────────────────────────────────────────────────────

describe('what changes the file, and what is refused', () => {
  it('copies and layout are both in the ETag', async () => {
    const admin = await makeUser('ADMIN');
    const code = await mintOne();

    const one = await adminSheet(admin.auth, code, { format: 'pdf' });
    const ten = await adminSheet(admin.auth, code, { format: 'pdf', copies: 10 });
    const grid = await adminSheet(admin.auth, code, { format: 'pdf', copies: 10, layout: 'grid' });

    const tags = new Set([one.headers.etag, ten.headers.etag, grid.headers.etag]);
    expect(tags.size).toBe(3);
    // And the grid's geometry with it, as the batch sheet's is.
    Object.assign(env, { STANDEE_SHEET_QR_INCHES: 2 });
    const bigger = await adminSheet(admin.auth, code, {
      format: 'pdf',
      copies: 10,
      layout: 'grid',
    });
    expect(bigger.headers.etag).not.toBe(grid.headers.etag);
  });

  it('refuses copies or a layout on a PNG — it is one picture', async () => {
    const admin = await makeUser('ADMIN');
    const code = await mintOne();

    for (const query of [
      { format: 'png', copies: 2 },
      { format: 'png', layout: 'grid' },
      { copies: 3 }, // format defaults to png
    ]) {
      const res = await adminSheet(admin.auth, code, query);
      expect(res.status).toBe(400);
      expect(envelope(res).code).toBe('INVALID_REQUEST');
    }
    // Explicit defaults on a PNG are fine: they change nothing.
    const ok = await adminSheet(admin.auth, code, { format: 'png', copies: 1, layout: 'single' });
    expect(ok.status).toBe(200);
    expect(ok.headers['x-standee-sheet-copies']).toBeUndefined();
  });

  it('refuses 0, 51, a fraction and an unknown layout', async () => {
    const admin = await makeUser('ADMIN');
    const code = await mintOne();

    for (const query of [
      { format: 'pdf', copies: 0 },
      { format: 'pdf', copies: 51 },
      { format: 'pdf', copies: '2.5' },
      { format: 'pdf', layout: 'sheet' },
    ]) {
      const res = await adminSheet(admin.auth, code, query);
      expect(res.status).toBe(400);
      expect(envelope(res).code).toBe('INVALID_REQUEST');
    }
    expect((await adminSheet(admin.auth, code, { format: 'pdf', copies: 50 })).status).toBe(200);
  });

  it('still refuses a retired code, in either layout', async () => {
    const admin = await makeUser('ADMIN');
    const code = await mintOne();
    await QrCode.updateOne({ code }, { $set: { state: 'RETIRED' } });

    for (const layout of ['single', 'grid']) {
      const res = await adminSheet(admin.auth, code, { format: 'pdf', copies: 5, layout });
      expect(res.status).toBe(409);
      expect(envelope(res).code).toBe('CODE_RETIRED');
    }
  });
});

// ── The rep's door ──────────────────────────────────────────────────────────

describe('GET /rep/standees/:code/qr with copies and layout', () => {
  it('renders the SAME bytes the admin door renders, for the holder only', async () => {
    const admin = await makeUser('ADMIN');
    const rep = await makeUser('SALES_REP');
    const other = await makeUser('SALES_REP');
    const code = await mintOne();
    await assignTo(admin.auth, code, rep.id);

    const query = { format: 'pdf', copies: 4, layout: 'grid' };
    const mine = await repSheet(rep.auth, code, query);
    const admins = await adminSheet(admin.auth, code, query);

    expect(mine.status).toBe(200);
    expect(mine.body.equals(admins.body)).toBe(true);
    expect(mine.headers.etag).toBe(admins.headers.etag);
    expect(mine.headers['x-standee-sheet-copies']).toBe('4');
    expect(mine.headers['x-standee-sheet-pages']).toBe('1');

    expect((await repSheet(other.auth, code, query)).status).toBe(404);
  });

  it('validates the query the same way', async () => {
    const admin = await makeUser('ADMIN');
    const rep = await makeUser('SALES_REP');
    const code = await mintOne();
    await assignTo(admin.auth, code, rep.id);

    const res = await repSheet(rep.auth, code, { format: 'pdf', copies: 99 });
    expect(res.status).toBe(400);
    expect(envelope(res).code).toBe('INVALID_REQUEST');
  });
});

// ── The plan ────────────────────────────────────────────────────────────────

describe('the /qr/plan read in front of the dialog', () => {
  it('describes the grid and the copies ceiling, through both doors', async () => {
    const admin = await makeUser('ADMIN');
    const rep = await makeUser('SALES_REP');
    const code = await mintOne();
    await assignTo(admin.auth, code, rep.id);

    const expected = {
      status: 'success',
      plan: { columns: 3, rows: 3, perPage: 9, maxCopies: 50 },
    };
    const viaAdmin = await request(app).get(`/admin/qr-codes/${code}/qr/plan`).set(admin.auth);
    const viaRep = await request(app).get(`/rep/standees/${code}/qr/plan`).set(rep.auth);

    expect(viaAdmin.status).toBe(200);
    expect(viaAdmin.body).toEqual(expected);
    expect(viaRep.status).toBe(200);
    expect(viaRep.body).toEqual(expected);
  });

  it('agrees with the sheet on the page count for either layout', async () => {
    const admin = await makeUser('ADMIN');
    const code = await mintOne();

    Object.assign(env, { STANDEE_SHEET_COLUMNS: 2, STANDEE_SHEET_ROWS: 2 });
    const plan = (await request(app).get(`/admin/qr-codes/${code}/qr/plan`).set(admin.auth)).body
      .plan;
    expect(plan.perPage).toBe(4);

    for (const copies of [1, 4, 5, 50]) {
      const single = await adminSheet(admin.auth, code, { format: 'pdf', copies });
      const grid = await adminSheet(admin.auth, code, { format: 'pdf', copies, layout: 'grid' });
      // The dialog's arithmetic, done here exactly as the client does it.
      expect(single.headers['x-standee-sheet-pages']).toBe(String(copies));
      expect(grid.headers['x-standee-sheet-pages']).toBe(
        String(Math.max(1, Math.ceil(copies / plan.perPage)))
      );
    }
  });

  it('refuses what the sheet refuses: retired, unknown, and not held', async () => {
    const admin = await makeUser('ADMIN');
    const rep = await makeUser('SALES_REP');
    const artist = await makeUser('MODEL_ARTIST');
    const code = await mintOne();

    // Not held → the rep's 404; ADMIN-only → the artist's 403.
    expect((await request(app).get(`/rep/standees/${code}/qr/plan`).set(rep.auth)).status).toBe(
      404
    );
    expect(
      (await request(app).get(`/admin/qr-codes/${code}/qr/plan`).set(artist.auth)).status
    ).toBe(403);
    expect(
      (await request(app).get('/admin/qr-codes/ZZZZ9999/qr/plan').set(admin.auth)).status
    ).toBe(404);

    await assignTo(admin.auth, code, rep.id);
    await QrCode.updateOne({ code }, { $set: { state: 'RETIRED' } });
    const retiredAdmin = await request(app).get(`/admin/qr-codes/${code}/qr/plan`).set(admin.auth);
    const retiredRep = await request(app).get(`/rep/standees/${code}/qr/plan`).set(rep.auth);
    expect(retiredAdmin.status).toBe(409);
    expect(retiredAdmin.body.code).toBe('CODE_RETIRED');
    expect(retiredRep.status).toBe(409);
    expect(retiredRep.body.code).toBe('CODE_RETIRED');
  });
});
