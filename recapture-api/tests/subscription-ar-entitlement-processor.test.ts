// tests/subscription-ar-entitlement-processor.test.ts
//
// The SUBSCRIPTION_AR_ENTITLEMENT processor (Stage 5). What this file exists
// to pin, in order of how badly the alternative goes:
//   • IT NEVER UNPUBLISHES. The opposite of tests/catalog-unpublish.test.ts:
//     a pause is ONE partial write of `{ arEnabled: false }` — never
//     `isPublished`, never `deleteRestaurant`, never a `delete-item`. The
//     photo menu at the printed QR must survive a lapsed plan (AC-4.1).
//   • THE BODY IS EXACTLY `{ arEnabled }` (E36). Mirage's update is partial;
//     a `name` in that body renames the restaurant and breaks every QR.
//   • THE LAST-WRITE CHECK (D4): a payload that no longer matches the row is
//     dropped as a success with `skipped: true`, and Mirage is not called.
//   • An unprovisioned catalog is a no-op success; a retryable Mirage failure
//     propagates for the worker's backoff; a terminal one alerts the admins.
import { describe, it, expect, beforeAll, afterAll, beforeEach, afterEach, vi } from 'vitest';
import mongoose, { Types } from 'mongoose';
import { MongoMemoryServer } from 'mongodb-memory-server';

import { Catalog } from '@/models/Catalog';
import { CatalogSubscription } from '@/models/CatalogSubscription';
import { Job } from '@/models/Job';
import { Notification } from '@/models/Notification';
import { SUBSCRIPTION_AR_ENTITLEMENT_JOB_TYPE } from '@/models/types/job.types';
import { User } from '@/models/User';
import * as catalogPublishService from '@/services/catalogPublishService';
import { resetMirageClient, setMirageClient } from '@/services/mirage';
import {
  arEntitlementIdempotencyKey,
  enqueueArEntitlementJob,
} from '@/services/subscription/arEntitlementJobs';
import {
  EntitlementErrorCode,
  subscriptionArEntitlementProcessor,
  type ArEntitlementJobResult,
} from '@/worker/processors/subscriptionArEntitlementProcessor';
import { NonRetryableJobError, type WorkerJob } from '@/worker/workerTypes';
import { FakeMirage } from './fixtures/mirageFake';
import { DAY_MS, emitted, makeUser, seedCatalog, seedSubscription } from './helpers/subscriptionPayments';

let mongod: MongoMemoryServer;
const mirage = new FakeMirage();

beforeAll(async () => {
  mongod = await MongoMemoryServer.create();
  await mongoose.connect(mongod.getUri());
  await Promise.all([Catalog.syncIndexes(), CatalogSubscription.syncIndexes(), Job.syncIndexes()]);
});

afterAll(async () => {
  await mongoose.disconnect();
  await mongod.stop();
});

beforeEach(() => {
  mirage.reset();
  setMirageClient(mirage);
  vi.spyOn(console, 'log').mockImplementation(() => {});
  vi.spyOn(console, 'warn').mockImplementation(() => {});
  vi.spyOn(console, 'error').mockImplementation(() => {});
});

afterEach(async () => {
  vi.restoreAllMocks();
  resetMirageClient();
  await Promise.all([
    User.deleteMany({}),
    Catalog.deleteMany({}),
    CatalogSubscription.deleteMany({}),
    Job.deleteMany({}),
    Notification.deleteMany({}),
  ]);
});

/** An owner, a catalog provisioned onto a fake Mirage restaurant, and a row in `status`. */
async function provisioned(status: 'PAUSED' | 'ACTIVE' | 'GRACE' | 'CANCELLED' | null) {
  const owner = await makeUser();
  const catalogId = await seedCatalog(owner.id);
  const restaurant = mirage.seedRestaurant(`cafe_${catalogId.toHexString()}`);
  await Catalog.updateOne(
    { _id: catalogId },
    { $set: { mirageRestaurantId: restaurant.id, publicUrl: `https://menu.test/${restaurant.id}` } }
  ).exec();
  if (status) {
    await seedSubscription(catalogId, owner.id, status, {
      periodEnd: new Date(Date.now() - 10 * DAY_MS),
      ...(status === 'PAUSED' ? { pausedAt: new Date() } : {}),
    });
  }
  return { owner, catalogId, restaurant };
}

/** A job as the worker's claim hands it to a processor. */
function jobFor(
  catalogId: Types.ObjectId,
  ownerId: Types.ObjectId,
  enabled: boolean,
  extra: Partial<WorkerJob> = {}
): WorkerJob {
  return {
    _id: new Types.ObjectId(),
    userId: ownerId,
    state: 'PROCESSING',
    jobType: SUBSCRIPTION_AR_ENTITLEMENT_JOB_TYPE,
    payload: { catalogId: catalogId.toHexString(), enabled, reason: enabled ? 'PAYMENT' : 'GRACE_EXPIRED' },
    attempts: 0,
    maxAttempts: 3,
    createdAt: new Date(),
    updatedAt: new Date(),
    ...extra,
  };
}

const run = (job: WorkerJob) =>
  subscriptionArEntitlementProcessor(job) as Promise<ArEntitlementJobResult>;

describe('the write', () => {
  it('a pause is ONE updateRestaurant with exactly { arEnabled: false } — and nothing else (E36, AC-4.1)', async () => {
    const { owner, catalogId, restaurant } = await provisioned('PAUSED');
    const update = vi.spyOn(mirage, 'updateRestaurant');
    const unpublish = vi.spyOn(catalogPublishService, 'requestUnpublish');

    const result = await run(jobFor(catalogId, owner.id, false));

    expect(result).toMatchObject({ enabled: false, skipped: null });
    expect(update).toHaveBeenCalledTimes(1);
    expect(update.mock.calls[0]?.[0]).toBe(restaurant.id);
    // The argument keys, not just the value: a `name` here is the E36 bug.
    expect(Object.keys(update.mock.calls[0]?.[1] ?? {})).toEqual(['arEnabled']);
    expect(update.mock.calls[0]?.[1]).toEqual({ arEnabled: false });

    // The only Mirage traffic is that one write.
    expect(mirage.calls.map((c) => c.method)).toEqual(['updateRestaurant']);
    expect(mirage.callsTo('deleteRestaurant')).toHaveLength(0);
    expect(mirage.callsTo('deleteItem')).toHaveLength(0);
    expect(unpublish).not.toHaveBeenCalled();

    // Mirage: still published, 3D off, restaurant intact.
    const stored = mirage.restaurants.get(restaurant.id);
    expect(stored?.arEnabled).toBe(false);
    expect(stored?.isPublished ?? true).toBe(true);
    expect(stored?.name).toBe(restaurant.name);

    // The stamp the admin panel shows (E18).
    const row = await CatalogSubscription.findOne({ catalogId }).lean();
    expect(row?.arEntitlementSyncedAt).toBeInstanceOf(Date);
    expect(row?.status).toBe('PAUSED');

    expect(emitted('subscription_ar_entitlement_synced')).toEqual([
      { catalog_id: catalogId.toHexString(), enabled: false, reason: 'GRACE_EXPIRED', skipped: false },
    ]);
  });

  it('a resume writes { arEnabled: true } exactly once (AC-4.4)', async () => {
    const { owner, catalogId, restaurant } = await provisioned('ACTIVE');
    mirage.restaurants.get(restaurant.id)!.arEnabled = false;
    const update = vi.spyOn(mirage, 'updateRestaurant');

    await run(jobFor(catalogId, owner.id, true));

    expect(update).toHaveBeenCalledTimes(1);
    expect(update.mock.calls[0]?.[1]).toEqual({ arEnabled: true });
    expect(mirage.restaurants.get(restaurant.id)?.arEnabled).toBe(true);
  });

  it('never touches the catalog document (D5)', async () => {
    const { owner, catalogId } = await provisioned('PAUSED');
    const before = await Catalog.findById(catalogId).lean().exec();

    await run(jobFor(catalogId, owner.id, false));

    expect(await Catalog.findById(catalogId).lean().exec()).toEqual(before);
  });
});

describe('the last-write check (D4)', () => {
  it('a pause payload against a row that has since paid: no Mirage call, success, skipped', async () => {
    const { owner, catalogId } = await provisioned('ACTIVE'); // the owner paid after the enqueue

    const result = await run(jobFor(catalogId, owner.id, false));

    expect(result.skipped).toBe('STATE_CHANGED');
    expect(mirage.calls).toHaveLength(0);
    expect(emitted('subscription_ar_entitlement_synced')[0]).toMatchObject({ skipped: true });
    expect((await CatalogSubscription.findOne({ catalogId }).lean())?.arEntitlementSyncedAt).toBeUndefined();
  });

  it('a resume payload against a row that is PAUSED again: no Mirage call, success, skipped', async () => {
    const { owner, catalogId } = await provisioned('PAUSED');

    const result = await run(jobFor(catalogId, owner.id, true));

    expect(result.skipped).toBe('STATE_CHANGED');
    expect(mirage.calls).toHaveLength(0);
  });

  it('a row that is gone: no Mirage call, success', async () => {
    const { owner, catalogId } = await provisioned(null);

    const result = await run(jobFor(catalogId, owner.id, false));

    expect(result.skipped).toBe('SUBSCRIPTION_GONE');
    expect(mirage.calls).toHaveLength(0);
  });
});

describe('a catalog that was never provisioned', () => {
  it('succeeds as a no-op — there is nothing live to switch', async () => {
    const owner = await makeUser();
    const catalogId = await seedCatalog(owner.id);
    await seedSubscription(catalogId, owner.id, 'PAUSED', { pausedAt: new Date() });

    const result = await run(jobFor(catalogId, owner.id, false));

    expect(result.skipped).toBe('NOT_PROVISIONED');
    expect(mirage.calls).toHaveLength(0);
  });
});

describe('failures', () => {
  it('a retryable Mirage failure propagates (the worker backs off) and alerts nobody yet', async () => {
    const { owner, catalogId } = await provisioned('PAUSED');
    mirage.failNext({ method: 'updateRestaurant', status: 503, message: 'Service Unavailable' });

    await expect(run(jobFor(catalogId, owner.id, false))).rejects.toMatchObject({
      name: 'MirageError',
      isRetryable: true,
    });

    expect(await Notification.countDocuments({ kind: 'SYSTEM' })).toBe(0);
    expect((await CatalogSubscription.findOne({ catalogId }).lean())?.arEntitlementSyncedAt).toBeUndefined();
  });

  it('the LAST retryable attempt alerts the admins before failing', async () => {
    await makeUser('ADMIN');
    const { owner, catalogId } = await provisioned('ACTIVE');
    mirage.failNext({ method: 'updateRestaurant', status: 503, message: 'Service Unavailable' });

    await expect(
      run(jobFor(catalogId, owner.id, true, { attempts: 2, maxAttempts: 3 }))
    ).rejects.toMatchObject({ name: 'MirageError' });

    const alerts = await Notification.find({ kind: 'SYSTEM' }).lean().exec();
    expect(alerts).toHaveLength(1);
    expect(alerts[0]?.title).toMatch(/resume/i);
    expect(alerts[0]?.action?.url).toBe(`/admin/subscriptions/${catalogId.toHexString()}`);
    expect(emitted('admin_alert_sent')[0]).toMatchObject({ kind: 'ENTITLEMENT_FAILED' });
  });

  it('a terminal Mirage refusal fails the job for good and alerts the admins', async () => {
    await makeUser('ADMIN');
    const { owner, catalogId } = await provisioned('PAUSED');
    mirage.failNext({ method: 'updateRestaurant', status: 401, message: 'No token found.' });

    await expect(run(jobFor(catalogId, owner.id, false))).rejects.toBeInstanceOf(NonRetryableJobError);
    await expect(run(jobFor(catalogId, owner.id, false))).resolves.toBeDefined(); // the fake failed once

    const alerts = await Notification.find({ kind: 'SYSTEM' }).lean().exec();
    expect(alerts).toHaveLength(1);
    expect(alerts[0]?.title).toMatch(/pause/i);
  });

  it('a malformed payload is terminal', async () => {
    const owner = await makeUser();
    const job = jobFor(new Types.ObjectId(), owner.id, false, { payload: { catalogId: 'nope' } });

    await expect(run(job)).rejects.toMatchObject({
      name: 'NonRetryableJobError',
      code: EntitlementErrorCode.JOB_MALFORMED,
    });
  });
});

describe('the enqueue', () => {
  it('two enqueues with the same intent and dedupe instant are ONE job; a different instant is another', async () => {
    const owner = await makeUser();
    const catalogId = await seedCatalog(owner.id);
    const at = new Date('2026-10-01T00:00:00.000Z');

    const first = await enqueueArEntitlementJob({
      catalogId,
      ownerUserId: owner.id,
      enabled: false,
      reason: 'GRACE_EXPIRED',
      dedupeAt: at,
    });
    const replay = await enqueueArEntitlementJob({
      catalogId,
      ownerUserId: owner.id,
      enabled: false,
      reason: 'GRACE_EXPIRED',
      dedupeAt: at,
    });
    const later = await enqueueArEntitlementJob({
      catalogId,
      ownerUserId: owner.id,
      enabled: false,
      reason: 'ADMIN',
      dedupeAt: new Date(at.getTime() + 1),
    });

    expect(first.created).toBe(true);
    expect(replay).toEqual({ jobId: first.jobId, created: false });
    expect(later.created).toBe(true);
    expect(later.jobId.equals(first.jobId)).toBe(false);

    const jobs = await Job.find({ jobType: SUBSCRIPTION_AR_ENTITLEMENT_JOB_TYPE }).lean().exec();
    expect(jobs).toHaveLength(2);
    expect(jobs[0]?.idempotencyKey).toBe(arEntitlementIdempotencyKey(catalogId, false, at));
    // No project, a publish-level priority, and a queued state the worker claims.
    expect(jobs.every((j) => j.projectId === undefined && j.priority === 10 && j.state === 'QUEUED')).toBe(
      true
    );
  });
});
