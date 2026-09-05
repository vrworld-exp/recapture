// src/services/catalogModelPromotionService.ts
//
// When Meshy finishes, the dishes that linked the model while it was still
// generating gain their assets and their AR button — on their own, with nobody
// tapping anything.
//
// ── BEST-EFFORT BY CONTRACT ─────────────────────────────────────────────────
// The caller is meshyModelProcessor, and a generation that reached this point
// has ALREADY COST MESHY CREDITS and already produced a usable model. Failing
// that job because a promotion did not work would turn a recoverable
// bookkeeping miss into a wasted spend and a retry that pays again. So nothing
// here is allowed to become the job's problem: the processor wraps the call in
// try/catch, and this file is written so that even the parts that CAN fail
// (the publish enqueue) are ordered after the parts that must not.
//
// ── THE ORDER IS THE WHOLE DESIGN ───────────────────────────────────────────
// Write the product rows, bump the revision, THEN try to publish. The rows are
// the source of truth; the enqueue is an optimization on when they reach the
// public page. Reverse the order and a lost publish-lock race would leave
// products that never got their assets at all.
//
// Import direction: this lives in services/ and imports models plus
// catalogPublishService. The worker imports it. Services must never import from
// the worker, and nothing here does.
import { Types } from 'mongoose';

import { Catalog } from '@/models/Catalog';
import { CatalogProduct } from '@/models/CatalogProduct';
import { ProjectModel } from '@/models/ProjectModel';
import type { ProductAssets } from '@/models/types/catalog.types';
import { bumpDraftRevision } from '@/services/catalogService';
import { requestPublish } from '@/services/catalogPublishService';

export interface PromotionResult {
  /** Products whose assets were written by THIS call. */
  promoted: number;
  /** Catalogs asked to publish. Fewer than `promoted` when a lock was held. */
  publishesRequested: number;
}

const NOTHING: PromotionResult = { promoted: 0, publishesRequested: 0 };

/**
 * Promotes a finished model's artifacts onto every product that linked it while
 * it was still generating, and asks for a re-publish.
 *
 * Idempotent: the `modelStatus` filter in step 2 is what makes a re-run a
 * no-op. A product already promoted is READY, matches nothing, and is neither
 * rewritten nor re-counted — which matters because the worker may re-run this
 * processor after a crash or a lease takeover.
 */
export async function promoteModelToProducts(modelId: Types.ObjectId): Promise<PromotionResult> {
  // ── 1) The model must actually be finished and usable ─────────────────────
  const model = await ProjectModel.findById(modelId).select('status artifacts').lean().exec();
  if (!model || model.status !== 'SUCCEEDED' || !model.artifacts?.cdnUrls?.glb) return NOTHING;

  const cdn = model.artifacts.cdnUrls;
  // COPIED, NOT RESOLVED. The product is a snapshot of the model it was given,
  // so a later regeneration or optimization of the same record cannot silently
  // change what an already-published product points at. Exactly the rule
  // createProduct follows for a model that was ready at link time.
  const assets: ProductAssets = {
    glbUrl: cdn.glb,
    ...(cdn.usdz ? { usdzUrl: cdn.usdz } : {}),
    ...(cdn.preview ? { thumbnailUrl: cdn.preview } : {}),
  };

  // ── 2) The products still waiting on it ───────────────────────────────────
  const waiting = await CatalogProduct.find({
    sourceModelId: modelId,
    deletedAt: null,
    modelStatus: { $in: ['QUEUED', 'PROCESSING'] },
  })
    .select('_id catalogId')
    .lean()
    .exec();
  if (waiting.length === 0) return NOTHING;

  // ── 3) One write per product, and it must land ────────────────────────────
  // `syncStatus: 'PENDING'` is what the planner reads to decide this row has
  // something to send; without it a promoted product would sit on the menu with
  // its old (absent) assets until some unrelated edit happened to touch it.
  const promotion = await CatalogProduct.updateMany(
    {
      _id: { $in: waiting.map((p) => p._id) },
      modelStatus: { $in: ['QUEUED', 'PROCESSING'] },
    },
    { $set: { assets, modelStatus: 'READY', syncStatus: 'PENDING' } }
  ).exec();

  const promoted = promotion.modifiedCount;
  if (promoted === 0) return NOTHING;

  // ── 4) The revision, per catalog ──────────────────────────────────────────
  // A promotion IS a change to what the public page should show, so it moves
  // `draftRevision` like any authoring edit. Without the bump a catalog that
  // finishes its publish would read as fully live while a dish is still 2D.
  const catalogIds = [...new Set(waiting.map((p) => String(p.catalogId)))];
  for (const id of catalogIds) {
    await bumpDraftRevision(new Types.ObjectId(id));
  }

  // ── 5) The enqueue — the OPTIMIZATION, never the obligation ───────────────
  let publishesRequested = 0;
  for (const id of catalogIds) {
    if (await tryPublish(new Types.ObjectId(id))) publishesRequested++;
  }

  return { promoted, publishesRequested };
}

/**
 * Asks for a publish, and treats every refusal as normal.
 *
 * ⚠ NEVER MOVE THE FIELD WRITES BELOW THIS CALL, AND NEVER PROPAGATE ITS ERROR.
 *
 * Six dishes finishing within seconds of each other WILL collide on the publish
 * lock. `openRun` makes the loser a clean IN_PROGRESS and rolls back its own run
 * and job — that behaviour is correct and must not be changed. What matters
 * here is the reaction: the rows are already written with `syncStatus: PENDING`
 * and a bumped `draftRevision`, so a lost race costs publish LATENCY, not a
 * promotion. The run holding the lock either already includes these rows (it
 * snapshots at plan time) or `finalizeCatalogAfterRun`'s sweep enqueues the
 * follow-up that does.
 *
 * BLOCKED is equally normal: an unprovisioned or gated catalog is not ready to
 * publish for reasons that have nothing to do with this model.
 */
async function tryPublish(catalogId: Types.ObjectId): Promise<boolean> {
  try {
    const catalog = await Catalog.findOne({ _id: catalogId, deletedAt: null })
      .select('userId')
      .lean()
      .exec();
    if (!catalog) return false;

    const result = await requestPublish(String(catalog.userId));
    if (result.outcome === 'QUEUED') return true;

    console.info(
      `[promotion] publish not enqueued for ${catalogId.toHexString()} (${result.outcome}) — ` +
        'rows stay PENDING for the next run'
    );
    return false;
  } catch (err) {
    // The rows are already correct. A publish that could not even be requested
    // is a latency problem, and the finalize sweep or the owner's next publish
    // resolves it.
    console.warn('[promotion] publish request threw; rows are unaffected', err);
    return false;
  }
}

/**
 * The follow-up run for promotions that landed while the lock was held.
 *
 * THE GAP THIS CLOSES: a promotion that loses the lock race while the ACTIVE
 * run has already taken its snapshot leaves rows `syncStatus: PENDING` with
 * nobody coming for them. `draftRevision > snapshotRevision` is exactly "a
 * change landed after this run was planned", which is the same signal the
 * "unpublished changes" badge is built on.
 *
 * ONE FOLLOW-UP, NOT A LOOP. If this run also collides, the finalize after it
 * catches the same rows. Called from the publish processor after
 * `finalizeCatalogAfterRun` — the one moment the lock is guaranteed free —
 * rather than from a periodic scanner, which would be a background process
 * nobody monitors and one more thing that can drift.
 *
 * Returns whether a run was enqueued. Never throws: it is called on the way out
 * of a publish that has already succeeded.
 */
export async function sweepPromotedProducts(
  catalogId: Types.ObjectId,
  snapshotRevision: number
): Promise<boolean> {
  try {
    const catalog = await Catalog.findOne({ _id: catalogId, deletedAt: null })
      .select('draftRevision')
      .lean()
      .exec();
    if (!catalog || catalog.draftRevision <= snapshotRevision) return false;

    // Narrow to the case this sweep exists for. An ordinary edit made during the
    // run is the owner's to publish when they choose; a promotion is something
    // the system did on its own, so the system owes it a run.
    const stranded = await CatalogProduct.exists({
      catalogId,
      deletedAt: null,
      archivedAt: null,
      syncStatus: 'PENDING',
      modelStatus: 'READY',
    }).exec();
    if (!stranded) return false;

    return await tryPublish(catalogId);
  } catch (err) {
    console.warn('[promotion] follow-up sweep failed; rows stay PENDING', err);
    return false;
  }
}

/**
 * Marks every product waiting on a model as FAILED.
 *
 * THE DISH STAYS ON THE MENU. It keeps its name, price, category and place in
 * the order; it simply has no AR button. The product is not deleted and the
 * model is not unlinked, because a human may want to retry generation against
 * this exact product — and because deleting a dish a restaurant typed in
 * because OUR generation failed is not a defensible thing to do.
 *
 * A product that already carries assets (a READY dish whose REPLACEMENT model
 * failed) is deliberately left alone by the same `modelStatus` filter: it is
 * still rendering the previous model perfectly well, and the failure of the new
 * one is not a reason to take that away.
 */
export async function markModelFailedOnProducts(modelId: Types.ObjectId): Promise<number> {
  const result = await CatalogProduct.updateMany(
    { sourceModelId: modelId, deletedAt: null, modelStatus: { $in: ['QUEUED', 'PROCESSING'] } },
    { $set: { modelStatus: 'FAILED' } }
  ).exec();
  return result.modifiedCount;
}

/**
 * Mirrors a model's in-flight status onto the products waiting on it.
 *
 * Without this a dish linked while its model was QUEUED would read QUEUED
 * forever, and a client polling it has nothing to show. Called from the worker
 * at the same point it moves `ProjectModel.status`, so the two never disagree
 * by more than one write.
 *
 * Only ever moves a row between the two pending states — READY and FAILED are
 * terminal here, and NONE means the product is not waiting on anything.
 */
export async function syncPendingModelStatus(
  modelId: Types.ObjectId,
  status: 'QUEUED' | 'PROCESSING'
): Promise<number> {
  const result = await CatalogProduct.updateMany(
    { sourceModelId: modelId, deletedAt: null, modelStatus: { $in: ['QUEUED', 'PROCESSING'] } },
    { $set: { modelStatus: status } }
  ).exec();
  return result.modifiedCount;
}
