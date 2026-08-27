// tests/worker.test.ts
//
// Background worker (src/worker/): atomic claim, processor dispatch,
// retry/backoff, stale-claim recovery, unregistered-jobType terminal failure,
// and graceful drain. Hermetic: in-memory MongoDB, no API server, no S3.
//
// The worker loop is driven through its stopSignal seam (see workerTypes.ts)
// because tests can't emit real SIGTERM/SIGINT without tripping the test
// runner's own handlers.
import { describe, it, expect, beforeAll, afterAll, afterEach } from 'vitest';
import mongoose, { Types } from 'mongoose';
import { MongoMemoryServer } from 'mongodb-memory-server';

import { Job, type IJob } from '@/models/Job';
import { claimNextJob } from '@/worker/jobQueue';
import { registerProcessor } from '@/worker/processorRegistry';
import { startWorker, UNSUPPORTED_JOB_TYPE_CODE } from '@/worker/worker';
import type { WorkerConfig } from '@/worker/workerTypes';

let mongod: MongoMemoryServer;

beforeAll(async () => {
  mongod = await MongoMemoryServer.create();
  await mongoose.connect(mongod.getUri());
  await Job.syncIndexes();

  // One registry per process — register every jobType the suite needs up
  // front (re-registering a type throws by design).
  registerProcessor('TEST_OK', async () => ({ ok: true }));
  registerProcessor('TEST_FAIL', async () => {
    throw new Error('test failure');
  });
  registerProcessor('TEST_SLOW', async () => {
    await new Promise((r) => setTimeout(r, 200));
    return { slow: true };
  });
});

afterAll(async () => {
  await mongoose.disconnect();
  await mongod.stop();
});

afterEach(async () => {
  await Job.deleteMany({});
});

// ── Helpers ──────────────────────────────────────────────────────────────────

function makeJob(overrides: Partial<IJob> & { jobType: string }): Promise<IJob> {
  return Job.create({
    projectId: new Types.ObjectId(),
    userId: new Types.ObjectId(),
    state: 'QUEUED',
    ...overrides,
  });
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
    workerId: 'worker-test-1',
    heartbeatEveryNPolls: 1_000_000, // keep heartbeat noise out of test output
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

describe('worker: happy path', () => {
  it('claims a QUEUED job, processes it, and marks it COMPLETED', async () => {
    const job = await makeJob({ jobType: 'TEST_OK' });

    await withWorker({}, async () => {
      await waitFor(inState(job._id as Types.ObjectId, 'COMPLETED'), 'job COMPLETED');
    });

    const done = await Job.findById(job._id).lean();
    expect(done?.state).toBe('COMPLETED');
    expect(done?.result).toEqual({ ok: true });
    expect(done?.claimedBy).toBe('worker-test-1');
    expect(done?.startedAt).toBeInstanceOf(Date);
    expect(done?.completedAt).toBeInstanceOf(Date);
    expect(done?.lastError).toBeNull();
  });
});

describe('worker: retry and terminal failure', () => {
  it('re-queues with exponential-backoff nextRetryAt, then goes FAILED when attempts are exhausted', async () => {
    const job = await makeJob({ jobType: 'TEST_FAIL', maxAttempts: 2 });

    await withWorker({}, async () => {
      // Attempt 1 fails → back to QUEUED with a future retry window.
      await waitFor(async () => {
        const j = await Job.findById(job._id).lean();
        return j?.state === 'QUEUED' && j.attempts === 1;
      }, 'first failure re-queued');

      const retried = await Job.findById(job._id).lean();
      expect(retried?.lastError).toBe('test failure');
      expect(retried?.claimedAt).toBeNull();
      expect(retried?.claimedBy).toBeNull();
      // Backoff for attempt 1 is 1 minute.
      const delayMs = (retried!.nextRetryAt as Date).getTime() - Date.now();
      expect(delayMs).toBeGreaterThan(50_000);
      expect(delayMs).toBeLessThanOrEqual(60_000);

      // The job must NOT be claimable while nextRetryAt is in the future —
      // give the worker a few polls to (not) pick it up.
      await new Promise((r) => setTimeout(r, 150));
      expect((await Job.findById(job._id).lean())?.state).toBe('QUEUED');

      // Open the retry window; attempt 2 exhausts maxAttempts → FAILED.
      await Job.updateOne({ _id: job._id }, { $set: { nextRetryAt: new Date(Date.now() - 1) } });
      await waitFor(inState(job._id as Types.ObjectId, 'FAILED'), 'job FAILED after retries');
    });

    const failed = await Job.findById(job._id).lean();
    expect(failed?.attempts).toBe(2);
    expect(failed?.lastError).toBe('test failure');
    expect(failed?.nextRetryAt).toBeNull();
    expect(failed?.error?.code).toBe('PROCESSING_FAILED');
    expect(failed?.error?.message).toBe('test failure');
  });

  it('maxAttempts: 1 fails terminally on the first failure with no retry window', async () => {
    const job = await makeJob({ jobType: 'TEST_FAIL', maxAttempts: 1 });

    await withWorker({}, async () => {
      await waitFor(inState(job._id as Types.ObjectId, 'FAILED'), 'job FAILED immediately');
    });

    const failed = await Job.findById(job._id).lean();
    expect(failed?.attempts).toBe(1);
    expect(failed?.nextRetryAt).toBeNull();
  });
});

describe('worker: stale-claim recovery', () => {
  it('re-claims a job whose CLAIMED lease expired, but leaves a live claim alone', async () => {
    const stale = await makeJob({
      jobType: 'TEST_OK',
      state: 'CLAIMED',
      claimedAt: new Date(Date.now() - 200_000), // beyond the 120s lease
      claimedBy: 'worker-crashed-instance',
    });
    const live = await makeJob({
      jobType: 'TEST_OK',
      state: 'CLAIMED',
      claimedAt: new Date(), // fresh lease held by another instance
      claimedBy: 'worker-other-instance',
    });

    await withWorker({}, async () => {
      await waitFor(inState(stale._id as Types.ObjectId, 'COMPLETED'), 'stale job re-processed');
      // Several polls later the live claim must still be untouched.
      await new Promise((r) => setTimeout(r, 150));
    });

    expect((await Job.findById(stale._id).lean())?.claimedBy).toBe('worker-test-1');
    const untouched = await Job.findById(live._id).lean();
    expect(untouched?.state).toBe('CLAIMED');
    expect(untouched?.claimedBy).toBe('worker-other-instance');
  });
});

describe('worker: unregistered jobType', () => {
  // The queue is SHARED: another deployment against the same database may be
  // the one that knows this type. Leaving the row untouched is what lets that
  // build claim it; failing it here would kill work this worker was merely too
  // old to do. See claimNextJob's `jobTypes` parameter.
  it('leaves a type it cannot process QUEUED for a build that can', async () => {
    const job = await makeJob({ jobType: 'NO_SUCH_TYPE', maxAttempts: 3 });
    const other = await makeJob({ jobType: 'TEST_OK' });

    await withWorker({}, async () => {
      // The registered job draining is the proof the loop ran at all — without
      // it, "still QUEUED" would also pass on a worker that never polled.
      await waitFor(inState(other._id as Types.ObjectId, 'COMPLETED'), 'registered job COMPLETED');
    });

    const untouched = await Job.findById(job._id).lean();
    expect(untouched?.state).toBe('QUEUED');
    expect(untouched?.attempts).toBe(0);
    expect(untouched?.claimedBy).toBeNull();
    expect(untouched?.error).toBeFalsy();
  });

  it('still fails terminally if the claim is somehow held without a processor', async () => {
    const job = await makeJob({ jobType: 'NO_SUCH_TYPE', maxAttempts: 3 });

    // Bypass the type filter the way only a registry change under a live claim
    // could, so the defence-in-depth branch in processJob is exercised.
    await withWorker({ jobTypes: ['NO_SUCH_TYPE'] }, async () => {
      await waitFor(inState(job._id as Types.ObjectId, 'FAILED'), 'unknown-type job FAILED');
    });

    const failed = await Job.findById(job._id).lean();
    expect(failed?.lastError).toContain('No processor for jobType: NO_SUCH_TYPE');
    expect(failed?.error?.code).toBe(UNSUPPORTED_JOB_TYPE_CODE);
    expect(failed?.nextRetryAt).toBeNull(); // terminal — never re-queued
  });
});

describe('jobQueue: atomic claim', () => {
  it('two simultaneous claims of one job — exactly one wins', async () => {
    const job = await makeJob({ jobType: 'TEST_OK' });

    const [a, b] = await Promise.all([
      claimNextJob('worker-a', 120_000),
      claimNextJob('worker-b', 120_000),
    ]);

    const winners = [a, b].filter((j) => j !== null);
    expect(winners).toHaveLength(1);
    expect(winners[0]!._id.toString()).toBe((job._id as Types.ObjectId).toString());

    const claimed = await Job.findById(job._id).lean();
    expect(claimed?.state).toBe('CLAIMED');
    expect(['worker-a', 'worker-b']).toContain(claimed?.claimedBy);
  });
});

describe('worker: graceful shutdown', () => {
  it('drains the in-flight job before startWorker resolves', async () => {
    const job = await makeJob({ jobType: 'TEST_SLOW' });

    const ac = new AbortController();
    const done = startWorker({
      pollIntervalMs: 15,
      claimTimeoutMs: 120_000,
      concurrency: 2,
      workerId: 'worker-test-drain',
      heartbeatEveryNPolls: 1_000_000,
      stopSignal: ac.signal,
    });

    // Stop mid-processing: the loop must finish the claimed job, not abandon it.
    await waitFor(inState(job._id as Types.ObjectId, 'PROCESSING'), 'job PROCESSING');
    ac.abort();
    await done;

    expect((await Job.findById(job._id).lean())?.state).toBe('COMPLETED');
  });
});
