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
import { Types } from 'mongoose';
import { BUCKET_ARTIFACTS, CLOUDFRONT_BASE } from '@/config/s3';
import { env } from '@/config/env';
import { Job } from '@/models/Job';
import { ProjectModel, type IProjectModel } from '@/models/ProjectModel';
import type { ModelArtifacts } from '@/models/types/projectModel.types';
import { presignObjectGetUrl, putObjectBytes } from '@/services/s3ObjectStore';
import {
  getMeshyClient,
  MeshyErrorCode,
  type MeshyTask,
} from '@/worker/engine/meshy/meshyClient';
import {
  clearProgress,
  failRecordIfTerminal,
  reportProgress,
  setStatus,
} from '@/worker/processors/modelRecordState';
import {
  markModelFailedOnProducts,
  promoteModelToProducts,
  syncPendingModelStatus,
} from '@/services/catalogModelPromotionService';
import { enterStage, recordStageProgress } from '@/worker/stageTransitions';
import { log } from '@/worker/workerLog';
import { NonRetryableJobError, type JobProcessor, type WorkerJob } from '@/worker/workerTypes';

/** Per-model artifact prefix — keeps each generation's output separate, so a
 * regenerate never overwrites the attempt an artist may still want to compare
 * (and makes a record's storage self-contained). */
function modelArtifactPrefix(rawPrefix: string, modelId: string): string {
  return `${rawPrefix}models/${modelId}/`;
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

  // Keep the menu rows in step with the record. A dish linked while this model
  // was QUEUED would otherwise read QUEUED for the whole generation, and a
  // client polling it has nothing to show. Non-fatal for the same reason
  // promotion is — see the comment on that call below.
  try {
    await syncPendingModelStatus(record._id as Types.ObjectId, 'PROCESSING');
  } catch (err: unknown) {
    log('warn', 'Could not move linked products to PROCESSING; model is unaffected', {
      jobId: job._id,
      modelId,
      err: String(err),
    });
  }

  try {
    const task = await submitOrResume(job, record, rawBucket, rawPrefix, claimedBy);
    await reportProgress(record, 'FINALIZING', 100);
    const artifacts = await rehostArtifacts(task, record, rawPrefix);

    record.status = 'SUCCEEDED';
    record.artifacts = artifacts;
    record.error = undefined;
    await record.save();
    await clearProgress(record);

    // LAST, AND NON-FATAL — the try/catch IS THE CONTRACT, not defensiveness.
    // Credits are already spent and the record above is complete and correct; a
    // promotion that fails costs a dish its AR button until the next promotion
    // or an owner edit, while a THROWN promotion failure would fail the whole
    // job and let the retry pay Meshy again. One of those is recoverable.
    try {
      await promoteModelToProducts(record._id as Types.ObjectId);
    } catch (err: unknown) {
      log('warn', 'Model promotion failed; model is unaffected', {
        jobId: job._id,
        modelId,
        err: String(err),
      });
    }

    log('info', 'Meshy model generated', {
      jobId: job._id,
      modelId,
      projectId: record.projectId,
    });
    // Only OUR keys/URLs — a Meshy URL must never reach the DB (they expire).
    return { source: 'meshy', modelId, artifacts: artifacts.cdnUrls };
  } catch (err: unknown) {
    await failRecordIfTerminal(job, record, err, 'PROCESSING_FAILED', 'Model generation failed.');

    // Same contract on the way down: linked dishes must reach FAILED rather
    // than sitting on PROCESSING forever, but a bookkeeping write must not
    // replace the real error the worker needs to classify for retry/backoff.
    // Only fires when the record actually went terminal — a retryable failure
    // leaves the products PROCESSING, which is still the truth.
    try {
      if (record.status === 'FAILED') {
        await markModelFailedOnProducts(record._id as Types.ObjectId);
      }
    } catch (markErr: unknown) {
      log('warn', 'Could not mark linked products FAILED', {
        jobId: job._id,
        modelId,
        err: String(markErr),
      });
    }

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
    ...(task.thumbnailUrl
      ? [{ url: task.thumbnailUrl, filename: 'preview.jpg', contentType: 'image/jpeg' }]
      : []),
  ];

  // The GLB's size is recorded as it goes by — it is the only input to the
  // "is this worth optimizing?" rule, and the bytes are already in hand here,
  // so measuring it later would mean a needless HEAD round trip per record.
  let glbBytes: number | undefined;
  for (const target of targets) {
    const bytes = await download(target.url);
    if (target.filename === 'model.glb') glbBytes = bytes.byteLength;
    await putObjectBytes(BUCKET_ARTIFACTS, `${prefix}${target.filename}`, bytes, target.contentType);
  }

  const has = (filename: string): boolean => targets.some((t) => t.filename === filename);
  return {
    glbKey: `${prefix}model.glb`,
    ...(glbBytes !== undefined ? { glbBytes } : {}),
    ...(has('model.usdz') ? { usdzKey: `${prefix}model.usdz` } : {}),
    ...(has('preview.jpg') ? { previewImageKey: `${prefix}preview.jpg` } : {}),
    cdnUrls: {
      glb: `${CLOUDFRONT_BASE}/${prefix}model.glb`,
      ...(has('model.usdz') ? { usdz: `${CLOUDFRONT_BASE}/${prefix}model.usdz` } : {}),
      ...(has('preview.jpg') ? { preview: `${CLOUDFRONT_BASE}/${prefix}preview.jpg` } : {}),
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

function sleep(ms: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, ms));
}
