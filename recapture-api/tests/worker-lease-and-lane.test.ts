// tests/worker-lease-and-lane.test.ts
//
// Two worker-loop properties a catalog publish depends on and nothing else
// exercised:
//
//   • THE LEASE HEARTBEAT. A processor that outlasts WORKER_CLAIM_TIMEOUT_MS
//     must not have its job re-claimed and run a second time in parallel. The
//     Meshy processor renews the lease through its stage writes by accident of
//     design; the publish processor writes its progress to CatalogPublishRun
//     and renewed nothing — so a publish longer than the lease (a few 3D
//     dishes) was walked twice at once, into a Mirage whose create checks
//     uniqueness BEFORE it uploads. Duplicated items and PARTIAL runs followed.
//
//   • THE RESERVED LANE. With the general budget full of long-running jobs
//     (Meshy generations hold a slot for up to ten minutes), a lane job type
//     must still be claimed within a poll — that is what stops a rep waiting at
//     a table for a slot that two generations are sitting on.
//
// Hermetic: in-memory MongoDB, stub processors registered under test-only
// job types so the real processors (and their S3/Meshy/Mirage needs) are never
// on the path.
import { describe, it, expect, beforeAll, afterAll, afterEach } from 'vitest';
import mongoose, { Types } from 'mongoose';
import { MongoMemoryServer } from 'mongodb-memory-server';

import { Job, type IJob } from '@/models/Job';
import { registerProcessor } from '@/worker/processorRegistry';
import { startWorker } from '@/worker/worker';
import type { WorkerConfig, WorkerJob } from '@/worker/workerTypes';

const SLOW_TYPE = 'TEST_SLOW_JOB';
const LANE_TYPE = 'TEST_LANE_JOB';

let mongod: MongoMemoryServer;

/** How many times each stub processor has been entered, by job id. */
const runs = new Map<string, number>();
/** Per-job override for how long the stub holds the slot. */
const holdMs = new Map<string, number>();
/** Resolvers for jobs told to hold until released. */
const releases = new Map<string, () => void>();

function sleep(ms: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

async function stub(job: WorkerJob): Promise<Record<string, unknown>> {
  const id = String(job._id);
  runs.set(id, (runs.get(id) ?? 0) + 1);
  const hold = holdMs.get(id);
  if (hold === undefined) {
    // Hold until the test releases the job.
    await new Promise<void>((resolve) => releases.set(id, resolve));
  } else {
    await sleep(hold);
  }
  return { ok: true };
}

beforeAll(async () => {
  mongod = await MongoMemoryServer.create();
  await mongoose.connect(mongod.getUri());
  await Job.syncIndexes();
  registerProcessor(SLOW_TYPE, stub);
  registerProcessor(LANE_TYPE, stub);
});

afterAll(async () => {
  await mongoose.disconnect();
  await mongod.stop();
});

afterEach(async () => {
  for (const release of releases.values()) release();
  releases.clear();
  runs.clear();
  holdMs.clear();
  await Job.deleteMany({});
});

function queued(jobType: string, overrides: Partial<IJob> = {}): Promise<IJob> {
  return Job.create({
    projectId: new Types.ObjectId(),
    userId: new Types.ObjectId(),
    jobType,
    state: 'QUEUED',
    ...overrides,
  });
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
    workerId: 'worker-lease-test',
    heartbeatEveryNPolls: 1_000_000,
    jobTypes: [SLOW_TYPE, LANE_TYPE],
    stopSignal: ac.signal,
    ...overrides,
  });
  try {
    await fn();
  } finally {
    for (const release of releases.values()) release();
    ac.abort();
    await done;
  }
}

async function waitFor(predicate: () => Promise<boolean>, what: string): Promise<void> {
  const deadline = Date.now() + 10_000;
  while (Date.now() < deadline) {
    if (await predicate()) return;
    await sleep(20);
  }
  throw new Error(`Timed out waiting for: ${what}`);
}

const inState = (id: Types.ObjectId, state: string) => async () => {
  const j = await Job.findById(id).lean();
  return j?.state === state;
};

const entered = (id: Types.ObjectId, times: number) => async () =>
  (runs.get(String(id)) ?? 0) >= times;

describe('worker lease heartbeat', () => {
  it('a job that outlasts the lease is renewed, not re-claimed and run twice', async () => {
    const job = await queued(SLOW_TYPE);
    const id = job._id as Types.ObjectId;
    // Holds the slot for FOUR leases. Without the heartbeat, the loop's second
    // slot re-claims it as stale after the first one lapses and the processor
    // is entered again while the first entry is still running.
    holdMs.set(String(id), 800);

    await withWorker({ claimTimeoutMs: 200 }, async () => {
      await waitFor(entered(id, 1), 'processor entered');
      const claimedAtStart = (await Job.findById(id).lean())?.claimedAt;
      expect(claimedAtStart).toBeInstanceOf(Date);

      // Past the lease, the claim is still alive because it was renewed.
      await sleep(450);
      const midway = await Job.findById(id).lean();
      expect(midway?.state).toBe('PROCESSING');
      expect(midway?.claimedAt?.getTime()).toBeGreaterThan((claimedAtStart as Date).getTime());

      await waitFor(inState(id, 'COMPLETED'), 'job COMPLETED');
    });

    expect(runs.get(String(id))).toBe(1);
    const done = await Job.findById(id).lean();
    expect(done?.attempts ?? 0).toBe(0);
    expect(done?.result).toMatchObject({ ok: true });
  });

  it('a lease that lapses because the worker died is still recovered by the next claim', async () => {
    // The heartbeat must not have turned the lease into a permanent lock: a
    // job left PROCESSING by a worker that is gone still comes back.
    const job = await queued(SLOW_TYPE, {
      state: 'PROCESSING',
      claimedBy: 'worker-that-died',
      claimedAt: new Date(Date.now() - 60_000),
    });
    const id = job._id as Types.ObjectId;
    holdMs.set(String(id), 10);

    await withWorker({ claimTimeoutMs: 1_000 }, async () => {
      await waitFor(inState(id, 'COMPLETED'), 'orphaned job re-claimed and completed');
    });

    expect(runs.get(String(id))).toBe(1);
    expect((await Job.findById(id).lean())?.claimedBy).toBe('worker-lease-test');
  });
});

describe('worker reserved lane', () => {
  it('claims a lane-type job while the general budget is full of long jobs', async () => {
    const blockerA = await queued(SLOW_TYPE);
    const blockerB = await queued(SLOW_TYPE);
    // Both held open until the test says otherwise — the "two Meshy jobs".

    await withWorker(
      { concurrency: 2, reservedLane: { jobTypes: [LANE_TYPE], slots: 1 } },
      async () => {
        await waitFor(entered(blockerA._id as Types.ObjectId, 1), 'blocker A running');
        await waitFor(entered(blockerB._id as Types.ObjectId, 1), 'blocker B running');

        // General budget is full. A third general job must NOT be claimed…
        const starved = await queued(SLOW_TYPE);
        // …but a lane job must be, within a poll.
        const laneJob = await queued(LANE_TYPE);
        holdMs.set(String(laneJob._id), 10);

        await waitFor(inState(laneJob._id as Types.ObjectId, 'COMPLETED'), 'lane job completed');
        expect((await Job.findById(starved._id).lean())?.state).toBe('QUEUED');
        expect(runs.get(String(starved._id))).toBeUndefined();

        // And the lane is a budget of its own: a second lane job waits for the
        // first lane slot, not for a general one — but it does still run.
        const laneJob2 = await queued(LANE_TYPE);
        holdMs.set(String(laneJob2._id), 10);
        await waitFor(inState(laneJob2._id as Types.ObjectId, 'COMPLETED'), 'second lane job');
      }
    );
  });

  it('never claims a lane type this instance cannot process', async () => {
    const foreign = await queued('TEST_UNKNOWN_TYPE');
    const blocker = await queued(SLOW_TYPE);

    await withWorker(
      {
        concurrency: 1,
        jobTypes: [SLOW_TYPE],
        reservedLane: { jobTypes: ['TEST_UNKNOWN_TYPE'], slots: 1 },
      },
      async () => {
        await waitFor(entered(blocker._id as Types.ObjectId, 1), 'blocker running');
        await sleep(100);
        expect((await Job.findById(foreign._id).lean())?.state).toBe('QUEUED');
      }
    );
  });

  it('a lane-type job still uses a free general slot (the lane is a floor, not a cap)', async () => {
    const laneA = await queued(LANE_TYPE);
    const laneB = await queued(LANE_TYPE);
    holdMs.set(String(laneA._id), 10);
    holdMs.set(String(laneB._id), 10);

    await withWorker(
      { concurrency: 2, reservedLane: { jobTypes: [LANE_TYPE], slots: 1 } },
      async () => {
        await waitFor(inState(laneA._id as Types.ObjectId, 'COMPLETED'), 'lane A');
        await waitFor(inState(laneB._id as Types.ObjectId, 'COMPLETED'), 'lane B');
      }
    );
  });
});
