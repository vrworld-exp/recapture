// tests/subscription-standees.test.ts
//
// G2 — the admin's "how many standees went out" counter. What this file pins:
//   • PATCH sets `standeeAllocation.issued`, bounded by `included` in the
//     same write (16 on a 15-plan → 422 EXCEEDS_INCLUDED; 6 → the DTO reads
//     `{ included: 15, issued: 6 }` on the owner's, the rep's and the admin's
//     reads alike).
//   • No plan (no row, or a trial that includes none) → 422.
//   • ADMIN only, `.strict()` body, audited.
import { describe, it, expect, beforeAll, afterAll, beforeEach, afterEach, vi } from 'vitest';
import request from 'supertest';
import mongoose, { Types } from 'mongoose';
import { MongoMemoryServer } from 'mongodb-memory-server';

import { createApp } from '@/app';
import { Catalog } from '@/models/Catalog';
import { CatalogDelegation } from '@/models/CatalogDelegation';
import { CatalogSubscription } from '@/models/CatalogSubscription';
import { PaymentRecord } from '@/models/PaymentRecord';
import { User } from '@/models/User';
import { DEFAULT_PLAN_CATALOG } from '@/config/subscriptionPlans';
import { delegated, emitted, seedSubscription } from './helpers/subscriptionPayments';

const app = createApp();
let mongod: MongoMemoryServer;

beforeAll(async () => {
  mongod = await MongoMemoryServer.create();
  await mongoose.connect(mongod.getUri());
  await Promise.all([
    Catalog.syncIndexes(),
    CatalogSubscription.syncIndexes(),
    CatalogDelegation.syncIndexes(),
  ]);
});

afterAll(async () => {
  await mongoose.disconnect();
  await mongod.stop();
});

beforeEach(() => {
  vi.spyOn(console, 'log').mockImplementation(() => {});
});

afterEach(async () => {
  vi.restoreAllMocks();
  await Promise.all([
    User.deleteMany({}),
    Catalog.deleteMany({}),
    CatalogDelegation.deleteMany({}),
    CatalogSubscription.deleteMany({}),
    PaymentRecord.deleteMany({}),
  ]);
});

const path = (id: Types.ObjectId | string) => `/admin/catalogs/${id}/subscription/standees`;

async function signaturePlan() {
  const ctx = await delegated();
  await seedSubscription(ctx.catalogId, ctx.owner.id, 'ACTIVE', {
    planId: 'SIGNATURE',
    planSnapshot: DEFAULT_PLAN_CATALOG.plans.SIGNATURE,
    billingInterval: 'MONTHLY',
    standeeAllocation: { included: 15, issued: 0 },
  });
  return ctx;
}

describe('PATCH /admin/catalogs/:id/subscription/standees', () => {
  it('sets issued and the three reads agree: owner, rep, admin', async () => {
    const { owner, rep, admin, catalogId } = await signaturePlan();

    const res = await request(app).patch(path(catalogId)).set(admin.auth).send({ issued: 6 });
    expect(res.status).toBe(200);
    expect(res.body.subscription.standeeAllocation).toEqual({ included: 15, issued: 6 });

    const [ownerRead, repRead, adminRead] = await Promise.all([
      request(app).get('/catalog/subscription').set(owner.auth),
      request(app).get(`/rep/catalogs/${catalogId}/subscription`).set(rep.auth),
      request(app).get(`/admin/catalogs/${catalogId}/subscription`).set(admin.auth),
    ]);
    for (const read of [ownerRead, repRead, adminRead]) {
      expect(read.status).toBe(200);
      expect(read.body.subscription.standeeAllocation).toEqual({ included: 15, issued: 6 });
    }

    expect(emitted('subscription_standees_issued')).toEqual([
      expect.objectContaining({ catalog_id: catalogId.toHexString(), issued: 6, included: 15 }),
    ]);
    expect(emitted('subscription_standees_issued')[0]!.admin_id_hash).toEqual(expect.any(String));
  });

  it('is an absolute count: a lower number is accepted (a standee came back)', async () => {
    const { admin, catalogId } = await signaturePlan();
    await request(app).patch(path(catalogId)).set(admin.auth).send({ issued: 10 });
    const res = await request(app).patch(path(catalogId)).set(admin.auth).send({ issued: 4 });
    expect(res.status).toBe(200);
    expect(res.body.subscription.standeeAllocation).toEqual({ included: 15, issued: 4 });
  });

  it('refuses more than the plan includes with 422 EXCEEDS_INCLUDED and leaves the row alone', async () => {
    const { admin, catalogId } = await signaturePlan();
    const res = await request(app).patch(path(catalogId)).set(admin.auth).send({ issued: 16 });
    expect(res.status).toBe(422);
    expect(res.body).toMatchObject({ status: 'error', code: 'EXCEEDS_INCLUDED', included: 15 });
    const row = await CatalogSubscription.findOne({ catalogId }).lean().exec();
    expect(row!.standeeAllocation).toEqual({ included: 15, issued: 0 });
    expect(emitted('subscription_standees_issued')).toEqual([]);
  });

  it('exactly `included` is allowed', async () => {
    const { admin, catalogId } = await signaturePlan();
    const res = await request(app).patch(path(catalogId)).set(admin.auth).send({ issued: 15 });
    expect(res.status).toBe(200);
    expect(res.body.subscription.standeeAllocation).toEqual({ included: 15, issued: 15 });
  });

  it('a catalog with no subscription row → 422 (it includes nothing)', async () => {
    const { admin, catalogId } = await delegated();
    const res = await request(app).patch(path(catalogId)).set(admin.auth).send({ issued: 1 });
    expect(res.status).toBe(422);
    expect(res.body).toMatchObject({ code: 'EXCEEDS_INCLUDED', included: 0 });
  });

  it('a trial (included: 0) → 422 for 1, 200 for 0', async () => {
    const { owner, admin, catalogId } = await delegated();
    await seedSubscription(catalogId, owner.id, 'TRIAL');
    const one = await request(app).patch(path(catalogId)).set(admin.auth).send({ issued: 1 });
    expect(one.status).toBe(422);
    const zero = await request(app).patch(path(catalogId)).set(admin.auth).send({ issued: 0 });
    expect(zero.status).toBe(200);
  });

  it('validates the body: negative, fractional, unknown keys and a missing count are 400', async () => {
    const { admin, catalogId } = await signaturePlan();
    for (const body of [{ issued: -1 }, { issued: 2.5 }, { issued: 3, extra: true }, {}, { note: 'x' }]) {
      const res = await request(app).patch(path(catalogId)).set(admin.auth).send(body);
      expect(res.status, JSON.stringify(body)).toBe(400);
    }
  });

  it('accepts an optional note', async () => {
    const { admin, catalogId } = await signaturePlan();
    const res = await request(app)
      .patch(path(catalogId))
      .set(admin.auth)
      .send({ issued: 2, note: 'Handed over at the launch visit' });
    expect(res.status).toBe(200);
  });

  it('is ADMIN only — the rep and the owner get 403', async () => {
    const { owner, rep, catalogId } = await signaturePlan();
    expect((await request(app).patch(path(catalogId)).set(rep.auth).send({ issued: 1 })).status).toBe(403);
    expect((await request(app).patch(path(catalogId)).set(owner.auth).send({ issued: 1 })).status).toBe(403);
  });

  it('404s an unknown or deleted catalog', async () => {
    const { admin, catalogId } = await signaturePlan();
    expect(
      (await request(app).patch(path(new Types.ObjectId())).set(admin.auth).send({ issued: 1 })).status
    ).toBe(404);
    expect((await request(app).patch(path('nope')).set(admin.auth).send({ issued: 1 })).status).toBe(404);
    await Catalog.updateOne({ _id: catalogId }, { $set: { deletedAt: new Date() } });
    expect((await request(app).patch(path(catalogId)).set(admin.auth).send({ issued: 1 })).status).toBe(404);
  });
});
