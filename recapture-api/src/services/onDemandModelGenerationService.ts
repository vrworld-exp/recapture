// src/services/onDemandModelGenerationService.ts
//
// The "Generate 3D model" button: the SAME server-side photo selection the
// automatic path uses, triggered by a person instead of by a capture finishing
// (docs/prompts/on-demand-model-generation.md).
//
// ── WHY THIS EXISTS SEPARATELY FROM THE AUTOMATIC PATH ──────────────────────
// autoPhotoSelectionService has only ever run against synthetic manifests.
// Switching the automatic trigger on would make its first contact with real
// capture data an unattended, per-capture spend. This service is the de-risked
// version of that same experiment: human-triggered, one project at a time, on a
// capture someone deliberately chose — and it carries a full trace of WHY those
// photos, so the first real declines are diagnosable instead of mysterious.
//
// It shares everything that matters with the automatic path (the selector, the
// enqueue + money contract, the 24h ceiling) and duplicates none of it. What is
// deliberately NOT shared is the feature flag: see MANUAL_MODEL_GENERATION_ENABLED.
//
// ── STEPS 1–6 ARE ALL SYNCHRONOUS ───────────────────────────────────────────
// Everything here is over in well under a second — there is nothing to watch,
// and no streaming transport is warranted. The route returns a COMPLETED trace
// and the UI renders it as an already-ticked checklist. The slow half (Meshy,
// minutes) is reported by the worker through `record.progress` and polled, as
// it already was.
//
// Never throws for a business reason: every refusal is a typed outcome, exactly
// like maybeAutoGenerateModel. Only an infrastructure failure throws.
import { randomUUID } from 'node:crypto';
import { Types } from 'mongoose';
import { env } from '@/config/env';
import { Project } from '@/models/Project';
import { ProjectModel } from '@/models/ProjectModel';
import type {
  GenerationStep,
  GenerationStepName,
  GenerationStepStatus,
} from '@/models/types/projectModel.types';
import { hasRoleAtLeast } from '@/models/User';
import {
  findExportableJob,
  MODEL_INPUT_KEY_PREFIX,
} from '@/services/adminProjectsService';
import {
  selectPhotosForAutoGeneration,
  type AutoSelectionDeclineReason,
  type AutoSelectionTrace,
} from '@/services/autoPhotoSelectionService';
import {
  captureGenerationIdempotencyKey,
  countServerSelectedGenerationsInLast24h,
  createMeshyModelRequest,
  persistGenerationTrace,
  toStoredSelection,
  type ModelActor,
} from '@/services/projectModelsService';
import { getServerFlag } from '@/services/remoteConfigService';
import { getObjectText, listObjectsUnderPrefix } from '@/services/s3ObjectStore';

export type { GenerationStep, GenerationStepName } from '@/models/types/projectModel.types';

/**
 * Remote-config key for the live kill switch.
 *
 * Deliberately NOT in `remoteConfigSchema` — the same reasoning as
 * `autoModelGenerationEnabled`: that schema is the PUBLIC client wire payload,
 * and this is a server-side operational switch that must never appear on it.
 * Unset means enabled; the env flag is already the explicit opt-in.
 */
export const MANUAL_MODEL_FLAG_KEY = 'manualModelGenerationEnabled';

export type OnDemandBlockReason =
  /** Env gate or remote kill switch is off. */
  | 'DISABLED'
  /** The actor hit the rolling 24h ceiling shared with automatic generations. */
  | 'USER_CAP_REACHED'
  /** The project has no finalized capture to select photos from. */
  | 'NOT_EXPORTABLE'
  /** No such project (or soft-deleted). */
  | 'PROJECT_NOT_FOUND';

export type OnDemandResult =
  | {
      outcome: 'ENQUEUED';
      modelId: string;
      steps: GenerationStep[];
      trace: AutoSelectionTrace;
    }
  /** A generation for this capture job already exists — nothing was paid for. */
  | { outcome: 'REPLAYED'; modelId: string; steps: GenerationStep[] }
  /** The selector refused. The most valuable outcome to render well. */
  | {
      outcome: 'DECLINED';
      reason: AutoSelectionDeclineReason;
      steps: GenerationStep[];
      trace: AutoSelectionTrace;
    }
  | { outcome: 'BLOCKED'; reason: OnDemandBlockReason; steps: GenerationStep[] };

export interface GenerateModelOnDemandInput {
  projectId: string;
  /**
   * Who pressed the button. The generation is attributed to them, and their
   * role picks which 24h ceiling applies — staff get a HIGHER one, never an
   * exemption.
   */
  actor: ModelActor;
  /**
   * Mint a fresh idempotency key so a second press pays for a second
   * generation. STAFF ONLY — the route enforces that. Without it, repeat
   * presses replay the existing record, which is what stops an owner tapping
   * a button into an unbounded bill.
   */
  force?: boolean;
}

/**
 * An infrastructure failure (S3 unreachable, DB write refused) — NOT a business
 * refusal. Carries the steps decided so far so the route can still hand back a
 * trace: "which step were we on when it broke" is most of the diagnosis.
 */
export class GenerationInfrastructureError extends Error {
  constructor(
    message: string,
    readonly steps: GenerationStep[],
    readonly cause?: unknown
  ) {
    super(message);
    this.name = 'GenerationInfrastructureError';
  }
}

/**
 * The idempotency key for a button-triggered generation.
 *
 * A non-forced press uses the SHARED capture key
 * ([captureGenerationIdempotencyKey]): a second press on the same capture — or
 * an automatic generation that already ran for it — REPLAYS the existing record
 * rather than paying again. A genuine recapture is a new job id and correctly
 * gets a new, deliberate spend.
 */
export function manualGenerationIdempotencyKey(
  jobId: Types.ObjectId | string,
  force = false
): string {
  const base = captureGenerationIdempotencyKey(jobId);
  // A forced regenerate is asking to pay again on purpose, so it must NOT
  // collide with the record it is regenerating (or with an automatic one).
  return force ? `${base}:${randomUUID()}` : base;
}

/**
 * Runs the automatic selection for one project on request, and enqueues the
 * generation if the photos support one.
 */
export async function generateModelOnDemand(
  input: GenerateModelOnDemandInput
): Promise<OnDemandResult> {
  const { projectId, actor, force = false } = input;
  const recorder = new StepRecorder();

  // ── Gate. Checked FIRST so a panic-disable costs nothing: no queries, no S3.
  // Env is the hard gate (needs a deploy); remote config is the live switch.
  if (!env.MANUAL_MODEL_GENERATION_ENABLED) {
    recorder.record('GUARDS', 'FAILED', 'disabled by env');
    return { outcome: 'BLOCKED', reason: 'DISABLED', steps: recorder.steps };
  }
  if (!(await isRemotelyEnabled())) {
    recorder.record('GUARDS', 'FAILED', 'disabled by remote kill switch');
    return { outcome: 'BLOCKED', reason: 'DISABLED', steps: recorder.steps };
  }

  // ── Step 1: resolve the capture job. Newest exportable, exactly as the
  // export/preview/delete surfaces resolve it, so the button acts on the
  // capture the person is looking at.
  const project = await Project.findOne({
    _id: new Types.ObjectId(projectId),
    deletedAt: null,
  })
    .select('_id')
    .lean()
    .exec();
  if (!project) {
    recorder.record('RESOLVE_JOB', 'FAILED', 'project not found');
    return { outcome: 'BLOCKED', reason: 'PROJECT_NOT_FOUND', steps: recorder.steps };
  }

  const job = await findExportableJob(projectId);
  if (!job || !job.upload) {
    recorder.record('RESOLVE_JOB', 'FAILED', 'no finalized capture job');
    return { outcome: 'BLOCKED', reason: 'NOT_EXPORTABLE', steps: recorder.steps };
  }
  const upload = job.upload;
  recorder.record('RESOLVE_JOB', 'OK', `job ${job.id as string} (${job.state})`);

  // ── Repeat-press guard, BEFORE any S3 work. The unique index remains the
  // race authority; this is the cheap common case (someone pressed twice) and
  // it is what makes the button idempotent by default.
  const idempotencyKey = manualGenerationIdempotencyKey(job._id, force);
  if (!force) {
    const existing = await ProjectModel.findOne({
      createdByUserId: new Types.ObjectId(actor.userId),
      idempotencyKey,
    })
      .select('_id')
      .lean()
      .exec();
    if (existing) {
      recorder.record('GUARDS', 'SKIPPED', 'a generation already exists for this capture');
      return {
        outcome: 'REPLAYED',
        modelId: existing._id.toString(),
        steps: recorder.steps,
      };
    }
  }

  // ── Step 2: the capture manifest. An absent or unparseable document is not
  // an infrastructure failure — it is a capture we cannot select from, and the
  // selector already has a typed refusal for exactly that. Only a TRANSPORT
  // failure throws (getObjectText returns `absent` only on a true 404).
  let manifest: unknown;
  try {
    const object = await getObjectText(upload.rawBucket, upload.manifestKey);
    if (object.outcome === 'absent') {
      manifest = undefined;
      recorder.record('LOAD_MANIFEST', 'FAILED', 'capture manifest is not in S3');
    } else {
      try {
        manifest = JSON.parse(object.body);
        recorder.record('LOAD_MANIFEST', 'OK', `${object.body.length} bytes`);
      } catch {
        manifest = undefined;
        recorder.record('LOAD_MANIFEST', 'FAILED', 'manifest is not valid JSON');
      }
    }
  } catch (err: unknown) {
    recorder.record('LOAD_MANIFEST', 'FAILED', 'could not read the manifest object');
    throw new GenerationInfrastructureError(
      'Could not read the capture manifest.',
      recorder.steps,
      err
    );
  }

  // ── Step 3: what is ACTUALLY in the bucket, as keys RELATIVE to rawPrefix.
  //
  // HAZARD (live-readiness fix B2): absolute bucket keys here match nothing the
  // manifest derives, so every candidate is dropped and the selector declines
  // 100% of real captures. The slice below is load-bearing.
  //
  // Soft-deleted photos need no special casing: the delete MOVES the object to
  // `deleted/`, so its original relative key is simply absent and drops out.
  // The reserved `model-input/` namespace is excluded to mirror the capture
  // processor — those are staff-edited copies, not capture photos.
  let availableKeys: string[];
  try {
    const modelInputPrefix = `${upload.rawPrefix}${MODEL_INPUT_KEY_PREFIX}`;
    availableKeys = (await listObjectsUnderPrefix(upload.rawBucket, upload.rawPrefix))
      .filter((object) => !object.key.startsWith(modelInputPrefix))
      .filter((object) => object.key.startsWith(upload.rawPrefix))
      .map((object) => object.key.slice(upload.rawPrefix.length));
    recorder.record('LIST_OBJECTS', 'OK', `${availableKeys.length} objects under the job prefix`);
  } catch (err: unknown) {
    recorder.record('LIST_OBJECTS', 'FAILED', 'could not list the job prefix');
    throw new GenerationInfrastructureError(
      'Could not list the capture files.',
      recorder.steps,
      err
    );
  }

  // ── Step 4: the selector. Spread first, sharpness second — and a DECLINE is
  // a saved generation, not a bug.
  const selection = selectPhotosForAutoGeneration(manifest, {
    minBlurScore: env.AUTO_MODEL_MIN_BLUR_SCORE,
    availableKeys,
  });
  const trace = selection.trace ?? emptySelectionTrace();
  if (selection.outcome === 'DECLINED') {
    recorder.record('SELECT_PHOTOS', 'FAILED', describeDecline(selection.reason, trace));
    return {
      outcome: 'DECLINED',
      reason: selection.reason,
      steps: recorder.steps,
      trace,
    };
  }
  recorder.record('SELECT_PHOTOS', 'OK', selection.reason);

  // ── Step 5: the spend ceiling. Automatic and button-triggered generations
  // count against ONE pool — it is the same money, and a per-source cap would
  // just be two ways to spend twice as much. Staff get a higher ceiling.
  const cap = hasRoleAtLeast(actor.role, 'MODEL_ARTIST')
    ? env.MANUAL_MODEL_MAX_PER_STAFF_PER_DAY
    : env.MANUAL_MODEL_MAX_PER_USER_PER_DAY;
  const recentCount = await countServerSelectedGenerationsInLast24h(actor.userId);
  if (recentCount >= cap) {
    recorder.record('GUARDS', 'FAILED', `${recentCount}/${cap} generations in the last 24h`);
    return { outcome: 'BLOCKED', reason: 'USER_CAP_REACHED', steps: recorder.steps };
  }
  recorder.record('GUARDS', 'OK', `${recentCount}/${cap} in the last 24h${force ? ', forced' : ''}`);

  // ── Step 6: enqueue, through the SAME service the staff path uses — it owns
  // the record-before-job ordering, the containment check, and the idempotency
  // replay. A second create path here would drift from the money contract.
  const result = await createMeshyModelRequest({
    projectId,
    // PIN the job (live-readiness fix B4). Omitting it re-resolves the
    // project's newest exportable job, so keys selected from job A get
    // presigned under job B's prefix if a recapture finalizes mid-flight.
    jobId: job._id,
    keys: selection.keys,
    actor,
    idempotencyKey,
    createdByManualButton: true,
  });

  switch (result.outcome) {
    case 'CREATED': {
      recorder.record('ENQUEUE', 'OK', `${selection.keys.length} photos queued for generation`);
      const modelId = result.model.id as string;
      await persistGenerationTrace(modelId, {
        steps: recorder.steps,
        selection: toStoredSelection(trace),
        requestedBy: 'MANUAL',
      });
      return { outcome: 'ENQUEUED', modelId, steps: recorder.steps, trace };
    }
    case 'REPLAYED':
      // The unique index caught a concurrent press. The winner's generation
      // stands; we deliberately do NOT enqueue a second one.
      recorder.record('ENQUEUE', 'SKIPPED', 'an identical request was already in flight');
      return {
        outcome: 'REPLAYED',
        modelId: result.model.id as string,
        steps: recorder.steps,
      };
    case 'PROJECT_NOT_FOUND':
      recorder.record('ENQUEUE', 'FAILED', 'project disappeared mid-request');
      return { outcome: 'BLOCKED', reason: 'PROJECT_NOT_FOUND', steps: recorder.steps };
    case 'NOT_EXPORTABLE':
      recorder.record('ENQUEUE', 'FAILED', 'capture job is no longer exportable');
      return { outcome: 'BLOCKED', reason: 'NOT_EXPORTABLE', steps: recorder.steps };
    default:
      // INVALID_COUNT / INVALID_KEY. Unreachable by construction — the selector
      // only ever emits 3–4 contained relative keys — so reaching here means
      // the two have drifted apart, which is a defect and not a user outcome.
      recorder.record('ENQUEUE', 'FAILED', `selection rejected: ${result.outcome}`);
      throw new GenerationInfrastructureError(
        `The selected photos were rejected by the create path (${result.outcome}).`,
        recorder.steps
      );
  }
}

/**
 * The one-line staff explanation of a decline — the counters that ACTUALLY
 * decided it, not just the reason code.
 *
 * `droppedNoBlurScore` is called out because it is the expected answer on any
 * capture packed before 2026-07-21: the bundle packer did not thread blurScore
 * into the manifest until then, and the selector requires it. Without this
 * line, that data-age problem reads as a broken selector.
 */
function describeDecline(reason: AutoSelectionDeclineReason, trace: AutoSelectionTrace): string {
  const parts = [
    `pool=${trace.poolSize}/${trace.photosInManifest} (${trace.ringUsed})`,
    `noBlurScore=${trace.droppedNoBlurScore}`,
    `missingObject=${trace.droppedMissingObject}`,
    `unresolvableKey=${trace.droppedUnresolvableKey}`,
    `belowFloor(${trace.minBlurScoreUsed})=${trace.belowBlurFloor}`,
    `quadrants=[${trace.quadrantHistogram.join(',')}]`,
  ];
  return `${reason}: ${parts.join(', ')}`;
}

/** Reads the live kill switch. Fail-CLOSED — see isRemotelyEnabled in
 * autoModelGenerationService: an unreadable store means we cannot confirm the
 * switch, and the downside of guessing wrong is spending money. */
async function isRemotelyEnabled(): Promise<boolean> {
  try {
    return (await getServerFlag(MANUAL_MODEL_FLAG_KEY)) !== false;
  } catch {
    return false;
  }
}

/** Defensive fallback: the selector always populates a trace, but the field is
 * optional on its result type so old callers stay valid. */
function emptySelectionTrace(): AutoSelectionTrace {
  return {
    ringUsed: 'ALL',
    photosInManifest: 0,
    poolSize: 0,
    droppedUnresolvableKey: 0,
    droppedMissingObject: 0,
    droppedNoBlurScore: 0,
    belowBlurFloor: 0,
    warnedExcluded: 0,
    minBlurScoreUsed: env.AUTO_MODEL_MIN_BLUR_SCORE,
    segmentCountUsed: null,
    quadrantHistogram: [0, 0, 0, 0],
    unplacedCount: 0,
    chosen: [],
  };
}

/** Accumulates steps with their own wall-clock durations. */
class StepRecorder {
  readonly steps: GenerationStep[] = [];
  private last = Date.now();

  record(step: GenerationStepName, status: GenerationStepStatus, detail?: string): void {
    const now = Date.now();
    this.steps.push({
      step,
      status,
      ...(detail ? { detail } : {}),
      at: new Date(now).toISOString(),
      durationMs: now - this.last,
    });
    this.last = now;
  }
}
