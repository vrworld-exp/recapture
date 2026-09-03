# Stage 5 — Pending Models and Asset Promotion

**Side:** backend · **Size:** L (≈ 2 days) · **Depends on:** nothing in this pack

---

## Goal

At the end of this stage a dish can appear on the live menu **before** its 3D model finishes
generating, and flip to AR-ready on its own when Meshy returns. The 2D menu is live on activation;
AR arrives per dish.

**This stage is independent of stages 2–4 and should be built in parallel — and landed first.** It
is the only stage that modifies an existing hot path (`meshyModelProcessor`), so it wants the most
soak time before reps depend on it.

> Read **C1** in [`00-preflight-and-corrections.md`](00-preflight-and-corrections.md) before you
> start. The plan's `productIds`-scoped re-publish would corrupt `publishedRevision`. This stage
> builds the simpler and correct thing instead.

---

## Prerequisites

None from this pack. But note the flow this stage extends **is dark today**:
`AUTO_MODEL_GENERATION_ENABLED` defaults `false` (`src/config/env.ts:268`) and the live
`autoModelGenerationEnabled` remote flag reads fail-closed. Turning both on is a real-spend
decision and belongs to [stage 7](stage-07-verification-and-rollout.md), not here. **You can build
and test this entire stage with the flags off** by enqueuing a `MESHY_MODEL_GENERATION` job
directly.

---

## Verified context

| Fact | Where |
|---|---|
| `resolveOwnedModel` rejects anything not `SUCCEEDED` with a `cdnUrls.glb` | `src/services/catalogProductsService.ts:393-395` |
| Ownership is proven through `Project.userId`, never the model row | `src/services/catalogProductsService.ts:383-390` |
| `rehostArtifacts` is the last real step of the meshy processor | `src/worker/processors/meshyModelProcessor.ts:96, 237` |
| `captureProcessingProcessor` calls `maybeAutoGenerateModel` as a last non-fatal step | `src/worker/processors/captureProcessingProcessor.ts` |
| `PRODUCT_DIFF_FIELDS` includes `glbUrl`, `usdzUrl`, `thumbnailUrl` | `src/services/catalog/publishPlanner.ts:94-97` |
| `planProduct` emits `SKIP` when the diff is empty | `src/services/catalog/publishPlanner.ts:307+` |
| The publish lock: conditional `findOneAndUpdate` on `activePublishRunId: null`, loser gets `409` | `src/services/catalogPublishService.ts:508-521` |
| `finalizeCatalogAfterRun` advances `publishedRevision` on any SUCCEEDED non-UNPUBLISH run | `src/services/catalog/publishRunState.ts:346-357` |
| Poll cadence proven in the client: 3s → 10s, `_maxPolls = 120` | `lib/application/projects/model_generation_notifier.dart:25-32` |

---

## Steps

### 1. `modelStatus` on the product

**File:** `recapture-api/src/models/types/catalog.types.ts` — add the vocabulary beside the others:

```ts
/**
 * Does this product have a usable 3D model RIGHT NOW?
 *
 * Mirrors ProjectModel.status onto the row the menu actually renders, so the
 * menu never has to join to a project to answer "can this dish launch AR".
 *
 *   NONE       — image-only, or 3D with no linked model.
 *   QUEUED     — linked to a model that has not started generating.
 *   PROCESSING — Meshy is working on it.
 *   READY      — assets are promoted and live. THE ONLY STATE THAT GATES AR.
 *   FAILED     — generation failed; the product stays on the menu in 2D.
 *
 * `type` stays AUTHORED INTENT (THREE_D vs IMAGE_ONLY) and does not move.
 * `modelStatus` is the runtime fact. A THREE_D product with modelStatus
 * PROCESSING is a real, valid, publishable menu item — it just has no AR button.
 */
export const PRODUCT_MODEL_STATUSES = ['NONE', 'QUEUED', 'PROCESSING', 'READY', 'FAILED'] as const;
export type ProductModelStatus = (typeof PRODUCT_MODEL_STATUSES)[number];
```

**File:** `recapture-api/src/models/CatalogProduct.ts` — add the field with
`required: true, default: 'NONE'`. Every pre-existing document materialises as `NONE` on read, so
there is no migration — the same reasoning as `User.role`'s default.

**Backfill, once, deliberately:** existing `THREE_D` products with `assets.glbUrl` set are `READY`,
not `NONE`. Either run a one-off script or — better — derive it at read time in `toProductDto` for
documents where the field is absent. Pick one and write down which; a half-backfilled field is
worse than either.

Add `modelStatus` to the product DTO. **Do not add it to `PRODUCT_DIFF_FIELDS`** — Mirage has no
such concept, and adding it would plan a publish for a state change that has nothing to send.

### 2. Let a product link a pending model

**File:** `recapture-api/src/services/catalogProductsService.ts:353-410`

Add a fourth outcome to `ResolveModelResult`:

```ts
type ResolveModelResult =
  | { outcome: 'MODEL_NOT_FOUND' }
  | { outcome: 'MODEL_NOT_READY' }
  | { outcome: 'OK_PENDING'; projectId: Types.ObjectId; modelId: Types.ObjectId;
      modelStatus: ProductModelStatus }
  | { outcome: 'OK'; assets: ProductAssets; projectId: Types.ObjectId; modelId: Types.ObjectId };
```

In `resolveOwnedModel`, replace the blanket rejection at `:393-395`:

```ts
// A QUEUED or PROCESSING model is now LINKABLE — the dish goes live in 2D and
// the AR button appears when meshyModelProcessor promotes the assets. FAILED
// still is not: there is nothing coming, so linking one would produce a product
// that waits forever.
if (model.status === 'QUEUED' || model.status === 'PROCESSING') {
  return { outcome: 'OK_PENDING', projectId: model.projectId, modelId: model._id as Types.ObjectId,
           modelStatus: model.status };
}
if (model.status !== 'SUCCEEDED' || !model.artifacts?.cdnUrls?.glb) {
  return { outcome: 'MODEL_NOT_READY' };
}
```

**Leave the ownership check above it exactly as it is.** It resolves the model through
`Project.userId`, which is precisely the boundary stage 4 was designed not to weaken — a rep's
captures are owned by the restaurant so that this check keeps working unchanged.

A product created on `OK_PENDING` gets `sourceProjectId`, `sourceModelId`, `modelStatus` from the
model, and **no `assets`**. It is a real `THREE_D` product with nothing to render in 3D yet.

Every caller of `resolveOwnedModel` — create, edit, replace-model — must handle the new outcome.
The union makes that a compile error if you miss one; do not add a `default` case to silence it.

### 3. The promotion service

**New file:** `recapture-api/src/services/catalogModelPromotionService.ts`

```ts
/**
 * Promotes a finished model's artifacts onto every product that linked it while
 * pending, and asks for a re-publish.
 *
 * Best-effort by contract: the caller (meshyModelProcessor) must not fail a
 * successful generation because promotion did not work. The model is generated
 * either way; a missed promotion is recoverable, a failed job is a wasted spend.
 */
export async function promoteModelToProducts(modelId: Types.ObjectId): Promise<PromotionResult>;
```

Sequence, and the reason for the order:

1. Load the model; return early unless `SUCCEEDED` with `artifacts.cdnUrls.glb`.
2. Find `CatalogProduct` rows where `sourceModelId === modelId`, `deletedAt: null`,
   `modelStatus: { $in: ['QUEUED', 'PROCESSING'] }`. The status filter is what makes a re-run a
   no-op.
3. For each, in one update:
   - **copy** `artifacts.cdnUrls` → `assets.{glbUrl, usdzUrl, thumbnailUrl}` — copied, **not
     resolved**, keeping the existing rule that a later regeneration cannot silently change a
     published product;
   - `modelStatus: 'READY'`;
   - `syncStatus: 'PENDING'`.
4. Bump `catalog.draftRevision`.
5. **Then** attempt to enqueue a publish.

**Steps 3–4 must complete before step 5 is attempted, and step 5 must not be able to undo them.**
The product fields are the source of truth; the enqueue is an optimization.

**On `FAILED`:** set `modelStatus: 'FAILED'` and leave `assets` empty. The dish stays on the menu in
2D. Do not delete the product and do not unlink the model — a human may want to retry generation
against the same product.

### 4. Lock-tolerant enqueue — the real hazard

Six dishes finishing within seconds of each other will collide on the publish lock. `openRun`
(`catalogPublishService.ts:508-521`) makes the loser a clean `409` and rolls back its own run and
job. That is correct behaviour and must not be changed. What must change is how promotion reacts to
it:

```ts
// The enqueue is the OPTIMIZATION, never the obligation. The rows are already
// written with syncStatus PENDING and a bumped draftRevision, so a lost lock
// race costs a publish LATENCY, not a promotion. The run that currently holds
// the lock either already includes these rows (it snapshots at plan time) or
// the next one will.
//
// NEVER move the field writes below this call, and never propagate this error.
const result = await requestPublish(catalog);
if (result.outcome === 'IN_PROGRESS') {
  logger.info('promotion: publish lock held, rows left PENDING for the next run');
}
```

**Then close the gap that leaves.** A promotion that loses the race while the *active* run has
already passed its snapshot leaves rows PENDING with nobody coming. Add a sweep: on
`finalizeCatalogAfterRun`, if any product in the catalog is `syncStatus: 'PENDING'` **and**
`modelStatus: 'READY'` **and** was not in the run's snapshot, enqueue one follow-up run. One
follow-up, not a loop — a second collision means the next finalize will catch it.

> Prefer the sweep on finalize over a periodic scanner. It runs exactly when the lock is guaranteed
> free, it needs no new job type, and it cannot drift into a background process nobody monitors.

### 5. Call it from the worker

**File:** `recapture-api/src/worker/processors/meshyModelProcessor.ts`, after `rehostArtifacts`
(`:96`)

Mirror how `captureProcessingProcessor` calls `maybeAutoGenerateModel` as its last non-fatal step:

```ts
const artifacts = await rehostArtifacts(task, record, rawPrefix);

// LAST, and non-fatal. A promotion failure must not fail a generation that
// already cost Meshy credits and already produced a usable model — the model
// record is complete and correct whatever happens below.
try {
  await promoteModelToProducts(record._id as Types.ObjectId);
} catch (err) {
  workerLog.warn('model promotion failed; model is unaffected', { modelId, err });
}
```

The `try/catch` is the contract, not defensiveness. Write the reason in the comment.

Do the same for the failure path so `modelStatus` reaches `FAILED` rather than sticking on
`PROCESSING` forever.

**Import direction check:** the worker may import from services; services must not import from the
worker. `catalogModelPromotionService` lives in `src/services/` and imports only models and
`catalogPublishService`. That is the right direction.

### 6. Keep `modelStatus` moving before promotion

A product linked at `QUEUED` should read `PROCESSING` once Meshy starts, or the client polls with
nothing to show. The cheapest correct answer: have the meshy processor update linked products'
`modelStatus` at the same point it updates `ProjectModel.status`. One extra `updateMany` on a
`sourceModelId` index — add `{sourceModelId: 1, modelStatus: 1}` to `CatalogProduct`.

---

## Tests to write

**New file:** `recapture-api/tests/catalog-model-promotion.test.ts`

- **Pending link is allowed.** Create a `THREE_D` product against a `PROCESSING` model; assert
  `201`, `modelStatus: 'PROCESSING'`, `assets` empty, `sourceModelId` set.
- **`FAILED` is still refused** at link time with `MODEL_NOT_READY`.
- **Someone else's pending model is `MODEL_NOT_FOUND`**, not `MODEL_NOT_READY` — the ownership
  check must not have been loosened along with the status check. Explicit assertion.
- **Promotion flips to READY.** Drive the processor with a faked Meshy success
  (`setMeshyClient`) and an S3 spy; assert the product gains `assets.glbUrl` and
  `modelStatus: 'READY'`, `syncStatus: 'PENDING'`, and the catalog's `draftRevision` advanced.
- **Assets are copied, not referenced.** Mutate `ProjectModel.artifacts.cdnUrls` afterwards; assert
  the product's `assets` did not change.
- **Lock contention loses nothing.** Take the publish lock, run promotion, assert: no throw, the
  product is `READY` + `PENDING`, `draftRevision` bumped, and no second run was created. **The
  stage's headline test.**
- **The follow-up sweep fires.** Continue the above: finalize the held run and assert exactly one
  follow-up publish run is enqueued and the rows reach `SYNCED`.
- **Promotion is idempotent.** Run it twice; assert one set of assets, one `draftRevision` bump, and
  the second call is a no-op (the `modelStatus` filter is what makes this true).
- **A promotion failure does not fail the job.** Make `CatalogProduct.updateMany` throw; assert the
  meshy job still reports success and `ProjectModel.status` is `SUCCEEDED`.
- **Generation failure sets `FAILED`** and leaves the product on the menu with no assets.

**Extend:** `recapture-api/tests/catalog-publish-planner.test.ts`

- **A promoted product plans `UPDATE`, its untouched siblings plan `SKIP`.** This is what makes
  correction C1's "the planner self-narrows" claim true rather than hoped-for. Assert on the plan's
  step list directly.

**Extend:** `recapture-api/tests/catalog-product-edit.test.ts`

- Replacing a READY product's model with a pending one moves it back to `PROCESSING` and clears
  `assets` — or explicitly does not, if you decide the old model should keep rendering until the new
  one lands. **Decide, and pin it with the test.** Leaving it unspecified is how a dish silently
  loses its AR button mid-service.

---

## Done when

- [ ] `modelStatus` exists on `CatalogProduct` with `default: 'NONE'`, is in the DTO, and is **not**
      in `PRODUCT_DIFF_FIELDS`.
- [ ] The backfill decision is made and written down.
- [ ] `resolveOwnedModel` returns `OK_PENDING` for `QUEUED`/`PROCESSING` and every caller handles it
      without a `default` case.
- [ ] The ownership check in `resolveOwnedModel` is byte-identical to before.
- [ ] Promotion writes fields first, enqueues second, and never throws into the worker.
- [ ] Lock contention leaves rows `PENDING` and the finalize sweep picks them up.
- [ ] `productIds` is still unused anywhere (grep — per C1).
- [ ] `npm run type-check && npm run lint && npm test` — green.

---

## Rollback

Riskier than the other stages because it edits a live processor. Roll back by reverting the
`meshyModelProcessor` call site alone — that stops all promotion and leaves everything else inert.
Products already linked to pending models keep their `modelStatus` frozen and stay on the menu in
2D; nothing breaks, they just stop flipping to READY. Revert the model field last, and only after
confirming no product is mid-flight.
