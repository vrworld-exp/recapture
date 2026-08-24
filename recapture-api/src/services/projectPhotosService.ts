// src/services/projectPhotosService.ts
//
// The artist photo-upload surface: an artist opens a session, the EXISTING
// per-file presigned-multipart transport moves the bytes, and a commit verifies
// what actually landed.
//
// ── WHAT THIS DOES NOT DO ───────────────────────────────────────────────────
// It does not move bytes. `POST /jobs/:jobId/uploads/{initiate,part-url,
// complete}` is unchanged and untouched: its shared guard (`loadUploadableJob`)
// applies no jobType filter, and its ring-containment check fires only when a
// job-relative key starts with `images/` — so `uploads/photo_0001.jpg` passes
// it as written, with identical resume, retry and progress behaviour. That is
// the whole reason this feature is small. `tests/photo-upload-transfer.test.ts`
// is the regression that keeps it true.
//
// ── THE MONEY LINE ──────────────────────────────────────────────────────────
// Uploading costs nothing. GENERATING spends Meshy credits, and it is a
// separate, explicit step (`POST /projects/:id/photos/generate`) that keeps
// every guard the staff surface has: the `meshy-create:{userId}` rate window,
// the `Idempotency-Key` replay guard, and the unique-index race authority
// inside `createMeshyModelRequest`.
//
// ── LAYERING ────────────────────────────────────────────────────────────────
// No Express types here. Every business case is a discriminated result the
// route maps to a status code; missing / not-owned / soft-deleted collapse into
// ONE identical `PROJECT_NOT_FOUND` so the boundary leaks no existence.
import { Types } from 'mongoose';

import { BUCKET_RAW } from '@/config/s3';
import { env } from '@/config/env';
import { Job, PHOTO_UPLOAD_JOB_TYPE, type IJob } from '@/models/Job';
import {
  getProject,
  setProjectCaptureStats,
  updateProjectStatus,
  type ProjectListItem,
} from '@/services/projectsService';
import { DELETED_KEY_PREFIX, isContainedRelativeKey } from '@/services/adminProjectsService';
import {
  deleteObject,
  listObjectsUnderPrefix,
  moveObject,
  presignObjectGetUrl,
  type ListedObject,
} from '@/services/s3ObjectStore';
import { MAX_PARTS, PART_SIZE_MIN, planExpiresAt } from '@/services/jobsService';
import {
  UPLOADED_PHOTOS_KEY_PREFIX,
  buildJobKeyPrefix,
  buildUploadedPhotoKey,
  isUploadedPhotoRelativeKey,
  type JobKeyScope,
} from '@/utils/s3Keys';

// ── Session ──────────────────────────────────────────────────────────────────

/** One file the client intends to upload, as validated by photoSessionSchema. */
export interface PhotoSessionFileInput {
  contentType: string;
  size: number;
}

/**
 * The upload plan for one photo set. Field-for-field the capture plan
 * (`jobsService.UploadPlan`) MINUS the two capture-only members —
 * `manifestKey` (an uploaded set has no manifest) and `levels` (it has no
 * rings) — PLUS the server-assigned keys.
 *
 * A separate type rather than a widened `UploadPlan`: making those two optional
 * on the capture plan would let a capture job ship without a manifest key,
 * which is exactly the bug the conditional field is meant to prevent.
 */
export interface PhotoUploadPlan {
  uploadMethod: 'S3_PRESIGNED_MULTIPART';
  bucket: string;
  /** All of this job's objects live under this prefix (containment-enforced). */
  keyPrefix: string;
  /** Key rule for every file: keyPrefix + the job-relative path. */
  keyTemplate: string;
  /** ISO timestamp; per-file initiate calls are accepted until this instant. */
  expiresAt: string;
  partSizeMin: number;
  maxParts: number;
  expectedFilesCount: number;
}

/** One server-assigned slot, in REQUEST ORDER. */
export interface PhotoSessionFile {
  /** Full S3 object key — what the client echoes to initiate/part-url/complete. */
  key: string;
}

export type CreatePhotoSessionResult =
  | { outcome: 'PROJECT_NOT_FOUND' }
  /** The project's photos come from a capture — it must not grow an uploads
   * namespace, and the UI never offers this on one. */
  | { outcome: 'NOT_AN_UPLOAD_PROJECT' }
  | { outcome: 'RATE_LIMITED'; retryAfter: number }
  | {
      outcome: 'CREATED' | 'REPLAYED';
      jobId: string;
      projectId: string;
      uploadPlan: PhotoUploadPlan;
      files: PhotoSessionFile[];
    };

/**
 * Opens one upload session: mints a PHOTO_UPLOAD job, assigns every key from
 * the canonical builder, and returns the plan the existing engine binds to.
 *
 * Keys are built ONCE here and the prefix is persisted on the job — never
 * rebuilt later (AGENTS.md). `expectedFilesCount` is the file count with NO
 * manifest to add, because there is no manifest.
 *
 * `Idempotency-Key` replays through the SAME unique partial index on
 * `(userId, idempotencyKey)` that `POST /jobs` uses; a repeat with the same key
 * returns the original job and its original keys rather than a second one.
 */
export async function createPhotoUploadSession(input: {
  userId: string;
  projectId: string;
  files: PhotoSessionFileInput[];
  idempotencyKey?: string;
  /** Injected so the route owns the rate policy and this stays testable. */
  consumeRate: () => Promise<{ limited: true; retryAfter: number } | { limited: false }>;
}): Promise<CreatePhotoSessionResult> {
  const project = await getProject(input.userId, input.projectId);
  if (!project) return { outcome: 'PROJECT_NOT_FOUND' };
  if (project.source !== 'upload') return { outcome: 'NOT_AN_UPLOAD_PROJECT' };

  // Fast-path replay BEFORE the rate window: a client retrying the same keyed
  // request must not burn a slot for a session it already has.
  if (input.idempotencyKey) {
    const existing = await findKeyedJob(input.userId, input.idempotencyKey);
    if (existing) return replayed(project, existing);
  }

  const rate = await input.consumeRate();
  if (rate.limited) return { outcome: 'RATE_LIMITED', retryAfter: rate.retryAfter };

  // The jobId is minted first so the key prefix can embed it; the insert is one
  // document write, so a failure persists nothing.
  const jobId = new Types.ObjectId();
  const scope: JobKeyScope = {
    // RAW name — buildJobKeyPrefix slugifies it, so no caller can forget to.
    projectName: project.name,
    projectId: input.projectId,
    jobId: jobId.toHexString(),
  };
  const rawPrefix = buildJobKeyPrefix(scope);
  // 1-based, in REQUEST ORDER — the order is the set's stable gallery order.
  const keys = input.files.map((file, i) => buildUploadedPhotoKey(scope, i + 1, file.contentType));
  const relativeKeys = keys.map((key) => key.slice(rawPrefix.length));

  try {
    const job = await Job.create({
      _id: jobId,
      projectId: new Types.ObjectId(input.projectId),
      userId: new Types.ObjectId(input.userId),
      jobType: PHOTO_UPLOAD_JOB_TYPE,
      state: 'CREATED',
      ...(input.idempotencyKey ? { idempotencyKey: input.idempotencyKey } : {}),
      // Persisted so an Idempotency-Key REPLAY returns the identical key set.
      // A replay cannot re-derive it: the extensions come from the original
      // request's content types, which the replay does not carry.
      payload: { photoKeys: relativeKeys },
      upload: {
        uploadMethod: 'S3_PRESIGNED_MULTIPART',
        // No manifest to add — an uploaded set has none, which is also why
        // `manifestKey` is left unset (it is optional on UploadInfo for
        // exactly this job type).
        expectedFilesCount: input.files.length,
        uploadedFilesCount: 0,
        checksumAlgo: 'md5',
        rawBucket: BUCKET_RAW,
        rawPrefix,
      },
    });
    return {
      outcome: 'CREATED',
      jobId: job.id as string,
      projectId: project.id,
      uploadPlan: planFor(job, input.files.length),
      files: keys.map((key) => ({ key })),
    };
  } catch (err: unknown) {
    // Concurrent duplicate with the same key: the unique index rejected this
    // insert — resolve against the job that won the race.
    if (input.idempotencyKey && isDuplicateKeyError(err)) {
      const winner = await findKeyedJob(input.userId, input.idempotencyKey);
      if (winner) return replayed(project, winner);
    }
    throw err;
  }
}

/** Re-derives a keyed session's response from the persisted job, so a replay is
 * byte-identical to the original (same keys, same plan, same window). */
function replayed(project: ProjectListItem, job: IJob): CreatePhotoSessionResult {
  const count = job.upload?.expectedFilesCount ?? 0;
  return {
    outcome: 'REPLAYED',
    jobId: job.id as string,
    projectId: project.id,
    uploadPlan: planFor(job, count),
    // Rebuilt from the persisted prefix, never from the key builder: the
    // prefix is the stored truth, and the file names are deterministic.
    files: relativeKeysFor(job).map((relative) => ({
      key: `${job.upload?.rawPrefix ?? ''}${relative}`,
    })),
  };
}

/**
 * The job-relative keys assigned when the session was created, read back off
 * the job.
 *
 * They are PERSISTED (`payload.photoKeys`) rather than re-derived, for the same
 * reason `upload.rawPrefix` is: the key set depends on the original request's
 * content types, which a replay does not have. Re-deriving would hand a replay
 * a different `photo_0003.png` than the original `photo_0003.jpg` and the two
 * halves of one upload would disagree.
 */
function relativeKeysFor(job: IJob): string[] {
  const raw = job.payload?.photoKeys;
  return Array.isArray(raw) ? raw.filter((k): k is string => typeof k === 'string') : [];
}

function planFor(job: IJob, expectedFilesCount: number): PhotoUploadPlan {
  const upload = job.upload!;
  return {
    uploadMethod: 'S3_PRESIGNED_MULTIPART',
    bucket: upload.rawBucket,
    keyPrefix: upload.rawPrefix,
    keyTemplate: `${upload.rawPrefix}{relativePath}`,
    // The SAME window loadUploadableJob enforces — imported, not recomputed.
    expiresAt: planExpiresAt(job).toISOString(),
    partSizeMin: PART_SIZE_MIN,
    maxParts: MAX_PARTS,
    expectedFilesCount,
  };
}

function findKeyedJob(userId: string, idempotencyKey: string): Promise<IJob | null> {
  return Job.findOne({
    userId: new Types.ObjectId(userId),
    idempotencyKey,
    jobType: PHOTO_UPLOAD_JOB_TYPE,
  }).exec();
}

/** Mongo duplicate-key (E11000) — the unique index rejecting a concurrent insert. */
function isDuplicateKeyError(err: unknown): boolean {
  return typeof err === 'object' && err !== null && (err as { code?: number }).code === 11000;
}

// ── Commit ───────────────────────────────────────────────────────────────────

export type CommitPhotoUploadResult =
  | { outcome: 'PROJECT_NOT_FOUND' }
  | { outcome: 'JOB_NOT_FOUND' }
  /** At least one object exceeded PROJECT_PHOTO_MAX_BYTES. The offenders were
   * DELETED before this was returned — presigning cannot cap a body, so the
   * only place the cap is real is here. */
  | { outcome: 'PHOTO_TOO_LARGE'; deleted: number }
  | { outcome: 'TOO_FEW_PHOTOS'; found: number; minimum: number }
  | {
      outcome: 'COMMITTED';
      projectId: string;
      jobId: string;
      photoCount: number;
      totalBytes: number;
      /** True when the job was already UPLOADED (idempotent replay). */
      alreadyCommitted: boolean;
    };

/**
 * Verifies what actually landed in S3 and flips the job to UPLOADED.
 *
 * IDEMPOTENT: an already-UPLOADED job replays its stored counts WITHOUT
 * re-listing S3 — a double-tap costs one indexed read.
 *
 * The flip is a CONDITIONAL findOneAndUpdate guarded on the current state, so
 * two concurrent commits cannot both win (AGENTS.md: atomicity without
 * transactions).
 *
 * It deliberately does NOT set `Job.state = 'QUEUED'`: a PHOTO_UPLOAD job is
 * never processed, and QUEUED is the claimable state.
 *
 * It DOES promote the project to PROCESSING — see {@link finalizeUploadProject}.
 * That is what makes a finished upload a first-class project: it enters the
 * staff Live list (LIVE_PROJECT_STATUSES) and every exportable surface, exactly
 * like a finalized capture.
 */
export async function commitPhotoUpload(input: {
  userId: string;
  projectId: string;
  jobId: string;
}): Promise<CommitPhotoUploadResult> {
  const project = await getProject(input.userId, input.projectId);
  if (!project) return { outcome: 'PROJECT_NOT_FOUND' };

  const job = await Job.findOne({
    _id: new Types.ObjectId(input.jobId),
    projectId: new Types.ObjectId(input.projectId),
    userId: new Types.ObjectId(input.userId),
    jobType: PHOTO_UPLOAD_JOB_TYPE,
  }).exec();
  if (!job || !job.upload) return { outcome: 'JOB_NOT_FOUND' };

  if (job.state === 'UPLOADED') {
    // Self-heal: a crash between the original flip and the status write would
    // otherwise leave a committed upload stranded in DRAFT, invisible to Live.
    await finalizeUploadProject(project, job.upload.uploadedFilesCount, job.updatedAt);
    return {
      outcome: 'COMMITTED',
      projectId: project.id,
      jobId: job.id as string,
      photoCount: job.upload.uploadedFilesCount,
      totalBytes: 0, // not persisted; a replay reports the count, not the bytes
      alreadyCommitted: true,
    };
  }
  if (job.state !== 'CREATED' && job.state !== 'UPLOADING') {
    // Terminal / never-valid states behave like a job that isn't there, which
    // is also what keeps this route from becoming a second state machine.
    return { outcome: 'JOB_NOT_FOUND' };
  }

  const { rawBucket, rawPrefix } = job.upload;
  const objects = await listObjectsUnderPrefix(rawBucket, `${rawPrefix}${UPLOADED_PHOTOS_KEY_PREFIX}`);

  // Size is enforced from what S3 actually stored. An over-cap object is
  // DELETED, not merely rejected — the same stance the avatar commit takes, so
  // a refused upload cannot leave a paid-for object behind.
  const oversized = objects.filter((o) => o.size > env.PROJECT_PHOTO_MAX_BYTES);
  if (oversized.length > 0) {
    for (const object of oversized) {
      await deleteObject(rawBucket, object.key);
    }
    return { outcome: 'PHOTO_TOO_LARGE', deleted: oversized.length };
  }

  if (objects.length < env.PROJECT_PHOTO_MIN_COUNT) {
    return {
      outcome: 'TOO_FEW_PHOTOS',
      found: objects.length,
      minimum: env.PROJECT_PHOTO_MIN_COUNT,
    };
  }

  const totalBytes = objects.reduce((sum, o) => sum + o.size, 0);

  // Conditional flip: only a job still in CREATED/UPLOADING matches, so under a
  // concurrent double commit exactly one request performs the transition.
  const updated = await Job.findOneAndUpdate(
    { _id: job._id, state: { $in: ['CREATED', 'UPLOADING'] } },
    { $set: { state: 'UPLOADED', 'upload.uploadedFilesCount': objects.length } },
    { new: true }
  ).exec();

  // Hub-card stats + the PROCESSING promotion, through the one funnel both
  // the fresh commit and the idempotent replay call.
  await finalizeUploadProject(project, objects.length, (updated ?? job).updatedAt);

  return {
    outcome: 'COMMITTED',
    projectId: project.id,
    jobId: job.id as string,
    photoCount: objects.length,
    totalBytes,
    // Losing the conditional update means another commit won the race and the
    // job is already UPLOADED — the same end state, reported honestly.
    alreadyCommitted: updated === null,
  };
}

/**
 * The single funnel every COMMITTED outcome runs through — fresh flip and
 * idempotent replay alike — so a committed upload always ends in the same
 * project state. Modelled on finalize's `queuedResult` (jobsService), for the
 * same two reasons: a replay must re-assert rather than skip (self-healing a
 * crash between the job flip and these writes), and the status write must
 * happen AFTER the job's own state write.
 *
 * Two writes, in this order:
 *
 * 1. `stats.totalPhotos` — `setProjectCaptureStats` is named for the capture
 *    funnel but its semantics are exactly what is needed ("this many photos
 *    landed, at this instant"), so it is reused rather than duplicated. Without
 *    it the Hub card reads "0 photos" on a project holding 48. [landedAt] is
 *    the job's own UPLOADED-flip instant, not `new Date()`, for the reason
 *    finalize passes `queuedAt`: a replay must rewrite IDENTICAL values, or
 *    every retried commit nudges the project's "last capture" forward and
 *    reorders the Hub list for no real event.
 * 2. `status` → PROCESSING. THIS is what makes a finished upload a first-class
 *    project rather than a private draft: PROCESSING is in
 *    `LIVE_PROJECT_STATUSES`, so the set becomes visible to every artist and
 *    admin on the staff Live list, and it is the status the exportable
 *    surfaces (export, preview gallery, Generate) gate on — the same
 *    PROCESSING a finalized capture lands in, deliberately, so neither list
 *    has to learn what an upload project is.
 *
 * A project already past DRAFT is left alone: PROCESSING → PROCESSING is a
 * self-transition (which `updateProjectStatus` warns about), and COMPLETED →
 * PROCESSING would drag a project with a finished model backwards.
 */
async function finalizeUploadProject(
  project: ProjectListItem,
  photoCount: number,
  landedAt: Date
): Promise<void> {
  await setProjectCaptureStats(project.id, photoCount, landedAt);
  if (project.status === 'PROCESSING' || project.status === 'COMPLETED') return;
  await updateProjectStatus(project.id, 'PROCESSING');
}

// ── List ─────────────────────────────────────────────────────────────────────

export interface ProjectPhotoItem {
  /** Job-RELATIVE key (`uploads/photo_0001.jpg`) — what delete/generate echo. */
  key: string;
  /** Presigned GET. A BEARER CREDENTIAL: it may appear in this response body
   * and NOWHERE else — never in a log, never in analytics. */
  url: string;
  size: number;
}

export type ListProjectPhotosResult =
  | { outcome: 'PROJECT_NOT_FOUND' }
  | { outcome: 'NO_PHOTO_SET' }
  | {
      outcome: 'OK';
      projectId: string;
      jobId: string;
      items: ProjectPhotoItem[];
      urlsExpireAt: string;
    };

/**
 * The newest PHOTO_UPLOAD job's objects, presigned for the grid, in KEY ORDER
 * (which is upload order, because the index is zero-padded).
 *
 * Lists ANY state, not just UPLOADED: the artist must be able to see what
 * landed even if the commit has not run yet.
 */
export async function listProjectPhotos(input: {
  userId: string;
  projectId: string;
}): Promise<ListProjectPhotosResult> {
  const project = await getProject(input.userId, input.projectId);
  if (!project) return { outcome: 'PROJECT_NOT_FOUND' };

  const job = await newestPhotoUploadJob(input.projectId);
  if (!job || !job.upload) return { outcome: 'NO_PHOTO_SET' };

  const { rawBucket, rawPrefix } = job.upload;
  const objects = await listObjectsUnderPrefix(rawBucket, `${rawPrefix}${UPLOADED_PHOTOS_KEY_PREFIX}`);
  const ttl = env.PROJECT_PHOTO_URL_TTL_SECONDS;

  const items = await Promise.all(
    sortedByKey(objects).map(async (object) => ({
      key: object.key.slice(rawPrefix.length),
      url: await presignObjectGetUrl(rawBucket, object.key, ttl),
      size: object.size,
    }))
  );

  return {
    outcome: 'OK',
    projectId: project.id,
    jobId: job.id as string,
    items,
    urlsExpireAt: new Date(Date.now() + ttl * 1000).toISOString(),
  };
}

function sortedByKey(objects: ListedObject[]): ListedObject[] {
  return [...objects].sort((a, b) => (a.key < b.key ? -1 : a.key > b.key ? 1 : 0));
}

// ── Soft delete ──────────────────────────────────────────────────────────────

export type DeleteProjectPhotosResult =
  | { outcome: 'PROJECT_NOT_FOUND' }
  | { outcome: 'NO_PHOTO_SET' }
  /** One key escaped the photo namespace — NOTHING was moved. */
  | { outcome: 'INVALID_KEY' }
  | {
      outcome: 'DELETED';
      projectId: string;
      jobId: string;
      deleted: string[];
      missing: string[];
    };

/**
 * Moves each job-relative key into the job's `deleted/` park — the same
 * soft-delete namespace the admin photo delete uses. NEVER a hard delete.
 *
 * FAIL-CLOSED: the WHOLE list is validated before the first object moves, so
 * one escaping key refuses the entire request and touches nothing. Both guards
 * apply — `isContainedRelativeKey` (no traversal, not already parked) AND
 * `isUploadedPhotoRelativeKey` (the exact `uploads/photo_{nnnn}.{ext}` shape),
 * so a caller can only ever name an object of the photo set itself.
 */
export async function softDeleteProjectPhotos(input: {
  userId: string;
  projectId: string;
  keys: string[];
}): Promise<DeleteProjectPhotosResult> {
  const project = await getProject(input.userId, input.projectId);
  if (!project) return { outcome: 'PROJECT_NOT_FOUND' };

  const job = await newestPhotoUploadJob(input.projectId);
  if (!job || !job.upload) return { outcome: 'NO_PHOTO_SET' };

  // Dedupe while preserving order; validate EVERY key before moving anything.
  const keys = [...new Set(input.keys)];
  for (const key of keys) {
    if (!isContainedRelativeKey(key) || !isUploadedPhotoRelativeKey(key)) {
      return { outcome: 'INVALID_KEY' };
    }
  }

  const { rawBucket, rawPrefix } = job.upload;
  const deleted: string[] = [];
  const missing: string[] = [];
  for (const key of keys) {
    const result = await moveObject(
      rawBucket,
      `${rawPrefix}${key}`,
      `${rawPrefix}${DELETED_KEY_PREFIX}${key}`
    );
    (result === 'moved' ? deleted : missing).push(key);
  }

  return {
    outcome: 'DELETED',
    projectId: project.id,
    jobId: job.id as string,
    deleted,
    missing,
  };
}

// ── Generation source ────────────────────────────────────────────────────────

/**
 * The job a generation request for this project must be pinned to: its newest
 * UPLOADED photo-upload job.
 *
 * Resolved SERVER-SIDE and never taken from the request body — a caller that
 * could name the job could point a generation at another project's photo set.
 * `createMeshyModelRequest` re-checks the pairing anyway (its
 * `findModelSourceJobById` has projectId in the query), so this is the first of
 * two independent gates, not the only one.
 */
export async function findGenerationSourceJob(projectId: string): Promise<IJob | null> {
  return Job.findOne({
    projectId: new Types.ObjectId(projectId),
    jobType: PHOTO_UPLOAD_JOB_TYPE,
    state: 'UPLOADED',
  })
    .sort({ createdAt: -1 })
    .exec();
}

/** The project's newest photo-upload job in ANY state — the set the artist is
 * looking at. */
function newestPhotoUploadJob(projectId: string): Promise<IJob | null> {
  return Job.findOne({
    projectId: new Types.ObjectId(projectId),
    jobType: PHOTO_UPLOAD_JOB_TYPE,
  })
    .sort({ createdAt: -1 })
    .exec();
}
