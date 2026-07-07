// scripts/aws-smoke-test.ts
//
// End-to-end AWS smoke test against the REAL configured account/buckets.
// Run with: npx tsx scripts/aws-smoke-test.ts   (from recapture-api/)
//
// Exercises exactly what the API uses in production, via the same shared
// client and services:
//   1. ListObjectsV2 on both buckets            (creds + region + bucket exist)
//   2. Put → Head → Get → Delete a test object  (rw perms on raw bucket)
//   3. Put → Delete on the artifacts bucket     (worker write path)
//   4. Multipart initiate → presign part URL → real PUT via the presigned
//      URL → abort                              (the /jobs upload-urls flow)
//   5. CloudFront base URL reachability         (informational only)
//
// Everything it creates lives under the `_smoke-test/` prefix and is deleted
// (or the multipart upload aborted) before exit. Never prints secrets.
import {
  DeleteObjectCommand,
  ListObjectsV2Command,
  PutObjectCommand,
  AbortMultipartUploadCommand,
} from '@aws-sdk/client-s3';
import { s3Client, BUCKET_RAW, BUCKET_ARTIFACTS, CLOUDFRONT_BASE } from '../src/config/s3';
import { env } from '../src/config/env';
import { objectExists, getObjectText } from '../src/services/s3ObjectStore';
import { initiateMultipartUpload, presignPartUrl } from '../src/services/s3MultipartService';

let failures = 0;

function pass(step: string, detail = ''): void {
  console.log(`  ✅ ${step}${detail ? ` — ${detail}` : ''}`);
}

function fail(step: string, err: unknown): void {
  failures++;
  const e = err as { name?: string; message?: string; $metadata?: { httpStatusCode?: number } };
  const status = e.$metadata?.httpStatusCode ? ` (HTTP ${e.$metadata.httpStatusCode})` : '';
  console.log(`  ❌ ${step} — ${e.name ?? 'Error'}${status}: ${e.message ?? String(err)}`);
}

async function testListBucket(bucket: string): Promise<void> {
  try {
    const page = await s3Client.send(
      new ListObjectsV2Command({ Bucket: bucket, MaxKeys: 1 })
    );
    const hint = page.KeyCount ? 'has objects' : 'empty';
    pass(`list ${bucket}`, hint);
  } catch (err) {
    fail(`list ${bucket}`, err);
  }
}

async function testPutHeadGetDelete(bucket: string, fullRoundTrip: boolean): Promise<void> {
  const key = `_smoke-test/${Date.now()}.txt`;
  const body = `recapture aws smoke test ${new Date().toISOString()}`;
  try {
    await s3Client.send(new PutObjectCommand({ Bucket: bucket, Key: key, Body: body }));
    pass(`put ${bucket}/${key}`);
  } catch (err) {
    fail(`put ${bucket}/${key}`, err);
    return; // nothing to head/get/delete
  }

  if (fullRoundTrip) {
    try {
      const exists = await objectExists(bucket, key);
      exists ? pass('head (objectExists)') : fail('head (objectExists)', new Error('returned false for existing object'));
    } catch (err) {
      fail('head (objectExists)', err);
    }
    try {
      const fetched = await getObjectText(bucket, key);
      fetched.outcome === 'ok' && fetched.body === body
        ? pass('get (getObjectText)', 'body matches')
        : fail('get (getObjectText)', new Error(`outcome=${fetched.outcome}, body mismatch`));
    } catch (err) {
      fail('get (getObjectText)', err);
    }
  }

  try {
    await s3Client.send(new DeleteObjectCommand({ Bucket: bucket, Key: key }));
    pass(`delete ${bucket}/${key}`);
  } catch (err) {
    fail(`delete ${bucket}/${key}`, err);
  }
}

async function testMultipartPresignFlow(): Promise<void> {
  const key = `_smoke-test/multipart-${Date.now()}.bin`;
  let uploadId: string | undefined;
  try {
    uploadId = await initiateMultipartUpload(BUCKET_RAW, key);
    pass('multipart initiate', `uploadId ${uploadId.slice(0, 12)}…`);
  } catch (err) {
    fail('multipart initiate', err);
    return;
  }

  try {
    const url = await presignPartUrl(BUCKET_RAW, key, uploadId, 1);
    pass('presign part URL');
    // Real PUT through the presigned URL — proves signature, clock skew and
    // bucket policy all line up for the client-side upload path.
    const res = await fetch(url, { method: 'PUT', body: 'smoke-test part payload' });
    if (res.ok && res.headers.get('etag')) {
      pass('PUT via presigned URL', `ETag ${res.headers.get('etag')}`);
    } else {
      fail('PUT via presigned URL', new Error(`HTTP ${res.status}: ${(await res.text()).slice(0, 200)}`));
    }
  } catch (err) {
    fail('presigned part upload', err);
  } finally {
    try {
      await s3Client.send(
        new AbortMultipartUploadCommand({ Bucket: BUCKET_RAW, Key: key, UploadId: uploadId })
      );
      pass('multipart abort (cleanup)');
    } catch (err) {
      fail('multipart abort (cleanup)', err);
    }
  }
}

async function testCloudFront(): Promise<void> {
  try {
    const res = await fetch(CLOUDFRONT_BASE, { method: 'HEAD' });
    // Any HTTP answer means DNS + distribution respond; 403/404 is expected
    // while nothing is published. Informational only — never a failure.
    pass('CloudFront reachable', `HTTP ${res.status}`);
  } catch (err) {
    const e = err as { message?: string; cause?: { code?: string } };
    console.log(
      `  ⚠️ CloudFront not reachable (informational): ${e.cause?.code ?? e.message ?? String(err)}`
    );
  }
}

async function main(): Promise<void> {
  console.log(`AWS smoke test — region ${env.AWS_REGION}`);
  console.log(`  raw bucket:       ${BUCKET_RAW}`);
  console.log(`  artifacts bucket: ${BUCKET_ARTIFACTS}`);
  console.log(`  cloudfront:       ${CLOUDFRONT_BASE}`);

  console.log('\n[1/5] Bucket access (list)');
  await testListBucket(BUCKET_RAW);
  await testListBucket(BUCKET_ARTIFACTS);

  console.log('\n[2/5] Raw bucket put/head/get/delete');
  await testPutHeadGetDelete(BUCKET_RAW, true);

  console.log('\n[3/5] Artifacts bucket put/delete');
  await testPutHeadGetDelete(BUCKET_ARTIFACTS, false);

  console.log('\n[4/5] Multipart initiate → presign → PUT → abort (upload-urls flow)');
  await testMultipartPresignFlow();

  console.log('\n[5/5] CloudFront base URL');
  await testCloudFront();

  console.log(failures === 0 ? '\nAll AWS checks passed ✅' : `\n${failures} check(s) FAILED ❌`);
  process.exit(failures === 0 ? 0 : 1);
}

main().catch((err) => {
  console.error('Smoke test crashed:', err);
  process.exit(1);
});
