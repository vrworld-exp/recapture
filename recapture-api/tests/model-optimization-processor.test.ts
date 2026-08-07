// tests/model-optimization-processor.test.ts
//
// The MODEL_OPTIMIZATION processor and the pure optimizer behind it, exercised
// against a REAL GLB fixture (tests/fixtures/sample-model.glb — duplicated
// materials, split vertices, an orphan mesh and a PNG texture, i.e. the shapes
// the pipeline exists to collapse).
//
// A synthetic "pretend it got smaller" stub would prove nothing here: the whole
// feature is the claim that the output is materially smaller AND still a valid
// document, and only a real glTF-Transform round trip can say that.
//
// The other load-bearing assertion is that the SOURCE RECORD IS UNTOUCHED. An
// optimization writes only to the OPT record and its own S3 prefix; a bug that
// overwrote the original's artifacts would destroy the model it was derived
// from, and `latestSucceededModel` now returns whichever is newer.
//
// Hermetic: in-memory MongoDB, scripted S3 (no bytes leave the process).
import fs from 'node:fs';
import path from 'node:path';
import { describe, it, expect, beforeAll, afterAll, beforeEach, afterEach, vi } from 'vitest';
import mongoose, { Types } from 'mongoose';
import { MongoMemoryServer } from 'mongodb-memory-server';

import { env } from '@/config/env';
import { s3Client } from '@/config/s3';
import { Job } from '@/models/Job';
import { Project } from '@/models/Project';
import { ProjectModel, type IProjectModel } from '@/models/ProjectModel';
import { buildJobKeyPrefix } from '@/utils/s3Keys';
import * as optimizerModule from '@/services/modelOptimizerService';
import {
  ModelOptimizeError,
  ModelOptimizeErrorCode,
  optimizeGlb,
} from '@/services/modelOptimizerService';
import { modelOptimizationProcessor } from '@/worker/processors/modelOptimizationProcessor';
import { NonRetryableJobError, type WorkerJob } from '@/worker/workerTypes';

let mongod: MongoMemoryServer;
const WORKER_ID = 'worker-test-1';

const FIXTURE = new Uint8Array(
  fs.readFileSync(path.join(__dirname, 'fixtures', 'sample-model.glb'))
);

beforeAll(async () => {
  mongod = await MongoMemoryServer.create();
  await mongoose.connect(mongod.getUri());
});

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

/** Records every S3 verb the processor uses, and answers GETs with the fixture. */
function mockS3(options: { body?: Uint8Array } = {}) {
  const puts: { key: string; size: number }[] = [];
  const copies: { from: string; to: string }[] = [];
  const gets: string[] = [];
  vi.spyOn(s3Client, 'send').mockImplementation((async (cmd: {
    constructor: { name: string };
    input: { Key?: string; Body?: Uint8Array; CopySource?: string };
  }) => {
    switch (cmd.constructor.name) {
      case 'GetObjectCommand':
        gets.push(cmd.input.Key as string);
        return {
          Body: {
            transformToByteArray: async () => options.body ?? FIXTURE,
          },
          ContentType: 'model/gltf-binary',
        };
      case 'PutObjectCommand':
        puts.push({
          key: cmd.input.Key as string,
          size: (cmd.input.Body as Uint8Array).byteLength,
        });
        return {};
      case 'CopyObjectCommand':
        copies.push({
          from: decodeURI(cmd.input.CopySource as string),
          to: cmd.input.Key as string,
        });
        return {};
      default:
        return {};
    }
  }) as never);
  return { puts, copies, gets };
}

/**
 * A claimed optimization job + its OPT record + the SOURCE record it derives
 * from, wired the way the worker loop leaves them.
 */
async function seed(
  sourceOverrides: Partial<IProjectModel> = {},
  optOverrides: Partial<IProjectModel> = {}
) {
  const userId = new Types.ObjectId();
  const project = await Project.create({
    userId,
    name: 'P',
    objectSize: 'MEDIUM',
    mode: 'GUIDED',
    status: 'PROCESSING',
  });
  const captureJobId = new Types.ObjectId();
  const prefix = buildJobKeyPrefix({
    userId: userId.toHexString(),
    projectId: project.id as string,
    jobId: captureJobId.toHexString(),
  });
  await Job.create({
    _id: captureJobId,
    projectId: project._id,
    userId,
    state: 'QUEUED',
    upload: {
      uploadMethod: 'S3_PRESIGNED_MULTIPART',
      expectedFilesCount: 3,
      uploadedFilesCount: 3,
      checksumAlgo: 'md5',
      rawBucket: 'recapture-test-raw',
      rawPrefix: prefix,
      manifestKey: `${prefix}capture_manifest.json`,
    },
  });

  const sourceId = new Types.ObjectId();
  const sourcePrefix = `${prefix}models/${sourceId.toHexString()}/`;
  const source = await ProjectModel.create({
    _id: sourceId,
    projectId: project._id,
    jobId: captureJobId,
    source: 'meshy',
    status: 'SUCCEEDED',
    selectedKeys: ['images/EYE/a.jpg'],
    createdByUserId: userId,
    createdByRole: 'MODEL_ARTIST',
    artifacts: {
      glbKey: `${sourcePrefix}model.glb`,
      usdzKey: `${sourcePrefix}model.usdz`,
      previewImageKey: `${sourcePrefix}preview.jpg`,
      glbBytes: FIXTURE.byteLength,
      cdnUrls: {
        glb: `https://cdn.example/${sourcePrefix}model.glb`,
        usdz: `https://cdn.example/${sourcePrefix}model.usdz`,
        preview: `https://cdn.example/${sourcePrefix}preview.jpg`,
      },
    },
    ...sourceOverrides,
  });

  const record = await ProjectModel.create({
    projectId: project._id,
    jobId: captureJobId,
    source: 'optimized',
    status: 'QUEUED',
    selectedKeys: [],
    optimizedFrom: source._id,
    createdByUserId: userId,
    createdByRole: 'USER',
    ...optOverrides,
  });

  const optJob = await Job.create({
    projectId: project._id,
    userId,
    jobType: 'MODEL_OPTIMIZATION',
    state: 'PROCESSING',
    claimedBy: WORKER_ID,
    claimedAt: new Date(),
    payload: { modelId: record.id as string },
  });

  const workerJob: WorkerJob = {
    _id: optJob._id as Types.ObjectId,
    projectId: project._id as Types.ObjectId,
    userId,
    state: 'PROCESSING',
    jobType: 'MODEL_OPTIMIZATION',
    claimedBy: WORKER_ID,
    attempts: 0,
    maxAttempts: 3,
    payload: { modelId: record.id as string },
    createdAt: new Date(),
    updatedAt: new Date(),
  };

  return { workerJob, record, source, prefix, sourcePrefix };
}

describe('modelOptimizationProcessor — happy path', () => {
  it('writes a SMALLER GLB under the OPT record’s own prefix', async () => {
    const s3 = mockS3();
    const { workerJob, record, source, prefix } = await seed();

    await modelOptimizationProcessor(workerJob);

    const optPrefix = `${prefix}models/${record.id}/`;
    const glbPut = s3.puts.find((p) => p.key === `${optPrefix}model.glb`);
    expect(glbPut).toBeDefined();
    // The claim the whole feature rests on.
    expect(glbPut!.size).toBeLessThan(FIXTURE.byteLength);
    // Its OWN prefix — never the source's.
    expect(s3.puts.every((p) => !p.key.startsWith(`${prefix}models/${source.id}/`))).toBe(
      true
    );

    const saved = await ProjectModel.findById(record._id).exec();
    expect(saved!.status).toBe('SUCCEEDED');
    expect(saved!.artifacts?.glbKey).toBe(`${optPrefix}model.glb`);
    expect(saved!.artifacts?.glbBytes).toBe(glbPut!.size);
    expect(saved!.optimization?.sourceBytes).toBe(FIXTURE.byteLength);
    expect(saved!.optimization?.outputBytes).toBe(glbPut!.size);
    // Only OUR CloudFront URLs are ever persisted.
    expect(saved!.artifacts?.cdnUrls.glb).toContain(optPrefix);
    // Live progress is cleared on a terminal status.
    expect(saved!.progress).toBeUndefined();
  });

  it('COPIES the source preview and USDZ so the row keeps its thumbnail and AR', async () => {
    const s3 = mockS3();
    const { workerJob, record, prefix, sourcePrefix } = await seed();

    await modelOptimizationProcessor(workerJob);

    const optPrefix = `${prefix}models/${record.id}/`;
    expect(s3.copies).toEqual(
      expect.arrayContaining([
        expect.objectContaining({ to: `${optPrefix}preview.jpg` }),
        expect.objectContaining({ to: `${optPrefix}model.usdz` }),
      ])
    );
    expect(s3.copies[0]!.from).toContain(sourcePrefix);

    const saved = await ProjectModel.findById(record._id).exec();
    // latestSucceededModel now returns THIS record; without these the iOS AR
    // path and the project thumbnail would silently die on first optimize.
    expect(saved!.artifacts?.usdzKey).toBe(`${optPrefix}model.usdz`);
    expect(saved!.artifacts?.previewImageKey).toBe(`${optPrefix}preview.jpg`);
    expect(saved!.artifacts?.cdnUrls.usdz).toBeTruthy();
    expect(saved!.artifacts?.cdnUrls.preview).toBeTruthy();
  });

  it('leaves the SOURCE record untouched', async () => {
    mockS3();
    const { workerJob, source } = await seed();
    // Field ORDER differs between a freshly-created document and a re-read one,
    // so compare the values that matter rather than the serialized blob.
    const before = {
      status: source.status,
      artifacts: JSON.parse(JSON.stringify(source.artifacts)),
      updatedAt: source.updatedAt.toISOString(),
    };

    await modelOptimizationProcessor(workerJob);

    const after = await ProjectModel.findById(source._id).exec();
    expect({
      status: after!.status,
      artifacts: JSON.parse(JSON.stringify(after!.artifacts)),
      updatedAt: after!.updatedAt.toISOString(),
    }).toEqual(before);
    // And it must not have acquired optimization fields of its own.
    expect(after!.optimizedFrom).toBeUndefined();
    expect(after!.optimization).toBeUndefined();
  });

  it('omits the optional artifacts the source did not have', async () => {
    const s3 = mockS3();
    // A GLB-only source: no USDZ, no preview to copy.
    const bare = 'legacy/prefix/';
    const { workerJob, record, prefix } = await seed({
      artifacts: {
        glbKey: `${bare}model.glb`,
        glbBytes: FIXTURE.byteLength,
        cdnUrls: { glb: `https://cdn.example/${bare}model.glb` },
      },
    });

    await modelOptimizationProcessor(workerJob);

    expect(s3.copies).toHaveLength(0);
    const saved = await ProjectModel.findById(record._id).exec();
    expect(saved!.status).toBe('SUCCEEDED');
    expect(saved!.artifacts?.usdzKey).toBeUndefined();
    expect(saved!.artifacts?.previewImageKey).toBeUndefined();
    expect(saved!.artifacts?.glbKey).toBe(`${prefix}models/${record.id}/model.glb`);
  });
});

describe('modelOptimizationProcessor — terminal failures', () => {
  it('rejects a non-win rather than adding a duplicate row', async () => {
    mockS3();
    const { workerJob, record } = await seed();

    // The 95% gate is PROCESSOR logic, so the optimizer is stubbed to land
    // exactly inside the band. Its real compression is asserted separately
    // below — driving this branch with a real model would mean finding one that
    // happens to be incompressible, which is a fixture that rots.
    vi.spyOn(optimizerModule, 'optimizeGlb').mockResolvedValue({
      bytes: FIXTURE.slice(0, Math.floor(FIXTURE.byteLength * 0.97)),
      inputBytes: FIXTURE.byteLength,
      outputBytes: Math.floor(FIXTURE.byteLength * 0.97),
      overBudget: false,
      localBboxLongestAxis: 0.4,
      degraded: [],
    });

    await expect(modelOptimizationProcessor(workerJob)).rejects.toThrow(
      NonRetryableJobError
    );

    const saved = await ProjectModel.findById(record._id).exec();
    expect(saved!.status).toBe('FAILED');
    expect(saved!.error?.code).toBe('OPTIMIZATION_INEFFECTIVE');
    expect(saved!.error?.message).toBe('This model is already close to its smallest size.');
    // Nothing was written — a 3%-smaller duplicate is clutter, not a feature.
    expect(saved!.artifacts).toBeUndefined();
  });

  it('fails terminally when the source model is gone', async () => {
    mockS3();
    const { workerJob, record, source } = await seed();
    await ProjectModel.deleteOne({ _id: source._id }).exec();

    await expect(modelOptimizationProcessor(workerJob)).rejects.toThrow(
      NonRetryableJobError
    );
    const saved = await ProjectModel.findById(record._id).exec();
    expect(saved!.status).toBe('FAILED');
    expect(saved!.error?.code).toBe('OPTIMIZE_SOURCE_MISSING');
  });

  it('fails terminally on a malformed payload', async () => {
    const { workerJob } = await seed();
    await expect(
      modelOptimizationProcessor({ ...workerJob, payload: {} })
    ).rejects.toThrow(NonRetryableJobError);
  });

  it('never puts an S3 key or a URL into the persisted error message', async () => {
    mockS3();
    const { workerJob, record, source, sourcePrefix } = await seed();
    await ProjectModel.deleteOne({ _id: source._id }).exec();

    await expect(modelOptimizationProcessor(workerJob)).rejects.toThrow();
    const saved = await ProjectModel.findById(record._id).exec();
    const message = saved!.error?.message ?? '';
    // This string is persisted, logged and RENDERED. A key or a presigned URL
    // in it is a leak that outlives the request.
    expect(message).not.toBe('');
    expect(message).not.toContain(sourcePrefix);
    expect(message).not.toContain('http');
  });
});

describe('optimizeGlb', () => {
  it('shrinks a real GLB and reports the numbers', async () => {
    const result = await optimizeGlb(FIXTURE, {
      maxInputBytes: env.MODEL_OPTIMIZE_MAX_INPUT_BYTES,
      budgetBytes: env.MODEL_OPTIMIZE_THRESHOLD_BYTES,
    });

    expect(result.inputBytes).toBe(FIXTURE.byteLength);
    expect(result.outputBytes).toBeLessThan(result.inputBytes);
    expect(result.overBudget).toBe(false);
    // Measured BEFORE meshopt quantizes the positions, so it still describes
    // the source geometry.
    expect(result.localBboxLongestAxis).toBeGreaterThan(0);
    expect(result.degraded).toEqual([]);
  });

  it('emits EXT_meshopt_compression as REQUIRED — the client must have a decoder', async () => {
    const { bytes } = await optimizeGlb(FIXTURE, {
      maxInputBytes: env.MODEL_OPTIMIZE_MAX_INPUT_BYTES,
      budgetBytes: env.MODEL_OPTIMIZE_THRESHOLD_BYTES,
    });
    const json = Buffer.from(bytes).toString('latin1');
    // This is WHY web/index.html and _lifecycleJs must set
    // meshoptDecoderLocation. If this assertion ever stops holding, that
    // configuration is no longer load-bearing — and if it holds while the
    // configuration is missing, every optimized model fails to load.
    expect(json).toContain('extensionsRequired');
    expect(json).toContain('EXT_meshopt_compression');
  });

  it('reports overBudget against the budget it was GIVEN, not a hardcoded one', async () => {
    const result = await optimizeGlb(FIXTURE, {
      maxInputBytes: env.MODEL_OPTIMIZE_MAX_INPUT_BYTES,
      budgetBytes: 1,
    });
    expect(result.overBudget).toBe(true);
  });

  it('refuses an oversized input BEFORE parsing it', async () => {
    await expect(
      optimizeGlb(FIXTURE, { maxInputBytes: 10, budgetBytes: 1024 })
    ).rejects.toMatchObject({
      name: 'ModelOptimizeError',
      code: ModelOptimizeErrorCode.INPUT_TOO_LARGE,
    });
  });

  it('rejects bytes that are not a GLB, with a user-safe message', async () => {
    const notAGlb = new Uint8Array([1, 2, 3, 4, 5, 6, 7, 8]);
    const err = await optimizeGlb(notAGlb, {
      maxInputBytes: env.MODEL_OPTIMIZE_MAX_INPUT_BYTES,
      budgetBytes: 1024,
    }).catch((e: unknown) => e);

    expect(err).toBeInstanceOf(ModelOptimizeError);
    // The upstream parser error may quote buffer contents — it must not
    // propagate into something we persist and render.
    expect((err as Error).message).toBe('This model could not be read for optimization.');
  });

  it('still produces a valid document when `sharp` cannot load', async () => {
    // A Render image that resolved the wrong native variant has a `sharp` that
    // throws on import. That must degrade to "textures untouched", not fail the
    // whole feature: the mesh passes are most of the win and need no native code.
    vi.doMock('sharp', () => {
      throw new Error('Could not load the sharp module');
    });
    vi.resetModules();
    const { optimizeGlb: freshOptimize } = await import('@/services/modelOptimizerService');

    const result = await freshOptimize(FIXTURE, {
      maxInputBytes: env.MODEL_OPTIMIZE_MAX_INPUT_BYTES,
      budgetBytes: env.MODEL_OPTIMIZE_THRESHOLD_BYTES,
    });

    expect(result.degraded).toEqual(['texture-compress-unavailable']);
    expect(result.outputBytes).toBeGreaterThan(0);
    // Still a real, re-readable GLB — just a bigger one.
    expect(Buffer.from(result.bytes.slice(0, 4)).toString('latin1')).toBe('glTF');

    vi.doUnmock('sharp');
    vi.resetModules();
  });
});
