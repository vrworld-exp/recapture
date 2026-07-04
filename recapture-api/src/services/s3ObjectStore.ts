// src/services/s3ObjectStore.ts
//
// Small S3 object-inspection helpers over the SHARED configured client
// (config/s3.ts — never a second client): existence check (HEAD) and a
// FULLY-PAGINATED object count under a prefix. Pure S3 concerns; the finalize
// verification rules live in jobsService.
import {
  GetObjectCommand,
  HeadObjectCommand,
  ListObjectsV2Command,
} from '@aws-sdk/client-s3';
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

function isNotFound(err: unknown): boolean {
  if (typeof err !== 'object' || err === null) return false;
  const e = err as { name?: string; $metadata?: { httpStatusCode?: number } };
  return e.name === 'NotFound' || e.name === 'NoSuchKey' || e.$metadata?.httpStatusCode === 404;
}
