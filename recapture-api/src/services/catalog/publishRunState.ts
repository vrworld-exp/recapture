// src/services/catalog/publishRunState.ts
//
// Every durable write a publish run makes to its own bookkeeping: the run
// document's state machine, its entries and counts, the per-row sync state, and
// the catalog's finalize fields.
//
// It is a service, not part of the processor, for two reasons: B4's endpoints
// need `hasActiveRun` and the same 409 guard, and B2's executors need the row
// writers. Keeping them here means there is ONE place that knows how a run's
// state advances, and the worker is just its first caller.
//
// ATOMICITY WITHOUT TRANSACTIONS, everywhere (AGENTS.md §Data layer). Every
// transition below is a single conditional `findOneAndUpdate`/`updateOne`
// guarded on the state it is moving out of, so two workers racing a re-claimed
// job cannot both "start" or both "finalise" a run.
import { Types } from 'mongoose';

import { Catalog } from '@/models/Catalog';
import { CatalogCategory } from '@/models/CatalogCategory';
import { CatalogProduct } from '@/models/CatalogProduct';
import { CatalogPublishRun } from '@/models/CatalogPublishRun';
import { Job } from '@/models/Job';
import type {
  ProductPublishedSnapshot,
  PublishMode,
  PublishOutcome,
  PublishRunEntry,
  PublishRunState,
  SyncStatus,
} from '@/models/types/catalog.types';

/** Terminal run states — a run in one of these is finished and never resumes. */
const TERMINAL_RUN_STATES: readonly PublishRunState[] = ['SUCCEEDED', 'PARTIAL', 'FAILED'];

export function isTerminalRunState(state: PublishRunState): boolean {
  return TERMINAL_RUN_STATES.includes(state);
}

// ── Abandoned-lock recovery ─────────────────────────────────────────────────
//
// On the happy path a catalog's publish lock (`activePublishRunId`) is cleared
// in exactly one place: finalizeCatalogAfterRun, at the END of the processor. A
// job that dies BEFORE reaching that processor therefore strands the catalog —
// the run stays QUEUED, the lock stays taken, the client polls a run that will
// never move, and every later publish is refused with 409 PUBLISH_IN_PROGRESS.
// Until this existed, only a human running scripts/release-stuck-publish.ts
// could get the user out.
//
// WHY PREVENTION IS NOT AVAILABLE HERE. The Job collection IS the queue, so
// every deployment pointed at one database polls the same rows. A build that
// predates MIRAGE_CATALOG_PUBLISH can claim one of these jobs, find no
// processor, and fail it terminally (UNSUPPORTED_JOB_TYPE). claimNextJob's
// jobType filter stops THIS build from doing that — but a claim filter can only
// ever bind the builds that contain it, and a stale deployment is still running
// the old query. Retiring that deployment is an ops action, not a code change.
// So the code's job is to make the outcome survivable rather than permanent,
// for a job that died of ANY cause and not just that one.

/** Job states from which a job can still be picked up by some worker. */
const LIVE_JOB_STATES: ReadonlySet<string> = new Set([
  'QUEUED',
  'CLAIMED',
  'PROCESSING',
  'TEXTURING',
  'OPTIMIZING',
]);

/** `error.code` on a run whose job died before the processor ever ran. */
export const PUBLISH_ABANDONED_CODE = 'PUBLISH_ABANDONED';

/** What the user is told — actionable, because the fix genuinely is one tap. */
export const PUBLISH_ABANDONED_MESSAGE = 'This publish never ran. Press Publish again.';

export interface AbandonedVerdict {
  release: boolean;
  reason: string;
}

/**
 * Is this lock dead, or merely slow?
 *
 * That distinction is the entire safety argument for clearing a lock, so it is
 * one function with every branch named rather than a condition inlined at the
 * call sites. Both repairs share it — this module's automatic one and
 * scripts/release-stuck-publish.ts's manual one — so the two can never
 * disagree about what is safe to touch.
 *
 * `runState: null` means the run document is gone; `jobState: null`, the job.
 */
export function judgeAbandonedRun(
  runState: PublishRunState | null,
  jobState: string | null,
  force = false
): AbandonedVerdict {
  if (runState === null) {
    return { release: true, reason: 'run document no longer exists' };
  }
  if (isTerminalRunState(runState)) {
    // finalizeRun landed; the catalog write after it did not. Pure repair.
    return { release: true, reason: `run already terminal (${runState}), lock never cleared` };
  }
  if (jobState !== null && LIVE_JOB_STATES.has(jobState)) {
    return { release: false, reason: `job is ${jobState} — still claimable, leave it alone` };
  }

  // Past here the job is dead or gone, so nothing will advance this run again.
  if (runState === 'RUNNING') {
    // A RUNNING run got past beginRun, so a worker WAS walking the plan and rows
    // may already be half-pushed to Mirage.
    //
    // THE MISSING-JOB CASE BELONGS HERE TOO. Testing it earlier is a bug: that
    // the job document is gone is not evidence that nothing reached Mirage, it
    // is the absence of evidence — and the entries[] this run already wrote say
    // otherwise. NEVER automatic either way: clearing the lock would let a
    // second run race Mirage's non-idempotent writes, which is the exact thing
    // the lock exists to prevent. A human reads entries[] and passes --force.
    const dead = jobState ?? 'missing';
    return force
      ? { release: true, reason: `FORCED — run is RUNNING with a ${dead} job` }
      : {
          release: false,
          reason: `run is RUNNING with a ${dead} job — inspect its steps, then re-run with --force`,
        };
  }
  // QUEUED run + dead-or-gone job: the processor never started, so nothing
  // reached Mirage and there is nothing to reconcile.
  return { release: true, reason: `job is ${jobState ?? 'missing'} and will never run` };
}

/**
 * Clears a publish lock whose run can never finish, failing the run with an
 * actionable message. Returns whether the lock was actually cleared.
 *
 * TWO WRITES, RUN FIRST, mirroring finalizeCatalogAfterRun's own ordering: a
 * released catalog still pointing at a QUEUED run would read as publishable
 * while the status endpoint reported a phantom publish in flight.
 */
export async function releaseAbandonedRun(
  catalogId: Types.ObjectId,
  runId: Types.ObjectId,
  options: { force?: boolean } = {}
): Promise<boolean> {
  const run = await CatalogPublishRun.findById(runId).select({ state: 1, jobId: 1 }).lean().exec();
  const job = run?.jobId ? await Job.findById(run.jobId).select({ state: 1 }).lean().exec() : null;

  const verdict = judgeAbandonedRun(run?.state ?? null, job?.state ?? null, options.force ?? false);
  if (!verdict.release) return false;

  await CatalogPublishRun.updateOne(
    { _id: runId, state: { $in: ['QUEUED', 'RUNNING'] } },
    {
      $set: {
        state: 'FAILED',
        finishedAt: new Date(),
        error: { code: PUBLISH_ABANDONED_CODE, message: PUBLISH_ABANDONED_MESSAGE },
      },
    }
  ).exec();

  // Fenced on the run id: if a new publish took the lock between the read above
  // and here, THAT one is live and must not be cleared.
  const res = await Catalog.updateOne(
    { _id: catalogId, activePublishRunId: runId },
    { $set: { activePublishRunId: null } }
  ).exec();
  return res.modifiedCount > 0;
}

/**
 * Is a publish already in flight for this catalog?
 *
 * B4 turns a truthy answer into `409 PUBLISH_IN_PROGRESS` (with the active run
 * id, so the client can go straight to polling it). NOTE this is a READ: it
 * reports, it does not reserve. The actual mutual exclusion is the conditional
 * update in B4's run creation, guarded on `activePublishRunId: null` — a
 * read-then-write here would let two concurrent publishes both pass.
 *
 * It is ALMOST a pure read. The one write it can make is releaseAbandonedRun
 * below, which clears a lock whose run provably can never finish — the repair
 * belongs here because this is the choke point every publish gate already goes
 * through, so no caller can forget it. It still does not RESERVE anything.
 */
export async function hasActiveRun(
  catalogId: Types.ObjectId
): Promise<{ active: boolean; runId?: string }> {
  const catalog = await Catalog.findOne({ _id: catalogId, deletedAt: null })
    .select({ activePublishRunId: 1 })
    .lean()
    .exec();

  const runId = catalog?.activePublishRunId;
  if (!runId) return { active: false };

  // LAZY REPAIR ON READ. A lock whose run can never finish is cleared here, at
  // the moment someone asks about it — which is exactly when a user is stuck
  // watching a spinner or being refused with 409. releaseAbandonedRun declines
  // to touch anything merely slow, so a live publish is never disturbed.
  if (await releaseAbandonedRun(catalogId, runId)) return { active: false };

  return { active: true, runId: runId.toHexString() };
}

/** What {@link beginRun} found when it tried to start the run. */
export type BeginRunOutcome =
  /** We won the QUEUED → RUNNING flip; this attempt owns the run. */
  | { outcome: 'STARTED' }
  /**
   * Already RUNNING. This is the crash-replay path: the lease expired, the job
   * was re-claimed, and the previous attempt's entries are still on the
   * document. The run continues — the planner re-plans from live row state, so
   * whatever already succeeded now plans as SKIP.
   */
  | { outcome: 'RESUMED' }
  /** Finished on an earlier attempt. A replay must do nothing at all. */
  | { outcome: 'ALREADY_FINISHED'; state: PublishRunState }
  | { outcome: 'MISSING' };

/**
 * QUEUED → RUNNING, stamping `startedAt`.
 *
 * `startedAt` is set only by the winning flip, so a resumed run keeps the
 * instant the user actually pressed Publish rather than the instant a worker
 * happened to pick it back up.
 */
export async function beginRun(runId: Types.ObjectId): Promise<BeginRunOutcome> {
  const started = await CatalogPublishRun.findOneAndUpdate(
    { _id: runId, state: 'QUEUED' },
    { $set: { state: 'RUNNING', startedAt: new Date() } },
    { new: true }
  )
    .lean()
    .exec();
  if (started) return { outcome: 'STARTED' };

  const current = await CatalogPublishRun.findById(runId).select({ state: 1 }).lean().exec();
  if (!current) return { outcome: 'MISSING' };
  if (isTerminalRunState(current.state)) {
    return { outcome: 'ALREADY_FINISHED', state: current.state };
  }
  return { outcome: 'RESUMED' };
}

/**
 * Publishes the plan's size onto the run and zeroes the tallies.
 *
 * The reset is deliberate and only looks lossy. `entries[]` is the history and
 * is never touched; `counts` is the CURRENT reckoning, and on a resumed attempt
 * the current reckoning is the fresh plan — in which the rows that already
 * succeeded are SKIPs. Carrying the dead attempt's tallies forward would
 * double-count them and report "14 of 10 published".
 */
export async function resetRunCounts(runId: Types.ObjectId, total: number): Promise<void> {
  await CatalogPublishRun.updateOne(
    { _id: runId },
    { $set: { counts: { total, synced: 0, failed: 0, skipped: 0 } } }
  ).exec();
}

const COUNT_FIELD: Record<PublishOutcome, string> = {
  SUCCEEDED: 'counts.synced',
  FAILED: 'counts.failed',
  SKIPPED: 'counts.skipped',
};

/**
 * Appends one entry and bumps its tally, in ONE write.
 *
 * `$push` rather than a read-modify-write of the array: a crash between two
 * steps must leave every entry already recorded intact, and an array rewritten
 * from a stale in-memory copy is exactly how that guarantee is lost.
 */
export async function appendRunEntry(
  runId: Types.ObjectId,
  entry: PublishRunEntry
): Promise<void> {
  await CatalogPublishRun.updateOne(
    { _id: runId },
    { $push: { entries: entry }, $inc: { [COUNT_FIELD[entry.outcome]]: 1 } }
  ).exec();
}

/**
 * The §7.8 rule, in one place.
 *
 *   zero failures                    → SUCCEEDED   (an all-SKIP no-op republish
 *                                                   is a success, not a nothing)
 *   ≥1 success and ≥1 failure        → PARTIAL
 *   zero successes                   → FAILED
 *
 * Order matters: the "zero failures" test comes first, which is what makes a
 * run of nothing but SKIPs succeed.
 */
export function resolveRunState(counts: { synced: number; failed: number }): PublishRunState {
  if (counts.failed === 0) return 'SUCCEEDED';
  if (counts.synced > 0) return 'PARTIAL';
  return 'FAILED';
}

/** RUNNING → terminal. Guarded, so a re-claimed loser cannot re-finalise. */
export async function finalizeRun(
  runId: Types.ObjectId,
  state: PublishRunState,
  error?: { code: string; message: string }
): Promise<boolean> {
  const res = await CatalogPublishRun.updateOne(
    { _id: runId, state: { $nin: TERMINAL_RUN_STATES } },
    {
      $set: {
        state,
        finishedAt: new Date(),
        ...(error ? { error } : {}),
      },
    }
  ).exec();
  return res.matchedCount > 0;
}

export interface FinalizeCatalogParams {
  catalogId: Types.ObjectId;
  runId: Types.ObjectId;
  mode: PublishMode;
  state: PublishRunState;
  /** The `draftRevision` the run was planned from. */
  snapshotRevision: number;
}

/**
 * The catalog's side of finalization.
 *
 * TWO writes on purpose, not one. Clearing `activePublishRunId` must happen on
 * EVERY terminal path — success, partial, failure, and a processor that threw —
 * because a catalog left holding a dead run id can never be published again.
 * Advancing `publishedRevision` must happen on exactly one path. Folding them
 * into a single guarded update would tie the unconditional obligation to the
 * conditional one, and the first time the revision guard did not match, the
 * catalog would be wedged.
 *
 * `publishedRevision` advances only on SUCCEEDED, and only forward: a PARTIAL
 * run's successes are genuinely live, but some product is not, so "draft
 * changes not yet live" is the truth and the badge stays on (§7.8). An
 * UNPUBLISH run never advances it — it published nothing.
 */
export async function finalizeCatalogAfterRun(params: FinalizeCatalogParams): Promise<void> {
  const { catalogId, runId, mode, state, snapshotRevision } = params;

  if (state === 'SUCCEEDED' && mode !== 'UNPUBLISH') {
    await Catalog.updateOne(
      { _id: catalogId, deletedAt: null, publishedRevision: { $lt: snapshotRevision } },
      {
        $set: {
          publishedRevision: snapshotRevision,
          lastPublishedAt: new Date(),
          status: 'PUBLISHED',
        },
      }
    ).exec();
  }

  await Catalog.updateOne(
    { _id: catalogId, activePublishRunId: runId },
    { $set: { activePublishRunId: null } }
  ).exec();
}

// ── Per-row sync state ──────────────────────────────────────────────────────
//
// ⚠ EVERY write below passes `{ timestamps: false }`.
//
// Syncing is not an authoring edit, and `updatedAt` is what the planner reads
// to answer "was this row edited since we last pushed it?" — categories carry
// no publishedSnapshot to diff against, so their timestamps ARE the diff.
// Letting a sync write bump `updatedAt` would leave it permanently newer than
// the `lastSyncedAt` written in the very same statement, so every category
// would plan an UPDATE on every run, forever, and the zero-writes republish
// guarantee would quietly stop holding.

/**
 * The failure a row carries until its next attempt.
 *
 * `code` is an `UPPER_SNAKE` ReCapture code and `message` is our sentence for
 * it — never Mirage's prose, which is unversioned, untested and written for
 * a different audience.
 */
export interface RowFailure {
  code: string;
  message: string;
}

export async function markCategoryFailed(
  categoryId: string,
  failure: RowFailure
): Promise<void> {
  await CatalogCategory.updateOne(
    { _id: categoryId },
    {
      $set: {
        syncStatus: 'FAILED' satisfies SyncStatus,
        syncError: { code: failure.code, message: failure.message, at: new Date() },
      },
    },
    { timestamps: false }
  ).exec();
}

export async function markCategorySynced(
  categoryId: string,
  mirageCategoryId: string
): Promise<void> {
  await CatalogCategory.updateOne(
    { _id: categoryId },
    {
      $set: {
        mirageCategoryId,
        syncStatus: 'SYNCED' satisfies SyncStatus,
        lastSyncedAt: new Date(),
      },
      $unset: { syncError: '' },
    },
    { timestamps: false }
  ).exec();
}

export async function markProductFailed(productId: string, failure: RowFailure): Promise<void> {
  await CatalogProduct.updateOne(
    { _id: productId },
    {
      $set: {
        syncStatus: 'FAILED' satisfies SyncStatus,
        syncError: { code: failure.code, message: failure.message, at: new Date() },
      },
    },
    { timestamps: false }
  ).exec();
}

export async function markProductSynced(
  productId: string,
  published: ProductPublishedSnapshot
): Promise<void> {
  await CatalogProduct.updateOne(
    { _id: productId },
    {
      $set: {
        syncStatus: 'SYNCED' satisfies SyncStatus,
        lastSyncedAt: new Date(),
        publishedSnapshot: { ...published, at: new Date() },
        ...(published.mirageCategoryId
          ? { mirageCategoryIdAtSync: published.mirageCategoryId }
          : {}),
      },
      $unset: { syncError: '' },
    },
    { timestamps: false }
  ).exec();
}

/**
 * The row is no longer on Mirage. Clears the mapping AND the diff basis: a
 * product that still remembered a `publishedSnapshot` would plan as SKIP on the
 * next run and never come back.
 */
export async function markProductUnpublished(productId: string): Promise<void> {
  await CatalogProduct.updateOne(
    { _id: productId },
    {
      $set: { syncStatus: 'NEVER' satisfies SyncStatus },
      $unset: {
        mirageItemId: '',
        mirageCategoryIdAtSync: '',
        publishedSnapshot: '',
        syncError: '',
        lastSyncedAt: '',
      },
    },
    { timestamps: false }
  ).exec();
}
