// tests/jobs-uploads-complete.test.ts
//
// POST /jobs/:jobId/uploads/complete — server-side CompleteMultipartUpload for
// ONE file (no presigned complete exists; the SDK call needs credentials).
// Hermetic: in-memory MongoDB; the S3 network call is spied on the shared
// client. Guard failures must never reach S3 — same guard family as initiate.
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

/** Creates a project + job through the real endpoint; returns jobId + keyPrefix. */
async function makeJob(
  captureVariant?: 'with_bottom' | 'without_bottom'
): Promise<{ jobId: string; keyPrefix: string }> {
  const p = await Project.create({
    userId: new Types.ObjectId(userId),
    name: 'Brass Vase',
    objectSize: 'MEDIUM',
    mode: 'GUIDED',
  });
  const res = await request(app)
    .post('/jobs')
    .set(auth)
    .send({
      projectId: p.id,
      objectSize: 'medium',
      expectedFilesCount: 49,
      ...(captureVariant ? { captureVariant } : {}),
    });
  expect(res.status).toBe(201);
  return { jobId: res.body.job.id, keyPrefix: res.body.uploadPlan.keyPrefix };
}

/** Spies the shared client's send. Pass `null` to simulate S3 responding
 * WITHOUT an ETag. */
function mockS3Complete(etag: string | null = '"composite-etag"') {
  return vi
    .spyOn(s3Client, 'send')
    .mockResolvedValue((etag === null ? {} : { ETag: etag }) as never);
}

describe('POST /jobs/:jobId/uploads/complete', () => {
  it('200: sends CompleteMultipartUploadCommand with the exact Bucket/Key/UploadId/Parts', async () => {
    const { jobId, keyPrefix } = await makeJob();
    const sendSpy = mockS3Complete();
    const key = `${keyPrefix}images/EYE/eye_0001.jpg`;

    const res = await request(app)
      .post(`/jobs/${jobId}/uploads/complete`)
      .set(auth)
      .send({
        key,
        uploadId: 'existing-upload',
        parts: [
          { partNumber: 1, etag: '"etag-1"' },
          { partNumber: 2, etag: '"etag-2"' },
        ],
      });

    expect(res.status).toBe(200);
    expect(res.body).toEqual({ status: 'success', key, etag: '"composite-etag"' });

    const completeCalls = sendSpy.mock.calls.filter(
      (c) =>
        (c[0] as { constructor: { name: string } }).constructor.name ===
        'CompleteMultipartUploadCommand'
    );
    expect(completeCalls).toHaveLength(1);
    expect(
      (completeCalls[0]![0] as { input: Record<string, unknown> }).input
    ).toEqual({
      Bucket: 'recapture-test-raw',
      Key: key,
      UploadId: 'existing-upload',
      MultipartUpload: {
        Parts: [
          { PartNumber: 1, ETag: '"etag-1"' },
          { PartNumber: 2, ETag: '"etag-2"' },
        ],
      },
    });
  });

  it('guard failures never call S3: foreign key 400, wrong state 409, expired plan 410, unknown job 404', async () => {
    const { jobId, keyPrefix } = await makeJob();
    const sendSpy = mockS3Complete();
    const goodBody = {
      key: `${keyPrefix}images/EYE/eye_0001.jpg`,
      uploadId: 'u',
      parts: [{ partNumber: 1, etag: '"e"' }],
    };

    // Foreign key (outside the job's prefix) → 400.
    const foreignKey = await request(app)
      .post(`/jobs/${jobId}/uploads/complete`)
      .set(auth)
      .send({ ...goodBody, key: 'development/other-user/steal.jpg' });
    expect(foreignKey.status).toBe(400);
    expect(foreignKey.body.fields).toHaveProperty('key');

    // Unknown job → 404 (not-owned indistinguishable from missing).
    const missing = await request(app)
      .post(`/jobs/${new Types.ObjectId().toHexString()}/uploads/complete`)
      .set(auth)
      .send(goodBody);
    expect(missing.status).toBe(404);

    // Expired plan window → 410.
    await Job.collection.updateOne(
      { _id: new Types.ObjectId(jobId) },
      { $set: { createdAt: new Date(Date.now() - (env.UPLOAD_PLAN_TTL_SECONDS + 60) * 1000) } }
    );
    const expired = await request(app)
      .post(`/jobs/${jobId}/uploads/complete`)
      .set(auth)
      .send(goodBody);
    expect(expired.status).toBe(410);
    expect(expired.body.code).toBe('PLAN_EXPIRED');

    // Non-uploadable state → 409 (fresh job to escape the aged window).
    const second = await makeJob();
    await Job.updateOne({ _id: second.jobId }, { $set: { state: 'COMPLETED' } });
    const wrongState = await request(app)
      .post(`/jobs/${second.jobId}/uploads/complete`)
      .set(auth)
      .send({ ...goodBody, key: `${second.keyPrefix}images/EYE/eye_0001.jpg` });
    expect(wrongState.status).toBe(409);
    expect(wrongState.body.code).toBe('JOB_NOT_UPLOADABLE');

    expect(sendSpy).not.toHaveBeenCalled();
  });

  it("variant containment: a LOW key on a 'without_bottom' job → 400, S3 never called", async () => {
    const { jobId, keyPrefix } = await makeJob('without_bottom');
    const sendSpy = mockS3Complete();

    const res = await request(app)
      .post(`/jobs/${jobId}/uploads/complete`)
      .set(auth)
      .send({
        key: `${keyPrefix}images/LOW/low_0001.jpg`,
        uploadId: 'u',
        parts: [{ partNumber: 1, etag: '"e"' }],
      });

    expect(res.status).toBe(400);
    expect(sendSpy).not.toHaveBeenCalled();
  });

  it('malformed body → 400, S3 never called', async () => {
    const { jobId, keyPrefix } = await makeJob();
    const sendSpy = mockS3Complete();
    const key = `${keyPrefix}images/EYE/eye_0001.jpg`;

    for (const body of [
      { key, uploadId: 'u', parts: [] }, // empty parts
      { key, uploadId: 'u', parts: [{ partNumber: 0, etag: '"e"' }] }, // partNumber < 1
      { key, uploadId: 'u', parts: [{ partNumber: 1, etag: '' }] }, // empty etag
      { key, parts: [{ partNumber: 1, etag: '"e"' }] }, // missing uploadId
      { key, uploadId: 'u', parts: [{ partNumber: 1, etag: '"e"', extra: 1 }] }, // strict
      { key, uploadId: 'u', parts: [{ partNumber: 1, etag: '"e"' }], extra: 1 }, // strict
    ]) {
      const res = await request(app)
        .post(`/jobs/${jobId}/uploads/complete`)
        .set(auth)
        .send(body);
      expect(res.status, JSON.stringify(body)).toBe(400);
    }
    expect(sendSpy).not.toHaveBeenCalled();
  });

  it('401 without a token; S3 error (rejected send) → 500 via the error handler', async () => {
    const { jobId, keyPrefix } = await makeJob();
    const body = {
      key: `${keyPrefix}images/EYE/eye_0001.jpg`,
      uploadId: 'stale-upload',
      parts: [{ partNumber: 1, etag: '"e"' }],
    };

    expect(
      (await request(app).post(`/jobs/${jobId}/uploads/complete`).send(body)).status
    ).toBe(401);

    // A stale/foreign uploadId is S3's error to raise — surfaced, not pre-validated.
    vi.spyOn(s3Client, 'send').mockRejectedValue(new Error('NoSuchUpload') as never);
    vi.spyOn(console, 'error').mockImplementation(() => {});
    const res = await request(app)
      .post(`/jobs/${jobId}/uploads/complete`)
      .set(auth)
      .send(body);
    expect(res.status).toBe(500);
  });

  it('S3 responding without an ETag → 500 via the error handler', async () => {
    const { jobId, keyPrefix } = await makeJob();
    mockS3Complete(null);
    vi.spyOn(console, 'error').mockImplementation(() => {});

    const res = await request(app)
      .post(`/jobs/${jobId}/uploads/complete`)
      .set(auth)
      .send({
        key: `${keyPrefix}images/EYE/eye_0001.jpg`,
        uploadId: 'u',
        parts: [{ partNumber: 1, etag: '"e"' }],
      });
    expect(res.status).toBe(500);
  });
});
