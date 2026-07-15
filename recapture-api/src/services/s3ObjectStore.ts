// src/services/s3ObjectStore.ts
//
// Small S3 object-inspection helpers over the SHARED configured client
// (config/s3.ts — never a second client): existence check (HEAD) and a
// FULLY-PAGINATED object count under a prefix. Pure S3 concerns; the finalize
// verification rules live in jobsService.
import {
  CopyObjectCommand,
  DeleteObjectCommand,
  GetObjectCommand,
  HeadObjectCommand,
  ListObjectsV2Command,
} from '@aws-sdk/client-s3';
import { getSignedUrl } from '@aws-sdk/s3-request-presigner';
import { s3Client } from '@/config/s3';

/**
 * Whether an object exists at (bucket, key). A 404/NotFound is the `false`
 * answer, never an error; anything else (auth, network, throttle) rethrows so
 * the caller fails loudly instead of mis-reporting "missing".
 */
export async function objectExists(bucket: string, key: string): Promise<boolean> {
  try {
    await s3Client.send(new HeadObjectCommand({ Bucket: bucket, Key: key }));
    return true;
  } catch (err) {
    if (isNotFound(err)) return false;
    throw err;
  }
}

/**
 * Counts the objects under [prefix], following continuation tokens to the end —
 * a truncated first page must never undercount a large upload. "Folder marker"
 * zero-byte keys ending in '/' are excluded (nothing in this pipeline creates
 * them, but a console-created one must not skew the verification count).
 */
export async function countObjectsUnderPrefix(bucket: string, prefix: string): Promise<number> {
  let count = 0;
  let continuationToken: string | undefined;
  do {
    const page = await s3Client.send(
      new ListObjectsV2Command({
        Bucket: bucket,
        Prefix: prefix,
        ...(continuationToken ? { ContinuationToken: continuationToken } : {}),
      })
    );
    for (const object of page.Contents ?? []) {
      if (object.Key && !object.Key.endsWith('/')) count++;
    }
    continuationToken = page.IsTruncated ? page.NextContinuationToken : undefined;
  } while (continuationToken);
  return count;
}

/** One listed object: its full key and byte size. */
export interface ListedObject {
  key: string;
  size: number;
}

/**
 * Lists every object under [prefix] (key + size), following continuation
 * tokens like {@link countObjectsUnderPrefix} and applying the same
 * folder-marker exclusion. Used by the staff export, whose per-job object
 * count is small (≤ ~120) — the result is returned as one array, not a stream.
 */
export async function listObjectsUnderPrefix(
  bucket: string,
  prefix: string
): Promise<ListedObject[]> {
  const objects: ListedObject[] = [];
  let continuationToken: string | undefined;
  do {
    const page = await s3Client.send(
      new ListObjectsV2Command({
        Bucket: bucket,
        Prefix: prefix,
        ...(continuationToken ? { ContinuationToken: continuationToken } : {}),
      })
    );
    for (const object of page.Contents ?? []) {
      if (object.Key && !object.Key.endsWith('/')) {
        objects.push({ key: object.Key, size: object.Size ?? 0 });
      }
    }
    continuationToken = page.IsTruncated ? page.NextContinuationToken : undefined;
  } while (continuationToken);
  return objects;
}

/**
 * Presigns a GET URL for one object. Local SigV4 signing — no network call —
 * so presigning a whole export manifest in parallel is cheap. The URL is a
 * bearer credential for that object until [expiresInSeconds]: NEVER log it.
 */
export async function presignObjectGetUrl(
  bucket: string,
  key: string,
  expiresInSeconds: number
): Promise<string> {
  return getSignedUrl(s3Client, new GetObjectCommand({ Bucket: bucket, Key: key }), {
    expiresIn: expiresInSeconds,
  });
}

/** Result of fetching a text object: absent (404) or its body string. */
export type FetchedObject = { outcome: 'absent' } | { outcome: 'ok'; body: string };

/**
 * Fetches an object's body as text. Absent (404) is a normal outcome, never an
 * error; other S3 failures rethrow. Parsing/interpretation is the caller's
 * concern — this returns the raw string.
 */
export async function getObjectText(bucket: string, key: string): Promise<FetchedObject> {
  try {
    const result = await s3Client.send(new GetObjectCommand({ Bucket: bucket, Key: key }));
    const body = await result.Body?.transformToString();
    return { outcome: 'ok', body: body ?? '' };
  } catch (err) {
    if (isNotFound(err)) return { outcome: 'absent' };
    throw err;
  }
}

/**
 * Copies one object (server-side) from (bucket, sourceKey) to (bucket, destKey).
 * S3 CopyObject is a single server-side operation — no bytes transit this
 * process. A missing source surfaces as a thrown NoSuchKey; the caller decides
 * whether that is an error or a "already gone" no-op.
 */
export async function copyObject(
  bucket: string,
  sourceKey: string,
  destKey: string
): Promise<void> {
  await s3Client.send(
    new CopyObjectCommand({
      Bucket: bucket,
      // CopySource is `${bucket}/${key}` URL-encoded so keys with reserved
      // characters (none in our canonical keys, but be correct) copy safely.
      CopySource: encodeURI(`${bucket}/${sourceKey}`),
      Key: destKey,
    })
  );
}

/**
 * Deletes one object at (bucket, key). S3 DeleteObject is idempotent — deleting
 * an absent key is a success (204), never a 404 — so this never throws for a
 * missing key.
 */
export async function deleteObject(bucket: string, key: string): Promise<void> {
  await s3Client.send(new DeleteObjectCommand({ Bucket: bucket, Key: key }));
}

/**
 * "Soft delete" one object: copy it to [destKey], then delete the original — an
 * S3 has no native move, so this is the two-step equivalent. Returns:
 *   - 'moved'   — the source existed and is now only at destKey.
 *   - 'missing' — the source did not exist (nothing copied, nothing deleted).
 * The copy runs first so a crash between the two steps leaves the object
 * readable at BOTH locations (recoverable) rather than lost.
 */
export async function moveObject(
  bucket: string,
  sourceKey: string,
  destKey: string
): Promise<'moved' | 'missing'> {
  if (!(await objectExists(bucket, sourceKey))) return 'missing';
  await copyObject(bucket, sourceKey, destKey);
  await deleteObject(bucket, sourceKey);
  return 'moved';
}

function isNotFound(err: unknown): boolean {
  if (typeof err !== 'object' || err === null) return false;
  const e = err as { name?: string; $metadata?: { httpStatusCode?: number } };
  return e.name === 'NotFound' || e.name === 'NoSuchKey' || e.$metadata?.httpStatusCode === 404;
}
