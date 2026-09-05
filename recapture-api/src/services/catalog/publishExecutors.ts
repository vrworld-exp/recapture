// src/services/catalog/publishExecutors.ts
//
// The seam between "what to publish" (the pure planner) and "how to publish it"
// (the Mirage calls). B1 defines the contract and ships no-op defaults that
// record SKIPPED; B2 replaces the category and product implementations, B3 the
// asset uploader behind the product one. THE EXPORTED SIGNATURES ARE STABLE —
// treat a change to them as a change to two other tasks.
//
// WHY THIS LIVES IN services/ AND NOT IN THE PROCESSOR. The implementations are
// services (categorySync.ts, productSync.ts) and services must not import from
// `src/worker/` (AGENTS.md §layering). Putting the interfaces beside the
// processor would invert that dependency the moment B2 landed. The processor
// imports from here; nothing here imports from the worker.
//
// The registry is the same shape as `setMirageClient`/`resetMirageClient`: a
// module-level swap point that tests drive directly, rather than a DI container
// nothing else in this codebase has.
import type { PublishOutcome } from '@/models/types/catalog.types';
import type { PublishMode } from '@/models/types/catalog.types';
import type { PublishStep } from '@/services/catalog/publishPlanner';
import type { CatalogSnapshot } from '@/services/catalog/publishSnapshot';

/**
 * State that is discovered DURING a run and that later steps depend on.
 *
 * This is the answer to "a catalog with no `mirageRestaurantId` plans a CREATE,
 * and every later step must consume the id that step produced". The snapshot is
 * frozen and still says the restaurant does not exist; the context is where the
 * run's own progress is recorded, and it is what the executors read.
 */
export interface PublishRunContext {
  readonly runId: string;
  readonly catalogId: string;
  readonly userId: string;
  readonly mode: PublishMode;
  /** Frozen. Read it; never write through it. */
  readonly snapshot: CatalogSnapshot;
  /** Written by the RESTAURANT step, read by everything after it. */
  mirageRestaurantId?: string;
  /**
   * ReCapture category id → Mirage category id, as resolved so far this run.
   * Seeded from the snapshot's existing mappings and updated by each CATEGORY
   * step, so a product created three steps later files itself under the id that
   * was actually minted rather than the absent one the snapshot recorded.
   */
  readonly mirageCategoryIds: Map<string, string>;
  /**
   * The materialised "Uncategorized" Mirage category, created at most ONCE per
   * run and only for catalogs that need it (feature 26). B2 fills this in.
   */
  uncategorizedMirageCategoryId?: string;
  /**
   * One-per-run log de-duplication (B3 logs the "no USDZ" gap once, not once per
   * product). Keys are free-form; the set is per-run and never persisted.
   */
  readonly loggedOnce: Set<string>;
}

/**
 * What one step did.
 *
 * `code` and `message` are OURS — an `UPPER_SNAKE` code and the sentence we
 * show for it. Mirage's prose is a classification input inside the adapter and
 * must never reach here (catalog.types.ts SyncError).
 *
 * An executor returns this for row-level outcomes. It THROWS only when the
 * failure is not the row's fault and the whole job should back off and retry —
 * an unreachable Mirage, a rejected credential, a 5xx. The processor rethrows
 * those so the worker's existing 1→2→4-minute backoff handles them, leaving the
 * run RUNNING and the entries written so far intact.
 */
export interface PublishStepResult {
  outcome: PublishOutcome;
  /** Required when `outcome` is FAILED. */
  code?: string;
  /** Our user-facing sentence, stored on the row's `syncError`. */
  message?: string;
}

export type PublishStepExecutor = (
  step: PublishStep,
  context: PublishRunContext
) => Promise<PublishStepResult>;

/**
 * The three executors a run walks through. The planner emits exactly these
 * three target kinds (PUBLISH_TARGET_KINDS), so the record is total and a new
 * target kind is a compile error here.
 */
export interface PublishExecutors {
  /**
   * Provisions or updates the Mirage restaurant and writes
   * `context.mirageRestaurantId`. B4 wires this to the existing
   * `provisionCatalog` / `syncCatalogBranding`.
   */
  RESTAURANT: PublishStepExecutor;
  /** B2 — `services/catalog/categorySync.ts`. */
  CATEGORY: PublishStepExecutor;
  /** B2 — `services/catalog/productSync.ts` (assets via B3). */
  PRODUCT: PublishStepExecutor;
}

/**
 * The default: do nothing, report SKIPPED.
 *
 * Deliberately not a throw. B1's processor test drives a full run end to end
 * with these in place, and a default that exploded would make "the skeleton
 * walks the plan and finalises correctly" untestable until B2 exists.
 */
const noopExecutor: PublishStepExecutor = async () => ({ outcome: 'SKIPPED' });

const DEFAULT_EXECUTORS: PublishExecutors = {
  RESTAURANT: noopExecutor,
  CATEGORY: noopExecutor,
  PRODUCT: noopExecutor,
};

let executors: PublishExecutors = { ...DEFAULT_EXECUTORS };

/** The executor set the processor dispatches on. */
export function getPublishExecutors(): PublishExecutors {
  return executors;
}

/**
 * Installs real (or fake) executors. Partial so B2 can land the category and
 * product implementations without inventing a restaurant one, and so a test can
 * stub a single target kind.
 */
export function setPublishExecutors(overrides: Partial<PublishExecutors>): void {
  executors = { ...executors, ...overrides };
}

/** Back to the no-op defaults. Call in a test's `afterEach`. */
export function resetPublishExecutors(): void {
  executors = { ...DEFAULT_EXECUTORS };
}
