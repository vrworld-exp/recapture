✅✅✅✅✅✅✅✅✅✅✅✅/2
# 02 — Feature → Side Mapping

Every feature 1–69 assigned to the side(s) that must build it.

**Sides:** `RC-FE` ReCapture Flutter client · `RC-BE` ReCapture Node backend ·
`MIRAGE-API` an existing Mirage endpoint ReCapture calls (nothing new built on Mirage) ·
`NEW-INTEGRATION` the new adapter/sync layer inside the ReCapture backend ·
`CROSS` cuts across several.

Mirage endpoints are referenced by the IDs from `01-codebase-findings.md` §"Complete Route Table"
(M1–M29). `MIRAGE-API (gap)` means the feature needs Mirage behaviour that does not exist in
`mirage-be/` — each is raised in `06-open-questions.md` §C.

---

## A. Product Catalog — Create & Manage

### A1. Catalog Container

| # | Feature (short) | Side(s) | Mirage endpoint used | Notes / dependencies / risks |
|---|---|---|---|---|
| 1 | One primary catalog per user | RC-BE, RC-FE | — | New `Catalog` collection, unique index on `userId`. No Mirage counterpart until first publish |
| 2 | Catalog metadata (name, business name, logo, cover, contact) | RC-BE, RC-FE | — | Only `name`/`icon`/`phone`/`location`/`description` have a Mirage home (M2/M3). **Cover image has no Mirage field** → stored ReCapture-side only |
| 3 | Unique catalog ID | RC-BE | — | Mongo `ObjectId`. Distinct from the Mirage restaurant id — feature 41 maps the two |
| 4 | Catalog status Draft / Published | RC-BE, RC-FE | — | Mirage has no published flag; "unpublished" is modelled ReCapture-side (see 39) |
| 5 | Preview before publishing | RC-FE | — | Renders from the ReCapture draft, not from Mirage. Reuses `model_viewer_plus` as on `model_viewer_screen.dart` |

### A2. Add Product to Catalog

| # | Feature (short) | Side(s) | Mirage endpoint used | Notes / dependencies / risks |
|---|---|---|---|---|
| 6 | Add a product | RC-BE, RC-FE | — (M8 at publish) | Draft-only write; nothing reaches Mirage until publish (feature 57) |
| 7 | Two modes: 3D product / image-only | RC-BE, RC-FE | M8 `POST /api/v1/create-item` (`adminController.createItems`, `adminController.js:783`) | Maps to Mirage's `imgOnly` boolean, which `createItems` sets itself when an image arrives without an object (`adminController.js:963-969`) |
| 8a | Fields: name, description, price, category | RC-BE, RC-FE | M8 / M9 | ⚠ **M9 `update-item` never writes `description` or `category`** (`adminController.js:1038-1047`) → edits to those two are `MIRAGE-API (gap)` |
| 8b | Field: product tags | RC-BE, RC-FE + MIRAGE-API (gap) | — | **No tags field on Mirage's item schema.** ReCapture-side only; not visible on the public catalog |
| 8c | Field: availability (in stock / out of stock) | RC-BE, RC-FE + MIRAGE-API (gap) | — | **No availability field on Mirage's item schema.** Out-of-stock cannot be shown to customers |
| 8d | Thumbnail auto-generated for 3D only | RC-BE | M8 (`image` file field) | Reuse `ProjectModel.artifacts.cdnUrls.preview` (`OwnerModelListItemDto.previewUrl`) — already generated. Image-only products use their own upload |
| 9 | Mark product as "featured" | RC-BE, RC-FE + MIRAGE-API (gap) | — | **No featured flag on Mirage's item schema.** Affects ReCapture-side ordering only |
| 10 | Reorder products | RC-BE, RC-FE + MIRAGE-API (gap) | — | See 48. Mirage sorts `createdAt: -1` (`itemController.js:543`) and stores no position |

### A3. Product Sources

| # | Feature (short) | Side(s) | Mirage endpoint used | Notes / dependencies / risks |
|---|---|---|---|---|
| 11 | Add from existing captured model | RC-BE, RC-FE | — | Reads the existing owner surface `GET /projects/:id/models` (`routes/projects.ts:408`). Only `status: SUCCEEDED` models are selectable |
| 12 | Add from a fresh scan | RC-FE | — | Deep-links into the **existing, unmodified** capture flow (`AppRoutes.preCapture`) and returns with the resulting `modelId`. No change to the capture pipeline |
| 13 | Add using a single image | RC-BE, RC-FE | — (M8 at publish) | New image key space + 3-step presign→PUT→commit, cloned from the avatar flow (`routes/auth.ts:208,400`) |

### A4. Edit Product

| # | Feature (short) | Side(s) | Mirage endpoint used | Notes / dependencies / risks |
|---|---|---|---|---|
| 14 | Edit any product field | RC-BE, RC-FE | M9 `PUT /api/v1/update-item/:itemId` (`adminController.updateItem`, `adminController.js:1021`) | M9 applies only `name`, `price`, `isNonVeg`, `annotations`, and the two files. Description/category/tags/availability edits are `MIRAGE-API (gap)` |
| 15 | Replace the 3D model | RC-BE, RC-FE, NEW-INTEGRATION | M9 (`object` file field) | Re-streams the new GLB. Old Mirage S3 object is orphaned — Mirage never deletes replaced assets |
| 16 | Replace the image | RC-BE, RC-FE, NEW-INTEGRATION | M9 (`image` file field) | Same orphaning caveat |
| 17 | Convert image-only → 3D | CROSS | M9 (`object` file field) | ⚠ M9 **cannot unset `imgOnly`** — it is never assigned on the update path. The public page would keep treating the product as image-only → `MIRAGE-API (gap)`; workaround is delete-then-recreate (M10 + M8), which changes the Mirage item id |
| 18 | Duplicate a product | RC-BE, RC-FE | M8 at publish | ⚠ Mirage enforces **unique item name per restaurant** (`adminController.js:888-897`), so the copy must be renamed ("… (copy)") before it can publish |
| — | | | | |

### A5. Delete / Archive Product

| # | Feature (short) | Side(s) | Mirage endpoint used | Notes / dependencies / risks |
|---|---|---|---|---|
| 19 | Soft-delete / archive | RC-BE, RC-FE | M10 at publish | ReCapture uses the house `deletedAt`/`archivedAt` convention (AGENTS.md §Data layer). Archiving a **published** product must remove it from Mirage — Mirage's own `isDeleted` is never written by any endpoint, so M10 hard-delete is the only lever |
| 20 | Restore an archived product | RC-BE, RC-FE | M8 at publish | Restore + publish **re-creates** the Mirage item, so it gets a **new** Mirage item id. The mapping row must be re-pointed |
| 21 | Permanent delete (with confirmation) | RC-BE, RC-FE | M10 `DELETE /api/v1/delete-item/:itemId` (`adminController.deleteItems`, `adminController.js:1291`) | ⚠ M10 **also hard-deletes the category** when the item was its last member (`adminController.js:1312-1319`). The sync layer must re-create the category before the next item sync |

### A6. Category Management

| # | Feature (short) | Side(s) | Mirage endpoint used | Notes / dependencies / risks |
|---|---|---|---|---|
| 22 | Create custom categories | RC-BE, RC-FE | M5 `POST /api/v1/create-category` (`adminController.createCategory`, `adminController.js:520`) | Mirage lowercases the name and replaces spaces with underscores (`adminController.js:573-574`), so the stored name ≠ the entered name. Display name must be kept ReCapture-side |
| 23a | Rename a category | RC-BE, RC-FE | M6 `PUT /api/v1/update-category/:categoryId` (`adminController.updateCategory`, `adminController.js:647`) | Works |
| 23b | Delete a category | RC-BE, RC-FE + **MIRAGE-API (gap)** | M7 is a **stub** — `deleteCategory` returns the string `"Not created now."` (`adminController.js:1349-1351`) | Workaround: delete/move every item in it (M10), which makes Mirage cascade-delete the category |
| 23c | Reorder categories | RC-BE, RC-FE + MIRAGE-API (gap) | — | No position field on Mirage's category schema; it sorts `createdAt: -1` (`itemController.js:507`) |
| 24 | Assign a product to a category | RC-BE, RC-FE | M8 (`category` body field, **required ObjectId**) | Mandatory, not optional — `createItems` rejects a missing/invalid category (`adminController.js:847-854`). This forces categories into MVP |
| 25 | Move products between categories | RC-BE, RC-FE + **MIRAGE-API (gap)** | — | ⚠ M9 does **not** write `category`. Reassigning on Mirage requires M10 + M8 (delete & recreate), which mints a new Mirage item id |
| 26 | Uncategorized bucket | RC-BE, RC-FE, NEW-INTEGRATION | M5 | ReCapture models it as a nullable `categoryId`; because 24 is mandatory on Mirage, the sync layer materialises a real Mirage category (e.g. `uncategorized`) on first publish |

### A7. Catalog Listing & Search (inside ReCapture)

| # | Feature (short) | Side(s) | Mirage endpoint used | Notes / dependencies / risks |
|---|---|---|---|---|
| 27 | Grid/list of all products | RC-BE, RC-FE | — | Server-truth list with cursor pagination via the existing `utils/cursor.ts`; index it like `Project` does |
| 28 | Filter by category / status / type | RC-BE, RC-FE | — | Compound index required per AGENTS.md §Data layer |
| 29 | Search by name | RC-BE, RC-FE | — | Prefix/substring match scoped to the caller's catalog. Not Mirage's M21 — this is the authoring view |
| 30 | Bulk actions (delete, category change, publish/unpublish) | RC-BE, RC-FE | M8/M9/M10 at publish | ⚠ Mirage has **no batch endpoints** — a bulk action of N products becomes N sequential requests through the sync worker |

---

## B. QR & Public Hosting on Mirage

### B1. Catalog QR

| # | Feature (short) | Side(s) | Mirage endpoint used | Notes / dependencies / risks |
|---|---|---|---|---|
| 31 | One QR for the whole catalog | RC-BE, RC-FE | — | Encodes the public URL issued at provisioning (feature 40) |
| 32 | **QR is stable across republish/rename** | RC-BE | reads M14 `GET /api/v1/get-data-for-new-ui/:restaurantSlug` (`itemController.getDataForNewUi`, `itemController.js:463`) | **Hard constraint.** Satisfied by minting the URL from the immutable Mirage **`_id`**, not the mutable `name` — every public resolver falls back to `findById` (`itemController.js:476-478`). See `03-architecture-proposal.md` §8 |
| 33 | Download QR as PNG / PDF | RC-BE, RC-FE | — | Rendering server-side keeps one implementation and makes PDF trivial; the client only downloads and shares |
| 34 | View the public link | RC-FE | — | Read the frozen `publicUrl` from the catalog record — never recompute it |
| 35 | Copy / share the link | RC-FE | — | `share_plus` ^13.2.0 is already a dependency |

### B2. Publishing to Mirage

| # | Feature (short) | Side(s) | Mirage endpoint used | Notes / dependencies / risks |
|---|---|---|---|---|
| 36 | "Publish" pushes the catalog to Mirage | RC-BE, NEW-INTEGRATION, RC-FE | M2/M5/M6/M8/M9/M10 | Enqueues one `MIRAGE_CATALOG_PUBLISH` job on the existing worker (`worker/processorRegistry.ts`). Explicit user action, never auto-sync |
| 37 | Last-published timestamp | RC-BE, RC-FE | — | `lastPublishedAt` on the catalog, written only when a publish run fully succeeds |
| 38 | "Draft changes not yet live" indicator | RC-BE, RC-FE | — | Derived from `draftRevision > publishedRevision`, not from a user-set flag |
| 39 | Unpublish catalog | RC-BE, NEW-INTEGRATION, RC-FE | M10 per item, then M4 `DELETE /api/v1/delete-restaurant/:restaurantId` (`adminController.deleteRestaurant`, `adminController.js:1245`) — **or neither** | ⚠ Mirage has **no hide/offline flag**. M4 is a hard cascade delete that also destroys the restaurant `_id`, which would **break the stable QR (feature 32)**. Recommended: delete items only, keep the restaurant. Raised as Q-blocking in `06-open-questions.md` |

---

## C. Integration with Mirage

### C1. Client Provisioning

| # | Feature (short) | Side(s) | Mirage endpoint used | Notes / dependencies / risks |
|---|---|---|---|---|
| 40 | Provision client on first publish | NEW-INTEGRATION | M2 `POST /api/v1/create-restaurant` (`adminController.createRestaurant`, `adminController.js:183`) | ⚠ Name collision is a **fuzzy regex** check (`adminController.js:213-215`) — a business named "Cafe" is rejected if any restaurant name contains "cafe". Needs a disambiguation strategy |
| 41 | Store ReCapture user ↔ Mirage client id | RC-BE | — | Persisted on the `Catalog` document, never re-derived per call (task constraint §7) |
| 42 | Sync client branding to Mirage | NEW-INTEGRATION | M3 `PUT /api/v1/update-restaurant/:restaurantId` (`adminController.updateRestaurant`, `adminController.js:282`) | Only `name`, `location`, `phone`, `icon`, `description` land. ⚠ M3 400s unless **both** `name` and `location` are strings — it is not a partial update. **Website/social links/address have no Mirage field** → `MIRAGE-API (gap)` |

### C2. Product Sync

| # | Feature (short) | Side(s) | Mirage endpoint used | Notes / dependencies / risks |
|---|---|---|---|---|
| 43 | Product maps 1:1 to a Mirage entry | RC-BE, NEW-INTEGRATION | — | `mirageItemId` on the product document is the mapping. Also the idempotency substitute, since Mirage offers none |
| 44 | Create → Mirage create | NEW-INTEGRATION | M8 `POST /api/v1/create-item` (`adminController.js:783`) | Retry of a create returns `400 "Product already exist"`; the worker must reconcile via M12 `GET /get-all-items-for-cat/:categoryId` to recover the id |
| 45 | Edit → Mirage update | NEW-INTEGRATION | M9 `PUT /api/v1/update-item/:itemId` (`adminController.js:1021`) | Partial coverage only — see 8a/14/17/25 |
| 46 | Delete → Mirage delete/archive | NEW-INTEGRATION | M10 `DELETE /api/v1/delete-item/:itemId` (`adminController.js:1291`) | Hard delete only; watch the last-item category cascade |
| 47 | Category change reflected in Mirage | NEW-INTEGRATION | M5, M6, and M10+M8 for reassignment | Reassignment is the gap (see 25) |
| 48 | Product sort position synced | NEW-INTEGRATION + **MIRAGE-API (gap)** | — | **No sort field exists on Mirage's item schema**; the public page orders by `createdAt: -1` (`itemController.js:543`). Only achievable today by controlling creation order, which republish cannot preserve without deleting and re-creating everything |

### C3. Asset Sync

| # | Feature (short) | Side(s) | Mirage endpoint used | Notes / dependencies / risks |
|---|---|---|---|---|
| 49a | GLB uploaded in Mirage's expected format | NEW-INTEGRATION | M8/M9 (`object` multipart field) | ⚠ Mirage takes **bytes only** — no URL passthrough (`adminController.js:948-955`). The worker must stream the GLB from ReCapture CloudFront and re-POST it, producing a **second copy** on `maya-restaurants`. 100 MB multer cap |
| 49b | USDZ referenced correctly | **MIRAGE-API (gap)** | — | `item.model.iosSrc` exists in the schema but **multer accepts no third file field and no controller ever writes it**. iOS AR Quick Look cannot be served for a ReCapture-published product |
| 50 | Product images uploaded and linked | NEW-INTEGRATION | M8/M9 (`image` multipart field) | Same byte-transfer path |
| 51 | Thumbnails synced (3D products) | NEW-INTEGRATION | M8/M9 (`image` field) | Mirage has one image slot per item, so the 3D product's generated `previewUrl` occupies it |

### C4. Sync State & Reliability

| # | Feature (short) | Side(s) | Mirage endpoint used | Notes / dependencies / risks |
|---|---|---|---|---|
| 52 | Per-product sync status (Synced/Pending/Failed) | RC-BE, RC-FE | — | `syncStatus` + `syncError` on the product document; server-truth so a second device agrees (edge case §8) |
| 53 | Manual retry of failed syncs | RC-BE, NEW-INTEGRATION, RC-FE | M8/M9/M10 | Re-enqueues a scoped publish job for the failed subset only |
| 54 | Auto-retry on transient failures | NEW-INTEGRATION | — | Reuses the existing worker backoff (1→2→4 min, capped 30 min, `worker/jobQueue.ts:19-20`). Needs a Mirage-specific retryable/terminal classifier because Mirage returns 400 for everything |
| 55 | Sync / activity log | RC-BE, RC-FE | — | New capped-growth collection. Marked optional-MVP in the brief; bucketed V2 |

### C5. Consistency Rules

| # | Feature (short) | Side(s) | Mirage endpoint used | Notes / dependencies / risks |
|---|---|---|---|---|
| 56 | Publish is the single source of truth for customers | CROSS | — | Enforced by construction: **only** the publish worker holds Mirage credentials and writes to Mirage |
| 57 | Draft changes don't affect live until published | RC-BE | — | Product edits bump `draftRevision`; the worker publishes from a snapshot, never from live draft rows |

---

## D. Business Profile

| # | Feature (short) | Side(s) | Mirage endpoint used | Notes / dependencies / risks |
|---|---|---|---|---|
| 58 | Business profile fields available | RC-BE, RC-FE | — | New fields. `User` today has only `displayName`/`avatarKey` (`models/User.ts:24-57`). **Website, social links, and a structured address have no Mirage home** |
| 59 | Profile drives public catalog branding | NEW-INTEGRATION | M3 `PUT /api/v1/update-restaurant/:restaurantId` (`adminController.js:282`) | Only name/location/phone/icon/description are carried. `ClientConfig` is **not** the place for this — it is one global capture-tuning doc (`models/ClientConfig.ts`) |
| 60 | Edit business profile | RC-BE, RC-FE | M3 at publish | Editing marks the catalog dirty (feature 38) |

---

## E. Analytics (Baseline)

All five collection features are **already emitted today** by the public Mirage catalog page into
`analyticsEventModel` — no new instrumentation is needed on either side for 61–65.

| # | Feature (short) | Side(s) | Mirage endpoint used | Notes / dependencies / risks |
|---|---|---|---|---|
| 61 | Track catalog views (QR scan → open) | MIRAGE-API | M26 `POST /api/v1/analytics/collect` → read via M27 `GET /api/v1/analytics/summary` | Existing event types `client_page_view` + `session_start` (`analyticsEventModel.js` `EVENT_TYPES`) |
| 62 | Track product views | MIRAGE-API | M27 / M29 `GET /api/v1/analytics/top-products` (`analyticsController.getTopProducts`, `analyticsController.js:459`) | Existing `product_page_view`, `product_detail_opened` |
| 63 | Track 3D model loads | MIRAGE-API | M27 (`analyticsController.getSummary`, `analyticsController.js:163`) | Existing `model_loaded` (+ `model_load_failed`) |
| 64 | Track AR mode launches | MIRAGE-API | M27 | Existing `ar_session_started` (+ `ar_view_clicked`) |
| 65 | Track image-only product views | MIRAGE-API, NEW-INTEGRATION | M29 | Mirage does not tag events by product type; ReCapture partitions `top-products` rows by joining `props.productId` → its own `mirageItemId` → `type` field. No Mirage change needed |
| 66 | Dashboard inside ReCapture | NEW-INTEGRATION, RC-BE, RC-FE | M27, M28 `GET /api/v1/analytics/timeseries` (`analyticsController.getTimeseries`, `analyticsController.js:382`), M29 — all with `?restaurant=<mirageRestaurantId>` | ⚠ These three are **admin-scoped** and, per the in-code note at `analyticsRoutes.js:20-24`, must not be opened to client scope. ReCapture's backend proxies them with its admin credential and **forces** the `restaurant` param to the caller's mapped id — never accepting it from the client |

---

## F. Notifications & Feedback

| # | Feature (short) | Side(s) | Mirage endpoint used | Notes / dependencies / risks |
|---|---|---|---|---|
| 67 | Toast/inline confirmation on add/edit/delete/publish | RC-FE | — | Existing `SnackBarThemeData` in `lib/app/theme/app_theme.dart:279` |
| 68 | Actionable error state on sync failure | RC-FE, RC-BE | — | Requires the backend to map Mirage's prose 400s onto stable `UPPER_SNAKE` codes in the house envelope; the client must never surface a raw Mirage message |
| 69 | Success state "Live on Mirage" with link + QR | RC-FE | — | Reads the frozen `publicUrl` (feature 34) |

---

## Coverage & Gap Summary

All 69 features are assigned. Distribution (a feature counts once per side it touches):

| Side | Features |
|---|---|
| RC-FE | 1–2, 4–29, 30, 31, 33–35, 36–39, 52, 53, 55, 58, 60, 66, 67–69 |
| RC-BE | 1–4, 6–11, 13–16, 18–24, 26–33, 36–38, 41, 43, 52, 53, 55, 57, 58, 60, 66, 68 |
| NEW-INTEGRATION | 15, 16, 26, 36, 39, 40, 42, 43–51, 53, 54, 59, 65, 66 |
| MIRAGE-API | 7, 8a, 14, 15, 16, 18–26, 30, 32, 36, 39, 40, 42, 44–47, 49a, 50, 51, 53, 61–66 |
| CROSS | 17, 30, 56 |

**Features carrying a `MIRAGE-API (gap)` marker** — every one is written up in
`06-open-questions.md` §C with a workaround and a suggested endpoint change:

8b (tags), 8c (availability), 9 (featured), 10 & 48 (sort order), 17 (`imgOnly` cannot be unset),
23b (`delete-category` is a stub), 23c (category order), 25 (item category reassignment),
39 (no unpublish/hide), 42 (no website/social/address fields), 49b (no USDZ field),
plus the cross-cutting 49a (no URL passthrough — bytes only) and 30 (no batch writes).
