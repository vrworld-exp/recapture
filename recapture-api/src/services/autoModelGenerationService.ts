// src/services/autoModelGenerationService.ts
//
// The decision layer for AUTOMATIC model generation: given a capture job that
// just finished processing, decide whether to spend Meshy credits on it — and
// if so, enqueue the generation
// (docs/auto-model-generation-implementation-prompt.md).
//
// ── WHY THIS FILE IS MOSTLY GUARDS ──────────────────────────────────────────
// The staff path spends credits only when a human decides to. Automatic
// generation spends them on EVERY finished capture, including test captures,
// accidental captures, and a user who recaptures the same object five times
// because they disliked the lighting. The guards below are the whole difference
// between a feature and a bill.
//
// The most important one is not a limit at all — it is the QUALITY floor
// (delegated to the selector): a bad capture costs exactly as much to generate
// as a good one, so declining to spend is the cheapest, highest-leverage guard
// available. This service prefers SKIPPING to generating something worthless.
//
// Every path returns an outcome; nothing here throws for a business reason. The
// caller (the capture processor) treats generation as best-effort and must
// never fail a good capture over it.
import { Types } from 'mongoose';
import { env } from '@/config/env';
import { ProjectModel } from '@/models/ProjectModel';
import { getServerFlag } from '@/services/remoteConfigService';
import { selectPhotosForAutoGeneration } from '@/services/autoPhotoSelectionService';
import { createMeshyModelRequest } from '@/services/projectModelsService';
import type { WorkerJob } from '@/worker/workerTypes';

/** Remote-config key for the live kill switch (see maybeAutoGenerateModel). */
export const AUTO_MODEL_FLAG_KEY = 'autoModelGenerationEnabled';

export type AutoGenerationSkipReason =
  /** Env gate or remote-config flag is off. */
  | 'DISABLED'
  /** This capture job already has an auto-generation (retry / re-claim). */
  | 'ALREADY_EXISTS'
  /** The owner hit their rolling 24h ceiling. */
  | 'USER_CAP_REACHED'
  /** The selector refused — not enough usable, well-spread photos. */
  | 'NOT_SELECTABLE'
  /** The job document lacks what we need to attribute or locate the capture. */
  | 'JOB_INCOMPLETE'
  /** Record or queue write failed; the capture itself is unaffected. */
  | 'ENQUEUE_FAILED';

export type AutoGenerationOutcome =
  | { outcome: 'ENQUEUED'; modelId: string; keyCount: number; reason: string }
  | { outcome: 'SKIPPED'; reason: AutoGenerationSkipReason; detail?: string };

export interface MaybeAutoGenerateInput {
  /** The CAPTURE job that just finished processing. */
  job: WorkerJob;
  /** Its parsed capture_manifest.json — already validated by the processor. */
  manifest: unknown;
  /**
   * Relative keys actually present under the job prefix. Optional but strongly
   * recommended: it stops a manifest entry whose object never landed from
   * becoming a presigned URL that 404s on Meshy's side — a wasted paid
   * generation. See the selector's `availableKeys`.
   */
  availableKeys?: readonly string[];
}

/**
 * The deterministic idempotency key for a job's automatic generation.
 *
 * This is the money guard that matters most. Because it is derived from the
 * capture job id (not random, not client-supplied), the unique
 * (createdByUserId, idempotencyKey) index means a re-claimed, retried, or
 * duplicate-processed capture job REPLAYS the existing record instead of
 * enqueuing — and paying for — a second generation. A genuine recapture is a
 * NEW job id, so it correctly gets a new (deliberate) spend.
 */
export function autoGenerationIdempotencyKey(jobId: Types.ObjectId | string): string {
  return `auto:${jobId.toString()}`;
}

/**
 * Decides and (if warranted) enqueues one automatic generation for a finished
 * capture job. Never throws for a business reason — every refusal is a
 * SKIPPED outcome the caller can log.
 */
export async function maybeAutoGenerateModel(
  input: MaybeAutoGenerateInput
): Promise<AutoGenerationOutcome> {
  const { job, manifest } = input;

  // ── Guard 1: the kill switch. Checked FIRST so a panic-disable costs nothing
  // — no queries, no manifest parsing. Env is the hard gate (needs a deploy),
  // remote config is the live switch; BOTH must be on.
  if (!env.AUTO_MODEL_GENERATION_ENABLED) {
    return { outcome: 'SKIPPED', reason: 'DISABLED', detail: 'env' };
  }
  if (!(await isRemotelyEnabled())) {
    return { outcome: 'SKIPPED', reason: 'DISABLED', detail: 'remote-config' };
  }

  const projectId = job.projectId?.toString();
  const userId = job.userId?.toString();
  if (!projectId || !userId) {
    return { outcome: 'SKIPPED', reason: 'JOB_INCOMPLETE' };
  }

  // ── Guard 2: one auto-generation per CAPTURE JOB, never per project.
  // A cheap pre-check that skips the work below in the common retry case; the
  // unique index (via the REPLAYED outcome) remains the actual race authority,
  // because two workers can pass this check concurrently.
  const idempotencyKey = autoGenerationIdempotencyKey(job._id);
  const existing = await ProjectModel.findOne({
    createdByUserId: new Types.ObjectId(userId),
    idempotencyKey,
  })
    .select('_id')
    .lean()
    .exec();
  if (existing) {
    return { outcome: 'SKIPPED', reason: 'ALREADY_EXISTS' };
  }

  // ── Guard 3: the owner's rolling 24h ceiling. Protects against a stuck
  // client that keeps finalizing, and bounds the blast radius of any bug that
  // makes captures complete in a loop.
  const since = new Date(Date.now() - 24 * 60 * 60 * 1000);
  const recentCount = await ProjectModel.countDocuments({
    createdByUserId: new Types.ObjectId(userId),
    createdBySystem: true,
    createdAt: { $gte: since },
  }).exec();
  if (recentCount >= env.AUTO_MODEL_MAX_PER_USER_PER_DAY) {
    return {
      outcome: 'SKIPPED',
      reason: 'USER_CAP_REACHED',
      detail: `${recentCount}/${env.AUTO_MODEL_MAX_PER_USER_PER_DAY} in 24h`,
    };
  }

  // ── Guard 4: quality. The selector decides whether these photos can support
  // a model worth paying for; a DECLINE here is a saved generation, not a bug.
  const selection = selectPhotosForAutoGeneration(manifest, {
    minBlurScore: env.AUTO_MODEL_MIN_BLUR_SCORE,
    ...(input.availableKeys ? { availableKeys: input.availableKeys } : {}),
  });
  if (selection.outcome === 'DECLINED') {
    return { outcome: 'SKIPPED', reason: 'NOT_SELECTABLE', detail: selection.reason };
  }

  // ── Enqueue through the SAME service the staff path uses: it already owns
  // dedupe, count + containment validation, record-before-job ordering, and the
  // idempotency replay. A second create path here would drift from it.
  const result = await createMeshyModelRequest({
    projectId,
    // PIN the generation to the job we just selected from. Without this the
    // service re-resolves the project's NEWEST exportable job, so a user who
    // recaptures while this capture is still processing gets these keys
    // presigned under the other job's prefix — dead URLs at best, another
    // capture's photos at worst. The automatic path always knows its job; it
    // should never be guessing.
    jobId: job._id,
    keys: selection.keys,
    // No human asked for this, so it is attributed to the project OWNER — whose
    // capture caused the spend, and whose daily cap it counts against.
    actor: { userId, role: 'USER' },
    idempotencyKey,
    createdBySystem: true,
  });

  switch (result.outcome) {
    case 'CREATED':
      return {
        outcome: 'ENQUEUED',
        modelId: result.model.id as string,
        keyCount: selection.keys.length,
        reason: selection.reason,
      };
    // The index caught a concurrent worker — the winner's generation stands and
    // we deliberately do NOT enqueue a second one.
    case 'REPLAYED':
      return { outcome: 'SKIPPED', reason: 'ALREADY_EXISTS' };
    default:
      // PROJECT_NOT_FOUND / NOT_EXPORTABLE / INVALID_COUNT / INVALID_KEY. These
      // are real, but they are not the capture's problem — log and move on.
      return { outcome: 'SKIPPED', reason: 'ENQUEUE_FAILED', detail: result.outcome };
  }
}

/**
 * Reads the live KILL switch.
 *
 * An UNSET flag means enabled: the env gate above is already an explicit,
 * deliberate opt-in, so requiring a second explicit opt-in would just make the
 * feature mysteriously do nothing on a fresh environment. The remote flag is
 * therefore a pure off-switch — set it to `false` to stop generation instantly
 * without a deploy.
 *
 * Fail-CLOSED on a store error: unlike the client config path (which must never
 * 5xx and degrades to defaults), an unreadable store here means we cannot
 * confirm the switch, and the downside of guessing wrong is spending money.
 */
async function isRemotelyEnabled(): Promise<boolean> {
  try {
    return (await getServerFlag(AUTO_MODEL_FLAG_KEY)) !== false;
  } catch {
    return false;
  }
}
