// tests/meshy-model-processor.test.ts
//
// The MESHY_MODEL_GENERATION processor. The load-bearing test here is
// "resume-with-existing-meshyTaskId does NOT resubmit" — that assertion is the
// difference between a crash costing nothing and a crash costing a second paid
// generation.
//
// Hermetic: in-memory MongoDB, a fake meshyClient (CI never calls Meshy), a
// scripted S3 client, and a stubbed download. Presigning is left real — it signs
// locally with the test credentials and makes no network call.
import { describe, it, expect, beforeAll, afterAll, beforeEach, afterEach, vi } from 'vitest';
import mongoose, { Types } from 'mongoose';
import axios from 'axios';
import { MongoMemoryServer } from 'mongodb-memory-server';

import { env } from '@/config/env';
import { s3Client } from '@/config/s3';
import { Job } from '@/models/Job';
import { Project } from '@/models/Project';
import { ProjectModel, type IProjectModel } from '@/models/ProjectModel';
import { buildJobKeyPrefix } from '@/utils/s3Keys';
import { meshyModelProcessor } from '@/worker/processors/meshyModelProcessor';
import {
  MeshyErrorCode,
  meshyClient,
  setMeshyClient,
  type MeshyClient,
  type MeshyTask,
} from '@/worker/engine/meshy/meshyClient';
import { NonRetryableJobError, type WorkerJob } from '@/worker/workerTypes';

let mongod: MongoMemoryServer;
const WORKER_ID = 'worker-test-1';

beforeAll(async () => {
  mongod = await MongoMemoryServer.create();
  await mongoose.connect(mongod.getUri());
});

afterAll(async () => {
  await mongoose.disconnect();
  await mongod.stop();
  setMeshyClient(meshyClient);
});

beforeEach(() => {
  // Keep the poll loop instant — the real 5s cadence is an ops tunable, not
  // part of what these tests assert.
  // @ts-expect-error — env is a plain parsed object.
  env.MESHY_POLL_INTERVAL_MS = 1;
  vi.spyOn(console, 'log').mockImplementation(() => {});
});

afterEach(async () => {
  await Job.deleteMany({});
  await Project.deleteMany({});
  await ProjectModel.deleteMany({});
  vi.restoreAllMocks();
});

function task(overrides: Partial<MeshyTask> = {}): MeshyTask {
  return {
    id: 'task-1',
    status: 'SUCCEEDED',
    progress: 100,
    modelUrls: { glb: 'https://meshy.example/out.glb' },
    ...overrides,
  };
}

/** A fake transport that records what it was asked to do. */
function fakeClient(over: Partial<MeshyClient> = {}) {
  const create = vi.fn().mockResolvedValue({ taskId: 'task-1' });
  const get = vi.fn().mockResolvedValue(task());
  const cancel = vi.fn().mockResolvedValue(undefined);
  const client: MeshyClient = {
    createMultiImageTask: create,
    getTask: get,
    cancelTask: cancel,
    ...over,
  };
  setMeshyClient(client);
  return { create, get, cancel };
}

/** Captures every S3 PutObject key so re-hosting can be asserted. */
function mockS3(): string[] {
  const puts: string[] = [];
  vi.spyOn(s3Client, 'send').mockImplementation((async (cmd: {
    constructor: { name: string };
    input: { Key?: string };
  }) => {
    if (cmd.constructor.name === 'PutObjectCommand') puts.push(cmd.input.Key as string);
    return {};
  }) as never);
  vi.spyOn(axios, 'get').mockResolvedValue({ data: new ArrayBuffer(8) });
  return puts;
}

/**
 * A claimed generation job + its record, wired the way the worker loop leaves
 * them: the Job is PROCESSING and claimed by this worker.
 */
async function seed(
  recordOverrides: Partial<IProjectModel> = {}
): Promise<{ workerJob: WorkerJob; record: IProjectModel; prefix: string }> {
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

  const record = await ProjectModel.create({
    projectId: project._id,
    jobId: captureJobId,
    source: 'meshy',
    status: 'QUEUED',
    selectedKeys: ['images/EYE/a.jpg', 'images/EYE/b.jpg', 'images/TOP/c.jpg'],
    createdByUserId: new Types.ObjectId(),
    createdByRole: 'MODEL_ARTIST',
    ...recordOverrides,
  });

  const genJob = await Job.create({
    projectId: project._id,
    userId,
    jobType: 'MESHY_MODEL_GENERATION',
    state: 'PROCESSING',
    claimedBy: WORKER_ID,
    claimedAt: new Date(),
    payload: { modelId: record.id as string },
  });

  const workerJob: WorkerJob = {
    _id: genJob._id as Types.ObjectId,
    projectId: project._id as Types.ObjectId,
    userId,
    state: 'PROCESSING',
    jobType: 'MESHY_MODEL_GENERATION',
    claimedBy: WORKER_ID,
    attempts: 0,
    maxAttempts: 3,
    payload: { modelId: record.id as string },
    createdAt: new Date(),
    updatedAt: new Date(),
  };
  return { workerJob, record, prefix };
}

describe('meshyModelProcessor — happy path', () => {
  it('submits, re-hosts to our S3, and stores only CloudFront URLs', async () => {
    const { create, get } = fakeClient();
    const puts = mockS3();
    const { workerJob, record, prefix } = await seed();

    const result = await meshyModelProcessor(workerJob);

    expect(create).toHaveBeenCalledTimes(1);
    expect(get).toHaveBeenCalled();
    // Meshy fetches the sources itself via presigned GETs — one per selection.
    expect((create.mock.calls[0]![0] as string[])).toHaveLength(3);

    // Per-model prefix: a regenerate can never overwrite an earlier attempt.
    const modelPrefix = `${prefix}models/${record.id}/`;
    expect(puts).toEqual([`${modelPrefix}model.glb`]);

    const saved = await ProjectModel.findById(record.id).exec();
    expect(saved!.status).toBe('SUCCEEDED');
    expect(saved!.meshyTaskId).toBe('task-1');
    expect(saved!.artifacts!.glbKey).toBe(`${modelPrefix}model.glb`);
    expect(saved!.artifacts!.cdnUrls.glb).toBe(
      `${env.CLOUDFRONT_BASE_URL}/${modelPrefix}model.glb`
    );

    // Contract: Meshy's own (expiring) URL must never be persisted anywhere.
    const asJson = JSON.stringify(saved!.toObject());
    expect(asJson).not.toContain('meshy.example');
    expect(JSON.stringify(result)).not.toContain('meshy.example');
  });

  it('re-hosts the usdz and thumbnail when Meshy returns them', async () => {
    fakeClient({
      getTask: vi.fn().mockResolvedValue(
        task({
          modelUrls: { glb: 'https://meshy.example/o.glb', usdz: 'https://meshy.example/o.usdz' },
          thumbnailUrl: 'https://meshy.example/o.png',
        })
      ),
    });
    const puts = mockS3();
    const { workerJob, record, prefix } = await seed();

    await meshyModelProcessor(workerJob);

    // The poster is PNG because MESHY_PRESET sets alpha_thumbnail: true — the
    // filename and that flag are one decision, so this pins both.
    const p = `${prefix}models/${record.id}/`;
    expect(puts).toEqual([`${p}model.glb`, `${p}model.usdz`, `${p}preview.png`]);
    const saved = await ProjectModel.findById(record.id).exec();
    expect(saved!.artifacts!.usdzKey).toBe(`${p}model.usdz`);
    expect(saved!.artifacts!.previewImageKey).toBe(`${p}preview.png`);
    expect(saved!.artifacts!.cdnUrls.preview).toBe(
      `${env.CLOUDFRONT_BASE_URL}/${p}preview.png`
    );
  });

  it('polls until the task leaves PENDING/IN_PROGRESS, renewing the lease each tick', async () => {
    const get = vi
      .fn()
      .mockResolvedValueOnce(task({ status: 'PENDING', progress: 0 }))
      .mockResolvedValueOnce(task({ status: 'IN_PROGRESS', progress: 50 }))
      .mockResolvedValue(task());
    fakeClient({ getTask: get });
    mockS3();
    const { workerJob } = await seed();

    await meshyModelProcessor(workerJob);

    expect(get).toHaveBeenCalledTimes(3);
    // Each non-terminal poll persisted progress — which IS the lease renewal
    // that stops a long generation being re-claimed mid-flight.
    const job = await Job.findById(workerJob._id).exec();
    expect(job!.stageProgress!.stage).toBe('PROCESSING');
  });
});

describe('meshyModelProcessor — the money contract', () => {
  it('RESUMES an existing meshyTaskId instead of submitting a second (paid) task', async () => {
    const { create, get } = fakeClient();
    mockS3();
    // The state a crash / lease-takeover leaves behind: the task was already
    // created and paid for, and its id is on the record.
    const { workerJob, record } = await seed({
      meshyTaskId: 'already-paid-task',
      status: 'PROCESSING',
    } as Partial<IProjectModel>);

    await meshyModelProcessor(workerJob);

    // THE ASSERTION: no second generation was ever submitted.
    expect(create).not.toHaveBeenCalled();
    expect(get).toHaveBeenCalledWith('already-paid-task');

    const saved = await ProjectModel.findById(record.id).exec();
    expect(saved!.status).toBe('SUCCEEDED');
    expect(saved!.meshyTaskId).toBe('already-paid-task');
  });

  it('persists the task id before polling, so a crash mid-generation can resume', async () => {
    let idAtFirstPoll: string | undefined;
    const { workerJob, record } = await seed();
    fakeClient({
      getTask: vi.fn().mockImplementation(async () => {
        const live = await ProjectModel.findById(record.id).exec();
        idAtFirstPoll ??= live?.meshyTaskId;
        return task();
      }),
    });
    mockS3();

    await meshyModelProcessor(workerJob);

    // Already durable by the very first poll — not written at the end.
    expect(idAtFirstPoll).toBe('task-1');
  });

  it('a quota failure is terminal — the record fails and nothing retries', async () => {
    const quota = new NonRetryableJobError(
      MeshyErrorCode.QUOTA_EXHAUSTED,
      'Meshy rejected the request for insufficient credits.'
    );
    fakeClient({ createMultiImageTask: vi.fn().mockRejectedValue(quota) });
    mockS3();
    const { workerJob, record } = await seed();

    // Rethrown so the worker loop routes it to a terminal FAILED, no retry.
    await expect(meshyModelProcessor(workerJob)).rejects.toBeInstanceOf(NonRetryableJobError);

    const saved = await ProjectModel.findById(record.id).exec();
    expect(saved!.status).toBe('FAILED');
    expect(saved!.error!.code).toBe(MeshyErrorCode.QUOTA_EXHAUSTED);
  });

  it('a task reporting FAILED is terminal', async () => {
    fakeClient({
      getTask: vi.fn().mockResolvedValue(task({ status: 'FAILED', taskError: 'bad input' })),
    });
    mockS3();
    const { workerJob, record } = await seed();

    const err = await meshyModelProcessor(workerJob).catch((e: unknown) => e);

    expect(err).toBeInstanceOf(NonRetryableJobError);
    expect((err as NonRetryableJobError).code).toBe(MeshyErrorCode.GENERATION_FAILED);
    expect((await ProjectModel.findById(record.id).exec())!.status).toBe('FAILED');
  });

  it('SUCCEEDED with no GLB is terminal rather than a re-charging retry', async () => {
    fakeClient({ getTask: vi.fn().mockResolvedValue(task({ modelUrls: {} })) });
    mockS3();
    const { workerJob, record } = await seed();

    await expect(meshyModelProcessor(workerJob)).rejects.toBeInstanceOf(NonRetryableJobError);
    expect((await ProjectModel.findById(record.id).exec())!.status).toBe('FAILED');
  });
});

describe('meshyModelProcessor — retryable failures', () => {
  it('leaves the record PROCESSING when attempts remain, so the retry can resume', async () => {
    fakeClient({ getTask: vi.fn().mockRejectedValue(new Error('Meshy 503')) });
    mockS3();
    const { workerJob, record } = await seed();

    const err = await meshyModelProcessor(workerJob).catch((e: unknown) => e);

    // A plain Error routes to the worker's retry/backoff.
    expect(err).toBeInstanceOf(Error);
    expect(err).not.toBeInstanceOf(NonRetryableJobError);
    // NOT failed: the job will run again, and the truth is "still generating".
    const saved = await ProjectModel.findById(record.id).exec();
    expect(saved!.status).toBe('PROCESSING');
    // The id is on the record, so the retry resumes rather than re-submits.
    expect(saved!.meshyTaskId).toBe('task-1');
  });

  it('fails the record once the LAST attempt fails, so it cannot hang PROCESSING forever', async () => {
    fakeClient({ getTask: vi.fn().mockRejectedValue(new Error('Meshy 503')) });
    mockS3();
    const { workerJob, record } = await seed();
    // The worker is about to consume attempt 3 of 3 — nothing runs after this.
    workerJob.attempts = 2;
    workerJob.maxAttempts = 3;

    await expect(meshyModelProcessor(workerJob)).rejects.toThrow('Meshy 503');

    const saved = await ProjectModel.findById(record.id).exec();
    expect(saved!.status).toBe('FAILED');
    expect(saved!.error!.code).toBe('PROCESSING_FAILED');
  });
});

describe('meshyModelProcessor — malformed jobs', () => {
  it('is terminal when the job carries no modelId', async () => {
    fakeClient();
    const { workerJob } = await seed();
    workerJob.payload = {};

    await expect(meshyModelProcessor(workerJob)).rejects.toBeInstanceOf(NonRetryableJobError);
  });

  it('is terminal when the model record is gone', async () => {
    fakeClient();
    const { workerJob } = await seed();
    await ProjectModel.deleteMany({});

    await expect(meshyModelProcessor(workerJob)).rejects.toBeInstanceOf(NonRetryableJobError);
  });
});
