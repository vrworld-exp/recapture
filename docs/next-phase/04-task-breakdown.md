# 04 — Task Breakdown

Concrete engineering tasks derived from `03-architecture-proposal.md`. Each is one focused session,
independently reviewable, with a stated "done".

**Sides:** `RC-FE` Flutter client · `RC-BE` ReCapture backend · `NEW-INTEGRATION` the Mirage
adapter/sync layer inside the backend · `CROSS` spans sides.
**Sizes:** `S` ≈ ½ day · `M` ≈ 1 day · `L` ≈ 2 days.

Bucketing (MVP / V1.1 / V2) is in `05-mvp-v1.1-v2-bucketing.md`; every task below appears there
exactly once.

> **Status — 2026-08-26: all 42 tasks are implemented.** They shipped through the prompt pack
> (`prompts/`: B1–B7 backend, F1–F12 Flutter, M1–M5 Mirage) rather than one task per session, so
> the checkboxes across these next-phase docs were never ticked — **they are not a progress
> signal.** `prompts/README.md` is the current state of the phase, including the three things
> still open: no `live` verification run on any M-prompt, M5's on-device iOS AR Quick Look check,
> and the M1–M5 port-back into `mirage-be`.

---

## Phase 1 — Foundations

| ID | Title | Side | Features | Depends on | Size | Done when |
|---|---|---|---|---|---|---|
| T-001 | `Catalog`, `CatalogProduct`, `CatalogCategory`, `CatalogPublishRun` Mongoose models + indexes | RC-BE | 1, 3, 4, 8, 19, 22, 26, 43, 52 | — | M | All four schemas exist with the §6 fields and every listed compound index; `tsc --noEmit` clean; a test proves the `{userId:1}` unique index rejects a second catalog under concurrent create |
| T-002 | Business profile fields on `Catalog` + `GET`/`PATCH /catalog/profile` | RC-BE | 58, 60 | T-001 | S | Profile reads and writes round-trip through the house envelope with Zod validation; `User` is untouched |
| T-003 | `MIRAGE_*` config in `config/env.ts` + `.env.example` | NEW-INTEGRATION | 40 | — | S | All §5 vars validated by Zod with safe defaults for tunables and no defaults for secrets; the API boots with them absent only if they are optional; both files changed in the same commit |
| T-004 | Mirage HTTP adapter (`services/mirage/mirageClient.ts`) — headers, envelope unwrap, error classification, timeouts | NEW-INTEGRATION | 44–47 | T-003 | M | Every M-endpoint used in §5 has a typed method; the (status, message) → retryable/reconcile/auth/terminal table is table-driven and covered by fixtures quoting real Mirage messages; `CLOUD_FRONT_URL`/`BUCKET_NAME` are injected on every write |
| T-005 | Flutter catalog domain entities + repositories + Dio wiring | RC-FE | 1–4, 7, 52 | T-001 | M | All §4 entities parse field-by-field (never a spread) with golden-JSON tests; repositories ride the existing `dioProvider` |
| T-006 | Catalog tab shell + `go_router` routes | RC-FE | 1, 4 | T-005 | S | All 10 new routes registered in `AppRoutes`/`AppRouteNames`; the tab is reachable from Projects; empty state renders |

## Phase 2 — Product management

| ID | Title | Side | Features | Depends on | Size | Done when |
|---|---|---|---|---|---|---|
| T-007 | `GET`/`POST`/`PATCH /catalog` + logo/cover presign & commit | RC-BE | 1, 2, 3, 4 | T-001 | M | Create is idempotent (returns the existing catalog); every write bumps `draftRevision`; a second user's catalog is an identical 404 |
| T-008 | Category CRUD + reorder endpoints | RC-BE | 22, 23, 24, 25, 26 | T-001 | M | Create/rename/delete/reorder work; delete refuses while products reference it unless `?reassignTo=`; uncategorized is a null `categoryId` |
| T-009 | Product create — 3D from an existing model, and image-only | RC-BE | 6, 7, 8, 11, 24 | T-001, T-008 | L | A 3D product can only reference a `SUCCEEDED` `ProjectModel` owned by the caller and copies `cdnUrls.glb/usdz/preview`; an image-only product requires a committed image key; all §6 fields validate |
| T-010 | Product image key space + presign/commit (clone of the avatar 3-step) | RC-BE | 13, 16 | T-001 | M | `productImageKeys.ts` builds and strictly parses the §6 scheme; a key owned by another catalog is a **403**; oversize is rejected at commit; traversal is impossible; mirrors `tests/avatar-keys.test.ts` |
| T-011 | Product edit — fields, replace model, replace image, convert type | RC-BE | 14, 15, 16, 17 | T-009, T-010 | M | Every field patchable; model/image replacement swaps asset refs and retains the old key until the next successful publish; a type conversion is recorded so the planner can emit DELETE+CREATE |
| T-012 | Archive / restore / permanent delete | RC-BE | 19, 20, 21 | T-009 | M | Archive sets `archivedAt`, restore clears it, hard delete sets `deletedAt` and sweeps owned S3 objects; a published product's `mirageItemId` survives archive so the planner can delete it on Mirage |
| T-013 | Duplicate a product | RC-BE | 18 | T-009 | S | Copy carries every field except identity/mapping/sync state, is auto-renamed to avoid Mirage's per-restaurant name collision, and starts `syncStatus: NEVER` |
| T-014 | Featured flag + position reorder endpoint | RC-BE | 9, 10 | T-009 | S | Toggling featured and writing a full position array are both single round trips; ordering is deterministic under equal positions via the `_id` tie-break |
| T-015 | Product list — filter, search, cursor pagination | RC-BE | 27, 28, 29 | T-009 | M | Filter by category/status/type and search by name are all index-backed (no collection scan in `explain`); pagination reuses `utils/cursor.ts` and is deterministic |
| T-016 | Bulk actions endpoint | RC-BE | 30 | T-012, T-014 | M | Bulk delete / recategorise / include-exclude apply atomically per item with a per-item result array; partial failure is reported, not swallowed |
| T-017 | Flutter product grid + filters + search | RC-FE | 27, 28, 29 | T-005, T-015 | L | 2-col phone / 4-col tablet grid, filter chips, debounced search, infinite scroll, empty and error states |
| T-018 | Flutter add-product flow (existing model · fresh scan · image) | RC-FE | 6, 7, 11, 12, 13 | T-006, T-009, T-010 | L | All three sources produce a product; the fresh-scan path deep-links into the **unmodified** capture flow and returns with a `modelId`; image upload runs presign → PUT → commit with progress |
| T-019 | Flutter product editor — edit, replace, convert, duplicate | RC-FE | 14, 15, 16, 17, 18 | T-018, T-011, T-013 | L | Every field editable; replace-model and replace-image flows work; conversion warns that the product will get a new public link |
| T-020 | Flutter archive / restore / delete UI | RC-FE | 19, 20, 21 | T-017, T-012 | M | Archive is one tap with undo; an Archived filter lists and restores; permanent delete requires typed confirmation |
| T-021 | Flutter category manager with drag reorder | RC-FE | 22, 23, 24, 25, 26 | T-017, T-008, T-014 | L | Create/rename/delete/reorder categories, assign and move products, uncategorized bucket always present; reorder persists optimistically with rollback |
| T-022 | Flutter bulk-selection mode | RC-FE | 30 | T-017, T-016 | M | Long-press enters selection; bulk delete/recategorise run with a per-item result summary |
| T-023 | Flutter business profile screen | RC-FE | 58, 59, 60 | T-006, T-002 | M | All profile fields editable with validation; fields that cannot reach the public page are visibly marked as ReCapture-only |

## Phase 3 — Catalog & QR

| ID | Title | Side | Features | Depends on | Size | Done when |
|---|---|---|---|---|---|---|
| T-024 | Mirage client provisioning + mapping + public-URL minting and freezing | NEW-INTEGRATION | 40, 41, 42, 59 | T-004, T-007 | L | First publish adopts an existing Mirage restaurant by exact name or creates one via M2; `mirageRestaurantId` and `publicUrl` are persisted once and **never** rewritten; branding syncs via M3 with both `name` and `location` always sent; a name collision surfaces `CATALOG_NAME_TAKEN` with a suggestion |
| T-025 | QR generation, PNG/PDF download, link copy and share | CROSS | 31, 32, 33, 34, 35 | T-024 | M | `GET /catalog/qr?format=png\|pdf` renders from the stored `publicUrl` only; the PNG is byte-identical across calls; the client can view, copy and share the link. **A test asserts the URL is unchanged after rename, republish and product churn** |
| T-026 | Flutter catalog preview | RC-FE | 5 | T-017 | M | Preview renders the draft in the public page's shape; 3D products load in `model_viewer_plus`; the **meshopt decoder trigger is set in both `web/index.html` and `_lifecycleJs`** and `meshopt_decoder_test.dart` is extended to cover it |

## Phase 4 — Publish & sync

| ID | Title | Side | Features | Depends on | Size | Done when |
|---|---|---|---|---|---|---|
| T-027 | `MIRAGE_CATALOG_PUBLISH` job type + processor skeleton + planner | NEW-INTEGRATION | 36, 52, 54 | T-004, T-024 | L | The type is registered via `registerProcessor` with no change to the polling loop; the planner derives CREATE/UPDATE/SKIP/DELETE from `publishedSnapshot`; retry/backoff and stale-lease re-claim are exercised by tests |
| T-028 | Category sync (create, rename, cascade repair) | NEW-INTEGRATION | 47, 26 | T-027, T-008 | M | Missing categories are created via M5 before any item sync; renames go through M6; the "Uncategorized" bucket is materialised on demand; **`mirageCategoryId` is cleared when M10 removes a category's last item** |
| T-029 | Product sync — create/update/delete with mapping and reconciliation | NEW-INTEGRATION | 43, 44, 45, 46 | T-027, T-028 | L | `mirageItemId` is persisted immediately after M8; a replayed create reconciles via M12 instead of duplicating; **publishing the same product twice produces exactly one Mirage item** (the brief's non-negotiable), proven by a crash-replay test |
| T-030 | Asset sync — preflight and byte streaming to Mirage | NEW-INTEGRATION | 49, 50, 51 | T-029 | L | GLB/image/thumbnail stream from `BUCKET_ARTIFACTS` into multipart M8/M9; HEAD preflight rejects missing/oversize assets as terminal before any Mirage call; unchanged assets are not re-uploaded; the USDZ gap is logged once per run, not per product |
| T-031 | Publish endpoint + draft/published state machine + validation gates | RC-BE | 36, 37, 38, 56, 57 | T-027 | L | `POST /catalog/publish` returns `202 {runId}`; a concurrent second call gets `409`; all §7.7 gates run before any Mirage call (empty catalog is blocked); `publishedRevision`/`lastPublishedAt` advance only on a fully successful run |
| T-032 | Unpublish | RC-BE, NEW-INTEGRATION | 39 | T-029, T-031 | M | Unpublish removes items via M10 and **keeps the restaurant, URL and QR**; state flips to `UNPUBLISHED`; republish restores under the same URL; permanent catalog deletion is a separate explicitly-confirmed action |
| T-033 | Per-product sync status + manual retry endpoint | CROSS | 52, 53 | T-029 | M | `GET /catalog/publish/status` returns per-product state and counts; `POST /catalog/publish/retry` re-enqueues only `syncStatus: FAILED` products; state is server-truth and identical on a second device |
| T-034 | Flutter publish screen — status, last published, draft badge, partial failure, success | RC-FE | 36, 37, 38, 39, 52, 53, 68, 69 | T-006, T-031, T-033 | L | Publish with live progress polling; "Draft changes not yet live" derived from revisions; a partial run shows "N of M published" with a working Retry failed; success shows "Live on Mirage" with the link and QR; **no raw Mirage message is ever displayed** |
| T-035 | Product order sync | NEW-INTEGRATION | 48 | T-029 | S | Position is honoured wherever Mirage allows it (creation order on first publish); the UI states plainly that public order is by creation date; the gap is documented in-code with a citation |
| T-036 | Sync / activity log | RC-BE | 55 | T-029 | M | `GET /catalog/activity` pages the run entries with target, action, outcome and a stable error code; growth is bounded |

## Phase 5 — Analytics

| ID | Title | Side | Features | Depends on | Size | Done when |
|---|---|---|---|---|---|---|
| T-037 | Analytics proxy service (summary, timeseries, top-products) | NEW-INTEGRATION | 61, 62, 63, 64, 65, 66 | T-004, T-024 | M | The three endpoints proxy M27/M28/M29 with `?restaurant=` **forced** from the mapping; a client-supplied `restaurant` param is ignored (asserted by test); top-products rows are partitioned into 3D vs image-only via `mirageItemId`; an unprovisioned catalog returns empty, never an unscoped read |
| T-038 | Flutter analytics dashboard | RC-FE | 66 | T-006, T-037 | L | Catalog views, unique visitors, top viewed products, AR launches and the 3D/image-only split render with a date-range control, plus loading, empty and error states |
| T-039 | ReCapture-side authoring analytics events | CROSS | (supports 61–66) | T-031 | S | Every event in §10b is emitted through the single existing seam per side with non-PII props only; a test asserts no phone, email, address or product name appears in any props |

## Phase 6 — Polish

| ID | Title | Side | Features | Depends on | Size | Done when |
|---|---|---|---|---|---|---|
| T-040 | Toasts and inline confirmations | RC-FE | 67 | T-018 | S | Add/edit/delete/publish all confirm through the existing `SnackBarThemeData`; destructive actions offer undo where reversible |
| T-041 | Error and success states with actionable messages | RC-FE | 68, 69 | T-034 | M | Every backend error code maps to a specific message and a next action; sync failures name the product and offer retry or edit; success shows the link and QR |
| T-042 | Test hardening — Mirage fakes, contract tests, QR-stability suite | CROSS | 32, 44–46, 54 | T-030, T-031 | L | The full §13 backend and client checklists pass; CI never calls live Mirage; the crash-replay idempotency test and the QR-stability test are both green |

---

## Summary

**42 tasks.** By side: RC-BE 15 · RC-FE 12 · NEW-INTEGRATION 9 · CROSS 6.
By size: S 8 (~4 d) · M 18 (~18 d) · L 16 (~32 d) → **~54 engineering days** before review and QA.

Critical path (longest dependency chain to a working end-to-end publish):

```
T-001 → T-009 → T-029 → T-030 → T-031 → T-034
  ↑       ↑        ↑
T-003 → T-004 → T-024 → T-027
```

Every feature 1–69 is covered; see `02-feature-to-side-mapping.md` for the per-feature view.
