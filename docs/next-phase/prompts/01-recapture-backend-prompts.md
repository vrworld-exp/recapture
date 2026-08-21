✅✅✅✅✅✅✅✅✅✅✅

# ReCapture Backend Prompts — B1 … B7

Repo root for every prompt in this file: `phase2/ReCapture/` (work happens in `recapture-api/`).
`ReCapture/AGENTS.md` is the tie-breaker over anything written here.

Ordering: **B1 → B2 → B3 → B4 → B5** are the MVP chain. **B6, B7** are additive and can land later.

---

# B1 — Publish Run Foundations: job type, planner, processor skeleton

```
# FEATURE: Catalog Publish — Job Type, Snapshot Planner, Processor Skeleton
# Product: ReCapture (business catalog) → Mirage
# Phase: Next Phase — Publish & Sync
# Track: Backend / Integration
# Scope: New Feature (task T-027; features 36, 52, 54, 56, 57)
# Priority: Critical — everything in B2–B5 hangs off this

---

## Context

ReCapture already has the whole authoring side: `Catalog`, `CatalogCategory`, `CatalogProduct`
and `CatalogPublishRun` models, catalog/category/product endpoints, Mirage provisioning, and a
typed Mirage HTTP adapter with error classification. What does not exist yet is the thing that
moves a draft catalog onto Mirage.

The design decision that everything else depends on: **publishing is an explicit user action that
runs as ONE background job over a snapshot** — never per-edit auto-sync. Draft edits bump
`Catalog.draftRevision`; only a fully successful run advances `publishedRevision`. This is what
makes features 56 and 57 true by construction rather than by discipline.

## Current state — read before writing anything

- `src/models/CatalogPublishRun.ts` — the run document already exists with `catalogId`, `userId`,
  `jobId`, `snapshotRevision`, `state`, `counts`, `startedAt`, `finishedAt`, `idempotencyKey`,
  `error`, `entries[]`.
- `src/models/types/catalog.types.ts` — `PUBLISH_RUN_STATES` (`QUEUED | RUNNING | SUCCEEDED |
  PARTIAL | FAILED`), `PUBLISH_TARGET_KINDS`, `PUBLISH_ACTIONS` (`CREATE|UPDATE|DELETE|SKIP`),
  `PUBLISH_OUTCOMES`, `PublishRunEntry`, `PublishRunCounts`, `SYNC_STATUSES`,
  `ProductPublishedSnapshot`. **Use these — do not declare new vocabularies.**
- `src/worker/processorRegistry.ts` + `src/worker/workerRuntime.ts:34-41` — how a job type plugs in.
- `src/worker/jobQueue.ts:19-70` — `claimNextJob` (single conditional `findOneAndUpdate`, stale-lease
  re-claim) and the hardcoded 1→2→4…30 min backoff.
- `src/models/types/job.types.ts` — the three existing `jobType` discriminators.

## Task

Add a `MIRAGE_CATALOG_PUBLISH` job type, a pure snapshot **planner**, and a processor skeleton that
walks the plan, writes `PublishRunEntry` rows, and finalises the run. B2/B3 fill in the actual
Mirage calls behind two injected executors; this prompt must leave clean seams for them.

## Files to inspect first

1. `src/models/types/job.types.ts`, `src/models/Job.ts`
2. `src/worker/processorRegistry.ts`, `src/worker/workerRuntime.ts`, `src/worker/jobQueue.ts`
3. `src/worker/processors/modelOptimizationProcessor.ts` — the closest existing shape to copy
4. `src/models/CatalogPublishRun.ts`, `src/models/types/catalog.types.ts`
5. `src/services/catalogProvisioningService.ts` — where `mirageRestaurantId` comes from
6. `tests/model-optimization-processor.test.ts` — the processor test shape to mirror

## Implementation instructions

1. **Job type.** Add `MIRAGE_CATALOG_PUBLISH_JOB_TYPE = 'MIRAGE_CATALOG_PUBLISH'` to
   `src/models/types/job.types.ts` beside the existing three, with the same comment discipline.
   Register it in `workerRuntime.ts` via `registerProcessor` — **do not touch the polling loop**.
   Job payload: `{ catalogId, publishRunId, mode: 'FULL' | 'RETRY_FAILED' | 'UNPUBLISH', productIds? }`.

2. **Snapshot.** New `src/services/catalog/publishSnapshot.ts`. Given a catalog id, read the
   catalog, its non-deleted categories, and its non-deleted products **once**, and return a frozen
   plain-object snapshot carrying `draftRevision` at read time. The processor must plan and execute
   from this snapshot only — never re-read live draft rows mid-run (feature 57).

3. **Planner.** New `src/services/catalog/publishPlanner.ts`, a **pure function**
   `planPublish(snapshot, mode): PublishPlan`. No IO, no Mongoose, no network — this is the unit
   that gets tested hardest. It emits an ordered list of steps:
   - `RESTAURANT` → `CREATE` when `mirageRestaurantId` is absent, else `UPDATE` when any branding
     field differs from the last push, else `SKIP`.
   - `CATEGORY` → `CREATE` when `mirageCategoryId` is absent; `UPDATE` on a rename; `SKIP` otherwise.
     Categories always precede products (Mirage requires a real category ObjectId on create).
   - `PRODUCT` → `CREATE` when `mirageItemId` is absent; `UPDATE` when the current row differs from
     `publishedSnapshot`; `DELETE` when the row is archived or soft-deleted **and** has a
     `mirageItemId`; `SKIP` when identical.
   - Field-by-field diff against `publishedSnapshot`. **Never** `JSON.stringify` two objects and
     compare strings, and never spread a document into a snapshot — a newly added field must not be
     able to silently vanish from the diff (see the comment at `catalog.types.ts:150-155`).
   - Deterministic order: restaurant, then categories by `position` then `_id`, then products by
     `position` then `_id`. Two runs over the same snapshot must produce a byte-identical plan.

4. **Processor.** New `src/worker/processors/mirageCatalogPublishProcessor.ts`:
   - Loads the run + snapshot, flips the run to `RUNNING` with `startedAt` via a conditional
     `findOneAndUpdate` guarded on `state: 'QUEUED'` (atomicity without transactions).
   - Walks the plan **sequentially** — Mirage has no batch endpoints and runs on a sleeping tier;
     do not parallelise.
   - Calls two injected executors, `categoryExecutor` and `productExecutor`, defined here as
     interfaces with no-op default implementations that record `SKIPPED`. **B2/B3 replace the
     defaults.** Keep the exported signatures stable.
   - After each step, appends one `PublishRunEntry` (`target`, `targetId`, `targetName`, `action`,
     `outcome`, `code?`, `at`) with `$push` and updates `counts`. A crash mid-run must leave the
     already-appended entries intact.
   - Per-row failure is **isolated**: record `FAILED` on that entry, set the row's `syncStatus:
     'FAILED'` + `syncError`, and continue to the next step. A single bad product must never abort
     the run.
   - Finalise per §7.8: zero failures → `SUCCEEDED`; ≥1 success and ≥1 failure → `PARTIAL`;
     zero successes → `FAILED`. **Only `SUCCEEDED` advances `publishedRevision` and
     `lastPublishedAt`.** Always clear `Catalog.activePublishRunId`, including on the failure paths.

5. **Retryability.** Reuse the existing worker backoff. Classify with the existing
   `src/services/mirage/mirageErrors.ts` helpers; a `NonRetryableJobError` for terminal cases so a
   permanently-bad product cannot retry-burn the whole run.

6. **Analytics.** Add the publish events to `src/validation/analyticsSchemas.ts` (the single
   tracking-plan source of truth) and emit through `track()` only: run started, run finished (with
   state + counts), per-target failure (with the `UPPER_SNAKE` code). **No product names, no
   business names, no phone/email in props.**

## What NOT to change

- The polling loop, `claimNextJob`, or the backoff constants.
- Any existing route, service, or model outside the files this task adds.
- The three existing job types.
- Nothing here calls Mirage yet — resist adding "just one" call.

## Edge cases to handle

- Publish requested while `activePublishRunId` is set → this task exposes a
  `hasActiveRun(catalogId)` helper; B4 turns it into the 409.
- Catalog with `mirageRestaurantId` absent → plan a `RESTAURANT CREATE` step, and every later step
  must consume the id the restaurant step produced, not a stale snapshot copy.
- Empty catalog → the planner returns a plan with zero product steps; B4 blocks it before enqueue.
- A product whose category was deleted after the snapshot was taken → plan against the snapshot;
  the executor resolves "uncategorized" in B2.
- Worker crash between two steps → stale-lease re-claim reruns the job; already-`SYNCED` rows must
  plan as `SKIP` on the replay.
- `mode: 'RETRY_FAILED'` → plan only rows with `syncStatus: 'FAILED'`.

## Constraints

- TypeScript `strict`; `no-explicit-any` is an ESLint **error**.
- Layering: `routes → services → models`. The worker may import services; **services must not import
  from `src/worker/`**.
- Soft-delete convention `deletedAt: null`; a compound index for every new query path.
- No Redis. No transactions — conditional `findOneAndUpdate` guarded on current state.
- Every new tunable goes in `config/env.ts` **and** `.env.example` in the same commit, with a safe
  default so existing deploys still boot.

## Acceptance criteria

- [ ] `MIRAGE_CATALOG_PUBLISH` is registered and dispatches without any change to the polling loop.
- [ ] `planPublish` is pure — its test imports it with no DB, no network, no mocks.
- [ ] Planning the same snapshot twice yields an identical plan (asserted).
- [ ] A row that failed does not prevent later rows from running (asserted).
- [ ] `SUCCEEDED` advances `publishedRevision`; `PARTIAL` and `FAILED` do not (asserted for all three).
- [ ] `activePublishRunId` is cleared on every terminal path including a thrown processor error.
- [ ] `tsc --noEmit`, ESLint and the full Vitest suite are clean.

## Testing instructions

Add `tests/catalog-publish-planner.test.ts` (pure, table-driven: create/update/delete/skip for each
target kind, ordering determinism, field-by-field diff catches a change in every diffed field) and
`tests/catalog-publish-processor.test.ts` (hermetic, `mongodb-memory-server`, executors stubbed:
happy path, one-row failure → `PARTIAL`, all-rows failure → `FAILED`, crash-replay leaves entries
intact and re-plans `SKIP`). Env is injected by `vitest.config.ts` before the module graph loads.
CI must never touch live Mirage.
```

---

# B2 — Category & Product Sync with Idempotent Reconciliation

```
# FEATURE: Catalog Publish — Category and Product Sync Executors
# Product: ReCapture → Mirage
# Phase: Next Phase — Publish & Sync
# Track: Backend / Integration
# Scope: New Feature (tasks T-028, T-029, T-035; features 43–48, 26, 47)
# Priority: Critical
# Depends on: B1

---

## Context

B1 left two executor seams with no-op defaults. This task implements them: the real Mirage calls
for categories and products, plus the reconciliation that substitutes for the idempotency Mirage
does not offer.

**The non-negotiable guarantee: publishing the same product twice produces exactly one Mirage
item.** Mirage has no idempotency keys and no upserts; a replayed create returns
`400 "... already exist"` **without the id**. Reconciliation is therefore the mechanism, and
`CatalogProduct.mirageItemId` is the mapping that makes it work.

## Current state

- `src/services/mirage/mirageClient.ts` — typed methods already exist: `listRestaurants`,
  `createRestaurant`, `updateRestaurant`, `deleteRestaurant`, `listCategories`, `createCategory`,
  `updateCategory`, `listItemsForCategory`, `createItem`, `updateItem`, `deleteItem`,
  `getPublicCatalog`, `analyticsSummary`, `analyticsTimeseries`, `analyticsTopProducts`, plus
  `setMirageClient`/`getMirageClient`/`resetMirageClient` for tests.
- ⚠ **`src/services/mirage/mirageTypes.ts` is STALE.** It documents `UpdateItemInput` as having no
  `description`/`categoryId`/`imgOnly` because Mirage ignored them. **Mirage has since been
  extended** — `update-item` now applies `description` and `category`, `imgOnly` is derived on both
  create and update, and the item schema now carries `tags`, `availability`, `featured` and
  `sortPosition`; the restaurant carries `website`, `socialLinks`, `address`, `isPublished`; the
  category carries `sortPosition`; and multer accepts a third file field `objectIos` (USDZ).
  **Part of this task is refreshing the adapter to the current contract and deleting the stale
  comments.**
- `CatalogCategory` already has `mirageCategoryId`, `syncStatus`, `syncError`, `lastSyncedAt`.
- `CatalogProduct` already has `mirageItemId`, `mirageCategoryIdAtSync`, `syncStatus`, `syncError`,
  `lastSyncedAt`, `publishedSnapshot`.

## Files to inspect first

1. `src/services/mirage/mirageClient.ts`, `mirageTypes.ts`, `mirageErrors.ts`
2. `src/worker/processors/mirageCatalogPublishProcessor.ts` (from B1)
3. `src/services/catalogProvisioningService.ts`
4. `../../mirage-be-phase-2-recap/src/Controllers/adminController.js` — `createItems`,
   `updateItem`, `createCategory`, `updateCategory`, `deleteCategory`, `deleteItems`
5. `../../mirage-be-phase-2-recap/src/Models/{itemModel,categoryModel,restaurantModel}.js`
6. `tests/mirage-error-classification.test.ts`

## Implementation instructions

1. **Refresh the adapter contract.** Update `mirageTypes.ts` and `mirageClient.ts` so
   `CreateItemInput` / `UpdateItemInput` carry `description`, `categoryId`, `tags[]`,
   `availability`, `featured`, `sortPosition`, and an `objectIos` file field; restaurant inputs
   carry `website`, `socialLinks`, `address`, `isPublished`; category inputs carry `sortPosition`.
   Multipart array/boolean/number fields must be serialised the way Mirage's
   `parseProductOptionalFields` expects. Replace every stale "Mirage ignores this" comment with a
   citation of the current handler line.

2. **Category executor** — `src/services/catalog/categorySync.ts`:
   - `CREATE` → `createCategory({ name, restaurantId, sortPosition, ... })`, persist
     `mirageCategoryId` **immediately** after the call returns, before anything else can fail.
   - `UPDATE` → `updateCategory`. Remember Mirage lowercases and underscores the stored name; the
     ReCapture display name stays authoritative locally, so never write Mirage's echo back over it.
   - **Uncategorized bucket (feature 26):** a product with `categoryId: null` needs a real Mirage
     category. Materialise one named `Uncategorized` on demand, once per run, and cache its id on
     the catalog. Do not create it for catalogs that do not need it.
   - **Cascade repair:** `delete-item` removes the category when it deleted that category's last
     item. After any product `DELETE`, if the category is now empty, clear its `mirageCategoryId`
     so the next run re-creates it instead of pushing into a dead id.

3. **Product executor** — `src/services/catalog/productSync.ts`:
   - `CREATE` → `createItem(...)`; **persist `mirageItemId` immediately**; then write
     `publishedSnapshot`, `syncStatus: 'SYNCED'`, `lastSyncedAt`, and `mirageCategoryIdAtSync`.
   - **Reconciliation:** when a create fails with Mirage's duplicate-name error, call
     `listItemsForCategory(mirageCategoryId)`, find the item by exact name, adopt its id, and
     convert the step to an `UPDATE`. Only then report success. If no match is found, fail the row
     with a ReCapture code — never guess.
   - `UPDATE` → `updateItem(...)` with only the fields that actually differ from
     `publishedSnapshot`.
   - `DELETE` → `deleteItem(mirageItemId)`; treat "already gone" as success; clear `mirageItemId`
     and set `syncStatus: 'NEVER'`.
   - **Category reassignment** now goes through `update-item` (Mirage applies `category` today) —
     no delete-and-recreate, and therefore the Mirage item id and its analytics history survive.
     Verify against the live handler before relying on it, and if it turns out not to apply, fail
     the row with an explicit code rather than silently no-op.
   - **Order (feature 48):** push `sortPosition` from `CatalogProduct.position`, and category order
     from `CatalogCategory.position`.
   - Asset fields are **not** handled here — B3 owns them. This executor calls into an injected
     `assetUploader` whose default implementation is a no-op that leaves assets untouched.

4. **Error mapping.** Every failure that reaches a row's `syncError` must be a ReCapture
   `UPPER_SNAKE` code plus **our** sentence. Mirage's prose is a classification input inside the
   adapter and must never be persisted or returned. Add a code for each observed Mirage failure
   (duplicate name, invalid category id, restaurant not found, auth rejected, payload too large,
   upstream timeout).

## What NOT to change

- The planner (B1) — executors do not re-plan.
- `catalogProvisioningService.ts` beyond reading the mapping.
- The response envelope, or anything under `routes/`.
- Do not add a second HTTP client. Everything goes through `mirageClient`.

## Edge cases to handle

- Create succeeded on Mirage but the process died before `mirageItemId` was persisted → the replay's
  create fails duplicate → reconciliation adopts the existing id. **This is the crash-replay test.**
- Two products with the same name in one catalog → Mirage enforces per-restaurant name uniqueness;
  fail the second row with a specific code and a suggested rename, and keep the run going.
- Category deleted on Mirage between runs → `mirageCategoryId` points at nothing; re-create and
  re-file the products.
- Rename on both sides between runs → ReCapture is authoritative; push our name.
- Mirage 400 with an unrecognised message → classify as terminal for the row, not for the run, and
  log the raw message once (server-side only) with the row id for triage.

## Constraints

- Sequential calls only; no concurrency against Mirage.
- Persist ids at the first possible moment — an unpersisted id is a duplicate waiting to happen.
- No `any`. No new dependency.
- Every Mirage write must carry the configured `BUCKET_NAME` and `CLOUD_FRONT_URL` from
  `MIRAGE_ASSET_BUCKET` / `MIRAGE_ASSET_CDN_URL` — a missing value silently produces a stored URL
  beginning `undefined/` that only fails when a customer opens the page.

## Acceptance criteria

- [ ] Publishing the same catalog twice with no edits results in zero Mirage writes and all `SKIP`.
- [ ] Crash-replay test: create-then-crash-before-persist leaves **exactly one** Mirage item.
- [ ] A duplicate-name create is reconciled into an update with the adopted id.
- [ ] Uncategorized products land in a materialised Mirage category, created once per run.
- [ ] Deleting a category's last item clears the local `mirageCategoryId`.
- [ ] No Mirage prose appears in `syncError.code`, `syncError.message`, or any response body.
- [ ] `mirageTypes.ts` matches the current Mirage handlers, with line citations.

## Testing instructions

`tests/catalog-category-sync.test.ts`, `tests/catalog-product-sync.test.ts`,
`tests/catalog-publish-idempotency.test.ts`. Drive Mirage through `setMirageClient(fake)`. The fake
must reproduce Mirage's real behaviour: boolean `status`, HTTP 400 for validation *and* not-found
*and* unknown paths, the duplicate-name message quoted verbatim from `adminController.js`, and the
last-item category cascade on delete. CI never calls live Mirage.
```

---

# B3 — Asset Sync: preflight and transfer (GLB / USDZ / image / thumbnail)

```
# FEATURE: Catalog Publish — Asset Sync to Mirage
# Product: ReCapture → Mirage
# Phase: Next Phase — Publish & Sync
# Track: Backend / Integration
# Scope: New Feature (task T-030; features 49, 50, 51)
# Priority: Critical
# Depends on: B2 (and ideally Mirage prompt M1)

---

## Context

Mirage stores its own copy of every asset. ReCapture holds GLB/USDZ/preview on
`BUCKET_ARTIFACTS` behind its own CloudFront, and product images on `BUCKET_RAW`. Mirage's write
endpoints historically accepted **bytes only** (multer disk → `fs.readFileSync` → `s3.upload`), so
publishing means streaming each asset out of S3 and back into a multipart POST — a 90 MB GLB
crossing the wire twice on a sleeping free tier.

**Check `mirage-be-phase-2-recap` first.** If prompt **M1** has landed, `create-item`/`update-item`
accept `imageUrl` / `objectUrl` / `objectIosUrl` and fetch server-side. In that case the URL path is
strongly preferred and byte streaming becomes the fallback. Implement **both**, selected by one
config flag, so this task is not blocked on the Mirage change.

## Files to inspect first

1. `src/config/s3.ts`, `src/services/s3ObjectStore.ts`, `src/utils/s3Keys.ts`,
   `src/utils/productImageKeys.ts`
2. `src/models/ProjectModel.ts` — `artifacts.cdnUrls.{glb,usdz,preview}`, `artifacts.glbBytes`
3. `src/services/projectModelsService.ts` — the owner DTO and `latestSucceededModel` (the OPT record)
4. `src/services/catalog/productSync.ts` (B2) — the `assetUploader` seam
5. `src/config/env.ts:344-363` — `MIRAGE_ASSET_BUCKET`, `MIRAGE_ASSET_CDN_URL`,
   `MIRAGE_REQUEST_TIMEOUT_MS`, `MIRAGE_MAX_ASSET_BYTES`
6. `../../mirage-be-phase-2-recap/src/libs/{multer,s3}.js`

## Implementation instructions

1. **Preflight before any Mirage call** — `src/services/catalog/assetPreflight.ts`. For each asset
   the plan will push: S3 `HEAD` for existence, size and content type. Reject as a **terminal**
   row failure (never a retry) when the object is missing, is over `MIRAGE_MAX_ASSET_BYTES`, or has
   an unexpected content type. Failing here costs nothing; failing after a 90 MB upload costs
   minutes on a sleeping tier.

2. **Change detection.** Compare the asset's S3 ETag (or key + size + `lastModified`) against what
   `publishedSnapshot` recorded. **An unchanged asset is never re-uploaded** — this is the single
   biggest cost saver on republish.

3. **Transfer, two modes** behind `MIRAGE_ASSET_TRANSFER_MODE = 'url' | 'bytes'` (default `bytes`
   until M1 ships):
   - `url` — send the ReCapture CloudFront URL as `imageUrl` / `objectUrl` / `objectIosUrl`; Mirage
     fetches it. Verify the returned document's stored URL points at Mirage's own CDN before
     recording success.
   - `bytes` — `GetObject` as a **stream** and pipe it into the multipart request. Never
     `Buffer.concat` a whole GLB into memory; Render's instance will not survive concurrent 90 MB
     buffers.
   Both modes go through `mirageClient`; no second HTTP path.

4. **Which asset goes where** (Mirage has one image slot and two model slots):
   - 3D product → `object` = the **optimized** GLB (`latestSucceededModel` returns the OPT record),
     `objectIos` = the USDZ when present, `image` = the auto-generated `previewUrl` thumbnail
     (feature 8d/51).
   - Image-only product → `image` = the committed product image. No model fields.
   - **Never persist or forward a Meshy URL.** Only ReCapture CloudFront URLs exist by this point;
     assert it and fail loudly if one appears.

5. **USDZ.** Mirage now has the `objectIos` multer field and writes `model.iosSrc`. Push it when the
   product has one. When the product has no USDZ, log the gap **once per run**, not per product.

6. **Record.** On success write the asset identity used (URL + ETag/size) into `publishedSnapshot`
   so the next run's change detection is exact.

## What NOT to change

- The capture pipeline, the optimizer, the Meshy processors, or `utils/s3Keys.ts` key construction.
- Bucket names or the `{env}` prefix rule — `{env}` is the firewall that stops a non-prod deploy
  touching prod objects.
- Do not delete anything from Mirage's bucket. Replaced Mirage assets are orphaned by design;
  Mirage owns its own lifecycle.

## Edge cases to handle

- GLB larger than Mirage's 100 MB multer cap → terminal row failure with a code the UI can explain,
  before any upload starts.
- CloudFront 403/404 on a URL that used to work → terminal for the row, actionable message.
- Timeout mid-upload → retryable; the next attempt must restart the whole asset, and must not leave
  the product marked `SYNCED`.
- Product converted image-only → 3D → `imgOnly` is derived on Mirage's side from what is present, so
  push the model and let it flip; verify the response reflects it.
- Thumbnail missing on a 3D product (generation still in flight) → block the row with a clear code;
  publishing a 3D product with no image gives customers a blank card.
- Two products sharing one source model → both push their own copy; do not attempt cross-product
  de-duplication.

## Constraints

- Streaming only. Bounded memory. One asset at a time.
- Every limit (`MIRAGE_MAX_ASSET_BYTES`, transfer mode, timeout) comes from `config/env.ts` and is
  documented in `.env.example` in the same commit.
- No `any`. S3 is exercised in tests via `vi.spyOn(s3Client, 'send')` — no live AWS.

## Acceptance criteria

- [ ] Preflight rejects missing/oversize assets before any Mirage call (asserted).
- [ ] Republishing with unchanged assets performs **zero** asset uploads (asserted).
- [ ] Byte mode never buffers a whole file (asserted by a streaming-shape test or a memory guard).
- [ ] USDZ is pushed via `objectIos` when present; the gap is logged once per run when absent.
- [ ] The 3D product's Mirage `image` is the generated thumbnail, not a placeholder.
- [ ] No Meshy URL can reach Mirage (asserted).

## Testing instructions

`tests/catalog-asset-sync.test.ts` with a scripted S3 (`vi.spyOn`) and the Mirage fake: happy path
for both transfer modes, unchanged-asset skip, oversize rejection, missing-object rejection,
mid-upload timeout → retry, USDZ present/absent.
```

---

# B4 — Publish / Unpublish endpoints, state machine, gates, status, retry

```
# FEATURE: Catalog Publish API — endpoints, gates, per-product status, retry, unpublish
# Product: ReCapture
# Phase: Next Phase — Publish & Sync
# Track: Backend
# Scope: New Feature (tasks T-031, T-032, T-033; features 36, 37, 38, 39, 52, 53, 56, 57)
# Priority: Critical
# Depends on: B1 (B2/B3 for a real end-to-end run)

---

## Context

This is the user-facing half of publish: the endpoints the Flutter client calls, the gates that run
**before** any Mirage call, and the state that makes "Draft changes not yet live" honest.

`Catalog` already carries `status` (`DRAFT | PUBLISHED | UNPUBLISHED`), `draftRevision`,
`publishedRevision`, `lastPublishedAt`, `activePublishRunId`, `mirageRestaurantId`, `publicUrl`,
`publicUrlScheme`.

## Endpoints to add (all under the existing `/catalog` router, all `requireAuth`, all house envelope)

| Method | Path | Purpose |
|---|---|---|
| POST | `/catalog/publish` | Gate → provision if needed → create run → enqueue job → `202 { runId }` |
| GET | `/catalog/publish/status` | Current/last run: state, counts, per-product `syncStatus` + code, `lastPublishedAt`, `hasDraftChanges` |
| POST | `/catalog/publish/retry` | Re-enqueue **only** rows with `syncStatus: 'FAILED'` |
| POST | `/catalog/unpublish` | Remove items from Mirage, keep the restaurant, keep the URL and QR |

## Files to inspect first

1. `src/routes/catalog.ts` — the established route/validation/track shape in this file
2. `src/validation/catalogSchemas.ts`
3. `src/services/catalogProvisioningService.ts` — `provisionCatalog`, `syncCatalogBranding`,
   `CATALOG_NAME_TAKEN`, `suggestAvailableName`
4. `src/models/Catalog.ts`, `src/models/CatalogPublishRun.ts`
5. `src/utils/rateLimit.ts` — `consumeRateWindow` (DB-backed; there is no Redis)
6. `tests/catalog-provisioning.test.ts`

## Implementation instructions

1. **Gates — all ReCapture-side, all before any Mirage call** (§7.7). Publish is refused with a
   specific `UPPER_SNAKE` code and an actionable message when:
   - the catalog has zero publishable products (`CATALOG_EMPTY`);
   - a product is missing its required asset (3D without a model or thumbnail; image-only without an
     image);
   - a 3D product references a model that is not `SUCCEEDED` or is not owned by the caller;
   - business name / catalog name is missing (Mirage requires a restaurant name);
   - duplicate product names exist within the catalog (Mirage enforces per-restaurant uniqueness);
   - a publish run is already active (`409 PUBLISH_IN_PROGRESS`).
   Return **all** failing gates in one response, not just the first — the client shows a checklist.

2. **Provisioning on first publish.** Call the existing `provisionCatalog`; on
   `CATALOG_NAME_TAKEN`, return the code plus `suggestAvailableName`'s suggestion in `fields`.
   `mirageRestaurantId`, `publicUrl` and `publicUrlScheme` are written **once** and never rewritten
   — add a guard that throws if any code path attempts to overwrite an existing value (feature 32 is
   a hard constraint: a printed QR must keep working).

3. **Run creation.** One `CatalogPublishRun` per publish, `state: 'QUEUED'`, `snapshotRevision =
   catalog.draftRevision`, then the job, then `activePublishRunId` set by a conditional
   `findOneAndUpdate` guarded on `activePublishRunId: null`. A concurrent second call loses the
   guard and gets `409` — not a second run.

4. **Status.** `hasDraftChanges = draftRevision > publishedRevision` (feature 38) — derived, never a
   user-set flag. Per-product rows return `{ id, name, type, syncStatus, code?, message? }` with
   **our** message. Server-truth so a second device agrees.

5. **Retry.** `POST /catalog/publish/retry` enqueues `mode: 'RETRY_FAILED'`. Same 409 guard.
   Rate-limit it with `consumeRateWindow` — a user tapping Retry in a loop must not queue ten jobs.

6. **Unpublish (feature 39, decision from Q1).** Delete the **items** via Mirage and flip
   `restaurant.isPublished = false` (Mirage now supports it), then set `status: 'UNPUBLISHED'`.
   **Never call `delete-restaurant`** — it destroys the ObjectId the public URL and every printed QR
   are built on. Republish restores under the same URL. Permanent catalog deletion, if it ever
   exists, is a separate explicitly-confirmed action and is out of scope here.

7. **Envelope + codes.** Every failure is `{ status: "error", code, message }` with an
   `UPPER_SNAKE` code the client can switch on. Mirage prose never appears.

## What NOT to change

- The worker, the planner, or the executors.
- `provisionCatalog`'s existing behaviour beyond calling it.
- Any existing catalog/product/category endpoint's contract.
- Do not add a "publish single product" endpoint — publishing is a whole-catalog action (Q-E4).

## Edge cases to handle

- Publish while another publish is running → `409 PUBLISH_IN_PROGRESS` with the active `runId`.
- Publish with zero products → `CATALOG_EMPTY`, blocked before provisioning (Q7).
- Publish immediately after an edit → the snapshot must include that edit (revision is read at run
  creation, not at enqueue time).
- Worker died mid-run and the lease expired → status must still be readable and honest; a re-claim
  finishes the run without a second user action.
- Unpublish on a `DRAFT` catalog → no-op success, no Mirage call.
- Retry with nothing failed → success with a zero-count run, not an error.
- Second device polling status during a run → identical payload; no client-local state.

## Constraints

- Routers stay thin; all logic in `src/services/`.
- Zod validation for every body/query; `validateBody` for bodies, `safeParse` for query/params.
- Enumeration-safety: another user's catalog is an identical 404, never a 403.
- DB-backed rate limiting only.

## Acceptance criteria

- [ ] `POST /catalog/publish` returns `202 { runId }` and exactly one job is enqueued.
- [ ] A concurrent second publish gets `409` and no second run exists.
- [ ] All gates run before any Mirage call; the empty-catalog case never provisions.
- [ ] `publicUrl` and `mirageRestaurantId` are provably immutable once written (test attempts to
      overwrite and asserts it throws).
- [ ] `hasDraftChanges` flips true on any draft write and false only after a `SUCCEEDED` run.
- [ ] Unpublish keeps the restaurant, the URL and the QR; republish reuses the same URL (asserted).
- [ ] Another user's catalog returns the same 404 as a nonexistent one.

## Testing instructions

`tests/catalog-publish-api.test.ts`, `tests/catalog-unpublish.test.ts`,
`tests/catalog-publish-status.test.ts`, plus a QR-stability assertion that `publicUrl` is unchanged
after rename + republish + product churn. Supertest + `mongodb-memory-server`, Mirage faked.
```

---

# B5 — QR generation (PNG / PDF) and the public link

```
# FEATURE: Catalog QR — server-rendered PNG and PDF from the frozen public URL
# Product: ReCapture
# Phase: Next Phase — QR & Public Hosting
# Track: Backend
# Scope: New Feature (task T-025 backend half; features 31–35)
# Priority: High
# Depends on: B4 (needs a provisioned `publicUrl`)

---

## Context

From the business owner's point of view the QR **is** the product. It gets printed on a sticker, a
menu, a shop window. Feature 32 is therefore a hard constraint: **regenerating catalog contents must
never change the QR or the URL.**

That property is already designed in: `publicUrlScheme: 'MIRAGE_OBJECT_ID'` means the URL is
`{MIRAGE_PUBLIC_BASE_URL}/{mirageRestaurantId}` — an immutable ObjectId, not the mutable restaurant
name. Every Mirage public resolver falls back to `findById` when the name lookup misses, which is
what makes an id-based URL work. This task renders that stored string and nothing else.

## Task

`GET /catalog/qr?format=png|pdf&size=<px>` → the QR image for the caller's catalog, rendered
**server-side from `catalog.publicUrl` verbatim**. Also expose the link itself on the catalog
payload (it already is — verify) so the client never composes a URL.

## Files to inspect first

1. `src/models/Catalog.ts:42-57` — `publicUrl`, `publicUrlScheme` and their comments
2. `src/routes/catalog.ts` — route + Zod + `track()` shape
3. `src/config/env.ts:327` — `MIRAGE_PUBLIC_BASE_URL`
4. `recapture-api/package.json` — current deps (no QR or PDF library yet)
5. `src/routes/auth.ts:400-494` — a binary-response endpoint for the header/caching shape

## Implementation instructions

1. **Dependencies.** Add exactly one QR library and one PDF library (or generate a minimal PDF
   wrapper by hand around the PNG — a single-page PDF containing one image is small enough to write
   without a dependency, and one fewer dependency is the better trade here). Justify the choice in a
   comment. `sharp` is already present for raster work — reuse it rather than adding a second image
   library.

2. **Render.** Read `catalog.publicUrl`. If it is absent (never published), return
   `409 CATALOG_NOT_PUBLISHED` with an actionable message — do **not** invent a URL.
   Fixed defaults: error correction level **M**, quiet zone 4 modules, default 1024 px, `?size=`
   clamped to a sane range. No logo embedding in this task (Q12 open) — leave a documented seam.

3. **Determinism.** The same catalog must produce a **byte-identical** PNG on every call. No
   timestamps, no random ids, no locale-dependent rendering. This is asserted by a test.

4. **PDF.** One page, the QR centred, the catalog/business name beneath it as plain text, and the
   public URL as text so a printed sheet is still usable if the code smudges. A4 by default.

5. **Headers.** `Content-Type`, `Content-Disposition: attachment; filename="<slug>-qr.png"`, and a
   strong `ETag` (reuse `src/utils/etag.ts`) — the URL never changes, so the response is highly
   cacheable. Ensure `Content-Disposition` and `ETag` are exposed via CORS so the **web** client can
   read them (`src/app.ts:30`).

6. **Rate limit.** `consumeRateWindow` — rendering is cheap but not free.

## What NOT to change

- `publicUrl` — this endpoint is read-only over it. Never recompute, normalise, trim, or
  lower-case the stored string.
- The provisioning service.
- Do not add per-product QR codes (explicitly parked in brief §G).

## Edge cases to handle

- Catalog not yet published → `409 CATALOG_NOT_PUBLISHED`.
- `MIRAGE_PUBLIC_BASE_URL` changed after provisioning → the **stored** URL still wins; grandfathered
  catalogs keep the URL that was printed. Add a test that proves changing the env var does not
  change an already-issued URL.
- Extremely long URL → error correction still fits at the default size; assert.
- Another user's catalog → identical 404.
- `?size=` out of range → clamp, do not error.

## Constraints

- One new dependency at most for QR, one at most for PDF, both justified in-code.
- Binary responses still error through the house envelope on the error path.
- No `any`; `tsc --noEmit` clean.

## Acceptance criteria

- [ ] `GET /catalog/qr?format=png` returns a scannable PNG that decodes back to `publicUrl` exactly
      (asserted by decoding it in the test).
- [ ] Two calls return byte-identical PNGs.
- [ ] The QR is unchanged after a catalog rename, a republish, and product add/delete (asserted).
- [ ] PDF renders one page with the code, the name and the URL text.
- [ ] Unpublished catalog gets `409`, not a broken image.
- [ ] `Content-Disposition` and `ETag` are readable from a browser client.

## Testing instructions

`tests/catalog-qr.test.ts`: decode round-trip, byte-identity across calls, stability across
rename/republish/churn, env-change immunity, 409 when unpublished, 404 for another user.
```

---

# B6 — Publish activity log

```
# FEATURE: Catalog Publish Activity Log
# Product: ReCapture
# Phase: Next Phase — Publish & Sync
# Track: Backend
# Scope: New Feature (task T-036; feature 55)
# Priority: Medium (V2 per the bucketing doc)
# Depends on: B1, B4

---

## Context

Feature 55 is marked optional-for-MVP in the brief. It stays cheap because the data already exists:
`CatalogPublishRun.entries[]` is a full per-target record of every action and outcome — the
`catalog.types.ts` comment says plainly that this is why a fifth collection is not needed.

## Task

`GET /catalog/activity?cursor=&limit=` — paged, newest-first history across runs: run id, started/
finished, state, counts, and the entries (`target`, `targetName`, `action`, `outcome`, `code`, `at`).

## Files to inspect first

1. `src/models/CatalogPublishRun.ts`, `src/models/types/catalog.types.ts:224-240`
2. `src/utils/cursor.ts` — the existing cursor pagination helper
3. `src/routes/catalog.ts`

## Implementation instructions

1. Cursor pagination via `utils/cursor.ts`, deterministic ordering (`startedAt` desc, `_id` desc),
   with a compound index to back it.
2. Project entries **field by field**. Never spread the document — `entries[]` can grow new internal
   fields that must not leak.
3. `code` is the ReCapture code; `message` is our sentence resolved from the code at read time, so
   improving a message improves history too. No Mirage prose, ever.
4. **Bounded growth (Q11):** retain the last N runs per catalog (config, default 50) and prune older
   ones on write, or set a TTL. State the choice in a comment. A catalog republished daily for two
   years must not grow unbounded.
5. `targetName` is catalog content — safe to return to the owner, but it must never enter analytics
   props or logs.

## What NOT to change

- The run document's write path — this is read-only over what B1 already writes.
- Do not add a second events collection.

## Edge cases to handle

- No runs yet → empty page, not a 404.
- A run still `RUNNING` → included, with `finishedAt` absent.
- An entry whose product has since been deleted → `targetName` is denormalised, so the row still
  reads sensibly. Assert this.
- Another user's catalog → identical 404.

## Acceptance criteria

- [ ] Paging is deterministic and index-backed (no collection scan in `explain`).
- [ ] Retention/pruning is enforced and tested.
- [ ] No Mirage prose in any field.
- [ ] Entries for deleted products still render with their names.

## Testing instructions

`tests/catalog-activity-log.test.ts`: pagination determinism, retention pruning, deleted-target
readability, ownership isolation.
```

---

# B7 — Analytics proxy (summary, timeseries, top products)

```
# FEATURE: Catalog Analytics Proxy — scoped reads of Mirage analytics
# Product: ReCapture
# Phase: Next Phase — Analytics
# Track: Backend / Integration
# Scope: New Feature (task T-037; features 61–66)
# Priority: Medium (V2 per the bucketing doc)
# Depends on: B4 (needs the provisioned mapping)

---

## Context

**No new collection is needed.** Mirage's public catalog page has been emitting `session_start`,
`client_page_view`, `product_page_view`, `product_detail_opened`, `model_loaded`,
`model_load_failed`, `ar_view_clicked` and `ar_session_started` into `analyticsEventModel` all
along, with a 365-day TTL. Features 61–65 are already collected. Only the **read** surface is
missing.

Mirage's three report endpoints are **admin-scoped**, and its own in-code note
(`analyticsRoutes.js:20-24`) says they must not be opened to client scope by loosening `isAdmin`.
So ReCapture proxies them with its admin credential and **forces** the `restaurant` parameter from
the caller's own mapping.

## Task

Three endpoints under `/catalog/analytics`, each proxying one Mirage report with the restaurant id
injected server-side:

| Method | Path | Proxies |
|---|---|---|
| GET | `/catalog/analytics/summary?from=&to=` | Mirage `GET /api/v1/analytics/summary` |
| GET | `/catalog/analytics/timeseries?from=&to=` | Mirage `GET /api/v1/analytics/timeseries` |
| GET | `/catalog/analytics/top-products?from=&to=&limit=` | Mirage `GET /api/v1/analytics/top-products` |

## Files to inspect first

1. `src/services/mirage/mirageClient.ts` — `analyticsSummary`, `analyticsTimeseries`,
   `analyticsTopProducts` already exist
2. `../../mirage-be-phase-2-recap/src/Controllers/analyticsController.js` — the real response shapes
3. `../../mirage-be-phase-2-recap/src/Models/analyticsEventModel.js` — the event vocabulary
4. `src/models/Catalog.ts` (`mirageRestaurantId`), `src/models/CatalogProduct.ts` (`mirageItemId`)

## Implementation instructions

1. **Scope is never client-supplied.** Read `mirageRestaurantId` from the caller's catalog and pass
   it. If the request carries a `restaurant` parameter, **ignore it** — asserted by a test. A
   catalog with no mapping returns empty results, never an unscoped read.

2. **Translate shapes at the boundary.** Mirage's `{ status: boolean, message, data }` must not leak.
   Return the house envelope with a field-by-field DTO; strip anything not needed by the dashboard.

3. **Partition by product type (feature 65).** Mirage does not tag events by product type. Join each
   `top-products` row's product id back through `CatalogProduct.mirageItemId` and label each row
   `3D` or `IMAGE_ONLY`, plus totals per type. Rows that no longer map to a local product are
   returned as `UNKNOWN`, not dropped.

4. **Date range.** Validate `from`/`to` with Zod, default to the last 30 days, cap the span, and
   clamp `limit` (Mirage caps at 100 anyway).

5. **Caching.** Reports are expensive on a sleeping tier. Cache per (catalog, range) in-process with
   a short TTL. **No Redis** — that is a stack decision.

6. **Failure isolation.** Mirage being down must degrade the dashboard, not break it: return a
   documented `ANALYTICS_UNAVAILABLE` code the client renders as an empty state with a retry.

## What NOT to change

- Mirage's analytics routes or its `isAdmin` gate (M4 covers that, separately and deliberately).
- The client-side `Analytics.logEvent` seam — ReCapture's own authoring events are a different task.
- Do not build heatmaps, funnels or cohorts — explicitly parked in brief §G.

## Edge cases to handle

- Catalog never published → empty payload, no Mirage call.
- Mirage admin token expired → refresh once through the adapter's existing token handling, then fail
  with a stable code.
- Range with `from > to` → 400 with a field error.
- A top-products row for a product deleted locally → `UNKNOWN`, still counted in totals.
- Timezone: Mirage stores `receivedAt` UTC; state the boundary rule in a comment and be consistent.

## Constraints

- No new collection, no Redis, no `any`.
- All three reads go through `mirageClient`.
- Never log or return raw visitor ids.

## Acceptance criteria

- [ ] A client-supplied `restaurant` parameter is provably ignored.
- [ ] Unprovisioned catalog returns empty, and makes zero Mirage calls.
- [ ] `top-products` rows are labelled `3D` / `IMAGE_ONLY` / `UNKNOWN` with correct totals.
- [ ] Mirage's boolean `status` never appears in a ReCapture response.
- [ ] Mirage downtime yields `ANALYTICS_UNAVAILABLE`, not a 500.

## Testing instructions

`tests/catalog-analytics-proxy.test.ts` with the Mirage fake: scope forcing, empty-when-unprovisioned,
type partitioning, envelope translation, downtime degradation, range validation.
```
