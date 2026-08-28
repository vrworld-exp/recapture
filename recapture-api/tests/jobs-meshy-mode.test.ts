// tests/jobs-meshy-mode.test.ts
//
// Meshy capture mode end-to-end through the job endpoints: create with
// `captureMode: 'meshy'`, finalize the single EYE ring (5 or 6 — the ring may
// finish one slot short), and prove the per-ring floor bites (a 4-photo EYE ring
// is a rejection) and that TOP/LOW — which Meshy no longer captures — are
// rejected as UNEXPECTED_LEVELS.
//
// The legacy-client case lives here too: a request that never mentions
// captureMode must still be a full capture, because that is every client
// currently in the field.
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

async function makeProject(): Promise<string> {
  const p = await Project.create({
    userId: new Types.ObjectId(userId),
    name: 'Small Figurine',
    objectSize: 'MEDIUM',
    mode: 'GUIDED',
  });
  return p.id as string;
}

/** Creates a job through the real route, so the schema default for an omitted
 * captureMode is exercised rather than bypassed. */
async function createJob(body: Record<string, unknown>) {
  return request(app)
    .post('/jobs')
    .set(auth)
    .send({ projectId: await makeProject(), objectSize: 'medium', ...body });
}

/** A Meshy manifest: per-ring counts (default = the single legal EYE ring of 6).
 * Overriding the counts lets a bundle be made wrong — too few on EYE, or with
 * TOP/LOW rings Meshy no longer captures. */
function meshyManifest(
  counts: Record<string, number> = { EYE: 6 },
  extra: Record<string, unknown> = {}
): string {
  const photos = Object.entries(counts).flatMap(([ring, n]) =>
    Array.from({ length: n }, (_, i) => ({ photoId: `${ring}_${i}`, ringName: ring }))
  );
  return JSON.stringify({
    ...extra,
    summary: { totalPhotos: photos.length, warningsCount: 0, overallComplete: true },
    photos,
  });
}

function mockS3(manifestBody: string, objectCount: number) {
  const impl = async (cmd: { constructor: { name: string }; input: Record<string, unknown> }) => {
    switch (cmd.constructor.name) {
      case 'GetObjectCommand':
        return { Body: { transformToString: async () => manifestBody } };
      case 'ListObjectsV2Command': {
        const prefix = cmd.input.Prefix as string;
        return {
          Contents: Array.from({ length: objectCount }, (_, i) => ({
            Key: `${prefix}f_${i}.jpg`,
          })),
          IsTruncated: false,
        };
      }
      default:
        throw new Error(`unexpected S3 command: ${cmd.constructor.name}`);
    }
  };
  return vi.spyOn(s3Client, 'send').mockImplementation(impl as never);
}

async function finalizeWith(
  jobId: string,
  manifestBody: string,
  objectCount: number
) {
  mockS3(manifestBody, objectCount);
  return request(app).post(`/jobs/${jobId}/finalize`).set(auth);
}

describe('POST /jobs — captureMode on the wire', () => {
  it('accepts meshy and persists it, with the 7-file count (6 + manifest)', async () => {
    const res = await createJob({ captureMode: 'meshy', expectedFilesCount: 7 });

    expect(res.status).toBe(201);
    const saved = await Job.findById(res.body.job.id).exec();
    expect(saved!.captureMode).toBe('meshy');
    expect(saved!.captureVariant).toBe('with_bottom');
  });

  it('accepts the one-slot-short count of 6 (5 photos + manifest)', async () => {
    // The ring may finish at 5 of 6, so 6 files (5 + manifest) is now in range.
    const res = await createJob({ captureMode: 'meshy', expectedFilesCount: 6 });

    expect(res.status).toBe(201);
    expect((await Job.findById(res.body.job.id).exec())!.captureMode).toBe('meshy');
  });

  it('rejects a count below the one-slot-short floor (5 = 4 photos + manifest)', async () => {
    const res = await createJob({ captureMode: 'meshy', expectedFilesCount: 5 });

    expect(res.status).toBe(400);
    expect(res.body.code).toBe('INVALID_REQUEST');
    expect(res.body.message).toContain('meshy');
  });

  it('a client that never sends captureMode is a FULL capture', async () => {
    // Every client in the field today. The default must be applied at the same
    // layer the variant default is, not inferred later from the counts.
    const res = await createJob({ expectedFilesCount: 49 });

    expect(res.status).toBe(201);
    const saved = await Job.findById(res.body.job.id).exec();
    expect(saved!.captureMode).toBe('full');
  });

  it('rejects a full-sized count under meshy mode', async () => {
    // 49 files is a perfectly valid FULL capture and a nonsensical Meshy one —
    // the range has to come from the mode, not from the variant alone.
    const res = await createJob({ captureMode: 'meshy', expectedFilesCount: 49 });

    expect(res.status).toBe(400);
    expect(res.body.code).toBe('INVALID_REQUEST');
    expect(res.body.message).toContain('meshy');
  });

  it('rejects the old 6/2/2 Meshy count (11) — only 6–7 is legal now', async () => {
    // A client still shaped to the retired 6/2/2 capture would send 11; the
    // single-ring reshape makes only 6 or 7 an accepted Meshy count.
    const res = await createJob({ captureMode: 'meshy', expectedFilesCount: 11 });

    expect(res.status).toBe(400);
    expect(res.body.code).toBe('INVALID_REQUEST');
    expect(res.body.message).toContain('meshy');
  });

  it('rejects a meshy-sized count under full mode', async () => {
    const res = await createJob({ captureMode: 'full', expectedFilesCount: 7 });

    expect(res.status).toBe(400);
    expect(res.body.code).toBe('INVALID_REQUEST');
    expect(res.body.message).toContain('full');
  });

  it('rejects an unknown mode rather than defaulting it', async () => {
    const res = await createJob({ captureMode: 'turbo', expectedFilesCount: 7 });

    expect(res.status).toBe(400);
    expect(res.body.code).toBe('INVALID_REQUEST');
  });

  it('without_bottom meshy is the SAME single ring of 6 + manifest = 7', async () => {
    const res = await createJob({
      captureMode: 'meshy',
      captureVariant: 'without_bottom',
      expectedFilesCount: 7,
    });

    expect(res.status).toBe(201);
  });
});

describe('POST /jobs/:jobId/finalize — meshy bundles', () => {
  /**
   * A job in UPLOADING with [storedCount] files expected.
   *
   * Creation always uses the legal 7 (create-job's range is 6–7 in this mode)
   * and the stored count is then overridden — that is the only way to drive the
   * FINALIZE rules with a wrong-sized bundle, which is what these tests are
   * actually about.
   */
  async function uploadingMeshyJob(storedCount = 7): Promise<string> {
    const res = await createJob({ captureMode: 'meshy', expectedFilesCount: 7 });
    expect(res.status).toBe(201);
    const jobId = res.body.job.id as string;
    await Job.updateOne(
      { _id: jobId },
      { $set: { state: 'UPLOADING', 'upload.expectedFilesCount': storedCount } }
    );
    return jobId;
  }

  it('a valid single EYE ring of 6 finalizes (7 files)', async () => {
    const jobId = await uploadingMeshyJob();

    const res = await finalizeWith(jobId, meshyManifest(), 7);

    expect(res.status).toBe(200);
    expect(res.body.state).toBe('QUEUED');
    expect(res.body.filesVerified).toBe(7);
  });

  it('a 5-photo EYE ring finalizes — the ring may finish one slot short (6 files)', async () => {
    // The 80% floor makes 5 of 6 a complete, uploadable Meshy ring.
    const jobId = await uploadingMeshyJob(6);

    const res = await finalizeWith(jobId, meshyManifest({ EYE: 5 }), 6);

    expect(res.status).toBe(200);
    expect(res.body.state).toBe('QUEUED');
    expect(res.body.filesVerified).toBe(6);
  });

  it('a 4-photo EYE ring is rejected — below the 5-of-6 floor', async () => {
    // One slot short is allowed (5); two short (4) is INSUFFICIENT_PHOTOS_PER_LEVEL.
    const jobId = await uploadingMeshyJob(5);

    const res = await finalizeWith(jobId, meshyManifest({ EYE: 4 }), 5);

    expect(res.status).toBe(422);
    expect(res.body.code).toBe('VERIFICATION_FAILED');
    expect(res.body.validationErrors[0].rule).toBe('INSUFFICIENT_PHOTOS_PER_LEVEL');
    expect(res.body.validationErrors[0].detail.levels).toEqual([
      { levelId: 'EYE', count: 4, required: 5 },
    ]);
  });

  it('TOP/LOW rings are UNEXPECTED_LEVELS — Meshy has no such rings', async () => {
    // The whole point of the reshape: a client still shooting three rings would
    // stamp TOP/LOW into the manifest; the single-ring allowed set rejects them.
    const jobId = await uploadingMeshyJob(11);

    const res = await finalizeWith(jobId, meshyManifest({ EYE: 6, TOP: 2, LOW: 2 }), 11);

    expect(res.status).toBe(422);
    const unexpected = res.body.validationErrors.find(
      (e: { rule: string }) => e.rule === 'UNEXPECTED_LEVELS'
    );
    expect(unexpected).toBeDefined();
    expect(unexpected.detail.unexpectedLevels).toEqual(expect.arrayContaining(['TOP', 'LOW']));
  });

  it('an EYE ring padded to the full-mode count is rejected as EXCESS', async () => {
    // Proof the ceiling is per-ring too: 16 on EYE is legal in full mode and
    // must not be legal here just because some ring somewhere allows it.
    const jobId = await uploadingMeshyJob(17);
    const res = await finalizeWith(jobId, meshyManifest({ EYE: 16 }), 17);

    expect(res.status).toBe(422);
    expect(res.body.validationErrors.map((e: { rule: string }) => e.rule)).toContain(
      'EXCESS_PHOTOS_PER_LEVEL'
    );
  });

  it('a manifest declaring the WRONG mode is a mismatch finding', async () => {
    const jobId = await uploadingMeshyJob();

    const res = await finalizeWith(
      jobId,
      meshyManifest({ EYE: 6 }, { captureMode: 'full' }),
      7
    );

    expect(res.status).toBe(422);
    expect(res.body.validationErrors.map((e: { rule: string }) => e.rule)).toContain(
      'FLOW_VARIANT_MISMATCH'
    );
  });

  it('a manifest declaring the matching mode passes', async () => {
    const jobId = await uploadingMeshyJob();

    const res = await finalizeWith(
      jobId,
      meshyManifest({ EYE: 6 }, { captureMode: 'meshy' }),
      7
    );

    expect(res.status).toBe(200);
  });
});
