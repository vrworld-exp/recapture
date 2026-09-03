# 07 — Same-Day Restaurant Activation

Architecture plan for collapsing restaurant onboarding into a single on-site visit: the rep closes
the deal, photographs the dishes, and activates a pre-printed QR standee before leaving the building.

> **Implementation pack:** [`../same-day-activation/`](../same-day-activation/) breaks this plan
> into seven staged, independently-shippable steps with per-stage tests, done-when checklists and
> rollback notes. **Start with
> [`00-preflight-and-corrections.md`](../same-day-activation/00-preflight-and-corrections.md)** —
> five statements in this document are stale or wrong when checked against the working tree, one of
> them a correctness hazard (`FULL` + `productIds` would corrupt `publishedRevision`). The stages
> already incorporate the corrections; this document is left as written for the record.

Every convention here defers to `ReCapture/AGENTS.md`. Where this document adds something new, it
says so explicitly and gives the reason. Written as a plan, not a task breakdown — see
`04-task-breakdown.md` for the format that work items take once this is agreed.

---

## Context

Onboarding a restaurant onto Mirage Menu today is a multi-day relay: sales closes → photographer
shoots dishes → backend assigns a QR → ops prints and delivers a standee. We are collapsing that
into a single on-site visit, with the 2D menu live on activation and AR arriving per dish as each
model finishes generating.

**The originating brief assumed this was greenfield. It is not.** Roughly 70% of Part 2 and a
conflicting 100% of Part 1 already exist on `feature/recap-phase-2`. This plan is therefore mostly
*extension and correction*, not new construction. What is genuinely new: the QR code inventory, the
public resolver, the sales-rep role, and delegated (act-on-behalf-of) tenancy.

### What already exists — do not rebuild

| Brief says "build" | Reality |
|---|---|
| Camera overlay, 2–4 angles per dish | `CaptureMode.meshy` — one EYE ring of **6**, shutter-only, hard tilt gate, server picks best 4. `lib/domain/capture/capture_mode.dart` |
| Submit to Meshy Multi-Image-to-3D | `src/worker/engine/meshy/meshyClient.ts` + `meshyModelProcessor.ts`. Submit → poll → re-host to CloudFront |
| Webhook on completion | **Polling, by documented decision** (`docs/meshy-integration.md` §7). `meshyTaskId` is persisted the instant it exists so a re-claim resumes rather than resubmits. No webhook needed or wanted |
| Per-dish pending/ready/failed | `ProjectModel.status` = `QUEUED\|PROCESSING\|SUCCEEDED\|FAILED` + `progress{phase,percent}` |
| Menu data model | `Catalog → CatalogCategory → CatalogProduct`, published to Mirage by the `MIRAGE_CATALOG_PUBLISH` worker job |
| QR generation | `src/services/catalogQrService.ts` — deterministic PNG/PDF, `GET /catalog/qr` |

### The three conflicts this plan resolves

1. **The QR is backwards.** `Catalog.publicUrl` is minted as
   `{MIRAGE_PUBLIC_BASE_URL}/{mirageRestaurantId}` *after* signup and frozen forever
   (`assertMappingImmutable` throws on rewrite — see §8 of `03-architecture-proposal.md`). The brief
   needs a meaningless code printed *before* signup, remappable at will.
2. **Everything is one-tenant-per-user.** `Catalog` has a unique index on `userId`; `Project` and
   `CatalogProduct` are `userId`-scoped. A rep activating many restaurants breaks this.
3. **A product cannot link an unfinished model.** `resolveOwnedModel` returns `MODEL_NOT_READY`
   unless `status === 'SUCCEEDED'`, and asset URLs are *copied* at link time and never repointed.

---

## Decisions taken

Confirmed with the product owner before this plan was written.

| # | Decision |
|---|---|
| D1 | Public resolver lives in `recapture-api` as a new unauthenticated `/r/:code` route group |
| D2 | Restaurant owns its own account; the rep acts through a `CatalogDelegation` grant |
| D3 | `SALES_REP` joins the linear role ladder at rank 1 |
| D4 | A product may link a pending model; the Meshy processor promotes assets and triggers a targeted re-publish |

---

## Part 1 — Pre-generated QR + on-site mapping

### The key insight that preserves the frozen-URL invariant

**`publicUrl` never becomes remappable. The `QrCode` does.**

A pre-printed standee encodes `{PUBLIC_RESOLVER_BASE_URL}/r/{code}`. At activation, that exact
string is written to `catalog.publicUrl` — once, never recomputed. `assertMappingImmutable` stays
untouched, and `catalogQrService` needs **zero changes**: it still reads `publicUrl` verbatim, so
`GET /catalog/qr` renders a code byte-identical to the one on the standee.

Remapping happens on the `QrCode` row, one level below the catalog. `QrCode.catalogId` is
many-to-one, so replacing a lost standee means activating a *second* code onto the same catalog and
retiring the first — `publicUrl` does not move, and the old code's scan history stays intact. This
satisfies feature 32 rather than working around it.

### New collections (`recapture-api/src/models/`)

**`QrCode.ts`** — the printed inventory item.
`code` (unique, uppercase) · `batchId` · `state` `UNASSIGNED|ACTIVE|RETIRED` · `catalogId?` ·
`activatedAt?` · `activatedByUserId?` · `deletedAt`.
Indexes: unique `{code}`, `{catalogId, state}`, `{batchId, state}`.

Codes are Crockford base32 minus ambiguous glyphs, 8 chars from `crypto.randomBytes`, resolved
case-insensitively. Meaningless and permanent — never derived from anything.

**`QrCodeAssignment.ts`** — the mapping *history*, which is what makes reassignment non-destructive.
`qrCodeId` · `catalogId` · `assignedAt` · `unassignedAt?` · `assignedByUserId`.
`QrCode.catalogId` is the current pointer; these rows are the ledger.

**`QrScanDaily.ts`** — one doc per code per day, `$inc` upsert.
`qrCodeId` · `assignmentId` · `day` · `count`. Keyed by `assignmentId` so scans stay attributed to
the mapping that was live when they happened. A rollup rather than per-scan rows because scan volume
is unbounded and the resolver must stay fast; consistent with the no-Redis, DB-backed house pattern
(AGENTS.md §Data layer).

### The public resolver — `recapture-api/src/routes/public.ts`

Mounted `app.use('/r', publicRouter)` in `src/app.ts` alongside the existing mounts. This is the
**first customer-facing surface in this API** — `/catalog`, `/projects` and `/jobs` all mount
`requireAuth` at the router level, and only `/health` and `/remote-config` are open today.

`GET /r/:code`:

| Code state | Response |
|---|---|
| `ACTIVE` | record scan, `302` → `catalog.publicUrl` (the Mirage menu) |
| `UNASSIGNED` | `200` HTML — "this menu isn't live yet" demo/fallback page |
| `RETIRED` | `200` HTML — "this code has been replaced" |
| unknown | `200` HTML fallback, **not** a 404 JSON body |

**Envelope carve-out, to be documented in AGENTS.md.** Every other route returns the JSON envelope,
but the client here is a phone camera opening a browser. The public router needs its own terminal
error handling so a crash renders the fallback page rather than falling through to
`errorHandler.ts`, which emits `{error, code}` JSON. A dead link is the one outcome the brief
forbids, so the fallback must be reachable even on an internal error.

### Extending the URL scheme

`PUBLIC_URL_SCHEMES` in `src/models/types/catalog.types.ts:42` is a deliberate one-member enum —
the documented grandfathering seam. Add `'RECAPTURE_SHORT_CODE'` beside `'MIRAGE_OBJECT_ID'`.
Existing catalogs keep their old scheme and their printed codes keep working.

One targeted change in `src/services/catalogProvisioningService.ts` (~line 264): `mintPublicUrl`'s
conditional write must set `publicUrl`/`publicUrlScheme` **only when absent**. A rep-activated
catalog already has one, written at activation before Mirage has ever heard of the restaurant.
`mirageRestaurantId`/`mirageProvisionedAt` continue to be written as they are today.

### Batch minting — `/admin` (ADMIN only)

- `POST /admin/qr-batches` `{count, label}` → mints N `UNASSIGNED` codes.
- `GET /admin/qr-batches/:id/export` → CSV of `code, url` for the print vendor.

Gate behind `requireRole('ADMIN')` inline, matching the existing destructive-route pattern in
`src/routes/admin.ts`. Note this partially answers Q12 in `06-open-questions.md` (print-ready sheet
vs single code): the vendor gets a CSV and prints at scale, so no sticker-sheet renderer is needed.

---

## Part 2 — Rep-captured photos → live AR

### Reused unchanged

`CaptureMode.meshy` → `POST /jobs` → finalize → `captureProcessingProcessor` →
`maybeAutoGenerateModel` → `autoPhotoSelectionService` → `MESHY_MODEL_GENERATION` job →
`meshyModelProcessor` (submit → poll → re-host) → `ProjectModel.artifacts.cdnUrls`.

Note: the existing meshy capture is 6 photos with server-side best-4 selection, versus the brief's
"2–4 angles". Building to 6 and letting the selector decline is the better shape and is already
tested (`tests/auto-photo-selection.test.ts`, `test/capture/meshy_*_test.dart`).

**This flow is dark today.** `AUTO_MODEL_GENERATION_ENABLED` defaults `false` and the live
`autoModelGenerationEnabled` remote flag reads **fail-closed**. Both must be switched on for
hands-off rep activation — that is a real-spend decision, flagged below.

### The gap — per-dish `generating → ready`

**1. Relax the link check.** `resolveOwnedModel` (`src/services/catalogProductsService.ts:366-399`)
currently rejects anything not `SUCCEEDED`. Add an `OK_PENDING` outcome returning `projectId` and
`modelId` with no assets.

**2. Add `modelStatus` to `CatalogProduct`** (`src/models/CatalogProduct.ts`):
`NONE | QUEUED | PROCESSING | READY | FAILED`. It mirrors `ProjectModel.status` onto the row the
menu actually renders. `type` stays authored intent; `modelStatus` gates AR.

**3. Promote on success.** Add a best-effort final step to `meshyModelProcessor` after
`rehostArtifacts`, mirroring how `captureProcessingProcessor` calls `maybeAutoGenerateModel` as its
last non-fatal step. New `src/services/catalogModelPromotionService.ts`:

- find `CatalogProduct` rows where `sourceModelId == modelId`
- copy `artifacts.cdnUrls` → `assets.{glbUrl,usdzUrl,thumbnailUrl}` (copied, not resolved — keeps
  the existing "a later regeneration cannot silently change a published product" rule)
- set `modelStatus: 'READY'`, `syncStatus: 'PENDING'`, bump `catalog.draftRevision`
- enqueue a product-scoped publish

**4. Targeted re-publish is already supported.** `Job.payload` for `MIRAGE_CATALOG_PUBLISH` already
carries `{catalogId, publishRunId, mode, productIds?}`, and `CatalogPublishRun.mode` already has a
non-`FULL` member. Reuse the `productIds`-scoped path rather than inventing a second mechanism.

**⚠ Publish-lock contention is the real hazard here.** `activePublishRunId` is a conditional
`findOneAndUpdate` that makes a second simultaneous publish a clean 409. Six dishes finishing within
seconds of each other will collide. Design the promotion to be **lock-tolerant**: always write the
product fields and `syncStatus: 'PENDING'` first, then *attempt* to enqueue; on contention, leave
the rows PENDING and let a single follow-up run sweep them. Never let a lost lock race drop a
promotion — the fields are the source of truth, the enqueue is an optimization.

**5. Client.** `lib/application/catalog/catalog_products_notifier.dart` polls while any product is
pending, reusing the exact cadence already proven in
`lib/application/projects/model_generation_notifier.dart` (3s → 10s backoff, `_maxPolls = 120`,
`ref.onDispose` teardown, last-good-state on transient failure). `product_card.dart` gains a
"3D generating…" → "AR ready" badge.

---

## Tenancy and roles

### Delegation (D2)

At activation the rep enters the restaurant's phone. The backend resolve-or-creates a `User` on it —
the same operation `verifyOtpService` performs today (first OTP verify *is* signup), minus the OTP,
since the rep is present and vouching. `phoneVerified: false`.

The `Catalog` belongs to that user, so the unique index on `Catalog.userId` and every `userId`-scoped
query survive untouched. When the owner later signs in with that phone through the normal OTP flow,
they simply *are* the owner — no migration, no claim step.

**New `CatalogDelegation.ts`**: `repUserId` · `catalogId` · `grantedAt` · `revokedAt?`.
Index `{repUserId, catalogId}` unique among live rows, plus `{catalogId, revokedAt}`.

**Projects the rep captures are owned by the restaurant** (`Project.userId = restaurantUserId`,
`createdByUserId = rep` for audit). This matters: `resolveOwnedModel` proves model ownership through
`Project.userId` matching the catalog owner. Keeping projects under the restaurant means that check
needs no weakening — which is exactly the security boundary we don't want to soften.

**Rep routes mirror owner routes rather than modifying them.** New `src/routes/rep.ts`, mounted
`/rep` with `requireAuth` + `requireRole('SALES_REP')`, using one shared
`resolveDelegatedCatalog(repUserId, catalogId)` helper. The existing `/catalog` and `/projects`
routers stay exactly as they are — no second, weaker door into owner data, consistent with the
existing rule that `/projects/:id/models` must not become a weaker twin of the `/admin` route.

Endpoints:

- `GET /rep/codes/:code` — preflight; is this code valid and unassigned?
- `POST /rep/activations` `{code, restaurantName, restaurantPhone, businessName?, contact?}`
- `GET /rep/catalogs` — the rep's active delegations
- `POST /rep/catalogs/:id/products` — dish authoring on behalf of the restaurant
- `POST /rep/catalogs/:id/qr-codes` `{code}` — attach a replacement standee
- `POST /rep/qr-codes/:code/retire`

Activation binds the code with a conditional `findOneAndUpdate` guarded on `state: 'UNASSIGNED'`, so
two reps scanning the same standee produce one winner and one clean 409 — the same atomicity pattern
used for `activePublishRunId` and refresh-token rotation.

### Role ladder (D3)

`src/models/User.ts:13-16`:

```
USER_ROLES = ['USER', 'SALES_REP', 'MODEL_ARTIST', 'ADMIN']
ROLE_RANK  = { USER: 0, SALES_REP: 1, MODEL_ARTIST: 2, ADMIN: 3 }
```

Accepted consequence, stated so it is visible rather than silent: privilege is inclusive upward, so
**every MODEL_ARTIST and ADMIN passes every rep gate**, including activating and repointing QR codes.
Tolerable because both are trusted roles granted only by `scripts/set-user-role.ts` with no grant UI.
Mitigation: keep `/rep` activation on its own rate window and write a `CatalogDelegation` row for
every acting-on-behalf write, so the inheritance is auditable.

**⚠ Client-side landmine.** `lib/domain/entities/user_role.dart` defines `isStaff => this != user`.
Adding `salesRep` silently makes every rep "staff", which would show them the `/admin`-backed
"Live projects" tab (`projects_screen.dart`) and hand them 403s. Change `isStaff` to a rank
comparison (`>= modelArtist`) and add a separate `isSalesRep`. `fromApiValue` already fails closed
to `user`, which is the right default for an unknown role.

---

## Files to touch

**New — backend**

```
src/models/QrCode.ts, QrCodeAssignment.ts, QrScanDaily.ts, CatalogDelegation.ts
src/routes/public.ts            ← /r/:code resolver (unauthenticated)
src/routes/rep.ts               ← /rep activation + delegated authoring
src/services/qrCodeService.ts, qrResolverService.ts, activationService.ts
src/services/catalogDelegationService.ts, catalogModelPromotionService.ts
src/validation/repSchemas.ts, qrSchemas.ts
```

**Modified — backend**

```
src/app.ts                            mount publicRouter + repRouter
src/models/User.ts                    USER_ROLES + ROLE_RANK
src/models/CatalogProduct.ts          + modelStatus
src/models/types/catalog.types.ts:42  + 'RECAPTURE_SHORT_CODE'
src/services/catalogProductsService.ts:366   resolveOwnedModel → OK_PENDING
src/services/catalogProvisioningService.ts   mintPublicUrl writes only when absent
src/worker/processors/meshyModelProcessor.ts + best-effort promotion step
src/routes/admin.ts                   + qr-batch mint/export (ADMIN)
src/config/env.ts + .env.example      PUBLIC_RESOLVER_BASE_URL, QR_BATCH_MAX_SIZE,
                                      ACTIVATION_MAX_PER_WINDOW/_WINDOW_SECONDS  (add together)
scripts/set-user-role.ts              accept SALES_REP
```

**Modified — client**

```
lib/domain/entities/user_role.dart              + salesRep; fix isStaff to rank compare
lib/domain/entities/catalog_product.dart        + modelStatus
lib/application/catalog/catalog_products_notifier.dart   poll while pending
lib/data/repositories/                          + rep_repository.dart
lib/app/routes/app_router.dart                  + /rep/* (register the reserved /catalog/qr too)
lib/presentation/screens/rep/                   activation + dish capture entry (new)
lib/presentation/widgets/catalog/product_card.dart  generating → ready badge
```

Reuse rather than re-derive: `utils/rateLimit.ts::consumeRateWindow` for every new limiter,
`utils/analytics.ts::trackEvent` + a new entry in `validation/analyticsSchemas.ts` (exhaustive by
`satisfies` — a missing schema is a compile error), `utils/otp.ts::hashIdentifier` for any hashed
identifier, and the existing presign→PUT→commit three-step for any new image upload.

---

## Risks and open items

1. **Public traffic on a starter instance that also runs the worker.** `render.yaml` sets
   `RUN_WORKER_IN_PROCESS=true` and already documents this as a broken invariant because
   `MODEL_OPTIMIZATION` is CPU-bound and stalls the event loop. Adding customer scan traffic makes
   cold starts and optimizer stalls *diner-visible*. **Recommend splitting the worker into its own
   Render service before this ships.**
2. **Turning on unattended Meshy spend.** `AUTO_MODEL_GENERATION_ENABLED` + the live remote flag both
   need to go on. `AUTO_MODEL_MAX_PER_USER_PER_DAY` defaults to 10, which under D2 is per *restaurant*
   — roughly one menu's worth. Confirm that ceiling before launch.
3. **Mistyped phone at activation** creates an orphan `User` permanently holding a catalog slot
   (the unique index counts soft-deleted rows). Needs a staff fix-up path; scope it explicitly.
4. **Repointing a code to a *different* catalog** (activated to the wrong restaurant) leaves the
   first catalog's `publicUrl` pointing at a code that no longer resolves to it. Replacing a standee
   for the *same* catalog is safe; cross-catalog repointing needs a rule — suggest allowing it only
   while the catalog has never been published.
5. **Phase 2 free-tier QR** is not blocked by this design: `QrCode` carries no pricing or tier
   concept, and an unassigned code already has a graceful landing page to build on.
6. **Pre-existing, unrelated, should be fixed anyway:** `recapture-api/tok.txt` is git-tracked and
   holds a raw JWT; `src/utils/nodeMailerTransport.ts:4-5` has a literal Gmail address and app
   password as `process.env` fallbacks.

---

## Verification

**Backend** (`cd recapture-api`) — `npm run type-check && npm run lint && npm test`. New vitest
suites follow the existing per-file `MongoMemoryServer` pattern, faking Meshy via `setMeshyClient`,
S3 via `vi.spyOn(s3Client,'send')`, and Mirage via `tests/fixtures/mirageFake.ts` — CI never calls a
live API.

- `qr-resolver.test.ts` — all four code states; assert an unknown code returns HTML, never JSON,
  and that a thrown error still renders the fallback.
- `qr-activation.test.ts` — two concurrent activations of one code produce exactly one winner.
- `qr-reassignment.test.ts` — attaching a replacement code leaves `publicUrl` and the prior
  assignment's scan rollups untouched.
- `rep-delegation.test.ts` — a rep cannot touch a catalog they hold no live delegation for, and the
  failure is indistinguishable from not-found.
- `catalog-model-promotion.test.ts` — a pending-linked product flips to READY on model success; and
  the lock-contention case: promotion under an active publish run leaves rows PENDING and loses
  nothing.
- Extend `catalog-provisioning.test.ts` — provisioning must not overwrite a pre-set `publicUrl`.

**Client** — `flutter analyze && flutter test`. Add a role-gating test mirroring
`test/projects/projects_screen_role_gating_test.dart` asserting `SALES_REP` does **not** read as
staff, and a products-notifier test for the pending→ready poll transition.

**End-to-end** — drive the web build with the `run-recapture` skill (headless Chrome, dev OTP
`555555`): sign in as a rep, activate a code, confirm `/r/{code}` 302s to the Mirage menu, then
confirm an unactivated code renders the fallback instead of a dead link. Note the skill's documented
limit — native capture surfaces (camera, sensors, permission channels) do not exist on web, so the
dish-capture leg needs a device build.
