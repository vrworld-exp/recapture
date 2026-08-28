// scripts/release-stuck-publish.ts
//
// Releases a catalog whose publish lock outlived its run.
//
// WHEN YOU STILL NEED THIS. The API now repairs the common case by itself:
// hasActiveRun and the publish-status endpoint call releaseAbandonedRun
// (src/services/catalog/publishRunState.ts) on every read, so a QUEUED run
// behind a terminally dead job is cleared the moment anyone polls or presses
// Publish. What is left for this script is the case that repair deliberately
// REFUSES: a RUNNING run whose job died mid-walk, where rows may already be
// half-pushed to Mirage and a human has to look before the lock comes off.
// It also stays the way to see, and fix, the whole database at once.
//
// WHY THE STRANDING HAPPENS AT ALL. `activePublishRunId` is cleared on the
// happy path in exactly one place — finalizeCatalogAfterRun, inside the publish
// processor. A job that dies BEFORE reaching that processor strands the
// catalog. The way in has been a stale deployment on the shared queue: the Job
// collection IS the queue, every deployment pointed at one database polls it,
// and a build predating MIRAGE_CATALOG_PUBLISH claims the job, finds no
// processor and fails it terminally with UNSUPPORTED_JOB_TYPE.
//
// claimNextJob's jobType filter (src/worker/jobQueue.ts) is often described as
// having fixed that. IT DID NOT, AND IT CANNOT: a claim-side filter only ever
// binds the builds that contain it, and a stale deployment is still running the
// old query. The filter stops CURRENT builds from causing the problem; the
// automatic repair keeps a stale one from wedging a catalog permanently. The
// actual prevention is an ops action — retire or redeploy the stale service.
//
// WHAT IT REFUSES TO DO. It will not touch a run whose job is still claimable —
// that is live work, and clearing the lock under it would let a second run race
// Mirage's non-idempotent writes, which is the exact thing the lock exists to
// prevent. A run only qualifies when its job is terminally dead (FAILED/
// CANCELED) or gone entirely.
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
import type { PublishRunState } from '../src/models/types/catalog.types';
// The judge and the write both live in the service, so this script and the
// API's automatic repair can never disagree about what is safe to release.
import { judgeAbandonedRun, releaseAbandonedRun } from '../src/services/catalog/publishRunState';

interface Candidate {
  catalogId: Types.ObjectId;
  catalogName: string;
  runId: Types.ObjectId;
  /** null = the run document is gone. */
  runState: PublishRunState | null;
  /** null = the job document is gone. */
  jobState: string | null;
  jobError: string | null;
  /** What the run actually pushed before it died — the thing --force must be judged against. */
  entries: { target: string; action: string; targetName: string; outcome: string; code: string }[];
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
      runState: run?.state ?? null,
      jobState: job?.state ?? null,
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
      const verdict = judgeAbandonedRun(candidate.runState, candidate.jobState, force);
      const jobError = candidate.jobError ? ` (${candidate.jobError})` : '';
      console.log(
        `${candidate.catalogName} (${candidate.catalogId.toHexString()})\n` +
          `  run ${candidate.runId.toHexString()} — ${candidate.runState ?? '(run missing)'}\n` +
          `  job — ${candidate.jobState ?? '(job missing)'}${jobError}`
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
      // Re-judged inside, against a fresh read and fenced on the run id — so a
      // publish that started between collect() and here is not clobbered.
      const done = await releaseAbandonedRun(candidate.catalogId, candidate.runId, { force });
      console.log(
        done
          ? `  released — ${verdict.reason}\n`
          : '  NOT released — the lock changed hands while this script ran; re-run to re-read\n'
      );
      if (done) released++;
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
