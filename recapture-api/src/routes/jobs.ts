// src/routes/jobs.ts
import { Router, type Response } from 'express';
import { asyncHandler } from '@/utils/asyncHandler';
import { requireAuth } from '@/middleware/auth';
import {
  createJobSchema,
  idempotencyKeySchema,
  jobIdParamsSchema,
  initiateUploadSchema,
  partUrlSchema,
  completeUploadSchema,
  finalizeJobSchema,
} from '@/validation/jobSchemas';
import {
  createJob,
  initiateFileUpload,
  refreshUploadPartUrl,
  completeFileUpload,
  finalizeJob,
  type UploadGuardFailure,
} from '@/services/jobsService';
import { hashIdentifier } from '@/utils/otp';
import { track, AnalyticsEvent } from '@/utils/analytics';

const router = Router();

// Every route in this router requires a valid access token (401 before any
// handler runs; `req.user = { userId, authUid }` attached).
router.use(requireAuth);

/**
 * POST /jobs — create an upload job for a completed capture session and return
 * the job-scoped upload plan (bucket + key space + multipart limits + bounded
 * validity). The "initiate the session upload" step: the mobile engine then
 * initiates each file's presigned multipart upload against the per-file
 * endpoints (separate task) within the plan's window.
 *
 * Ownership comes ONLY from the token; missing, not-owned, and soft-deleted
 * projects all return an identical 404 (no existence leak) with nothing
 * created. `objectSize` must match the project's stored size (400 on mismatch)
 * and `expectedFilesCount` must land in the captureVariant's valid range —
 * coverage minimum … full total, manifest-inclusive (400 outside it).
 *
 * IDEMPOTENCY (this endpoint introduces the minimal per-endpoint mechanism —
 * none existed): send an `Idempotency-Key` header; a retry with the same key +
 * same payload returns the ORIGINAL job and plan (200, `idempotentReplay:
 * true`); the same key with a different payload is a 409.
 */
router.post(
  '/',
  asyncHandler(async (req, res) => {
    const parsed = createJobSchema.safeParse(req.body);
    if (!parsed.success) {
      const issue = parsed.error.issues[0];
      const field = issue?.path.join('.') || 'body';
      res.status(400).json({
        status: 'error',
        code: 'INVALID_REQUEST',
        message: issue?.message ?? 'Invalid request',
        fields: { [field]: issue?.message ?? 'invalid value' },
      });
      return;
    }

    // Optional Idempotency-Key header — when present it must be well-formed
    // (bounded); a malformed key is a 400, not a silently ignored retry guard.
    let idempotencyKey: string | undefined;
    const rawKey = req.headers['idempotency-key'];
    if (rawKey !== undefined) {
      const key = idempotencyKeySchema.safeParse(
        Array.isArray(rawKey) ? rawKey[0] : rawKey
      );
      if (!key.success) {
        res.status(400).json({
          status: 'error',
          code: 'INVALID_REQUEST',
          message: 'Idempotency-Key must be 1-128 characters.',
        });
        return;
      }
      idempotencyKey = key.data;
    }

    const userId = req.user!.userId;
    const result = await createJob(userId, parsed.data, idempotencyKey);

    switch (result.outcome) {
      case 'PROJECT_NOT_FOUND':
        res.status(404).json({
          status: 'error',
          code: 'NOT_FOUND',
          message: 'Project not found.',
        });
        return;

      case 'SIZE_MISMATCH':
        res.status(400).json({
          status: 'error',
          code: 'INVALID_REQUEST',
          message: `objectSize does not match the project (expected '${result.projectSize}').`,
          fields: { objectSize: `expected '${result.projectSize}'` },
        });
        return;

      case 'COUNT_INCONSISTENT':
        res.status(400).json({
          status: 'error',
          code: 'INVALID_REQUEST',
          // Names the MODE as well as the variant: the two together pick the
          // valid range, so a message citing only the variant would look wrong
          // to anyone reading it against a Meshy capture's numbers.
          message:
            `expectedFilesCount is inconsistent with captureMode/captureVariant — a ` +
            `'${result.captureMode}' '${result.captureVariant}' capture has between ` +
            `${result.minimum} and ${result.maximum} files (images + manifest).`,
          fields: { expectedFilesCount: `must be ${result.minimum}-${result.maximum}` },
        });
        return;

      case 'IDEMPOTENCY_CONFLICT':
        res.status(409).json({
          status: 'error',
          code: 'IDEMPOTENCY_CONFLICT',
          message: 'Idempotency-Key was already used with a different request.',
        });
        return;

      case 'REPLAYED':
        // Same key + same payload → the original job; nothing new was created.
        res.status(200).json({
          status: 'success',
          idempotentReplay: true,
          job: result.job,
          uploadPlan: result.uploadPlan,
        });
        return;

      case 'CREATED':
        track(AnalyticsEvent.JOB_CREATED, {
          user_id_hash: hashIdentifier(userId),
          project_id: result.job.projectId,
          job_id: result.job.id,
          object_size: result.job.objectSize,
          flow_variant: result.job.captureVariant,
          expected_files_count: result.job.expectedFilesCount,
        });
        res.status(201).json({
          status: 'success',
          job: result.job,
          uploadPlan: result.uploadPlan,
        });
        return;
    }
  })
);

/** Maps the shared per-file upload guard failures to their status codes. */
function sendUploadGuardFailure(res: Response, failure: UploadGuardFailure): void {
  switch (failure.outcome) {
    case 'JOB_NOT_FOUND':
      res.status(404).json({
        status: 'error',
        code: 'NOT_FOUND',
        message: 'Job not found.',
      });
      return;
    case 'JOB_NOT_UPLOADABLE':
      res.status(409).json({
        status: 'error',
        code: 'JOB_NOT_UPLOADABLE',
        message: `Job is ${failure.state} — uploads are not accepted.`,
      });
      return;
    case 'PLAN_EXPIRED':
      res.status(410).json({
        status: 'error',
        code: 'PLAN_EXPIRED',
        message: `The upload plan expired at ${failure.expiresAt}. Create a new job.`,
      });
      return;
    case 'INVALID_KEY':
      res.status(400).json({
        status: 'error',
        code: 'INVALID_REQUEST',
        message: "key must live under the job's keyPrefix.",
        fields: { key: "must start with the job's keyPrefix" },
      });
      return;
  }
}

/**
 * POST /jobs/:jobId/uploads/initiate — begin ONE file's presigned multipart
 * upload: returns the S3 uploadId + presigned PUT URLs for every part. Called
 * by the mobile engine once per file (it alone knows sizes/part plans — which
 * is why this cannot be a single all-files GET). A repeat call for the same
 * key mints a FRESH uploadId (the engine's re-initiate recovery); the server
 * keeps no per-file state, so nothing is left half-initiated when S3 errors
 * (those surface as 500 via the error handler).
 *
 * Guards: owned job (404, no leak) → CREATED/UPLOADING only (409) → plan
 * window open (410) → key contained under the job's keyPrefix (400) → part
 * count achievable for fileSize (400). First successful initiate flips the
 * job CREATED → UPLOADING (exactly once) and emits job_upload_started.
 */
router.post(
  '/:jobId/uploads/initiate',
  asyncHandler(async (req, res) => {
    const params = jobIdParamsSchema.safeParse(req.params);
    if (!params.success) {
      res.status(400).json({
        status: 'error',
        code: 'INVALID_REQUEST',
        message: params.error.issues[0]?.message ?? 'Invalid job id',
      });
      return;
    }
    const body = initiateUploadSchema.safeParse(req.body);
    if (!body.success) {
      const issue = body.error.issues[0];
      const field = issue?.path.join('.') || 'body';
      res.status(400).json({
        status: 'error',
        code: 'INVALID_REQUEST',
        message: issue?.message ?? 'Invalid request',
        fields: { [field]: issue?.message ?? 'invalid value' },
      });
      return;
    }

    const userId = req.user!.userId;
    const result = await initiateFileUpload(userId, params.data.jobId, body.data);

    if (result.outcome === 'PART_COUNT_INCONSISTENT') {
      res.status(400).json({
        status: 'error',
        code: 'INVALID_REQUEST',
        message:
          `partCount is not achievable for fileSize — must be ` +
          `${result.minimum}-${result.maximum} for this file.`,
        fields: { partCount: `must be ${result.minimum}-${result.maximum}` },
      });
      return;
    }
    if (result.outcome !== 'INITIATED') {
      sendUploadGuardFailure(res, result);
      return;
    }

    if (result.uploadStarted) {
      track(AnalyticsEvent.JOB_UPLOAD_STARTED, {
        user_id_hash: hashIdentifier(userId),
        job_id: params.data.jobId,
      });
    }

    res.status(201).json({
      status: 'success',
      uploadId: result.uploadId,
      key: result.key,
      parts: result.parts,
      urlsExpireAt: result.urlsExpireAt,
    });
  })
);

/**
 * POST /jobs/:jobId/uploads/part-url — re-presign ONE part's URL after the
 * original expired mid-session (the engine retries the part with the fresh
 * URL). Same guards as initiate; touches no state. The uploadId itself is
 * validated by S3 at PUT time, not here.
 */
router.post(
  '/:jobId/uploads/part-url',
  asyncHandler(async (req, res) => {
    const params = jobIdParamsSchema.safeParse(req.params);
    if (!params.success) {
      res.status(400).json({
        status: 'error',
        code: 'INVALID_REQUEST',
        message: params.error.issues[0]?.message ?? 'Invalid job id',
      });
      return;
    }
    const body = partUrlSchema.safeParse(req.body);
    if (!body.success) {
      const issue = body.error.issues[0];
      const field = issue?.path.join('.') || 'body';
      res.status(400).json({
        status: 'error',
        code: 'INVALID_REQUEST',
        message: issue?.message ?? 'Invalid request',
        fields: { [field]: issue?.message ?? 'invalid value' },
      });
      return;
    }

    const userId = req.user!.userId;
    const result = await refreshUploadPartUrl(userId, params.data.jobId, body.data);

    if (result.outcome !== 'SIGNED') {
      sendUploadGuardFailure(res, result);
      return;
    }

    res.status(200).json({ status: 'success', url: result.url });
  })
);

/**
 * POST /jobs/:jobId/uploads/complete — commit ONE file's multipart upload
 * (S3 CompleteMultipartUpload) from the client-collected part ETags. The
 * client cannot do this itself: no presigned complete URL exists and the SDK
 * call needs credentials. Same guards as initiate; no per-file state is
 * persisted. An S3 failure (including a stale/foreign uploadId) surfaces as
 * 500 via the error handler — same policy as part-url, never pre-validated.
 */
router.post(
  '/:jobId/uploads/complete',
  asyncHandler(async (req, res) => {
    const params = jobIdParamsSchema.safeParse(req.params);
    if (!params.success) {
      res.status(400).json({
        status: 'error',
        code: 'INVALID_REQUEST',
        message: params.error.issues[0]?.message ?? 'Invalid job id',
      });
      return;
    }
    const body = completeUploadSchema.safeParse(req.body);
    if (!body.success) {
      const issue = body.error.issues[0];
      const field = issue?.path.join('.') || 'body';
      res.status(400).json({
        status: 'error',
        code: 'INVALID_REQUEST',
        message: issue?.message ?? 'Invalid request',
        fields: { [field]: issue?.message ?? 'invalid value' },
      });
      return;
    }

    const userId = req.user!.userId;
    const result = await completeFileUpload(userId, params.data.jobId, body.data);

    if (result.outcome !== 'COMPLETED') {
      sendUploadGuardFailure(res, result);
      return;
    }

    res.status(200).json({ status: 'success', key: result.key, etag: result.etag });
  })
);

/**
 * POST /jobs/:jobId/finalize — the commit gate after the client has uploaded
 * every file + the manifest: verifies against S3 (manifest present; listed
 * object count == expectedFilesCount — client-reported counts are cross-checks
 * only), then queues the job for processing. In this codebase the QUEUED state
 * flip IS the enqueue (the worker polls QUEUED jobs), so the transition and
 * the enqueue are one atomic conditional update — idempotent and exactly-once
 * under concurrent calls; a re-finalize of a QUEUED job replays the original
 * result. Verification failures are 422 (nothing changes); a job past
 * finalizing (processing/terminal) is a 409.
 */
router.post(
  '/:jobId/finalize',
  asyncHandler(async (req, res) => {
    const params = jobIdParamsSchema.safeParse(req.params);
    if (!params.success) {
      res.status(400).json({
        status: 'error',
        code: 'INVALID_REQUEST',
        message: params.error.issues[0]?.message ?? 'Invalid job id',
      });
      return;
    }
    // The body is usually absent — normalize to {} before the strict parse.
    const body = finalizeJobSchema.safeParse(req.body ?? {});
    if (!body.success) {
      const issue = body.error.issues[0];
      const field = issue?.path.join('.') || 'body';
      res.status(400).json({
        status: 'error',
        code: 'INVALID_REQUEST',
        message: issue?.message ?? 'Invalid request',
        fields: { [field]: issue?.message ?? 'invalid value' },
      });
      return;
    }

    const userId = req.user!.userId;
    const result = await finalizeJob(userId, params.data.jobId, body.data.reportedFilesCount);

    switch (result.outcome) {
      case 'JOB_NOT_FOUND':
        res.status(404).json({
          status: 'error',
          code: 'NOT_FOUND',
          message: 'Job not found.',
        });
        return;

      case 'JOB_NOT_FINALIZABLE':
        res.status(409).json({
          status: 'error',
          code: 'JOB_NOT_FINALIZABLE',
          message: `Job is ${result.state} — it cannot be finalized.`,
        });
        return;

      case 'VERIFICATION_FAILED':
        res.status(422).json({
          status: 'error',
          code: 'VERIFICATION_FAILED',
          reason: result.reason,
          message:
            result.reason === 'manifest_missing'
              ? 'The capture manifest has not been uploaded.'
              : result.reason === 'manifest_invalid'
                ? 'The capture manifest failed validation.'
                : `Uploaded file count does not match — expected ${result.expected}, ` +
                  `found ${result.actual}.`,
          expectedFilesCount: result.expected,
          ...(result.actual !== null ? { actualFilesCount: result.actual } : {}),
          // Per-rule findings (stable rule ids + plain-JSON detail) so the
          // client can show exactly what is wrong with the capture.
          ...(result.validationErrors ? { validationErrors: result.validationErrors } : {}),
        });
        return;

      case 'QUEUED':
        if (!result.alreadyQueued) {
          track(AnalyticsEvent.JOB_QUEUED, {
            user_id_hash: hashIdentifier(userId),
            job_id: result.jobId,
            flow_variant: result.captureVariant,
            files_verified: result.filesVerified,
          });
        }
        res.status(200).json({
          status: 'success',
          jobId: result.jobId,
          state: 'QUEUED',
          filesVerified: result.filesVerified,
          queuedAt: result.queuedAt,
          ...(result.alreadyQueued ? { idempotentReplay: true } : {}),
        });
        return;
    }
  })
);

export default router;
