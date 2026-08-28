// scripts/release-stuck-publish.ts
//
// Releases a catalog whose publish lock outlived its run.
//
// WHEN YOU NEED THIS. `activePublishRunId` is cleared in exactly one place —
// finalizeCatalogAfterRun, inside the publish processor. A job that dies
// BEFORE reaching that processor therefore strands the catalog: the run stays
// QUEUED, `isPublishing` stays true, the client polls forever, and every later
// publish gets 409 PUBLISH_IN_PROGRESS. The known way in was a stale worker on
// the shared queue failing the job with UNSUPPORTED_JOB_TYPE (fixed at source
// by claimNextJob's jobType filter — see src/worker/jobQueue.ts).
//
// WHAT IT REFUSES TO DO. It will not touch a run that is RUNNING, and it will
// not touch a QUEUED run whose job is still claimable — those are live work,
// and clearing the lock under them would let a second run race Mirage's
// non-idempotent writes, which is the exact thing the lock exists to prevent.
// A run only qualifies when its job is terminally dead (FAILED/CANCELED) or
// gone entirely.
//
// Run with: npx tsx scripts/release-stuck-publish.ts            # dry run, all catalogs
//           npx tsx scripts/release-stuck-publish.ts --apply    # write
//           npx tsx scripts/release-stuck-publish.ts <catalogId> --apply
//
// `--force` additionally releases a RUNNING run whose job is terminally dead —
// the case the verdict below sends to a human. It does NOT override a live job:
// releasing a lock under a worker that is still walking the plan is the one
// thing this script must never do, forced or not. Read the STEPS list the run
// printed first; forcing is only safe when nothing was half-pushed to Mirage.
//
// Needs .env (MONGODB_URI — same loader as the API).
import mongoose, { Types } from 'mongoose';
import { env } from '../src/config/env';
import { Catalog } from '../src/models/Catalog';
import { CatalogPublishRun } from '../src/models/CatalogPublishRun';
import { Job } from '../src/models/Job';

/** Job states from which a job can still be picked up by some worker. */
const LIVE_JOB_STATES = new Set(['QUEUED', 'CLAIMED', 'PROCESSING', 'TEXTURING', 'OPTIMIZING']);

const RELEASE_CODE = 'PUBLISH_ABANDONED';

interface Candidate {
  catalogId: Types.ObjectId;
  catalogName: string;
  runId: Types.ObjectId;
  runState: string;
  jobState: string;
  jobError: string | null;
  /** What the run actually pushed before it died — the thing --force must be judged against. */
  entries: { target: string; action: string; targetName: string; outcome: string; code: string }[];
}

type Verdict = { release: true; reason: string } | { release: false; reason: string };

/**
 * Is this lock dead, or merely slow?
 *
 * The distinction is the whole safety argument of the script, so it is one
 * function with every branch named rather than a condition inlined at the call
 * site.
 */
function judge(runState: string, jobState: string | null, force: boolean): Verdict {
  if (runState !== 'QUEUED' && runState !== 'RUNNING') {
    // Terminal run still holding the lock: finalizeRun landed, the catalog
    // write after it did not. Releasing is pure repair.
    return { release: true, reason: `run already terminal (${runState}), lock never cleared` };
  }
  if (jobState === null) {
    return { release: true, reason: 'job document no longer exists' };
  }
  if (LIVE_JOB_STATES.has(jobState)) {
    return { release: false, reason: `job is ${jobState} — still claimable, leave it alone` };
  }
  if (runState === 'RUNNING') {
    // A dead job under a RUNNING run means a worker died mid-walk — or, in the
    // UNSUPPORTED_JOB_TYPE case, that a stale worker on the shared queue
    // claimed the job and killed it before the processor ever ran. Rows may be
    // half-pushed to Mirage, so the default is to stop and let a human read the
    // STEPS list above. --force is that human saying they have.
    return force
      ? { release: true, reason: `FORCED — run is RUNNING with a ${jobState} job` }
      : {
          release: false,
          reason: `run is RUNNING with a ${jobState} job — inspect the steps above, then re-run with --force`,
        };
  }
  return { release: true, reason: `job is ${jobState} and will never run` };
}

async function collect(only: Types.ObjectId | null): Promise<Candidate[]> {
  const catalogs = await Catalog.find({
    activePublishRunId: { $ne: null },
    ...(only ? { _id: only } : {}),
  })
    .select({ _id: 1, name: 1, activePublishRunId: 1 })
    .lean()
    .exec();

  const out: Candidate[] = [];
  for (const catalog of catalogs) {
    const runId = catalog.activePublishRunId as Types.ObjectId;
    const run = await CatalogPublishRun.findById(runId)
      .select({ state: 1, jobId: 1, entries: 1 })
      .lean()
      .exec();
    const job = run?.jobId
      ? await Job.findById(run.jobId).select({ state: 1, error: 1 }).lean().exec()
      : null;

    out.push({
      catalogId: catalog._id as Types.ObjectId,
      catalogName: catalog.name,
      runId,
      runState: run?.state ?? '(run missing)',
      jobState: job?.state ?? '(job missing)',
      jobError: job?.error?.code ?? null,
      entries: (run?.entries ?? []).map((e) => ({
        target: e.target,
        action: e.action,
        targetName: e.targetName ?? '',
        outcome: e.outcome,
        code: e.code ?? '',
      })),
    });
  }
  return out;
}

/**
 * Two writes, run-first, mirroring finalizeCatalogAfterRun's own ordering: a
 * released catalog pointing at a still-QUEUED run would read as publishable
 * while the status endpoint reported a phantom publish in flight.
 */
async function release(candidate: Candidate, reason: string): Promise<void> {
  await CatalogPublishRun.updateOne(
    { _id: candidate.runId, state: { $in: ['QUEUED', 'RUNNING'] } },
    {
      $set: {
        state: 'FAILED',
        finishedAt: new Date(),
        error: {
          code: RELEASE_CODE,
          message: 'This publish never ran. Press Publish again.',
        },
      },
    }
  ).exec();

  // Fenced on the run id: if a new publish somehow took the lock between the
  // read and here, that one is live and must not be cleared.
  await Catalog.updateOne(
    { _id: candidate.catalogId, activePublishRunId: candidate.runId },
    { $set: { activePublishRunId: null } }
  ).exec();

  console.log(`  released — ${reason}`);
}

async function main(): Promise<void> {
  const args = process.argv.slice(2);
  const apply = args.includes('--apply');
  const force = args.includes('--force');
  const idArg = args.find((a) => !a.startsWith('--'));

  if (idArg && !Types.ObjectId.isValid(idArg)) {
    console.error(`Not a catalog id: ${idArg}`);
    process.exit(1);
  }
  const only = idArg ? new Types.ObjectId(idArg) : null;

  await mongoose.connect(env.MONGODB_URI);
  try {
    const candidates = await collect(only);
    if (candidates.length === 0) {
      console.log('No catalog is holding a publish lock.');
      return;
    }

    console.log(`${candidates.length} catalog(s) holding a publish lock:\n`);
    let released = 0;
    for (const candidate of candidates) {
      const verdict = judge(
        candidate.runState,
        candidate.jobState === '(job missing)' ? null : candidate.jobState,
        force
      );
      console.log(
        `${candidate.catalogName} (${candidate.catalogId.toHexString()})\n` +
          `  run ${candidate.runId.toHexString()} — ${candidate.runState}\n` +
          `  job — ${candidate.jobState}${candidate.jobError ? ` (${candidate.jobError})` : ''}`
      );
      // Always printed, dry run included: these steps are the evidence --force
      // is meant to be judged on, so seeing them must never need a second command.
      console.log(
        candidate.entries.length === 0
          ? '  steps — none recorded (nothing reached Mirage)'
          : `  steps — ${candidate.entries.length} recorded:`
      );
      for (const e of candidate.entries) {
        const name = e.targetName ? `"${e.targetName}" ` : '';
        const code = e.code ? ` (${e.code})` : '';
        console.log(`      ${e.target} ${e.action} ${name}-> ${e.outcome}${code}`);
      }
      if (!verdict.release) {
        console.log(`  SKIPPED — ${verdict.reason}\n`);
        continue;
      }
      if (!apply) {
        console.log(`  would release — ${verdict.reason}\n`);
        released++;
        continue;
      }
      await release(candidate, verdict.reason);
      console.log('');
      released++;
    }

    console.log(
      apply
        ? `Done. Released ${released} catalog(s).`
        : `Dry run. ${released} catalog(s) would be released — re-run with --apply to write.`
    );
  } finally {
    await mongoose.disconnect();
  }
}

main().catch((err: unknown) => {
  console.error(err instanceof Error ? err.message : String(err));
  process.exit(1);
});
