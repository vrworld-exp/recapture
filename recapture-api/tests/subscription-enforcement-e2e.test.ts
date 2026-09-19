// tests/subscription-enforcement-e2e.test.ts
//
// The whole Stage 5 lifecycle with the gates ON, end to end, against a fake
// Mirage that records every call:
//
//   trial → publish → periodEnd → GRACE (3D still up, publish still allowed)
//         → graceEndsAt → PAUSED → pause job → Mirage { arEnabled: false }
//         → 3D publish refused, photo publish allowed
//         → payment (scripted webhook) → ACTIVE → resume job → { arEnabled: true }
//
// Every Mirage write is asserted by name: through the whole lifecycle the
// restaurant is written exactly twice by subscription code, both times with
// `arEnabled` alone. Nothing is unpublished, nothing is deleted, and the
// public URL never changes (AC-4.1, AC-4.3, AC-4.4). Also here: a payment
// DURING grace never produces a pause job (AC-3.3), and the E15 provisioning
// hook.
import { describe, it, expect, beforeAll, afterAll, beforeEach, afterEach, vi } from 'vitest';
import request from 'supertest';
import mongoose, { Types } from 'mongoose';
import { MongoMemoryServer } from 'mongodb-memory-server';

import { createApp } from '@/app';
import { env } from '@/config/env';
import { DEFAULT_PLAN_CATALOG } from '@/config/subscriptionPlans';
import { Catalog } from '@/models/Catalog';
import { CatalogCategory } from '@/models/CatalogCategory';
import { CatalogDelegation } from '@/models/CatalogDelegation';
import { CatalogProduct } from '@/models/CatalogProduct';
import { CatalogPublishRun } from '@/models/CatalogPublishRun';
import { CatalogSubscription } from '@/models/CatalogSubscription';
import { ClientConfig } from '@/models/ClientConfig';
import { Job } from '@/models/Job';
import { Notification } from '@/models/Notification';
import { PaymentRecord } from '@/models/PaymentRecord';
import { RateWindow } from '@/models/RateWindow';
import { ReminderLog } from '@/models/ReminderLog';
import { SUBSCRIPTION_AR_ENTITLEMENT_JOB_TYPE } from '@/models/types/job.types';
import { User } from '@/models/User';
import { resetRazorpayClient, setRazorpayClient } from '@/providers/razorpay';
import { provisionCatalog } from '@/services/catalogProvisioningService';
import { resetMirageClient, setMirageClient } from '@/services/mirage';
import { runSubscriptionSweep } from '@/services/subscription/lifecycleSweep';
import { SUBSCRIPTION_GATES_FLAG_KEY } from '@/services/subscription/subscriptionGate';
import { subscriptionArEntitlementProcessor } from '@/worker/processors/subscriptionArEntitlementProcessor';
import type { WorkerJob } from '@/worker/workerTypes';
import { FakeMirage } from './fixtures/mirageFake';
import {
  DAY_MS,
  delegated,
  fakeRazorpay,
  paymentCaptured,
  signedWebhook,
  type Auth,
} from './helpers/subscriptionPayments';

const app = createApp();
let mongod: MongoMemoryServer;
const mirage = new FakeMirage();
const GRACE_MS = DEFAULT_PLAN_CATALOG.graceDays * DAY_MS;

beforeAll(async () => {
  mongod = await MongoMemoryServer.create();
  await mongoose.connect(mongod.getUri());
  await Promise.all([
    Catalog.syncIndexes(),
    CatalogSubscription.syncIndexes(),
    CatalogDelegation.syncIndexes(),
    PaymentRecord.syncIndexes(),
    Job.syncIndexes(),
    ReminderLog.syncIndexes(),
  ]);
});

afterAll(async () => {
  await mongoose.disconnect();
  await mongod.stop();
});

beforeEach(async () => {
  mirage.reset();
  setMirageClient(mirage);
  setRazorpayClient(fakeRazorpay());
  // MIRAGE_BASE_URL stays UNSET on purpose: the client is the fake, and an
  // unconfigured transport makes warmUpMirage a no-op instead of a real GET.
  Object.assign(env, { MIRAGE_PUBLIC_BASE_URL: 'https://menu.test' });
  await ClientConfig.create({ [SUBSCRIPTION_GATES_FLAG_KEY]: true });
  vi.spyOn(console, 'log').mockImplementation(() => {});
  vi.spyOn(console, 'warn').mockImplementation(() => {});
  vi.spyOn(console, 'error').mockImplementation(() => {});
});

afterEach(async () => {
  vi.restoreAllMocks();
  resetMirageClient();
  resetRazorpayClient();
  await Promise.all([
    User.deleteMany({}),
    Catalog.deleteMany({}),
    CatalogCategory.deleteMany({}),
    CatalogDelegation.deleteMany({}),
    CatalogProduct.deleteMany({}),
    CatalogPublishRun.deleteMany({}),
    CatalogSubscription.deleteMany({}),
    ClientConfig.deleteMany({}),
    Job.deleteMany({}),
    Notification.deleteMany({}),
    PaymentRecord.deleteMany({}),
    RateWindow.deleteMany({}),
    ReminderLog.deleteMany({}),
  ]);
});

const THREE_D_ASSETS = {
  glbUrl: 'https://test.cloudfront.net/dev/p/model.glb',
  thumbnailUrl: 'https://test.cloudfront.net/dev/p/preview.jpg',
};

/** A category and `threeD` READY-model dishes plus `photos` image dishes. */
async function seedMenu(
  catalogId: Types.ObjectId,
  userId: Types.ObjectId,
  counts: { threeD: number; photos: number }
): Promise<void> {
  const category = await CatalogCategory.create({ catalogId, userId, name: 'menu', position: 0 });
  const base = { catalogId, userId, categoryId: category._id };
  const rows = [];
  for (let i = 0; i < counts.threeD; i++) {
    rows.push({ ...base, type: 'THREE_D', name: `dish_${i}`, position: i, assets: THREE_D_ASSETS });
  }
  for (let i = 0; i < counts.photos; i++) {
    rows.push({
      ...base,
      type: 'IMAGE_ONLY',
      name: `photo_${i}`,
      position: counts.threeD + i,
      assets: { imageKey: `dev/catalog/x/products/p/${i}.jpg` },
    });
  }
  await CatalogProduct.create(rows);
}

const publish = (auth: Auth) => request(app).post('/catalog/publish').set(auth).send({});

/** Frees the publish lock the way a finished run would, so the next publish can be requested. */
async function releaseRun(catalogId: Types.ObjectId): Promise<void> {
  await Catalog.updateOne({ _id: catalogId }, { $set: { activePublishRunId: null } }).exec();
  await CatalogPublishRun.updateMany({ catalogId }, { $set: { state: 'SUCCEEDED' } }).exec();
}

/** Runs every queued entitlement job through the processor, as the worker would. */
async function drainEntitlementJobs(): Promise<number> {
  const jobs = await Job.find({ jobType: SUBSCRIPTION_AR_ENTITLEMENT_JOB_TYPE, state: 'QUEUED' })
    .lean<WorkerJob[]>()
    .exec();
  for (const job of jobs) {
    await subscriptionArEntitlementProcessor(job);
    await Job.updateOne({ _id: job._id }, { $set: { state: 'COMPLETED' } }).exec();
  }
  return jobs.length;
}

const entitlementJobs = () =>
  Job.find({ jobType: SUBSCRIPTION_AR_ENTITLEMENT_JOB_TYPE }).sort({ createdAt: 1 }).lean().exec();

async function openOrder(auth: Auth): Promise<{ orderId: string; amountPaise: number }> {
  const res = await request(app)
    .post('/catalog/subscription/order')
    .set(auth)
    .send({ planId: 'TASTE', interval: 'MONTHLY' });
  expect([200, 201]).toContain(res.status);
  return { orderId: res.body.order.providerOrderId, amountPaise: res.body.order.amountPaise };
}

/** Opens an order and delivers its `payment.captured`; returns a replay of the same delivery. */
async function pay(auth: Auth, paymentId: string): Promise<() => Promise<void>> {
  const { orderId, amountPaise } = await openOrder(auth);
  const signed = signedWebhook(paymentCaptured({ orderId, paymentId, amountPaise }));
  const deliver = async (): Promise<void> => {
    const res = await request(app)
      .post('/webhooks/razorpay')
      .set('Content-Type', 'application/json')
      .set('X-Razorpay-Signature', signed.signature)
      .send(signed.body);
    expect(res.status).toBe(200);
  };
  await deliver();
  return deliver;
}

describe('trial → publish → grace → pause → pay → resume, with the gates on', () => {
  it('walks the whole lifecycle and writes Mirage exactly twice, both times { arEnabled } alone', async () => {
    const { owner, rep, catalogId } = await delegated();
    await seedMenu(catalogId, owner.id, { threeD: 2, photos: 1 });
    const T0 = new Date('2026-10-01T00:00:00.000Z');

    // ── No plan yet: the 3D menu cannot publish ──────────────────────────────
    expect((await publish(owner.auth)).status).toBe(422);
    expect(mirage.restaurants.size).toBe(0);

    // ── The rep starts the trial ─────────────────────────────────────────────
    const trial = await request(app).post(`/rep/catalogs/${catalogId}/subscription/trial`).set(rep.auth);
    expect(trial.status).toBe(201);
    await CatalogSubscription.updateOne(
      { catalogId },
      { $set: { periodStart: T0, periodEnd: new Date(T0.getTime() + 30 * DAY_MS) } }
    ).exec();

    // ── First publish: provisions the restaurant, entitled by default ────────
    const first = await publish(owner.auth);
    expect(first.status).toBe(202);
    const catalog = await Catalog.findById(catalogId).lean().exec();
    expect(catalog?.mirageRestaurantId).toBeTruthy();
    const restaurantId = catalog!.mirageRestaurantId!;
    const publicUrl = catalog!.publicUrl;
    expect(mirage.restaurants.get(restaurantId)?.arEnabled).toBeUndefined(); // Mirage's default = true
    // An entitled row at provisioning enqueues nothing (E15's other half).
    expect(await entitlementJobs()).toHaveLength(0);
    await releaseRun(catalogId);

    // ── The trial ends: GRACE. 3D still up, publish still allowed ────────────
    const T1 = new Date(T0.getTime() + 30 * DAY_MS);
    const lapse = await runSubscriptionSweep(T1);
    expect(lapse).toMatchObject({ toGrace: 1, toPaused: 0 });
    let row = await CatalogSubscription.findOne({ catalogId }).lean();
    expect(row).toMatchObject({ status: 'GRACE', graceFrom: 'TRIAL' });
    expect(row?.graceEndsAt?.getTime()).toBe(T1.getTime() + GRACE_MS);
    expect(await entitlementJobs()).toHaveLength(0);
    expect(mirage.callsTo('updateRestaurant')).toHaveLength(0);
    expect((await publish(owner.auth)).status).toBe(202);
    await releaseRun(catalogId);

    // The DTO the app renders carries the grace origin (E16).
    const dto = await request(app).get('/catalog/subscription').set(owner.auth);
    expect(dto.body.subscription).toMatchObject({ status: 'GRACE', graceFrom: 'TRIAL' });
    const summary = await request(app).get('/catalog').set(owner.auth);
    expect(summary.body.catalog.subscription).toMatchObject({ status: 'GRACE', graceFrom: 'TRIAL' });

    // ── Grace ends: PAUSED, one pause job, Mirage told { arEnabled: false } ──
    const T2 = new Date(T1.getTime() + GRACE_MS + 600_000); // ten minutes late, as sweeps are
    const pause = await runSubscriptionSweep(T2);
    expect(pause).toMatchObject({ toGrace: 0, toPaused: 1, pausesEnqueued: 1 });
    row = await CatalogSubscription.findOne({ catalogId }).lean();
    expect(row?.status).toBe('PAUSED');
    expect(row?.pausedAt?.getTime()).toBe(T2.getTime());

    let jobs = await entitlementJobs();
    expect(jobs).toHaveLength(1);
    expect(jobs[0]?.payload).toEqual({
      catalogId: catalogId.toHexString(),
      enabled: false,
      reason: 'GRACE_EXPIRED',
    });

    const update = vi.spyOn(mirage, 'updateRestaurant');
    expect(await drainEntitlementJobs()).toBe(1);
    expect(update).toHaveBeenCalledTimes(1);
    expect(update.mock.calls[0]).toEqual([restaurantId, { arEnabled: false }]);
    expect(mirage.restaurants.get(restaurantId)).toMatchObject({ arEnabled: false });
    expect(mirage.restaurants.get(restaurantId)?.isPublished ?? true).toBe(true);
    row = await CatalogSubscription.findOne({ catalogId }).lean();
    expect(row?.arEntitlementSyncedAt).toBeInstanceOf(Date);

    // ── While PAUSED: 3D publish refused, photo-only publish allowed (C5) ────
    const refused = await publish(owner.auth);
    expect(refused.status).toBe(422);
    expect(refused.body.gates.map((g: { code: string }) => g.code)).toEqual(['SUBSCRIPTION_REQUIRED']);
    await CatalogProduct.updateMany({ catalogId, type: 'THREE_D' }, { $set: { archivedAt: new Date() } });
    expect((await publish(owner.auth)).status).toBe(202);
    await releaseRun(catalogId);
    await CatalogProduct.updateMany({ catalogId, type: 'THREE_D' }, { $set: { archivedAt: null } });

    // ── The owner pays: ACTIVE, one resume job, Mirage told { arEnabled: true } ──
    const replay = await pay(owner.auth, 'pay_e2e_1');
    row = await CatalogSubscription.findOne({ catalogId }).lean();
    expect(row).toMatchObject({ status: 'ACTIVE', planId: 'TASTE', graceFrom: null, pausedAt: null });

    jobs = await entitlementJobs();
    expect(jobs).toHaveLength(2);
    expect(jobs[1]?.payload).toEqual({ catalogId: catalogId.toHexString(), enabled: true, reason: 'PAYMENT' });

    expect(await drainEntitlementJobs()).toBe(1);
    expect(update).toHaveBeenCalledTimes(2);
    expect(update.mock.calls[1]).toEqual([restaurantId, { arEnabled: true }]);
    expect(mirage.restaurants.get(restaurantId)?.arEnabled).toBe(true);

    // ── Back in business: the 3D publish goes through ────────────────────────
    expect((await publish(owner.auth)).status).toBe(202);

    // ── The invariants, over the whole story ─────────────────────────────────
    // Subscription code wrote the restaurant exactly twice, and never anything else.
    expect(update.mock.calls.map((c) => Object.keys(c[1]))).toEqual([['arEnabled'], ['arEnabled']]);
    expect(mirage.callsTo('deleteRestaurant')).toHaveLength(0);
    expect(mirage.callsTo('deleteItem')).toHaveLength(0);
    expect(mirage.restaurants.size).toBe(1);
    const finalCatalog = await Catalog.findById(catalogId).lean().exec();
    expect(finalCatalog?.mirageRestaurantId).toBe(restaurantId);
    expect(finalCatalog?.publicUrl).toBe(publicUrl);
    expect(finalCatalog?.status).not.toBe('UNPUBLISHED');
    // A replayed webhook is idempotent all the way down: no third job.
    await replay();
    expect(await Job.countDocuments({ jobType: SUBSCRIPTION_AR_ENTITLEMENT_JOB_TYPE })).toBe(2);
  });

  it('a payment DURING grace goes back to ACTIVE with no pause job and no Mirage call (AC-3.3)', async () => {
    const { owner, catalogId } = await delegated();
    await seedMenu(catalogId, owner.id, { threeD: 1, photos: 0 });
    const T0 = new Date('2026-10-01T00:00:00.000Z');
    await CatalogSubscription.create({
      catalogId,
      userId: owner.id,
      status: 'ACTIVE',
      source: 'ONLINE',
      planId: 'TASTE',
      planSnapshot: DEFAULT_PLAN_CATALOG.plans.TASTE,
      billingInterval: 'MONTHLY',
      periodStart: new Date(T0.getTime() - 30 * DAY_MS),
      periodEnd: T0,
      threeDDishCap: 10,
    });
    expect((await publish(owner.auth)).status).toBe(202);
    const restaurantId = (await Catalog.findById(catalogId).lean().exec())!.mirageRestaurantId!;

    await runSubscriptionSweep(T0);
    expect((await CatalogSubscription.findOne({ catalogId }).lean())?.status).toBe('GRACE');

    await pay(owner.auth, 'pay_e2e_grace');
    const row = await CatalogSubscription.findOne({ catalogId }).lean();
    expect(row).toMatchObject({ status: 'ACTIVE', graceEndsAt: null, graceFrom: null });

    // The grace deadline passes — nothing is left to pause.
    const late = await runSubscriptionSweep(new Date(T0.getTime() + GRACE_MS + DAY_MS));
    expect(late).toMatchObject({ toGrace: 0, toPaused: 0 });

    expect(await entitlementJobs()).toHaveLength(0);
    expect(mirage.callsTo('updateRestaurant')).toHaveLength(0);
    expect(mirage.restaurants.get(restaurantId)?.arEnabled).toBeUndefined();
  });

  it('E15: provisioning a catalog whose row is PAUSED enqueues { enabled: false } immediately', async () => {
    const { owner, catalogId } = await delegated();
    await seedMenu(catalogId, owner.id, { threeD: 0, photos: 2 });
    await CatalogSubscription.create({
      catalogId,
      userId: owner.id,
      status: 'PAUSED',
      source: 'ONLINE',
      periodStart: new Date(Date.now() - 60 * DAY_MS),
      periodEnd: new Date(Date.now() - 30 * DAY_MS),
      pausedAt: new Date(Date.now() - 20 * DAY_MS),
      threeDDishCap: 10,
    });

    const result = await provisionCatalog(catalogId);
    expect(result.outcome).toBe('CREATED');

    const jobs = await entitlementJobs();
    expect(jobs).toHaveLength(1);
    expect(jobs[0]?.payload).toMatchObject({ enabled: false });

    await drainEntitlementJobs();
    const restaurantId = (await Catalog.findById(catalogId).lean().exec())!.mirageRestaurantId!;
    expect(mirage.restaurants.get(restaurantId)?.arEnabled).toBe(false);
  });

  it('admin resync-ar enqueues the CURRENT desired state and answers 202 with the job id', async () => {
    const { owner, admin, catalogId } = await delegated();
    await CatalogSubscription.create({
      catalogId,
      userId: owner.id,
      status: 'ACTIVE',
      source: 'ONLINE',
      planId: 'TASTE',
      planSnapshot: DEFAULT_PLAN_CATALOG.plans.TASTE,
      billingInterval: 'MONTHLY',
      periodStart: new Date(),
      periodEnd: new Date(Date.now() + 30 * DAY_MS),
      threeDDishCap: 10,
    });

    const res = await request(app)
      .post(`/admin/catalogs/${catalogId}/subscription/resync-ar`)
      .set(admin.auth)
      .send({});

    expect(res.status).toBe(202);
    expect(res.body).toMatchObject({ status: 'success', enabled: true });
    const job = await Job.findById(res.body.jobId).lean().exec();
    expect(job?.payload).toEqual({ catalogId: catalogId.toHexString(), enabled: true, reason: 'ADMIN' });

    // Pressing it again queues another attempt, not the same job.
    const again = await request(app)
      .post(`/admin/catalogs/${catalogId}/subscription/resync-ar`)
      .set(admin.auth)
      .send({});
    expect(again.status).toBe(202);
    expect(again.body.jobId).not.toBe(res.body.jobId);

    // Not for a rep, and 409 without a row.
    const { rep } = await delegated();
    expect(
      (await request(app).post(`/admin/catalogs/${catalogId}/subscription/resync-ar`).set(rep.auth).send({}))
        .status
    ).toBe(403);
    const { catalogId: bare } = await delegated();
    const none = await request(app).post(`/admin/catalogs/${bare}/subscription/resync-ar`).set(admin.auth).send({});
    expect(none.status).toBe(409);
    expect(none.body.code).toBe('NO_SUBSCRIPTION');

    // The admin panel shows the stamp beside the DTO, null until a job lands.
    const panel = await request(app).get(`/admin/catalogs/${catalogId}/subscription`).set(admin.auth);
    expect(panel.status).toBe(200);
    expect(panel.body.arEntitlementSyncedAt).toBeNull();
  });
});
