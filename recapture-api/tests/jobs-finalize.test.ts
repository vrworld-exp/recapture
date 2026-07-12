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

/** Creates a project + job (default: the full 37 files — 36 images + manifest
 * for both variants; pass a partial count for coverage-floor cases) and moves
 * it to UPLOADING. */
async function makeUploadingJob(
  captureVariant?: 'with_bottom' | 'without_bottom',
  expectedFilesCount = 37
): Promise<string> {
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
      expectedFilesCount,
      ...(captureVariant ? { captureVariant } : {}),
    });
  expect(res.status).toBe(201);
  const jobId = res.body.job.id as string;
  await Job.updateOne({ _id: jobId }, { $set: { state: 'UPLOADING' } });
  return jobId;
}

/**
 * A content-valid capture manifest: `photosPerRing` on each given ring (the
 * with_bottom shape by default — 12 × EYE/TOP/LOW = 36 entries), declared
 * consistently. `flowVariant` is the manifest's optional top-level field;
 * omitted by default like a pre-variant client would.
 */
function validManifestBody(
  photosPerRing = 12,
  rings: string[] = ['EYE', 'TOP', 'LOW'],
  flowVariant?: string
): string {
  const photos = rings.flatMap((ring) =>
    Array.from({ length: photosPerRing }, (_, i) => ({
      photoId: `${ring}_${i}`,
      ringName: ring,
    }))
  );
  return JSON.stringify({
    ...(flowVariant !== undefined ? { flowVariant } : {}),
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
  objectCount = 37,
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
    mockS3({ objectCount: 37 });
    const logSpy = vi.spyOn(console, 'log').mockImplementation(() => {});

    const res = await request(app).post(`/jobs/${jobId}/finalize`).set(auth);

    expect(res.status).toBe(200);
    expect(res.body.status).toBe('success');
    expect(res.body.jobId).toBe(jobId);
    expect(res.body.state).toBe('QUEUED');
    expect(res.body.filesVerified).toBe(37);
    expect(Date.parse(res.body.queuedAt)).not.toBeNaN();
    expect(res.body.idempotentReplay).toBeUndefined();

    const saved = await Job.findById(jobId).exec();
    expect(saved!.state).toBe('QUEUED');
    expect(saved!.queuedAt).toBeInstanceOf(Date);
    expect(saved!.upload!.uploadedFilesCount).toBe(37);

    const queued = logSpy.mock.calls.filter((c) =>
      String(c[0]).includes('[analytics] job_queued')
    );
    expect(queued).toHaveLength(1);
    expect(String(queued[0]![1])).toContain('"files_verified":37');
  });

  it('paginates the S3 listing — a truncated first page never undercounts', async () => {
    const jobId = await makeUploadingJob();
    const sendSpy = mockS3({ objectCount: 37, pageSize: 15 }); // 3 pages

    const res = await request(app).post(`/jobs/${jobId}/finalize`).set(auth);

    expect(res.status).toBe(200);
    expect(res.body.filesVerified).toBe(37);
    const listCalls = sendSpy.mock.calls.filter(
      (c) => (c[0] as { constructor: { name: string } }).constructor.name ===
        'ListObjectsV2Command'
    );
    expect(listCalls).toHaveLength(3);
  });

  it('a matching reportedFilesCount cross-check passes', async () => {
    const jobId = await makeUploadingJob();
    mockS3({ objectCount: 37 });

    const res = await request(app)
      .post(`/jobs/${jobId}/finalize`)
      .set(auth)
      .send({ reportedFilesCount: 37 });

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
    mockS3({ objectCount: 30 });

    const res = await request(app).post(`/jobs/${jobId}/finalize`).set(auth);

    expect(res.status).toBe(422);
    expect(res.body.reason).toBe('count_mismatch');
    expect(res.body.expectedFilesCount).toBe(37);
    expect(res.body.actualFilesCount).toBe(30);
    expect((await Job.findById(jobId).exec())!.state).toBe('UPLOADING');
  });

  it('MORE objects than expected (stray/duplicates) → 422, never silently queued', async () => {
    const jobId = await makeUploadingJob();
    mockS3({ objectCount: 50 });

    const res = await request(app).post(`/jobs/${jobId}/finalize`).set(auth);

    expect(res.status).toBe(422);
    expect(res.body.reason).toBe('count_mismatch');
    expect((await Job.findById(jobId).exec())!.state).toBe('UPLOADING');
  });

  it('reportedFilesCount disagreeing with S3 → 422 (S3 stays the authority)', async () => {
    const jobId = await makeUploadingJob();
    mockS3({ objectCount: 37 });

    const res = await request(app)
      .post(`/jobs/${jobId}/finalize`)
      .set(auth)
      .send({ reportedFilesCount: 36 });

    expect(res.status).toBe(422);
    expect(res.body.reason).toBe('reported_count_mismatch');
    expect((await Job.findById(jobId).exec())!.state).toBe('UPLOADING');
  });

  it('manifest failing ALL content rules → 422 with every finding, in rule order', async () => {
    const jobId = await makeUploadingJob();
    // Declares 10 but has 8 entries; LOW absent entirely; EYE/TOP under the
    // with_bottom coverage floor of 10 (80% of the 12-per-ring total).
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
      { levelId: 'EYE', count: 5, required: 10 },
      { levelId: 'TOP', count: 3, required: 10 },
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

describe('POST /jobs/:jobId/finalize — capture flow variants', () => {
  it("happy path 'with_bottom': 3×12 manifest declaring its variant → QUEUED", async () => {
    const jobId = await makeUploadingJob('with_bottom');
    mockS3({ manifestBody: validManifestBody(12, ['EYE', 'TOP', 'LOW'], 'with_bottom') });

    const res = await request(app).post(`/jobs/${jobId}/finalize`).set(auth);

    expect(res.status).toBe(200);
    expect(res.body.state).toBe('QUEUED');
    expect(res.body.filesVerified).toBe(37);
  });

  it("happy path 'without_bottom': 2×18 manifest + 37 objects → QUEUED; idempotent replay OK", async () => {
    const jobId = await makeUploadingJob('without_bottom');
    mockS3({ manifestBody: validManifestBody(18, ['EYE', 'TOP'], 'without_bottom') });

    const first = await request(app).post(`/jobs/${jobId}/finalize`).set(auth);
    expect(first.status).toBe(200);
    expect(first.body.state).toBe('QUEUED');
    expect(first.body.filesVerified).toBe(37);

    // Replay must not re-verify — drop the S3 mock entirely.
    vi.restoreAllMocks();
    const second = await request(app).post(`/jobs/${jobId}/finalize`).set(auth);
    expect(second.status).toBe(200);
    expect(second.body.idempotentReplay).toBe(true);
    expect(second.body.queuedAt).toBe(first.body.queuedAt);
  });

  it("a 'without_bottom' manifest WITHOUT a flowVariant field is tolerated (pre-variant clients)", async () => {
    const jobId = await makeUploadingJob('without_bottom');
    mockS3({ manifestBody: validManifestBody(18, ['EYE', 'TOP']) }); // no flowVariant

    const res = await request(app).post(`/jobs/${jobId}/finalize`).set(auth);

    expect(res.status).toBe(200);
    expect(res.body.state).toBe('QUEUED');
  });

  it("LOW entries on a 'without_bottom' job → 422 UNEXPECTED_LEVELS, nothing queued", async () => {
    const jobId = await makeUploadingJob('without_bottom');
    // EYE/TOP meet their 18-per-ring floor and the count is declared
    // consistently — the stray LOW ring is the ONLY finding.
    const photos = [
      ...Array.from({ length: 18 }, (_, i) => ({ photoId: `E${i}`, ringName: 'EYE' })),
      ...Array.from({ length: 18 }, (_, i) => ({ photoId: `T${i}`, ringName: 'TOP' })),
      { photoId: 'L0', ringName: 'LOW' },
      { photoId: 'L1', ringName: 'LOW' },
    ];
    mockS3({
      manifestBody: JSON.stringify({
        flowVariant: 'without_bottom',
        summary: { totalPhotos: photos.length },
        photos,
      }),
    });

    const res = await request(app).post(`/jobs/${jobId}/finalize`).set(auth);

    expect(res.status).toBe(422);
    expect(res.body.reason).toBe('manifest_invalid');
    expect(res.body.validationErrors).toHaveLength(1);
    expect(res.body.validationErrors[0].rule).toBe('UNEXPECTED_LEVELS');
    expect(res.body.validationErrors[0].detail).toEqual({ unexpectedLevels: ['LOW'] });
    expect((await Job.findById(jobId).exec())!.state).toBe('UPLOADING');
  });

  it("a variant ring missing entirely (TOP on 'without_bottom') → 422 MISSING_REQUIRED_LEVELS", async () => {
    const jobId = await makeUploadingJob('without_bottom');
    mockS3({ manifestBody: validManifestBody(18, ['EYE'], 'without_bottom') });

    const res = await request(app).post(`/jobs/${jobId}/finalize`).set(auth);

    expect(res.status).toBe(422);
    const missing = res.body.validationErrors.find(
      (e: { rule: string }) => e.rule === 'MISSING_REQUIRED_LEVELS'
    );
    expect(missing.detail).toEqual({ missingLevels: ['TOP'] });
  });

  it('manifest flowVariant disagreeing with the job → 422 FLOW_VARIANT_MISMATCH', async () => {
    const jobId = await makeUploadingJob('without_bottom');
    // Ring shape satisfies without_bottom — ONLY the declared variant is wrong.
    mockS3({ manifestBody: validManifestBody(18, ['EYE', 'TOP'], 'with_bottom') });

    const res = await request(app).post(`/jobs/${jobId}/finalize`).set(auth);

    expect(res.status).toBe(422);
    expect(res.body.validationErrors).toHaveLength(1);
    expect(res.body.validationErrors[0].rule).toBe('FLOW_VARIANT_MISMATCH');
    expect(res.body.validationErrors[0].detail).toEqual({
      declared: 'with_bottom',
      expected: 'without_bottom',
    });
    expect((await Job.findById(jobId).exec())!.state).toBe('UPLOADING');
  });

  it('collect-all: mismatch + unexpected LOW + under-minimum rings reported together, in order', async () => {
    const jobId = await makeUploadingJob('without_bottom');
    // A full with_bottom-shaped manifest (3×12, declared) on a without_bottom
    // job: wrong declared variant, a LOW ring that should not exist, and
    // EYE/TOP below the 15-per-ring coverage floor (80% of 18) — every
    // violated rule in one pass.
    mockS3({ manifestBody: validManifestBody(12, ['EYE', 'TOP', 'LOW'], 'with_bottom') });

    const res = await request(app).post(`/jobs/${jobId}/finalize`).set(auth);

    expect(res.status).toBe(422);
    expect(res.body.validationErrors.map((e: { rule: string }) => e.rule)).toEqual([
      'FLOW_VARIANT_MISMATCH',
      'UNEXPECTED_LEVELS',
      'INSUFFICIENT_PHOTOS_PER_LEVEL',
    ]);
    const insufficient = res.body.validationErrors[2];
    expect(insufficient.detail.levels).toEqual([
      { levelId: 'EYE', count: 12, required: 15 },
      { levelId: 'TOP', count: 12, required: 15 },
    ]);
    expect((await Job.findById(jobId).exec())!.state).toBe('UPLOADING');
  });

  it("happy path PARTIAL 'without_bottom': 16+16 manifest + 33 objects → QUEUED end-to-end", async () => {
    // The real-device case behind the coverage-floor range: both rings
    // finished at 16/18 (≥ the 80% floor of 15), 32 images + manifest = 33.
    const jobId = await makeUploadingJob('without_bottom', 33);
    mockS3({
      manifestBody: validManifestBody(16, ['EYE', 'TOP'], 'without_bottom'),
      objectCount: 33, // S3 matches the STORED expectedFilesCount exactly
    });

    const res = await request(app)
      .post(`/jobs/${jobId}/finalize`)
      .set(auth)
      .send({ reportedFilesCount: 33 });

    expect(res.status).toBe(200);
    expect(res.body.state).toBe('QUEUED');
    expect(res.body.filesVerified).toBe(33);
    const saved = await Job.findById(jobId).exec();
    expect(saved!.state).toBe('QUEUED');
    expect(saved!.upload!.uploadedFilesCount).toBe(33);
  });

  it('a partial job still demands the EXACT stored count from S3 (32 ≠ 33 → 422)', async () => {
    const jobId = await makeUploadingJob('without_bottom', 33);
    mockS3({
      manifestBody: validManifestBody(16, ['EYE', 'TOP'], 'without_bottom'),
      objectCount: 32, // one object short of what the client declared
    });

    const res = await request(app).post(`/jobs/${jobId}/finalize`).set(auth);

    expect(res.status).toBe(422);
    expect(res.body.reason).toBe('count_mismatch');
    expect(res.body.expectedFilesCount).toBe(33);
    expect(res.body.actualFilesCount).toBe(32);
    expect((await Job.findById(jobId).exec())!.state).toBe('UPLOADING');
  });

  it("a ring below the coverage floor (14/18) → 422 INSUFFICIENT_PHOTOS_PER_LEVEL", async () => {
    // 14 + 17 images + manifest = 32 files — the TOTAL is inside the create
    // range (31–37), but the EYE ring sits below the 15-per-ring coverage
    // floor. Manifest declared consistently + S3 count matching, so only the
    // per-ring floor rule fires.
    const jobId = await makeUploadingJob('without_bottom', 32);
    const photos = [
      ...Array.from({ length: 14 }, (_, i) => ({ photoId: `E${i}`, ringName: 'EYE' })),
      ...Array.from({ length: 17 }, (_, i) => ({ photoId: `T${i}`, ringName: 'TOP' })),
    ];
    mockS3({
      manifestBody: JSON.stringify({
        flowVariant: 'without_bottom',
        summary: { totalPhotos: photos.length },
        photos,
      }),
      objectCount: 32,
    });

    const res = await request(app).post(`/jobs/${jobId}/finalize`).set(auth);

    expect(res.status).toBe(422);
    expect(res.body.reason).toBe('manifest_invalid');
    expect(res.body.validationErrors).toHaveLength(1);
    expect(res.body.validationErrors[0].rule).toBe('INSUFFICIENT_PHOTOS_PER_LEVEL');
    expect(res.body.validationErrors[0].detail.levels).toEqual([
      { levelId: 'EYE', count: 14, required: 15 },
    ]);
    expect((await Job.findById(jobId).exec())!.state).toBe('UPLOADING');
  });

  it("a ring above the variant's per-ring total (19/18) → 422 EXCESS_PHOTOS_PER_LEVEL", async () => {
    // 19 + 15 images + manifest = 35 files — in the create range, but the EYE
    // ring exceeds the 18-per-ring ceiling. The exact-total check no longer
    // catches this, so the explicit per-ring ceiling rule must.
    const jobId = await makeUploadingJob('without_bottom', 35);
    const photos = [
      ...Array.from({ length: 19 }, (_, i) => ({ photoId: `E${i}`, ringName: 'EYE' })),
      ...Array.from({ length: 15 }, (_, i) => ({ photoId: `T${i}`, ringName: 'TOP' })),
    ];
    mockS3({
      manifestBody: JSON.stringify({
        flowVariant: 'without_bottom',
        summary: { totalPhotos: photos.length },
        photos,
      }),
      objectCount: 35,
    });

    const res = await request(app).post(`/jobs/${jobId}/finalize`).set(auth);

    expect(res.status).toBe(422);
    expect(res.body.reason).toBe('manifest_invalid');
    expect(res.body.validationErrors).toHaveLength(1);
    expect(res.body.validationErrors[0].rule).toBe('EXCESS_PHOTOS_PER_LEVEL');
    expect(res.body.validationErrors[0].detail.levels).toEqual([
      { levelId: 'EYE', count: 19, allowed: 18 },
    ]);
    expect((await Job.findById(jobId).exec())!.state).toBe('UPLOADING');
  });
});

describe('POST /jobs/:jobId/finalize — idempotency + state guards', () => {
  it('re-finalizing a QUEUED job replays without re-verifying or re-enqueuing', async () => {
    const jobId = await makeUploadingJob();
    mockS3({ objectCount: 37 });
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
    expect(second.body.filesVerified).toBe(37);

    // No second job_queued across both calls.
    const secondEvents = logSpy2.mock.calls.filter((c) =>
      String(c[0]).includes('[analytics] job_queued')
    ).length;
    expect(firstEvents).toBe(1);
    expect(secondEvents).toBe(0);
  });

  it('concurrent finalizes → both 200, exactly one enqueue/event', async () => {
    const jobId = await makeUploadingJob();
    mockS3({ objectCount: 37 });
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

describe('POST /jobs/:jobId/finalize — rejection side-effects: zero enqueue + boundaries', () => {
  // The QUEUED flip IS the enqueue in this codebase; the job_queued analytics
  // emission is its observable signal. Every rejection below asserts BOTH zero
  // emissions AND no state advance — a 4xx that still enqueued is the exact
  // failure this block guards against.
  const queuedEvents = (logSpy: { mock: { calls: unknown[][] } }) =>
    logSpy.mock.calls.filter((c) => String(c[0]).includes('[analytics] job_queued'));

  it('one object short of expected (N-1) → 422, zero job_queued, state unchanged', async () => {
    const jobId = await makeUploadingJob();
    // Boundary derives from the seeded job record, not a free-standing literal.
    const expected = (await Job.findById(jobId).exec())!.upload!.expectedFilesCount;
    mockS3({ objectCount: expected - 1 });
    const logSpy = vi.spyOn(console, 'log').mockImplementation(() => {});

    const res = await request(app).post(`/jobs/${jobId}/finalize`).set(auth);

    expect(res.status).toBe(422);
    expect(res.body.reason).toBe('count_mismatch');
    expect(res.body.expectedFilesCount).toBe(expected);
    expect(res.body.actualFilesCount).toBe(expected - 1);
    expect(queuedEvents(logSpy)).toHaveLength(0);
    const saved = await Job.findById(jobId).exec();
    expect(saved!.state).toBe('UPLOADING');
    expect(saved!.queuedAt).toBeUndefined();
  });

  it('empty bundle (zero objects) → 422, zero job_queued, state unchanged', async () => {
    const jobId = await makeUploadingJob();
    mockS3({ objectCount: 0 });
    const logSpy = vi.spyOn(console, 'log').mockImplementation(() => {});

    const res = await request(app).post(`/jobs/${jobId}/finalize`).set(auth);

    expect(res.status).toBe(422);
    expect(res.body.reason).toBe('count_mismatch');
    expect(res.body.actualFilesCount).toBe(0);
    expect(queuedEvents(logSpy)).toHaveLength(0);
    expect((await Job.findById(jobId).exec())!.state).toBe('UPLOADING');
  });

  it('every rejection reason → zero job_queued and no state advance', async () => {
    const cases: { mock: Parameters<typeof mockS3>[0]; body?: { reportedFilesCount: number } }[] = [
      { mock: { manifestExists: false } }, // manifest_missing
      { mock: { manifestBody: '{not json' } }, // manifest_invalid (unreadable)
      { mock: { manifestBody: validManifestBody(5) } }, // manifest_invalid (content rules)
      { mock: { objectCount: 50 } }, // count_mismatch (over-count)
      { mock: {}, body: { reportedFilesCount: 36 } }, // reported_count_mismatch
    ];
    for (const c of cases) {
      const jobId = await makeUploadingJob();
      mockS3(c.mock);
      const logSpy = vi.spyOn(console, 'log').mockImplementation(() => {});

      let req = request(app).post(`/jobs/${jobId}/finalize`).set(auth);
      if (c.body) req = req.send(c.body);
      const res = await req;

      expect(res.status).toBe(422);
      expect(res.body.code).toBe('VERIFICATION_FAILED');
      expect(queuedEvents(logSpy)).toHaveLength(0);
      const saved = await Job.findById(jobId).exec();
      expect(saved!.state).toBe('UPLOADING');
      expect(saved!.queuedAt).toBeUndefined();
      vi.restoreAllMocks();
    }
  });

  it('concurrent finalizes on an incomplete bundle → both rejected, zero job_queued', async () => {
    const jobId = await makeUploadingJob();
    mockS3({ objectCount: 30 });
    const logSpy = vi.spyOn(console, 'log').mockImplementation(() => {});

    const [a, b] = await Promise.all([
      request(app).post(`/jobs/${jobId}/finalize`).set(auth),
      request(app).post(`/jobs/${jobId}/finalize`).set(auth),
    ]);

    expect(a.status).toBe(422);
    expect(b.status).toBe(422);
    expect(queuedEvents(logSpy)).toHaveLength(0);
    const saved = await Job.findById(jobId).exec();
    expect(saved!.state).toBe('UPLOADING');
    expect(saved!.queuedAt).toBeUndefined();
  });

  it('a rejected job re-finalizes successfully once the upload completes', async () => {
    const jobId = await makeUploadingJob();
    const expected = (await Job.findById(jobId).exec())!.upload!.expectedFilesCount;
    mockS3({ objectCount: expected - 1 });

    const rejected = await request(app).post(`/jobs/${jobId}/finalize`).set(auth);
    expect(rejected.status).toBe(422);
    expect((await Job.findById(jobId).exec())!.state).toBe('UPLOADING');

    // The missing object arrives; the same job finalizes cleanly — exactly one
    // enqueue, and only on the successful attempt.
    vi.restoreAllMocks();
    mockS3({ objectCount: expected });
    const logSpy = vi.spyOn(console, 'log').mockImplementation(() => {});

    const accepted = await request(app).post(`/jobs/${jobId}/finalize`).set(auth);

    expect(accepted.status).toBe(200);
    expect(accepted.body.state).toBe('QUEUED');
    expect(accepted.body.idempotentReplay).toBeUndefined();
    expect(queuedEvents(logSpy)).toHaveLength(1);
    const saved = await Job.findById(jobId).exec();
    expect(saved!.state).toBe('QUEUED');
    expect(saved!.queuedAt).toBeInstanceOf(Date);
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
