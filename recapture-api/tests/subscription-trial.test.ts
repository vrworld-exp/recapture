// tests/subscription-trial.test.ts
//
// Door 1: a rep (or an admin) starts the one free trial a restaurant gets.
//
// What this file most exists to pin:
//   • ONE TRIAL, EVER. Two reps tapping at once end with one TRIAL row; a
//     second attempt later is a 409; a trial on a catalog the owner has since
//     deleted still counts (D2).
//   • THE BODY IS NOT AN INPUT. A plan or a duration in the request is a 400.
//   • THE TWO DOORS ANSWER IDENTICALLY, and the rep's is bounded by the
//     delegation exactly like every other rep write.
import { describe, it, expect, beforeAll, afterAll, beforeEach, afterEach, vi } from 'vitest';
import request from 'supertest';
import mongoose, { Types } from 'mongoose';
import jwt from 'jsonwebtoken';
import { MongoMemoryServer } from 'mongodb-memory-server';

import { createApp } from '@/app';
import { env } from '@/config/env';
import { Catalog } from '@/models/Catalog';
import { CatalogDelegation } from '@/models/CatalogDelegation';
import { CatalogSubscription } from '@/models/CatalogSubscription';
import { ClientConfig } from '@/models/ClientConfig';
import { PaymentRecord } from '@/models/PaymentRecord';
import { RateWindow } from '@/models/RateWindow';
import { User, type UserRole } from '@/models/User';
import { startTrial } from '@/services/subscription/subscriptionService';

const app = createApp();
let mongod: MongoMemoryServer;

beforeAll(async () => {
  mongod = await MongoMemoryServer.create();
  await mongoose.connect(mongod.getUri());
  await Catalog.syncIndexes();
  await CatalogSubscription.syncIndexes();
  await CatalogDelegation.syncIndexes();
});

afterAll(async () => {
  await mongoose.disconnect();
  await mongod.stop();
});

beforeEach(() => {
  vi.spyOn(console, 'log').mockImplementation(() => {});
  vi.spyOn(console, 'warn').mockImplementation(() => {});
});

afterEach(async () => {
  vi.restoreAllMocks();
  await Promise.all([
    User.deleteMany({}),
    Catalog.deleteMany({}),
    CatalogDelegation.deleteMany({}),
    CatalogSubscription.deleteMany({}),
    ClientConfig.deleteMany({}),
    PaymentRecord.deleteMany({}),
    RateWindow.deleteMany({}),
  ]);
});

const DAY_MS = 86_400_000;
type Auth = { Authorization: string };

async function makeUser(role: UserRole = 'USER'): Promise<{ id: Types.ObjectId; auth: Auth }> {
  const user = await User.create({
    authProvider: 'custom',
    authUid: `test|${new Types.ObjectId().toHexString()}`,
    role,
  });
  const token = jwt.sign({ userId: user.id, authUid: user.authUid }, env.JWT_SECRET, {
    expiresIn: '15m',
  });
  return { id: user._id as Types.ObjectId, auth: { Authorization: `Bearer ${token}` } };
}

/** An owner, a rep holding their catalog, and the catalog. */
async function delegated() {
  const owner = await makeUser();
  const rep = await makeUser('SALES_REP');
  const catalog = await Catalog.create({
    userId: owner.id,
    name: `cafe_${new Types.ObjectId().toHexString()}`,
    status: 'DRAFT',
  });
  const catalogId = catalog._id as Types.ObjectId;
  await CatalogDelegation.create({
    repUserId: rep.id,
    catalogId,
    grantedAt: new Date(),
    revokedAt: null,
  });
  return { owner, rep, catalogId };
}

const trialPath = (id: Types.ObjectId | string) => `/rep/catalogs/${id}/subscription/trial`;

function emitted(name: string): Record<string, unknown>[] {
  return vi
    .mocked(console.log)
    .mock.calls.filter((c) => String(c[0]).includes(`[analytics] ${name}`))
    .map((c) => JSON.parse(String(c[1])) as Record<string, unknown>);
}

describe('POST /rep/catalogs/:id/subscription/trial', () => {
  it('starts a 30-day, 10-dish trial on the spot (AC-2.3, AC-2.5)', async () => {
    const { rep, catalogId } = await delegated();

    const res = await request(app).post(trialPath(catalogId)).set(rep.auth);

    expect(res.status).toBe(201);
    expect(res.body.status).toBe('success');
    expect(res.body.subscription).toMatchObject({
      status: 'TRIAL',
      planId: null,
      planName: null,
      threeDDishCap: 10,
      daysLeft: 30,
      trialAvailable: false,
      isEntitledTo3D: true,
    });

    const row = await CatalogSubscription.findOne({ catalogId }).lean().exec();
    expect(row).toMatchObject({ status: 'TRIAL', source: 'TRIAL', threeDDishCap: 10 });
    expect(row!.periodEnd.getTime() - row!.periodStart.getTime()).toBe(30 * DAY_MS);
    expect(row!.trialUsedAt).toBeInstanceOf(Date);
    expect(row!.trialActivatedBy).toMatchObject({ role: 'SALES_REP' });
    expect(String(row!.trialActivatedBy!.userId)).toBe(String(rep.id));
    expect(String(row!.userId)).toBe(String((await Catalog.findById(catalogId))!.userId));

    expect(emitted('subscription_trial_started')).toEqual([
      expect.objectContaining({
        catalog_id: catalogId.toHexString(),
        actor_role: 'SALES_REP',
        door: 'REP',
      }),
    ]);
  });

  it('refuses the second attempt with 409 TRIAL_ALREADY_USED — after the trial lapses (AC-2.4)', async () => {
    const { rep, catalogId } = await delegated();
    await request(app).post(trialPath(catalogId)).set(rep.auth).expect(201);

    // While the trial is live, the refusal says so.
    const live = await request(app).post(trialPath(catalogId)).set(rep.auth);
    expect(live.status).toBe(409);
    expect(live.body).toMatchObject({
      status: 'error',
      code: 'SUBSCRIPTION_ACTIVE',
      message: 'This restaurant already has an active subscription.',
    });

    // Once it has lapsed (the Stage 5 sweep will do this), "already used".
    await CatalogSubscription.updateOne({ catalogId }, { $set: { status: 'PAUSED' } });
    const again = await request(app).post(trialPath(catalogId)).set(rep.auth);
    expect(again.status).toBe(409);
    expect(again.body).toMatchObject({
      code: 'TRIAL_ALREADY_USED',
      message: 'This restaurant has already used its free trial.',
    });
    expect(await CatalogSubscription.countDocuments({ catalogId })).toBe(1);
    expect(emitted('subscription_trial_refused').map((e) => e.reason)).toEqual([
      'ACTIVE',
      'ALREADY_USED',
    ]);
  });

  it('two reps at once: one STARTED, one SUBSCRIPTION_ACTIVE, one row (A5)', async () => {
    const { owner, catalogId } = await delegated();
    const repA = await makeUser('SALES_REP');
    const repB = await makeUser('SALES_REP');

    const [a, b] = await Promise.all([
      startTrial(catalogId, owner.id, { userId: repA.id, role: 'SALES_REP' }, 'REP'),
      startTrial(catalogId, owner.id, { userId: repB.id, role: 'SALES_REP' }, 'REP'),
    ]);

    expect([a.outcome, b.outcome].sort()).toEqual(['STARTED', 'SUBSCRIPTION_ACTIVE']);
    expect(await CatalogSubscription.countDocuments({ catalogId })).toBe(1);
    const row = await CatalogSubscription.findOne({ catalogId }).lean().exec();
    expect(row?.status).toBe('TRIAL');
  });

  it('allows a trial on a CANCELLED comp that never had one (comped-then-cancelled)', async () => {
    const { rep, owner, catalogId } = await delegated();
    await CatalogSubscription.create({
      catalogId,
      userId: owner.id,
      status: 'CANCELLED',
      source: 'COMP',
      periodStart: new Date(Date.now() - 40 * DAY_MS),
      periodEnd: new Date(Date.now() - 10 * DAY_MS),
      threeDDishCap: -1,
      planId: undefined,
      cancelledAt: new Date(),
    });

    const res = await request(app).post(trialPath(catalogId)).set(rep.auth);

    expect(res.status).toBe(201);
    const row = await CatalogSubscription.findOne({ catalogId }).lean().exec();
    expect(row).toMatchObject({ status: 'TRIAL', source: 'TRIAL', threeDDishCap: 10 });
    expect(row?.trialUsedAt).toBeInstanceOf(Date);
  });

  it('refuses a PAUSED row whose trial was used, and a live row', async () => {
    const { rep, owner, catalogId } = await delegated();
    await CatalogSubscription.create({
      catalogId,
      userId: owner.id,
      status: 'PAUSED',
      source: 'TRIAL',
      periodStart: new Date(Date.now() - 40 * DAY_MS),
      periodEnd: new Date(Date.now() - 10 * DAY_MS),
      threeDDishCap: 10,
      trialUsedAt: new Date(Date.now() - 40 * DAY_MS),
    });
    const used = await request(app).post(trialPath(catalogId)).set(rep.auth);
    expect(used.status).toBe(409);
    expect(used.body.code).toBe('TRIAL_ALREADY_USED');

    await CatalogSubscription.updateOne(
      { catalogId },
      { $set: { status: 'ACTIVE', planId: 'TASTE' }, $unset: { trialUsedAt: 1 } }
    );
    const active = await request(app).post(trialPath(catalogId)).set(rep.auth);
    expect(active.status).toBe(409);
    expect(active.body.code).toBe('SUBSCRIPTION_ACTIVE');
  });

  it('refuses an owner who has paid before (E41)', async () => {
    const { rep, owner, catalogId } = await delegated();
    await PaymentRecord.create({
      catalogId,
      userId: owner.id,
      subscriptionId: new Types.ObjectId(),
      kind: 'MANUAL',
      method: 'CASH',
      verificationStatus: 'VERIFIED',
      amountPaise: 119_900,
      initiatedBy: { userId: rep.id, role: 'SALES_REP' },
    });

    const res = await request(app).post(trialPath(catalogId)).set(rep.auth);

    expect(res.status).toBe(409);
    expect(res.body.code).toBe('TRIAL_NOT_ELIGIBLE');
    expect(await CatalogSubscription.countDocuments({})).toBe(0);

    // A PENDING manual entry is not a payment yet.
    await PaymentRecord.updateMany({}, { $set: { verificationStatus: 'PENDING_VERIFICATION' } });
    expect((await request(app).post(trialPath(catalogId)).set(rep.auth)).status).toBe(201);
  });

  it('refuses a body: the plan and the length are config, not input', async () => {
    const { rep, catalogId } = await delegated();

    const res = await request(app).post(trialPath(catalogId)).set(rep.auth).send({ days: 365 });

    expect(res.status).toBe(400);
    expect(res.body.code).toBe('INVALID_REQUEST');
    expect(await CatalogSubscription.countDocuments({})).toBe(0);
  });

  it('gives a rep without a delegation the same 404 as GET, identical body', async () => {
    const owner = await makeUser();
    const rep = await makeUser('SALES_REP');
    const catalog = await Catalog.create({ userId: owner.id, name: 'x', status: 'DRAFT' });

    const get = await request(app).get(`/rep/catalogs/${catalog._id}/subscription`).set(rep.auth);
    const post = await request(app).post(trialPath(catalog._id as Types.ObjectId)).set(rep.auth);

    expect(get.status).toBe(404);
    expect(post.status).toBe(404);
    expect(post.body).toEqual(get.body);
    expect(post.body.code).toBe('CATALOG_NOT_FOUND');
  });

  it('is rate limited per catalog', async () => {
    const { rep, catalogId } = await delegated();
    for (let i = 0; i < 5; i++) await request(app).post(trialPath(catalogId)).set(rep.auth);

    const res = await request(app).post(trialPath(catalogId)).set(rep.auth);
    expect(res.status).toBe(429);
    expect(res.body.code).toBe('RATE_LIMITED');
  });

  it('refuses a plain USER at the router gate', async () => {
    const user = await makeUser();
    const res = await request(app).post(trialPath(new Types.ObjectId())).set(user.auth);
    expect(res.status).toBe(403);
    expect(res.body.code).toBe('FORBIDDEN');
  });
});

describe('POST /admin/catalogs/:id/subscription/trial', () => {
  const adminPath = (id: Types.ObjectId | string) => `/admin/catalogs/${id}/subscription/trial`;

  it('lets an ADMIN start a trial with no delegation, with the same body shape', async () => {
    const admin = await makeUser('ADMIN');
    const owner = await makeUser();
    const catalog = await Catalog.create({ userId: owner.id, name: 'x', status: 'DRAFT' });

    const res = await request(app).post(adminPath(catalog._id as Types.ObjectId)).set(admin.auth);

    expect(res.status).toBe(201);
    expect(res.body.subscription).toMatchObject({ status: 'TRIAL', threeDDishCap: 10 });
    const row = await CatalogSubscription.findOne({ catalogId: catalog._id }).lean().exec();
    expect(row?.trialActivatedBy).toMatchObject({ role: 'ADMIN' });
    expect(emitted('subscription_trial_started')[0]).toMatchObject({ door: 'ADMIN' });
  });

  it('gives a SALES_REP 403 FORBIDDEN', async () => {
    const rep = await makeUser('SALES_REP');
    const res = await request(app).post(adminPath(new Types.ObjectId())).set(rep.auth);
    expect(res.status).toBe(403);
    expect(res.body.code).toBe('FORBIDDEN');
    // MODEL_ARTIST passes the router but not the route.
    const artist = await makeUser('MODEL_ARTIST');
    expect((await request(app).post(adminPath(new Types.ObjectId())).set(artist.auth)).status).toBe(
      403
    );
  });

  it('answers 404 CATALOG_NOT_FOUND for an unknown, malformed or deleted id', async () => {
    const admin = await makeUser('ADMIN');
    const owner = await makeUser();
    const gone = await Catalog.create({
      userId: owner.id,
      name: 'x',
      status: 'DRAFT',
      deletedAt: new Date(),
    });

    for (const id of [new Types.ObjectId().toHexString(), 'not-an-id', String(gone._id)]) {
      const res = await request(app).post(adminPath(id)).set(admin.auth);
      expect(res.status).toBe(404);
      expect(res.body.code).toBe('CATALOG_NOT_FOUND');
    }
  });

  it('answers the same 409s as the rep door', async () => {
    const admin = await makeUser('ADMIN');
    const { rep, catalogId } = await delegated();
    await request(app).post(trialPath(catalogId)).set(rep.auth).expect(201);

    const viaAdmin = await request(app).post(adminPath(catalogId)).set(admin.auth);
    const viaRep = await request(app).post(trialPath(catalogId)).set(rep.auth);

    expect(viaAdmin.status).toBe(409);
    expect(viaAdmin.body).toEqual(viaRep.body);
  });
});
