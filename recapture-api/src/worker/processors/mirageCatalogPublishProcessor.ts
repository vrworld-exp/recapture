// src/worker/processors/mirageCatalogPublishProcessor.ts
//
// The MIRAGE_CATALOG_PUBLISH processor: take one CatalogPublishRun, plan it
// from a frozen snapshot, walk the plan, and finalise.
//
// WHAT THIS FILE IS AND IS NOT. It is the orchestration — the run state
// machine, the sequential walk, the per-row isolation, the §7.8 finalize rule.
// It is NOT where Mirage is called: every step goes through an injected
// executor (services/catalog/publishExecutors.ts) whose B1 default records
// SKIPPED. B2 replaces the category and product executors, B3 the assets
// behind them, B4 the restaurant one. That seam is the whole point of the
// split, and it is why this file's tests need neither Mirage nor S3.
//
// THREE PROPERTIES THE SHAPE BELOW EXISTS TO GUARANTEE:
//
//   • Sequential. Mirage has no batch endpoints and runs on a tier that sleeps
//     (index.js self-pings every 30 s to stay awake). Parallelising the walk
//     would multiply the wake-up cost, race its non-atomic writes, and make the
//     duplicate-name reconciliation in B2 undecidable. `for … of` with `await`
//     inside is deliberate; do not "optimise" it into Promise.all.
//
//   • Per-row isolation. One product that Mirage refuses records FAILED on its
//     own entry and its own row, and the walk continues. A catalog of fifty
//     products must not be held hostage by the one with a bad image.
//
//   • Resumable. A worker that dies mid-run has its lease re-claimed by
//     claimNextJob, and this processor re-enters a RUNNING run, re-plans from
//     LIVE row state (so everything already SYNCED plans as SKIP) and finishes
//     it. The entries written by the dead attempt stay on the document.
import { Types } from 'mongoose';

import type {
  PublishMode,
  PublishRunEntry,
  PublishRunState,
} from '@/models/types/catalog.types';
import { PUBLISH_MODES } from '@/models/types/catalog.types';
import { CatalogPublishRun } from '@/models/CatalogPublishRun';
import {
  getPublishExecutors,
  type PublishRunContext,
  type PublishStepResult,
} from '@/services/catalog/publishExecutors';
import {
  planPublish,
  planTotals,
  type PublishPlan,
  type PublishStep,
} from '@/services/catalog/publishPlanner';
import {
  appendRunEntry,
  beginRun,
  finalizeCatalogAfterRun,
  finalizeRun,
  markCategoryFailed,
  markProductFailed,
  resetRunCounts,
  resolveRunState,
} from '@/services/catalog/publishRunState';
import {
  CatalogSnapshotMissingError,
  takeCatalogSnapshot,
  type CatalogSnapshot,
} from '@/services/catalog/publishSnapshot';
import { MirageError } from '@/services/mirage';
import { track, AnalyticsEvent } from '@/utils/analytics';
import { hashIdentifier } from '@/utils/otp';
import { log } from '@/worker/workerLog';
import {
  DEFAULT_MAX_ATTEMPTS,
  NonRetryableJobError,
  type JobProcessor,
  type WorkerJob,
} from '@/worker/workerTypes';

/** Stable codes this processor can put on a run or a row. */
export const PublishErrorCode = {
  /** The job's payload is not the shape the enqueue path writes. */
  JOB_MALFORMED: 'PUBLISH_JOB_MALFORMED',
  /** The run document is gone — nothing to execute against. */
  RUN_MISSING: 'PUBLISH_RUN_MISSING',
  /** The catalog was hard-deleted between enqueue and execution. */
  CATALOG_MISSING: 'PUBLISH_CATALOG_MISSING',
  /** Mirage rejected our credential; an operator has to fix it. */
  AUTH_REJECTED: 'PUBLISH_AUTH_REJECTED',
  /** An executor threw something we do not recognise. Row-scoped. */
  STEP_FAILED: 'PUBLISH_STEP_FAILED',
  /** The restaurant could not be provisioned, so nothing under it can publish. */
  RESTAURANT_UNAVAILABLE: 'PUBLISH_RESTAURANT_UNAVAILABLE',
} as const;

/** The job payload the publish endpoints write. */
export interface MirageCatalogPublishPayload {
  catalogId: string;
  publishRunId: string;
  mode: PublishMode;
  /** Optional narrowing, intersected with the mode's own selection. */
  productIds?: string[];
}

function isObjectIdHex(value: unknown): value is string {
  return typeof value === 'string' && /^[a-f0-9]{24}$/i.test(value);
}

/**
 * Reads the payload defensively.
 *
 * A malformed payload is terminal by construction — the enqueue path always
 * writes all three fields, so anything else is a bug or a hand-edited document,
 * and neither heals with a retry.
 */
function parsePayload(job: WorkerJob): MirageCatalogPublishPayload {
  const payload = job.payload ?? {};
  const catalogId = payload.catalogId;
  const publishRunId = payload.publishRunId;
  const mode = payload.mode;
  const productIds = payload.productIds;

  if (
    !isObjectIdHex(catalogId) ||
    !isObjectIdHex(publishRunId) ||
    typeof mode !== 'string' ||
    !(PUBLISH_MODES as readonly string[]).includes(mode)
  ) {
    throw new NonRetryableJobError(
      PublishErrorCode.JOB_MALFORMED,
      'This publish job is missing the catalog, the run or the mode it was created for.'
    );
  }

  return {
    catalogId,
    publishRunId,
    mode: mode as PublishMode,
    ...(Array.isArray(productIds) && productIds.every(isObjectIdHex)
      ? { productIds }
      : {}),
  };
}

/**
 * Would the worker turn this throw into a terminal FAILED, or into a retry?
 *
 * The distinction decides whether the run finalises and the catalog's
 * `activePublishRunId` is released. Releasing it on a RETRYABLE throw would let
 * the user start a second publish while the first one is still queued to
 * resume, and two runs racing Mirage's non-idempotent writes is the exact
 * failure the lock exists to prevent.
 */
function willBeTerminal(err: unknown, job: WorkerJob): boolean {
  if (err instanceof NonRetryableJobError) return true;
  const attempts = (job.attempts ?? 0) + 1;
  const maxAttempts = job.maxAttempts ?? DEFAULT_MAX_ATTEMPTS;
  return attempts >= maxAttempts;
}

/**
 * Runs one step and normalises everything it can throw into either a row-level
 * result or a job-level throw.
 *
 *   retryable MirageError → rethrown. Mirage is down or slow; that is not this
 *                           product's fault and marking fifty rows FAILED over
 *                           it would be a lie. The worker backs off and the run
 *                           resumes.
 *   auth MirageError      → terminal for the RUN. The adapter already spent its
 *                           one token refresh; a credential nobody has fixed
 *                           will reject every remaining row identically.
 *   anything else         → the ROW failed. This includes an executor bug: the
 *                           guarantee that one product cannot abort a run is
 *                           worth more than the tidiness of crashing on an
 *                           unexpected exception, and the raw message is logged
 *                           server-side (never stored, never returned) so the
 *                           row is triageable.
 */
async function runStep(
  step: PublishStep,
  context: PublishRunContext
): Promise<PublishStepResult> {
  // A SKIP never reaches an executor. The planner has already proved Mirage
  // matches what we last pushed, so there is nothing to call — and doing it
  // here rather than in each executor is what makes "republishing an unchanged
  // catalog performs zero Mirage writes" a property of the walk instead of
  // three separate implementations remembering to check.
  if (step.action === 'SKIP') return { outcome: 'SKIPPED' };

  const executor = getPublishExecutors()[step.target];
  try {
    return await executor(step, context);
  } catch (err: unknown) {
    if (err instanceof NonRetryableJobError) throw err;
    if (err instanceof MirageError) {
      if (err.isRetryable) throw err;
      if (err.failureClass === 'auth') {
        throw new NonRetryableJobError(PublishErrorCode.AUTH_REJECTED, err.message);
      }
      return { outcome: 'FAILED', code: err.code, message: err.message };
    }

    log('warn', 'Publish step threw an unclassified error', {
      runId: context.runId,
      target: step.target,
      targetId: step.targetId,
      action: step.action,
      // Diagnostic only. This never reaches the row, the response or analytics.
      raw: err instanceof Error ? err.message : String(err),
    });
    return {
      outcome: 'FAILED',
      code: PublishErrorCode.STEP_FAILED,
      message: 'Publishing this item failed unexpectedly. Try again.',
    };
  }
}

/** The row-side write that mirrors a FAILED entry. The restaurant has no row. */
async function recordRowFailure(step: PublishStep, result: PublishStepResult): Promise<void> {
  if (!step.targetId) return;
  const failure = {
    code: result.code ?? PublishErrorCode.STEP_FAILED,
    message: result.message ?? 'Publishing this item failed.',
  };
  if (step.target === 'CATEGORY') await markCategoryFailed(step.targetId, failure);
  if (step.target === 'PRODUCT') await markProductFailed(step.targetId, failure);
}

/** The run context later steps read the restaurant/category ids out of. */
function buildContext(
  runId: string,
  userId: string,
  mode: PublishMode,
  snapshot: CatalogSnapshot
): PublishRunContext {
  const mirageCategoryIds = new Map<string, string>();
  for (const category of snapshot.categories) {
    if (category.mirageCategoryId) mirageCategoryIds.set(category.id, category.mirageCategoryId);
  }
  return {
    runId,
    catalogId: snapshot.catalog.id,
    userId,
    mode,
    snapshot,
    ...(snapshot.catalog.mirageRestaurantId
      ? { mirageRestaurantId: snapshot.catalog.mirageRestaurantId }
      : {}),
    mirageCategoryIds,
    loggedOnce: new Set<string>(),
  };
}

export const mirageCatalogPublishProcessor: JobProcessor = async (job) => {
  const { catalogId, publishRunId, mode, productIds } = parsePayload(job);
  const runId = new Types.ObjectId(publishRunId);
  const catalogObjectId = new Types.ObjectId(catalogId);

  const run = await CatalogPublishRun.findById(runId).lean().exec();
  if (!run) {
    throw new NonRetryableJobError(
      PublishErrorCode.RUN_MISSING,
      'The publish run this job was created for no longer exists.'
    );
  }

  const started = await beginRun(runId);
  if (started.outcome === 'MISSING') {
    throw new NonRetryableJobError(
      PublishErrorCode.RUN_MISSING,
      'The publish run this job was created for no longer exists.'
    );
  }
  if (started.outcome === 'ALREADY_FINISHED') {
    // A replayed job for a run that already reached a terminal state. Doing
    // nothing is the only correct answer: its outcome is what the user was
    // shown, and re-executing it would push a second copy of everything.
    return { runId: publishRunId, state: started.state, replayed: true };
  }

  const userIdHash = hashIdentifier(run.userId.toHexString());

  try {
    const snapshot = await takeCatalogSnapshot(catalogObjectId);
    const plan: PublishPlan = planPublish(snapshot, mode, {
      ...(productIds ? { productIds } : {}),
    });
    const totals = planTotals(plan);

    await resetRunCounts(runId, totals.total);
    track(AnalyticsEvent.CATALOG_PUBLISH_STARTED, {
      user_id_hash: userIdHash,
      catalog_id: catalogId,
      run_id: publishRunId,
      mode,
      planned_total: totals.total,
    });
    log('info', 'Publish run started', {
      runId: publishRunId,
      catalogId,
      mode,
      resumed: started.outcome === 'RESUMED',
      ...totals,
    });

    const context = buildContext(publishRunId, run.userId.toHexString(), mode, snapshot);
    const tally = { synced: 0, failed: 0, skipped: 0 };

    for (const step of plan.steps) {
      const result = await runStep(step, context);

      const entry: PublishRunEntry = {
        target: step.target,
        ...(step.targetId ? { targetId: step.targetId } : {}),
        ...(step.targetName ? { targetName: step.targetName } : {}),
        action: step.action,
        outcome: result.outcome,
        ...(result.outcome === 'FAILED'
          ? { code: result.code ?? PublishErrorCode.STEP_FAILED }
          : {}),
        at: new Date(),
      };
      await appendRunEntry(runId, entry);

      if (result.outcome === 'FAILED') {
        tally.failed += 1;
        await recordRowFailure(step, result);
        track(AnalyticsEvent.CATALOG_PUBLISH_TARGET_FAILED, {
          user_id_hash: userIdHash,
          catalog_id: catalogId,
          run_id: publishRunId,
          target: step.target,
          action: step.action,
          failure_reason: entry.code ?? PublishErrorCode.STEP_FAILED,
        });

        // The one failure that IS fatal to the rest of the plan. Every category
        // and every item hangs off a restaurant id; without one there is
        // nothing for the remaining steps to be created under, and attempting
        // them would produce a wall of identical parent-missing failures.
        if (step.target === 'RESTAURANT') {
          log('warn', 'Publish run aborted — no Mirage restaurant', {
            runId: publishRunId,
            catalogId,
            remainingSteps: plan.steps.length - (tally.synced + tally.failed + tally.skipped),
          });
          break;
        }
        continue;
      }

      if (result.outcome === 'SUCCEEDED') tally.synced += 1;
      else tally.skipped += 1;
    }

    const state = resolveRunState(tally);
    await finalizeRun(
      runId,
      state,
      state === 'FAILED'
        ? {
            code: PublishErrorCode.RESTAURANT_UNAVAILABLE,
            message: 'Nothing could be published this time. See the item list for details.',
          }
        : undefined
    );
    await finalizeCatalogAfterRun({
      catalogId: catalogObjectId,
      runId,
      mode,
      state,
      snapshotRevision: plan.snapshotRevision,
    });

    track(AnalyticsEvent.CATALOG_PUBLISH_FINISHED, {
      user_id_hash: userIdHash,
      catalog_id: catalogId,
      run_id: publishRunId,
      mode,
      state,
      total: totals.total,
      synced: tally.synced,
      failed: tally.failed,
      skipped: tally.skipped,
    });
    log('info', 'Publish run finished', {
      runId: publishRunId,
      catalogId,
      state,
      ...tally,
    });

    return { runId: publishRunId, state, counts: { total: totals.total, ...tally } };
  } catch (err: unknown) {
    const missing = err instanceof CatalogSnapshotMissingError;
    const fatal = missing
      ? new NonRetryableJobError(
          PublishErrorCode.CATALOG_MISSING,
          'The catalog this publish was created for no longer exists.'
        )
      : err;

    // A run-level failure the worker will RETRY leaves the run RUNNING and the
    // catalog still locked, so the resumed attempt picks up where it stopped.
    // A run-level failure the worker will not retry is terminal, and terminal
    // means the catalog MUST be released — a catalog holding a dead run id can
    // never be published again by anyone.
    if (willBeTerminal(fatal, job)) {
      const state: PublishRunState = 'FAILED';
      await finalizeRun(runId, state, {
        code: fatal instanceof NonRetryableJobError ? fatal.code : PublishErrorCode.STEP_FAILED,
        message:
          fatal instanceof NonRetryableJobError
            ? fatal.message
            : 'Publishing failed. Try again in a moment.',
      });
      await finalizeCatalogAfterRun({
        catalogId: catalogObjectId,
        runId,
        mode,
        state,
        snapshotRevision: run.snapshotRevision,
      });
      track(AnalyticsEvent.CATALOG_PUBLISH_FINISHED, {
        user_id_hash: userIdHash,
        catalog_id: catalogId,
        run_id: publishRunId,
        mode,
        state,
        total: run.counts.total,
        synced: 0,
        failed: 0,
        skipped: 0,
      });
    }

    throw fatal;
  }
};
