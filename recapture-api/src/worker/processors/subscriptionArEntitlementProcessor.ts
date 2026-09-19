// src/worker/processors/subscriptionArEntitlementProcessor.ts
//
// The SUBSCRIPTION_AR_ENTITLEMENT processor: tell Mirage whether one
// restaurant's 3D/AR is switched on (RECAPTURE_SUBSCRIPTION_PLAN.md §6,
// AC-4). ONE Mirage write, `updateRestaurant(id, { arEnabled })`, and
// nothing else — this file must never reach for the unpublish path, a
// delete, or an item write. The photo menu stays live at the printed QR
// whatever this job decides; only the 3D viewer comes and goes.
//
// THE LAST-WRITE CHECK (D4). The payload says what the enqueuer wanted; the
// subscription row says what is true NOW. The two can disagree: the sweep
// paused the row and enqueued `enabled: false`, then the owner paid before
// this ran and the payment enqueued `enabled: true`. Running the stale pause
// would hide 3D on a paid restaurant until the resume job caught up. So the
// row is re-read here and a payload that no longer matches it is dropped —
// as a SUCCESS, because the job that matches the row is the one that will do
// the right thing.
//
// E36: the body is EXACTLY `{ arEnabled }`. Mirage's update is partial, and
// sending `name` (or anything from the catalog) would rename the restaurant
// and break every printed QR — `customerUrl` resolves by name.
import { Types } from 'mongoose';

import { Catalog } from '@/models/Catalog';
import { CatalogSubscription, isEntitledTo3D } from '@/models/CatalogSubscription';
import { getMirageClient, MirageError, warmUpMirage } from '@/services/mirage';
import { alertAdmins } from '@/services/subscription/adminAlerts';
import {
  AR_ENTITLEMENT_REASONS,
  type ArEntitlementJobPayload,
  type ArEntitlementReason,
} from '@/services/subscription/arEntitlementJobs';
import { track, AnalyticsEvent } from '@/utils/analytics';
import { log } from '@/worker/workerLog';
import {
  DEFAULT_MAX_ATTEMPTS,
  NonRetryableJobError,
  type JobProcessor,
  type WorkerJob,
} from '@/worker/workerTypes';

/** Stable codes this processor can fail with. */
export const EntitlementErrorCode = {
  /** The job's payload is not the shape arEntitlementJobs.ts writes. */
  JOB_MALFORMED: 'ENTITLEMENT_JOB_MALFORMED',
  /** Mirage rejected our credential; an operator has to fix it. */
  AUTH_REJECTED: 'ENTITLEMENT_AUTH_REJECTED',
  /** Mirage refused the write for a reason a retry cannot change. */
  MIRAGE_REFUSED: 'ENTITLEMENT_MIRAGE_REFUSED',
} as const;

/** What the job's `result` records — also the shape the tests read. */
export interface ArEntitlementJobResult extends Record<string, unknown> {
  catalogId: string;
  /** What was (or would have been) written. */
  enabled: boolean;
  reason: ArEntitlementReason;
  /** Why no Mirage call happened, when none did. */
  skipped: 'NOT_PROVISIONED' | 'SUBSCRIPTION_GONE' | 'STATE_CHANGED' | null;
}

function isObjectIdHex(value: unknown): value is string {
  return typeof value === 'string' && /^[a-f0-9]{24}$/i.test(value);
}

function isReason(value: unknown): value is ArEntitlementReason {
  return (AR_ENTITLEMENT_REASONS as readonly string[]).includes(value as string);
}

/**
 * Reads the payload defensively. A malformed one is terminal by
 * construction: the enqueue writes all three fields, so anything else is a
 * bug or a hand-edited document, and neither heals with a retry.
 */
function parsePayload(job: WorkerJob): ArEntitlementJobPayload {
  const payload = job.payload ?? {};
  const { catalogId, enabled, reason } = payload;
  if (!isObjectIdHex(catalogId) || typeof enabled !== 'boolean' || !isReason(reason)) {
    throw new NonRetryableJobError(
      EntitlementErrorCode.JOB_MALFORMED,
      'SUBSCRIPTION_AR_ENTITLEMENT payload must carry catalogId, enabled and reason'
    );
  }
  return { catalogId, enabled, reason };
}

/** Would the worker turn this throw into a terminal FAILED, or into a retry? */
function willBeTerminal(err: unknown, job: WorkerJob): boolean {
  if (err instanceof NonRetryableJobError) return true;
  const attempts = (job.attempts ?? 0) + 1;
  const maxAttempts = job.maxAttempts ?? DEFAULT_MAX_ATTEMPTS;
  return attempts >= maxAttempts;
}

export const subscriptionArEntitlementProcessor: JobProcessor = async (job) => {
  const { catalogId: catalogIdHex, enabled, reason } = parsePayload(job);
  const catalogId = new Types.ObjectId(catalogIdHex);

  const done = (skipped: ArEntitlementJobResult['skipped']): ArEntitlementJobResult => {
    track(AnalyticsEvent.SUBSCRIPTION_AR_ENTITLEMENT_SYNCED, {
      catalog_id: catalogIdHex,
      enabled,
      reason,
      skipped: skipped !== null,
    });
    return { catalogId: catalogIdHex, enabled, reason, skipped };
  };

  // 1. The Mirage restaurant. A catalog that was never provisioned has
  //    nothing live to switch; the E15 hook on provisioning covers it later.
  //    Read WITHOUT the deletedAt filter: a catalog on its way out still has
  //    a restaurant until DELETE /catalog removes it, and hiding 3D on it is
  //    harmless.
  const catalog = await Catalog.findById(catalogId)
    .select({ mirageRestaurantId: 1 })
    .lean<{ mirageRestaurantId?: string }>()
    .exec();
  const mirageRestaurantId = catalog?.mirageRestaurantId;
  if (!mirageRestaurantId) {
    log('info', 'Entitlement job: catalog not provisioned — nothing to switch', {
      jobId: job._id,
      catalogId: catalogIdHex,
    });
    return done('NOT_PROVISIONED');
  }

  // 2. The last-write check (D4).
  const subscription = await CatalogSubscription.findOne({ catalogId })
    .select({ status: 1 })
    .lean<{ _id: Types.ObjectId; status: Parameters<typeof isEntitledTo3D>[0] }>()
    .exec();
  if (!subscription) {
    // No row: nothing has ever entitled or paused this restaurant, and the
    // gate will say SUBSCRIPTION_REQUIRED on its next publish. Leave Mirage's
    // default alone.
    log('warn', 'Entitlement job: subscription row gone — leaving Mirage as is', {
      jobId: job._id,
      catalogId: catalogIdHex,
    });
    return done('SUBSCRIPTION_GONE');
  }
  const desired = isEntitledTo3D(subscription.status);
  if (desired !== enabled) {
    log('info', 'Entitlement job: row changed since enqueue — skipping (D4)', {
      jobId: job._id,
      catalogId: catalogIdHex,
      payloadEnabled: enabled,
      rowStatus: subscription.status,
    });
    return done('STATE_CHANGED');
  }

  // 3. The one write. Wake Mirage on a read first (a write that times out
  //    against a booting instance cannot be retried in place).
  try {
    await warmUpMirage();
    // E36: exactly this object, nothing from the catalog.
    await getMirageClient().updateRestaurant(mirageRestaurantId, { arEnabled: desired });
  } catch (err: unknown) {
    if (err instanceof MirageError && !err.isRetryable) {
      const code =
        err.failureClass === 'auth'
          ? EntitlementErrorCode.AUTH_REJECTED
          : EntitlementErrorCode.MIRAGE_REFUSED;
      const terminal = new NonRetryableJobError(code, err.message);
      await reportTerminalFailure(job, catalogIdHex, desired, reason, terminal.message);
      throw terminal;
    }
    if (willBeTerminal(err, job)) {
      const message = err instanceof Error ? err.message : String(err);
      await reportTerminalFailure(job, catalogIdHex, desired, reason, message);
    }
    // Retryable: the worker backs off and this runs again. The customer page
    // keeps its previous state a little longer — late in the safe direction.
    throw err;
  }

  // 4. Stamp the sync so a stale one is visible on the admin panel (E18).
  await CatalogSubscription.updateOne(
    { _id: subscription._id },
    { $set: { arEntitlementSyncedAt: new Date() } }
  ).exec();

  log('info', 'Entitlement synced to Mirage', {
    jobId: job._id,
    catalogId: catalogIdHex,
    enabled: desired,
    reason,
  });
  return done(null);
};

/**
 * The job is about to fail for good. A pause that never lands leaves 3D up
 * a while longer (safe); a resume that never lands leaves a paid owner
 * without 3D, and only an admin can re-run it — so an admin is told either
 * way, and the alert names the button to press.
 */
async function reportTerminalFailure(
  job: WorkerJob,
  catalogId: string,
  enabled: boolean,
  reason: ArEntitlementReason,
  message: string
): Promise<void> {
  console.error(
    `[entitlement] job ${String(job._id)} failed terminally for catalog ${catalogId} ` +
      `(enabled=${enabled}, reason=${reason}): ${message}`
  );
  await alertAdmins({
    kind: 'ENTITLEMENT_FAILED',
    title: enabled ? '3D resume did not reach Mirage' : '3D pause did not reach Mirage',
    message: enabled
      ? 'A paid restaurant may still be showing photos only. Open the subscription and press Resync 3D.'
      : 'A paused restaurant may still be showing 3D. Open the subscription and press Resync 3D.',
    catalogId,
    detail: `job=${String(job._id)} reason=${reason} enabled=${enabled} error=${message}`,
  });
}
