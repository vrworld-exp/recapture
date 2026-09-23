// src/services/subscription/pageStateJobs.ts
//
// The ONE way a SUBSCRIPTION_PAGE_STATE job is enqueued — the sibling of
// arEntitlementJobs.ts, for the field that decides whether the CUSTOMER PAGE
// is live at all rather than whether 3D is on it.
//
// Three callers, all of them in the PENDING_PAYMENT lifecycle (requirement 2):
//   • pendingPaymentService, when a rep/staff publish opens the window
//     (`isPublished: true` + the deadline, so Mirage can show the banner);
//   • lifecycleSweep, when the window expires (`isPublished: false`);
//   • subscriptionService's activation primitives and startTrial, when a
//     payment, a comp or a trial clears the debt (`isPublished: true`,
//     `paymentDueAt: null`).
//
// WHAT THE JOB DOES, AND DOES NOT DO: its processor writes exactly
// `{ isPublished, paymentDueAt }` on the Mirage restaurant. It never deletes
// the restaurant (the `_id` is what every printed QR encodes), never touches an
// item, and never touches `arEnabled` — that is the other job's single field.
//
// WHY A SUBSCRIPTION THAT MERELY LAPSED NEVER REACHES HERE. AC-4 promises a
// restaurant that has PAID that its photo menu stays live at the printed QR
// forever, and that promise is kept by there being no code path from a lapse to
// this file. Only a window that was never paid for can take a page down.
import { Types } from 'mongoose';

import { Job } from '@/models/Job';
import { PUBLISH_JOB_PRIORITY, SUBSCRIPTION_PAGE_STATE_JOB_TYPE } from '@/models/types/job.types';
import type { SubscriptionStatus } from '@/models/types/subscription.types';

export const PAGE_STATE_REASONS = [
  /** A rep/staff publish opened the pending-payment window. */
  'PENDING_PAYMENT_STARTED',
  /** The window ran out unpaid — the page goes dark. */
  'PENDING_PAYMENT_EXPIRED',
  /** A payment (online or manual) cleared the debt. */
  'PAYMENT',
  /** An admin comp cleared it. */
  'COMP',
  /** A trial superseded the window. */
  'TRIAL',
  /** An admin pressed the resync button. */
  'ADMIN',
] as const;
export type PageStateReason = (typeof PAGE_STATE_REASONS)[number];

/** The job payload, as the enqueue writes it and the processor reads it. */
export interface PageStateJobPayload {
  catalogId: string;
  /** Whether Mirage should serve the customer page at all. */
  isPublished: boolean;
  /**
   * ISO instant the page goes dark, or null for "nothing is due". Mirage stores
   * it verbatim and its public payload hands it to the menu UI, which renders
   * the countdown — so the deadline is computed ONCE, here, and never again
   * from a day count on another clock.
   */
  paymentDueAt: string | null;
  reason: PageStateReason;
}

/** The subscription fields the desired state is computed from. */
export interface PageStateRow {
  status: SubscriptionStatus;
  periodEnd: Date;
  pageDeactivatedAt?: Date;
}

/**
 * What Mirage SHOULD hold for this row, right now.
 *
 *   • PENDING_PAYMENT → page live, and the deadline is the row's `periodEnd`,
 *     which is the instant the sweep will switch it off.
 *   • a row whose `pageDeactivatedAt` is set → page dark, deadline kept so the
 *     Mirage side can still say what it is waiting for.
 *   • everything else → page live, nothing due. That includes PAUSED and
 *     CANCELLED: a restaurant that paid and lapsed keeps its photo menu at the
 *     printed QR (AC-4), and only `arEnabled` goes.
 *
 * Deliberately does NOT read `Catalog.status`: whether the owner has unpublished
 * their own menu is a different decision on a different field, made by
 * catalogPublishService, and this job must not fight it. See the guard below.
 */
export function desiredPageStateFor(row: PageStateRow): {
  isPublished: boolean;
  paymentDueAt: Date | null;
} {
  if (row.pageDeactivatedAt) {
    return { isPublished: false, paymentDueAt: row.periodEnd };
  }
  if (row.status === 'PENDING_PAYMENT') {
    return { isPublished: true, paymentDueAt: row.periodEnd };
  }
  return { isPublished: true, paymentDueAt: null };
}

export interface EnqueuePageStateInput {
  catalogId: Types.ObjectId;
  /** The catalog's owner — every Job carries a userId. */
  ownerUserId: Types.ObjectId;
  isPublished: boolean;
  paymentDueAt: Date | null;
  reason: PageStateReason;
  /**
   * What makes two enqueues of the same intent ONE job — the same rule as
   * {@link arEntitlementIdempotencyKey}: callers pass the subscription row's
   * `updatedAt`, because the write that changed the status is the thing being
   * synced, so a re-run sweep lands on the same key and Mongo's unique index
   * answers with the job that already exists. An admin resync passes "now".
   */
  dedupeAt: Date;
}

export interface EnqueuePageStateResult {
  jobId: Types.ObjectId;
  /** False when the unique index found the job already queued. */
  created: boolean;
}

/** The unique (userId, idempotencyKey) index's refusal. */
function isDuplicateKey(err: unknown): boolean {
  return (
    typeof err === 'object' &&
    err !== null &&
    'code' in err &&
    (err as { code?: unknown }).code === 11000
  );
}

export function pageStateIdempotencyKey(
  catalogId: Types.ObjectId,
  isPublished: boolean,
  dedupeAt: Date
): string {
  return `page-state:${catalogId.toHexString()}:${isPublished}:${dedupeAt.getTime()}`;
}

/**
 * Enqueues the job, or returns the one the same key already names.
 *
 * Priority is the publish job's, and the worker lists this type in its reserved
 * lane beside the publish and entitlement jobs: a restaurant that just paid to
 * get its page back is standing and watching, and must not queue behind a
 * ten-minute Meshy generation.
 */
export async function enqueuePageStateJob(
  input: EnqueuePageStateInput
): Promise<EnqueuePageStateResult> {
  const idempotencyKey = pageStateIdempotencyKey(
    input.catalogId,
    input.isPublished,
    input.dedupeAt
  );
  const payload: PageStateJobPayload = {
    catalogId: input.catalogId.toHexString(),
    isPublished: input.isPublished,
    paymentDueAt: input.paymentDueAt ? input.paymentDueAt.toISOString() : null,
    reason: input.reason,
  };

  try {
    const job = await Job.create({
      userId: input.ownerUserId,
      jobType: SUBSCRIPTION_PAGE_STATE_JOB_TYPE,
      state: 'QUEUED',
      priority: PUBLISH_JOB_PRIORITY,
      idempotencyKey,
      queuedAt: new Date(),
      payload,
    });
    return { jobId: job._id as Types.ObjectId, created: true };
  } catch (err) {
    if (!isDuplicateKey(err)) throw err;
    const existing = await Job.findOne({ userId: input.ownerUserId, idempotencyKey })
      .select({ _id: 1 })
      .lean<{ _id: Types.ObjectId }>()
      .exec();
    if (!existing) throw err;
    return { jobId: existing._id, created: false };
  }
}
