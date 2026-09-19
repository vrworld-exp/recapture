// src/services/subscription/arEntitlementJobs.ts
//
// The ONE way a SUBSCRIPTION_AR_ENTITLEMENT job is enqueued (Stage 5 of
// RECAPTURE_SUBSCRIPTION_PLAN.md, §6 "How PAUSED actually works"). Four
// callers: the lifecycle sweep (GRACE → PAUSED), the two activation
// primitives (a resume out of PAUSED/CANCELLED), first-time provisioning of a
// catalog that is not entitled (E15), and the admin's resync. They all pass
// through here so the payload shape, the priority and the idempotency key
// are written once.
//
// WHAT THE JOB DOES, AND DOES NOT DO: its processor writes exactly
// `{ arEnabled }` on the Mirage restaurant. It never unpublishes, never
// deletes an item, never touches `Catalog.status`. The photo menu at the
// printed QR stays live either way — that is the product rule (AC-4).
import { Types } from 'mongoose';

import { Job } from '@/models/Job';
import {
  PUBLISH_JOB_PRIORITY,
  SUBSCRIPTION_AR_ENTITLEMENT_JOB_TYPE,
} from '@/models/types/job.types';

export const AR_ENTITLEMENT_REASONS = ['GRACE_EXPIRED', 'PAYMENT', 'COMP', 'ADMIN'] as const;
export type ArEntitlementReason = (typeof AR_ENTITLEMENT_REASONS)[number];

/** The job payload, as the enqueue writes it and the processor reads it. */
export interface ArEntitlementJobPayload {
  catalogId: string;
  enabled: boolean;
  reason: ArEntitlementReason;
}

export interface EnqueueArEntitlementInput {
  catalogId: Types.ObjectId;
  /** The catalog's owner — every Job carries a userId. */
  ownerUserId: Types.ObjectId;
  enabled: boolean;
  reason: ArEntitlementReason;
  /**
   * What makes two enqueues of the same intent ONE job. The sweep and the
   * activation paths pass the subscription row's `updatedAt` — the write that
   * changed the status is the thing being synced, so a re-run sweep over the
   * same row lands on the same key and Mongo's unique index answers with the
   * job that already exists. The admin resync passes "now": an operator who
   * presses the button twice wants two attempts.
   */
  dedupeAt: Date;
}

export interface EnqueueArEntitlementResult {
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

export function arEntitlementIdempotencyKey(
  catalogId: Types.ObjectId,
  enabled: boolean,
  dedupeAt: Date
): string {
  return `ar-entitlement:${catalogId.toHexString()}:${enabled}:${dedupeAt.getTime()}`;
}

/**
 * Enqueues the job, or returns the one the same key already names.
 *
 * Priority is the publish job's (PUBLISH_JOB_PRIORITY), and the worker lists
 * this type in its reserved lane beside the publish job: a resume is
 * something an owner who just paid is standing and waiting on, and it must
 * not queue behind a ten-minute Meshy generation.
 */
export async function enqueueArEntitlementJob(
  input: EnqueueArEntitlementInput
): Promise<EnqueueArEntitlementResult> {
  const idempotencyKey = arEntitlementIdempotencyKey(input.catalogId, input.enabled, input.dedupeAt);
  const payload: ArEntitlementJobPayload = {
    catalogId: input.catalogId.toHexString(),
    enabled: input.enabled,
    reason: input.reason,
  };

  try {
    const job = await Job.create({
      userId: input.ownerUserId,
      jobType: SUBSCRIPTION_AR_ENTITLEMENT_JOB_TYPE,
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
