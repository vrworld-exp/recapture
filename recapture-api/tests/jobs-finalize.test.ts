// tests/jobs-finalize.test.ts
//
// POST /jobs/:jobId/finalize — the commit gate: verify manifest + S3 object
// count, then the atomic QUEUED flip (which IS the enqueue in this codebase —
// the worker polls QUEUED jobs). Hermetic: in-memory MongoDB; the S3 HEAD/LIST
// calls are scripted on the shared client (with real pagination semantics).
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

/** Creates a project + job (expected 73 files) and moves it to UPLOADING. */
async function makeUploadingJob(): Promise<string> {
  const p = await Project.create({
    userId: new Types.ObjectId(userId),
    name: 'Brass Vase',
    objectSize: 'MEDIUM',
    mode: 'GUIDED',
  });
  const res = await request(app)
    .post('/jobs')
    .set(auth)
    .send({ projectId: p.id, objectSize: 'medium', expectedFilesCount: 73 });
  expect(res.status).toBe(201);
  const jobId = res.body.job.id as string;
  await Job.updateOne({ _id: jobId }, { $set: { state: 'UPLOADING' } });
  return jobId;
}

/**
 * A content-valid capture manifest for a MEDIUM job: 24 photos per ring
 * (the server minimum) across EYE/TOP/LOW = 72 entries, declared consistently.
 */
function validManifestBody(photosPerRing = 24): string {
  const photos = ['EYE', 'TOP', 'LOW'].flatMap((ring) =>
    Array.from({ length: photosPerRing }, (_, i) => ({
      photoId: `${ring}_${i}`,
      ringName: ring,
    }))
  );
  return JSON.stringify({
    summary: { totalPhotos: photos.length, warningsCount: 0, overallComplete: true },
    photos,
  });
}

/**
 * Scripts the shared S3 client: GET answers the manifest existence + content
 * check; LIST pages through [objectCount] keys in [pageSize] chunks (real
 * ContinuationToken semantics, so pagination is genuinely exercised).
 */
function mockS3({
  manifestExists = true,
  manifestBody = validManifestBody(),
  objectCount = 73,
  pageSize = 1000,
  listError = false,
} = {}) {
  const impl = async (cmd: { constructor: { name: string }; input: Record<string, unknown> }) => {
    switch (cmd.constructor.name) {
      case 'GetObjectCommand': {
        if (!manifestExists) {
          throw Object.assign(new Error('NotFound'), {
            name: 'NotFound',
            $metadata: { httpStatusCode: 404 },
          });
        }
        return { Body: { transformToString: async () => manifestBody } };
      }
      case 'ListObjectsV2Command': {
        if (listError) throw new Error('S3 unavailable');
        const prefix = cmd.input.Prefix as string;
        const start = cmd.input.ContinuationToken ? Number(cmd.input.ContinuationToken) : 0;
        const end = Math.min(start + pageSize, objectCount);
        return {
          Contents: Array.from({ length: end - start }, (_, i) => ({
            Key: `${prefix}f_${start + i}.jpg`,
          })),
          IsTruncated: end < objectCount,
          ...(end < objectCount ? { NextContinuationToken: String(end) } : {}),
        };
      }
      default:
        throw new Error(`unexpected S3 command: ${cmd.constructor.name}`);
    }
  };
  return vi.spyOn(s3Client, 'send').mockImplementation(impl as never);
}

describe('POST /jobs/:jobId/finalize — happy path', () => {
  it('200: verifies manifest + count, flips to QUEUED (the enqueue), records queuedAt', async () => {
    const jobId = await makeUploadingJob();
    mockS3({ objectCount: 73 });
    const logSpy = vi.spyOn(console, 'log').mockImplementation(() => {});

    const res = await request(app).post(`/jobs/${jobId}/finalize`).set(auth);

    expect(res.status).toBe(200);
    expect(res.body.status).toBe('success');
    expect(res.body.jobId).toBe(jobId);
    expect(res.body.state).toBe('QUEUED');
    expect(res.body.filesVerified).toBe(73);
    expect(Date.parse(res.body.queuedAt)).not.toBeNaN();
    expect(res.body.idempotentReplay).toBeUndefined();

    const saved = await Job.findById(jobId).exec();
    expect(saved!.state).toBe('QUEUED');
    expect(saved!.queuedAt).toBeInstanceOf(Date);
    expect(saved!.upload!.uploadedFilesCount).toBe(73);

    const queued = logSpy.mock.calls.filter((c) =>
      String(c[0]).includes('[analytics] job_queued')
    );
    expect(queued).toHaveLength(1);
    expect(String(queued[0]![1])).toContain('"files_verified":73');
  });

  it('paginates the S3 listing — a truncated first page never undercounts', async () => {
    const jobId = await makeUploadingJob();
    const sendSpy = mockS3({ objectCount: 73, pageSize: 30 }); // 3 pages

    const res = await request(app).post(`/jobs/${jobId}/finalize`).set(auth);

    expect(res.status).toBe(200);
    expect(res.body.filesVerified).toBe(73);
    const listCalls = sendSpy.mock.calls.filter(
      (c) => (c[0] as { constructor: { name: string } }).constructor.name ===
        'ListObjectsV2Command'
    );
    expect(listCalls).toHaveLength(3);
  });

  it('a matching reportedFilesCount cross-check passes', async () => {
    const jobId = await makeUploadingJob();
    mockS3({ objectCount: 73 });

    const res = await request(app)
      .post(`/jobs/${jobId}/finalize`)
      .set(auth)
      .send({ reportedFilesCount: 73 });

    expect(res.status).toBe(200);
  });
});

describe('POST /jobs/:jobId/finalize — verification failures (422, no state change)', () => {
  it('missing manifest → 422 manifest_missing, state unchanged, nothing queued', async () => {
    const jobId = await makeUploadingJob();
    mockS3({ manifestExists: false });

    const res = await request(app).post(`/jobs/${jobId}/finalize`).set(auth);

    expect(res.status).toBe(422);
    expect(res.body.code).toBe('VERIFICATION_FAILED');
    expect(res.body.reason).toBe('manifest_missing');
    expect((await Job.findById(jobId).exec())!.state).toBe('UPLOADING');
  });

  it('fewer objects than expected (incomplete upload) → 422 with both counts', async () => {
    const jobId = await makeUploadingJob();
    mockS3({ objectCount: 60 });

    const res = await request(app).post(`/jobs/${jobId}/finalize`).set(auth);

    expect(res.status).toBe(422);
    expect(res.body.reason).toBe('count_mismatch');
    expect(res.body.expectedFilesCount).toBe(73);
    expect(res.body.actualFilesCount).toBe(60);
    expect((await Job.findById(jobId).exec())!.state).toBe('UPLOADING');
  });

  it('MORE objects than expected (stray/duplicates) → 422, never silently queued', async () => {
    const jobId = await makeUploadingJob();
    mockS3({ objectCount: 80 });

    const res = await request(app).post(`/jobs/${jobId}/finalize`).set(auth);

    expect(res.status).toBe(422);
    expect(res.body.reason).toBe('count_mismatch');
    expect((await Job.findById(jobId).exec())!.state).toBe('UPLOADING');
  });

  it('reportedFilesCount disagreeing with S3 → 422 (S3 stays the authority)', async () => {
    const jobId = await makeUploadingJob();
    mockS3({ objectCount: 73 });

    const res = await request(app)
      .post(`/jobs/${jobId}/finalize`)
      .set(auth)
      .send({ reportedFilesCount: 72 });

    expect(res.status).toBe(422);
    expect(res.body.reason).toBe('reported_count_mismatch');
    expect((await Job.findById(jobId).exec())!.state).toBe('UPLOADING');
  });

  it('manifest failing ALL content rules → 422 with every finding, in rule order', async () => {
    const jobId = await makeUploadingJob();
    // Declares 10 but has 8 entries; LOW absent entirely; EYE/TOP under the
    // MEDIUM minimum of 24 photos each.
    const photos = [
      ...Array.from({ length: 5 }, (_, i) => ({ photoId: `E${i}`, ringName: 'EYE' })),
      ...Array.from({ length: 3 }, (_, i) => ({ photoId: `T${i}`, ringName: 'TOP' })),
    ];
    mockS3({
      manifestBody: JSON.stringify({ summary: { totalPhotos: 10 }, photos }),
    });

    const res = await request(app).post(`/jobs/${jobId}/finalize`).set(auth);

    expect(res.status).toBe(422);
    expect(res.body.code).toBe('VERIFICATION_FAILED');
    expect(res.body.reason).toBe('manifest_invalid');
    // All broken rules in one pass, stable order preserved.
    expect(
      res.body.validationErrors.map((e: { rule: string }) => e.rule)
    ).toEqual([
      'FILE_COUNT_MISMATCH',
      'MISSING_REQUIRED_LEVELS',
      'INSUFFICIENT_PHOTOS_PER_LEVEL',
    ]);
    expect(res.body.validationErrors[0].detail).toEqual({ declared: 10, actual: 8 });
    expect(res.body.validationErrors[1].detail).toEqual({ missingLevels: ['LOW'] });
    expect(res.body.validationErrors[2].detail.levels).toEqual([
      { levelId: 'EYE', count: 5, required: 24 },
      { levelId: 'TOP', count: 3, required: 24 },
    ]);
    expect((await Job.findById(jobId).exec())!.state).toBe('UPLOADING'); // untouched
  });

  it('unparseable manifest JSON → 422 MANIFEST_UNREADABLE, never a 500', async () => {
    const jobId = await makeUploadingJob();
    mockS3({ manifestBody: '{not json' });

    const res = await request(app).post(`/jobs/${jobId}/finalize`).set(auth);

    expect(res.status).toBe(422);
    expect(res.body.reason).toBe('manifest_invalid');
    expect(res.body.validationErrors).toHaveLength(1);
    expect(res.body.validationErrors[0].rule).toBe('MANIFEST_UNREADABLE');
    expect((await Job.findById(jobId).exec())!.state).toBe('UPLOADING');
  });

  it('S3 listing failure → 500, state untouched (retry can re-finalize)', async () => {
    const jobId = await makeUploadingJob();
    mockS3({ listError: true });
    vi.spyOn(console, 'error').mockImplementation(() => {});

    const res = await request(app).post(`/jobs/${jobId}/finalize`).set(auth);

    expect(res.status).toBe(500);
    expect((await Job.findById(jobId).exec())!.state).toBe('UPLOADING');
  });
});

describe('POST /jobs/:jobId/finalize — idempotency + state guards', () => {
  it('re-finalizing a QUEUED job replays without re-verifying or re-enqueuing', async () => {
    const jobId = await makeUploadingJob();
    mockS3({ objectCount: 73 });
    const logSpy = vi.spyOn(console, 'log').mockImplementation(() => {});

    const first = await request(app).post(`/jobs/${jobId}/finalize`).set(auth);
    // Snapshot BEFORE restoring — mockRestore clears the spy's call history.
    const firstEvents = logSpy.mock.calls.filter((c) =>
      String(c[0]).includes('[analytics] job_queued')
    ).length;
    vi.restoreAllMocks(); // drop the S3 mock — a replay must not touch S3
    const logSpy2 = vi.spyOn(console, 'log').mockImplementation(() => {});
    const second = await request(app).post(`/jobs/${jobId}/finalize`).set(auth);

    expect(first.status).toBe(200);
    expect(second.status).toBe(200);
    expect(second.body.idempotentReplay).toBe(true);
    expect(second.body.queuedAt).toBe(first.body.queuedAt); // original enqueue time
    expect(second.body.filesVerified).toBe(73);

    // No second job_queued across both calls.
    const secondEvents = logSpy2.mock.calls.filter((c) =>
      String(c[0]).includes('[analytics] job_queued')
    ).length;
    expect(firstEvents).toBe(1);
    expect(secondEvents).toBe(0);
  });

  it('concurrent finalizes → both 200, exactly one enqueue/event', async () => {
    const jobId = await makeUploadingJob();
    mockS3({ objectCount: 73 });
    const logSpy = vi.spyOn(console, 'log').mockImplementation(() => {});

    const [a, b] = await Promise.all([
      request(app).post(`/jobs/${jobId}/finalize`).set(auth),
      request(app).post(`/jobs/${jobId}/finalize`).set(auth),
    ]);

    expect(a.status).toBe(200);
    expect(b.status).toBe(200);
    expect((await Job.findById(jobId).exec())!.state).toBe('QUEUED');
    const events = logSpy.mock.calls.filter((c) =>
      String(c[0]).includes('[analytics] job_queued')
    );
    expect(events).toHaveLength(1); // exactly-once enqueue
  });

  it('a job past finalizing (PROCESSING) → 409, no re-enqueue', async () => {
    const jobId = await makeUploadingJob();
    await Job.updateOne({ _id: jobId }, { $set: { state: 'PROCESSING' } });
    mockS3();

    const res = await request(app).post(`/jobs/${jobId}/finalize`).set(auth);

    expect(res.status).toBe(409);
    expect(res.body.code).toBe('JOB_NOT_FINALIZABLE');
    expect((await Job.findById(jobId).exec())!.state).toBe('PROCESSING');
  });
});

describe('POST /jobs/:jobId/finalize — request validation + auth', () => {
  it('401 without a token; 400 malformed jobId; 404 unknown/foreign job', async () => {
    const jobId = await makeUploadingJob();
    mockS3();

    expect((await request(app).post(`/jobs/${jobId}/finalize`)).status).toBe(401);
    expect((await request(app).post('/jobs/not-hex/finalize').set(auth)).status).toBe(400);
    expect(
      (await request(app).post(`/jobs/${new Types.ObjectId().toHexString()}/finalize`).set(auth))
        .status
    ).toBe(404);

    const stranger = new Types.ObjectId().toHexString();
    const strangerAuth = {
      Authorization: `Bearer ${jwt.sign(
        { userId: stranger, authUid: `test|${stranger}` },
        env.JWT_SECRET,
        { expiresIn: '15m' }
      )}`,
    };
    const foreign = await request(app).post(`/jobs/${jobId}/finalize`).set(strangerAuth);
    expect(foreign.status).toBe(404); // not-owned indistinguishable from missing
    expect((await Job.findById(jobId).exec())!.state).toBe('UPLOADING'); // no side effects
  });

  it('unknown body fields and bad reportedFilesCount → 400', async () => {
    const jobId = await makeUploadingJob();
    mockS3();

    for (const body of [
      { extra: true },
      { reportedFilesCount: 0 },
      { reportedFilesCount: 7.5 },
    ]) {
      const res = await request(app).post(`/jobs/${jobId}/finalize`).set(auth).send(body);
      expect(res.status).toBe(400);
    }
    expect((await Job.findById(jobId).exec())!.state).toBe('UPLOADING');
  });
});
