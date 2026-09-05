// src/services/catalogActivityService.ts
//
// The publish activity log (feature 55) — a paged, newest-first history of
// every publish run and every target it touched.
//
// IT COSTS ALMOST NOTHING BECAUSE THE DATA ALREADY EXISTS.
// `CatalogPublishRun.entries[]` is written by the processor as it walks the
// plan: one row per target, with the action, the outcome and our failure code.
// That is precisely what an activity log is, which is why there is no fifth
// collection here and no second write path — this file is READ-ONLY over what
// B1 already records.
//
// TWO THINGS IT DOES ADD, and both are about the long run:
//
//   • RETENTION. A catalog republished daily for two years is 730 run
//     documents, each carrying an entry per product. Nobody reads the 400th,
//     and unbounded growth in a document-per-run collection is how a small
//     feature becomes an operational problem. Pruning happens on write —
//     see `pruneRunHistory` — rather than as a TTL, because "keep the last N"
//     is what a user expects from a history list and "keep 90 days" is not:
//     a business that publishes twice a year would lose everything.
//
//   • PROJECTION. Entries are copied FIELD BY FIELD. `entries[]` is an internal
//     array on a worker-owned document and it will grow fields; a spread is how
//     one of them reaches a response the next time somebody adds one.
import { Types } from 'mongoose';

import { env } from '@/config/env';
import { Catalog } from '@/models/Catalog';
import { CatalogPublishRun } from '@/models/CatalogPublishRun';
import type {
  PublishAction,
  PublishMode,
  PublishOutcome,
  PublishRunState,
  PublishTargetKind,
} from '@/models/types/catalog.types';
import { messageForSyncCode } from '@/services/catalog/publishSyncErrors';
import { decodeCursor, encodeCursor } from '@/utils/cursor';

export interface ActivityEntryDto {
  target: PublishTargetKind;
  targetId?: string;
  /**
   * Denormalised at write time, which is what makes this log still readable
   * after the product it names has been deleted. It is catalog CONTENT — safe
   * to return to the owner, and never to be copied into analytics or a log line.
   */
  targetName?: string;
  action: PublishAction;
  outcome: PublishOutcome;
  /** OUR `UPPER_SNAKE` code. Never Mirage prose. */
  code?: string;
  /**
   * Resolved FROM the code at read time, not stored alongside it. Improving a
   * sentence therefore improves the whole history, including runs that finished
   * months ago — the alternative freezes every past wording forever.
   */
  message?: string;
  at: string;
}

export interface ActivityRunDto {
  id: string;
  state: PublishRunState;
  mode: PublishMode;
  counts: { total: number; synced: number; failed: number; skipped: number };
  startedAt: string | null;
  /** Absent while the run is still going. */
  finishedAt: string | null;
  error?: { code: string; message: string };
  entries: ActivityEntryDto[];
}

export interface ActivityPageDto {
  runs: ActivityRunDto[];
  /** Absent when this is the last page. */
  nextCursor?: string;
}

export type ListActivityResult =
  | { outcome: 'OK'; page: ActivityPageDto }
  | { outcome: 'NOT_FOUND' }
  | { outcome: 'BAD_CURSOR' };

export const ACTIVITY_MAX_LIMIT = 50;
export const ACTIVITY_DEFAULT_LIMIT = 20;

/**
 * One page of history, newest first.
 *
 * ORDERED ON (createdAt desc, _id desc) and paged on the same pair, which is
 * what makes the paging deterministic when two runs share a millisecond — a
 * cursor on `createdAt` alone would skip or repeat a row there. The compound
 * index `{catalogId, createdAt: -1}` on the model backs the scan; `_id` is the
 * tie-break the index's natural order already provides.
 *
 * ⚠ `startedAt` is NOT the sort key even though the endpoint is about when
 * things ran. A QUEUED run has no `startedAt` at all, and sorting on a field
 * that can be absent puts brand-new runs in an arbitrary place — usually the
 * bottom, which is exactly where a user looking for "what is happening now"
 * will not look. `createdAt` always exists and always orders correctly.
 */
export async function listCatalogActivity(
  userId: string,
  options: { cursor?: string; limit?: number } = {}
): Promise<ListActivityResult> {
  const catalog = await Catalog.findOne({ userId: new Types.ObjectId(userId), deletedAt: null })
    .select({ _id: 1 })
    .lean()
    .exec();
  if (!catalog) return { outcome: 'NOT_FOUND' };

  const limit = Math.min(ACTIVITY_MAX_LIMIT, Math.max(1, options.limit ?? ACTIVITY_DEFAULT_LIMIT));

  let after: { createdAt: Date; id: string } | null = null;
  if (options.cursor) {
    const decoded = decodeCursor(options.cursor);
    // A tampered or cross-list cursor is a clean 400, never a 500 and never a
    // silently wrong page.
    if (!decoded) return { outcome: 'BAD_CURSOR' };
    after = { createdAt: decoded.updatedAt, id: decoded.id };
  }

  const query = {
    catalogId: catalog._id as Types.ObjectId,
    ...(after
      ? {
          $or: [
            { createdAt: { $lt: after.createdAt } },
            { createdAt: after.createdAt, _id: { $lt: new Types.ObjectId(after.id) } },
          ],
        }
      : {}),
  };

  // One extra row is the "is there a next page?" probe — cheaper and more
  // accurate than a countDocuments alongside the find.
  const rows = await CatalogPublishRun.find(query)
    .sort({ createdAt: -1, _id: -1 })
    .limit(limit + 1)
    .lean()
    .exec();

  const page = rows.slice(0, limit);
  const hasMore = rows.length > limit;
  const last = page[page.length - 1];

  return {
    outcome: 'OK',
    page: {
      runs: page.map(toRunDto),
      ...(hasMore && last
        ? { nextCursor: encodeCursor(last.createdAt, String(last._id)) }
        : {}),
    },
  };
}

function toRunDto(run: {
  _id: unknown;
  state: PublishRunState;
  mode: PublishMode;
  counts: { total: number; synced: number; failed: number; skipped: number };
  startedAt?: Date;
  finishedAt?: Date;
  error?: { code: string; message: string };
  entries: {
    target: PublishTargetKind;
    targetId?: string;
    targetName?: string;
    action: PublishAction;
    outcome: PublishOutcome;
    code?: string;
    at: Date;
  }[];
}): ActivityRunDto {
  return {
    id: String(run._id),
    state: run.state,
    mode: run.mode,
    counts: {
      total: run.counts.total,
      synced: run.counts.synced,
      failed: run.counts.failed,
      skipped: run.counts.skipped,
    },
    startedAt: run.startedAt?.toISOString() ?? null,
    // A RUNNING run appears in the list with no finish time, which is what the
    // screen wants: "publishing now" is the most interesting row on it.
    finishedAt: run.finishedAt?.toISOString() ?? null,
    ...(run.error ? { error: { code: run.error.code, message: run.error.message } } : {}),
    entries: run.entries.map((entry) => ({
      target: entry.target,
      ...(entry.targetId ? { targetId: entry.targetId } : {}),
      ...(entry.targetName ? { targetName: entry.targetName } : {}),
      action: entry.action,
      outcome: entry.outcome,
      ...(entry.code
        ? { code: entry.code, message: messageForSyncCode(entry.code) }
        : {}),
      at: entry.at.toISOString(),
    })),
  };
}

// ── Retention (Q11) ─────────────────────────────────────────────────────────

/**
 * Keeps the newest `CATALOG_ACTIVITY_RETAINED_RUNS` runs for a catalog and
 * deletes the rest.
 *
 * CALLED ON WRITE, from the endpoint that creates a run — one extra query per
 * publish, which is nothing next to the publish itself, and it means the bound
 * holds continuously rather than whenever a sweep last ran. A TTL index was the
 * alternative and is the wrong shape: it expires on AGE, so a business that
 * publishes twice a year would open the activity screen to nothing at all,
 * while one publishing hourly would still accumulate a month of noise.
 *
 * Best-effort by design. A failed prune must never turn a successful publish
 * into an error — the worst case is a few extra documents until the next one.
 */
export async function pruneRunHistory(catalogId: Types.ObjectId): Promise<number> {
  const keep = env.CATALOG_ACTIVITY_RETAINED_RUNS;

  const survivors = await CatalogPublishRun.find({ catalogId })
    .sort({ createdAt: -1, _id: -1 })
    .limit(keep)
    .select({ _id: 1 })
    .lean()
    .exec();

  if (survivors.length < keep) return 0;

  const result = await CatalogPublishRun.deleteMany({
    catalogId,
    _id: { $nin: survivors.map((run) => run._id) },
  }).exec();

  return result.deletedCount ?? 0;
}
