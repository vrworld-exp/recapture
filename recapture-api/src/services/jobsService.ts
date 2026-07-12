// src/services/jobsService.ts
//
// Job creation for the upload pipeline (POST /jobs): validates the request
// against the project, persists the job, and derives the job-scoped UPLOAD PLAN
// the mobile upload engine consumes.
//
// ── Contract reconciliation (why nothing is presigned here) ──────────────────
// The mobile chunked-upload engine (lib/application/upload/multipart_upload_api
// .dart) initiates each file's multipart upload SEPARATELY, sending the file's
// size + part count — which the server cannot know at job-creation time. So the
// plan returned here carries the job-scoped KEY SPACE + multipart limits + a
// bounded validity window; the presigned URLs themselves are issued by the
// per-file initiate/part-url endpoints (separate task) within that window.
// Because no presigned URL is generated here, job creation is a SINGLE document
// insert — there is no half-created "job without a plan" state to clean up.
//
// KEYS: the engine derives each file's key from the client bundle's relative
// layout (images/{EYE|TOP|LOW}/eye_0001.jpg + capture_manifest.json), so the
// plan does NOT enumerate per-file slots — it provides the authoritative
// `keyPrefix` (+ a template documenting the rule) that the initiate endpoint
// must enforce as a containment check. The prefix and manifest key come from
// the CANONICAL key utility (@/utils/s3Keys) — the single source of truth for
// the {env}/{userId}/{projectId}/{jobId}/… scheme — never inline templates.
import { Types } from 'mongoose';
import { Job, type IJob } from '@/models/Job';
import { Project } from '@/models/Project';
import { type ObjectSize } from '@/models/types/capture.types';
import {
  DEFAULT_CAPTURE_FLOW_VARIANT,
  expectedImageCount,
  expectedPerRing,
  minimumImageCount,
  minimumPerRing,
  ringsForVariant,
  type CaptureFlowVariant,
} from '@/models/types/captureVariants';
import { BUCKET_RAW } from '@/config/s3';
import { env } from '@/config/env';
import {
  type CreateJobInput,
  type InitiateUploadInput,
  type PartUrlInput,
  type CompleteUploadInput,
} from '@/validation/jobSchemas';
import {
  PART_SIZE_MIN,
  MAX_PARTS,
  MAX_PART_SIZE,
  PRESIGN_EXPIRES_SECONDS,
  initiateMultipartUpload,
  completeMultipartUpload,
  presignPartUrl,
  presignPartUrls,
} from '@/services/s3MultipartService';
import { getObjectText, countObjectsUnderPrefix } from '@/services/s3ObjectStore';
import { updateProjectStatus } from '@/services/projectsService';
import { buildJobKeyPrefix, buildManifestKey } from '@/utils/s3Keys';
import { validateCaptureManifest } from '@/services/manifestValidationService';
import type { ManifestValidationError } from '@/models/types/manifest.types';

// The S3 hard limits live with the S3 helpers; re-exported here because the
// create response echoes them in the upload plan.
export { PART_SIZE_MIN, MAX_PARTS };

// Client wire values (lowercase, same as POST /projects) ↔ model enums.
type WireSize = CreateJobInput['objectSize'];
const WIRE_TO_MODEL: Record<WireSize, ObjectSize> = {
  small: 'SMALL',
  medium: 'MEDIUM',
  large: 'LARGE',
};
const MODEL_TO_WIRE: Record<ObjectSize, WireSize> = {
  SMALL: 'small',
  MEDIUM: 'medium',
  LARGE: 'large',
};

/** Job DTO for the create response — wire-shaped (lowercase size), no internals. */
export interface JobDto {
  id: string;
  projectId: string;
  state: IJob['state'];
  objectSize: WireSize;
  captureVariant: CaptureFlowVariant;
  expectedFilesCount: number;
  createdAt: string;
}

/**
 * The job-scoped upload plan the mobile engine binds to. Carries the key space
 * and multipart limits — NOT presigned URLs (see the header note).
 */
export interface UploadPlan {
  uploadMethod: 'S3_PRESIGNED_MULTIPART';
  bucket: string;
  /** All of this job's objects live under this prefix (containment-enforced). */
  keyPrefix: string;
  /** Where the capture manifest must be uploaded. */
  manifestKey: string;
  /** Key rule for every other file: keyPrefix + the bundle-relative path. */
  keyTemplate: string;
  /** The ONLY image LEVEL segments this job's plan covers (the variant's
   * rings) — an images/{LEVEL}/… key outside this set fails containment. */
  levels: readonly string[];
  /** ISO timestamp; per-file initiate calls are accepted until this instant. */
  expiresAt: string;
  partSizeMin: number;
  maxParts: number;
  expectedFilesCount: number;
}

/**
 * Outcome of a create attempt. As with the projects service, business cases are
 * discriminated results (never throws) and the route maps each to a status
 * code. `PROJECT_NOT_FOUND` covers missing, not-owned, AND soft-deleted (all →
 * 404, no existence leak).
 */
export type CreateJobResult =
  | { outcome: 'PROJECT_NOT_FOUND' }
  | { outcome: 'SIZE_MISMATCH'; projectSize: WireSize }
  | {
      outcome: 'COUNT_INCONSISTENT';
      minimum: number;
      maximum: number;
      captureVariant: CaptureFlowVariant;
    }
  | { outcome: 'IDEMPOTENCY_CONFLICT' }
  | { outcome: 'CREATED'; job: JobDto; uploadPlan: UploadPlan }
  | { outcome: 'REPLAYED'; job: JobDto; uploadPlan: UploadPlan };

/**
 * Creates an upload job for `userId`'s project (ownership token-resolved only).
 *
 * Validation layers, in order:
 *   1. project exists / is owned / not soft-deleted — nothing is created for an
 *      unauthorized project;
 *   2. the client's `objectSize` must MATCH the project's stored size (the
 *      project is authoritative; a mismatch is a client bug, not a preference);
 *   3. `expectedFilesCount` must land in the variant's valid RANGE —
 *      [minimumImageCount + 1, expectedImageCount + 1], both manifest-
 *      inclusive. The client lets a ring count as complete at
 *      MIN_RING_COVERAGE_PCT segment coverage, so a partial capture is a
 *      legitimate upload; the upper bound is still the variant's full total.
 *      The CLIENT-declared count is stored on the job unchanged and finalize
 *      demands an exact S3 match against that stored value — the range here
 *      only bounds what a declared count may be.
 *
 * IDEMPOTENCY: when `idempotencyKey` is provided, a repeat create with the same
 * key + same payload returns the ORIGINAL job and its plan (REPLAYED — the
 * plan's expiresAt is derived from the job's createdAt, so retries never extend
 * the window); the same key with a DIFFERENT payload is a conflict. The unique
 * (userId, idempotencyKey) index arbitrates concurrent duplicates: the losing
 * insert gets E11000 and resolves against the winner.
 */
export async function createJob(
  userId: string,
  input: CreateJobInput,
  idempotencyKey?: string
): Promise<CreateJobResult> {
  const ownerId = new Types.ObjectId(userId);

  const project = await Project.findOne({
    _id: new Types.ObjectId(input.projectId),
    userId: ownerId,
    deletedAt: null,
  }).exec();
  if (!project) {
    return { outcome: 'PROJECT_NOT_FOUND' };
  }

  const modelSize = WIRE_TO_MODEL[input.objectSize];
  if (project.objectSize !== modelSize) {
    return { outcome: 'SIZE_MISMATCH', projectSize: MODEL_TO_WIRE[project.objectSize] };
  }

  // Variant range: the flow variant bounds the image count — the coverage
  // floor (MIN_RING_COVERAGE_PCT per ring) below, the full ring total above.
  // The model's expectedFilesCount is manifest-INCLUSIVE, hence the +1s.
  const minimum = minimumImageCount(input.captureVariant) + 1;
  const maximum = expectedImageCount(input.captureVariant) + 1;
  if (input.expectedFilesCount < minimum || input.expectedFilesCount > maximum) {
    return {
      outcome: 'COUNT_INCONSISTENT',
      minimum,
      maximum,
      captureVariant: input.captureVariant,
    };
  }

  // Fast-path replay: an earlier create with this key already exists.
  if (idempotencyKey) {
    const existing = await Job.findOne({ userId: ownerId, idempotencyKey }).exec();
    if (existing) {
      return withUploadingStatus(replayOrConflict(existing, input));
    }
  }

  // The jobId is minted first so the key prefix can embed it; the insert is a
  // single document write (atomic — a failure persists nothing). Both keys
  // come from the canonical builder ({env} is config-driven there).
  const jobId = new Types.ObjectId();
  const keyScope = { userId, projectId: input.projectId, jobId: jobId.toHexString() };
  const rawPrefix = buildJobKeyPrefix(keyScope);

  try {
    const job = await Job.create({
      _id: jobId,
      projectId: project._id,
      userId: ownerId,
      state: 'CREATED',
      objectSize: modelSize,
      captureVariant: input.captureVariant,
      ...(idempotencyKey ? { idempotencyKey } : {}),
      upload: {
        uploadMethod: 'S3_PRESIGNED_MULTIPART',
        expectedFilesCount: input.expectedFilesCount,
        uploadedFilesCount: 0,
        checksumAlgo: 'md5',
        rawBucket: BUCKET_RAW,
        rawPrefix,
        manifestKey: buildManifestKey(keyScope),
      },
    });
    return withUploadingStatus({ outcome: 'CREATED', job: toDto(job), uploadPlan: planFor(job) });
  } catch (err) {
    // Concurrent duplicate with the same key: the unique index rejected this
    // insert — resolve against the job that won the race.
    if (idempotencyKey && isDuplicateKeyError(err)) {
      const winner = await Job.findOne({ userId: ownerId, idempotencyKey }).exec();
      if (winner) {
        return withUploadingStatus(replayOrConflict(winner, input));
      }
    }
    throw err;
  }
}

/**
 * Project lifecycle: a successful create outcome moves the parent project to
 * UPLOADING — strictly AFTER the job document is known to persist (a project
 * must never enter UPLOADING for a job that failed to insert). Idempotent
 * replays re-assert the status too: the duplicate-submission spec calls for
 * refreshing statusUpdatedAt, and it self-heals a crash that landed between
 * the original insert and its status write. A status-write failure PROPAGATES
 * (→ 500) rather than rolling back the job: this codebase uses sequential
 * writes, not transactions — the persisted-job/stale-status window is a known
 * MVP consistency gap (compensating logic is a future concern).
 */
async function withUploadingStatus(result: CreateJobResult): Promise<CreateJobResult> {
  if (result.outcome === 'CREATED' || result.outcome === 'REPLAYED') {
    await updateProjectStatus(result.job.projectId, 'UPLOADING');
  }
  return result;
}

/**
 * A repeat create against an existing keyed job: identical payload → replay the
 * original job + plan; different payload under the same key → conflict (409).
 */
function replayOrConflict(existing: IJob, input: CreateJobInput): CreateJobResult {
  const samePayload =
    existing.projectId.toHexString() === input.projectId &&
    existing.objectSize === WIRE_TO_MODEL[input.objectSize] &&
    variantOf(existing) === input.captureVariant &&
    existing.upload?.expectedFilesCount === input.expectedFilesCount;
  if (!samePayload) {
    return { outcome: 'IDEMPOTENCY_CONFLICT' };
  }
  return { outcome: 'REPLAYED', job: toDto(existing), uploadPlan: planFor(existing) };
}

/**
 * Derives the plan from the persisted job — deterministic, so a replay returns
 * byte-identical plan data. `expiresAt` is anchored to the job's createdAt
 * (bounded; retries never extend the window).
 */
function planFor(job: IJob): UploadPlan {
  const upload = job.upload!;
  return {
    uploadMethod: 'S3_PRESIGNED_MULTIPART',
    bucket: upload.rawBucket,
    keyPrefix: upload.rawPrefix,
    manifestKey: upload.manifestKey,
    keyTemplate: `${upload.rawPrefix}{relativePath}`,
    levels: ringsForVariant(variantOf(job)),
    expiresAt: planExpiresAt(job).toISOString(),
    partSizeMin: PART_SIZE_MIN,
    maxParts: MAX_PARTS,
    expectedFilesCount: upload.expectedFilesCount,
  };
}

/** The job's capture flow variant. The schema default backfills documents
 * predating the field on read; the ?? is a second belt for lean/legacy paths. */
function variantOf(job: IJob): CaptureFlowVariant {
  return job.captureVariant ?? DEFAULT_CAPTURE_FLOW_VARIANT;
}

/** The instant the job's upload plan stops accepting initiate/part-url calls. */
function planExpiresAt(job: IJob): Date {
  return new Date(job.createdAt.getTime() + env.UPLOAD_PLAN_TTL_SECONDS * 1000);
}

function toDto(job: IJob): JobDto {
  return {
    id: job.id as string,
    projectId: job.projectId.toHexString(),
    state: job.state,
    objectSize: MODEL_TO_WIRE[job.objectSize ?? 'MEDIUM'],
    captureVariant: variantOf(job),
    expectedFilesCount: job.upload?.expectedFilesCount ?? 0,
    createdAt: job.createdAt.toISOString(),
  };
}

function isDuplicateKeyError(err: unknown): boolean {
  return (
    typeof err === 'object' &&
    err !== null &&
    (err as { code?: number }).code === 11000
  );
}

// ── Per-file multipart initiate + presigned part URLs ─────────────────────────
//
// The presign step of the upload pipeline: the mobile engine calls this ONCE
// PER FILE (it alone knows each file's size/part plan), gets the S3 uploadId +
// presigned part-PUT URLs, streams the parts directly to S3, and later
// completes/aborts (separate endpoints). Deliberately STATELESS per file on the
// server: the client's durable UploadProgressStore is the resume authority and
// S3 is the uploadId authority — a server-side per-file mirror would be a
// second source of truth that drifts (the Job model has no files[] array by
// design). A repeated initiate for the same key mints a FRESH uploadId (the
// engine's re-initiate-once recovery); stale multipart uploads are for the
// abort endpoint + an S3 lifecycle rule (AbortIncompleteMultipartUpload) to
// reap — flag: that lifecycle rule must exist on the raw bucket.

/** Allowed charset for the key's job-relative remainder (mirrors the client's
 * deterministic bundle names — images/{RING}/eye_0001.jpg, capture_manifest.json). */
const KEY_REMAINDER_RE = /^[A-Za-z0-9._/-]+$/;
/** S3's hard maximum object-key length. */
const KEY_MAX_LENGTH = 1024;

export type UploadGuardFailure =
  | { outcome: 'JOB_NOT_FOUND' }
  | { outcome: 'JOB_NOT_UPLOADABLE'; state: IJob['state'] }
  | { outcome: 'PLAN_EXPIRED'; expiresAt: string }
  | { outcome: 'INVALID_KEY' };

export type InitiateUploadResult =
  | UploadGuardFailure
  | { outcome: 'PART_COUNT_INCONSISTENT'; minimum: number; maximum: number }
  | {
      outcome: 'INITIATED';
      uploadId: string;
      key: string;
      parts: Array<{ partNumber: number; url: string }>;
      /** ISO instant the presigned part URLs expire (per-part refresh after). */
      urlsExpireAt: string;
      /** True when this initiate flipped the job CREATED → UPLOADING. */
      uploadStarted: boolean;
    };

export type PartUrlResult = UploadGuardFailure | { outcome: 'SIGNED'; url: string };

export type CompleteUploadResult =
  | UploadGuardFailure
  | { outcome: 'COMPLETED'; key: string; etag: string };

/**
 * Initiates one file's S3 multipart upload and presigns ALL its part URLs (in
 * parallel — signing is local).
 *
 * Guards, in order: job exists + owned (404, no leak) → job state accepts
 * uploads (CREATED/UPLOADING; anything else 409) → the plan window is still
 * open (410 after `uploadPlan.expiresAt`) → the key is CONTAINED under the
 * job's `keyPrefix` with a conservative charset (the containment check the
 * create-job plan promised) → `partCount` must be achievable for `fileSize`
 * under S3's part-size limits.
 *
 * Nothing is persisted per file; the only mutation is the one-time job state
 * transition CREATED → UPLOADING (conditional update — race-safe, fires the
 * analytics latch exactly once). An S3 initiate failure therefore leaves no
 * half-initiated job state behind.
 */
export async function initiateFileUpload(
  userId: string,
  jobId: string,
  input: InitiateUploadInput
): Promise<InitiateUploadResult> {
  const guarded = await loadUploadableJob(userId, jobId, input.key);
  if ('outcome' in guarded) return guarded;
  const { job } = guarded;

  // partCount must be achievable: no part may exceed 5 GiB (lower bound) and
  // every non-final part must reach the 5 MiB floor (upper bound = the count
  // the minimum chunk size yields). The engine's planFileParts always lands in
  // this range; anything outside it is a client bug.
  const minimum = Math.max(1, Math.ceil(input.fileSize / MAX_PART_SIZE));
  const maximum = Math.min(MAX_PARTS, Math.max(1, Math.ceil(input.fileSize / PART_SIZE_MIN)));
  if (input.partCount < minimum || input.partCount > maximum) {
    return { outcome: 'PART_COUNT_INCONSISTENT', minimum, maximum };
  }

  const bucket = job.upload!.rawBucket;
  const uploadId = await initiateMultipartUpload(bucket, input.key);
  const parts = await presignPartUrls(bucket, input.key, uploadId, input.partCount);

  // One-time CREATED → UPLOADING. Conditional on the current state so exactly
  // one concurrent initiate performs (and reports) the transition.
  const flipped = await Job.findOneAndUpdate(
    { _id: job._id, state: 'CREATED' },
    { $set: { state: 'UPLOADING' } }
  ).exec();

  return {
    outcome: 'INITIATED',
    uploadId,
    key: input.key,
    parts,
    urlsExpireAt: new Date(Date.now() + PRESIGN_EXPIRES_SECONDS * 1000).toISOString(),
    uploadStarted: flipped !== null,
  };
}

/**
 * Re-presigns ONE part's URL after the original expired mid-session (the
 * engine's 403-recovery path). Same guards as initiate; no state is touched.
 * The uploadId is not server-validated — S3 rejects a stale/foreign uploadId
 * at PUT time, which the engine maps to its re-initiate recovery.
 */
export async function refreshUploadPartUrl(
  userId: string,
  jobId: string,
  input: PartUrlInput
): Promise<PartUrlResult> {
  const guarded = await loadUploadableJob(userId, jobId, input.key);
  if ('outcome' in guarded) return guarded;
  const { job } = guarded;

  const url = await presignPartUrl(
    job.upload!.rawBucket,
    input.key,
    input.uploadId,
    input.partNumber
  );
  return { outcome: 'SIGNED', url };
}

/**
 * Completes ONE file's multipart upload server-side (the client cannot — no
 * presigned complete exists and the SDK call needs credentials). Same guard
 * family as initiate via loadUploadableJob; deliberately persists NO per-file
 * state (the stateless per-file design — S3 is the authority). A stale or
 * foreign uploadId surfaces as S3's error → 500 via the error handler, same
 * policy as part-url: never pre-validated here.
 */
export async function completeFileUpload(
  userId: string,
  jobId: string,
  input: CompleteUploadInput
): Promise<CompleteUploadResult> {
  const guarded = await loadUploadableJob(userId, jobId, input.key);
  if ('outcome' in guarded) return guarded;
  const { job } = guarded;

  const etag = await completeMultipartUpload(
    job.upload!.rawBucket,
    input.key,
    input.uploadId,
    input.parts
  );
  return { outcome: 'COMPLETED', key: input.key, etag };
}

// ── Finalize: verify manifest + counts, enqueue, set QUEUED ───────────────────
//
// The COMMIT GATE between "files uploaded" and "processing started". Two
// verifications against what is ACTUALLY in S3 (never trusting the client):
// the manifest object exists at the job's manifestKey, and the object count
// under the job's prefix equals `expectedFilesCount` exactly (undershoot =
// incomplete upload, overshoot = stray/duplicate objects — both refuse to
// enqueue). Per the Job model's documented semantics, `expectedFilesCount` is
// the TOTAL object count INCLUDING the manifest, so the S3 count is compared
// as-is. A client-reported count, when supplied, is a cross-check only.
//
// "ENQUEUE" IS THE STATE FLIP: this codebase deliberately has no external
// queue — the Job model's own design comment says the P7 processing worker
// discovers work by polling `state: 'QUEUED'` via the {state, updatedAt}
// index. So the conditional UPLOADING/CREATED → QUEUED update IS the enqueue,
// which makes "transition + enqueue" atomic by construction and exactly-once
// under concurrency (one findOneAndUpdate wins; the loser re-reads and
// replays the winner's result). There is no failure window where the job is
// QUEUED but never enqueued, or enqueued but not QUEUED.

export type FinalizeJobResult =
  | { outcome: 'JOB_NOT_FOUND' }
  | { outcome: 'JOB_NOT_FINALIZABLE'; state: IJob['state'] }
  | {
      outcome: 'VERIFICATION_FAILED';
      reason:
        | 'manifest_missing'
        | 'count_mismatch'
        | 'reported_count_mismatch'
        | 'manifest_invalid';
      expected: number;
      /** The S3-listed count (null when the check never got that far). */
      actual: number | null;
      /** Per-rule findings when reason is manifest_invalid (content rules). */
      validationErrors?: ManifestValidationError[];
    }
  | {
      outcome: 'QUEUED';
      jobId: string;
      filesVerified: number;
      queuedAt: string;
      captureVariant: CaptureFlowVariant;
      /** True when this call found the job already queued (idempotent replay). */
      alreadyQueued: boolean;
    };

/**
 * Verifies and queues one job. Idempotent: an already-QUEUED job replays the
 * original result (no re-verification, no double-enqueue); CREATED/UPLOADING
 * verify and flip; anything else (processing/terminal) is a 409-shaped
 * conflict. An S3 failure surfaces as 500 with the job state untouched — a
 * retry re-finalizes cleanly.
 */
export async function finalizeJob(
  userId: string,
  jobId: string,
  reportedFilesCount?: number
): Promise<FinalizeJobResult> {
  const job = await Job.findOne({
    _id: new Types.ObjectId(jobId),
    userId: new Types.ObjectId(userId),
  }).exec();
  if (!job || !job.upload) {
    return { outcome: 'JOB_NOT_FOUND' };
  }

  if (job.state === 'QUEUED') {
    return queuedResult(job, true);
  }
  if (job.state !== 'CREATED' && job.state !== 'UPLOADING') {
    return { outcome: 'JOB_NOT_FINALIZABLE', state: job.state };
  }

  // The persisted rawPrefix/manifestKey ARE the canonical builder's output,
  // stored at create time — finalize verifies under the exact prefix the plan
  // advertised (writer and verifier share one source by construction). They
  // are deliberately NOT recomputed here: recomputing would silently re-point
  // verification if the env prefix or scheme ever changed mid-flight.
  const { rawBucket, rawPrefix, manifestKey, expectedFilesCount } = job.upload;

  // Verification 1: the manifest object must exist (the upload engine writes
  // it last, so its presence implies the client finished its upload pass). One
  // GET serves both this existence check and the content validation below.
  const manifestObject = await getObjectText(rawBucket, manifestKey);
  if (manifestObject.outcome === 'absent') {
    return {
      outcome: 'VERIFICATION_FAILED',
      reason: 'manifest_missing',
      expected: expectedFilesCount,
      actual: null,
    };
  }

  // Verification 2: the S3-listed object count (paginated; manifest included
  // per the model's expectedFilesCount semantics) must match EXACTLY.
  const actual = await countObjectsUnderPrefix(rawBucket, rawPrefix);
  if (actual !== expectedFilesCount) {
    return {
      outcome: 'VERIFICATION_FAILED',
      reason: 'count_mismatch',
      expected: expectedFilesCount,
      actual,
    };
  }

  // Cross-check only — S3 remains the authority even when the client reports.
  if (reportedFilesCount !== undefined && reportedFilesCount !== actual) {
    return {
      outcome: 'VERIFICATION_FAILED',
      reason: 'reported_count_mismatch',
      expected: expectedFilesCount,
      actual,
    };
  }

  // Verification 3: manifest CONTENT rules (pure, collect-all — every broken
  // rule reported in one pass). Bad JSON is a verification failure like any
  // other unreadable-manifest finding, never a 500. The expected ring set and
  // per-ring bounds are SERVER-derived from the job's captureVariant — the
  // client-authored manifest never attests its own minimums, and a declared
  // flowVariant that disagrees with the job is itself a finding. The per-ring
  // floor is the coverage minimum (a ring completed at MIN_RING_COVERAGE_PCT
  // is uploadable); the ceiling stays the variant's full per-ring count.
  let parsedManifest: unknown;
  try {
    parsedManifest = JSON.parse(manifestObject.body);
  } catch {
    parsedManifest = undefined; // → MANIFEST_UNREADABLE from the validator
  }
  const variant = variantOf(job);
  const variantRings = [...ringsForVariant(variant)];
  const validation = validateCaptureManifest(parsedManifest, {
    requiredLevels: variantRings,
    allowedLevels: variantRings,
    minPhotosPerLevel: minimumPerRing(variant),
    maxPhotosPerLevel: expectedPerRing(variant),
    expectedFlowVariant: variant,
  });
  if (!validation.valid) {
    return {
      outcome: 'VERIFICATION_FAILED',
      reason: 'manifest_invalid',
      expected: expectedFilesCount,
      actual,
      validationErrors: validation.errors,
    };
  }

  // The enqueue: one conditional update = atomic transition + exactly-once
  // queue entry. Concurrent finalizes race here; exactly one wins.
  const winner = await Job.findOneAndUpdate(
    { _id: job._id, state: { $in: ['CREATED', 'UPLOADING'] } },
    {
      $set: {
        state: 'QUEUED',
        queuedAt: new Date(),
        'upload.uploadedFilesCount': actual,
      },
    },
    { new: true }
  ).exec();

  if (winner) {
    return queuedResult(winner, false);
  }

  // Lost the race: re-read the winner's outcome. QUEUED → idempotent replay;
  // anything else (a concurrent cancel, say) → conflict.
  const current = await Job.findById(job._id).exec();
  if (current?.state === 'QUEUED') {
    return queuedResult(current, true);
  }
  return { outcome: 'JOB_NOT_FINALIZABLE', state: current?.state ?? job.state };
}

/**
 * The single funnel for every QUEUED outcome (fresh flip, early replay, and
 * lost-race replay), so the project's PROCESSING transition happens on all of
 * them and always AFTER the job's own QUEUED write. Replays re-assert the
 * status (refreshing statusUpdatedAt per the duplicate-finalize spec, and
 * self-healing a crash between the original flip and its status write). Same
 * error rule as create: a status-write failure propagates (→ 500) with the
 * job left QUEUED — known MVP consistency gap, no transactions here.
 */
async function queuedResult(job: IJob, alreadyQueued: boolean): Promise<FinalizeJobResult> {
  const projectId = job.projectId?.toHexString();
  if (!projectId) {
    // Defensive only (the schema requires projectId today): a job without a
    // project would be standalone and doesn't drive any project status.
    console.warn(
      `[ProjectStatus] job ${job.id} has no projectId — skipping PROCESSING transition`
    );
  } else {
    await updateProjectStatus(projectId, 'PROCESSING');
  }
  return {
    outcome: 'QUEUED',
    jobId: job.id as string,
    filesVerified: job.upload?.uploadedFilesCount ?? 0,
    queuedAt: (job.queuedAt ?? job.updatedAt).toISOString(),
    captureVariant: variantOf(job),
    alreadyQueued,
  };
}

/**
 * Shared guards for the per-file upload endpoints. Returns the job on success,
 * or the guard failure to map at the route.
 */
async function loadUploadableJob(
  userId: string,
  jobId: string,
  key: string
): Promise<{ job: IJob } | UploadGuardFailure> {
  const job = await Job.findOne({
    _id: new Types.ObjectId(jobId),
    userId: new Types.ObjectId(userId),
  }).exec();
  if (!job || !job.upload) {
    return { outcome: 'JOB_NOT_FOUND' };
  }

  if (job.state !== 'CREATED' && job.state !== 'UPLOADING') {
    return { outcome: 'JOB_NOT_UPLOADABLE', state: job.state };
  }

  const expiresAt = planExpiresAt(job);
  if (expiresAt.getTime() <= Date.now()) {
    return { outcome: 'PLAN_EXPIRED', expiresAt: expiresAt.toISOString() };
  }

  // Containment: every object of this job lives under its keyPrefix; the
  // remainder must be non-empty, within S3's key length, in the conservative
  // charset, and free of `..` segments (S3 would store them literally, but a
  // key that disagrees with the client bundle's layout is a bug either way).
  const prefix = job.upload.rawPrefix;
  const remainder = key.startsWith(prefix) ? key.slice(prefix.length) : null;
  if (
    remainder === null ||
    remainder.length === 0 ||
    key.length > KEY_MAX_LENGTH ||
    !KEY_REMAINDER_RE.test(remainder) ||
    remainder.split('/').some((seg) => seg === '..' || seg === '')
  ) {
    return { outcome: 'INVALID_KEY' };
  }

  // Variant containment: an image key's LEVEL segment must be one of the rings
  // the job's capture variant plans (e.g. images/LOW/… is rejected on a
  // without_bottom job — the plan never covered it). Same failure family as
  // the prefix check: a key outside the advertised plan.
  const segments = remainder.split('/');
  if (segments[0] === 'images') {
    const level = segments[1];
    const allowed = ringsForVariant(variantOf(job)) as readonly string[];
    if (level === undefined || !allowed.includes(level)) {
      return { outcome: 'INVALID_KEY' };
    }
  }

  return { job };
}
