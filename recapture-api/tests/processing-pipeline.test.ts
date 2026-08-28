// tests/processing-pipeline.test.ts
//
// The processing-pipeline stage machine (QUEUED → PROCESSING → TEXTURING →
// OPTIMIZING → COMPLETED, any active → FAILED) end to end: pure transition
// rules, per-transition atomic persistence (stage/progress/timestamps/
// outputs/artifacts), resume-from-persisted-stage (crash recovery AND the
// retry policy), the claimedBy/CANCELED write fences, and concurrency across
// jobs. Hermetic: in-memory MongoDB, S3 scripted on the shared client, and
// the reconstruction engine swapped through its test seam.
import { describe, it, expect, beforeAll, afterAll, afterEach, vi } from 'vitest';
import mongoose, { Types } from 'mongoose';
import { MongoMemoryServer } from 'mongodb-memory-server';

import { s3Client } from '@/config/s3';
import { Job, type IJob } from '@/models/Job';
import {
  setReconstructionEngine,
  stubReconstructionEngine,
  type EngineStageInput,
  type ReconstructionEngine,
} from '@/worker/engine/reconstructionEngine';
import { markCompleted } from '@/worker/jobQueue';
import {
  canTransition,
  InvalidStageTransitionError,
  nextStage,
  resumeStageFor,
  stagesFrom,
} from '@/worker/processingStages';
import { registerProcessor } from '@/worker/processorRegistry';
import { captureProcessingProcessor } from '@/worker/processors/captureProcessingProcessor';
import { enterStage, recordStageProgress } from '@/worker/stageTransitions';
import { startWorker } from '@/worker/worker';
import {
  ClaimLostError,
  DEFAULT_JOB_TYPE,
  NonRetryableJobError,
  type WorkerConfig,
} from '@/worker/workerTypes';

let mongod: MongoMemoryServer;

beforeAll(async () => {
  mongod = await MongoMemoryServer.create();
  await mongoose.connect(mongod.getUri());
  await Job.syncIndexes();
  registerProcessor(DEFAULT_JOB_TYPE, captureProcessingProcessor);
});

afterAll(async () => {
  await mongoose.disconnect();
  await mongod.stop();
});

afterEach(async () => {
  await Job.deleteMany({});
  vi.restoreAllMocks();
  setReconstructionEngine(null); // restore the stub
});

// ── Helpers (same patterns as tests/processing-worker.test.ts) ───────────────

const RAW_BUCKET = 'test-raw-bucket';
const RAW_PREFIX = 'dev/u1/p1/j1/';
const MANIFEST_KEY = `${RAW_PREFIX}capture_manifest.json`;

function makeQueuedJob(overrides: Partial<IJob> = {}): Promise<IJob> {
  return Job.create({
    projectId: new Types.ObjectId(),
    userId: new Types.ObjectId(),
    state: 'QUEUED',
    captureVariant: 'with_bottom',
    upload: {
      uploadMethod: 'S3_PRESIGNED_MULTIPART',
      expectedFilesCount: 49,
      uploadedFilesCount: 49,
      checksumAlgo: 'md5',
      rawBucket: RAW_BUCKET,
      rawPrefix: RAW_PREFIX,
      manifestKey: MANIFEST_KEY,
    },
    ...overrides,
  });
}

function validManifestBody(): string {
  const photos = ['EYE', 'TOP', 'LOW'].flatMap((ring) =>
    Array.from({ length: 16 }, (_, i) => ({ photoId: `${ring}_${i}`, ringName: ring }))
  );
  return JSON.stringify({
    flowVariant: 'with_bottom',
    summary: { totalPhotos: photos.length, warningsCount: 0, overallComplete: true },
    photos,
  });
}

/** Scripts every S3 call the validation stage makes as a healthy bundle. */
function mockValidS3() {
  const impl = async (cmd: { constructor: { name: string }; input: Record<string, unknown> }) => {
    switch (cmd.constructor.name) {
      case 'GetObjectCommand':
        return { Body: { transformToString: async () => validManifestBody() } };
      case 'ListObjectsV2Command':
        return {
          Contents: Array.from({ length: 49 }, (_, i) => ({
            Key: `${cmd.input.Prefix as string}f_${i}.jpg`,
          })),
          IsTruncated: false,
        };
      default:
        throw new Error(`unexpected S3 command: ${cmd.constructor.name}`);
    }
  };
  return vi.spyOn(s3Client, 'send').mockImplementation(impl as never);
}

/**
 * An injectable engine whose stages are overridable and call-counted.
 * Defaults delegate to the stub (which emits progress milestones).
 */
function makeEngine(overrides: Partial<ReconstructionEngine> = {}) {
  const calls = { reconstruct: 0, texture: 0, optimize: 0 };
  const engine: ReconstructionEngine = {
    reconstruct: (input) => {
      calls.reconstruct++;
      return (overrides.reconstruct ?? stubReconstructionEngine.reconstruct)(input);
    },
    texture: (input) => {
      calls.texture++;
      return (overrides.texture ?? stubReconstructionEngine.texture)(input);
    },
    optimize: (input) => {
      calls.optimize++;
      return (overrides.optimize ?? stubReconstructionEngine.optimize)(input);
    },
  };
  return { engine, calls };
}

async function withWorker(
  overrides: Partial<WorkerConfig>,
  fn: () => Promise<void>
): Promise<void> {
  const ac = new AbortController();
  const done = startWorker({
    pollIntervalMs: 15,
    claimTimeoutMs: 120_000,
    concurrency: 2,
    workerId: 'worker-pipeline-test',
    heartbeatEveryNPolls: 1_000_000,
    stopSignal: ac.signal,
    ...overrides,
  });
  try {
    await fn();
  } finally {
    ac.abort();
    await done;
  }
}

async function waitFor(predicate: () => Promise<boolean>, what: string): Promise<void> {
  const deadline = Date.now() + 10_000;
  while (Date.now() < deadline) {
    if (await predicate()) return;
    await new Promise((r) => setTimeout(r, 20));
  }
  throw new Error(`Timed out waiting for: ${what}`);
}

const inState = (id: Types.ObjectId, state: string) => async () => {
  const j = await Job.findById(id).lean();
  return j?.state === state;
};

// ── Pure stage machine ───────────────────────────────────────────────────────

describe('processingStages: pure transition rules', () => {
  it('allows exactly the sequential forward chain', () => {
    expect(canTransition('QUEUED', 'PROCESSING')).toBe(true);
    expect(canTransition('PROCESSING', 'TEXTURING')).toBe(true);
    expect(canTransition('TEXTURING', 'OPTIMIZING')).toBe(true);
    expect(canTransition('OPTIMIZING', 'COMPLETED')).toBe(true);
  });

  it('rejects skipping, backward moves, and self transitions', () => {
    expect(canTransition('QUEUED', 'TEXTURING')).toBe(false); // skip
    expect(canTransition('PROCESSING', 'OPTIMIZING')).toBe(false); // skip
    expect(canTransition('PROCESSING', 'COMPLETED')).toBe(false); // skip
    expect(canTransition('OPTIMIZING', 'TEXTURING')).toBe(false); // backward
    expect(canTransition('COMPLETED', 'PROCESSING')).toBe(false); // backward
    expect(canTransition('TEXTURING', 'TEXTURING')).toBe(false); // self
  });

  it('allows FAILED from every stage except COMPLETED', () => {
    expect(canTransition('QUEUED', 'FAILED')).toBe(true);
    expect(canTransition('PROCESSING', 'FAILED')).toBe(true);
    expect(canTransition('TEXTURING', 'FAILED')).toBe(true);
    expect(canTransition('OPTIMIZING', 'FAILED')).toBe(true);
    expect(canTransition('COMPLETED', 'FAILED')).toBe(false);
  });

  it('nextStage walks the chain and dead-ends at COMPLETED', () => {
    expect(nextStage('QUEUED')).toBe('PROCESSING');
    expect(nextStage('OPTIMIZING')).toBe('COMPLETED');
    expect(nextStage('COMPLETED')).toBeNull();
  });

  it('resumeStageFor: fresh jobs enter PROCESSING, in-flight jobs re-enter their stage', () => {
    expect(resumeStageFor(undefined)).toBe('PROCESSING');
    expect(resumeStageFor({ stage: 'QUEUED', percent: 0 })).toBe('PROCESSING');
    expect(resumeStageFor({ stage: 'TEXTURING', percent: 40 })).toBe('TEXTURING');
    expect(resumeStageFor({ stage: 'OPTIMIZING', percent: 10 })).toBe('OPTIMIZING');
  });

  it('stagesFrom returns the remaining executable stages in order', () => {
    expect(stagesFrom('PROCESSING')).toEqual(['PROCESSING', 'TEXTURING', 'OPTIMIZING']);
    expect(stagesFrom('OPTIMIZING')).toEqual(['OPTIMIZING']);
  });
});

// ── Happy path ───────────────────────────────────────────────────────────────

describe('pipeline: happy path through all stages', () => {
  it('runs PROCESSING→TEXTURING→OPTIMIZING→COMPLETED persisting each transition', async () => {
    mockValidS3();
    const { engine, calls } = makeEngine();
    setReconstructionEngine(engine);
    const job = await makeQueuedJob();

    await withWorker({}, async () => {
      await waitFor(inState(job._id as Types.ObjectId, 'COMPLETED'), 'job COMPLETED');
    });

    const done = await Job.findById(job._id).lean();
    expect(done?.state).toBe('COMPLETED');
    expect(done?.stageProgress).toMatchObject({ stage: 'COMPLETED', percent: 100 });
    expect(calls).toEqual({ reconstruct: 1, texture: 1, optimize: 1 });

    // Every executable stage got a start/end window, in pipeline order.
    const ts = done!.stageTimestamps!;
    for (const stage of ['PROCESSING', 'TEXTURING', 'OPTIMIZING'] as const) {
      expect(ts[stage]?.startedAt).toBeInstanceOf(Date);
      expect(ts[stage]?.completedAt).toBeInstanceOf(Date);
      expect(ts[stage]!.completedAt!.getTime()).toBeGreaterThanOrEqual(
        ts[stage]!.startedAt!.getTime()
      );
    }
    expect(ts.TEXTURING!.startedAt!.getTime()).toBeGreaterThanOrEqual(
      ts.PROCESSING!.startedAt!.getTime()
    );
    expect(ts.OPTIMIZING!.startedAt!.getTime()).toBeGreaterThanOrEqual(
      ts.TEXTURING!.startedAt!.getTime()
    );

    // Each stage's engine output persisted; artifacts recorded on completion.
    expect(Object.keys(done!.stageOutputs!)).toEqual(
      expect.arrayContaining(['PROCESSING', 'TEXTURING', 'OPTIMIZING'])
    );
    expect(done?.artifacts?.glbKey).toBe(`${RAW_PREFIX}model.glb`);
    expect(done?.artifacts?.cdnUrls?.glb).toBe(`https://test.cloudfront.net/${RAW_PREFIX}model.glb`);
    expect(done?.result).toMatchObject({
      pipeline: 'engine',
      entryStage: 'PROCESSING',
      stagesRun: ['PROCESSING', 'TEXTURING', 'OPTIMIZING'],
    });
    expect(done?.error).toBeUndefined();
    expect(done?.attempts).toBe(0); // no failures consumed
  });

  it('status is client-queryable and accurate WHILE a stage runs', async () => {
    mockValidS3();
    let releaseTexture!: () => void;
    const gate = new Promise<void>((r) => (releaseTexture = r));
    const textureEntered = new Promise<void>((enter) => {
      const { engine } = makeEngine({
        texture: async (input: EngineStageInput) => {
          await input.onProgress(30);
          enter();
          await gate; // hold the job in TEXTURING until the test looked
          return { texturedMeshRef: 'x' };
        },
      });
      setReconstructionEngine(engine);
    });
    const job = await makeQueuedJob();

    await withWorker({}, async () => {
      await textureEntered;
      const mid = await Job.findById(job._id).lean();
      expect(mid?.state).toBe('TEXTURING');
      expect(mid?.stageProgress).toMatchObject({ stage: 'TEXTURING', percent: 30 });
      // PROCESSING already durably closed: window + output persisted.
      expect(mid?.stageTimestamps?.PROCESSING?.completedAt).toBeInstanceOf(Date);
      expect(mid?.stageOutputs?.PROCESSING).toBeDefined();
      expect(mid?.completedAt).toBeNull();

      releaseTexture();
      await waitFor(inState(job._id as Types.ObjectId, 'COMPLETED'), 'job COMPLETED');
    });
  });

  it('processes multiple jobs concurrently and independently', async () => {
    mockValidS3();
    const a = await makeQueuedJob();
    const b = await makeQueuedJob({ upload: undefined }); // malformed → early FAILED

    await withWorker({ concurrency: 2 }, async () => {
      await waitFor(inState(a._id as Types.ObjectId, 'COMPLETED'), 'job A COMPLETED');
      await waitFor(inState(b._id as Types.ObjectId, 'FAILED'), 'job B FAILED');
    });

    expect((await Job.findById(a._id).lean())?.stageProgress?.stage).toBe('COMPLETED');
    const failed = await Job.findById(b._id).lean();
    expect(failed?.error?.code).toBe('MANIFEST_MISSING'); // clear early error, no crash
    expect(failed?.stageProgress).toBeUndefined(); // pipeline never entered
  });
});

// ── Transition enforcement (DB-level) ────────────────────────────────────────

describe('stageTransitions: enforcement', () => {
  it('rejects entering a stage out of order (TEXTURING/OPTIMIZING before PROCESSING)', async () => {
    const job = await makeQueuedJob({ state: 'PROCESSING', claimedBy: 'w1', claimedAt: new Date() });

    // Advance-mode skip is rejected by the pure machine before any IO.
    await expect(
      enterStage(job._id as Types.ObjectId, 'w1', 'OPTIMIZING', {
        stage: 'PROCESSING',
        output: {},
      })
    ).rejects.toBeInstanceOf(InvalidStageTransitionError);

    // Entry-mode into a stage the durable pointer never reached loses the
    // fenced write and is rejected too.
    await expect(
      enterStage(job._id as Types.ObjectId, 'w1', 'TEXTURING')
    ).rejects.toBeInstanceOf(InvalidStageTransitionError);

    // The job was left untouched by both rejected attempts.
    const untouched = await Job.findById(job._id).lean();
    expect(untouched?.state).toBe('PROCESSING');
    expect(untouched?.stageProgress).toBeUndefined();
  });

  it('fenced writes from a worker that lost its claim throw ClaimLostError and change nothing', async () => {
    const job = await makeQueuedJob({
      state: 'TEXTURING',
      claimedBy: 'thief',
      claimedAt: new Date(),
      stageProgress: { stage: 'TEXTURING', percent: 10 },
    });

    await expect(
      recordStageProgress(job._id as Types.ObjectId, 'original-owner', 'TEXTURING', 55)
    ).rejects.toBeInstanceOf(ClaimLostError);
    await expect(
      enterStage(job._id as Types.ObjectId, 'original-owner', 'OPTIMIZING', {
        stage: 'TEXTURING',
        output: {},
      })
    ).rejects.toBeInstanceOf(ClaimLostError);

    const untouched = await Job.findById(job._id).lean();
    expect(untouched?.stageProgress).toMatchObject({ stage: 'TEXTURING', percent: 10 });
    expect(untouched?.state).toBe('TEXTURING');
  });

  it('markCompleted can never resurrect a CANCELED job', async () => {
    const job = await makeQueuedJob({ state: 'CANCELED', claimedBy: 'w1' });
    const flipped = await markCompleted(job._id as Types.ObjectId, { ok: true }, 'w1');
    expect(flipped).toBe(false);
    expect((await Job.findById(job._id).lean())?.state).toBe('CANCELED');
  });
});

// ── Failure, retry policy, bounded attempts ──────────────────────────────────

describe('pipeline: stage failure and bounded retry-from-failed-stage', () => {
  it('engine error in TEXTURING → re-queued (stage pointer kept), then resumes AT TEXTURING and finally FAILED with {stage, error}', async () => {
    mockValidS3();
    const { engine, calls } = makeEngine({
      texture: async () => {
        throw new Error('texturing exploded');
      },
    });
    setReconstructionEngine(engine);
    const job = await makeQueuedJob({ maxAttempts: 2 });

    await withWorker({}, async () => {
      // Attempt 1: PROCESSING succeeds, TEXTURING fails → back to QUEUED.
      await waitFor(async () => {
        const j = await Job.findById(job._id).lean();
        return j?.state === 'QUEUED' && j.attempts === 1;
      }, 'first failure re-queued');

      const retried = await Job.findById(job._id).lean();
      expect(retried?.lastError).toBe('texturing exploded');
      // Retry policy: the failed stage stays the durable entry point, and the
      // completed PROCESSING output is preserved for the resume.
      expect(retried?.stageProgress?.stage).toBe('TEXTURING');
      expect(retried?.stageOutputs?.PROCESSING).toBeDefined();
      expect(retried?.nextRetryAt).toBeInstanceOf(Date);

      // Attempt 2 (window forced open) exhausts maxAttempts → terminal FAILED.
      await Job.updateOne({ _id: job._id }, { $set: { nextRetryAt: new Date(Date.now() - 1) } });
      await waitFor(inState(job._id as Types.ObjectId, 'FAILED'), 'job FAILED');
    });

    const failed = await Job.findById(job._id).lean();
    expect(failed?.attempts).toBe(2); // bounded — no further retry
    expect(failed?.nextRetryAt).toBeNull();
    expect(failed?.error).toMatchObject({
      code: 'PROCESSING_FAILED',
      message: 'texturing exploded',
      stage: 'TEXTURING',
    });
    // Resume proof: reconstruction ran ONCE; texturing ran on both attempts.
    expect(calls.reconstruct).toBe(1);
    expect(calls.texture).toBe(2);
    expect(calls.optimize).toBe(0); // strict ordering — never reached
  });

  it('NonRetryableJobError from a stage → terminal FAILED immediately with its code and stage', async () => {
    mockValidS3();
    const { engine } = makeEngine({
      reconstruct: async () => {
        throw new NonRetryableJobError('INSUFFICIENT_COVERAGE', 'not enough parallax');
      },
    });
    setReconstructionEngine(engine);
    const job = await makeQueuedJob({ maxAttempts: 3 });

    await withWorker({}, async () => {
      await waitFor(inState(job._id as Types.ObjectId, 'FAILED'), 'job FAILED');
    });

    const failed = await Job.findById(job._id).lean();
    expect(failed?.attempts).toBe(1); // terminal despite maxAttempts 3
    expect(failed?.error).toMatchObject({
      code: 'INSUFFICIENT_COVERAGE',
      stage: 'PROCESSING',
    });
  });
});

// ── Crash recovery ───────────────────────────────────────────────────────────

describe('pipeline: crash recovery (stale claim, resume from persisted stage)', () => {
  it('re-claims a job orphaned mid-TEXTURING and resumes there without redoing PROCESSING', async () => {
    mockValidS3();
    const { engine, calls } = makeEngine();
    setReconstructionEngine(engine);

    // A worker died mid-TEXTURING: lease long expired, durable pointer and the
    // completed PROCESSING output still in place.
    const job = await makeQueuedJob({
      state: 'TEXTURING',
      claimedAt: new Date(Date.now() - 200_000),
      claimedBy: 'worker-crashed-instance',
      stageProgress: { stage: 'TEXTURING', percent: 40 },
      stageOutputs: { PROCESSING: { meshRef: 'kept-from-before-the-crash' } },
      startedAt: new Date(Date.now() - 210_000),
    });

    await withWorker({}, async () => {
      await waitFor(inState(job._id as Types.ObjectId, 'COMPLETED'), 'orphan resumed to COMPLETED');
    });

    const done = await Job.findById(job._id).lean();
    expect(done?.claimedBy).toBe('worker-pipeline-test');
    expect(done?.stageProgress).toMatchObject({ stage: 'COMPLETED', percent: 100 });
    // Resumed, not restarted: reconstruction was NOT re-run and its
    // pre-crash output survived; texturing re-ran idempotently.
    expect(calls).toEqual({ reconstruct: 0, texture: 1, optimize: 1 });
    expect(done?.stageOutputs?.PROCESSING).toEqual({ meshRef: 'kept-from-before-the-crash' });
    expect(done?.result).toMatchObject({ entryStage: 'TEXTURING', stagesRun: ['TEXTURING', 'OPTIMIZING'] });
    expect(done?.artifacts?.glbKey).toBeDefined();
  });
});

// ── Cancellation ─────────────────────────────────────────────────────────────

describe('pipeline: cancellation mid-stage', () => {
  it('an external CANCELED flip stops the pipeline at its next write; the job stays CANCELED with no error/attempt', async () => {
    mockValidS3();
    const { engine, calls } = makeEngine({
      texture: async (input: EngineStageInput) => {
        // The cancel endpoint (separate task) flips the state while the
        // engine is working…
        await Job.updateOne(
          { _id: new Types.ObjectId(input.jobId) },
          { $set: { state: 'CANCELED' } }
        ).exec();
        // …and the very next fenced write (progress) aborts the stage.
        await input.onProgress(50);
        throw new Error('unreachable — onProgress must throw JobCanceledError');
      },
    });
    setReconstructionEngine(engine);
    const job = await makeQueuedJob();

    await withWorker({}, async () => {
      await waitFor(inState(job._id as Types.ObjectId, 'CANCELED'), 'job CANCELED');
      // Give the loop time to (wrongly) resurrect it if the fences leaked.
      await new Promise((r) => setTimeout(r, 200));
    });

    const canceled = await Job.findById(job._id).lean();
    expect(canceled?.state).toBe('CANCELED'); // terminal — nothing resurrected it
    expect(canceled?.attempts).toBe(0); // cancellation is not a failure
    expect(canceled?.error).toBeUndefined();
    expect(canceled?.completedAt).toBeNull();
    expect(calls.optimize).toBe(0); // pipeline stopped — later stages never ran
  });
});
