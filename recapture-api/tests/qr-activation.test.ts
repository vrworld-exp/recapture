// tests/qr-activation.test.ts
//
// Stage 4: a rep turns a printed standee into a live catalog.
//
// TWO ASSERTIONS HERE CARRY THE SUITE.
//
// The first is CONCURRENCY: two reps scanning the same standee must produce one
// winner and one clean 409, one ACTIVE code, one assignment row and one
// delegation. There is no transaction anywhere in this path — the conditional
// update's guard IS the mutual exclusion — so this test is the only thing that
// proves the guard is actually doing that job.
//
// The second is PHONE NORMALISATION ROUND-TRIPPING THROUGH OTP. Activation
// stores `User.phone` on the rep's word; the owner later signs in with that
// number and verifyOtpService looks the user up by the exact string. If the two
// normalise differently the owner lands on a SECOND, empty account and their
// catalog is stranded behind an orphan user with no way back — silent, and
// unrecoverable without a migration.
import { describe, it, expect, beforeAll, afterAll, beforeEach, afterEach, vi } from 'vitest';
import request from 'supertest';
import mongoose, { Types } from 'mongoose';
import jwt from 'jsonwebtoken';
import { MongoMemoryServer } from 'mongodb-memory-server';

import { createApp } from '@/app';
import { env } from '@/config/env';
import { User, type UserRole } from '@/models/User';
import { Catalog } from '@/models/Catalog';
import { CatalogDelegation } from '@/models/CatalogDelegation';
import { QrCode } from '@/models/QrCode';
import { QrCodeAssignment } from '@/models/QrCodeAssignment';
import { RateWindow } from '@/models/RateWindow';
import { OtpCode } from '@/models/OtpCode';
import { VerifyThrottle } from '@/models/VerifyThrottle';
import { RefreshToken } from '@/models/RefreshToken';

const app = createApp();
let mongod: MongoMemoryServer;

const RESOLVER_BASE = 'https://scan.test';

beforeAll(async () => {
  mongod = await MongoMemoryServer.create();
  await mongoose.connect(mongod.getUri());
  // Three indexes are load-bearing in this suite and all three must really
  // exist: the code's uniqueness, the one-catalog-per-user rule the activation
  // upsert leans on, and the partial unique index that makes the delegation
  // grant idempotent.
  await QrCode.syncIndexes();
  await Catalog.syncIndexes();
  await CatalogDelegation.syncIndexes();
});

afterAll(async () => {
  await mongoose.disconnect();
  await mongod.stop();
});

beforeEach(() => {
  Object.assign(env, { PUBLIC_RESOLVER_BASE_URL: RESOLVER_BASE });
  vi.spyOn(console, 'log').mockImplementation(() => {});
  vi.spyOn(console, 'warn').mockImplementation(() => {});
});

afterEach(async () => {
  vi.restoreAllMocks();
  await Promise.all([
    User.deleteMany({}),
    Catalog.deleteMany({}),
    CatalogDelegation.deleteMany({}),
    QrCode.deleteMany({}),
    QrCodeAssignment.deleteMany({}),
    RateWindow.deleteMany({}),
    OtpCode.deleteMany({}),
    VerifyThrottle.deleteMany({}),
    RefreshToken.deleteMany({}),
  ]);
});

/** A real user doc (requireRole reads the DB) plus its Bearer header. */
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

async function mint(code: string): Promise<Types.ObjectId> {
  const doc = await QrCode.create({
    code,
    batchId: new Types.ObjectId(),
    state: 'UNASSIGNED',
    deletedAt: null,
  });
  return doc._id as Types.ObjectId;
}

const activation = (code: string, phone = '+919876543210') => ({
  code,
  restaurantName: 'Blue Cafe',
  restaurantPhone: phone,
});

describe('POST /rep/activations — the happy path', () => {
  it('creates the restaurant, its catalog, the mapping and the grant', async () => {
    const { auth, id: repId } = await makeUser('SALES_REP');
    await mint('ABCD2345');

    const res = await request(app).post('/rep/activations').set(auth).send(activation('ABCD2345'));

    expect(res.status).toBe(201);
    expect(res.body.outcome).toBe('ACTIVATED');

    const owner = await User.findOne({ phone: '+919876543210' }).exec();
    expect(owner).not.toBeNull();
    // THE RESTAURANT OWNS THE CATALOG — not the rep. Everything downstream
    // (the unique index on userId, every userId-scoped query, resolveOwnedModel)
    // depends on this one field.
    const catalog = await Catalog.findOne({ userId: owner!._id }).exec();
    expect(catalog).not.toBeNull();
    expect(String(catalog!._id)).toBe(res.body.catalogId);
    expect(catalog!.userId.equals(owner!._id as Types.ObjectId)).toBe(true);

    const qr = await QrCode.findOne({ code: 'ABCD2345' }).exec();
    expect(qr!.state).toBe('ACTIVE');
    expect(qr!.catalogId!.equals(catalog!._id as Types.ObjectId)).toBe(true);
    expect(qr!.currentAssignmentId).toBeDefined();
    expect(String(qr!.activatedByUserId)).toBe(repId);

    const grant = await CatalogDelegation.findOne({ catalogId: catalog!._id }).exec();
    expect(String(grant!.repUserId)).toBe(repId);
    expect(grant!.revokedAt).toBeNull();
  });

  it('leaves the restaurant UNVERIFIED — a rep vouched, nobody proved possession', async () => {
    const { auth } = await makeUser('SALES_REP');
    await mint('BBBB2222');

    await request(app).post('/rep/activations').set(auth).send(activation('BBBB2222'));

    const owner = await User.findOne({ phone: '+919876543210' }).exec();
    expect(owner!.phoneVerified).toBe(false);
    expect(owner!.role).toBe('USER');
  });

  it('freezes publicUrl as the standee URL, byte-identical to the print CSV', async () => {
    const { auth } = await makeUser('SALES_REP');
    await mint('CCCC3333');

    const res = await request(app).post('/rep/activations').set(auth).send(activation('CCCC3333'));

    // The exact string qrCodeService.exportBatchCsv emits for this code. These
    // three — the CSV, the stored URL and what the resolver accepts — must stay
    // byte-identical or a printed code resolves to nothing.
    const expected = `${RESOLVER_BASE}/r/CCCC3333`;
    expect(res.body.publicUrl).toBe(expected);
    const catalog = await Catalog.findById(res.body.catalogId).exec();
    expect(catalog!.publicUrl).toBe(expected);
    expect(catalog!.publicUrlScheme).toBe('RECAPTURE_SHORT_CODE');
  });

  it('accepts the printed form of a code — lowercase and hyphenated', async () => {
    const { auth } = await makeUser('SALES_REP');
    await mint('DDDD4444');

    const res = await request(app)
      .post('/rep/activations')
      .set(auth)
      .send(activation('dddd-4444'));

    expect(res.status).toBe(201);
    expect((await QrCode.findOne({ code: 'DDDD4444' }).exec())!.state).toBe('ACTIVE');
  });
});

describe('concurrency — the conditional claim IS the lock', () => {
  it('produces exactly one winner and one clean 409', async () => {
    // THE STAGE'S HEADLINE TEST. Two reps, one physical standee, no
    // transaction anywhere in the path.
    const repA = await makeUser('SALES_REP');
    const repB = await makeUser('SALES_REP');
    await mint('EEEE5555');

    const [a, b] = await Promise.all([
      request(app)
        .post('/rep/activations')
        .set(repA.auth)
        .send({ ...activation('EEEE5555'), restaurantPhone: '+919000000001' }),
      request(app)
        .post('/rep/activations')
        .set(repB.auth)
        .send({ ...activation('EEEE5555'), restaurantPhone: '+919000000002' }),
    ]);

    const statuses = [a.status, b.status].sort();
    expect(statuses).toEqual([201, 409]);

    const codes = await QrCode.find({ code: 'EEEE5555' }).exec();
    expect(codes).toHaveLength(1);
    expect(codes[0].state).toBe('ACTIVE');

    expect(await QrCodeAssignment.countDocuments({ qrCodeId: codes[0]._id })).toBe(1);
    expect(await CatalogDelegation.countDocuments({ catalogId: codes[0].catalogId })).toBe(1);
  });
});

describe('idempotency', () => {
  it('re-running the same activation returns ALREADY_ACTIVE and changes nothing', async () => {
    const { auth } = await makeUser('SALES_REP');
    await mint('FFFF6666');

    const first = await request(app)
      .post('/rep/activations')
      .set(auth)
      .send(activation('FFFF6666'));
    const second = await request(app)
      .post('/rep/activations')
      .set(auth)
      .send(activation('FFFF6666'));

    expect(first.status).toBe(201);
    expect(second.status).toBe(200);
    expect(second.body.outcome).toBe('ALREADY_ACTIVE');
    expect(second.body.publicUrl).toBe(first.body.publicUrl);
    expect(second.body.catalogId).toBe(first.body.catalogId);

    // No second assignment, no second grant — a re-run REPAIRS a half-finished
    // activation, it does not duplicate a finished one.
    const qr = await QrCode.findOne({ code: 'FFFF6666' }).exec();
    expect(await QrCodeAssignment.countDocuments({ qrCodeId: qr!._id })).toBe(1);
    expect(await CatalogDelegation.countDocuments({ catalogId: qr!.catalogId })).toBe(1);
    expect(await User.countDocuments({ phone: '+919876543210' })).toBe(1);
  });

  it('refuses a code already live on a DIFFERENT restaurant, creating nothing', async () => {
    const { auth } = await makeUser('SALES_REP');
    await mint('GGGG7777');
    await request(app).post('/rep/activations').set(auth).send(activation('GGGG7777'));

    const usersBefore = await User.countDocuments({});
    const catalogsBefore = await Catalog.countDocuments({});

    const res = await request(app)
      .post('/rep/activations')
      .set(auth)
      .send({ ...activation('GGGG7777'), restaurantPhone: '+919111111111' });

    expect(res.status).toBe(409);
    expect(res.body.code).toBe('CODE_UNAVAILABLE');
    // A mistyped code must not leave an orphan account behind.
    expect(await User.countDocuments({})).toBe(usersBefore);
    expect(await Catalog.countDocuments({})).toBe(catalogsBefore);
  });

  it('reuses an existing account rather than creating a second one', async () => {
    const { auth } = await makeUser('SALES_REP');
    const existing = await User.create({
      authProvider: 'custom',
      authUid: `test|${new Types.ObjectId().toHexString()}`,
      phone: '+919876543210',
      phoneVerified: true,
    });
    await mint('HHHH8888');

    const res = await request(app).post('/rep/activations').set(auth).send(activation('HHHH8888'));

    expect(res.status).toBe(201);
    expect(await User.countDocuments({ phone: '+919876543210' })).toBe(1);
    const catalog = await Catalog.findById(res.body.catalogId).exec();
    expect(catalog!.userId.equals(existing._id as Types.ObjectId)).toBe(true);
    // An already-verified owner is not un-verified by a rep re-signing them.
    expect((await User.findById(existing._id).exec())!.phoneVerified).toBe(true);
  });

  it('a RETIRED code cannot be activated', async () => {
    const { auth } = await makeUser('SALES_REP');
    await mint('JJJJ9999');
    await QrCode.updateOne({ code: 'JJJJ9999' }, { state: 'RETIRED' }).exec();

    const res = await request(app).post('/rep/activations').set(auth).send(activation('JJJJ9999'));

    expect(res.status).toBe(409);
    expect(res.body.code).toBe('CODE_UNAVAILABLE');
  });

  it('an unminted code is a 404, not an activation', async () => {
    const { auth } = await makeUser('SALES_REP');

    const res = await request(app).post('/rep/activations').set(auth).send(activation('KKKK0000'));

    expect(res.status).toBe(404);
    expect(res.body.code).toBe('CODE_NOT_FOUND');
  });
});

describe('the owner sign-in hand-off', () => {
  it('an activated phone resolves to the SAME user through the real OTP flow', async () => {
    // THE TEST THAT CATCHES THE STRANDED-OWNER BUG. It runs the genuine
    // send-otp → verify-otp path, not a stub of it, so the two normalisers are
    // compared for real.
    const { auth } = await makeUser('SALES_REP');
    await mint('MMMM2222');

    // The rep types the number the way a human writes it on a form.
    const activated = await request(app)
      .post('/rep/activations')
      .set(auth)
      .send(activation('MMMM2222', '+91 98765-43210'));
    expect(activated.status).toBe(201);

    const created = await User.findOne({ phone: '+919876543210' }).exec();
    expect(created).not.toBeNull();
    expect(created!.phoneVerified).toBe(false);

    // The owner signs in weeks later with the same number, typed differently
    // again.
    const sent = await request(app)
      .post('/auth/send-otp')
      .send({ channel: 'sms', phone: '+91 9876543210' });
    expect(sent.status).toBe(200);

    const record = await OtpCode.findOne({ identifier: '+919876543210' }).exec();
    expect(record).not.toBeNull();
    expect(sent.body.devCode).toBeDefined();

    const verified = await request(app)
      .post('/auth/verify-otp')
      .send({ channel: 'sms', phone: '+919876543210', code: sent.body.devCode });
    expect(verified.status).toBe(200);
    // NOT a new user. The same _id, now verified — they simply ARE the owner.
    expect(verified.body.isNewUser).toBe(false);
    expect(await User.countDocuments({ phone: '+919876543210' })).toBe(1);

    const after = await User.findOne({ phone: '+919876543210' }).exec();
    expect(String(after!._id)).toBe(String(created!._id));
    expect(after!.phoneVerified).toBe(true);
    // And the catalog is still theirs — no claim step, no merge.
    const catalog = await Catalog.findOne({ userId: after!._id }).exec();
    expect(String(catalog!._id)).toBe(activated.body.catalogId);
  });
});

describe('guards that must fire before any write', () => {
  it('refuses with PUBLIC_RESOLVER_BASE_URL unset, touching nothing', async () => {
    const { auth } = await makeUser('SALES_REP');
    await mint('NNNN3333');
    Object.assign(env, { PUBLIC_RESOLVER_BASE_URL: undefined });

    const usersBefore = await User.countDocuments({});
    const res = await request(app).post('/rep/activations').set(auth).send(activation('NNNN3333'));

    expect(res.status).toBe(409);
    expect(res.body.code).toBe('RESOLVER_NOT_CONFIGURED');
    // Activating against a guessed host would freeze `undefined/r/NNNN3333`
    // onto the catalog permanently — publicUrl is the one field nothing may
    // rewrite.
    expect(await User.countDocuments({})).toBe(usersBefore);
    expect(await Catalog.countDocuments({})).toBe(0);
    expect(await CatalogDelegation.countDocuments({})).toBe(0);
    expect((await QrCode.findOne({ code: 'NNNN3333' }).exec())!.state).toBe('UNASSIGNED');
  });

  it('trips the per-rep rate limit at ACTIVATION_MAX_PER_WINDOW + 1', async () => {
    const { auth } = await makeUser('SALES_REP');
    Object.assign(env, { ACTIVATION_MAX_PER_WINDOW: 3, ACTIVATION_WINDOW_SECONDS: 3600 });

    const codes = ['PPPP4444', 'QQQQ5555', 'RRRR6666', 'SSSS7777'];
    for (const code of codes) await mint(code);

    const statuses: number[] = [];
    for (const [i, code] of codes.entries()) {
      const res = await request(app)
        .post('/rep/activations')
        .set(auth)
        .send(activation(code, `+91900000000${i}`));
      statuses.push(res.status);
    }

    expect(statuses.slice(0, 3)).toEqual([201, 201, 201]);
    expect(statuses[3]).toBe(429);
    // The window is per REP, and it applies to ADMIN too by role inheritance —
    // which is what makes that inheritance auditable rather than unbounded.
    expect((await QrCode.findOne({ code: 'SSSS7777' }).exec())!.state).toBe('UNASSIGNED');

    Object.assign(env, { ACTIVATION_MAX_PER_WINDOW: 30 });
  });

  it('rejects a phone that is not E.164 — the same rule the OTP flow applies', async () => {
    const { auth } = await makeUser('SALES_REP');
    await mint('TTTT8888');

    const res = await request(app)
      .post('/rep/activations')
      .set(auth)
      .send(activation('TTTT8888', '9876543210'));

    expect(res.status).toBe(400);
    expect(res.body.code).toBe('INVALID_REQUEST');
    expect(await User.countDocuments({ phone: { $ne: null } })).toBe(0);
  });

  it('rejects a body carrying a userId — never silently drops it', async () => {
    const { auth } = await makeUser('SALES_REP');
    await mint('VVVV9999');

    const res = await request(app)
      .post('/rep/activations')
      .set(auth)
      .send({ ...activation('VVVV9999'), userId: new Types.ObjectId().toHexString() });

    // Silently ignoring it would make a privilege-escalation attempt look like
    // a success.
    expect(res.status).toBe(400);
    expect((await QrCode.findOne({ code: 'VVVV9999' }).exec())!.state).toBe('UNASSIGNED');
  });
});

describe('GET /rep/codes/:code — the scanner preflight', () => {
  it('reports an unassigned code as available', async () => {
    const { auth } = await makeUser('SALES_REP');
    await mint('WWWW0000');

    const res = await request(app).get('/rep/codes/WWWW0000').set(auth);

    expect(res.status).toBe(200);
    expect(res.body).toMatchObject({ code: 'WWWW0000', state: 'UNASSIGNED', available: true });
  });

  it('reports an activated code as unavailable', async () => {
    const { auth } = await makeUser('SALES_REP');
    await mint('XXXX1111');
    await request(app).post('/rep/activations').set(auth).send(activation('XXXX1111'));

    const res = await request(app).get('/rep/codes/xxxx-1111').set(auth);

    expect(res.body).toMatchObject({ state: 'ACTIVE', available: false });
  });

  it('400s a code that could never exist, without querying', async () => {
    const { auth } = await makeUser('SALES_REP');
    const findOne = vi.spyOn(QrCode, 'findOne');

    const res = await request(app).get('/rep/codes/!!!').set(auth);

    expect(res.status).toBe(400);
    expect(findOne).not.toHaveBeenCalled();
  });
});
