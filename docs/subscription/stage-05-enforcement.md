# Stage 5 — Enforcement (launch)

Two prompts, two repos. **Part B (Mirage)** must be deployed **before** Part A's flag is flipped,
because Part A's pause job writes a field Mirage must already understand. Order: ship B → ship A
with the flag off → run the grandfather script → flip `subscriptionGatesEnabled: true`.

Product source: `RECAPTURE_SUBSCRIPTION_PLAN.md` §5, §6 (incl. the engineering note), §8-D,
§11, §12 Stage 5, AC-3, AC-4.

---

# Part A — NEW FEATURE: Lifecycle sweep, SUBSCRIPTION_PAUSE/RESUME job, paused-state UI, gates on
# Product: Mirage Menu (ReCapture backend + Flutter client)
# Scope: New Feature
# Priority: Critical

---

## Task Description

- [ ] A scheduled sweep in the worker: `TRIAL|ACTIVE|COMPED → GRACE` at `periodEnd`,
      `GRACE → PAUSED` at `graceEndsAt` (never earlier, D3), each transition a conditional
      `findOneAndUpdate`, idempotent under concurrent runs.
- [ ] New job type `SUBSCRIPTION_AR_ENTITLEMENT` with payload `{ catalogId, enabled: boolean }`
      whose processor calls Mirage `updateRestaurant(id, { arEnabled })` — **never** the
      unpublish processor. Enqueued on `GRACE → PAUSED` (`enabled: false`) and from
      `applyPaidPeriod` when `needsArResume` (`enabled: true`).
- [ ] `arEntitlementSyncedAt` + last-write check (D4): the processor re-reads the subscription
      before writing and aborts if the desired state no longer matches.
- [ ] Owner home/catalog screen: PAUSED card "Your 3D menu is paused — your photo menu is still
      live — pay to restore 3D" as the first card (A9); GRACE red banner on catalog + publish
      screens.
- [ ] Ops runbook section: run `grandfather-catalogs-comped.ts`, then set
      `subscriptionGatesEnabled: true` on `client_configs`.

## Files to Inspect First

1. `recapture-api/src/worker/worker.ts` — the `while + sleep` loop (line ~100–330) and where
   Stage 3's `reconcileOpenOrders` tick was added; the sweep joins that tick.
2. `recapture-api/src/worker/workerRuntime.ts:38-60` — `registerProcessor(...)` is the only
   place to add a processor; `jobTypes` filters at line ~115.
3. `recapture-api/src/worker/workerTypes.ts`, `src/models/types/job.types.ts` — where
   `MIRAGE_CATALOG_PUBLISH_JOB_TYPE` is declared; `src/models/Job.ts:305-315` — the
   `projectId.required` exemption you must extend for the new type.
4. `recapture-api/src/worker/processors/mirageCatalogPublishProcessor.ts` — processor shape,
   `warmUpMirage()`, how `getMirageClient()` is used, how terminal vs retryable errors are
   thrown.
5. `recapture-api/src/services/mirage/mirageClient.ts:70,809` + `mirageTypes.ts` —
   `updateRestaurant(id, UpdateRestaurantInput)`; you add `arEnabled?: boolean` to the input.
6. `recapture-api/src/services/jobsService.ts` / `worker/jobQueue.ts` — how a job is enqueued
   with a priority and an idempotency key.
7. `recapture-api/src/services/subscription/subscriptionService.ts` — `applyPaidPeriod`'s
   `needsArResume`.
8. `recapture-api/tests/worker-lease-and-lane.test.ts`, `tests/catalog-unpublish.test.ts` — the
   test the pause job must be the **opposite** of (it must not call unpublish).
9. `lib/presentation/screens/catalog/catalog_screen.dart`, `publish_screen.dart`,
   `rep_publish_screen.dart`, `lib/presentation/widgets/catalog/publish_body.dart` — banner
   slots.
10. `docs/same-day-activation/stage-07-verification-and-rollout.md` — the rollout doc format to
    mirror for the runbook.

## Implementation Instructions

### Step 1: Job type

Declare `SUBSCRIPTION_AR_ENTITLEMENT_JOB_TYPE = 'SUBSCRIPTION_AR_ENTITLEMENT'` beside the
others; extend `Job.projectId.required` to `!== MIRAGE_CATALOG_PUBLISH && !== SUBSCRIPTION_AR_ENTITLEMENT`;
payload `{ catalogId: string; enabled: boolean; reason: 'GRACE_EXPIRED'|'PAYMENT'|'COMP'|'ADMIN' }`.
Enqueue with idempotency key `ar-entitlement:${catalogId}:${enabled}:${subscription.updatedAt.getTime()}`
so a re-run sweep does not stack duplicates. Priority: same as publish (`PUBLISH_JOB_PRIORITY`) —
a resume is something an owner who just paid is waiting on.

### Step 2: Processor — `worker/processors/subscriptionArEntitlementProcessor.ts`

1. Load `Catalog` (need `mirageRestaurantId`; if absent → succeed as no-op, nothing is live).
2. Load `CatalogSubscription`; compute `desired = isEntitledTo3D(status)`. If
   `desired !== job.payload.enabled` → **abort as success** with a log line (D4: the owner paid
   between enqueue and run; the resume job that payment enqueued will do the right thing).
3. `warmUpMirage()`, then `getMirageClient().updateRestaurant(mirageRestaurantId, { arEnabled: desired })`.
4. `$set arEntitlementSyncedAt: now` on the subscription.
Retryable Mirage errors propagate for the worker's backoff; terminal ones fail the job and
`console.error` — the customer page keeps its previous state, which is the safe direction for
a pause (late) and needs an admin re-run for a resume (add
`POST /admin/catalogs/:id/subscription/resync-ar` (ADMIN) that enqueues a job with the current
desired state).

### Step 3: Sweep — `services/subscription/lifecycleSweep.ts`

`runSubscriptionSweep(now = new Date())` returns `{ toGrace, toPaused, resumesEnqueued }`.

- **To GRACE:** `CatalogSubscription.updateMany({ status: { $in: ['TRIAL','ACTIVE','COMPED'] }, periodEnd: { $lte: now } }, [{ $set: { status: 'GRACE', graceEndsAt: { $add: ['$periodEnd', graceDays * 86_400_000] } } }])`
  (pipeline update so `graceEndsAt` derives from each row's own `periodEnd`, AC-3.1). Emit one
  analytics event per affected row (query the ids first, then update by `_id` list, so the count
  and the events agree).
- **To PAUSED:** find `{ status: 'GRACE', graceEndsAt: { $lte: now } }` ids; for each,
  `findOneAndUpdate({ _id, status: 'GRACE', graceEndsAt: { $lte: now } }, { $set: { status: 'PAUSED', pausedAt: now } })`
  — the conditional filter is the D4 guard; if it returns null the row changed under us (paid)
  and nothing is enqueued. On success enqueue the entitlement job with `enabled: false`.
- Nothing here touches `Catalog.status`, `publishedRevision`, or Mirage items.

Worker tick: every `SUBSCRIPTION_SWEEP_INTERVAL_MS` (env, default `600_000`), from the same
place Stage 3's reconcile runs, guarded by `try/catch` + log so a sweep error never kills the
loop. **Clock rule (D3):** the comparisons are `$lte: now` — the sweep can only be late, never
early.

### Step 4: Wire resume

In `applyPaidPeriod` (Stage 3), when `needsArResume` → enqueue the job with `enabled: true,
reason: 'PAYMENT'`. In `applyComp` → the same when the previous status was PAUSED/CANCELLED.
`cancelOnCatalogDelete` needs no job (the restaurant is deleted by `DELETE /catalog`).

### Step 5: Client paused/grace UI

- `Catalog.subscription` (Stage 2 summary) already carries `status` and `isEntitledTo3D`.
- `catalog_screen.dart`: when `status == paused` render a top card (first child) with the A9 copy
  and a button to `/catalog/subscription`; when `grace`, a red banner "Payment overdue — 3D menu
  pauses in N days" with the same button.
- `publish_body.dart`: a `PublishVoice`-aware banner slot above the checklist for GRACE (owner:
  "…pay to keep 3D live", rep: "…notify the owner"). PAUSED needs no banner — the gate row says
  it.
- Rep detail card: PAUSED line already exists (Stage 2); add "Photo menu is still live at the
  same QR" as the secondary line.

### Step 6: Runbook — `docs/subscription/rollout.md`

Ordered checklist: (1) Mirage Part B deployed and `arEnabled` verified on one restaurant via
curl; (2) backend deployed, flag absent; (3) `npx tsx scripts/grandfather-catalogs-comped.ts --dry-run`
then real; (4) set `subscriptionGatesEnabled: true`; (5) watch `publish_blocked_by_subscription`
counts for 24 h; (6) rollback = set the flag `false` (gates off instantly; sweep keeps running
harmlessly, nothing is deleted).

## API / Data Contract

```
POST /admin/catalogs/:id/subscription/resync-ar   (ADMIN)  → 202 { status:'success', jobId }
Mirage: PUT /update-restaurant/:restaurantId  body gains { arEnabled: boolean }   (Part B)
```

Job payload: `{ catalogId: string, enabled: boolean, reason: 'GRACE_EXPIRED'|'PAYMENT'|'COMP'|'ADMIN' }`.

## Analytics Events

`subscription_state_changed { catalog_id, from, to, by: 'SWEEP'|'PAYMENT'|'ADMIN' }`
`subscription_ar_entitlement_synced { catalog_id, enabled: boolean, reason, skipped: boolean }`
`subscription_sweep_ran { to_grace: number, to_paused: number, duration_ms: number }`

## What NOT to Change

- Do NOT call `unpublishCatalog`, the unpublish processor, `deleteRestaurant`, or any
  `delete-item` from the sweep or the entitlement processor (AC-4.1, AC-4.3).
- Do NOT write `Catalog.status`, `publishedRevision`, `activePublishRunId`, or
  `mirageRestaurantId` from subscription code.
- Do NOT interrupt a running publish: the sweep does not read `activePublishRunId` at all (D5).
- Do NOT compute "days left" or state transitions on the client.
- Do NOT add a second "PAUSED" concept in the app; it is `SubscriptionStatus.paused` from
  Stage 2.
- Do NOT flip the flag in code, seeds, or CI — it is an ops action on the `client_configs` doc.

## Edge Cases to Handle

- [ ] Grace ends at 03:00; sweep runs at 03:10 → PAUSED at 03:10 (late is fine); a sweep at
      02:55 must do nothing (D3 test with a fixed clock).
- [ ] Owner pays at 03:09:59 while the sweep is mid-run → conditional update returns null → no
      pause job (D4); or the pause ran first → the payment's resume job flips it back within one
      worker poll.
- [ ] Two worker instances run the sweep concurrently → each row transitions once; the
      idempotency key dedupes the job.
- [ ] Catalog never provisioned (`mirageRestaurantId` absent) → processor succeeds as no-op.
- [ ] Mirage asleep → `warmUpMirage` + retryable error → worker backoff; the customer page keeps
      3D a few minutes longer (acceptable direction).
- [ ] COMPED grandfather window ends → GRACE → PAUSED like any plan (README C4).
- [ ] Subscription CANCELLED via `DELETE /catalog` → no job; the restaurant is gone.
- [ ] Flag flipped on while some catalogs still lack a row (grandfather script skipped an
      unprovisioned catalog) → their first publish shows `SUBSCRIPTION_REQUIRED`, as designed —
      the rep starts a trial.

## Constraints

- Pipeline-style `updateMany` for the GRACE transition; conditional per-row `findOneAndUpdate`
  for PAUSED (the one that enqueues work).
- The processor is registered only in `workerRuntime.ts` and listed in the reserved-lane
  `jobTypes` filter exactly as the publish job is (so a resume is not starved by Meshy).
- `arEnabled: true` is the Mirage default; a restaurant that has never been written is entitled.

## Acceptance Criteria

- [ ] `tsc --noEmit`, `npm run lint`, `flutter analyze` pass; both suites green.
- [ ] Fixed-clock test: ACTIVE with `periodEnd = T` → sweep at `T-1s` no change; at `T` → GRACE
      with `graceEndsAt === T + 7d` (AC-3.1, AC-3.4).
- [ ] GRACE with `graceEndsAt = G` → sweep at `G-1s` no change; at `G` → PAUSED, one job
      `{ enabled: false }` enqueued; sweep again → no second job.
- [ ] Payment during GRACE (scripted webhook) → ACTIVE, no pause job ever enqueued, no Mirage
      call (AC-3.3).
- [ ] Payment while PAUSED → ACTIVE and one job `{ enabled: true }`; processor calls
      `updateRestaurant(id, { arEnabled: true })` exactly once (scripted `MirageClient`) (AC-4.4).
- [ ] Processor with a subscription whose desired state differs from the payload → no Mirage
      call, job succeeds, `skipped: true` event.
- [ ] `tests/catalog-unpublish.test.ts` and `tests/catalog-delete.test.ts` unchanged and green;
      a new assertion proves the entitlement processor never invokes the unpublish code path
      (spy on it).
- [ ] With the flag on: PAUSED catalog with 0 READY-model dishes publishes; with ≥1 it gets
      `SUBSCRIPTION_REQUIRED`; ACTIVE over cap gets `SUBSCRIPTION_CAPACITY_EXCEEDED`
      (re-run Stage 1's suite with the flag on).
- [ ] Owner app: PAUSED shows the A9 card first on the catalog screen; GRACE shows the red banner
      on catalog + publish screens; rep publish shows the rep-voice banner (widget tests).
- [ ] `rollout.md` exists with the six ordered steps and the rollback line.

## Testing Instructions

1. Backend: `tests/subscription-sweep.test.ts` (fixed clock via `vi.setSystemTime`),
   `tests/subscription-ar-entitlement-processor.test.ts` (scripted `setMirageClient`),
   `tests/subscription-enforcement-e2e.test.ts` (flag on: trial → publish → expire → grace →
   pause → pay → resume, asserting every Mirage call). Run the full suite once at the end.
2. Client: `test/catalog/subscription_banners_test.dart`.
3. Staging rehearsal per `rollout.md` with one real restaurant: set `periodEnd` to now-1m in
   Mongo, wait one sweep, scan the QR → photo menu loads, no 3D; pay with a test key → 3D back
   within a minute.

## Assumptions

- Assumed TRIAL and COMPED expiries go through GRACE (README C4). If a trial should pause
  immediately, remove `'TRIAL'` from the to-GRACE filter and add a `TRIAL → PAUSED` branch.
- Assumed a single boolean `arEnabled` on the Mirage restaurant is the entitlement flag (Part B).
  Per-feature flags (website embed etc.) can hang off the same write later.

---

# Part B — NEW FEATURE: `arEnabled` render-time entitlement on the public menu
# Product: Mirage Menu (mirage-be + mirage-fe)
# Scope: New Feature
# Priority: Critical

---

## Task Description

Let ReCapture switch a restaurant's 3D/AR off and on **without** unpublishing, per plan §6
"How PAUSED actually works" and AC-4. The image-based menu keeps serving at the same URL; only
the 3D viewer, the AR button, and 3D-dependent features stop.

- [ ] `restaurantModel`: `arEnabled: { type: Boolean, default: true }`.
- [ ] Admin `PUT /update-restaurant/:restaurantId` accepts `arEnabled` (parsed with the same
      `parseBooleanField` used for `isPublished`), partial update, no other side effects.
- [ ] `GET /get-data-for-new-ui/:restaurantSlug` returns `restaurantData.arEnabled` (default
      `true` when the field is absent), and the same on any other public read that feeds the
      viewer (`get-single-product`, `get-item/...`, `get-all-items`).
- [ ] Frontend: when `arEnabled === false`, every card renders the photo instead of
      `<model-viewer>`, the AR/"View in AR" control is hidden, and a card with a model but **no**
      photo renders a placeholder card ("AR preview unavailable", name + price still shown).
- [ ] The frontend's cached `restaurantData` must not pin a stale `arEnabled`: read the flag from
      the fresh response and never from the cache.

## Files to Inspect First

1. `mirage-be/src/Models/restaurantModel.js` — the schema (line ~30–110); `isPublished` is the
   precedent for a ReCapture-owned boolean.
2. `mirage-be/src/Controllers/adminController.js:502` (`updateRestaurant`) and the
   `parseBooleanField` / `isPublished` handling around lines 584–710.
3. `mirage-be/src/Controllers/itemController.js:492` (`getDataForNewUi`) — the `restaurantData`
   object built by hand at line ~527; `getSingleProductData`, `getSingleItem`, `getAllItems`.
4. `mirage-fe/src/features/menu/useFetchApiForNewUi.ts` — lines 55–100: the cache read
   (`cachedData.restaurantData`) and the fresh fetch.
5. `mirage-fe/src/features/menu/MenuItemCard.tsx` — `has3DModel = !!modelSrc` (line 30), the
   `<model-viewer>` branch (~81–130), the image branch (~134), the AR control (~180).
6. `mirage-fe/src/features/menu/NewModelViewer.tsx`, `MenuScreen.tsx:106` — where
   `restaurantData` is threaded to cards.
7. `mirage-fe/src/Types.ts` / `Types/` — `TypeRestaurantData`.
8. `docs/same-day-activation/stage-08-does-this-touch-mirage.md` in ReCapture — the style for
   documenting a Mirage change and its probe.

## Implementation Instructions

### Step 1: Backend

- Schema: add `arEnabled` after `isPublished` with a comment: "ReCapture-owned entitlement flag.
  `false` hides the 3D viewer/AR on the public page; items and models are untouched. Absent =
  true so pre-existing restaurants are unaffected."
- `updateRestaurant`: parse `req.body.arEnabled` exactly like `isPublished`; set only when
  defined. Do not touch `clientType`.
- Public reads: add `arEnabled: restaurantDetails.arEnabled !== false` to `restaurantData` in
  `getDataForNewUi`; for the single-item/product endpoints include `restaurant.arEnabled` in the
  response object they already build (field by field, no spread).
- `isPublished === false` handling is unchanged: unpublish still 404s; pause never does.

### Step 2: Frontend

- `TypeRestaurantData` gains `arEnabled?: boolean`; the `useFetchApiForNewUi` default state
  sets `arEnabled: true`.
- Cache: when hydrating from `cachedData`, set `arEnabled` from the **fresh** response once it
  arrives; until then keep `true` (fail open for a few hundred ms rather than flashing a
  placeholder for a paid restaurant). Concretely: after `setRestaurantData(json.restaurantData)`
  the fresh value wins; the cache write already stores the whole object, so the next visit's
  hydration is at most one fetch stale.
- `MenuItemCard`: accept `arEnabled: boolean` (default `true`); `const has3DModel = !!modelSrc && arEnabled;`.
  Then:
  - `modelSrc && !arEnabled && imageUrl` → existing image branch (photo card).
  - `modelSrc && !arEnabled && !imageUrl` → new `ArUnavailableCard` (same dimensions as the
    image card; a neutral placeholder graphic from `assets/`; name and price rendered by the
    same elements as every other card; no "paused"/billing wording — the diner is not the
    customer of that message).
  - The AR control (line ~180) and any "View in AR" CTA render only when `has3DModel`.
- Thread `arEnabled` from `MenuScreen` (`restaurantData.arEnabled`) to every card and to
  `NewModelViewer`/the single-item screen so a deep link to one dish obeys the flag too.
- Analytics: existing scan/view events keep firing (D9); add `ar_hidden_by_entitlement: true`
  to the item-view event payload when the flag hides a model, if the analytics helper accepts
  extra fields; otherwise skip.

### Step 3: Probe (document it)

`curl -X PUT $MIRAGE/admin/update-restaurant/<id> -H "Authorization: …" -d '{"arEnabled":false}'`
then `curl $MIRAGE/get-data-for-new-ui/<slug> | jq .restaurantData.arEnabled` → `false`; open
the page → photos only; set `true` → 3D back. Record in the PR.

## API / Data Contract

```
PUT /admin/update-restaurant/:restaurantId   body { arEnabled?: boolean }  (partial; other fields unchanged)
GET /get-data-for-new-ui/:slug → restaurantData.arEnabled: boolean (default true)
GET /get-single-product/:id, /get-item/:r/:c/:i, /get-all-items/:r → include restaurant arEnabled
```

## Analytics Events

No new events required. Item-view/scan events must continue to fire while `arEnabled === false`
(D9).

## What NOT to Change

- Do NOT delete, hide, or filter items/categories/3D assets when `arEnabled` is false.
- Do NOT reuse `clientType` or `isPublished` to express the pause.
- Do NOT change `getDataForNewUi`'s 404 for `isPublished === false`.
- Do NOT expose `arEnabled` as writable on any non-admin route.
- Do NOT restyle existing cards; the placeholder is one new component.

## Edge Cases to Handle

- [ ] Restaurant document predates the field → `arEnabled` undefined → served as `true`.
- [ ] `arEnabled: false` and the item has `modelSrc` + `imageUrl` → photo card, no model
      download initiated (assert no `<model-viewer>` in the DOM).
- [ ] `arEnabled: false`, `modelSrc`, no `imageUrl` → placeholder card with name and price.
- [ ] `arEnabled: false`, no `modelSrc` (image-only item) → unchanged.
- [ ] Cached page from before the pause → first paint may show 3D for < 1 s, then the fresh
      response hides it; no flicker loop.
- [ ] Deep link to a single dish while paused → photo/placeholder, no AR button.

## Constraints

- Public responses are built field by field (matching ReCapture's analytics-proxy stance and
  Mirage's existing style in `getDataForNewUi`).
- The placeholder asset must be a small static file (< 30 KB) bundled in `mirage-fe`, not a
  remote URL.
- Low-end Android: the paused path must not instantiate `<model-viewer>` at all.

## Acceptance Criteria

- [ ] `PUT /update-restaurant` with `{ arEnabled: false }` persists; with `{}` leaves it
      unchanged; with `"false"` (string) is parsed like `isPublished` is.
- [ ] `GET /get-data-for-new-ui/:slug` returns `arEnabled: true` for a legacy doc and `false`
      after the PUT; still 200 (AC-4.1).
- [ ] Page with `arEnabled: false`: zero `<model-viewer>` elements, zero AR buttons, every dish
      still listed with name and price; dishes without a photo show the placeholder (AC-4.2).
- [ ] Toggling back to `true` restores 3D on the same items with no re-create (AC-4.3, AC-4.4).
- [ ] Item-view analytics rows still written while paused.
- [ ] Works on Android Chrome (mid-range), iOS Safari, desktop Chrome; no console errors.
- [ ] The probe in Step 3 is recorded in the PR description.

## Testing Instructions

1. Backend (Mirage's existing test setup, or a supertest suite if one exists): schema default,
   PUT parsing, public read shape.
2. Frontend: component tests for `MenuItemCard` in the four combinations above; `npm run build`.
3. Manual: run mirage-be + mirage-fe locally, use the Step 3 probe, verify on a phone via LAN.

## Assumptions

- Assumed the AR-menu website embed (MasterChef feature) is the same public page in an iframe,
  so this flag covers it. If it is a separate endpoint, add the same `arEnabled` check there.
