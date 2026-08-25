// tests/processing-worker.test.ts
//
// The CAPTURE_PROCESSING processor end-to-end through the worker loop:
// claim → manifest download → bundle validation → pipeline hand-off →
// COMPLETED, plus the failure classification — terminal validation failures
// (manifest missing/invalid, count drift) go straight to FAILED with a stable
// error code (never retried), while transient S3 errors take the retry/backoff
// path. Hermetic: in-memory MongoDB, S3 scripted on the shared client (same
// pattern as tests/jobs-finalize.test.ts).
import { describe, it, expect, beforeAll, afterAll, afterEach, vi } from 'vitest';
import mongoose, { Types } from 'mongoose';
import { MongoMemoryServer } from 'mongodb-memory-server';

import { s3Client } from '@/config/s3';
import { Job, type IJob } from '@/models/Job';
import { registerProcessor } from '@/worker/processorRegistry';
import { captureProcessingProcessor } from '@/worker/processors/captureProcessingProcessor';
import { startWorker } from '@/worker/worker';
import { DEFAULT_JOB_TYPE, type WorkerConfig } from '@/worker/workerTypes';

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
});

// ── Helpers ──────────────────────────────────────────────────────────────────

const RAW_BUCKET = 'test-raw-bucket';
const RAW_PREFIX = 'dev/u1/p1/j1/';
const MANIFEST_KEY = `${RAW_PREFIX}capture_manifest.json`;

/** A QUEUED with_bottom job expecting 49 objects (48 photos + manifest). */
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

/** Valid with_bottom manifest: 16 photos on each of EYE/TOP/LOW. */
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

type S3Script = {
  /** Manifest GET behavior: body string, 'absent' (404), or a thrown Error. */
  manifest: string | 'absent' | Error;
  /** How many objects the LIST under the prefix reports. */
  objectCount: number;
};

function mockS3(script: S3Script) {
  const impl = async (cmd: { constructor: { name: string }; input: Record<string, unknown> }) => {
    switch (cmd.constructor.name) {
      case 'GetObjectCommand': {
        if (script.manifest instanceof Error) throw script.manifest;
        if (script.manifest === 'absent') {
          throw Object.assign(new Error('NoSuchKey'), { name: 'NoSuchKey' });
        }
        const body = script.manifest;
        return { Body: { transformToString: async () => body } };
      }
      case 'ListObjectsV2Command': {
        const prefix = cmd.input.Prefix as string;
        return {
          Contents: Array.from({ length: script.objectCount }, (_, i) => ({
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

/** Runs the worker around `fn`, then stops it gracefully and awaits the drain. */
async function withWorker(
  overrides: Partial<WorkerConfig>,
  fn: () => Promise<void>
): Promise<void> {
  const ac = new AbortController();
  const done = startWorker({
    pollIntervalMs: 15,
    claimTimeoutMs: 120_000,
    concurrency: 2,
    workerId: 'worker-proc-test',
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

// ── Tests ────────────────────────────────────────────────────────────────────

describe('processing worker: valid bundle', () => {
  it('downloads + validates the manifest, runs the stage pipeline, completes', async () => {
    const spy = mockS3({ manifest: validManifestBody(), objectCount: 49 });
    const job = await makeQueuedJob();

    await withWorker({}, async () => {
      await waitFor(inState(job._id as Types.ObjectId, 'COMPLETED'), 'job COMPLETED');
    });

    const done = await Job.findById(job._id).lean();
    expect(done?.result).toMatchObject({ validated: true, filesVerified: 49, pipeline: 'engine' });
    expect(done?.stageProgress).toMatchObject({ stage: 'COMPLETED', percent: 100 });
    expect(done?.artifacts?.glbKey).toBe(`${RAW_PREFIX}model.glb`);
    expect(done?.startedAt).toBeInstanceOf(Date);
    expect(done?.claimedBy).toBe('worker-proc-test');
    expect(done?.error).toBeUndefined();

    // The manifest was fetched from the job's own bucket/key.
    const getCall = spy.mock.calls
      .map((c) => c[0] as { constructor: { name: string }; input: Record<string, unknown> })
      .find((c) => c.constructor.name === 'GetObjectCommand');
    expect(getCall?.input).toMatchObject({ Bucket: RAW_BUCKET, Key: MANIFEST_KEY });
  });
});

describe('processing worker: terminal validation failures (never retried)', () => {
  it('manifest gone from S3 → FAILED with MANIFEST_MISSING on the first attempt', async () => {
    mockS3({ manifest: 'absent', objectCount: 49 });
    const job = await makeQueuedJob({ maxAttempts: 3 });

    await withWorker({}, async () => {
      await waitFor(inState(job._id as Types.ObjectId, 'FAILED'), 'job FAILED');
    });

    const failed = await Job.findById(job._id).lean();
    expect(failed?.attempts).toBe(1); // terminal on attempt 1 despite maxAttempts 3
    expect(failed?.nextRetryAt).toBeNull();
    expect(failed?.error?.code).toBe('MANIFEST_MISSING');
  });

  it('object count drifted since finalize → FAILED with FILE_COUNT_MISMATCH', async () => {
    mockS3({ manifest: validManifestBody(), objectCount: 48 });
    const job = await makeQueuedJob();

    await withWorker({}, async () => {
      await waitFor(inState(job._id as Types.ObjectId, 'FAILED'), 'job FAILED');
    });

    const failed = await Job.findById(job._id).lean();
    expect(failed?.error?.code).toBe('FILE_COUNT_MISMATCH');
    expect(failed?.error?.message).toContain('Expected 49');
    expect(failed?.nextRetryAt).toBeNull();
  });

  it('manifest content breaks a rule → FAILED with MANIFEST_INVALID and rule ids in details', async () => {
    const bad = JSON.parse(validManifestBody()) as { summary: { totalPhotos: number } };
    bad.summary.totalPhotos = 99; // FILE_COUNT_MISMATCH content rule
    mockS3({ manifest: JSON.stringify(bad), objectCount: 49 });
    const job = await makeQueuedJob();

    await withWorker({}, async () => {
      await waitFor(inState(job._id as Types.ObjectId, 'FAILED'), 'job FAILED');
    });

    const failed = await Job.findById(job._id).lean();
    expect(failed?.error?.code).toBe('MANIFEST_INVALID');
    expect(failed?.error?.details).toContain('FILE_COUNT_MISMATCH');
    expect(failed?.result).toBeNull(); // pipeline was never started
  });

  it('unparseable manifest JSON → FAILED via the MANIFEST_UNREADABLE content rule', async () => {
    mockS3({ manifest: '{not json', objectCount: 49 });
    const job = await makeQueuedJob();

    await withWorker({}, async () => {
      await waitFor(inState(job._id as Types.ObjectId, 'FAILED'), 'job FAILED');
    });

    const failed = await Job.findById(job._id).lean();
    expect(failed?.error?.code).toBe('MANIFEST_INVALID');
    expect(failed?.error?.details).toContain('MANIFEST_UNREADABLE');
  });
});

describe('processing worker: transient failures (retried)', () => {
  it('a transient S3 error re-queues with backoff instead of failing terminally', async () => {
    mockS3({ manifest: new Error('S3 timeout'), objectCount: 49 });
    const job = await makeQueuedJob({ maxAttempts: 3 });

    await withWorker({}, async () => {
      await waitFor(async () => {
        const j = await Job.findById(job._id).lean();
        return j?.state === 'QUEUED' && j.attempts === 1;
      }, 'transient failure re-queued');
    });

    const retried = await Job.findById(job._id).lean();
    expect(retried?.lastError).toBe('S3 timeout');
    expect(retried?.nextRetryAt).toBeInstanceOf(Date);
    expect((retried!.nextRetryAt as Date).getTime()).toBeGreaterThan(Date.now());
    expect(retried?.error).toBeUndefined(); // not terminal — no error sub-doc
  });
});
