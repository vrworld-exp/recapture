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
  PutObjectCommand,
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

/** Result of HEADing an object: absent (404) or its metadata. */
export type HeadResult =
  | { outcome: 'absent' }
  | { outcome: 'ok'; contentLength: number; contentType: string };

/**
 * HEADs one object and returns its size + content type, or 'absent' for a 404.
 * Same absent-is-normal contract as {@link objectExists}, but it also answers
 * "how big is it" in the SAME round trip — which is what the avatar commit
 * needs, since S3 presigning has no size condition and the byte ceiling can
 * only be enforced after the object exists.
 *
 * A missing ContentLength (S3 always sends one for a real object) reads as 0
 * rather than throwing: a size check must fail OPEN on a weird response, never
 * reject a legitimate upload over a missing header.
 */
export async function headObject(bucket: string, key: string): Promise<HeadResult> {
  try {
    const result = await s3Client.send(new HeadObjectCommand({ Bucket: bucket, Key: key }));
    return {
      outcome: 'ok',
      contentLength: result.ContentLength ?? 0,
      contentType: result.ContentType ?? 'application/octet-stream',
    };
  } catch (err) {
    if (isNotFound(err)) return { outcome: 'absent' };
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
 *
 * Pass `downloadFilename` to have S3 return the object with
 * `Content-Disposition: attachment; filename="…"`. This makes the presigned URL
 * a browser-downloadable link (correct filename + the object's stored
 * content-type) WITHOUT any cross-origin byte fetch — the raw-captures bucket
 * has no CORS policy, so a web client can't XHR the bytes, but a plain
 * navigation to a Content-Disposition URL downloads fine. It does not affect
 * how the same URL renders as an `<img>`/decoder subresource (that path ignores
 * the header), so it is safe to reuse one URL for both thumbnail and download.
 */
export async function presignObjectGetUrl(
  bucket: string,
  key: string,
  expiresInSeconds: number,
  options?: { downloadFilename?: string }
): Promise<string> {
  const disposition = options?.downloadFilename
    ? `attachment; filename="${sanitizeContentDispositionFilename(options.downloadFilename)}"`
    : undefined;
  return getSignedUrl(
    s3Client,
    new GetObjectCommand({
      Bucket: bucket,
      Key: key,
      ...(disposition ? { ResponseContentDisposition: disposition } : {}),
    }),
    { expiresIn: expiresInSeconds }
  );
}

/**
 * Sanitizes a filename for the quoted-string form of a Content-Disposition
 * header: replaces any whitespace — including the CR/LF a header-injection
 * attempt would need — plus the `"`/`\` that would break the quoting. S3 keys
 * are already restricted to a safe alphabet, so in practice this is a no-op
 * belt-and-braces.
 */
function sanitizeContentDispositionFilename(name: string): string {
  return name.replace(/["\\\s]/g, '_');
}

/**
 * Presigns a PUT URL for one object. Same local-SigV4 economics as
 * {@link presignObjectGetUrl} — cheap to mint in parallel. The Content-Type is
 * part of the signature, so the uploader can only ever store an object of the
 * declared type. The URL is a WRITE bearer credential for that exact key until
 * [expiresInSeconds]: NEVER log it.
 */
export async function presignObjectPutUrl(
  bucket: string,
  key: string,
  expiresInSeconds: number,
  contentType: string
): Promise<string> {
  return getSignedUrl(
    s3Client,
    new PutObjectCommand({ Bucket: bucket, Key: key, ContentType: contentType }),
    { expiresIn: expiresInSeconds }
  );
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

/** Result of fetching a binary object: absent (404) or its bytes + type. */
export type FetchedBytes =
  | { outcome: 'absent' }
  | { outcome: 'ok'; body: Buffer; contentType: string };

/**
 * Fetches an object's body as BYTES. Same absent-is-normal contract as
 * {@link getObjectText}, but for images: used by the admin photo-bytes proxy,
 * which streams a capture through the API so browser clients can read it
 * without the raw bucket needing CORS.
 *
 * Reads the whole object into memory deliberately — callers are limited to
 * single capture photos (a few MB), and buffering keeps the route's error
 * mapping simple (a mid-stream S3 failure cannot corrupt an already-committed
 * 200 response).
 */
export async function getObjectBytes(bucket: string, key: string): Promise<FetchedBytes> {
  try {
    const result = await s3Client.send(new GetObjectCommand({ Bucket: bucket, Key: key }));
    const bytes = await result.Body?.transformToByteArray();
    return {
      outcome: 'ok',
      body: Buffer.from(bytes ?? new Uint8Array()),
      contentType: result.ContentType ?? 'application/octet-stream',
    };
  } catch (err) {
    if (isNotFound(err)) return { outcome: 'absent' };
    throw err;
  }
}

/**
 * Writes [body] to (bucket, key), overwriting any existing object. S3 PutObject
 * is a full replace, so a re-run with the same deterministic key is idempotent —
 * which is exactly what makes a retried/resumed worker stage safe to repeat.
 */
export async function putObjectBytes(
  bucket: string,
  key: string,
  body: Uint8Array,
  contentType: string
): Promise<void> {
  await s3Client.send(
    new PutObjectCommand({ Bucket: bucket, Key: key, Body: body, ContentType: contentType })
  );
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
 * PERMANENTLY deletes every object under [prefix] (admin hard-delete). Lists
 * first — continuation tokens included — then deletes one by one; per-job
 * volumes are small (≤ ~120 objects), so sequential deletes are fine and keep
 * this on the same primitives the rest of the store uses. Returns the number
 * of objects deleted. Idempotent: an empty prefix deletes nothing and returns 0.
 *
 * A THROW mid-way leaves the remainder in place — callers must treat a failure
 * as retryable (delete-object is idempotent) rather than assume the prefix is
 * gone.
 */
export async function deleteObjectsUnderPrefix(bucket: string, prefix: string): Promise<number> {
  const objects = await listObjectsUnderPrefix(bucket, prefix);
  for (const object of objects) {
    await deleteObject(bucket, object.key);
  }
  return objects.length;
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
