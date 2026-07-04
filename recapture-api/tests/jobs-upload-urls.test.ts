// tests/jobs-upload-urls.test.ts
//
// POST /jobs/:jobId/uploads/initiate + /uploads/part-url — the per-file
// presign step of the upload pipeline. Hermetic: in-memory MongoDB; the ONE
// S3 network call (CreateMultipartUpload) is spied on the shared client, while
// presigning runs the REAL SigV4 signer (local, offline with the test creds) —
// so the asserted URLs are genuine presigned URLs, not fixtures.
import { describe, it, expect, beforeAll, afterAll, afterEach, vi } from 'vitest';
import request from 'supertest';
import mongoose, { Types } from 'mongoose';
import jwt from 'jsonwebtoken';
import { MongoMemoryServer } from 'mongodb-memory-server';

import { createApp } from '@/app';
import { env } from '@/config/env';
import { s3Client } from '@/config/s3';
import { Project } from '@/models/Project';
import { Job } from '@/models/Job';

const app = createApp();
let mongod: MongoMemoryServer;

beforeAll(async () => {
  mongod = await MongoMemoryServer.create();
  await mongoose.connect(mongod.getUri());
  await Job.syncIndexes();
});

afterAll(async () => {
  await mongoose.disconnect();
  await mongod.stop();
});

afterEach(async () => {
  await Project.deleteMany({});
  await Job.deleteMany({});
  vi.restoreAllMocks();
});

const userId = new Types.ObjectId().toHexString();
const auth = {
  Authorization: `Bearer ${jwt.sign({ userId, authUid: `test|${userId}` }, env.JWT_SECRET, {
    expiresIn: '15m',
  })}`,
};

function authFor(otherUserId: string) {
  return {
    Authorization: `Bearer ${jwt.sign(
      { userId: otherUserId, authUid: `test|${otherUserId}` },
      env.JWT_SECRET,
      { expiresIn: '15m' }
    )}`,
  };
}

/** Creates a project + job through the real endpoint; returns jobId + keyPrefix. */
async function makeJob(
  owner: string = userId,
  headers: Record<string, string> = auth
): Promise<{ jobId: string; keyPrefix: string }> {
  const p = await Project.create({
    userId: new Types.ObjectId(owner),
    name: 'Brass Vase',
    objectSize: 'MEDIUM',
    mode: 'GUIDED',
  });
  const res = await request(app)
    .post('/jobs')
    .set(headers)
    .send({ projectId: p.id, objectSize: 'medium', expectedFilesCount: 73 });
  expect(res.status).toBe(201);
  return { jobId: res.body.job.id, keyPrefix: res.body.uploadPlan.keyPrefix };
}

/** Spies the shared client's send (the CreateMultipartUpload network call).
 * Pass `null` to simulate S3 responding WITHOUT an UploadId. */
function mockS3Initiate(uploadId: string | null = 'test-upload-id') {
  return vi
    .spyOn(s3Client, 'send')
    .mockResolvedValue((uploadId === null ? {} : { UploadId: uploadId }) as never);
}

const TWELVE_MIB = 12 * 1024 * 1024;

describe('POST /jobs/:jobId/uploads/initiate', () => {
  it('201: returns uploadId + one REAL presigned URL per part; job → UPLOADING', async () => {
    const { jobId, keyPrefix } = await makeJob();
    const sendSpy = mockS3Initiate();
    const key = `${keyPrefix}images/EYE/eye_0001.jpg`;

    const before = Date.now();
    const res = await request(app)
      .post(`/jobs/${jobId}/uploads/initiate`)
      .set(auth)
      .send({ key, fileSize: TWELVE_MIB, partCount: 3 });

    expect(res.status).toBe(201);
    expect(res.body.status).toBe('success');
    expect(res.body.uploadId).toBe('test-upload-id');
    expect(res.body.key).toBe(key);

    // ceil(12MiB / 5MiB) = 3 parts, numbered 1..3, each a real presigned URL.
    expect(res.body.parts).toHaveLength(3);
    expect(res.body.parts.map((p: { partNumber: number }) => p.partNumber)).toEqual([1, 2, 3]);
    for (const part of res.body.parts) {
      expect(part.url).toMatch(/^https:\/\//);
      expect(part.url).toContain('X-Amz-Signature');
      expect(part.url).toContain('uploadId=test-upload-id');
      expect(part.url).toContain(`partNumber=${part.partNumber}`);
      expect(part.url).toContain(encodeURIComponent('recapture-test-raw').toLowerCase());
    }

    // 1-hour presign window echoed.
    const ttlMs = Date.parse(res.body.urlsExpireAt) - before;
    expect(ttlMs).toBeGreaterThan(3500 * 1000);
    expect(ttlMs).toBeLessThanOrEqual(3600 * 1000 + 5000);

    // Exactly one S3 initiate, against the shared client + raw bucket + key.
    const initiateCalls = sendSpy.mock.calls.filter(
      (c) => (c[0] as { constructor: { name: string } }).constructor.name ===
        'CreateMultipartUploadCommand'
    );
    expect(initiateCalls).toHaveLength(1);
    expect((initiateCalls[0]![0] as { input: { Bucket: string; Key: string } }).input).toEqual({
      Bucket: 'recapture-test-raw',
      Key: key,
    });

    // The job flipped CREATED → UPLOADING.
    const saved = await Job.findById(jobId).exec();
    expect(saved!.state).toBe('UPLOADING');
  });

  it('emits job_upload_started exactly once (the CREATED→UPLOADING flip)', async () => {
    const { jobId, keyPrefix } = await makeJob();
    mockS3Initiate();
    const logSpy = vi.spyOn(console, 'log').mockImplementation(() => {});

    for (const name of ['eye_0001.jpg', 'eye_0002.jpg']) {
      const res = await request(app)
        .post(`/jobs/${jobId}/uploads/initiate`)
        .set(auth)
        .send({ key: `${keyPrefix}images/EYE/${name}`, fileSize: TWELVE_MIB, partCount: 3 });
      expect(res.status).toBe(201);
    }

    const started = logSpy.mock.calls.filter((c) =>
      String(c[0]).includes('[analytics] job_upload_started')
    );
    expect(started).toHaveLength(1);
  });

  it('a repeat initiate for the SAME key mints a fresh uploadId (no reuse)', async () => {
    const { jobId, keyPrefix } = await makeJob();
    const key = `${keyPrefix}images/EYE/eye_0001.jpg`;

    mockS3Initiate('upload-1');
    const first = await request(app)
      .post(`/jobs/${jobId}/uploads/initiate`)
      .set(auth)
      .send({ key, fileSize: TWELVE_MIB, partCount: 3 });
    vi.restoreAllMocks();
    mockS3Initiate('upload-2');
    const second = await request(app)
      .post(`/jobs/${jobId}/uploads/initiate`)
      .set(auth)
      .send({ key, fileSize: TWELVE_MIB, partCount: 3 });

    expect(first.body.uploadId).toBe('upload-1');
    expect(second.body.uploadId).toBe('upload-2'); // re-initiate recovery path
  });

  it('key outside the job keyPrefix → 400, S3 never called', async () => {
    const { jobId } = await makeJob();
    const sendSpy = mockS3Initiate();

    const res = await request(app)
      .post(`/jobs/${jobId}/uploads/initiate`)
      .set(auth)
      .send({ key: 'development/other-user/steal.jpg', fileSize: TWELVE_MIB, partCount: 3 });

    expect(res.status).toBe(400);
    expect(res.body.fields).toHaveProperty('key');
    expect(sendSpy).not.toHaveBeenCalled();
  });

  it('key with a `..` segment or bad charset → 400', async () => {
    const { jobId, keyPrefix } = await makeJob();
    mockS3Initiate();

    for (const bad of [
      `${keyPrefix}images/../../evil.jpg`,
      `${keyPrefix}images//eye.jpg`,
      `${keyPrefix}images/eye 0001.jpg`,
      keyPrefix, // empty remainder
    ]) {
      const res = await request(app)
        .post(`/jobs/${jobId}/uploads/initiate`)
        .set(auth)
        .send({ key: bad, fileSize: TWELVE_MIB, partCount: 3 });
      expect(res.status, `key: ${bad}`).toBe(400);
    }
  });

  it('unachievable partCount for fileSize → 400 with the achievable range', async () => {
    const { jobId, keyPrefix } = await makeJob();
    mockS3Initiate();

    // 3 MiB file → at most ceil(3MiB/5MiB) = 1 part.
    const res = await request(app)
      .post(`/jobs/${jobId}/uploads/initiate`)
      .set(auth)
      .send({ key: `${keyPrefix}images/EYE/e.jpg`, fileSize: 3 * 1024 * 1024, partCount: 3 });

    expect(res.status).toBe(400);
    expect(res.body.message).toContain('1-1');
  });

  it('zero/negative/absent fileSize → 400 (never NaN part math)', async () => {
    const { jobId, keyPrefix } = await makeJob();
    const key = `${keyPrefix}images/EYE/e.jpg`;
    mockS3Initiate();

    for (const body of [
      { key, fileSize: 0, partCount: 1 },
      { key, fileSize: -5, partCount: 1 },
      { key, partCount: 1 },
    ]) {
      const res = await request(app)
        .post(`/jobs/${jobId}/uploads/initiate`)
        .set(auth)
        .send(body);
      expect(res.status).toBe(400);
    }
  });

  it('expired plan window → 410 PLAN_EXPIRED', async () => {
    const { jobId, keyPrefix } = await makeJob();
    mockS3Initiate();
    // Age the job past the TTL (raw collection update — createdAt is immutable
    // through mongoose).
    await Job.collection.updateOne(
      { _id: new Types.ObjectId(jobId) },
      { $set: { createdAt: new Date(Date.now() - (env.UPLOAD_PLAN_TTL_SECONDS + 60) * 1000) } }
    );

    const res = await request(app)
      .post(`/jobs/${jobId}/uploads/initiate`)
      .set(auth)
      .send({ key: `${keyPrefix}images/EYE/e.jpg`, fileSize: TWELVE_MIB, partCount: 3 });

    expect(res.status).toBe(410);
    expect(res.body.code).toBe('PLAN_EXPIRED');
  });

  it('non-uploadable job state → 409', async () => {
    const { jobId, keyPrefix } = await makeJob();
    mockS3Initiate();
    await Job.updateOne({ _id: jobId }, { $set: { state: 'COMPLETED' } });

    const res = await request(app)
      .post(`/jobs/${jobId}/uploads/initiate`)
      .set(auth)
      .send({ key: `${keyPrefix}images/EYE/e.jpg`, fileSize: TWELVE_MIB, partCount: 3 });

    expect(res.status).toBe(409);
    expect(res.body.code).toBe('JOB_NOT_UPLOADABLE');
  });

  it('401 without a token; 400 malformed jobId; 404 unknown/foreign job', async () => {
    const { jobId, keyPrefix } = await makeJob();
    mockS3Initiate();
    const body = { key: `${keyPrefix}images/EYE/e.jpg`, fileSize: TWELVE_MIB, partCount: 3 };

    expect((await request(app).post(`/jobs/${jobId}/uploads/initiate`).send(body)).status).toBe(
      401
    );
    expect(
      (await request(app).post('/jobs/not-hex/uploads/initiate').set(auth).send(body)).status
    ).toBe(400);
    expect(
      (
        await request(app)
          .post(`/jobs/${new Types.ObjectId().toHexString()}/uploads/initiate`)
          .set(auth)
          .send(body)
      ).status
    ).toBe(404);

    const stranger = new Types.ObjectId().toHexString();
    const foreign = await request(app)
      .post(`/jobs/${jobId}/uploads/initiate`)
      .set(authFor(stranger))
      .send(body);
    expect(foreign.status).toBe(404); // not-owned is indistinguishable from missing
  });

  it('S3 returning no UploadId → 500 via the error handler, job stays CREATED', async () => {
    const { jobId, keyPrefix } = await makeJob();
    mockS3Initiate(null); // send resolves without an UploadId
    vi.spyOn(console, 'error').mockImplementation(() => {}); // errorHandler log

    const res = await request(app)
      .post(`/jobs/${jobId}/uploads/initiate`)
      .set(auth)
      .send({ key: `${keyPrefix}images/EYE/e.jpg`, fileSize: TWELVE_MIB, partCount: 3 });

    expect(res.status).toBe(500);
    const saved = await Job.findById(jobId).exec();
    expect(saved!.state).toBe('CREATED'); // no half-initiated state persisted
  });
});

describe('POST /jobs/:jobId/uploads/part-url', () => {
  it('200: re-presigns one part URL for the given uploadId', async () => {
    const { jobId, keyPrefix } = await makeJob();
    const key = `${keyPrefix}images/EYE/eye_0001.jpg`;

    const res = await request(app)
      .post(`/jobs/${jobId}/uploads/part-url`)
      .set(auth)
      .send({ key, uploadId: 'existing-upload', partNumber: 5 });

    expect(res.status).toBe(200);
    expect(res.body.url).toContain('X-Amz-Signature');
    expect(res.body.url).toContain('uploadId=existing-upload');
    expect(res.body.url).toContain('partNumber=5');
  });

  it('guards match initiate: foreign key → 400, unknown job → 404', async () => {
    const { jobId } = await makeJob();

    const badKey = await request(app)
      .post(`/jobs/${jobId}/uploads/part-url`)
      .set(auth)
      .send({ key: 'development/elsewhere/x.jpg', uploadId: 'u', partNumber: 1 });
    expect(badKey.status).toBe(400);

    const missing = await request(app)
      .post(`/jobs/${new Types.ObjectId().toHexString()}/uploads/part-url`)
      .set(auth)
      .send({ key: 'development/x/y.jpg', uploadId: 'u', partNumber: 1 });
    expect(missing.status).toBe(404);
  });
});
