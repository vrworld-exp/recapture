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

/**
 * Is a publish already in flight for this catalog?
 *
 * B4 turns a truthy answer into `409 PUBLISH_IN_PROGRESS` (with the active run
 * id, so the client can go straight to polling it). NOTE this is a READ: it
 * reports, it does not reserve. The actual mutual exclusion is the conditional
 * update in B4's run creation, guarded on `activePublishRunId: null` — a
 * read-then-write here would let two concurrent publishes both pass.
 */
export async function hasActiveRun(
  catalogId: Types.ObjectId
): Promise<{ active: boolean; runId?: string }> {
  const catalog = await Catalog.findOne({ _id: catalogId, deletedAt: null })
    .select({ activePublishRunId: 1 })
    .lean()
    .exec();

  const runId = catalog?.activePublishRunId;
  return runId ? { active: true, runId: runId.toHexString() } : { active: false };
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
