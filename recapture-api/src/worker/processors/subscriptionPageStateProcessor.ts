// src/worker/processors/subscriptionPageStateProcessor.ts
//
// The SUBSCRIPTION_PAGE_STATE processor: tell Mirage whether one restaurant's
// CUSTOMER PAGE is live, and when its payment is due (requirement 2). TWO
// Mirage fields, `updateRestaurant(id, { isPublished, paymentDueAt })`, and
// nothing else — this file must never reach for `delete-restaurant` (the `_id`
// is what every printed QR encodes), never write an item, and never write
// `arEnabled`, which belongs to subscriptionArEntitlementProcessor alone.
//
// THE LAST-WRITE CHECK (D4), same shape as the entitlement job's and for the
// same reason, except that here the stale write is far more expensive: the
// sweep expired a window and enqueued `isPublished: false`, then the owner paid
// before this ran. Running the stale expiry would take a PAID restaurant's page
// down — the worst outcome this whole feature can produce. So the row is
// re-read, the desired state is recomputed from it, and a payload that no
// longer matches is dropped as a SUCCESS.
//
// DESIRED STATE IS A FUNCTION OF THE ROW, not of the payload: see
// {@link desiredPageStateFor}. The payload's job is only to say what the
// enqueuer believed, so the mismatch can be noticed.
import { Types } from 'mongoose';

import { Catalog } from '@/models/Catalog';
import { CatalogSubscription } from '@/models/CatalogSubscription';
import { getMirageClient, MirageError, warmUpMirage } from '@/services/mirage';
import { alertAdmins } from '@/services/subscription/adminAlerts';
import {
  desiredPageStateFor,
  PAGE_STATE_REASONS,
  type PageStateJobPayload,
  type PageStateReason,
  type PageStateRow,
} from '@/services/subscription/pageStateJobs';
import { track, AnalyticsEvent } from '@/utils/analytics';
import { log } from '@/worker/workerLog';
import {
  DEFAULT_MAX_ATTEMPTS,
  NonRetryableJobError,
  type JobProcessor,
  type WorkerJob,
} from '@/worker/workerTypes';

/** Stable codes this processor can fail with. */
export const PageStateErrorCode = {
  /** The job's payload is not the shape pageStateJobs.ts writes. */
  JOB_MALFORMED: 'PAGE_STATE_JOB_MALFORMED',
  /** Mirage rejected our credential; an operator has to fix it. */
  AUTH_REJECTED: 'PAGE_STATE_AUTH_REJECTED',
  /** Mirage refused the write for a reason a retry cannot change. */
  MIRAGE_REFUSED: 'PAGE_STATE_MIRAGE_REFUSED',
} as const;

/** What the job's `result` records — also the shape the tests read. */
export interface PageStateJobResult extends Record<string, unknown> {
  catalogId: string;
  /** What was (or would have been) written. */
  isPublished: boolean;
  paymentDueAt: string | null;
  reason: PageStateReason;
  /** Why no Mirage call happened, when none did. */
  skipped: 'NOT_PROVISIONED' | 'SUBSCRIPTION_GONE' | 'STATE_CHANGED' | null;
}

function isObjectIdHex(value: unknown): value is string {
  return typeof value === 'string' && /^[a-f0-9]{24}$/i.test(value);
}

function isReason(value: unknown): value is PageStateReason {
  return (PAGE_STATE_REASONS as readonly string[]).includes(value as string);
}

function isIsoOrNull(value: unknown): value is string | null {
  return value === null || (typeof value === 'string' && !Number.isNaN(Date.parse(value)));
}

/**
 * Reads the payload defensively. A malformed one is terminal by construction:
 * the enqueue writes all four fields, so anything else is a bug or a
 * hand-edited document, and neither heals with a retry.
 */
function parsePayload(job: WorkerJob): PageStateJobPayload {
  const payload = job.payload ?? {};
  const { catalogId, isPublished, paymentDueAt, reason } = payload;
  if (
    !isObjectIdHex(catalogId) ||
    typeof isPublished !== 'boolean' ||
    !isIsoOrNull(paymentDueAt) ||
    !isReason(reason)
  ) {
    throw new NonRetryableJobError(
      PageStateErrorCode.JOB_MALFORMED,
      'SUBSCRIPTION_PAGE_STATE payload must carry catalogId, isPublished, paymentDueAt and reason'
    );
  }
  return { catalogId, isPublished, paymentDueAt, reason };
}

/** Would the worker turn this throw into a terminal FAILED, or into a retry? */
function willBeTerminal(err: unknown, job: WorkerJob): boolean {
  if (err instanceof NonRetryableJobError) return true;
  const attempts = (job.attempts ?? 0) + 1;
  const maxAttempts = job.maxAttempts ?? DEFAULT_MAX_ATTEMPTS;
  return attempts >= maxAttempts;
}

export const subscriptionPageStateProcessor: JobProcessor = async (job) => {
  const { catalogId: catalogIdHex, isPublished, reason } = parsePayload(job);
  const catalogId = new Types.ObjectId(catalogIdHex);

  const done = (
    skipped: PageStateJobResult['skipped'],
    written: { isPublished: boolean; paymentDueAt: Date | null } = {
      isPublished,
      paymentDueAt: null,
    }
  ): PageStateJobResult => {
    track(AnalyticsEvent.SUBSCRIPTION_PAGE_STATE_SYNCED, {
      catalog_id: catalogIdHex,
      is_published: written.isPublished,
      reason,
      skipped: skipped !== null,
    });
    return {
      catalogId: catalogIdHex,
      isPublished: written.isPublished,
      paymentDueAt: written.paymentDueAt ? written.paymentDueAt.toISOString() : null,
      reason,
      skipped,
    };
  };

  // 1. The Mirage restaurant. A catalog that was never provisioned has no page
  //    to switch — and pendingPaymentService only opens a window on a publish,
  //    so this is the "deleted before the job ran" case.
  const catalog = await Catalog.findById(catalogId)
    .select({ mirageRestaurantId: 1, status: 1 })
    .lean<{ mirageRestaurantId?: string; status?: string }>()
    .exec();
  const mirageRestaurantId = catalog?.mirageRestaurantId;
  if (!mirageRestaurantId) {
    log('info', 'Page-state job: catalog not provisioned — nothing to switch', {
      jobId: job._id,
      catalogId: catalogIdHex,
    });
    return done('NOT_PROVISIONED');
  }

  // 2. The last-write check (D4), against the row rather than the payload.
  const subscription = await CatalogSubscription.findOne({ catalogId })
    .select({ status: 1, periodEnd: 1, pageDeactivatedAt: 1 })
    .lean<PageStateRow & { _id: Types.ObjectId }>()
    .exec();
  if (!subscription) {
    // No row at all: nothing here has any business deciding whether a page is
    // live. Leave Mirage exactly as it is.
    log('warn', 'Page-state job: subscription row gone — leaving Mirage as is', {
      jobId: job._id,
      catalogId: catalogIdHex,
    });
    return done('SUBSCRIPTION_GONE');
  }

  const desired = desiredPageStateFor(subscription);
  if (desired.isPublished !== isPublished) {
    log('info', 'Page-state job: row changed since enqueue — skipping (D4)', {
      jobId: job._id,
      catalogId: catalogIdHex,
      payloadIsPublished: isPublished,
      rowStatus: subscription.status,
    });
    return done('STATE_CHANGED');
  }

  // 3. WE DO NOT TURN A PAGE ON THAT IS NOT OURS TO TURN ON. `Catalog.status` is
  //    the owner's own switch (feature 39) and it writes the same Mirage field,
  //    and a first publish provisions the restaurant while the catalog is still
  //    DRAFT. In both cases `isPublished` belongs to somebody else right now.
  //
  //    So the field is OMITTED rather than the job dropped — Mirage's update is
  //    partial, and an omitted field is left exactly as it is. The DEADLINE is
  //    still written, which is the whole point: on a first publish this is how
  //    the banner reaches the customer page at all, and on a paid-but-
  //    owner-unpublished catalog it is how the stale banner comes off a page we
  //    are deliberately not reviving.
  //
  //    A turn-OFF is never withheld: switching a page off is always ours to do.
  const withholdIsPublished = desired.isPublished && catalog.status !== 'PUBLISHED';
  if (withholdIsPublished) {
    log('info', 'Page-state job: catalog not published on our side — writing the deadline only', {
      jobId: job._id,
      catalogId: catalogIdHex,
      catalogStatus: catalog.status ?? 'UNKNOWN',
    });
  }

  // 4. The one write. Wake Mirage on a read first (a write that times out
  //    against a booting instance cannot be retried in place).
  try {
    await warmUpMirage();
    // Only these two fields, nothing from the catalog — the E36 rule, which
    // applies here for the same reason: sending `name` would rename the
    // restaurant and break every printed QR.
    await getMirageClient().updateRestaurant(mirageRestaurantId, {
      ...(withholdIsPublished ? {} : { isPublished: desired.isPublished }),
      paymentDueAt: desired.paymentDueAt ? desired.paymentDueAt.toISOString() : null,
    });
  } catch (err: unknown) {
    if (err instanceof MirageError && !err.isRetryable) {
      const code =
        err.failureClass === 'auth'
          ? PageStateErrorCode.AUTH_REJECTED
          : PageStateErrorCode.MIRAGE_REFUSED;
      const terminal = new NonRetryableJobError(code, err.message);
      await reportTerminalFailure(job, catalogIdHex, desired.isPublished, reason, terminal.message);
      throw terminal;
    }
    if (willBeTerminal(err, job)) {
      const message = err instanceof Error ? err.message : String(err);
      await reportTerminalFailure(job, catalogIdHex, desired.isPublished, reason, message);
    }
    // Retryable: the worker backs off and this runs again. The page keeps its
    // previous state a little longer — which for an expiry is late in the SAFE
    // direction (a page that should be dark stays up), and for a restore is
    // covered by the alert below.
    throw err;
  }

  // 5. Stamp the sync so a stale one is visible on the admin panel (E18). The
  //    same field the entitlement job stamps: both are "when did Mirage last
  //    hear from us about this row".
  await CatalogSubscription.updateOne(
    { _id: subscription._id },
    { $set: { arEntitlementSyncedAt: new Date() } }
  ).exec();

  log('info', 'Page state synced to Mirage', {
    jobId: job._id,
    catalogId: catalogIdHex,
    isPublished: desired.isPublished,
    reason,
  });
  return done(null, desired);
};

/**
 * The job is about to fail for good. The two directions are NOT symmetrical:
 * a failed expiry leaves an unpaid page up a while longer (we lose a little
 * leverage); a failed restore leaves a PAYING restaurant's customer page dark,
 * which is the most damaging state this feature has. The alert says which.
 */
async function reportTerminalFailure(
  job: WorkerJob,
  catalogId: string,
  isPublished: boolean,
  reason: PageStateReason,
  message: string
): Promise<void> {
  console.error(
    `[page-state] job ${String(job._id)} failed terminally for catalog ${catalogId} ` +
      `(isPublished=${isPublished}, reason=${reason}): ${message}`
  );
  await alertAdmins({
    kind: 'ENTITLEMENT_FAILED',
    title: isPublished
      ? 'A paid restaurant’s page is still switched off'
      : 'An unpaid restaurant’s page did not switch off',
    message: isPublished
      ? 'URGENT: this restaurant has paid but its customer page is still dark. ' +
        'Open the subscription and press Resync page.'
      : 'An expired pending-payment page is still live. Open the subscription and press Resync page.',
    catalogId,
    detail: `job=${String(job._id)} reason=${reason} isPublished=${isPublished} error=${message}`,
  });
}
