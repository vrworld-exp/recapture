// scripts/e2e/stage5-upload-pipeline.ts
//
// Full upload pipeline against the live API + real S3, exactly like the app:
//   create project → POST /jobs (Idempotency-Key, replay, conflict) →
//   per-file initiate → PUT real bytes through presigned URLs (one file
//   multipart 2-part, incl. the part-url refresh endpoint) → complete →
//   manifest → finalize (422 manifest_missing first, then 200 QUEUED,
//   idempotent replay) → project PROCESSING.
// Second job: plan-expiry 410 (backdated createdAt), key containment 400,
// bad-manifest finalize → 422 with stable rule ids.
//
// KNOWN GAP (finding): the API has no multipart complete/abort endpoints
// (jobsService comment says "separate endpoints" — routes/jobs.ts has none),
// so this script completes each multipart upload directly via the shared S3
// client, standing in for the missing endpoint.
import { randomUUID, randomBytes } from 'crypto';
import {
  CompleteMultipartUploadCommand,
  PutObjectCommand,
} from '@aws-sdk/client-s3';
import { Types } from 'mongoose';
import { s3Client } from '../../src/config/s3';
import { Job } from '../../src/models/Job';
import { objectExists, countObjectsUnderPrefix } from '../../src/services/s3ObjectStore';
import {
  connectDb,
  disconnectDb,
  loadState,
  saveState,
  check,
  finish,
  api,
} from './_shared';

const RINGS = ['EYE', 'TOP', 'LOW'] as const;
const PHOTOS_PER_RING = 18; // LARGE minimum per ring
const PHOTO_COUNT = RINGS.length * PHOTOS_PER_RING; // 54
const EXPECTED_FILES = PHOTO_COUNT + 1; // + capture_manifest.json (counted under prefix)

/** Pseudo-JPEG bytes (JPEG SOI magic + random payload). */
function fakeJpeg(size: number): Buffer {
  return Buffer.concat([Buffer.from([0xff, 0xd8, 0xff, 0xe0]), randomBytes(size - 4)]);
}

async function putViaPresignedUrl(url: string, bytes: Buffer): Promise<string | null> {
  const res = await fetch(url, { method: 'PUT', body: bytes });
  if (!res.ok) return null;
  return res.headers.get('etag');
}

async function completeMultipart(
  bucket: string,
  key: string,
  uploadId: string,
  parts: Array<{ PartNumber: number; ETag: string }>
): Promise<void> {
  await s3Client.send(
    new CompleteMultipartUploadCommand({
      Bucket: bucket,
      Key: key,
      UploadId: uploadId,
      MultipartUpload: { Parts: parts },
    })
  );
}

/** Uploads one file fully through the API path (initiate → presigned PUTs →
 *  complete). Returns false on any failure. */
async function uploadFile(
  tok: string,
  jobId: string,
  bucket: string,
  key: string,
  bytes: Buffer,
  partSizeMin: number,
  opts: { refreshPart2ViaEndpoint?: boolean } = {}
): Promise<boolean> {
  const partCount = bytes.length > partSizeMin ? Math.ceil(bytes.length / partSizeMin) : 1;
  const init = await api('POST', `/jobs/${jobId}/uploads/initiate`, {
    token: tok,
    body: { key, fileSize: bytes.length, partCount },
  });
  if (init.status !== 201) {
    console.log(`    initiate failed for ${key}: ${init.status} ${JSON.stringify(init.body)}`);
    return false;
  }
  const uploadId: string = init.body.uploadId;
  const urls: Array<{ partNumber: number; url: string }> = init.body.parts;

  const etags: Array<{ PartNumber: number; ETag: string }> = [];
  for (let p = 1; p <= partCount; p++) {
    let url = urls.find((u) => u.partNumber === p)?.url;
    if (p === 2 && opts.refreshPart2ViaEndpoint) {
      // Exercise the part-url refresh endpoint for a real part upload.
      const refreshed = await api('POST', `/jobs/${jobId}/uploads/part-url`, {
        token: tok,
        body: { key, uploadId, partNumber: p },
      });
      if (refreshed.status !== 200) return false;
      url = refreshed.body.url;
    }
    if (!url) return false;
    const start = (p - 1) * partSizeMin;
    const end = p === partCount ? bytes.length : p * partSizeMin;
    const etag = await putViaPresignedUrl(url, bytes.subarray(start, end));
    if (!etag) return false;
    etags.push({ PartNumber: p, ETag: etag });
  }
  await completeMultipart(bucket, key, uploadId, etags);
  return true;
}

async function main(): Promise<void> {
  const state = loadState();
  const tok = state.accessToken!;
  const tag = state.runTag;
  await connectDb();

  // ── project + job ───────────────────────────────────────────────────────────
  const proj = await api('POST', '/projects', {
    token: tok,
    body: { name: `${tag}_upload_project`, size: 'large', mode: 'guided' },
  });
  const projectId: string = proj.body?.project?.id ?? proj.body?.project?._id;
  check('create upload project (large) → 201', proj.status === 201, `got ${proj.status}`);

  const idemKey = `e2e-${randomUUID()}`;
  const jobBody = { projectId, objectSize: 'large', expectedFilesCount: EXPECTED_FILES };
  const created = await api('POST', '/jobs', {
    token: tok,
    body: jobBody,
    headers: { 'Idempotency-Key': idemKey },
  });
  check(
    'POST /jobs → 201 + uploadPlan (no presigned URLs at create)',
    created.status === 201 &&
      created.body?.job?.state === 'CREATED' &&
      created.body?.uploadPlan?.keyPrefix?.length > 0 &&
      created.body?.uploadPlan?.manifestKey?.length > 0 &&
      JSON.stringify(created.body?.uploadPlan).indexOf('X-Amz-Signature') === -1,
    `got ${created.status}`
  );
  const jobId: string = created.body.job.id;
  const plan = created.body.uploadPlan;
  const bucket: string = plan.bucket;
  const keyPrefix: string = plan.keyPrefix;

  const projAfterJob = await api('GET', `/projects/${projectId}`, { token: tok });
  check(
    'project status → UPLOADING after create-job',
    projAfterJob.body?.project?.status === 'UPLOADING',
    `got ${projAfterJob.body?.project?.status}`
  );

  // Idempotency: same key + same payload → replay; same key + different → 409
  const replay = await api('POST', '/jobs', {
    token: tok,
    body: jobBody,
    headers: { 'Idempotency-Key': idemKey },
  });
  check(
    'idempotent replay → 200, same job id, idempotentReplay: true',
    replay.status === 200 && replay.body?.idempotentReplay === true && replay.body?.job?.id === jobId,
    `got ${replay.status}`
  );
  const conflict = await api('POST', '/jobs', {
    token: tok,
    body: { ...jobBody, expectedFilesCount: EXPECTED_FILES + 1 },
    headers: { 'Idempotency-Key': idemKey },
  });
  check('same key + different payload → 409', conflict.status === 409, `got ${conflict.status}`);

  // ── negative guards before uploading ────────────────────────────────────────
  const outsideKey = `${keyPrefix.split('/')[0]}/intruder/${jobId}/images/EYE/evil.jpg`;
  const containment = await api('POST', `/jobs/${jobId}/uploads/initiate`, {
    token: tok,
    body: { key: outsideKey, fileSize: 1024, partCount: 1 },
  });
  check(
    'initiate with key outside keyPrefix → 400 INVALID_REQUEST',
    containment.status === 400,
    `got ${containment.status}`
  );

  const earlyFinalize = await api('POST', `/jobs/${jobId}/finalize`, { token: tok, body: {} });
  check(
    'finalize before manifest → 422 manifest_missing',
    earlyFinalize.status === 422 && earlyFinalize.body?.reason === 'manifest_missing',
    `got ${earlyFinalize.status}/${earlyFinalize.body?.reason}`
  );

  // ── upload all 54 photos through the API path ───────────────────────────────
  const uploadedKeys: string[] = [];
  const bigSize = plan.partSizeMin + 1024 * 1024; // 5 MiB + 1 MiB → 2 parts
  let uploadFailures = 0;
  let first = true;
  for (const ring of RINGS) {
    for (let i = 1; i <= PHOTOS_PER_RING; i++) {
      const name = `${ring.toLowerCase()}_${String(i).padStart(4, '0')}.jpg`;
      const key = `${keyPrefix}images/${ring}/${name}`;
      const bytes = first ? fakeJpeg(bigSize) : fakeJpeg(2048);
      const ok = await uploadFile(tok, jobId, bucket, key, bytes, plan.partSizeMin, {
        refreshPart2ViaEndpoint: first, // multipart file also exercises part-url refresh
      });
      if (!ok) uploadFailures++;
      else uploadedKeys.push(key);
      first = false;
    }
  }
  check(
    `all ${PHOTO_COUNT} photos uploaded via initiate→presigned PUT→complete`,
    uploadFailures === 0,
    uploadFailures ? `${uploadFailures} failed` : `incl. one ${(bigSize / 1048576).toFixed(1)}MiB 2-part multipart`
  );

  const bigLanded = await objectExists(bucket, uploadedKeys[0]);
  check('multipart object landed in S3 (HEAD)', bigLanded);

  // ── manifest + finalize ─────────────────────────────────────────────────────
  const manifest = {
    version: 1,
    summary: { totalPhotos: PHOTO_COUNT },
    photos: uploadedKeys.map((k) => {
      const segs = k.split('/');
      return { ringName: segs[segs.length - 2], fileName: segs[segs.length - 1] };
    }),
  };
  const manifestBytes = Buffer.from(JSON.stringify(manifest, null, 2));
  const manifestOk = await uploadFile(
    tok,
    jobId,
    bucket,
    plan.manifestKey,
    manifestBytes,
    plan.partSizeMin
  );
  check('capture_manifest.json uploaded to plan.manifestKey', manifestOk);
  uploadedKeys.push(plan.manifestKey);

  const s3Count = await countObjectsUnderPrefix(bucket, keyPrefix);
  check(`S3 count under keyPrefix == ${EXPECTED_FILES}`, s3Count === EXPECTED_FILES, `got ${s3Count}`);

  const fin = await api('POST', `/jobs/${jobId}/finalize`, {
    token: tok,
    body: { reportedFilesCount: EXPECTED_FILES },
  });
  check(
    'finalize → 200 QUEUED, filesVerified matches',
    fin.status === 200 && fin.body?.state === 'QUEUED' && fin.body?.filesVerified === EXPECTED_FILES,
    `got ${fin.status}/${fin.body?.state}/${fin.body?.filesVerified}`
  );
  const finReplay = await api('POST', `/jobs/${jobId}/finalize`, { token: tok, body: {} });
  check(
    'finalize replay → 200 idempotentReplay',
    finReplay.status === 200 && finReplay.body?.idempotentReplay === true,
    `got ${finReplay.status}`
  );
  const projAfterFin = await api('GET', `/projects/${projectId}`, { token: tok });
  check(
    'project status → PROCESSING after finalize',
    projAfterFin.body?.project?.status === 'PROCESSING',
    `got ${projAfterFin.body?.project?.status}`
  );

  // ── second job: plan-expiry 410 + bad-manifest 422 ──────────────────────────
  const proj2 = await api('POST', '/projects', {
    token: tok,
    body: { name: `${tag}_badmanifest_project`, size: 'large', mode: 'guided' },
  });
  const project2Id: string = proj2.body?.project?.id ?? proj2.body?.project?._id;
  const job2 = await api('POST', '/jobs', {
    token: tok,
    body: { projectId: project2Id, objectSize: 'large', expectedFilesCount: PHOTO_COUNT },
  });
  const job2Id: string = job2.body?.job?.id;
  const plan2 = job2.body?.uploadPlan;
  check('second job created', job2.status === 201, `got ${job2.status}`);

  // Plan expiry: expiresAt derives from createdAt — backdate 25h → initiate → 410.
  const realCreatedAt = (await Job.findById(job2Id).exec())!.createdAt;
  await Job.updateOne(
    { _id: new Types.ObjectId(job2Id) },
    { $set: { createdAt: new Date(Date.now() - 25 * 3600 * 1000) } },
    { timestamps: false }
  ).exec();
  const expired = await api('POST', `/jobs/${job2Id}/uploads/initiate`, {
    token: tok,
    body: { key: `${plan2.keyPrefix}images/EYE/x.jpg`, fileSize: 1024, partCount: 1 },
  });
  check('initiate after plan window → 410 PLAN_EXPIRED', expired.status === 410, `got ${expired.status}`);
  await Job.updateOne(
    { _id: new Types.ObjectId(job2Id) },
    { $set: { createdAt: realCreatedAt } },
    { timestamps: false }
  ).exec();

  // Bad manifest: 54 objects total (53 photos all EYE + manifest) so the COUNT
  // matches but content breaks MISSING_REQUIRED_LEVELS (+ FILE_COUNT_MISMATCH).
  // Direct PutObject here — the API upload path is already proven above.
  const job2Keys: string[] = [];
  for (let i = 1; i <= PHOTO_COUNT - 1; i++) {
    const key = `${plan2.keyPrefix}images/EYE/eye_${String(i).padStart(4, '0')}.jpg`;
    await s3Client.send(
      new PutObjectCommand({ Bucket: plan2.bucket, Key: key, Body: fakeJpeg(512) })
    );
    job2Keys.push(key);
  }
  const badManifest = {
    version: 1,
    summary: { totalPhotos: PHOTO_COUNT }, // declares 54, actual entries 53 → FILE_COUNT_MISMATCH
    photos: job2Keys.map((k) => ({ ringName: 'EYE', fileName: k.split('/').pop() })),
  };
  await s3Client.send(
    new PutObjectCommand({
      Bucket: plan2.bucket,
      Key: plan2.manifestKey,
      Body: JSON.stringify(badManifest),
    })
  );
  job2Keys.push(plan2.manifestKey);

  const badFin = await api('POST', `/jobs/${job2Id}/finalize`, { token: tok, body: {} });
  const rules = (badFin.body?.validationErrors ?? []).map((e: any) => e.rule).sort();
  check(
    'bad-manifest finalize → 422 manifest_invalid + stable rule ids',
    badFin.status === 422 &&
      badFin.body?.reason === 'manifest_invalid' &&
      rules.includes('FILE_COUNT_MISMATCH') &&
      rules.includes('MISSING_REQUIRED_LEVELS'),
    `got ${badFin.status}/${badFin.body?.reason}/[${rules.join(',')}]`
  );

  saveState({
    ...state,
    projectId,
    jobId,
    badJobId: job2Id,
    project2Id,
    jobRootPrefix: keyPrefix,
    job2RootPrefix: plan2.keyPrefix,
    uploadedKeys: [...uploadedKeys, ...job2Keys],
    bucket,
  });
  await disconnectDb();
  finish();
}

main().catch((err) => {
  console.error('stage5 crashed:', err);
  process.exit(1);
});
