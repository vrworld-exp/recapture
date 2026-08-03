// tests/asset-optimization-processor.test.ts
//
// The ASSET_OPTIMIZATION processor and its handoff from Meshy generation.
//
// THE LOAD-BEARING ASSERTIONS, in priority order:
//   1. optimization failing NEVER moves the model off SUCCEEDED — the paid
//      generation and its original GLB survive any pipeline bug;
//   2. producing an optimized variant does NOT promote it — activeVariant stays
//      'original' until a human decides;
//   3. the original GLB is never overwritten — it is the only way to re-run an
//      improved recipe later.
//
// Hermetic: in-memory MongoDB and a scripted S3 client. The pipeline itself is
// real (real GLB bytes through real encoders) because a mocked pipeline would
// prove nothing about the wiring.
import { describe, it, expect, beforeAll, afterAll, beforeEach, afterEach, vi } from 'vitest';
import mongoose, { Types } from 'mongoose';
import { MongoMemoryServer } from 'mongodb-memory-server';

import { s3Client } from '@/config/s3';
import { Job } from '@/models/Job';
import { Project } from '@/models/Project';
import { ProjectModel, type IProjectModel } from '@/models/ProjectModel';
import { ASSET_PIPELINE_VERSION } from '@/models/types/assetManifest.types';
import { buildJobKeyPrefix } from '@/utils/s3Keys';
import {
  assetOptimizationProcessor,
  AssetOptimizationErrorCode,
} from '@/worker/processors/assetOptimizationProcessor';
import { NonRetryableJobError, type WorkerJob } from '@/worker/workerTypes';

import { makeMeshyLikeGlb } from './fixtures/glbFactory';

let mongod: MongoMemoryServer;
const WORKER_ID = 'worker-opt-1';

/** Built once — encoding a 1k texture per test would dominate the runtime. */
let heavyGlb: Uint8Array;
let tinyGlb: Uint8Array;

beforeAll(async () => {
  mongod = await MongoMemoryServer.create();
  await mongoose.connect(mongod.getUri());
  heavyGlb = (await makeMeshyLikeGlb({ baseColorSize: 1024, constantMetalRough: true })).glb;
  tinyGlb = (await makeMeshyLikeGlb({ gridSize: 6, baseColorSize: 32 })).glb;
}, 180_000);

afterAll(async () => {
  await mongoose.disconnect();
  await mongod.stop();
});

beforeEach(() => {
  vi.spyOn(console, 'log').mockImplementation(() => {});
});

afterEach(async () => {
  await Job.deleteMany({});
  await Project.deleteMany({});
  await ProjectModel.deleteMany({});
  vi.restoreAllMocks();
});

/**
 * Scripts S3: GetObject returns the given GLB, PutObject records its key and
 * cache header. Returns the captured writes.
 */
function mockS3(glb: Uint8Array): {
  puts: { key: string; contentType?: string; cacheControl?: string }[];
} {
  const puts: { key: string; contentType?: string; cacheControl?: string }[] = [];
  vi.spyOn(s3Client, 'send').mockImplementation((async (cmd: {
    constructor: { name: string };
    input: { Key?: string; ContentType?: string; CacheControl?: string };
  }) => {
    if (cmd.constructor.name === 'PutObjectCommand') {
      puts.push({
        key: cmd.input.Key as string,
        contentType: cmd.input.ContentType,
        cacheControl: cmd.input.CacheControl,
      });
      return {};
    }
    if (cmd.constructor.name === 'GetObjectCommand') {
      return {
        Body: { transformToByteArray: async () => glb },
        ContentType: 'model/gltf-binary',
      };
    }
    return {};
  }) as never);
  return { puts };
}

/** A SUCCEEDED model record plus a claimed ASSET_OPTIMIZATION job. */
async function seed(
  recordOverrides: Partial<IProjectModel> = {}
): Promise<{ workerJob: WorkerJob; record: IProjectModel; modelPrefix: string }> {
  const userId = new Types.ObjectId();
  const project = await Project.create({
    userId,
    name: 'P',
    objectSize: 'MEDIUM',
    mode: 'GUIDED',
    status: 'COMPLETED',
  });
  const captureJobId = new Types.ObjectId();
  const prefix = buildJobKeyPrefix({
    userId: userId.toHexString(),
    projectId: project.id as string,
    jobId: captureJobId.toHexString(),
  });

  const record = await ProjectModel.create({
    projectId: project._id,
    jobId: captureJobId,
    source: 'meshy',
    status: 'SUCCEEDED',
    selectedKeys: ['a.jpg'],
    createdByUserId: userId,
    createdByRole: 'ADMIN',
    artifacts: {
      glbKey: `${prefix}models/PLACEHOLDER/model.glb`,
      previewImageKey: `${prefix}models/PLACEHOLDER/preview.png`,
      cdnUrls: { glb: 'https://cdn.example/model.glb' },
    },
    ...recordOverrides,
  });

  // Rewrite the keys now the record id exists, mirroring modelArtifactPrefix.
  const modelPrefix = `${prefix}models/${record.id as string}/`;
  record.artifacts!.glbKey = `${modelPrefix}model.glb`;
  record.artifacts!.previewImageKey = `${modelPrefix}preview.png`;
  await record.save();

  const job = await Job.create({
    projectId: project._id,
    userId,
    jobType: 'ASSET_OPTIMIZATION',
    state: 'PROCESSING',
    claimedBy: WORKER_ID,
    claimedAt: new Date(),
    stageProgress: { stage: 'PROCESSING', percent: 0 },
    payload: { modelId: record.id as string },
  });

  return {
    workerJob: { ...(job.toObject() as unknown as WorkerJob), claimedBy: WORKER_ID },
    record,
    modelPrefix,
  };
}

describe('assetOptimizationProcessor — happy path', () => {
  it('publishes web.glb + report + manifest under a version prefix, never touching the original', async () => {
    const { workerJob, modelPrefix } = await seed();
    const { puts } = mockS3(heavyGlb);

    await assetOptimizationProcessor(workerJob);

    const keys = puts.map((p) => p.key);
    expect(keys).toEqual([
      `${modelPrefix}v${ASSET_PIPELINE_VERSION}/web.glb`,
      `${modelPrefix}v${ASSET_PIPELINE_VERSION}/report.json`,
      `${modelPrefix}v${ASSET_PIPELINE_VERSION}/manifest.json`,
    ]);

    // THE contract: the untouched Meshy original is never rewritten. It is the
    // only way to re-run an improved recipe later.
    expect(keys).not.toContain(`${modelPrefix}model.glb`);
  }, 180_000);

  it('serves the variant immutable with the right content type', async () => {
    const { workerJob } = await seed();
    const { puts } = mockS3(heavyGlb);

    await assetOptimizationProcessor(workerJob);

    const web = puts.find((p) => p.key.endsWith('web.glb'))!;
    expect(web.contentType).toBe('model/gltf-binary');
    expect(web.cacheControl).toBe('public, max-age=31536000, immutable');
  }, 180_000);

  it('records both variants with before/after numbers on the model', async () => {
    const { workerJob, record } = await seed();
    mockS3(heavyGlb);

    await assetOptimizationProcessor(workerJob);

    const saved = await ProjectModel.findById(record.id).exec();
    expect(saved!.optimized!.status).toBe('SUCCEEDED');
    expect(saved!.optimized!.pipelineVersion).toBe(ASSET_PIPELINE_VERSION);

    const manifest = saved!.optimized!.manifest!;
    expect(manifest.variants.map((v) => v.id)).toEqual(['original', 'web']);
    expect(manifest.reduction.bytesAfter).toBeLessThan(manifest.reduction.bytesBefore);
    expect(manifest.physicalSize.longestDimMeters).toBeGreaterThan(0);
    // Meshy's own poster, re-hosted — we never render our own.
    expect(manifest.posterUrl).toMatch(/preview\.png$/);
  }, 180_000);

  it('does NOT promote the optimized variant — that stays an admin decision', async () => {
    const { workerJob, record } = await seed();
    mockS3(heavyGlb);

    await assetOptimizationProcessor(workerJob);

    const saved = await ProjectModel.findById(record.id).exec();
    expect(saved!.optimized!.activeVariant).toBe('original');
  }, 180_000);

  it('preserves an admin promotion across a re-run', async () => {
    const { workerJob, record } = await seed();
    mockS3(heavyGlb);
    await assetOptimizationProcessor(workerJob);

    // Admin promotes, then the job is re-claimed and re-runs.
    await ProjectModel.updateOne(
      { _id: record._id },
      { $set: { 'optimized.activeVariant': 'web' } }
    ).exec();
    await assetOptimizationProcessor(workerJob);

    const saved = await ProjectModel.findById(record.id).exec();
    expect(saved!.optimized!.activeVariant).toBe('web');
  }, 240_000);

  it('marks an already-small model SKIPPED and publishes only the original', async () => {
    const { workerJob, record } = await seed();
    const { puts } = mockS3(tinyGlb);

    await assetOptimizationProcessor(workerJob);

    const saved = await ProjectModel.findById(record.id).exec();
    expect(saved!.optimized!.status).toBe('SKIPPED');
    expect(saved!.optimized!.manifest!.variants.map((v) => v.id)).toEqual(['original']);
    // No web.glb, but the report still explains WHY nothing happened.
    expect(puts.map((p) => p.key).some((k) => k.endsWith('web.glb'))).toBe(false);
    expect(puts.map((p) => p.key).some((k) => k.endsWith('report.json'))).toBe(true);
  }, 180_000);
});

describe('assetOptimizationProcessor — failure never retracts the model', () => {
  it('leaves the model SUCCEEDED when the source GLB is unreadable', async () => {
    const { workerJob, record } = await seed();
    mockS3(new Uint8Array([1, 2, 3, 4])); // not a GLB

    await expect(assetOptimizationProcessor({ ...workerJob, attempts: 2, maxAttempts: 3 })).rejects.toThrow();

    const saved = await ProjectModel.findById(record.id).exec();
    // THE headline guarantee: the paid generation is untouched.
    expect(saved!.status).toBe('SUCCEEDED');
    expect(saved!.artifacts!.glbKey).toBe(record.artifacts!.glbKey);
    expect(saved!.optimized!.status).toBe('FAILED');
    expect(saved!.optimized!.activeVariant).toBe('original');
  }, 180_000);

  it('is terminal (no retry) when the record has no GLB to optimize', async () => {
    const { workerJob } = await seed();
    await ProjectModel.updateOne(
      { _id: new Types.ObjectId(workerJob.payload!.modelId as string) },
      { $unset: { artifacts: 1 } }
    ).exec();
    mockS3(heavyGlb);

    const err = await assetOptimizationProcessor(workerJob).catch((e: unknown) => e);

    expect(err).toBeInstanceOf(NonRetryableJobError);
    expect((err as NonRetryableJobError).code).toBe(AssetOptimizationErrorCode.SOURCE_MISSING);
  }, 180_000);

  it('is terminal when the source object is gone from the bucket', async () => {
    const { workerJob } = await seed();
    vi.spyOn(s3Client, 'send').mockImplementation((async (cmd: {
      constructor: { name: string };
    }) => {
      if (cmd.constructor.name === 'GetObjectCommand') {
        throw Object.assign(new Error('NoSuchKey'), { name: 'NoSuchKey' });
      }
      return {};
    }) as never);

    const err = await assetOptimizationProcessor(workerJob).catch((e: unknown) => e);

    expect(err).toBeInstanceOf(NonRetryableJobError);
    expect((err as NonRetryableJobError).code).toBe(AssetOptimizationErrorCode.SOURCE_MISSING);
  }, 180_000);

  it('rejects a malformed job with no payload.modelId', async () => {
    const { workerJob } = await seed();

    const err = await assetOptimizationProcessor({ ...workerJob, payload: {} }).catch(
      (e: unknown) => e
    );

    expect(err).toBeInstanceOf(NonRetryableJobError);
    expect((err as NonRetryableJobError).code).toBe(AssetOptimizationErrorCode.JOB_MALFORMED);
  }, 60_000);

  it('does not write FAILED while retries remain — the job will resume', async () => {
    const { workerJob, record } = await seed();
    mockS3(new Uint8Array([1, 2, 3, 4]));

    await expect(
      assetOptimizationProcessor({ ...workerJob, attempts: 0, maxAttempts: 3 })
    ).rejects.toThrow();

    const saved = await ProjectModel.findById(record.id).exec();
    // Still PROCESSING (set on entry), not FAILED: the truth is "it will retry".
    expect(saved!.optimized?.status).not.toBe('FAILED');
  }, 180_000);
});
