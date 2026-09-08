// tests/standee-assignment.test.ts
//
// Handing a standee to a rep: the admin picker, the assignment itself, and what
// the rep can then see and download.
//
// THE ASSERTION THAT CARRIES THIS SUITE is that assignment is ADVISORY. A code
// assigned to rep A must still activate for rep B, and an unassigned code must
// still activate for anybody — because the alternative was considered and
// rejected, and a future change that quietly adds the lock would break the
// walk-up standee flow with no other test noticing. That is asserted here
// against the real activation endpoint, not against a comment.
//
// Second: the rep download is scoped by ASSIGNMENT, not merely by role. Every
// rep can reach `/rep/standees/:code/qr`; only the holder gets bytes, and a
// non-holder gets the same 404 a nonexistent code gives, so the endpoint cannot
// be used to discover which codes have been minted.
//
// Third: no raw phone or email appears in the picker or on an admin row. The
// reps list is the one place this feature reads other people's accounts, so the
// masked-only stance is asserted rather than assumed.
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

import { createApp } from '@/app';
import { env } from '@/config/env';
import { User, type UserRole } from '@/models/User';
import { QrBatch } from '@/models/QrBatch';
import { QrCode } from '@/models/QrCode';
import { Catalog } from '@/models/Catalog';
import { CatalogDelegation } from '@/models/CatalogDelegation';
import { QrCodeAssignment } from '@/models/QrCodeAssignment';
import { mintBatch } from '@/services/qrCodeService';

const app = createApp();
let mongod: MongoMemoryServer;

const RESOLVER_BASE = 'https://scan.test';

const REP_PHONE = '+919876543210';
const REP_EMAIL = 'fieldrep@example.com';

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
  await Catalog.deleteMany({});
  await CatalogDelegation.deleteMany({});
  await QrCodeAssignment.deleteMany({});
  vi.restoreAllMocks();
});

/** A real user doc (requireRole reads the DB on every request) + its header. */
async function makeUser(
  role: UserRole | undefined,
  extra: Record<string, unknown> = {}
): Promise<{ id: string; auth: { Authorization: string } }> {
  const user = await User.create({
    authProvider: 'custom',
    authUid: `test|${new Types.ObjectId().toHexString()}`,
    ...(role ? { role } : {}),
    ...extra,
  });
  const id = user.id as string;
  const token = jwt.sign({ userId: id, authUid: user.authUid }, env.JWT_SECRET, {
    expiresIn: '15m',
  });
  return { id, auth: { Authorization: `Bearer ${token}` } };
}

/** One minted batch, and the codes in it sorted the way the API returns them. */
async function mintCodes(count: number): Promise<string[]> {
  const { batchId } = await mintBatch({
    count,
    label: 'assignment suite',
    createdByUserId: new Types.ObjectId(),
  });
  const codes = await QrCode.find({ batchId }, { code: 1 }).sort({ code: 1 }).lean().exec();
  return codes.map((c) => c.code);
}

describe('GET /admin/sales-reps', () => {
  it('is ADMIN-only — a MODEL_ARTIST does not pass', async () => {
    const artist = await makeUser('MODEL_ARTIST');
    const res = await request(app).get('/admin/sales-reps').set(artist.auth);

    expect(res.status).toBe(403);
    expect(res.body.code).toBe('FORBIDDEN');
  });

  it('lists every staff role that can use /rep, and no plain USER', async () => {
    const admin = await makeUser('ADMIN');
    const rep = await makeUser('SALES_REP');
    const artist = await makeUser('MODEL_ARTIST');
    const plain = await makeUser('USER');

    const res = await request(app).get('/admin/sales-reps').set(admin.auth);
    expect(res.status).toBe(200);

    const ids = (res.body.reps as { id: string }[]).map((r) => r.id);
    // Inclusive upward, as everywhere else: an admin who also does field visits
    // must be assignable to, so the roster is defined by capability rather than
    // by `role === 'SALES_REP'`.
    expect(ids).toEqual(expect.arrayContaining([admin.id, rep.id, artist.id]));
    expect(ids).not.toContain(plain.id);
  });

  it('carries a MASKED contact and never a raw phone or email', async () => {
    const admin = await makeUser('ADMIN');
    await makeUser('SALES_REP', {
      phone: REP_PHONE,
      displayName: 'Field Rep',
      email: REP_EMAIL,
    });

    const res = await request(app).get('/admin/sales-reps').set(admin.auth);
    expect(res.status).toBe(200);

    const body = JSON.stringify(res.body);
    expect(body).not.toContain(REP_PHONE);
    expect(body).not.toContain(REP_EMAIL);

    const row = (res.body.reps as { displayName: string; contactMasked: string }[]).find(
      (r) => r.displayName === 'Field Rep'
    );
    // Phone wins over email (it is the primary channel), and the mask keeps only
    // the dial prefix and the last three digits.
    expect(row?.contactMasked).toBe('+91 ••••• ••210');
  });
});

describe('POST /admin/qr-codes/:code/assignment', () => {
  it('is ADMIN-only — a SALES_REP cannot hand themselves a standee', async () => {
    const rep = await makeUser('SALES_REP');
    const [code] = await mintCodes(1);

    const res = await request(app)
      .post(`/admin/qr-codes/${code}/assignment`)
      .set(rep.auth)
      .send({ repUserId: rep.id });

    expect(res.status).toBe(403);
    const stored = await QrCode.findOne({ code }).lean().exec();
    expect(stored?.assignedToUserId).toBeUndefined();
  });

  it('assigns, and the row then names the holder on the admin batch list', async () => {
    const admin = await makeUser('ADMIN');
    const rep = await makeUser('SALES_REP', { displayName: 'Field Rep' });
    const [code] = await mintCodes(2);

    const assign = await request(app)
      .post(`/admin/qr-codes/${code}/assignment`)
      .set(admin.auth)
      .send({ repUserId: rep.id });

    expect(assign.status).toBe(200);
    expect(assign.body.assignedTo.id).toBe(rep.id);

    const stored = await QrCode.findOne({ code }).lean().exec();
    expect(String(stored?.assignedToUserId)).toBe(rep.id);
    // The acting admin is recorded, so an assignment can be traced back later.
    expect(String(stored?.assignedByUserId)).toBe(admin.id);
    expect(stored?.assignedAt).toBeInstanceOf(Date);

    const batch = await QrBatch.findOne({}).lean().exec();
    const list = await request(app)
      .get(`/admin/qr-batches/${String(batch?._id)}/codes`)
      .set(admin.auth);

    expect(list.status).toBe(200);
    const rows = list.body.codes as { code: string; assignedTo: { id: string } | null }[];
    expect(rows.find((r) => r.code === code)?.assignedTo?.id).toBe(rep.id);
    // Every other code in the batch is still stock nobody holds.
    expect(rows.filter((r) => r.assignedTo !== null)).toHaveLength(1);
  });

  it('REASSIGNS on a second call rather than refusing', async () => {
    const admin = await makeUser('ADMIN');
    const first = await makeUser('SALES_REP');
    const second = await makeUser('SALES_REP');
    const [code] = await mintCodes(1);

    await request(app)
      .post(`/admin/qr-codes/${code}/assignment`)
      .set(admin.auth)
      .send({ repUserId: first.id });

    const again = await request(app)
      .post(`/admin/qr-codes/${code}/assignment`)
      .set(admin.auth)
      .send({ repUserId: second.id });

    expect(again.status).toBe(200);
    expect(again.body.assignedTo.id).toBe(second.id);

    // A standee is one physical object, so it is on exactly one rep's list.
    const forFirst = await QrCode.countDocuments({ assignedToUserId: first.id }).exec();
    expect(forFirst).toBe(0);
  });

  it('refuses an account that cannot use /rep at all', async () => {
    const admin = await makeUser('ADMIN');
    const plain = await makeUser('USER');
    const [code] = await mintCodes(1);

    const res = await request(app)
      .post(`/admin/qr-codes/${code}/assignment`)
      .set(admin.auth)
      .send({ repUserId: plain.id });

    expect(res.status).toBe(404);
    expect(res.body.code).toBe('REP_NOT_FOUND');
  });

  it('refuses a RETIRED code — nothing can be done with one', async () => {
    const admin = await makeUser('ADMIN');
    const rep = await makeUser('SALES_REP');
    const [code] = await mintCodes(1);
    await QrCode.updateOne({ code }, { $set: { state: 'RETIRED' } }).exec();

    const res = await request(app)
      .post(`/admin/qr-codes/${code}/assignment`)
      .set(admin.auth)
      .send({ repUserId: rep.id });

    expect(res.status).toBe(409);
    expect(res.body.code).toBe('CODE_RETIRED');
  });
});

describe('DELETE /admin/qr-codes/:code/assignment', () => {
  it('clears the holder, and succeeds again on a code nobody holds', async () => {
    const admin = await makeUser('ADMIN');
    const rep = await makeUser('SALES_REP');
    const [code] = await mintCodes(1);

    await request(app)
      .post(`/admin/qr-codes/${code}/assignment`)
      .set(admin.auth)
      .send({ repUserId: rep.id });

    const first = await request(app)
      .delete(`/admin/qr-codes/${code}/assignment`)
      .set(admin.auth);
    expect(first.status).toBe(200);
    expect(first.body.assignedTo).toBeNull();

    const stored = await QrCode.findOne({ code }).lean().exec();
    expect(stored?.assignedToUserId).toBeUndefined();
    // The audit field goes with it — a half-cleared row would read as assigned.
    expect(stored?.assignedByUserId).toBeUndefined();

    // Idempotent: the admin asked for it to be on nobody's list, and it is.
    const second = await request(app)
      .delete(`/admin/qr-codes/${code}/assignment`)
      .set(admin.auth);
    expect(second.status).toBe(200);
  });
});

describe('GET /rep/standees', () => {
  it('returns only the calling rep’s own stock', async () => {
    const admin = await makeUser('ADMIN');
    const mine = await makeUser('SALES_REP');
    const theirs = await makeUser('SALES_REP');
    const [a, b] = await mintCodes(2);

    await request(app)
      .post(`/admin/qr-codes/${a}/assignment`)
      .set(admin.auth)
      .send({ repUserId: mine.id });
    await request(app)
      .post(`/admin/qr-codes/${b}/assignment`)
      .set(admin.auth)
      .send({ repUserId: theirs.id });

    const res = await request(app).get('/rep/standees').set(mine.auth);
    expect(res.status).toBe(200);

    const codes = (res.body.standees as { code: string; url: string }[]).map((s) => s.code);
    expect(codes).toEqual([a]);
    // The row carries what the standee encodes, composed by the same function
    // the vendor CSV uses — a rep looking at the list sees the real URL.
    expect(res.body.standees[0].url).toBe(`${RESOLVER_BASE}/r/${a}`);
  });

  it('sorts usable stock first — a retired standee sinks below a free one', async () => {
    const admin = await makeUser('ADMIN');
    const rep = await makeUser('SALES_REP');
    const codes = await mintCodes(3);
    // Assign in code order, then retire the FIRST one, so a plain sort by code
    // would put the useless row at the top.
    for (const code of codes) {
      await request(app)
        .post(`/admin/qr-codes/${code}/assignment`)
        .set(admin.auth)
        .send({ repUserId: rep.id });
    }
    await QrCode.updateOne({ code: codes[0] }, { $set: { state: 'RETIRED' } }).exec();

    const res = await request(app).get('/rep/standees').set(rep.auth);
    expect(res.status).toBe(200);

    const rows = res.body.standees as { code: string; state: string }[];
    expect(rows.map((r) => r.state)).toEqual(['UNASSIGNED', 'UNASSIGNED', 'RETIRED']);
    expect(rows[rows.length - 1].code).toBe(codes[0]);
  });
});

describe('GET /rep/standees/:code/qr', () => {
  it('renders the sheet for the rep holding the code', async () => {
    const admin = await makeUser('ADMIN');
    const rep = await makeUser('SALES_REP');
    const [code] = await mintCodes(1);

    await request(app)
      .post(`/admin/qr-codes/${code}/assignment`)
      .set(admin.auth)
      .send({ repUserId: rep.id });

    const res = await request(app)
      .get(`/rep/standees/${code}/qr`)
      .query({ format: 'pdf' })
      .set(rep.auth)
      .buffer()
      .parse((r, cb) => {
        const chunks: Buffer[] = [];
        r.on('data', (c: Buffer) => chunks.push(c));
        r.on('end', () => cb(null, Buffer.concat(chunks)));
      });

    expect(res.status).toBe(200);
    expect(res.headers['content-type']).toContain('application/pdf');
    expect(res.headers['content-disposition']).toContain(code.toLowerCase());
  });

  it('gives a non-holder the SAME 404 a nonexistent code gives', async () => {
    const admin = await makeUser('ADMIN');
    const holder = await makeUser('SALES_REP');
    const other = await makeUser('SALES_REP');
    const [code] = await mintCodes(1);

    await request(app)
      .post(`/admin/qr-codes/${code}/assignment`)
      .set(admin.auth)
      .send({ repUserId: holder.id });

    const mine = await request(app).get(`/rep/standees/${code}/qr`).set(other.auth);
    const nonexistent = await request(app).get('/rep/standees/ZZZZ9999/qr').set(other.auth);

    // Byte-identical answers: the endpoint must not reveal that the code exists.
    expect(mine.status).toBe(404);
    expect(mine.body.code).toBe('CODE_NOT_FOUND');
    expect(nonexistent.status).toBe(404);
    expect(nonexistent.body.code).toBe(mine.body.code);
  });
});

describe('assignment is ADVISORY, not a reservation', () => {
  it('lets a DIFFERENT rep activate a code assigned to someone else', async () => {
    const admin = await makeUser('ADMIN');
    const holder = await makeUser('SALES_REP');
    const other = await makeUser('SALES_REP');
    const [code] = await mintCodes(1);

    await request(app)
      .post(`/admin/qr-codes/${code}/assignment`)
      .set(admin.auth)
      .send({ repUserId: holder.id });

    const res = await request(app)
      .post('/rep/activations')
      .set(other.auth)
      .send({ code, restaurantName: 'Not Their Standee', restaurantPhone: '+919000000001' });

    // 201 ACTIVATED. If this ever becomes a 409, assignment has silently turned
    // into a lock — which is a product decision, not a refactor, and it needs
    // the walk-up standee case below thought through again.
    expect(res.status).toBe(201);
    expect(res.body.outcome).toBe('ACTIVATED');
  });

  it('lets any rep activate a standee nobody was assigned', async () => {
    const rep = await makeUser('SALES_REP');
    const [code] = await mintCodes(1);

    const res = await request(app)
      .post('/rep/activations')
      .set(rep.auth)
      .send({ code, restaurantName: 'Walk Up', restaurantPhone: '+919000000002' });

    expect(res.status).toBe(201);
    expect(res.body.outcome).toBe('ACTIVATED');
  });
});

describe('a used standee leaves the folder', () => {
  it('drops off the rep list the moment it is activated', async () => {
    const admin = await makeUser('ADMIN');
    const rep = await makeUser('SALES_REP');
    const [free, used] = await mintCodes(2);
    for (const code of [free, used]) {
      await request(app)
        .post(`/admin/qr-codes/${code}/assignment`)
        .set(admin.auth)
        .send({ repUserId: rep.id });
    }

    const before = await request(app).get('/rep/standees').set(rep.auth);
    expect((before.body.standees as unknown[]).length).toBe(2);

    // Driven through the REAL activation endpoint rather than by setting the
    // state by hand: the thing under test is that using a standee removes it,
    // and a test that wrote 'ACTIVE' itself would keep passing if activation
    // ever stopped setting it.
    const activated = await request(app)
      .post('/rep/activations')
      .set(rep.auth)
      .send({
        code: used,
        restaurantName: 'Blue Cafe',
        restaurantPhone: '+919876500900',
      });
    expect(activated.status).toBe(201);

    const after = await request(app).get('/rep/standees').set(rep.auth);
    const codes = (after.body.standees as { code: string }[]).map((s) => s.code);
    expect(codes).toEqual([free]);
  });

  it('leaves the assignment row intact, so the admin still sees where it went',
    async () => {
      const admin = await makeUser('ADMIN');
      const rep = await makeUser('SALES_REP');
      const [code] = await mintCodes(1);
      await request(app)
        .post(`/admin/qr-codes/${code}/assignment`)
        .set(admin.auth)
        .send({ repUserId: rep.id });

      await request(app)
        .post('/rep/activations')
        .set(rep.auth)
        .send({
          code,
          restaurantName: 'Red Kitchen',
          restaurantPhone: '+919876500901',
        });

      // HIDDEN FROM THE REP, NOT UNASSIGNED. "Where did this run go" is a
      // question the admin batch view answers off this field; clearing it on
      // activation would make a used code read as though nobody ever held it.
      const row = await QrCode.findOne({ code }).lean().exec();
      expect(String(row!.assignedToUserId)).toBe(rep.id);
      expect(row!.state).toBe('ACTIVE');
    });

  it('keeps a RETIRED standee on the list — the rep still holds the paper', async () => {
    const admin = await makeUser('ADMIN');
    const rep = await makeUser('SALES_REP');
    const [code] = await mintCodes(1);
    await request(app)
      .post(`/admin/qr-codes/${code}/assignment`)
      .set(admin.auth)
      .send({ repUserId: rep.id });
    await QrCode.updateOne({ code }, { $set: { state: 'RETIRED' } }).exec();

    const res = await request(app).get('/rep/standees').set(rep.auth);

    // Deliberately NOT filtered with ACTIVE. A retired sheet is still in the
    // folder, and the row labelled "Retired" is the only thing telling the rep
    // to bin it — hiding it leaves them carrying dead paper to a table.
    expect((res.body.standees as { code: string }[]).map((s) => s.code)).toEqual([code]);
  });

  it('an emptied folder reads as empty, not as a list of used codes', async () => {
    const admin = await makeUser('ADMIN');
    const rep = await makeUser('SALES_REP');
    const [code] = await mintCodes(1);
    await request(app)
      .post(`/admin/qr-codes/${code}/assignment`)
      .set(admin.auth)
      .send({ repUserId: rep.id });
    await request(app)
      .post('/rep/activations')
      .set(rep.auth)
      .send({
        code,
        restaurantName: 'Green Grill',
        restaurantPhone: '+919876500902',
      });

    const res = await request(app).get('/rep/standees').set(rep.auth);

    // The empty state is the honest answer here: a rep who has used everything
    // needs more stock, and a folder of spent codes hid that.
    expect(res.body.standees).toEqual([]);
  });
});

describe('GET /rep/published — what this rep has put live', () => {
  /** Activates `code` for `rep`, and optionally takes the menu live. */
  async function signUp(
    rep: { auth: { Authorization: string } },
    code: string,
    phone: string,
    name: string,
    { publish = true }: { publish?: boolean } = {}
  ): Promise<string> {
    const res = await request(app)
      .post('/rep/activations')
      .set(rep.auth)
      // BOTH names, exactly as the rep app sends them. `restaurantName` is
      // slugged server-side because it doubles as the Mirage key, so
      // `businessName` is the only field that keeps what the rep typed.
      .send({
        code,
        restaurantName: name,
        restaurantPhone: phone,
        businessName: name,
      });
    expect(res.status).toBe(201);
    const catalogId = res.body.catalogId as string;
    if (publish) {
      await Catalog.updateOne(
        { _id: new Types.ObjectId(catalogId) },
        { $set: { status: 'PUBLISHED' } }
      ).exec();
    }
    return catalogId;
  }

  it('lists a standee whose menu is live, with the restaurant name', async () => {
    const admin = await makeUser('ADMIN');
    const rep = await makeUser('SALES_REP');
    const [code] = await mintCodes(1);
    await request(app)
      .post(`/admin/qr-codes/${code}/assignment`)
      .set(admin.auth)
      .send({ repUserId: rep.id });
    await signUp(rep, code, '+919876511001', 'Blue Cafe');

    const res = await request(app).get('/rep/published').set(rep.auth);

    expect(res.status).toBe(200);
    expect(res.body.standees).toHaveLength(1);
    expect(res.body.standees[0].code).toBe(code);
    // The HUMAN name. `name` is slugified at activation (blue_cafe), so a list
    // built on it alone would show reps slugs.
    expect(res.body.standees[0].businessName).toBe('Blue Cafe');
    // The same string the standee encodes and the same one frozen into
    // catalog.publicUrl — one URL, so the QR and the menu link cannot drift.
    expect(res.body.standees[0].url).toBe(`${RESOLVER_BASE}/r/${code}`);
    expect(res.body.total).toBe(1);
  });

  it('falls back to the slug for a catalog with no business name', async () => {
    const rep = await makeUser('SALES_REP');
    const [code] = await mintCodes(1);
    const catalogId = await signUp(rep, code, '+919876511020', 'Legacy Cafe');
    // Rows created before the client started sending a business name. The
    // list must still render them — as the slug, which is ugly and honest —
    // rather than showing a blank where a restaurant should be.
    await Catalog.updateOne(
      { _id: new Types.ObjectId(catalogId) },
      { $unset: { businessName: '' } }
    ).exec();

    const res = await request(app).get('/rep/published').set(rep.auth);

    expect(res.body.standees[0].businessName).toBeNull();
    expect(res.body.standees[0].name).toBe('legacy_cafe');
  });

  it('EXCLUDES an activated standee whose menu is not live yet', async () => {
    const rep = await makeUser('SALES_REP');
    const [code] = await mintCodes(1);
    await signUp(rep, code, '+919876511002', 'Not Live Yet', { publish: false });

    const res = await request(app).get('/rep/published').set(rep.auth);

    // Activation BINDS a standee; publishing puts the menu online, sometimes
    // much later. Conflating them would put every signed-up restaurant in a
    // list titled with the word published.
    expect(res.body.standees).toEqual([]);
    expect(res.body.total).toBe(0);
  });

  it('shows only the caller history, never another rep', async () => {
    const mine = await makeUser('SALES_REP');
    const theirs = await makeUser('SALES_REP');
    const [a, b] = await mintCodes(2);
    await signUp(mine, a, '+919876511003', 'Mine');
    await signUp(theirs, b, '+919876511004', 'Theirs');

    const res = await request(app).get('/rep/published').set(mine.auth);

    expect(
      (res.body.standees as { businessName: string }[]).map((s) => s.businessName)
    ).toEqual(['Mine']);
  });

  it('survives losing access to the restaurant', async () => {
    const rep = await makeUser('SALES_REP');
    const [code] = await mintCodes(1);
    const catalogId = await signUp(rep, code, '+919876511005', 'Revoked Cafe');
    await CatalogDelegation.updateMany(
      { catalogId: new Types.ObjectId(catalogId) },
      { $set: { revokedAt: new Date() } }
    ).exec();

    const res = await request(app).get('/rep/published').set(rep.auth);

    // KEYED ON WHO ACTIVATED IT, not on delegation. Delegation is revocable
    // current access; having signed a restaurant up is a fact about the past,
    // and a history that vanished when access changed would be the wrong list.
    expect(res.body.standees).toHaveLength(1);
  });

  it('filters by window, and keeps the all-time total intact', async () => {
    const rep = await makeUser('SALES_REP');
    const [recent, old] = await mintCodes(2);
    await signUp(rep, recent, '+919876511006', 'Recent Cafe');
    await signUp(rep, old, '+919876511007', 'Old Cafe');
    // Backdated past any window the screen offers.
    await QrCode.updateOne(
      { code: old },
      { $set: { activatedAt: new Date(Date.now() - 60 * 24 * 60 * 60 * 1000) } }
    ).exec();

    const res = await request(app).get('/rep/published?days=7').set(rep.auth);

    expect(
      (res.body.standees as { code: string }[]).map((s) => s.code)
    ).toEqual([recent]);
    // "How many have I put live" must not change when somebody taps a filter.
    expect(res.body.total).toBe(2);
  });

  it('rejects a nonsense window rather than guessing', async () => {
    const rep = await makeUser('SALES_REP');

    const res = await request(app).get('/rep/published?days=nope').set(rep.auth);

    expect(res.status).toBe(400);
    expect(res.body.code).toBe('INVALID_REQUEST');
  });

  it('newest first, so the last visit is at the top', async () => {
    const rep = await makeUser('SALES_REP');
    const [first, second] = await mintCodes(2);
    await signUp(rep, first, '+919876511008', 'First');
    await signUp(rep, second, '+919876511009', 'Second');
    await QrCode.updateOne(
      { code: first },
      { $set: { activatedAt: new Date(Date.now() - 5 * 24 * 60 * 60 * 1000) } }
    ).exec();

    const res = await request(app).get('/rep/published').set(rep.auth);

    expect(
      (res.body.standees as { businessName: string }[]).map((s) => s.businessName)
    ).toEqual(['Second', 'First']);
  });

  it('is closed to a plain USER', async () => {
    const user = await makeUser('USER');
    const res = await request(app).get('/rep/published').set(user.auth);
    expect(res.status).toBe(403);
  });
});

describe('the rep sheet download follows ownership, not just assignment', () => {
  it('renders for a code this rep activated but was never assigned', async () => {
    const rep = await makeUser('SALES_REP');
    const [code] = await mintCodes(1);
    // A walk-up standee: nobody assigned it, the rep used it anyway.
    await request(app)
      .post('/rep/activations')
      .set(rep.auth)
      .send({
        code,
        restaurantName: 'Walk Up',
        restaurantPhone: '+919876511030',
        businessName: 'Walk Up',
      });

    const res = await request(app).get(`/rep/standees/${code}/qr`).set(rep.auth);

    // The published list offers a download on every row it shows, so the
    // authorization behind it has to cover every row it can show.
    expect(res.status).toBe(200);
  });

  it('still 404s for a rep with no claim on the code at all', async () => {
    const admin = await makeUser('ADMIN');
    const mine = await makeUser('SALES_REP');
    const stranger = await makeUser('SALES_REP');
    const [code] = await mintCodes(1);
    await request(app)
      .post(`/admin/qr-codes/${code}/assignment`)
      .set(admin.auth)
      .send({ repUserId: mine.id });

    const res = await request(app).get(`/rep/standees/${code}/qr`).set(stranger.auth);

    // Widening to "held OR activated" must not have opened a third door.
    expect(res.status).toBe(404);
  });
});
