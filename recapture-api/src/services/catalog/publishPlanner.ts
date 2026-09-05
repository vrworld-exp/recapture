// src/services/catalog/publishPlanner.ts
//
// snapshot + mode → an ordered list of steps. THE PURE UNIT of the publish
// feature: no Mongoose, no network, no clock, no randomness. Everything that
// decides *what* a publish does lives here, so it can be tested exhaustively as
// a table of inputs and outputs; everything that decides *how* lives in the
// executors, which are where the messy part (Mirage) is.
//
// Two properties this file exists to guarantee:
//
//   • DETERMINISM. Planning the same snapshot twice yields a byte-identical
//     plan. Nothing here reads the clock or a Set/Map iteration order that the
//     input can perturb, and both collections are re-sorted on an explicit
//     (position, id) comparator rather than trusting the query's sort.
//
//   • NO SILENT SKIPS. The product diff is a TABLE keyed by
//     `PRODUCT_DIFF_FIELDS`, declared as a total Record, so adding a field to
//     the vocabulary without giving it accessors is a compile error. That is
//     the structural version of the warning at catalog.types.ts:150-155: a
//     field the diff forgets reads back as "unchanged", and the product silently
//     never publishes the edit. `JSON.stringify(a) === JSON.stringify(b)` and
//     object spreads are both banned here for exactly that reason — key order
//     and dropped keys are invisible failures.
import { isModelPending } from '@/models/types/catalog.types';
import type {
  ProductPublishedSnapshot,
  PublishAction,
  PublishMode,
  PublishTargetKind,
} from '@/models/types/catalog.types';
import type {
  CatalogSnapshot,
  CatalogSnapshotCategory,
  CatalogSnapshotProduct,
} from '@/services/catalog/publishSnapshot';

// ── Vocabulary ──────────────────────────────────────────────────────────────

/**
 * Why the planner chose an action. Recorded on the step (and, for a failure,
 * alongside the entry) so the activity log can say "skipped — already up to
 * date" instead of leaving a bare SKIP the reader has to guess at.
 */
export const PUBLISH_STEP_REASONS = [
  /** No `mirageRestaurantId` — the run has to provision first. */
  'NOT_PROVISIONED',
  /** The row has never been pushed; there is nothing on Mirage to update. */
  'NO_MIRAGE_ID',
  /** Branding may have moved: the catalog's draft is ahead of its published revision. */
  'DRAFT_AHEAD_OF_PUBLISHED',
  /** At least one diffed field differs from `publishedSnapshot`. */
  'FIELDS_CHANGED',
  /** The row was edited after its last successful sync. */
  'EDITED_SINCE_SYNC',
  /** Mirage now holds this product under a different category than we filed it in. */
  'CATEGORY_REFILED',
  /** A mapping exists but no snapshot does — we cannot prove it matches. */
  'NO_SNAPSHOT',
  /** `syncStatus: 'FAILED'` — this is the row the retry exists for. */
  'PREVIOUS_ATTEMPT_FAILED',
  /** The user archived the row; it has to come off the public page. */
  'ARCHIVED',
  /** The row is soft-deleted but Mirage still has it. */
  'DELETED',
  /** Mode UNPUBLISH: every published item comes down. */
  'UNPUBLISH_REQUESTED',
  /** Nothing to do. */
  'UP_TO_DATE',
] as const;
export type PublishStepReason = (typeof PUBLISH_STEP_REASONS)[number];

/**
 * The product fields a publish pushes and therefore diffs.
 *
 * Adding one here without adding it to {@link PRODUCT_DIFF_ACCESSORS} does not
 * compile. Removing one silently stops publishing edits to it — so don't.
 */
export const PRODUCT_DIFF_FIELDS = [
  'name',
  'description',
  'price',
  'type',
  'categoryId',
  // Feature 48. Mirage's item schema carries `sortPosition` now, so display
  // order is a PUBLISHED field like any other — and a reorder that the diff did
  // not notice would leave the public page in the old order while the app
  // reported the publish as successful.
  //
  // ⚠ ONE-TIME REPUBLISH ON DEPLOY. A product published before this field
  // existed has a `publishedSnapshot` with no `position`, which reads as
  // "changed" and plans an UPDATE on the next run. That is correct, not a
  // regression: those items are on Mirage with no `sortPosition` at all, so the
  // update is the one that finally pushes it. It happens once per product.
  'position',
  'glbUrl',
  'usdzUrl',
  'thumbnailUrl',
  'imageKey',
] as const;
export type ProductDiffField = (typeof PRODUCT_DIFF_FIELDS)[number];

// ── Plan shapes ─────────────────────────────────────────────────────────────

export interface PublishStep {
  target: PublishTargetKind;
  /** The ReCapture id of the product/category. Absent for the restaurant. */
  targetId?: string;
  /** Denormalised for the run entry, which outlives the row it names. */
  targetName?: string;
  action: PublishAction;
  reason: PublishStepReason;
  /**
   * Which diffed fields differ, in {@link PRODUCT_DIFF_FIELDS} order. Present
   * only on a product UPDATE that came from a field diff — the executor sends
   * exactly these and nothing else, which is what keeps a price edit from
   * re-uploading a 40 MB model.
   */
  changedFields?: readonly ProductDiffField[];
}

export interface PublishPlan {
  catalogId: string;
  mode: PublishMode;
  /** The `draftRevision` this plan was built from. */
  snapshotRevision: number;
  steps: readonly PublishStep[];
}

export interface PlanPublishOptions {
  /**
   * Narrow the run to these product ids. Intersected with the mode's own
   * selection, never widened by it — a RETRY_FAILED that names a SYNCED product
   * still plans nothing for it.
   */
  productIds?: readonly string[];
}

// ── Field comparison ────────────────────────────────────────────────────────

/**
 * `undefined` and `null` are the same absence here — Mongo stores an unset
 * optional either way — but neither equals `0` or `''`. A product whose price
 * was cleared and a product that never had one are the same product to Mirage;
 * a product priced at 0 is not.
 */
function absent(value: unknown): boolean {
  return value === undefined || value === null;
}

function sameValue(a: unknown, b: unknown): boolean {
  if (absent(a) && absent(b)) return true;
  if (absent(a) || absent(b)) return false;
  return a === b;
}

interface DiffAccessor {
  current: (product: CatalogSnapshotProduct) => unknown;
  published: (snapshot: ProductPublishedSnapshot) => unknown;
}

/**
 * The diff table. Total over {@link ProductDiffField} by construction — that
 * `Record<ProductDiffField, …>` annotation is the compile-time guard, and it is
 * the whole reason this is a table rather than a hand-written `if` chain.
 */
const PRODUCT_DIFF_ACCESSORS: Record<ProductDiffField, DiffAccessor> = {
  name: { current: (p) => p.name, published: (s) => s.name },
  description: { current: (p) => p.description, published: (s) => s.description },
  price: { current: (p) => p.price, published: (s) => s.price },
  type: { current: (p) => p.type, published: (s) => s.type },
  categoryId: { current: (p) => p.categoryId, published: (s) => s.categoryId },
  position: { current: (p) => p.position, published: (s) => s.position },
  glbUrl: { current: (p) => p.glbUrl, published: (s) => s.glbUrl },
  usdzUrl: { current: (p) => p.usdzUrl, published: (s) => s.usdzUrl },
  thumbnailUrl: { current: (p) => p.thumbnailUrl, published: (s) => s.thumbnailUrl },
  imageKey: { current: (p) => p.imageKey, published: (s) => s.imageKey },
};

/**
 * Field-by-field difference between a product and what was last pushed for it.
 * Exported because the planner's most important test is "changing any one of
 * these is detected", and that test iterates PRODUCT_DIFF_FIELDS.
 */
export function diffProduct(
  product: CatalogSnapshotProduct,
  published: ProductPublishedSnapshot
): readonly ProductDiffField[] {
  return PRODUCT_DIFF_FIELDS.filter((field) => {
    const accessor = PRODUCT_DIFF_ACCESSORS[field];
    return !sameValue(accessor.current(product), accessor.published(published));
  });
}

// ── Ordering ────────────────────────────────────────────────────────────────

/**
 * (position, id). Applied here rather than relied on from the query, so the
 * plan is a function of the snapshot's CONTENT and not of how it was fetched —
 * which is what makes the determinism assertion meaningful.
 */
function byPositionThenId<T extends { position: number; id: string }>(a: T, b: T): number {
  if (a.position !== b.position) return a.position - b.position;
  return a.id < b.id ? -1 : a.id > b.id ? 1 : 0;
}

// ── Per-target decisions ────────────────────────────────────────────────────

/**
 * RESTAURANT.
 *
 * The branding decision is coarser than the product one on purpose: there is no
 * `publishedBranding` snapshot on the Catalog document, so there is nothing to
 * diff field-by-field against. `draftRevision > publishedRevision` is the exact
 * signal the product already uses for "something in this catalog changed since
 * we last published it" — it can plan a redundant branding UPDATE (cheap: one
 * JSON call, no assets unless a logo changed) but never a missed one, which is
 * the right direction to be wrong in. Add a branding snapshot to the Catalog
 * model and this becomes a real diff without touching any caller.
 */
function planRestaurant(snapshot: CatalogSnapshot, mode: PublishMode): PublishStep | null {
  const { catalog } = snapshot;

  if (!catalog.mirageRestaurantId) {
    return {
      target: 'RESTAURANT',
      targetName: catalog.name,
      action: 'CREATE',
      reason: 'NOT_PROVISIONED',
    };
  }

  // A retry is scoped to the rows that failed, and an unpublish does not touch
  // branding at all (§7.6 — the restaurant document is what the QR depends on).
  if (mode !== 'FULL') return null;

  return {
    target: 'RESTAURANT',
    targetName: catalog.name,
    action: catalog.draftRevision > catalog.publishedRevision ? 'UPDATE' : 'SKIP',
    reason:
      catalog.draftRevision > catalog.publishedRevision
        ? 'DRAFT_AHEAD_OF_PUBLISHED'
        : 'UP_TO_DATE',
  };
}

/** CATEGORY. Always planned before any product — see the ordering note below. */
function planCategory(category: CatalogSnapshotCategory): PublishStep {
  const base = {
    target: 'CATEGORY' as const,
    targetId: category.id,
    targetName: category.name,
  };

  if (!category.mirageCategoryId) {
    return { ...base, action: 'CREATE', reason: 'NO_MIRAGE_ID' };
  }
  if (category.syncStatus === 'FAILED') {
    return { ...base, action: 'UPDATE', reason: 'PREVIOUS_ATTEMPT_FAILED' };
  }
  if (!category.lastSyncedAt || category.updatedAt > category.lastSyncedAt) {
    return { ...base, action: 'UPDATE', reason: 'EDITED_SINCE_SYNC' };
  }
  return { ...base, action: 'SKIP', reason: 'UP_TO_DATE' };
}

/**
 * PRODUCT. Returns null when there is genuinely nothing to record — a product
 * the user deleted before it was ever published is not a step, it is a
 * non-event, and emitting a SKIP for it would put a row in the activity log for
 * something that never existed on the public page.
 */
function planProduct(
  product: CatalogSnapshotProduct,
  mode: PublishMode,
  mirageCategoryIdFor: (categoryId: string | null) => string | undefined
): PublishStep | null {
  const base = {
    target: 'PRODUCT' as const,
    targetId: product.id,
    targetName: product.name,
  };

  // A dish waiting on its FIRST model is not a step at all — the same kind of
  // non-event as a product deleted before it was ever published. It has no
  // assets to send, the gates already excluded it from this run, and it will
  // plan a CREATE by itself once promotion writes its assets. Guarded on
  // `mirageItemId` so a product that IS on Mirage always keeps being planned:
  // silently dropping a published row would strand it there forever.
  if (
    !product.mirageItemId &&
    isModelPending(product.modelStatus) &&
    !product.glbUrl &&
    mode !== 'UNPUBLISH'
  ) {
    return null;
  }

  const gone = Boolean(product.deletedAt) || Boolean(product.archivedAt);
  const wantsDelete = gone || mode === 'UNPUBLISH';

  if (wantsDelete) {
    if (!product.mirageItemId) return null;
    return {
      ...base,
      action: 'DELETE',
      reason:
        mode === 'UNPUBLISH'
          ? 'UNPUBLISH_REQUESTED'
          : product.deletedAt
            ? 'DELETED'
            : 'ARCHIVED',
    };
  }

  if (!product.mirageItemId) {
    return { ...base, action: 'CREATE', reason: 'NO_MIRAGE_ID' };
  }
  if (!product.publishedSnapshot) {
    return { ...base, action: 'UPDATE', reason: 'NO_SNAPSHOT' };
  }

  const changedFields = diffProduct(product, product.publishedSnapshot);
  if (changedFields.length > 0) {
    return { ...base, action: 'UPDATE', reason: 'FIELDS_CHANGED', changedFields };
  }

  // The item is filed under a Mirage category that is no longer the one this
  // product's category maps to — Mirage's delete-item cascade can destroy a
  // category out from under us, and B2's re-create mints a new id. Only a
  // KNOWN mismatch counts: a category that has not been created yet resolves to
  // undefined, and the executor (which mints it) is the authority there, so
  // treating "unknown" as a difference would make every uncategorized product
  // publish on every run.
  const resolved = mirageCategoryIdFor(product.categoryId);
  if (resolved && product.mirageCategoryIdAtSync && resolved !== product.mirageCategoryIdAtSync) {
    return { ...base, action: 'UPDATE', reason: 'CATEGORY_REFILED' };
  }

  if (product.syncStatus === 'FAILED') {
    return { ...base, action: 'UPDATE', reason: 'PREVIOUS_ATTEMPT_FAILED' };
  }

  return { ...base, action: 'SKIP', reason: 'UP_TO_DATE' };
}

// ── The planner ─────────────────────────────────────────────────────────────

/**
 * Builds the ordered plan for one run.
 *
 * ORDER IS LOAD-BEARING: restaurant, then categories, then products. Mirage's
 * create-item rejects a missing or invalid category ObjectId
 * (adminController.js:847-854), and create-category needs a real restaurant id,
 * so this is not a stylistic ordering — a plan in any other order cannot
 * execute. Within each group, (position, id).
 *
 * Pure: same snapshot + same mode + same options ⇒ identical plan, every time.
 */
export function planPublish(
  snapshot: CatalogSnapshot,
  mode: PublishMode,
  options: PlanPublishOptions = {}
): PublishPlan {
  const steps: PublishStep[] = [];

  const restaurant = planRestaurant(snapshot, mode);
  if (restaurant) steps.push(restaurant);

  const productIdFilter = options.productIds ? new Set(options.productIds) : null;
  const products = [...snapshot.products]
    .sort(byPositionThenId)
    .filter((product) => !productIdFilter || productIdFilter.has(product.id));

  // RETRY_FAILED means exactly the rows the last run could not publish
  // (feature 53) — not "everything, but skip the ones that worked", which would
  // still walk the whole catalog and re-verify it against Mirage.
  const selectedProducts =
    mode === 'RETRY_FAILED'
      ? products.filter((product) => product.syncStatus === 'FAILED')
      : products;

  const categoriesById = new Map(snapshot.categories.map((c) => [c.id, c]));
  const mirageCategoryIdFor = (categoryId: string | null): string | undefined =>
    categoryId ? categoriesById.get(categoryId)?.mirageCategoryId : undefined;

  const productSteps = selectedProducts
    .map((product) => planProduct(product, mode, mirageCategoryIdFor))
    .filter((step): step is PublishStep => step !== null);

  // Unpublishing takes items down; it must not create or rename categories on
  // the way. Everything else needs the categories its products will be filed
  // under to exist first.
  if (mode !== 'UNPUBLISH') {
    const needed = neededCategories(snapshot, mode, selectedProducts, categoriesById);
    steps.push(...needed.sort(byPositionThenId).map(planCategory));
  }

  steps.push(...productSteps);

  return {
    catalogId: snapshot.catalog.id,
    mode,
    snapshotRevision: snapshot.catalog.draftRevision,
    steps,
  };
}

/**
 * Which categories this run has to touch.
 *
 * FULL takes all of them — a rename has to reach the public page whether or not
 * any product under it changed. RETRY_FAILED takes only the categories that
 * failed, PLUS any category a retried product needs that has no Mirage id yet:
 * without that second clause, retrying a product whose category never got
 * created would fail forever on a missing parent, which is precisely the state
 * a crashed run leaves behind.
 */
function neededCategories(
  snapshot: CatalogSnapshot,
  mode: PublishMode,
  selectedProducts: readonly CatalogSnapshotProduct[],
  categoriesById: ReadonlyMap<string, CatalogSnapshotCategory>
): CatalogSnapshotCategory[] {
  if (mode === 'FULL') return [...snapshot.categories];

  const needed = new Map<string, CatalogSnapshotCategory>();
  for (const category of snapshot.categories) {
    if (category.syncStatus === 'FAILED') needed.set(category.id, category);
  }
  for (const product of selectedProducts) {
    if (!product.categoryId) continue;
    const category = categoriesById.get(product.categoryId);
    if (category && !category.mirageCategoryId) needed.set(category.id, category);
  }
  return [...needed.values()];
}

/** Step totals, for the run's `counts.total` and the publish screen. */
export function planTotals(plan: PublishPlan): {
  total: number;
  create: number;
  update: number;
  delete: number;
  skip: number;
} {
  const count = (action: PublishAction): number =>
    plan.steps.filter((step) => step.action === action).length;
  return {
    total: plan.steps.length,
    create: count('CREATE'),
    update: count('UPDATE'),
    delete: count('DELETE'),
    skip: count('SKIP'),
  };
}
