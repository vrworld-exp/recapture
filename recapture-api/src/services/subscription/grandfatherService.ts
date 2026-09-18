// src/services/subscription/grandfatherService.ts
//
// The launch-day grandfather: every catalog that is already live on Mirage
// gets a COMPED subscription for `grandfatherDays`, so nothing goes dark the
// day the gates switch on (RECAPTURE_SUBSCRIPTION_PLAN.md §8 D1).
//
// The judgement and the write live here, not in the script, so a test can run
// them against an in-memory store — scripts/grandfather-catalogs-comped.ts is
// the argv-and-connect wrapper (the same split as release-stuck-publish).
import { Types } from 'mongoose';

import { Catalog } from '@/models/Catalog';
import { CatalogSubscription } from '@/models/CatalogSubscription';
import { UNCAPPED_THREE_D } from '@/models/types/subscription.types';
import { getPlanCatalog } from '@/services/subscription/planCatalogService';

const DAY_MS = 86_400_000;

export interface GrandfatherCandidate {
  catalogId: Types.ObjectId;
  userId: Types.ObjectId;
  /** Catalog content — for the terminal, never for analytics. */
  name: string;
}

export interface GrandfatherSummary {
  /** Provisioned, live catalogs looked at. */
  scanned: number;
  /** Rows inserted by THIS run. */
  comped: number;
  /** Already had a subscription (before the run, or from a concurrent one). */
  skipped: number;
  /** What a dry run would have comped; what a real run tried to. */
  candidates: GrandfatherCandidate[];
}

/**
 * "Provisioned" means a Mirage restaurant exists for it — the same partial
 * filter Catalog's mapping index uses — and it is not soft-deleted. A DRAFT
 * catalog nobody has published is not live and gets nothing; its owner starts
 * a trial like everyone else.
 */
async function provisionedCatalogs(): Promise<GrandfatherCandidate[]> {
  const rows = await Catalog.find({
    deletedAt: null,
    mirageRestaurantId: { $type: 'string' },
  })
    .select({ _id: 1, userId: 1, name: 1 })
    .sort({ _id: 1 })
    .lean()
    .exec();
  return rows.map((row) => ({
    catalogId: row._id as Types.ObjectId,
    userId: row.userId,
    name: row.name,
  }));
}

function isDuplicateKey(err: unknown): boolean {
  return (
    typeof err === 'object' &&
    err !== null &&
    'code' in err &&
    (err as { code?: unknown }).code === 11000
  );
}

/**
 * Comps every provisioned catalog that has no subscription row yet.
 *
 * Idempotent and safe to run twice at once: the decision "has no row" is
 * re-made by the unique index at insert time, and a loser's E11000 is counted
 * as `skipped`, not thrown. `now` is injectable so a test can pin the period.
 */
export async function grandfatherCatalogsComped(options: {
  dryRun: boolean;
  now?: Date;
}): Promise<GrandfatherSummary> {
  const now = options.now ?? new Date();
  const { grandfatherDays } = await getPlanCatalog();

  const catalogs = await provisionedCatalogs();
  const existing = await CatalogSubscription.find({
    catalogId: { $in: catalogs.map((c) => c.catalogId) },
  })
    .select({ catalogId: 1 })
    .lean()
    .exec();
  const hasRow = new Set(existing.map((row) => String(row.catalogId)));

  const candidates = catalogs.filter((c) => !hasRow.has(String(c.catalogId)));
  const summary: GrandfatherSummary = {
    scanned: catalogs.length,
    comped: 0,
    skipped: catalogs.length - candidates.length,
    candidates,
  };

  if (options.dryRun) return summary;

  for (const candidate of candidates) {
    try {
      // One document per insert (no insertMany): a duplicate must fail ONLY
      // its own row, and the schema's validation and defaults still apply.
      await CatalogSubscription.create({
        catalogId: candidate.catalogId,
        userId: candidate.userId,
        status: 'COMPED',
        source: 'COMP',
        periodStart: now,
        periodEnd: new Date(now.getTime() + grandfatherDays * DAY_MS),
        threeDDishCap: UNCAPPED_THREE_D,
      });
      summary.comped += 1;
    } catch (err) {
      // A concurrent run got there first. Its row is the same row this one
      // would have written, so this is "already done", not a failure.
      if (!isDuplicateKey(err)) throw err;
      summary.skipped += 1;
    }
  }

  return summary;
}
