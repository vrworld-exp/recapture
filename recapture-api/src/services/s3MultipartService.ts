// src/services/s3MultipartService.ts
//
// Thin S3 multipart helpers over the SHARED configured client (config/s3.ts —
// never a second client): initiate a multipart upload and presign part-PUT
// URLs. Pure S3 concerns only; job semantics (ownership, key containment, the
// plan window) live in jobsService.
//
// Presigning is LOCAL SigV4 signing — no network call — so generating a
// hundred part URLs in parallel is cheap. Only `initiateMultipartUpload`
// actually talks to S3.
import {
  CompleteMultipartUploadCommand,
  CreateMultipartUploadCommand,
  UploadPartCommand,
} from '@aws-sdk/client-s3';
import { getSignedUrl } from '@aws-sdk/s3-request-presigner';
import { s3Client } from '@/config/s3';

/**
 * S3 multipart hard minimum part size (bytes) for every non-final part. Fixed
 * by S3, not configuration — echoed to the client so both sides plan identical
 * chunking. (The mobile engine's planFileParts uses the same floor.)
 */
export const PART_SIZE_MIN = 5_242_880; // 5 MiB

/** S3 multipart hard maximum part count. Fixed by S3, not configuration. */
export const MAX_PARTS = 10_000;

/** S3 hard maximum size of a single part (bytes). */
export const MAX_PART_SIZE = 5 * 1024 * 1024 * 1024; // 5 GiB

/**
 * Presigned part-URL validity (seconds). Fixed at 1 hour: long enough to
 * upload one 5 MiB–5 GiB part on mobile, short enough that a leaked URL goes
 * stale quickly. The client re-fetches an expired URL per part (the engine's
 * refreshPartUrl path), so this does NOT bound the whole session.
 */
export const PRESIGN_EXPIRES_SECONDS = 3600;

/**
 * Starts a multipart upload for [key] and returns the S3 uploadId. Throws when
 * S3 refuses or returns no id — the caller fails the whole request (nothing is
 * persisted for a failed initiate).
 */
export async function initiateMultipartUpload(bucket: string, key: string): Promise<string> {
  const result = await s3Client.send(
    new CreateMultipartUploadCommand({ Bucket: bucket, Key: key })
  );
  if (!result.UploadId) {
    throw new Error(`S3 returned no UploadId for key: ${key}`);
  }
  return result.UploadId;
}

/**
 * Completes a multipart upload for [key] from the client-collected part ETags
 * and returns the composite object ETag. A stale/foreign uploadId or a wrong
 * ETag surfaces as S3's own error (the caller lets it propagate — same policy
 * as part-url: S3, not this service, is the uploadId authority).
 */
export async function completeMultipartUpload(
  bucket: string,
  key: string,
  uploadId: string,
  parts: Array<{ partNumber: number; etag: string }>
): Promise<string> {
  const result = await s3Client.send(
    new CompleteMultipartUploadCommand({
      Bucket: bucket,
      Key: key,
      UploadId: uploadId,
      MultipartUpload: {
        Parts: parts.map((p) => ({ PartNumber: p.partNumber, ETag: p.etag })),
      },
    })
  );
  if (!result.ETag) {
    throw new Error(`S3 returned no ETag completing key: ${key}`);
  }
  return result.ETag;
}

/**
 * Presigns the part-PUT URL for one (uploadId, partNumber).
 */
export async function presignPartUrl(
  bucket: string,
  key: string,
  uploadId: string,
  partNumber: number
): Promise<string> {
  return getSignedUrl(
    s3Client,
    new UploadPartCommand({
      Bucket: bucket,
      Key: key,
      UploadId: uploadId,
      PartNumber: partNumber,
    }),
    { expiresIn: PRESIGN_EXPIRES_SECONDS }
  );
}

/**
 * Presigns URLs for parts 1..[partCount] IN PARALLEL (signing is local; a
 * sequential loop would still be needlessly slow at 100+ parts).
 */
export async function presignPartUrls(
  bucket: string,
  key: string,
  uploadId: string,
  partCount: number
): Promise<Array<{ partNumber: number; url: string }>> {
  return Promise.all(
    Array.from({ length: partCount }, (_, i) => i + 1).map(async (partNumber) => ({
      partNumber,
      url: await presignPartUrl(bucket, key, uploadId, partNumber),
    }))
  );
}
