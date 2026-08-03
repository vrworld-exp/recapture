// src/worker/processors/meshyModelProcessor.ts
//
// The MESHY_MODEL_GENERATION processor: turn a staff user's 3–4 photo selection
// into a 3D model via Meshy AI, re-hosted on OUR S3.
// (docs/meshy-integration-implementation-prompt.md)
//
// This runs BESIDE the capture pipeline and shares none of its stages — it is a
// single logical unit of work: submit → poll → re-host. It reuses the pipeline's
// fenced stage writes (stageTransitions.ts) purely for their two side effects:
// LEASE RENEWAL and cancel/steal detection.
//
// ── THE MONEY CONTRACT (the reason this file is careful) ────────────────────
// A Meshy generation costs credits, and the worker may re-run this processor at
// any time (crash, lease takeover, retry-after-backoff). Two guards keep a
// re-run at ZERO extra cost:
//   1. `meshyTaskId` is persisted on the ProjectModel record the INSTANT the
//      task is created — a re-claim resumes polling it and never resubmits;
//   2. artifact keys are deterministic per model — a repeated re-host overwrites.
// Third guard, upstream: the create endpoint's Idempotency-Key (a double-tap
// never reaches here twice).
//
// Error routing (see meshyClient's mapping): plain Error → the worker's
// retry/backoff; NonRetryableJobError → terminal FAILED with no retry, so a
// quota failure can never retry-burn credits.
import axios from 'axios';
import { BUCKET_ARTIFACTS, CLOUDFRONT_BASE } from '@/config/s3';
import { env } from '@/config/env';
import { Job } from '@/models/Job';
import { ProjectModel, type IProjectModel } from '@/models/ProjectModel';
import type { ModelArtifacts, ModelProgressPhase } from '@/models/types/projectModel.types';
import { presignObjectGetUrl, putObjectBytes } from '@/services/s3ObjectStore';
import {
  getMeshyClient,
  MeshyErrorCode,
  type MeshyTask,
} from '@/worker/engine/meshy/meshyClient';
import { enterStage, recordStageProgress } from '@/worker/stageTransitions';
import { log } from '@/worker/workerLog';
import {
  DEFAULT_MAX_ATTEMPTS,
  NonRetryableJobError,
  type JobProcessor,
  type WorkerJob,
} from '@/worker/workerTypes';

/** Per-model artifact prefix — keeps each generation's output separate, so a
 * regenerate never overwrites the attempt an artist may still want to compare
 * (and makes a record's storage self-contained). */
function modelArtifactPrefix(rawPrefix: string, modelId: string): string {
  return `${rawPrefix}models/${modelId}/`;
}

/**
 * Publishes "what the worker is doing right now" onto the record, for the staff
 * progress UI (the admin app polls the models list while a record is pending).
 *
 * STRICTLY BEST-EFFORT: display data must never fail or delay a paid
 * generation, so errors are swallowed and the write is fenced on
 * `status: 'PROCESSING'` — it can never resurrect a record that has already
 * reached a terminal state.
 */
async function reportProgress(
  record: IProjectModel,
  phase: ModelProgressPhase,
  percent: number
): Promise<void> {
  const clamped = Math.max(0, Math.min(100, Math.round(percent)));
  try {
    await ProjectModel.updateOne(
      { _id: record._id, status: 'PROCESSING' },
      { $set: { progress: { phase, percent: clamped } } }
    ).exec();
  } catch {
    // Ignored by design — the next tick (or the terminal status) supersedes it.
  }
}

/** Removes the live progress once the record is terminal — SUCCEEDED/FAILED
 * carry their own truth and a stale "FINALIZING 100%" would only confuse. */
async function clearProgress(record: IProjectModel): Promise<void> {
  try {
    await ProjectModel.updateOne({ _id: record._id }, { $unset: { progress: 1 } }).exec();
  } catch {
    // Best-effort for the same reason as reportProgress; clients ignore
    // `progress` on terminal statuses anyway.
  }
}

export const meshyModelProcessor: JobProcessor = async (job) => {
  const claimedBy = job.claimedBy;
  const modelId = (job.payload as { modelId?: unknown } | undefined)?.modelId;
  if (!claimedBy || typeof modelId !== 'string') {
    // Malformed by construction — the create service always writes payload.modelId
    // and the loop always stamps claimedBy. Retrying cannot fix either.
    throw new NonRetryableJobError(
      'MODEL_JOB_MALFORMED',
      'Generation job is missing its claim or payload.modelId.'
    );
  }

  const record = await ProjectModel.findById(modelId).exec();
  if (!record) {
    throw new NonRetryableJobError(
      'MODEL_RECORD_MISSING',
      'The model record this job was enqueued for no longer exists.'
    );
  }

  // The capture job the selected photos live under — resolved from the record
  // (not re-derived), so the keys resolve against the exact prefix the staff
  // user selected from.
  const captureJob = await Job.findById(record.jobId).exec();
  if (!captureJob?.upload) {
    throw new NonRetryableJobError(
      'MODEL_SOURCE_MISSING',
      'The capture job holding the selected photos has no upload block.'
    );
  }
  const { rawBucket, rawPrefix } = captureJob.upload;

  // Enter the fenced stage: renews the lease and gives every later
  // recordStageProgress a pointer to fence against. PROCESSING is the only
  // stage this job type uses — Meshy is one async task, not three stages.
  await enterStage(job._id, claimedBy, 'PROCESSING');
  await setStatus(record, 'PROCESSING');
  await reportProgress(record, 'PREPARING', 0);

  try {
    const task = await submitOrResume(job, record, rawBucket, rawPrefix, claimedBy);
    await reportProgress(record, 'FINALIZING', 100);
    const artifacts = await rehostArtifacts(task, record, rawPrefix);

    record.status = 'SUCCEEDED';
    record.artifacts = artifacts;
    record.error = undefined;
    await record.save();
    await clearProgress(record);

    log('info', 'Meshy model generated', {
      jobId: job._id,
      modelId,
      projectId: record.projectId,
    });
    // Only OUR keys/URLs — a Meshy URL must never reach the DB (they expire).
    return { source: 'meshy', modelId, artifacts: artifacts.cdnUrls };
  } catch (err: unknown) {
    await failRecordIfTerminal(job, record, err);
    throw err;
  }
};

/**
 * The resume guard. If the record already names a Meshy task, that task was
 * already PAID FOR — poll it. Only a record with no task id submits, and the id
 * is persisted before anything else can throw.
 */
async function submitOrResume(
  job: WorkerJob,
  record: IProjectModel,
  rawBucket: string,
  rawPrefix: string,
  claimedBy: string
): Promise<MeshyTask> {
  const client = getMeshyClient();

  if (record.meshyTaskId) {
    log('info', 'Resuming existing Meshy task — not resubmitting', {
      jobId: job._id,
      modelId: record.id,
    });
    return pollToCompletion(job, record, record.meshyTaskId, claimedBy);
  }

  // Presigned GETs let Meshy fetch straight from our private raw bucket. They
  // are bearer credentials for those objects — short-lived, and NEVER logged.
  const imageUrls = await Promise.all(
    record.selectedKeys.map((key) =>
      presignObjectGetUrl(rawBucket, `${rawPrefix}${key}`, env.MESHY_SOURCE_URL_TTL_SECONDS)
    )
  );

  const { taskId } = await client.createMultiImageTask(imageUrls);
  // ── The critical write. Credits are spent as of the line above; if the
  // process dies before this lands, the re-claim resubmits and pays twice.
  // Nothing else may come between.
  record.meshyTaskId = taskId;
  await record.save();

  log('info', 'Meshy task submitted', {
    jobId: job._id,
    modelId: record.id,
    imageCount: imageUrls.length,
  });
  return pollToCompletion(job, record, taskId, claimedBy);
}

/**
 * Polls until the task reaches a terminal status, or MESHY_TASK_TIMEOUT_MS.
 *
 * Every tick calls recordStageProgress, which renews the claim lease — without
 * it, a generation outlasting WORKER_CLAIM_TIMEOUT_MS would be re-claimed
 * mid-flight by another worker. It also THROWS JobCanceledError/ClaimLostError
 * when the job is canceled or stolen; those must propagate (the worker loop
 * goes silent and the owner of the outcome takes over), so they are deliberately
 * not caught here — we only best-effort cancel the Meshy task on the way out.
 */
async function pollToCompletion(
  job: WorkerJob,
  record: IProjectModel,
  taskId: string,
  claimedBy: string
): Promise<MeshyTask> {
  const client = getMeshyClient();
  const deadline = Date.now() + env.MESHY_TASK_TIMEOUT_MS;

  for (;;) {
    const task = await client.getTask(taskId);
    // Publish Meshy's own percent for the staff UI — even on the terminal
    // tick, so the record never shows a stale early number.
    await reportProgress(record, 'GENERATING', task.progress);

    if (task.status === 'SUCCEEDED') return task;
    if (task.status === 'FAILED') {
      throw new NonRetryableJobError(
        MeshyErrorCode.GENERATION_FAILED,
        'Meshy could not generate a model from the selected photos.',
        task.taskError
      );
    }
    if (task.status === 'CANCELED') {
      throw new NonRetryableJobError(
        MeshyErrorCode.GENERATION_CANCELED,
        'The Meshy generation was canceled.'
      );
    }

    if (Date.now() >= deadline) {
      // Plain Error: a slow task may still finish, and the retry RESUMES this
      // same task id (no new charge). Bounded by the job's maxAttempts.
      throw new Error(
        `Meshy task did not finish within ${env.MESHY_TASK_TIMEOUT_MS}ms — will resume on retry`
      );
    }

    try {
      await recordStageProgress(job._id, claimedBy, 'PROCESSING', task.progress);
    } catch (err: unknown) {
      // Canceled or claim lost. We are the losing side: stop touching the job,
      // and try to stop the (paid, now pointless) Meshy task on the way out.
      await client.cancelTask(taskId);
      throw err;
    }

    await sleep(env.MESHY_POLL_INTERVAL_MS);
  }
}

/** One re-hosted file: what to download and where it lands. */
interface RehostTarget {
  url: string;
  filename: string;
  contentType: string;
}

/**
 * Downloads Meshy's results and re-uploads them to BUCKET_ARTIFACTS.
 *
 * This is not an optimization — it is a correctness requirement: Meshy's URLs
 * expire (`expires_at`), so persisting one would give us a model link that dies.
 * Only the resulting CloudFront URLs are ever stored (contract #5).
 */
async function rehostArtifacts(
  task: MeshyTask,
  record: IProjectModel,
  rawPrefix: string
): Promise<ModelArtifacts> {
  const glbUrl = task.modelUrls.glb;
  if (!glbUrl) {
    // GLB is the mandatory output — the app's viewer renders it. A SUCCEEDED
    // task without one is unusable, and re-running would only pay again.
    throw new NonRetryableJobError(
      MeshyErrorCode.GENERATION_FAILED,
      'Meshy reported success but returned no GLB model.'
    );
  }

  const prefix = modelArtifactPrefix(rawPrefix, record.id as string);
  const targets: RehostTarget[] = [
    { url: glbUrl, filename: 'model.glb', contentType: 'model/gltf-binary' },
    ...(task.modelUrls.usdz
      ? [{ url: task.modelUrls.usdz, filename: 'model.usdz', contentType: 'model/vnd.usdz+zip' }]
      : []),
    // PNG, not JPEG: the generation preset sets `alpha_thumbnail: true`, so
    // Meshy's poster comes back with a transparent background (what the dark
    // menu cards need). Serving those bytes as image/jpeg from CloudFront under
    // an immutable cache header would be wrong and uncacheable to undo — this
    // filename and MESHY_PRESET.alpha_thumbnail must change together.
    ...(task.thumbnailUrl
      ? [{ url: task.thumbnailUrl, filename: 'preview.png', contentType: 'image/png' }]
      : []),
  ];

  for (const target of targets) {
    const bytes = await download(target.url);
    await putObjectBytes(BUCKET_ARTIFACTS, `${prefix}${target.filename}`, bytes, target.contentType);
  }

  const has = (filename: string): boolean => targets.some((t) => t.filename === filename);
  return {
    glbKey: `${prefix}model.glb`,
    ...(has('model.usdz') ? { usdzKey: `${prefix}model.usdz` } : {}),
    ...(has('preview.png') ? { previewImageKey: `${prefix}preview.png` } : {}),
    cdnUrls: {
      glb: `${CLOUDFRONT_BASE}/${prefix}model.glb`,
      ...(has('model.usdz') ? { usdz: `${CLOUDFRONT_BASE}/${prefix}model.usdz` } : {}),
      ...(has('preview.png') ? { preview: `${CLOUDFRONT_BASE}/${prefix}preview.png` } : {}),
    },
  };
}

/**
 * Fetches one Meshy result URL. A failure here throws a PLAIN Error → retry:
 * the task id is already persisted, so the retry resumes it and re-downloads
 * without a second generation charge. The URL is never put in the message.
 */
async function download(url: string): Promise<Uint8Array> {
  try {
    const res = await axios.get<ArrayBuffer>(url, {
      responseType: 'arraybuffer',
      timeout: 120_000,
    });
    return new Uint8Array(res.data);
  } catch {
    throw new Error('Failed to download a generated model artifact from Meshy');
  }
}

/**
 * Moves the record to FAILED only when nothing more will run for it: either the
 * error is terminal, or this was the job's last attempt. On a retryable error
 * with attempts remaining, the record stays PROCESSING — which is the truth,
 * since the worker will pick it up again after the backoff.
 *
 * Cancel/claim-loss are neither: another owner now decides the outcome, so the
 * record is left exactly as it is.
 */
async function failRecordIfTerminal(
  job: WorkerJob,
  record: IProjectModel,
  err: unknown
): Promise<void> {
  const isTerminal = err instanceof NonRetryableJobError;
  const attemptsSoFar = job.attempts ?? 0;
  const maxAttempts = job.maxAttempts ?? DEFAULT_MAX_ATTEMPTS;
  const isFinalAttempt = attemptsSoFar + 1 >= maxAttempts;

  const name = (err as { name?: string })?.name;
  if (name === 'JobCanceledError' || name === 'ClaimLostError') return;
  if (!isTerminal && !isFinalAttempt) return;

  record.status = 'FAILED';
  record.error = {
    code: isTerminal ? (err as NonRetryableJobError).code : 'PROCESSING_FAILED',
    // Our own messages only (meshyClient never interpolates a response body or
    // a presigned URL into one), so this is safe to show staff.
    message: err instanceof Error ? err.message : 'Model generation failed.',
  };
  await record.save();
  await clearProgress(record);
}

async function setStatus(record: IProjectModel, status: IProjectModel['status']): Promise<void> {
  if (record.status === status) return;
  record.status = status;
  await record.save();
}

function sleep(ms: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, ms));
}
