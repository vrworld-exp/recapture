# 03 — Architecture Proposal

Standard MayasabhaXR architect format. Features are referenced by number (see the task brief);
Mirage endpoints by their `01-codebase-findings.md` IDs (M1–M29), each of which cites a real file
and route handler in `mirage-be/`.

Every convention here defers to `ReCapture/AGENTS.md`. Where this document adds something new, it
says so explicitly and gives the reason.

---

## 1. Requirement Understanding

ReCapture today is a single-purpose capture tool: a business user scans a physical object, a worker
turns the photos into a GLB, and the user views the result. This phase turns it into the business's
whole storefront authoring app. The user assembles a **catalog** — one per account — out of two
kinds of product: 3D products backed by a model they already captured, and image-only products that
are just a photo, a name and a price. They organise those into categories, preview the result, and
press **Publish**. Publishing pushes the catalog into Mirage, the existing customer-facing hosting
system, using Mirage's existing admin APIs; nothing new is built on the Mirage side. The business
gets back one QR code for the whole catalog, and that QR must keep working forever — through
republishes, renames, and product churn. Between publishes, the live catalog customers see must not
move: ReCapture is where you draft, Mirage is what is live, and the only bridge between them is an
explicit publish action.

---

## 2. Recommended Architecture

**One sentence:** ReCapture's backend becomes the authoring store and the *only* holder of Mirage
credentials; publishing is a job on the worker that already exists, and the public URL is minted
from Mirage's immutable ObjectId so the QR can never break.

Five decisions carry the design.

**(a) Mirage is a projection, not a peer database.** ReCapture owns catalog truth. Mirage holds a
derived copy that only the publish worker writes. This is what makes features 56/57 true by
construction rather than by discipline, and it is the only way to get a coherent draft/published
split out of a Mirage that has no draft concept of its own.

**(b) Reuse the existing worker; add a job type, not a service.** `worker/processorRegistry.ts`
exists precisely so new `jobType`s plug in "without touching the polling loop", and
`worker/jobQueue.ts` already gives atomic claim, crash-recovery re-claim, and 1→2→4-min exponential
backoff capped at 30 min. A publish is a `MIRAGE_CATALOG_PUBLISH` job beside `CAPTURE_PROCESSING`,
`MESHY_MODEL_GENERATION` and `MODEL_OPTIMIZATION`. At 5–20 pilot businesses a separate sync service,
a message bus, or a second queue technology would all be pure cost. **No Redis** — AGENTS.md §0.4
forbids it and nothing here needs it.

**(c) Idempotency is compensated on the ReCapture side, because Mirage has none.** Mirage has no
idempotency keys and no upserts; a retried create returns `400 "Product already exist"` and does not
give back the id. So the mapping row (`mirageItemId`) *is* the idempotency record: the worker
branches on its presence, and when a create fails on a name collision it reconciles by listing
(M12) and adopting the existing id. Every publish also carries a ReCapture-generated
`Idempotency-Key` at its own API boundary, matching the pattern already proven on `POST /jobs` and
`POST /admin/projects/:id/model` (unique partial index on `(actorId, idempotencyKey)`).

**(d) The QR is minted from the Mirage `_id`, and then frozen.** Every public resolver in Mirage
falls back to `findById` when the name lookup misses (`itemController.js:476-478`). An ObjectId is
immutable; a name is not — and Mirage additionally denormalises the name onto every child document
at create time and never rewrites it. Minting from `_id` makes feature 32 a property of the URL
scheme rather than a rule people have to remember. Details in §8.

**(e) Nothing about the capture pipeline changes.** The catalog *reads* `GET /projects/:id/models`
and consumes `OwnerModelListItemDto`. No new bucket, no second storage system, no change to
`utils/s3Keys.ts`. Product images get their own key space alongside avatars, using the same
presign → PUT → commit shape.

### What this design deliberately does **not** do

- No auto-sync on edit. Publishing is explicit (brief §13), and auto-sync would violate feature 57.
- No Mirage-side changes, and no design that assumes any. Where a Mirage gap blocks a feature, the
  feature degrades ReCapture-side and the gap is raised in `06-open-questions.md` §C.
- No Mirage credentials in the Flutter client, ever (brief §7).

---

## 3. System Overview

```
┌─────────────────────────────┐
│  Flutter client (lib/)      │   Riverpod notifiers → repositories → Dio (+AuthInterceptor)
│  Catalog · Products · QR    │   Holds NO Mirage credential. Talks only to recapture-api.
└──────────────┬──────────────┘
               │ HTTPS, bearer access token, house envelope {status:"success"|"error"}
┌──────────────▼──────────────────────────────────────────────────────────┐
│  recapture-api  (Express + TS)                                          │
│                                                                          │
│  routes/catalog.ts ─► services/catalogService.ts ─► models/Catalog,      │
│                       services/catalogProductsService.ts   CatalogProduct,│
│                                                            CatalogCategory│
│      writes bump catalog.draftRevision  ── authoring, never touches Mirage│
│                                                                          │
│  POST /catalog/publish ─► enqueue Job{ jobType: MIRAGE_CATALOG_PUBLISH } │
└──────────────┬───────────────────────────────────────────────────────────┘
               │ same DB-backed queue as capture/meshy/optimize
┌──────────────▼───────────────────────────────────────────────────────────┐
│  worker/processors/mirageCatalogPublishProcessor.ts                       │
│    plan → provision → categories → products → assets → finalize           │
│                                     │                                     │
│    services/mirage/mirageClient.ts ─┤  the ONLY module holding            │
│      headers: apikey + token        │  MIRAGE_* credentials               │
│      unwraps {status:boolean,…}     │                                     │
│      classifies retryable vs terminal                                     │
└──────────────┬───────────────────────┴───────────────────────────────────┘
               │ multipart/form-data (image, object) + JSON bodies
┌──────────────▼──────────────┐          ┌────────────────────────────────┐
│  mirage-be  /api/v1/*       │          │  ReCapture CloudFront          │
│  restaurant · category ·    │◄─ bytes ─┤  msxr-model-artifacts (GLB,    │
│  item  (+ analytics reads)  │  streamed│  USDZ, preview) — source of the │
└──────────────┬──────────────┘          │  files the worker re-uploads   │
               │                          └────────────────────────────────┘
┌──────────────▼──────────────┐
│  mirage-fe  /:restaurant    │  ← the QR points here
│  → M14 get-data-for-new-ui  │  → emits analytics to M26 /analytics/collect
└─────────────────────────────┘
```

**Publish data flow, in order.** (1) The user presses Publish. (2) `POST /catalog/publish` validates
the catalog is publishable, writes a **publish snapshot** onto every included product, creates a
`PublishRun` and enqueues one job, returning `202` immediately. (3) The worker claims the job via
the existing `claimNextJob`. (4) It provisions the Mirage restaurant if `mirageRestaurantId` is
absent (M2), stores the id and **freezes the public URL**. (5) It syncs branding (M3), then
categories (M5/M6), then products in dependency order, streaming each asset from ReCapture
CloudFront into a multipart request (M8/M9/M10). (6) Each product's outcome is written to its own
`syncStatus` as it happens, so a crash mid-run loses no progress. (7) On full success the catalog
flips to `PUBLISHED`, `publishedRevision := snapshotRevision`, `lastPublishedAt := now`.

**Read flow for analytics.** The client asks `recapture-api`; `recapture-api` calls M27/M28/M29 with
its admin credential and a **server-forced** `?restaurant=` equal to the caller's mapped id.

---

## 4. Frontend Changes

Follows the existing layering exactly: `domain → data → application → presentation`, Riverpod
notifiers that are pure state, repositories that own all HTTP and error translation, `go_router`
routes declared in `lib/app/routes/app_router.dart`.

**New routes** (added to `AppRoutes`/`AppRouteNames` in the existing style):

| Constant | Path |
|---|---|
| `catalog` | `/catalog` |
| `catalogSettings` | `/catalog/settings` |
| `catalogPreview` | `/catalog/preview` |
| `catalogPublish` | `/catalog/publish` |
| `catalogQr` | `/catalog/qr` |
| `catalogCategories` | `/catalog/categories` |
| `productNew` | `/catalog/products/new` |
| `productDetail` | `/catalog/products/:productId` |
| `businessProfile` | `/profile/business` |
| `catalogAnalytics` | `/catalog/analytics` |

**New domain entities** (`lib/domain/entities/`): `catalog.dart`, `catalog_status.dart`,
`catalog_product.dart`, `product_type.dart` (`threeD | imageOnly`), `product_sync_status.dart`
(`synced | pending | failed`), `catalog_category.dart`, `business_profile.dart`,
`publish_state.dart`, `catalog_analytics_summary.dart`. Pure Dart, hand-synced with the backend
DTOs — there is no shared package, and AGENTS.md §Guardrails treats that sync as a contract.

**New repositories** (`lib/data/repositories/`): `catalog_repository.dart`,
`catalog_products_repository.dart`, `catalog_publish_repository.dart`,
`business_profile_repository.dart`. All on the existing `dioProvider` so they inherit
`AuthInterceptor` token attach and 401-refresh.

**New notifiers** (`lib/application/catalog/`): `catalog_notifier.dart`,
`product_list_notifier.dart` (filters 28 + search 29 + cursor paging),
`product_editor_notifier.dart`, `category_notifier.dart`, `publish_notifier.dart`,
`product_image_upload_notifier.dart`.

**New screens** (`lib/presentation/screens/catalog/`): `catalog_screen.dart` (grid/list, 27–29),
`product_editor_screen.dart` (6–9, 14–18), `add_product_sheet.dart` (the 11/12/13 source picker),
`category_manager_screen.dart` (22–26 with drag-reorder), `catalog_preview_screen.dart` (5),
`publish_screen.dart` (36–39, 52–53, 68–69), `qr_screen.dart` (31–35),
`business_profile_screen.dart` (58–60), `analytics_dashboard_screen.dart` (66).

**Reuse, not reinvention:**

- **3D preview** — `model_viewer_plus` as already used in `model_viewer_screen.dart` /
  `model_render_view.dart`. ⚠ Any new page that renders an **optimized** GLB must set the meshopt
  decoder trigger in **both** `web/index.html` and `_lifecycleJs` (AGENTS.md; guarded by
  `test/projects/meshopt_decoder_test.dart`). A new catalog preview surface is exactly the kind of
  second page that has historically shipped broken on one platform.
- **Image picking** — `image_picker` ^1.1.2, already chosen for its native resize.
- **Sharing** — `share_plus` ^13.2.0 for feature 35.
- **Fresh-scan source (12)** — deep-links into the existing capture flow at `AppRoutes.preCapture`
  and returns a `modelId`. No change to any capture screen.
- **Offline** — catalog editing is server-truth (edge case: second device). The existing
  `offline_queue` Hive box is **not** extended to catalog writes in this phase; the client shows a
  disabled state when `connectivity` reports offline.

**Mobile-first:** the product grid is a 2-column `SliverGrid` on phones and 4-column on tablets;
bulk selection is a long-press mode rather than a hover affordance; QR and publish are full-screen
sheets. Business users are on phones (brief §1).

---

## 5. Backend Changes

New router `src/routes/catalog.ts`, mounted `app.use('/catalog', catalogRouter)` in `src/app.ts`
beside the existing six. New services `src/services/catalogService.ts`,
`catalogProductsService.ts`, `catalogCategoriesService.ts`, `catalogPublishService.ts`,
`catalogAnalyticsService.ts`. New integration module `src/services/mirage/`. New Zod schemas in
`src/validation/catalogSchemas.ts`. New key builder `src/utils/productImageKeys.ts`.

All routes are behind `requireAuth`; all bodies validated with `validateBody`; all responses use the
one envelope; all ownership failures return the same shape as not-found (enumeration-safety).

### New endpoints ReCapture exposes to its own client

| Method | Path | Purpose | Features |
|---|---|---|---|
| GET | `/catalog` | The caller's catalog + counts + publish state | 1, 4, 37, 38 |
| POST | `/catalog` | Create the catalog (idempotent — returns the existing one) | 1, 3 |
| PATCH | `/catalog` | Update metadata; bumps `draftRevision` | 2 |
| POST | `/catalog/logo/upload-url` · PUT `/catalog/logo` | Presign + commit for logo/cover | 2 |
| GET | `/catalog/preview` | Draft projection shaped like the public page | 5 |
| GET | `/catalog/products` | List + filter + search + cursor page | 27, 28, 29 |
| POST | `/catalog/products` | Create (3D from `modelId`, or image-only) | 6, 7, 8, 11, 12, 13 |
| GET | `/catalog/products/:id` | Detail | 27 |
| PATCH | `/catalog/products/:id` | Edit fields; replace model; convert type | 14, 15, 17 |
| POST | `/catalog/products/image/upload-url` · PUT `/catalog/products/:id/image` | Presign + commit product image | 13, 16 |
| POST | `/catalog/products/:id/duplicate` | Duplicate | 18 |
| POST | `/catalog/products/:id/archive` · `/restore` | Soft archive / restore | 19, 20 |
| DELETE | `/catalog/products/:id` | Permanent delete | 21 |
| PATCH | `/catalog/products/:id/featured` | Toggle featured | 9 |
| PATCH | `/catalog/products/order` | Bulk position write | 10 |
| POST | `/catalog/products/bulk` | Bulk delete / recategorise / include-exclude | 30 |
| GET/POST | `/catalog/categories` | List / create | 22, 26 |
| PATCH/DELETE | `/catalog/categories/:id` | Rename / delete | 23 |
| PATCH | `/catalog/categories/order` | Reorder | 23 |
| POST | `/catalog/publish` | Enqueue a publish run → `202` + `runId` | 36 |
| GET | `/catalog/publish/status` | Current/last run + per-product sync state | 37, 38, 52 |
| POST | `/catalog/publish/retry` | Re-enqueue failed subset only | 53 |
| POST | `/catalog/unpublish` | Take the catalog offline | 39 |
| GET | `/catalog/qr` | QR as PNG or PDF (`?format=png\|pdf`) | 31, 33 |
| GET | `/catalog/activity` | Sync/activity log page | 55 |
| GET/PATCH | `/catalog/profile` | Business profile | 58, 60 |
| GET | `/catalog/analytics/summary` · `/timeseries` · `/top-products` | Proxied, server-scoped | 61–66 |

### Mirage endpoints ReCapture will consume

| ID | Method | Path | Handler (file:line) | Used for |
|---|---|---|---|---|
| M2 | POST | `/api/v1/create-restaurant` | `adminController.createRestaurant` (`mirage-be/src/Controllers/adminController.js:183`) | 40 |
| M3 | PUT | `/api/v1/update-restaurant/:restaurantId` | `adminController.updateRestaurant` (`adminController.js:282`) | 42, 59 |
| M4 | DELETE | `/api/v1/delete-restaurant/:restaurantId` | `adminController.deleteRestaurant` (`adminController.js:1245`) | 39 — **not used by default**, see §7.6 |
| M5 | POST | `/api/v1/create-category` | `adminController.createCategory` (`adminController.js:520`) | 22, 26, 47 |
| M6 | PUT | `/api/v1/update-category/:categoryId` | `adminController.updateCategory` (`adminController.js:647`) | 23, 47 |
| M8 | POST | `/api/v1/create-item` | `adminController.createItems` (`adminController.js:783`) | 44, 49a, 50, 51 |
| M9 | PUT | `/api/v1/update-item/:itemId` | `adminController.updateItem` (`adminController.js:1021`) | 45, 15, 16 |
| M10 | DELETE | `/api/v1/delete-item/:itemId` | `adminController.deleteItems` (`adminController.js:1291`) | 46, 19, 21, 39 |
| M11 | GET | `/api/v1/get-all-categories-admin/:restaurantId` | `adminController.getALlCategoriesAdmin` (`adminController.js:426`) | reconciliation |
| M12 | GET | `/api/v1/get-all-items-for-cat/:categoryId` | `adminController.getAllItemsForCat` (`adminController.js:473`) | idempotency reconciliation |
| M14 | GET | `/api/v1/get-data-for-new-ui/:restaurantSlug` | `itemController.getDataForNewUi` (`mirage-be/src/Controllers/itemController.js:463`) | post-publish verification; URL scheme grounding |
| M27 | GET | `/api/v1/analytics/summary` | `analyticsController.getSummary` (`mirage-be/src/Controllers/analyticsController.js:163`) | 61–64, 66 |
| M28 | GET | `/api/v1/analytics/timeseries` | `analyticsController.getTimeseries` (`analyticsController.js:382`) | 66 |
| M29 | GET | `/api/v1/analytics/top-products` | `analyticsController.getTopProducts` (`analyticsController.js:459`) | 62, 65, 66 |

### New config (`config/env.ts` + `.env.example`, together — AGENTS.md §Config)

`MIRAGE_BASE_URL` (required), `MIRAGE_API_KEY` (required, secret), `MIRAGE_ADMIN_EMAIL` /
`MIRAGE_ADMIN_PASSWORD` **or** `MIRAGE_ADMIN_TOKEN` (see Q3), `MIRAGE_PUBLIC_BASE_URL` (required —
the host the QR encodes), `MIRAGE_ASSET_BUCKET` (default `maya-restaurants`),
`MIRAGE_ASSET_CDN_URL` (default `https://d1ubv1fp33ooxl.cloudfront.net`) — both required because
Mirage reads them **from the request body** and a missing value silently produces a stored URL of
`undefined/<key>`. Plus safe-defaulted tunables: `MIRAGE_REQUEST_TIMEOUT_MS` (60000 — asset uploads
are slow), `MIRAGE_MAX_ASSET_BYTES` (default 94371840 = 90 MiB, under Mirage's 100 MB multer cap),
`PUBLISH_MAX_PER_WINDOW` (10) / `PUBLISH_WINDOW_SECONDS` (3600) via the generic
`consumeRateWindow`, `CATALOG_PRODUCT_IMAGE_MAX_BYTES` (5 MiB),
`PRODUCT_IMAGE_UPLOAD_URL_TTL_SECONDS` (900).

---

## 6. Database Changes

Four new collections. All follow the house rules: `timestamps: true`, soft-delete via `deletedAt`,
`ObjectId` ids exposed as `id` strings, **a compound index per real query path**.

### `catalogs` — one per user

| Field | Type | Notes |
|---|---|---|
| `userId` | ObjectId ref User | **unique index** — enforces feature 1 |
| `name`, `businessName` | String | |
| `logoKey`, `coverImageKey` | String? | S3 keys, never URLs (avatar precedent) |
| `contact` | `{ phone?, email?, address?, website?, socials? }` | website/socials/address have no Mirage home |
| `status` | `'DRAFT' \| 'PUBLISHED' \| 'UNPUBLISHED'` | feature 4 |
| `mirageRestaurantId` | String? | feature 41 — set once, **never rewritten** |
| `mirageProvisionedAt` | Date? | |
| `publicUrl` | String? | **frozen at provisioning**, feature 32/34 |
| `publicUrlScheme` | `'MIRAGE_OBJECT_ID'` | recorded so a future scheme change cannot silently rewrite issued URLs |
| `draftRevision` | Number, default 0 | bumped by every authoring write |
| `publishedRevision` | Number, default -1 | set on a fully successful run — feature 38 is `draftRevision > publishedRevision` |
| `lastPublishedAt` | Date? | feature 37 |
| `activePublishRunId` | ObjectId? | guards concurrent publishes |
| `deletedAt` | Date? | |

Indexes: `{ userId: 1 }` unique; `{ status: 1, updatedAt: -1 }`.

### `catalog_products`

| Field | Type | Notes |
|---|---|---|
| `catalogId`, `userId` | ObjectId | `userId` denormalised so every ownership check is one query |
| `type` | `'THREE_D' \| 'IMAGE_ONLY'` | feature 7 |
| `name`, `description`, `price`, `currency` | | `currency` defaults `'INR'`; Mirage stores no currency |
| `categoryId` | ObjectId? | null = uncategorized (26) |
| `tags` | [String] | ReCapture-only (gap 8b) |
| `availability` | `'IN_STOCK' \| 'OUT_OF_STOCK'` | ReCapture-only (gap 8c) |
| `featured` | Boolean | ReCapture-only (gap 9) |
| `position` | Number | sparse ordering (gap 10/48) |
| `sourceProjectId`, `sourceModelId` | ObjectId? | 3D products — the `ProjectModel` this points at |
| `assets` | `{ glbUrl?, usdzUrl?, thumbnailUrl?, imageKey? }` | GLB/USDZ/thumbnail are **ReCapture CloudFront URLs** copied from `ProjectModel.artifacts.cdnUrls`; `imageKey` is an S3 key for image-only |
| `mirageItemId` | String? | feature 43 — the mapping **and** the idempotency record |
| `mirageCategoryIdAtSync` | String? | detects a category move that M9 cannot express |
| `syncStatus` | `'NEVER' \| 'PENDING' \| 'SYNCED' \| 'FAILED'` | feature 52 |
| `syncError` | `{ code, message, at }?` | feature 68 — `code` is a ReCapture `UPPER_SNAKE`, never Mirage prose |
| `lastSyncedAt` | Date? | |
| `publishedSnapshot` | Mixed? | the field values **as last pushed** — the diff basis for feature 38 and the answer to edge case §12.2 |
| `archivedAt` | Date? | feature 19/20 |
| `deletedAt` | Date? | feature 21 |

Indexes: `{ catalogId: 1, position: 1, _id: 1 }` (list + reorder, deterministic),
`{ catalogId: 1, categoryId: 1, deletedAt: 1 }` (filter 28),
`{ catalogId: 1, syncStatus: 1 }` (the publish worker's work query + feature 53),
`{ catalogId: 1, name: 1 }` (search 29 + Mirage's per-restaurant name-uniqueness pre-check),
`{ mirageItemId: 1 }` sparse.

### `catalog_categories`

`catalogId`, `userId`, `name`, `position`, `mirageCategoryId?`, `syncStatus`, `deletedAt`.
Indexes: `{ catalogId: 1, position: 1 }`, `{ catalogId: 1, name: 1 }` unique among non-deleted.

### `catalog_publish_runs`

`catalogId`, `userId`, `jobId`, `snapshotRevision`, `state`
(`QUEUED | RUNNING | SUCCEEDED | PARTIAL | FAILED`), `counts { total, synced, failed, skipped }`,
`startedAt`, `finishedAt`, `idempotencyKey`, `error?`. Plus `entries[]` (per-target outcome) which
doubles as the feature-55 activity log for the MVP without a fifth collection.
Indexes: `{ catalogId: 1, createdAt: -1 }`; unique partial `{ userId: 1, idempotencyKey: 1 }` where
`idempotencyKey` exists — the identical shape used by `ProjectModel` (`ProjectModel.ts:225-228`).

### Changes to existing collections

**None required.** Business profile fields live on `catalogs`, not on `User` — the catalog is the
thing that gets branded, `User` is deliberately near-PII-free, and `GET /auth/me` is documented as
masked-only. `ClientConfig` is untouched: it is one global capture-tuning document and explicitly
"no per-user/per-project config".

**New job type**: `MIRAGE_CATALOG_PUBLISH` added to `models/types/job.types.ts` beside the existing
three. Because `jobType` is a real discriminator, every existing query meaning "the capture job"
already filters `CAPTURE_PROCESSING` and is unaffected.

### New S3 key space (product images)

`src/utils/productImageKeys.ts`, a **third** parser alongside `s3Keys.ts` and `avatarKeys.ts` —
deliberately separate, exactly as the avatar space was:

```
{env}/catalog/{catalogId}/products/{productId}/{uuid}.{jpg|png|webp}
```

`{env}` is config-driven from `NODE_ENV` (non-negotiable — it is the prefix-delete firewall).
`{userId}` is **not** in the path; ownership comes from the token and the DB. Unlike avatars these
go in `BUCKET_ARTIFACTS` behind CloudFront, because a product photo is public catalog content, not
PII — the opposite of the avatar decision, for the opposite reason.

---

## 7. Sync Layer Design

The critical section. Everything here is shaped by three facts from `01-codebase-findings.md`:
Mirage has **no idempotency**, **no batch writes**, and returns **400 for nearly everything**.

### 7.1 Trigger and concurrency

Publish is user-triggered only. `POST /catalog/publish`:

1. rate-limits via `consumeRateWindow('publish:{userId}', PUBLISH_MAX_PER_WINDOW, …)`;
2. validates publishability (§7.7);
3. refuses if `activePublishRunId` is set and its job is not terminal → `409 PUBLISH_IN_PROGRESS`
   (one run per catalog; a second run would race Mirage's non-atomic writes);
4. writes `publishedSnapshot` intent by recording `snapshotRevision = catalog.draftRevision`;
5. inserts the `PublishRun` + the `Job`, sets `activePublishRunId` with a **conditional
   `findOneAndUpdate` guarded on `activePublishRunId: null`** — the house atomicity pattern, no
   transaction;
6. returns `202 { runId }`.

The client polls `GET /catalog/publish/status`. No websockets — the capture flow already polls and
the app has no socket infrastructure.

### 7.2 The adapter (`src/services/mirage/mirageClient.ts`)

The only module that knows Mirage exists. Responsibilities:

- attaches `apikey: env.MIRAGE_API_KEY` and `token: <admin JWT>` headers
  (`mirage-be/src/Middlewares/apiKeyValidator.js`, `Middlewares/middleware.js:19-31`);
- injects `CLOUD_FRONT_URL` and `BUCKET_NAME` into **every** write body — Mirage reads them from the
  body, and omitting them writes the literal string `undefined` into a customer-facing URL;
- unwraps `{status: boolean, message, data}` and **translates it into the ReCapture envelope's
  vocabulary** — a Mirage boolean `status` must never reach a ReCapture response;
- **classifies** the result, which is the hard part, because Mirage returns 400 for validation
  errors, not-found, a bad api key, *and* its global 404 handler. Classification is by
  (status, message-substring) pairs, kept in one table with a comment naming each Mirage source line:

  | Signal | Class |
  |---|---|
  | HTTP 5xx, timeout, ECONNRESET, socket hang up | **retryable** |
  | 400 + `"already exist"` | **reconcile** — adopt the existing entity (§7.4) |
  | 400/403 + `"Api key"` \| `"Login again"` \| `"jwt expired"` | **auth** — refresh admin token once, then terminal |
  | 400 + anything else, 404, 413 (`"File too large"`) | **terminal** |

  Terminal failures raise `NonRetryableJobError`, the existing mechanism that stops the worker
  retrying a doomed job.
- Every classification rule is pinned by a fake-Mirage contract test. Mirage has no tests and no
  types; a prose message is the only signal, so the fakes are the contract.

### 7.3 Processor stages

`worker/processors/mirageCatalogPublishProcessor.ts`, registered via `registerProcessor`. Stages run
in order and each is **individually resumable** — the worker writes progress to the DB as it goes,
so a re-claim after a crash (which `claimNextJob` performs automatically on a stale lease) restarts
at the first incomplete unit, not at the beginning.

```
PLAN ─► PROVISION ─► BRANDING ─► CATEGORIES ─► PRODUCTS ─► FINALIZE
                                                   │
                              per product: CREATE | UPDATE | DELETE
                                           (+ asset streaming)
```

- **PLAN** — diff each non-archived product's current fields against `publishedSnapshot` to derive
  its action: `CREATE` (no `mirageItemId`), `UPDATE` (snapshot differs), `SKIP` (identical),
  `DELETE` (archived or deleted but has a `mirageItemId`). Skipping unchanged products is what keeps
  a republish cheap given there are no batch endpoints.
- **PROVISION** — §7.5.
- **BRANDING** — M3. Note M3 400s unless **both** `name` and `location` are strings, so the adapter
  always sends both, substituting `""` for an empty location.
- **CATEGORIES** — create missing (M5), rename changed (M6). A category with no `mirageCategoryId`
  is created first because M8 requires a valid category ObjectId. The "Uncategorized" bucket
  (feature 26) is materialised here as a real Mirage category on first need.
- **PRODUCTS** — sequential, one at a time. Sequential rather than parallel on purpose: Mirage
  buffers whole files in memory (`libs/s3.js` `readFileSync`) and self-pings to stay awake on a
  sleeping tier; concurrent 90 MB multipart uploads are the fastest way to take it down. At 5–20
  businesses, throughput is not the constraint.
- **FINALIZE** — §7.8.

### 7.4 Idempotency without server support

Per product, in order:

1. **Has `mirageItemId`?** → M9 update. If M9 404s / says not found, clear the mapping and fall to (2).
2. **No mapping** → M8 create. On success, persist `mirageItemId` **before** anything else — this
   single write is what makes a crash cost zero duplicates, the same reasoning as `meshyTaskId`
   being persisted the instant the Meshy task exists.
3. **M8 returns `400 "Product already exist"`** → the create half-succeeded on an earlier attempt, or
   a name genuinely collides. **Reconcile:** call M12 `GET /get-all-items-for-cat/:categoryId`, find
   the item whose `name` matches exactly, adopt its `_id` as `mirageItemId`, and convert the action
   to `UPDATE`. If no match is found the name belongs to a different product → terminal
   `PRODUCT_NAME_CONFLICT`, surfaced to the user as an actionable rename prompt (feature 68).

The same three-step shape applies to categories via M11, and to the restaurant via M1.
**Publishing product X twice can therefore never create two Mirage entries** (brief §7).

### 7.5 Provisioning and the mapping (features 40–42)

On first publish, if `mirageRestaurantId` is null:

1. M1 `get-all-restaurants` → look for an exact case-insensitive name match, to adopt a
   pre-existing restaurant instead of failing (pilot businesses may already exist in Mirage);
2. otherwise M2 `create-restaurant` with `name`, `location`, `phoneNo`, `description`, the logo as
   the `image` file, plus `CLOUD_FRONT_URL`/`BUCKET_NAME`;
3. persist `mirageRestaurantId` immediately, **then** mint and freeze `publicUrl` (§8).

⚠ M2's uniqueness check is an unanchored case-insensitive regex, so "Cafe" is rejected when
"Blue Cafe House" exists. The adapter surfaces this as `CATALOG_NAME_TAKEN` with a suggested
alternative rather than retrying. Because the public URL is `_id`-based, the Mirage `name` is a
**bookkeeping label only** — the business's displayed name comes from the catalog record, so
appending a disambiguator to the Mirage name has no customer-visible effect. That is a direct
benefit of decision (d).

### 7.6 Deletes and unpublish

- **Archive/delete a published product** → M10 on publish. ⚠ M10 also hard-deletes the category when
  the product was its last item (`adminController.js:1312-1319`), so the processor **clears
  `mirageCategoryId` on the affected category whenever it deletes the last item in it**, forcing a
  re-create on the next run. Missing this produces `400 "Category not found"` on the next M8.
- **Unpublish (39)** — Mirage has **no offline/hidden flag**, and M4 would destroy the restaurant
  `_id` and therefore the QR. **Recommendation: unpublish deletes the items (M10) and keeps the
  restaurant.** The public page then renders an empty catalog under the same URL, the QR keeps
  working, and republish restores everything. Deleting the restaurant is offered only behind an
  explicit "delete catalog permanently, QR will stop working" confirmation. This trade-off is
  Q1 in `06-open-questions.md`.

### 7.7 Publish-time validation gates (all failures are ReCapture-side, before any Mirage call)

- catalog name and business name present;
- **at least one non-archived product** — Mirage renders an empty page fine, but a QR that leads
  nowhere is a bad first impression; publish is **blocked with a clear message** (edge case §8);
- every product has a name, and names are unique within the catalog (mirrors Mirage's constraint,
  caught early where the error can be fixed);
- every 3D product's `sourceModelId` resolves to a `SUCCEEDED` `ProjectModel` with
  `artifacts.cdnUrls.glb` present;
- every asset passes the **preflight** in §7.9;
- every image-only product has an `imageKey` whose object exists.

### 7.8 Finalize, partial failure, and state

After the product loop the run is classified:

- `SUCCEEDED` (0 failures) → `catalog.status = 'PUBLISHED'`,
  `publishedRevision = snapshotRevision`, `lastPublishedAt = now`, `activePublishRunId = null`.
- `PARTIAL` (≥1 failure, ≥1 success) → the catalog **stays PUBLISHED** if it already was, or becomes
  `PUBLISHED` on a first publish (the successful products are genuinely live and the QR must work).
  `publishedRevision` is **not** advanced, so feature 38 keeps showing "draft changes not live" —
  which is true. Failed products keep `syncStatus: FAILED` + `syncError`.
- `FAILED` (0 successes) → catalog state unchanged; the whole run is retryable.

The worker's own retry (backoff 1→2→4 min, cap 30 min) covers transient failures automatically
(feature 54). When attempts are exhausted the run lands `PARTIAL`/`FAILED` and feature 53's manual
retry re-enqueues a job scoped to `syncStatus: FAILED` products only.

### 7.9 Asset streaming (features 49–51)

The unavoidable shape: **ReCapture holds CloudFront URLs; Mirage accepts only file bytes.**

Per asset: `GET` the object from **`BUCKET_ARTIFACTS` via the S3 client** (not over the public
CloudFront edge — the worker already has credentials, and a direct S3 read avoids a CDN round trip
and any cache staleness), stream it into the multipart body, POST to Mirage. Mirage re-uploads to
`MIRAGE_ASSET_BUCKET` and stores `` `${CLOUD_FRONT_URL}/${key}` ``.

- **Preflight before any upload:** HEAD the object; reject missing objects and anything over
  `MIRAGE_MAX_ASSET_BYTES` (90 MiB, under Mirage's 100 MB multer cap) as terminal
  `ASSET_TOO_LARGE` — this is how a corrupt or oversized model is caught at the ReCapture side and
  never sent to Mirage (edge case §8).
- **Prefer the optimized GLB.** `latestSucceededModel` already returns the OPT record once one
  exists, so products naturally reference the smaller file. Mirage buffers whole files in memory;
  shipping a 60 MB raw GLB where a 4 MB optimized one exists is a real risk.
- **Assets are re-sent only when they changed** — the diff compares `assets.glbUrl` against the
  snapshot. Republishing text edits does not re-upload models.
- **Accepted consequence:** every published asset exists twice — once on `msxr-model-artifacts`
  behind ReCapture's CloudFront, once on `maya-restaurants` behind Mirage's. This is forced by
  Mirage's upload design, not chosen. **The constraint "CloudFront over raw S3" still holds**: every
  URL a customer ever receives is a CloudFront URL, and ReCapture introduces no second storage system
  of its own. Eliminating the duplicate needs a Mirage change (Q-C1 in `06-open-questions.md`).
- **USDZ cannot be delivered** — no multer field, no controller write (gap 49b). 3D products publish
  with `model.src` only; iOS falls back to the `<model-viewer>` web path. Raised as Q-C2.

### 7.10 Publish/Draft/Sync state machine

**Catalog:**

```
                    POST /catalog
                         │
                         ▼
   ┌──────────────────  DRAFT  ──────────────────┐
   │  publishedRevision = -1, publicUrl = null   │
   └──────────────────────┬──────────────────────┘
                          │ publish run SUCCEEDED
                          │ (provision mints + FREEZES publicUrl)
                          ▼
   ┌────────────────  PUBLISHED  ────────────────┐
   │  publicUrl frozen forever from this point   │◄──┐
   │  live = last successful snapshot            │   │ publish run
   └───────┬──────────────────────────┬──────────┘   │ SUCCEEDED
           │ any authoring write      │ unpublish    │
           │ draftRevision++          ▼              │
           │                   ┌──────────────┐      │
           │                   │ UNPUBLISHED  │──────┘
           │                   │ items removed│  republish
           │                   │ URL + QR kept│
           ▼                   └──────────────┘
   PUBLISHED + draftRevision > publishedRevision
   → feature 38 badge: "Draft changes not yet live"
   (the LIVE catalog is untouched — feature 57)
```

**Publish run:** `QUEUED → RUNNING → { SUCCEEDED | PARTIAL | FAILED }`, with the worker's
`QUEUED ⇄ RUNNING` retry loop in between and stale-lease re-claim on crash.

**Per product:** `NEVER ─publish→ PENDING ─► SYNCED` or `─► FAILED ─retry(53)→ PENDING`.
Any authoring edit to a `SYNCED` product does **not** change `syncStatus` — it bumps
`draftRevision`, and the product is re-planned as `UPDATE` on the next run. This keeps "synced"
meaning "Mirage matches the last snapshot", which is the question the user is actually asking.

---

## 8. QR / Public URL Strategy (feature 32 — hard constraint)

### What the code says

- The public catalog page is `mirage-fe/src/App.tsx:217-224` → `path="/:restaurant"`, and that
  segment goes straight to M14 (`mirage-fe/src/features/menu/useFetchApiForNewUi.ts:80`).
- M14 resolves it (`mirage-be/src/Controllers/itemController.js:472-478`):

  ```js
  let restaurantDetails = await restaurantModel.findOne({
     name: { $regex: restaurantSlug.toLowerCase(), $options: "i" } });
  if (!restaurantDetails && mongoose.isValidObjectId(restaurantSlug)) {
     restaurantDetails = await restaurantModel.findById(restaurantSlug);
  }
  ```

- **There is no `slug` field on the restaurant schema.** The de-facto slug is the mutable `name`.
- The same two-step (name-regex, then ObjectId fallback) appears in `getCategories`
  (`itemController.js:62-67`), `getItemsByCategory` (`:160-166`), `getAllItems` (`:266-272`),
  `getAllCategories`, `getALlCategoriesAdmin` and `getAllItemsForCat`.

### The decision

**Mint the public URL as `{MIRAGE_PUBLIC_BASE_URL}/{mirageRestaurantId}` — the Mirage ObjectId.**

Why this satisfies feature 32:

1. A Mongo `ObjectId` is **immutable**. Renaming the catalog (feature 2) changes `restaurant.name`
   via M3 and leaves `_id` untouched → the QR survives a rename, which is exactly the edge case the
   brief calls out.
2. Every public read path already resolves an ObjectId segment via the documented `findById`
   fallback. This is **not** a new Mirage capability — it is existing behaviour, so no Mirage change
   is proposed or required.
3. Republishing, adding, editing, reordering and deleting products never touch `_id`.
4. A name-based URL would be actively unsafe here: Mirage denormalises `restaurantSlug` onto every
   category and item **at create time** (`adminController.js:604`, `:950`) and no update path ever
   rewrites it, so after a rename parent and children disagree and `newSearchByText`
   (`itemController.js:430`) queries the stale copy. And the name lookup is an **unanchored regex**,
   so a short name resolves to whichever containing restaurant `findOne` returns first.

**Belt and braces — the URL is stored, not computed.** `catalog.publicUrl` is written once, at
provisioning, and every read (feature 34/35, the QR renderer, the share sheet) returns that stored
string. No code path ever recomputes it. `publicUrlScheme: 'MIRAGE_OBJECT_ID'` records how it was
derived, so if the scheme ever changes, already-issued URLs are visibly grandfathered rather than
silently rewritten. **Any future change that would recompute `publicUrl` for an existing catalog is
a violation of feature 32** and should fail code review on that basis.

**QR rendering (33)**: server-side from `publicUrl`, PNG and PDF from one code path
(`GET /catalog/qr?format=png|pdf`). The QR image is a pure function of a frozen string, so it is
byte-identical on every download — a business that already printed a sticker gets the same code.

**Residual risk, flagged not hidden:** the name-regex lookup runs *first*, so a restaurant whose
**name literally contains** the 24-hex id string would shadow the ObjectId route. This requires a
business to name itself a hex ObjectId; it is not defended against, only noted (Q-B in
`06-open-questions.md`). A one-line Mirage change — try `findById` before the regex — would remove
it entirely, but proposing Mirage changes is out of scope here.

---

## 9. APIs Required

Consolidated for review. **New ReCapture endpoints:** the 30-row table in §5.
**Mirage endpoints consumed:** the 14-row table in §5, every one citing a `mirage-be` file and route
handler. No Mirage endpoint appears anywhere in these deliverables that was not read in
`mirage-be/src/`.

**Rules that hold across all of them:**

- Mirage is reachable **only** from `recapture-api`. The Flutter client never sees
  `MIRAGE_BASE_URL`, `MIRAGE_API_KEY`, or an admin token (brief §7).
- Only `src/services/mirage/` imports the Mirage adapter. Routes and other services call
  `catalogPublishService`, never Mirage directly.
- Analytics proxies **force** `?restaurant=` from `catalog.mirageRestaurantId` server-side. Accepting
  it from the client would turn a per-business dashboard into a cross-tenant read, because the
  Mirage admin credential is unscoped.

---

## 10. Analytics Events Plan (features 61–66)

Two populations, and they must not be conflated.

### 10a. Customer-facing events — already emitted, no new instrumentation

Features 61–65 are satisfied by event types that **already exist** in
`mirage-be/src/Models/analyticsEventModel.js` (`EVENT_TYPES`) and are already emitted by the public
page into M26. ReCapture's job is to **read** them, not to define them. Renaming any of these
strings orphans historical rows — the model file says so explicitly.

| Feature | Mirage event type | Trigger (on the public catalog page) | Properties available |
|---|---|---|---|
| 61 catalog views | `client_page_view` (+ `session_start`) | QR scan / direct open of `/{publicUrl}` | `restaurant`, `restaurantSlug`, `visitorId`, `sessionId`, `path`, `device`, `country` |
| 62 product views | `product_page_view` | product opened by deep link / URL | `productId`, `productName`, `categoryName` |
| 62 product views | `product_detail_opened` | detail sheet opened | `productId`, `productName`, `categoryName`, `source` (`card\|hero\|deep_link\|search`) |
| 63 3D model loads | `model_loaded` (+ `model_load_failed`) | `<model-viewer>` load resolves/rejects | `productId` |
| 64 AR launches | `ar_view_clicked` → `ar_session_started` | AR button tapped → AR session actually starts | `productId`, `productName`, `arSupported`, `trigger` (`card\|detail\|qr_auto`) |
| 65 image-only views | `product_page_view` / `product_detail_opened`, **partitioned ReCapture-side** | as above | joined on `props.productId` → `catalog_products.mirageItemId` → `type` |

**Feature 65 needs no Mirage change.** Mirage does not tag events by product type, but ReCapture
already knows which of its products are `IMAGE_ONLY` and holds the `mirageItemId` mapping, so
`catalogAnalyticsService` splits the M29 `top-products` rows into 3D vs image-only after the fetch.
The `views`/`arViews` fields M29 returns per product are exactly what feature 66's dashboard needs.

**Feature 66 read path:** `GET /catalog/analytics/summary|timeseries|top-products` →
M27/M28/M29 with `?restaurant={mirageRestaurantId}` forced server-side, `?days` or `?from/&to` passed
through, `?limit` clamped. Dashboard shows: catalog views, unique visitors, top viewed products,
AR launches, and a 3D-vs-image-only split. ⚠ These Mirage routes are **admin-scoped** and their own
in-code note (`analyticsRoutes.js:20-24`) forbids opening them to client scope — proxying with a
server-held admin credential is the only route that respects that.

### 10b. ReCapture-side authoring events — new, emitted through the existing seam

Emitted via `utils/analytics.ts → trackEvent` (backend) and `lib/utils/analytics.dart →
Analytics.logEvent` (client) — the one entry point per side. **Props must be non-PII only**: hashed
identifiers, enum values, counts. No business name, phone, address, or product names.

| Event | Side | Trigger | Properties |
|---|---|---|---|
| `catalog_created` | BE | `POST /catalog` succeeds | `user_id_hash` |
| `catalog_product_added` | BE | product create succeeds | `user_id_hash`, `product_type`, `source` (`existing_model\|fresh_scan\|image`) |
| `catalog_product_updated` | BE | product patch succeeds | `user_id_hash`, `fields_changed_count`, `type_converted` (bool) |
| `catalog_product_archived` / `_deleted` | BE | archive / hard delete | `user_id_hash`, `was_published` |
| `catalog_publish_requested` | BE | `POST /catalog/publish` accepted | `user_id_hash`, `product_count`, `is_first_publish` |
| `catalog_client_provisioned` | BE | M2 create-restaurant succeeds | `user_id_hash`, `adopted_existing` (bool) |
| `catalog_publish_succeeded` | BE | run → SUCCEEDED | `user_id_hash`, `synced_count`, `duration_ms`, `assets_uploaded` |
| `catalog_publish_partial` | BE | run → PARTIAL | `user_id_hash`, `synced_count`, `failed_count`, `top_error_code` |
| `catalog_publish_failed` | BE | run → FAILED | `user_id_hash`, `error_code`, `attempts` |
| `catalog_sync_retry_clicked` | BE | `POST /catalog/publish/retry` | `user_id_hash`, `failed_count` |
| `catalog_unpublished` | BE | unpublish completes | `user_id_hash`, `items_removed` |
| `catalog_asset_rejected` | BE | preflight rejects an asset | `user_id_hash`, `reason` (`too_large\|missing\|unsupported`) |
| `catalog_qr_downloaded` | FE | QR download completes | `format` (`png\|pdf`) |
| `catalog_link_shared` | FE | share sheet dismissed with an action | — |
| `catalog_preview_opened` | FE | preview screen opened | `product_count` |
| `catalog_analytics_opened` | FE | dashboard opened | `range_days` |

⚠ **There is no analytics destination wired** on either side today (AGENTS.md §Analytics — the
emit seams log in non-prod only, and a typed registry, per-event Zod schemas, a PII guardrail and a
real destination are all "NOT YET BUILT"). These events will therefore be **defined and emitted but
not collected** until that pipeline exists. Features 61–66 are unaffected — they read Mirage's
independent, fully-working analytics store, not ReCapture's seam. This is Q-B in
`06-open-questions.md`.

---

## 11. Risks

| # | Risk | Impact | Mitigation |
|---|---|---|---|
| R1 | **Mirage's write API is unversioned, untested, untyped** — prose error messages are the only failure signal, and any edit to `adminController.js` can silently change behaviour | Sync breaks in production with no compile-time or CI warning | All classification rules in one table with cited source lines; a fake-Mirage contract test per rule; a post-publish verification read of M14 |
| R2 | **Asset duplication across two CDNs** (forced by Mirage's bytes-only upload) | Double storage cost; a replaced model orphans the old Mirage object forever | Accepted for MVP; only changed assets are re-sent; Q-C1 asks for URL passthrough |
| R3 | **`delete-item` cascade-deletes the category** when it removes the last item | Next publish fails `400 "Category not found"` | Processor clears `mirageCategoryId` whenever it deletes the last item in a category; covered by a test |
| R4 | **Name-based uniqueness is Mirage's only key** — global fuzzy-regex for restaurants, per-restaurant exact for items | A pilot business can be blocked from provisioning by an unrelated existing name | ObjectId-based URL makes the Mirage name a bookkeeping label, so it can be disambiguated freely; `CATALOG_NAME_TAKEN` surfaces a suggestion |
| R5 | **M9 ignores `description`, `category` and `imgOnly`** | Three edit paths silently do nothing on the public page | Detected at PLAN time; those changes force a delete+recreate (which mints a new Mirage item id) or are blocked with a clear message. Q-C3/Q-C4 |
| R6 | **Unpublish has no safe primitive** — the only removal is M4, which destroys the `_id` and the QR | Feature 39 vs feature 32 are in direct tension | Default unpublish removes items and keeps the restaurant; restaurant deletion is a separate, explicitly-confirmed destructive action. **Q1, blocking** |
| R7 | **The Mirage admin credential is unscoped** — one static API key (hardcoded in source and shipped in the public web bundle) plus an admin JWT grants read/write over every restaurant | A bug in the `?restaurant=` forcing, or a leaked ReCapture env, exposes all tenants | Credential lives only in `recapture-api` env; `?restaurant=` is forced server-side and never read from the client; a test asserts a client-supplied `restaurant` param is ignored. Q2 |
| R8 | **Mirage runs on a sleeping tier** (30 s self-ping in `index.js`) | First publish after idle may time out | 60 s timeout, worker retry, a warm-up call before a run — the same pattern as `axiosBackendMakeAlive.ts` / `backend_warmup_service.dart` already in ReCapture |
| R9 | **No sort field on Mirage** — features 10/48 cannot reach the public page | The business reorders and nothing changes for customers | Order is honoured inside ReCapture; the publish screen states plainly that public order is by creation date. Q-C5 |
| R10 | **meshopt decoder must be set on two separate pages** | Every optimized GLB shows "couldn't load this model" on one platform | The new preview surface must set it in both places; extend `test/projects/meshopt_decoder_test.dart` |
| R11 | **Hand-synced DTOs** between Dart entities and TS services | Drift ships a silent parse failure | Field-by-field parsers (`tryFrom*Map`, never a spread), plus a golden-JSON test per DTO on both sides |
| R12 | **Publish is long-running and user-visible** | A 20-product first publish with 20 model uploads can take minutes | `202` + polling from the start; per-product progress in `GET /catalog/publish/status`; partial success is a first-class state, not an error |

---

## 12. Implementation Phases

Feeds `04-task-breakdown.md`.

1. **Foundations** — models + indexes, catalog CRUD, business profile, Mirage config, the adapter,
   Flutter catalog shell and repositories.
2. **Product management** — product create (all three sources), image presign/commit, edit/replace,
   archive/restore/delete, categories, list/filter/search, and the Flutter screens for each.
3. **Catalog & QR** — provisioning, URL minting and freezing, QR render/download/share, preview.
4. **Publish & sync** — the job type and processor, category sync, product sync with reconciliation,
   asset streaming, the publish/unpublish endpoints, per-product sync status and retry, the publish UI.
5. **Analytics** — the proxy service and the dashboard.
6. **Polish** — toasts, error/success states, bulk actions, duplicate, activity log, test hardening.

---

## 13. Testing Checklist

Hermetic per AGENTS.md §Testing: isolated store, deterministic, **no real network**. Backend env is
injected by `vitest.config.ts` *before* the module graph loads. Mirage is **always** faked — CI must
never call the live Mirage, which shares a database with production.

**Backend (Vitest + Supertest + `mongodb-memory-server`)**

- Catalog CRUD: one catalog per user (unique index enforced under a concurrent double-create);
  ownership isolation — another user's catalog is an **identical** 404, not a 403.
- Product CRUD incl. type conversion (17), duplicate naming (18), archive→restore (19/20).
- Product image commit: a key belonging to another user is a **403**; oversize is rejected; the
  key parser rejects traversal — mirroring `tests/avatar-keys.test.ts`.
- **Publish planner**: CREATE/UPDATE/SKIP/DELETE derivation from `publishedSnapshot`; unchanged
  products are skipped; unchanged assets are not re-uploaded.
- **Idempotency**: publishing the same product twice produces **one** M8 call and one
  `mirageItemId`; a simulated crash after M8 but before the mapping write, replayed, reconciles via
  M12 and does **not** create a second item. *(This is the brief's §7 non-negotiable.)*
- **Concurrency**: two simultaneous `POST /catalog/publish` → one `202`, one `409`.
- **Error classification**: a table-driven test over every (status, message) pair from §7.2,
  asserting retryable vs reconcile vs auth vs terminal, each fixture quoting the real Mirage message.
- **Mirage down**: connection refused / 500 / timeout → job retries with backoff, catalog state
  unchanged, **no partial write claimed as success**.
- **Last-item category cascade**: after M10 removes a category's last item, the next run re-creates
  the category before M8.
- **QR stability**: rename the catalog → `publicUrl` byte-identical; republish → identical;
  add/delete products → identical; `publicUrl` is never recomputed once set. *(feature 32)*
- **Analytics proxy**: a client-supplied `?restaurant=` is ignored; the mapped id is always used;
  a catalog with no `mirageRestaurantId` returns empty rather than an unscoped read.
- **Envelope**: no Mirage boolean `status` and no raw Mirage message string escapes into any
  ReCapture response body.
- **PII**: no phone, email, business address or raw product name appears in any emitted analytics
  props or log line.

**Client (`flutter test`, Hive temp-dir helpers)**

- DTO parsers for every new entity, field-by-field, incl. unknown-field tolerance and null handling.
- Publish notifier state machine: queued → running → succeeded / partial / failed, and the
  "draft changes not yet live" badge derived from revisions.
- Product list: filter (28) + search (29) + pagination against a faked repository.
- **meshopt decoder present in both `web/index.html` and `_lifecycleJs`** — extend the existing
  `test/projects/meshopt_decoder_test.dart` to cover the new preview surface.
- Offline: catalog writes are disabled and messaged, never silently queued.

**Manual / QA before pilot**

- Full loop on a real phone: create catalog → add one 3D + one image-only product → publish →
  scan the printed QR → verify both render, AR launches on Android, and the analytics dashboard
  shows the visit within the reporting window.
- Rename the catalog, republish, **re-scan the same printed QR**.
- Kill the worker mid-publish; confirm re-claim resumes and produces no duplicates.

---

## Appendix — The 10 Edge Cases (brief §8)

| # | Case | Behaviour |
|---|---|---|
| 1 | **Partial sync failure** (3 of 10 fail) | Run ends `PARTIAL`. The 7 successes are live — the catalog is/stays `PUBLISHED` so the QR works. `publishedRevision` is **not** advanced, so the "Draft changes not yet live" badge stays on. The 3 failures show `syncStatus: FAILED` with an actionable `syncError` on their product cards, and the publish screen shows "7 of 10 published · 3 failed" with a **Retry failed** action (53) that re-enqueues only those 3. |
| 2 | **Local edit, not republished** | Nothing was sent to Mirage — authoring writes only bump `draftRevision`. The public page keeps serving the last published snapshot. The app shows the draft value locally and the badge from feature 38. This is feature 57, enforced by the fact that only the publish worker holds Mirage credentials. |
| 3 | **Product deleted locally** | Nothing happens on Mirage until publish. On publish the planner emits `DELETE` → M10, a **hard delete**, because Mirage's `isDeleted` flag is never written by any endpoint and M7 (`delete-category`) is a stub — there is no archive primitive to use. **Recommendation: delete on publish**, since a product left visible after the owner deleted it is worse than losing Mirage-side history; ReCapture keeps the archived row and can re-create it (20). Q-A in `06-open-questions.md`. |
| 4 | **Corrupt / unsupported 3D model** | Caught entirely ReCapture-side and **never sent to Mirage**. Three gates: the product can only reference a `ProjectModel` with `status: SUCCEEDED` and a present `artifacts.cdnUrls.glb`; the publish validation gate (§7.7) re-checks it; the asset preflight (§7.9) HEADs the object and enforces `MIRAGE_MAX_ASSET_BYTES`. A failure is terminal `ASSET_INVALID`/`ASSET_TOO_LARGE` on that product only — the rest of the run proceeds. |
| 5 | **Second device** | All catalog, draft and sync state is **server-truth**. The client caches for warm start only (the existing `projects_cache` pattern) and always revalidates on screen open. `syncStatus`, `draftRevision`/`publishedRevision`, and `activePublishRunId` all live in Mongo, so device B sees the same badge and the same in-progress publish. The catalog offline queue is deliberately **not** used for catalog writes (§4). |
| 6 | **Mirage is down** | The adapter classifies connection failures/5xx/timeouts as **retryable**. The publish job returns to `QUEUED` with backoff 1→2→4…→30 min (`worker/jobQueue.ts:19-20`) — an existing, tested mechanism. The catalog does **not** flip state, `publishedRevision` is not advanced, and nothing is claimed as published. If attempts exhaust, the run is `FAILED`, the user sees "Mirage is unreachable — we'll keep trying" with a manual retry. Products that already synced in an earlier run keep their `mirageItemId`, so recovery re-syncs only the rest — no partial write gets stuck. |
| 7 | **Image-only → 3D conversion (17)** | ReCapture-side: `type` flips to `THREE_D`, `sourceModelId` is set, `assets.glbUrl`/`thumbnailUrl` are taken from the `ProjectModel`, and the old `imageKey` is **retained** until the next successful publish, then swept (pointer flips before the sweep, so a crash orphans an object rather than breaking a product — the avatar precedent). The thumbnail is **not** regenerated: the 3D model already carries a generated `previewUrl`, which becomes the product image. ⚠ Mirage-side, M9 **cannot unset `imgOnly`** — the public page would still treat it as image-only. The planner therefore emits **DELETE + CREATE** for a type conversion, which mints a new Mirage item id (updated in the mapping) and loses that product's Mirage-side view counter. Flagged to the user as "this product will get a new link". Q-C4. |
| 8 | **Zero products** | Publish is **blocked** with `CATALOG_EMPTY`: "Add at least one product before publishing." Mirage would happily render an empty page, but the QR is a physical artifact — a business that prints a sticker leading to an empty catalog has a worse outcome than one that cannot publish yet. Non-destructive and easily reversed, so blocking is the right default. |
| 9 | **Catalog rename** | The QR and URL **do not change**. `publicUrl` is derived from the immutable Mirage `_id` and frozen at provisioning; a rename sends M3 to update `restaurant.name` for bookkeeping and touches nothing else. Guarded by an explicit test (§13). This is the whole reason for the §8 decision. |
| 10 | **Unpublish (39)** | **Default: items are deleted (M10), the restaurant document and therefore the `_id`, URL and QR are kept.** The public page renders an empty catalog; republishing restores everything under the same QR. Using M4 would hard-delete the restaurant and destroy the `_id`, permanently breaking every printed QR — so it is **not** what "unpublish" does. Full deletion is available only as a separate, explicitly-confirmed "delete catalog permanently — your QR code will stop working" action. Mirage has no hide/offline flag, so this is a trade-off, not a free choice: **Q1, blocking.** |
