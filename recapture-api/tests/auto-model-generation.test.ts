// tests/auto-model-generation.test.ts
//
// The guards standing between "a capture finished" and "we spent Meshy
// credits". Every test here is a test about NOT spending money — that is the
// whole job of this service.
//
// Hermetic: in-memory MongoDB, no S3, no Meshy. The env gate and the
// remote-config flag are driven directly.
import { describe, it, expect, beforeAll, afterAll, beforeEach, afterEach, vi } from 'vitest';
import mongoose, { Types } from 'mongoose';
import { MongoMemoryServer } from 'mongodb-memory-server';

import { env } from '@/config/env';
import { ClientConfig } from '@/models/ClientConfig';
import { Job, MESHY_MODEL_GENERATION_JOB_TYPE } from '@/models/Job';
import { Project } from '@/models/Project';
import { ProjectModel } from '@/models/ProjectModel';
import { buildJobKeyPrefix } from '@/utils/s3Keys';
import {
  AUTO_MODEL_FLAG_KEY,
  autoGenerationIdempotencyKey,
  maybeAutoGenerateModel,
} from '@/services/autoModelGenerationService';

let mongod: MongoMemoryServer;

beforeAll(async () => {
  mongod = await MongoMemoryServer.create();
  await mongoose.connect(mongod.getUri());
  await ProjectModel.syncIndexes();
});

afterAll(async () => {
  await mongoose.disconnect();
  await mongod.stop();
});

beforeEach(() => {
  // The feature ships dark; every test that wants it on says so explicitly.
  vi.spyOn(env, 'AUTO_MODEL_GENERATION_ENABLED', 'get').mockReturnValue(true);
});

afterEach(async () => {
  await Project.deleteMany({});
  await Job.deleteMany({});
  await ProjectModel.deleteMany({});
  await ClientConfig.deleteMany({});
  vi.restoreAllMocks();
});

/** A well-spread, sharp EYE capture — the selector accepts this. */
function goodManifest() {
  return {
    manifestVersion: '1.0',
    config: { segmentCounts: { A: 16, B: 16, C: 16 } },
    photos: Array.from({ length: 16 }, (_, i) => ({
      photoId: `eye_${i}`,
      ringName: 'EYE',
      levelCode: 'A',
      segmentIndex: i,
      verdict: 'accepted',
      quality: { blurScore: 120 },
      orientation: { yawDegrees: i * 22.5 },
      imagePath: `images/EYE/eye_${String(i).padStart(4, '0')}.jpg`,
    })),
  };
}

/** Everything shot from one side — the selector refuses this. */
function oneSidedManifest() {
  const m = goodManifest();
  m.photos = m.photos.slice(0, 3).map((p) => ({ ...p, segmentIndex: 0 }));
  return m;
}

async function makeCaptureJob() {
  const ownerId = new Types.ObjectId();
  const project = await Project.create({
    userId: ownerId,
    name: 'Auto test',
    objectSize: 'MEDIUM',
    mode: 'GUIDED',
    status: 'PROCESSING',
  });
  const jobId = new Types.ObjectId();
  const prefix = buildJobKeyPrefix({
    userId: ownerId.toHexString(),
    projectId: project.id as string,
    jobId: jobId.toHexString(),
  });
  const job = await Job.create({
    _id: jobId,
    projectId: project._id,
    userId: ownerId,
    state: 'PROCESSING',
    objectSize: 'MEDIUM',
    queuedAt: new Date(),
    upload: {
      uploadMethod: 'S3_PRESIGNED_MULTIPART',
      expectedFilesCount: 49,
      uploadedFilesCount: 49,
      checksumAlgo: 'md5',
      rawBucket: 'recapture-test-raw',
      rawPrefix: prefix,
      manifestKey: `${prefix}capture_manifest.json`,
    },
  });
  return { job, project, ownerId };
}

/** Sets (or clears) the live kill switch on the ops config document. */
async function setKillSwitch(value: boolean | undefined): Promise<void> {
  await ClientConfig.deleteMany({});
  if (value !== undefined) await ClientConfig.create({ [AUTO_MODEL_FLAG_KEY]: value });
}

describe('maybeAutoGenerateModel', () => {
  it('enqueues a generation for a good capture', async () => {
    const { job, project } = await makeCaptureJob();

    const result = await maybeAutoGenerateModel({ job: job as never, manifest: goodManifest() });

    expect(result.outcome).toBe('ENQUEUED');
    if (result.outcome !== 'ENQUEUED') return;
    expect(result.keyCount).toBe(4);

    const record = await ProjectModel.findById(result.modelId).exec();
    expect(record?.status).toBe('QUEUED');
    expect(record?.source).toBe('meshy');
    expect(record?.selectedKeys).toHaveLength(4);
    // Attributed to the project OWNER, and flagged as a system spend.
    expect(record?.createdBySystem).toBe(true);
    expect(record?.createdByUserId.toHexString()).toBe(job.userId?.toHexString());
    expect(record?.projectId.toHexString()).toBe(project.id);

    // The worker job the Meshy processor will claim.
    const queued = await Job.findOne({ jobType: MESHY_MODEL_GENERATION_JOB_TYPE }).exec();
    expect(queued?.state).toBe('QUEUED');
    expect((queued?.payload as { modelId?: string })?.modelId).toBe(result.modelId);
  });

  // ── Guard 1: the kill switches ────────────────────────────────────────────

  it('skips when the env gate is off', async () => {
    vi.spyOn(env, 'AUTO_MODEL_GENERATION_ENABLED', 'get').mockReturnValue(false);
    const { job } = await makeCaptureJob();

    const result = await maybeAutoGenerateModel({ job: job as never, manifest: goodManifest() });

    expect(result).toEqual({ outcome: 'SKIPPED', reason: 'DISABLED', detail: 'env' });
    expect(await ProjectModel.countDocuments({})).toBe(0);
  });

  it('skips when the live kill switch is set to false', async () => {
    await setKillSwitch(false);
    const { job } = await makeCaptureJob();

    const result = await maybeAutoGenerateModel({ job: job as never, manifest: goodManifest() });

    expect(result).toEqual({
      outcome: 'SKIPPED',
      reason: 'DISABLED',
      detail: 'remote-config',
    });
    expect(await ProjectModel.countDocuments({})).toBe(0);
  });

  it('runs when the kill switch is unset — the env gate is the opt-in', async () => {
    await setKillSwitch(undefined);
    const { job } = await makeCaptureJob();

    const result = await maybeAutoGenerateModel({ job: job as never, manifest: goodManifest() });

    expect(result.outcome).toBe('ENQUEUED');
  });

  // ── Guard 2: one generation per capture job ───────────────────────────────

  it('enqueues exactly once when the same job is processed twice', async () => {
    const { job } = await makeCaptureJob();

    const first = await maybeAutoGenerateModel({ job: job as never, manifest: goodManifest() });
    const second = await maybeAutoGenerateModel({ job: job as never, manifest: goodManifest() });

    expect(first.outcome).toBe('ENQUEUED');
    expect(second).toEqual({ outcome: 'SKIPPED', reason: 'ALREADY_EXISTS' });
    // The money assertion: one record, one queued generation.
    expect(await ProjectModel.countDocuments({})).toBe(1);
    expect(await Job.countDocuments({ jobType: MESHY_MODEL_GENERATION_JOB_TYPE })).toBe(1);
  });

  it('derives a per-job idempotency key', async () => {
    const { job } = await makeCaptureJob();
    await maybeAutoGenerateModel({ job: job as never, manifest: goodManifest() });

    const record = await ProjectModel.findOne({}).exec();
    expect(record?.idempotencyKey).toBe(autoGenerationIdempotencyKey(job._id));
  });

  it('lets the unique index settle a concurrent double-process', async () => {
    const { job } = await makeCaptureJob();

    // Both calls pass the pre-check before either writes — the race the index exists for.
    const [a, b] = await Promise.all([
      maybeAutoGenerateModel({ job: job as never, manifest: goodManifest() }),
      maybeAutoGenerateModel({ job: job as never, manifest: goodManifest() }),
    ]);

    const outcomes = [a.outcome, b.outcome].sort();
    expect(outcomes).toEqual(['ENQUEUED', 'SKIPPED']);
    expect(await ProjectModel.countDocuments({})).toBe(1);
  });

  // ── Guard 3: the per-user daily ceiling ───────────────────────────────────

  it('skips once the owner hits the 24h cap', async () => {
    const { job, project, ownerId } = await makeCaptureJob();
    // Backfill the cap with prior system generations.
    await ProjectModel.insertMany(
      Array.from({ length: env.AUTO_MODEL_MAX_PER_USER_PER_DAY }, () => ({
        projectId: project._id,
        jobId: new Types.ObjectId(),
        source: 'meshy',
        status: 'SUCCEEDED',
        selectedKeys: ['images/EYE/a.jpg'],
        createdByUserId: ownerId,
        createdByRole: 'USER',
        createdBySystem: true,
      }))
    );

    const result = await maybeAutoGenerateModel({ job: job as never, manifest: goodManifest() });

    expect(result.outcome).toBe('SKIPPED');
    if (result.outcome !== 'SKIPPED') return;
    expect(result.reason).toBe('USER_CAP_REACHED');
  });

  it('ignores generations older than 24h when applying the cap', async () => {
    const { job, project, ownerId } = await makeCaptureJob();
    const old = new Date(Date.now() - 25 * 60 * 60 * 1000);
    await ProjectModel.insertMany(
      Array.from({ length: env.AUTO_MODEL_MAX_PER_USER_PER_DAY }, () => ({
        projectId: project._id,
        jobId: new Types.ObjectId(),
        source: 'meshy',
        status: 'SUCCEEDED',
        selectedKeys: ['images/EYE/a.jpg'],
        createdByUserId: ownerId,
        createdByRole: 'USER',
        createdBySystem: true,
        createdAt: old,
        updatedAt: old,
      })),
      { timestamps: false }
    );

    const result = await maybeAutoGenerateModel({ job: job as never, manifest: goodManifest() });

    expect(result.outcome).toBe('ENQUEUED');
  });

  it('does not count staff-triggered generations against the auto cap', async () => {
    const { job, project, ownerId } = await makeCaptureJob();
    await ProjectModel.insertMany(
      Array.from({ length: env.AUTO_MODEL_MAX_PER_USER_PER_DAY }, () => ({
        projectId: project._id,
        jobId: new Types.ObjectId(),
        source: 'meshy',
        status: 'SUCCEEDED',
        selectedKeys: ['images/EYE/a.jpg'],
        createdByUserId: ownerId,
        createdByRole: 'ADMIN',
        // createdBySystem omitted — a human asked for these.
      }))
    );

    const result = await maybeAutoGenerateModel({ job: job as never, manifest: goodManifest() });

    expect(result.outcome).toBe('ENQUEUED');
  });

  // ── Guard 4: quality ──────────────────────────────────────────────────────

  it('skips a one-sided capture rather than paying for a bad model', async () => {
    const { job } = await makeCaptureJob();

    const result = await maybeAutoGenerateModel({
      job: job as never,
      manifest: oneSidedManifest(),
    });

    expect(result.outcome).toBe('SKIPPED');
    if (result.outcome !== 'SKIPPED') return;
    expect(result.reason).toBe('NOT_SELECTABLE');
    expect(await ProjectModel.countDocuments({})).toBe(0);
    expect(await Job.countDocuments({ jobType: MESHY_MODEL_GENERATION_JOB_TYPE })).toBe(0);
  });

  it('skips an unreadable manifest', async () => {
    const { job } = await makeCaptureJob();

    const result = await maybeAutoGenerateModel({ job: job as never, manifest: { junk: true } });

    expect(result.outcome).toBe('SKIPPED');
    if (result.outcome !== 'SKIPPED') return;
    expect(result.reason).toBe('NOT_SELECTABLE');
  });

  it('drops photos whose objects are not in the bucket listing', async () => {
    const { job } = await makeCaptureJob();
    const availableKeys = [0, 4, 8, 12].map(
      (i) => `images/EYE/eye_${String(i).padStart(4, '0')}.jpg`
    );

    const result = await maybeAutoGenerateModel({
      job: job as never,
      manifest: goodManifest(),
      availableKeys,
    });

    expect(result.outcome).toBe('ENQUEUED');
    const record = await ProjectModel.findOne({}).exec();
    expect(record?.selectedKeys.every((k) => availableKeys.includes(k))).toBe(true);
  });

  it('skips a job with no project or user rather than throwing', async () => {
    const bare = { _id: new Types.ObjectId() };

    const result = await maybeAutoGenerateModel({ job: bare as never, manifest: goodManifest() });

    expect(result).toEqual({ outcome: 'SKIPPED', reason: 'JOB_INCOMPLETE' });
  });
});
