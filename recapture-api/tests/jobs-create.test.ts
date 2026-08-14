// tests/jobs-create.test.ts
//
// POST /jobs — create upload job + return the job-scoped upload plan. Hermetic:
// ephemeral in-memory MongoDB, JWTs minted directly against the test secret
// (requireAuth verifies signature only), no AWS call is made (job creation
// presigns nothing — the plan carries the key space + limits; per-file presign
// is a separate endpoint).
import { describe, it, expect, beforeAll, afterAll, afterEach, vi } from 'vitest';
import request from 'supertest';
import mongoose, { Types } from 'mongoose';
import jwt from 'jsonwebtoken';
import { MongoMemoryServer } from 'mongodb-memory-server';

import { createApp } from '@/app';
import { env } from '@/config/env';
import { Project } from '@/models/Project';
import { Job } from '@/models/Job';
import { PART_SIZE_MIN, MAX_PARTS } from '@/services/jobsService';
import {
  DEFAULT_CAPTURE_FLOW_VARIANT,
  expectedImageCount,
} from '@/models/types/captureVariants';

const app = createApp();
let mongod: MongoMemoryServer;

beforeAll(async () => {
  mongod = await MongoMemoryServer.create();
  await mongoose.connect(mongod.getUri());
  // The idempotency guarantee rests on the unique partial index — build it
  // up-front so tests exercise the real arbiter, not best-effort queries.
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

function tokenFor(userId: string): string {
  return jwt.sign({ userId, authUid: `test|${userId}` }, env.JWT_SECRET, {
    expiresIn: '15m',
  });
}

async function makeProject(
  userId: string,
  objectSize: 'SMALL' | 'MEDIUM' | 'LARGE' = 'MEDIUM'
): Promise<string> {
  const p = await Project.create({
    userId: new Types.ObjectId(userId),
    name: 'Brass Vase',
    objectSize,
    mode: 'GUIDED',
  });
  return p.id as string;
}

const userId = new Types.ObjectId().toHexString();
const auth = { Authorization: `Bearer ${tokenFor(userId)}` };

/** The default variant's full total, manifest-inclusive (48 images + 1). */
const FULL_FILES = expectedImageCount(DEFAULT_CAPTURE_FLOW_VARIANT) + 1;

/** A valid body (default with_bottom variant: full images + manifest). */
function validBody(projectId: string) {
  return { projectId, objectSize: 'medium', expectedFilesCount: FULL_FILES };
}

describe('POST /jobs — happy path', () => {
  it('201: creates the job and returns the job-scoped upload plan', async () => {
    const projectId = await makeProject(userId);
    const logSpy = vi.spyOn(console, 'log').mockImplementation(() => {});

    const res = await request(app).post('/jobs').set(auth).send(validBody(projectId));

    expect(res.status).toBe(201);
    expect(res.body.status).toBe('success');

    const { job, uploadPlan } = res.body;
    expect(job.id).toMatch(/^[a-f0-9]{24}$/);
    expect(job.state).toBe('CREATED');
    expect(job.projectId).toBe(projectId);
    expect(job.objectSize).toBe('medium');
    expect(job.captureVariant).toBe('with_bottom'); // default when unsent
    expect(job.expectedFilesCount).toBe(FULL_FILES);

    // Plan: job-scoped key space + echoed S3 hard limits + bounded expiry.
    expect(uploadPlan.uploadMethod).toBe('S3_PRESIGNED_MULTIPART');
    expect(uploadPlan.bucket).toBe('recapture-test-raw'); // env S3_BUCKET_RAW
    // {env} is config-driven: NODE_ENV=development (vitest.config) → "dev/".
    // The job root carries a slugified PROJECT NAME beside the project id, and
    // deliberately no {userId} — ownership is enforced in the DB, not by prefix.
    expect(uploadPlan.keyPrefix).toBe(`dev/brass-vase_${projectId}/${job.id}/`);
    expect(uploadPlan.keyPrefix).not.toContain(userId);
    expect(uploadPlan.manifestKey).toBe(`${uploadPlan.keyPrefix}capture_manifest.json`);
    expect(uploadPlan.keyTemplate).toBe(`${uploadPlan.keyPrefix}{relativePath}`);
    expect(uploadPlan.levels).toEqual(['EYE', 'TOP', 'LOW']); // with_bottom rings
    expect(uploadPlan.partSizeMin).toBe(PART_SIZE_MIN);
    expect(uploadPlan.partSizeMin).toBe(5_242_880);
    expect(uploadPlan.maxParts).toBe(MAX_PARTS);
    expect(uploadPlan.maxParts).toBe(10_000);
    expect(Date.parse(uploadPlan.expiresAt) - Date.parse(job.createdAt)).toBe(
      env.UPLOAD_PLAN_TTL_SECONDS * 1000
    );

    // Persisted record matches the response (source of truth for later steps).
    const saved = await Job.findById(job.id).exec();
    expect(saved).not.toBeNull();
    expect(saved!.state).toBe('CREATED');
    expect(saved!.objectSize).toBe('MEDIUM');
    expect(saved!.captureVariant).toBe('with_bottom');
    expect(saved!.userId.toHexString()).toBe(userId);
    expect(saved!.upload!.expectedFilesCount).toBe(FULL_FILES);
    expect(saved!.upload!.uploadedFilesCount).toBe(0);
    expect(saved!.upload!.rawPrefix).toBe(uploadPlan.keyPrefix);
    expect(saved!.upload!.manifestKey).toBe(uploadPlan.manifestKey);

    // Analytics: one job_created with grounded props.
    const jobCreated = logSpy.mock.calls.filter((c) =>
      String(c[0]).includes('[analytics] job_created')
    );
    expect(jobCreated).toHaveLength(1);
    expect(String(jobCreated[0]![1])).toContain(`"expected_files_count":${FULL_FILES}`);
    expect(String(jobCreated[0]![1])).toContain('"flow_variant":"with_bottom"');
  });

  it('response never leaks credentials — only plan data', async () => {
    const projectId = await makeProject(userId);
    const res = await request(app).post('/jobs').set(auth).send(validBody(projectId));

    const raw = JSON.stringify(res.body);
    expect(raw).not.toContain('test-access-key'); // AWS_ACCESS_KEY_ID
    expect(raw).not.toContain('test-secret-key'); // AWS_SECRET_ACCESS_KEY
    expect(raw.toLowerCase()).not.toContain('secret');
  });
});

describe('POST /jobs — validation (400)', () => {
  it.each([
    ['unknown objectSize', { objectSize: 'gigantic' }],
    ['zero count', { expectedFilesCount: 0 }],
    ['negative count', { expectedFilesCount: -1 }],
    ['non-integer count', { expectedFilesCount: 72.5 }],
    ['count over the absolute max', { expectedFilesCount: 99_999 }],
    ['extra field (strict)', { userId: 'evil' }],
  ])('%s → 400, nothing created', async (_name, patch) => {
    const projectId = await makeProject(userId);
    const res = await request(app)
      .post('/jobs')
      .set(auth)
      .send({ ...validBody(projectId), ...patch });

    expect(res.status).toBe(400);
    expect(res.body.code).toBe('INVALID_REQUEST');
    expect(await Job.countDocuments()).toBe(0);
  });

  it('missing projectId → 400 with a field-level error', async () => {
    const res = await request(app)
      .post('/jobs')
      .set(auth)
      .send({ objectSize: 'medium', expectedFilesCount: 73 });

    expect(res.status).toBe(400);
    expect(res.body.fields).toHaveProperty('projectId');
  });

  it('malformed Idempotency-Key (over 128 chars) → 400', async () => {
    const projectId = await makeProject(userId);
    const res = await request(app)
      .post('/jobs')
      .set(auth)
      .set('Idempotency-Key', 'k'.repeat(129))
      .send(validBody(projectId));

    expect(res.status).toBe(400);
    expect(await Job.countDocuments()).toBe(0);
  });

  it('objectSize mismatching the project → 400 naming the expected size', async () => {
    const projectId = await makeProject(userId, 'MEDIUM');
    const res = await request(app)
      .post('/jobs')
      .set(auth)
      .send({ projectId, objectSize: 'small', expectedFilesCount: 91 });

    expect(res.status).toBe(400);
    expect(res.body.message).toContain("'medium'");
    expect(await Job.countDocuments()).toBe(0);
  });

  // The valid range is [compatMinimumImageCount + 1, compatMaximumImageCount
  // + 1] — the legacy-compatible coverage floor (80% per ring, min over the
  // retired 12/18 revision and the current 16/24 one) to the highest full
  // total, manifest-inclusive. Both variants: 30 images minimum, 48 maximum
  // → 31–49 files.
  it.each([
    ['far undershoot', 10],
    ['one below the compat coverage floor (min − 1)', 30],
    ['one above the full total (max + 1)', 50],
    ['overshoot (pre-variant size-based count)', 73],
  ])(
    'expectedFilesCount %s → 400 naming the valid range',
    async (_name, count) => {
      const projectId = await makeProject(userId, 'MEDIUM');
      const res = await request(app)
        .post('/jobs')
        .set(auth)
        .send({ projectId, objectSize: 'medium', expectedFilesCount: count });

      expect(res.status).toBe(400);
      // with_bottom: [3 × 10 + manifest, 3 × 16 + manifest] = 31–49.
      expect(res.body.message).toContain('between 31 and 49');
      expect(res.body.fields.expectedFilesCount).toBe('must be 31-49');
      expect(await Job.countDocuments()).toBe(0);
    }
  );

  it.each([
    ['with_bottom', 'with_bottom'],
    ['without_bottom', 'without_bottom'],
  ])('%s: the range bounds are accepted exactly (min and max)', async (_n, captureVariant) => {
    for (const count of [31, 49]) {
      const projectId = await makeProject(userId, 'MEDIUM');
      const res = await request(app)
        .post('/jobs')
        .set(auth)
        .send({ projectId, objectSize: 'medium', captureVariant, expectedFilesCount: count });

      expect(res.status).toBe(201);
      expect(res.body.job.expectedFilesCount).toBe(count);
    }
  });

  it.each([
    ['with_bottom', 'with_bottom'],
    ['without_bottom', 'without_bottom'],
  ])('%s: min − 1 and max + 1 → 400 with the range', async (_n, captureVariant) => {
    for (const count of [30, 50]) {
      const projectId = await makeProject(userId, 'MEDIUM');
      const res = await request(app)
        .post('/jobs')
        .set(auth)
        .send({ projectId, objectSize: 'medium', captureVariant, expectedFilesCount: count });

      expect(res.status).toBe(400);
      expect(res.body.code).toBe('INVALID_REQUEST');
      expect(res.body.message).toContain(`'${captureVariant}'`);
      expect(res.body.message).toContain('between 31 and 49');
      expect(res.body.fields.expectedFilesCount).toBe('must be 31-49');
    }
    expect(await Job.countDocuments()).toBe(0);
  });

  it('a partial without_bottom capture (21/24 per ring → 43 files) is accepted', async () => {
    // The real-device case behind the range: two rings finished at 21/24
    // segments (≥ the 80% coverage floor of 20) pack 42 images + manifest.
    const projectId = await makeProject(userId, 'MEDIUM');
    const res = await request(app)
      .post('/jobs')
      .set(auth)
      .send({
        projectId,
        objectSize: 'medium',
        captureVariant: 'without_bottom',
        expectedFilesCount: 43,
      });

    expect(res.status).toBe(201);
    expect(res.body.job.expectedFilesCount).toBe(43);
    // Finalize verifies against the STORED client count — it must persist as-is.
    const saved = await Job.findById(res.body.job.id).exec();
    expect(saved!.upload!.expectedFilesCount).toBe(43);
  });

  it('BACK-COMPAT: a capture made under the retired 12/18-per-ring config is still accepted', async () => {
    // A session captured before the 16/24 bump reaches create-job with the old
    // counts (client config is cached) — the compat range must admit it.
    for (const [captureVariant, count] of [
      ['with_bottom', 37], // legacy full: 3 × 12 + manifest
      ['without_bottom', 37], // legacy full: 2 × 18 + manifest
      ['with_bottom', 31], // legacy coverage floor: 3 × 10 + manifest
    ] as const) {
      const projectId = await makeProject(userId, 'MEDIUM');
      const res = await request(app)
        .post('/jobs')
        .set(auth)
        .send({ projectId, objectSize: 'medium', captureVariant, expectedFilesCount: count });

      expect(res.status).toBe(201);
      expect(res.body.job.expectedFilesCount).toBe(count);
    }
  });
});

describe('POST /jobs — authorization', () => {
  it('401 without a token', async () => {
    const res = await request(app)
      .post('/jobs')
      .send({ projectId: new Types.ObjectId().toHexString(), objectSize: 'medium', expectedFilesCount: 73 });

    expect(res.status).toBe(401);
  });

  it("404 for another user's project — no job, no plan", async () => {
    const otherUser = new Types.ObjectId().toHexString();
    const projectId = await makeProject(otherUser); // owned by someone else

    const res = await request(app).post('/jobs').set(auth).send(validBody(projectId));

    expect(res.status).toBe(404);
    expect(res.body.code).toBe('NOT_FOUND');
    expect(await Job.countDocuments()).toBe(0);
  });

  it('404 for a nonexistent project', async () => {
    const res = await request(app)
      .post('/jobs')
      .set(auth)
      .send(validBody(new Types.ObjectId().toHexString()));

    expect(res.status).toBe(404);
  });

  it('404 for a soft-deleted project', async () => {
    const projectId = await makeProject(userId);
    await Project.updateOne({ _id: projectId }, { $set: { deletedAt: new Date() } });

    const res = await request(app).post('/jobs').set(auth).send(validBody(projectId));

    expect(res.status).toBe(404);
    expect(await Job.countDocuments()).toBe(0);
  });
});

describe('POST /jobs — idempotency', () => {
  it('same key + same payload → the original job replayed, one job total', async () => {
    const projectId = await makeProject(userId);
    const logSpy = vi.spyOn(console, 'log').mockImplementation(() => {});
    const key = 'retry-abc-123';

    const first = await request(app)
      .post('/jobs')
      .set(auth)
      .set('Idempotency-Key', key)
      .send(validBody(projectId));
    const second = await request(app)
      .post('/jobs')
      .set(auth)
      .set('Idempotency-Key', key)
      .send(validBody(projectId));

    expect(first.status).toBe(201);
    expect(second.status).toBe(200);
    expect(second.body.idempotentReplay).toBe(true);
    expect(second.body.job.id).toBe(first.body.job.id);
    // The plan is byte-identical — expiry anchored to createdAt, never extended.
    expect(second.body.uploadPlan).toEqual(first.body.uploadPlan);
    expect(await Job.countDocuments()).toBe(1);

    // Exactly one job_created — the replay emits nothing.
    const jobCreated = logSpy.mock.calls.filter((c) =>
      String(c[0]).includes('[analytics] job_created')
    );
    expect(jobCreated).toHaveLength(1);
  });

  it('same key + DIFFERENT payload (changed captureVariant) → 409, no second job', async () => {
    const projectId = await makeProject(userId);
    const key = 'retry-abc-456';

    const first = await request(app)
      .post('/jobs')
      .set(auth)
      .set('Idempotency-Key', key)
      .send(validBody(projectId));
    // Both variants total 49 files, so the ONLY drift is the variant itself —
    // it must still conflict like any other body drift under the same key.
    const second = await request(app)
      .post('/jobs')
      .set(auth)
      .set('Idempotency-Key', key)
      .send({ ...validBody(projectId), captureVariant: 'without_bottom' });

    expect(first.status).toBe(201);
    expect(second.status).toBe(409);
    expect(second.body.code).toBe('IDEMPOTENCY_CONFLICT');
    expect(await Job.countDocuments()).toBe(1);
  });

  it('the same key is independent per user (no cross-user collision)', async () => {
    const otherUser = new Types.ObjectId().toHexString();
    const projectA = await makeProject(userId);
    const projectB = await makeProject(otherUser);
    const key = 'shared-key';

    const a = await request(app)
      .post('/jobs')
      .set(auth)
      .set('Idempotency-Key', key)
      .send(validBody(projectA));
    const b = await request(app)
      .post('/jobs')
      .set({ Authorization: `Bearer ${tokenFor(otherUser)}` })
      .set('Idempotency-Key', key)
      .send(validBody(projectB));

    expect(a.status).toBe(201);
    expect(b.status).toBe(201);
    expect(await Job.countDocuments()).toBe(2);
  });

  it('requests without a key never idempotency-collide', async () => {
    const projectId = await makeProject(userId);

    const first = await request(app).post('/jobs').set(auth).send(validBody(projectId));
    const second = await request(app).post('/jobs').set(auth).send(validBody(projectId));

    expect(first.status).toBe(201);
    expect(second.status).toBe(201);
    expect(second.body.job.id).not.toBe(first.body.job.id);
    expect(await Job.countDocuments()).toBe(2);
  });

  it('a partial count replays under the same key; a different count 409s', async () => {
    const projectId = await makeProject(userId, 'MEDIUM');
    const key = 'retry-partial-123';
    const body = {
      projectId,
      objectSize: 'medium',
      captureVariant: 'without_bottom',
      expectedFilesCount: 43, // partial (21+21 images + manifest)
    };

    const first = await request(app)
      .post('/jobs')
      .set(auth)
      .set('Idempotency-Key', key)
      .send(body);
    const replay = await request(app)
      .post('/jobs')
      .set(auth)
      .set('Idempotency-Key', key)
      .send(body);
    // A different (still-valid) count under the same key is a payload drift.
    const conflict = await request(app)
      .post('/jobs')
      .set(auth)
      .set('Idempotency-Key', key)
      .send({ ...body, expectedFilesCount: 35 });

    expect(first.status).toBe(201);
    expect(replay.status).toBe(200);
    expect(replay.body.idempotentReplay).toBe(true);
    expect(replay.body.job.id).toBe(first.body.job.id);
    expect(conflict.status).toBe(409);
    expect(conflict.body.code).toBe('IDEMPOTENCY_CONFLICT');
    expect(await Job.countDocuments()).toBe(1);
  });

  it('a replay sending the defaulted variant EXPLICITLY still replays (no false conflict)', async () => {
    const projectId = await makeProject(userId);
    const key = 'retry-abc-789';

    const first = await request(app)
      .post('/jobs')
      .set(auth)
      .set('Idempotency-Key', key)
      .send(validBody(projectId)); // captureVariant omitted → with_bottom
    const second = await request(app)
      .post('/jobs')
      .set(auth)
      .set('Idempotency-Key', key)
      .send({ ...validBody(projectId), captureVariant: 'with_bottom' });

    expect(first.status).toBe(201);
    expect(second.status).toBe(200);
    expect(second.body.idempotentReplay).toBe(true);
    expect(await Job.countDocuments()).toBe(1);
  });
});

describe('POST /jobs — captureVariant', () => {
  it("201: 'without_bottom' persists on the job and the plan covers only EYE/TOP", async () => {
    const projectId = await makeProject(userId);

    const res = await request(app)
      .post('/jobs')
      .set(auth)
      .send({ ...validBody(projectId), captureVariant: 'without_bottom' });

    expect(res.status).toBe(201);
    expect(res.body.job.captureVariant).toBe('without_bottom');
    expect(res.body.job.expectedFilesCount).toBe(FULL_FILES); // 2 rings × 24 + manifest
    expect(res.body.uploadPlan.levels).toEqual(['EYE', 'TOP']); // no LOW planned

    const saved = await Job.findById(res.body.job.id).exec();
    expect(saved!.captureVariant).toBe('without_bottom');
  });

  it("201: an explicit 'with_bottom' behaves exactly like the default", async () => {
    const projectId = await makeProject(userId);

    const res = await request(app)
      .post('/jobs')
      .set(auth)
      .send({ ...validBody(projectId), captureVariant: 'with_bottom' });

    expect(res.status).toBe(201);
    expect(res.body.job.captureVariant).toBe('with_bottom');
    expect(res.body.uploadPlan.levels).toEqual(['EYE', 'TOP', 'LOW']);
  });

  it('an unknown variant id → 400, nothing created', async () => {
    const projectId = await makeProject(userId);

    const res = await request(app)
      .post('/jobs')
      .set(auth)
      .send({ ...validBody(projectId), captureVariant: 'sideways' });

    expect(res.status).toBe(400);
    expect(res.body.code).toBe('INVALID_REQUEST');
    expect(await Job.countDocuments()).toBe(0);
  });

  it('the created analytics event carries the variant', async () => {
    const projectId = await makeProject(userId);
    const logSpy = vi.spyOn(console, 'log').mockImplementation(() => {});

    const res = await request(app)
      .post('/jobs')
      .set(auth)
      .send({ ...validBody(projectId), captureVariant: 'without_bottom' });
    expect(res.status).toBe(201);

    const jobCreated = logSpy.mock.calls.filter((c) =>
      String(c[0]).includes('[analytics] job_created')
    );
    expect(jobCreated).toHaveLength(1);
    expect(String(jobCreated[0]![1])).toContain('"flow_variant":"without_bottom"');
  });
});
