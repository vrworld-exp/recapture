// tests/jobs-meshy-mode.test.ts
//
// Meshy capture mode end-to-end through the job endpoints: create with
// `captureMode: 'meshy'`, finalize a 10-image bundle, and prove the per-ring
// floor actually bites (9 images is a rejection, and so is 5/2/2 even though
// its TOTAL would satisfy any scalar bound).
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

/** A Meshy manifest: per-ring counts, so a bundle can be made wrong on ONE ring
 * while its total still looks plausible. */
function meshyManifest(
  counts: Record<string, number> = { EYE: 6, TOP: 2, LOW: 2 },
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
  it('accepts meshy and persists it, with the 11-file count (10 + manifest)', async () => {
    const res = await createJob({ captureMode: 'meshy', expectedFilesCount: 11 });

    expect(res.status).toBe(201);
    const saved = await Job.findById(res.body.job.id).exec();
    expect(saved!.captureMode).toBe('meshy');
    expect(saved!.captureVariant).toBe('with_bottom');
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

  it('rejects a meshy-sized count under full mode', async () => {
    const res = await createJob({ captureMode: 'full', expectedFilesCount: 11 });

    expect(res.status).toBe(400);
    expect(res.body.code).toBe('INVALID_REQUEST');
    expect(res.body.message).toContain('full');
  });

  it('rejects an unknown mode rather than defaulting it', async () => {
    const res = await createJob({ captureMode: 'turbo', expectedFilesCount: 11 });

    expect(res.status).toBe(400);
    expect(res.body.code).toBe('INVALID_REQUEST');
  });

  it('without_bottom meshy is 8 images + manifest', async () => {
    const res = await createJob({
      captureMode: 'meshy',
      captureVariant: 'without_bottom',
      expectedFilesCount: 9,
    });

    expect(res.status).toBe(201);
  });
});

describe('POST /jobs/:jobId/finalize — meshy bundles', () => {
  /**
   * A job in UPLOADING with [storedCount] files expected.
   *
   * Creation always uses the legal 11 (create-job's range refuses anything
   * else in this mode) and the stored count is then overridden — that is the
   * only way to drive the FINALIZE rules with a wrong-sized bundle, which is
   * what these tests are actually about.
   */
  async function uploadingMeshyJob(storedCount = 11): Promise<string> {
    const res = await createJob({ captureMode: 'meshy', expectedFilesCount: 11 });
    expect(res.status).toBe(201);
    const jobId = res.body.job.id as string;
    await Job.updateOne(
      { _id: jobId },
      { $set: { state: 'UPLOADING', 'upload.expectedFilesCount': storedCount } }
    );
    return jobId;
  }

  it('a valid 10-image 6/2/2 bundle finalizes', async () => {
    const jobId = await uploadingMeshyJob();

    const res = await finalizeWith(jobId, meshyManifest(), 11);

    expect(res.status).toBe(200);
    expect(res.body.state).toBe('QUEUED');
    expect(res.body.filesVerified).toBe(11);
  });

  it('a 9-image bundle is rejected', async () => {
    // The Task 3 done-criterion. 5/2/2 totals 9 and would pass any collapsed
    // scalar floor (min 2 per ring, 8 total) — it is the per-ring bound that
    // catches it.
    const jobId = await uploadingMeshyJob(10);

    const res = await finalizeWith(jobId, meshyManifest({ EYE: 5, TOP: 2, LOW: 2 }), 10);

    expect(res.status).toBe(422);
    expect(res.body.code).toBe('VERIFICATION_FAILED');
    expect(res.body.validationErrors[0].rule).toBe('INSUFFICIENT_PHOTOS_PER_LEVEL');
    expect(res.body.validationErrors[0].detail.levels).toEqual([
      { levelId: 'EYE', count: 5, required: 6 },
    ]);
  });

  it('one missing shot on a 2-photo ring is rejected — zero tolerance, stated', async () => {
    const jobId = await uploadingMeshyJob(10);

    const res = await finalizeWith(jobId, meshyManifest({ EYE: 6, TOP: 2, LOW: 1 }), 10);

    expect(res.status).toBe(422);
    expect(res.body.validationErrors[0].rule).toBe('INSUFFICIENT_PHOTOS_PER_LEVEL');
  });

  it('an EYE ring padded to the full-mode count is rejected as EXCESS', async () => {
    // Proof the ceiling is per-ring too: 16 on EYE is legal in full mode and
    // must not be legal here just because some ring somewhere allows it.
    const jobId = await uploadingMeshyJob(21);
    const res = await finalizeWith(jobId, meshyManifest({ EYE: 16, TOP: 2, LOW: 2 }), 21);

    expect(res.status).toBe(422);
    expect(res.body.validationErrors.map((e: { rule: string }) => e.rule)).toContain(
      'EXCESS_PHOTOS_PER_LEVEL'
    );
  });

  it('a manifest declaring the WRONG mode is a mismatch finding', async () => {
    const jobId = await uploadingMeshyJob();

    const res = await finalizeWith(
      jobId,
      meshyManifest({ EYE: 6, TOP: 2, LOW: 2 }, { captureMode: 'full' }),
      11
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
      meshyManifest({ EYE: 6, TOP: 2, LOW: 2 }, { captureMode: 'meshy' }),
      11
    );

    expect(res.status).toBe(200);
  });
});
