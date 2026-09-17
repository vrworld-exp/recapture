# NEW FEATURE: Subscription service, trial activation, and status screens (owner + rep)
# Product: Mirage Menu (ReCapture backend + Flutter client)
# Scope: New Feature
# Priority: High

---

## Task Description

Make the subscription **readable and startable** on both sides of the wire, per
`RECAPTURE_SUBSCRIPTION_PLAN.md` §4 Door 1, §6 (status table), §9, §11. After this stage a rep
can start a 30-day trial on the spot, and the owner/rep screens show real status and 3D usage. The
publish gates stay **off** (`subscriptionGatesEnabled` absent). No money moves.

- [ ] `subscriptionService.ts`: status DTO builder, `startTrial`, `cancelOnCatalogDelete`,
      `getOrNull`.
- [ ] Routes: `GET /catalog/subscription` (owner), `GET /rep/catalogs/:id/subscription`,
      `POST /rep/catalogs/:id/subscription/trial`, `POST /admin/catalogs/:id/subscription/trial`.
- [ ] `GET /catalog` (owner DTO) and `GET /rep/catalogs` (rep list) each gain a compact
      `subscription` summary.
- [ ] `DELETE /catalog` cancels the subscription (C9) — no refund, no trial reset.
- [ ] `/remote-config` serves the validated plan catalog under `subscriptionPlans`.
- [ ] Client: `CatalogSubscription` entity, repository methods, providers, the owner
      **Subscription** screen (status, usage, plan comparison with monthly/yearly toggle — **no Pay
      button yet**), rep list status chip, rep detail "Subscription" card with **Start trial**, and
      the Publish gate "Fix" routing for the two subscription codes.

## Files to Inspect First

1. `recapture-api/src/models/CatalogSubscription.ts`, `src/services/subscription/*` — Stage 1
   output; reuse `getPlanCatalog`, `countThreeDDishes`, `isEntitledTo3D`.
2. `recapture-api/src/services/catalogService.ts` — `toCatalogDto` (line ~145), `getCatalog`,
   `deleteCatalog` (line ~618) and its `DeleteCatalogResult`.
3. `recapture-api/src/services/catalogDelegationService.ts` — `listDelegatedCatalogs` (line ~92,
   the rep list DTO you decorate) and `resolveDelegatedCatalog`.
4. `recapture-api/src/routes/rep.ts` — router-level `requireRole('SALES_REP')`, `notDelegated()`,
   `fail()`, and the `/catalogs/:id/publish` handler as the template for a delegated write.
5. `recapture-api/src/routes/admin.ts` — router-level `requireRole('MODEL_ARTIST')` and the
   per-route `requireRole('ADMIN')` pattern.
6. `recapture-api/src/routes/catalog.ts` — owner routes; how `findOwnedCatalog` is used.
7. `recapture-api/src/services/remoteConfigService.ts` + `src/validation/remoteConfigSchema.ts`
   — the strict served schema you extend with one **pre-validated** field.
8. `recapture-api/src/services/catalogPublishService.ts` — `publishableProducts()` (export it if
   it is not) for the usage number.
9. `lib/domain/entities/catalog.dart`, `rep_activation.dart` (`RepCatalogSummary`),
   `lib/data/repositories/catalog_repository.dart`, `rep_repository.dart`.
10. `lib/presentation/screens/catalog/publish_screen.dart:65` and
    `lib/presentation/screens/rep/rep_publish_screen.dart:86` — the two `_fix(PublishGate)`
    handlers.
11. `lib/presentation/screens/rep/rep_catalogs_screen.dart`, `rep_catalog_detail_screen.dart`,
    `lib/presentation/screens/catalog/catalog_screen.dart` (header badge),
    `lib/app/routes/app_router.dart` (route constants, line ~100–260).
12. `lib/data/repositories/config_repository.dart` — how `/remote-config` is parsed and cached.
13. `test/rep/` and `recapture-api/tests/rep-publish.test.ts` — the "rep payload equals owner
    payload" assertion style to copy.

## Implementation Instructions

### Step 1: `src/services/subscription/subscriptionService.ts`

Pure-ish service (no Express types). Exports:

```ts
export interface SubscriptionStatusDto {
  status: SubscriptionStatus | 'NONE';
  planId: PlanId | null;
  planName: string | null;
  billingInterval: BillingInterval | null;
  periodEnd: string | null;         // ISO
  graceEndsAt: string | null;
  daysLeft: number | null;          // SERVER-computed (D6): ceil((periodEnd - now)/day), min 0;
                                    // in GRACE: days until graceEndsAt
  threeDDishCount: number;          // countThreeDDishes(publishableProducts(products))
  threeDDishCap: number | null;     // null = uncapped
  imageDishCount: number;           // live products that do NOT count as 3D
  trialAvailable: boolean;          // no row, or row with trialUsedAt unset
  isEntitledTo3D: boolean;
  standeeAllocation: { included: number; issued: number } | null;
  plans: PlanCatalog;               // so the screen never needs a second call
}

export async function getSubscriptionStatus(catalogId: Types.ObjectId): Promise<SubscriptionStatusDto>
export async function getSubscriptionSummary(catalogId): Promise<SubscriptionSummaryDto>
  // { status, daysLeft, planId, isEntitledTo3D, trialAvailable } — for list rows / catalog DTO
export async function startTrial(catalogId, actor: Actor):
  Promise<{ outcome: 'STARTED'; dto: SubscriptionStatusDto } | { outcome: 'TRIAL_ALREADY_USED' } | { outcome: 'SUBSCRIPTION_ACTIVE' }>
export async function cancelOnCatalogDelete(catalogId, now = new Date()): Promise<void>
```

`startTrial` atomicity, the house way (no transactions):

- If no row: `CatalogSubscription.create({...TRIAL fields})` inside try/catch on E11000 → on
  duplicate, re-read and fall through to the row-exists path (A5: two reps, one trial).
- If row exists: `findOneAndUpdate({ catalogId, trialUsedAt: null, status: { $in: ['CANCELLED','PAUSED'] } }, {$set: TRIAL fields})`.
  If it returns null → the row has `trialUsedAt` set → `TRIAL_ALREADY_USED`; or the status is
  TRIAL/ACTIVE/GRACE/COMPED → `SUBSCRIPTION_ACTIVE`. Decide which by re-reading.
- TRIAL fields: `status: 'TRIAL'`, `source: 'TRIAL'`, `periodStart: now`,
  `periodEnd: now + trialDays days`, `threeDDishCap: trialThreeDCap`, `trialUsedAt: now`,
  `trialActivatedBy: actor`, `planId: undefined`, `planSnapshot: undefined`,
  `graceEndsAt: undefined`.
- Emit `subscription_trial_started` (see Analytics).

`cancelOnCatalogDelete`: `findOneAndUpdate({ catalogId }, { $set: { status: 'CANCELLED', cancelledAt: now } })`.
`trialUsedAt` is untouched (D2). Idempotent when no row.

### Step 2: Owner and rep routes

- `routes/catalog.ts`: `GET /catalog/subscription` → `findOwnedCatalog`; 404 `CATALOG_NOT_FOUND`
  if none; else `{ status: 'success', subscription: dto }`.
- `routes/rep.ts` (declare **before** `/catalogs/:id/products/:productId`):
  - `GET /catalogs/:id/subscription` → `resolveDelegatedCatalog`, `notDelegated()` on miss, same
    body shape as the owner's.
  - `POST /catalogs/:id/subscription/trial` → `startTrial(catalog._id, { userId, role: req.user.role })`.
    Map: `STARTED` → 201 `{ status:'success', subscription }`; `TRIAL_ALREADY_USED` → 409
    `TRIAL_ALREADY_USED`; `SUBSCRIPTION_ACTIVE` → 409 `SUBSCRIPTION_ACTIVE`. Rate-limit with
    `consumeRateWindow('rep-trial:' + catalogId, 5, 3600)`.
- `routes/admin.ts`: `POST /admin/catalogs/:id/subscription/trial` with `requireRole('ADMIN')`,
  catalog by id (`Catalog.findOne({_id, deletedAt: null})`), same mapping (README C3).
- `routes/catalog.ts` `DELETE /catalog`: inside `deleteCatalog` in `catalogService.ts`, call
  `cancelOnCatalogDelete(catalog._id)` **after** the Mirage `deleteRestaurant` succeeds and before
  the soft-delete write, so a Mirage refusal (which aborts the delete) leaves the subscription
  untouched. Add `subscriptionCancelled: boolean` to `DeleteCatalogResult`.

### Step 3: Decorate existing DTOs

- `toCatalogDto` is sync; `getCatalog` is async. In `getCatalog`, after building the DTO, attach
  `subscription: await getSubscriptionSummary(catalog._id)`. Add the field to `CatalogDto`.
- `listDelegatedCatalogs`: one `CatalogSubscription.find({ catalogId: { $in: ids } }).lean()` and
  attach `subscription` per row (one query for the list, never per row). `null` when no row.

### Step 4: Plan catalog on `/remote-config`

In `remoteConfigService.getRemoteConfig`, add to `candidate`:
`subscriptionPlans: await getPlanCatalog()` — **already validated / defaulted** by Stage 1's
reader, so it can never fail the strict schema. In `remoteConfigSchema.ts` add
`subscriptionPlans: planCatalogSchema` and put `DEFAULT_PLAN_CATALOG` into
`DEFAULT_REMOTE_CONFIG`. Bump the config `version` per that file's convention. Check
`test/config/` on the client and `tests/` for remote-config for fixtures that need the new key.

### Step 5: Client domain + data

- `lib/domain/entities/catalog_subscription.dart`: `SubscriptionStatus` enum (+ `none`,
  `unknown` fallback, `apiValue`/`fromApiValue` hand-synced), `PlanId`, `BillingInterval`,
  `PlanDefinition`, `PlanCatalog`, `CatalogSubscription` (mirrors `SubscriptionStatusDto`),
  `SubscriptionSummary`. `fromMap` tolerant of missing keys (an older server).
- `Catalog` gains `SubscriptionSummary? subscription`; `RepCatalogSummary` likewise.
- `CatalogRepository`: `Future<CatalogSubscription> subscription()`.
- `RepRepository`: `Future<CatalogSubscription> subscription(String catalogId)`,
  `Future<CatalogSubscription> startTrial(String catalogId)` mapping 409 codes to a
  `CatalogFailure` variant (see `catalog_failure.dart`).
- `ConfigRepository`/`CaptureConfig`: parse `subscriptionPlans` into `PlanCatalog` with the
  same defaults as the server if absent.

### Step 6: Client application layer

- `lib/application/catalog/subscription_notifier.dart`: `subscriptionProvider`
  (`AsyncNotifier<CatalogSubscription>`, autoDispose, refresh on demand).
- `lib/application/rep/rep_subscription_notifier.dart`: family by `catalogId`; `startTrial()`
  → on success invalidate `repCatalogsProvider` and `repCatalogDocumentProvider` so the chip
  and card update together.

### Step 7: Client screens

- New route `AppRoutes.catalogSubscription = '/catalog/subscription'` →
  `lib/presentation/screens/catalog/subscription_screen.dart`:
  - Status line + date from `status`/`periodEnd`/`daysLeft` (copy table below).
  - Usage row: "3D/AR dishes 12 / 15 (Signature)" or "12 / 10 (trial)"; image dishes
    "Unlimited".
  - Plan comparison: three cards from `plans`, a Monthly/Yearly segmented toggle; yearly price
    = `yearlyPricePaise` rounded to the nearest rupee for **display only**, with "save 30%".
  - **No Pay/Renew/Upgrade button in this stage** — leave a clearly named slot
    (`_CheckoutSlot`) that Stage 3 fills. A "Talk to your sales rep to activate" line is fine.
  - Reachable from the catalog header badge in `catalog_screen.dart` (add a small chip next to
    the existing publish badge) and from Profile.
- `rep_catalogs_screen.dart`: per row a chip from `SubscriptionSummary`: `Trial 12d` /
  `Active` / `Overdue 3d` / `3D paused` / `Cancelled` / `Comped` / `No plan`.
- `rep_catalog_detail_screen.dart`: a "Subscription" card: status line, usage, and one action:
  **Start free trial** when `trialAvailable`, otherwise a disabled line "Owner pays in the app
  (coming soon)". Confirm dialog before starting: "Start a 30-day free trial for <restaurant>?
  Up to 10 3D dishes. One trial per restaurant." On 409 show the server's sentence.
- Gate Fix routing: in `publish_screen.dart::_fix` route `subscriptionRequired` and
  `subscriptionCapacityExceeded` to `AppRoutes.catalogSubscription`; in
  `rep_publish_screen.dart::_fix` route both to `repCatalogDetail` for that id (the card is the
  rep's Fix). Flip `canFix` for these two codes to true on both voices.

Status copy (one source: `lib/domain/catalog/subscription_copy.dart`):

| status | owner line | rep chip |
|---|---|---|
| NONE | "No subscription yet" | "No plan" |
| TRIAL | "Free trial — N days left, up to 10 3D dishes" | "Trial Nd" |
| ACTIVE | "Active until <d MMM yyyy> · <Plan>" | "Active" |
| GRACE | "Payment overdue — 3D menu pauses in N days" (red) | "Overdue Nd" |
| PAUSED | "3D menu paused — your photo menu is still live" | "3D paused" |
| CANCELLED | "Cancelled — resubscribe anytime" | "Cancelled" |
| COMPED | "Complimentary until <date>" | "Comped" |

## API / Data Contract

```
GET /catalog/subscription                         (owner)
GET /rep/catalogs/:id/subscription                (SALES_REP, delegated)
→ 200 { "status":"success", "subscription": SubscriptionStatusDto }

POST /rep/catalogs/:id/subscription/trial         (SALES_REP, delegated)
POST /admin/catalogs/:id/subscription/trial       (ADMIN)
→ 201 { "status":"success", "subscription": SubscriptionStatusDto }
→ 409 { "status":"error", "code":"TRIAL_ALREADY_USED", "message":"This restaurant has already used its free trial." }
→ 409 { "status":"error", "code":"SUBSCRIPTION_ACTIVE", "message":"This restaurant already has an active subscription." }
→ 404 CATALOG_NOT_FOUND (rep: not delegated; admin: no such catalog — same body)

GET /catalog  → adds "subscription": { status, daysLeft, planId, isEntitledTo3D, trialAvailable } | null
GET /rep/catalogs → each item adds the same "subscription" summary
GET /remote-config → adds "subscriptionPlans": PlanCatalog
```

## Analytics Events

Event: `subscription_trial_started`
Trigger: `startTrial` returns `STARTED`.
Properties: `catalog_id: string`, `actor_role: UserRole`, `actor_id_hash: string`
(`hashIdentifier`), `door: 'REP' | 'ADMIN'`.

Event: `subscription_trial_refused`
Trigger: `TRIAL_ALREADY_USED` or `SUBSCRIPTION_ACTIVE`.
Properties: `catalog_id`, `actor_role`, `reason: 'ALREADY_USED' | 'ACTIVE'`.

Client: `Analytics.logEvent('subscription_screen_viewed', { surface: 'owner' | 'rep' })` and
`('subscription_trial_tapped', { catalog_id })`.

## What NOT to Change

- Do NOT flip `subscriptionGatesEnabled` anywhere, including test fixtures for unrelated suites.
- Do NOT add a Pay button, Razorpay dependency, or any checkout UI — Stage 3.
- Do NOT change `resolveDelegatedCatalog`, `grantDelegation`, or `CatalogDelegation` — the
  trial route relies on the existing "only the rep who activated" bound.
- Do NOT let the trial route accept a plan or a duration in the body; both are config.
- Do NOT reset `trialUsedAt` on `DELETE /catalog` or on catalog re-create (D2).
- Do NOT compute `daysLeft` on the client (D6) — render the server's number.
- Do NOT add `accountPhone` or any owner contact to the subscription DTOs.
- Do NOT touch `PublishFlow`, `PublishGateway`, or the publish body layout beyond `_fix` and
  `canFix`.

## Edge Cases to Handle

- [ ] Two reps tap Start trial simultaneously → one `STARTED`, one `SUBSCRIPTION_ACTIVE`
      (E11000 path); both screens then show TRIAL.
- [ ] Trial on a catalog whose row is CANCELLED with `trialUsedAt` unset (comped-then-cancelled)
      → allowed, becomes TRIAL.
- [ ] Trial on a PAUSED row with `trialUsedAt` set → `TRIAL_ALREADY_USED`.
- [ ] Owner opens the Subscription screen with an older server that lacks `subscriptionPlans`
      → client falls back to its built-in defaults; screen still renders.
- [ ] `GET /rep/catalogs` with 30 delegated catalogs → exactly one subscription query.
- [ ] `periodEnd` in the past but sweep has not run yet (Stage 5 not shipped) → `daysLeft: 0`,
      status still shows what is stored; no client-side state inference.
- [ ] `DELETE /catalog` when Mirage refuses → subscription unchanged (test with a scripted
      `MirageClient` that throws).

## Constraints

- Every DTO field is built by hand (no spreading a Mongoose doc), matching the analytics-proxy
  rule in AGENTS.md.
- Route bodies: none for the trial route; reject a non-empty body with 400 `INVALID_REQUEST`
  via a `z.object({}).strict()` `validateBody`.
- `daysLeft` uses `Math.max(0, Math.ceil(ms / 86_400_000))` on the server; the client renders the
  integer verbatim.
- Rep and owner `GET …/subscription` bodies must be **payload-equal** for the same catalog
  (assert it in the test like `rep-publish.test.ts` does).

## Acceptance Criteria

- [ ] `tsc --noEmit`, `npm run lint`, `flutter analyze` pass.
- [ ] A rep with a delegation can start a trial: 201, row has `status: 'TRIAL'`,
      `periodEnd - periodStart === 30 days`, `threeDDishCap === 10`, `trialUsedAt` set,
      `trialActivatedBy.role === 'SALES_REP'` (AC-2.3, AC-2.5).
- [ ] The second trial attempt on the same catalog returns 409 `TRIAL_ALREADY_USED` (AC-2.4).
- [ ] A rep without a delegation gets 404 `CATALOG_NOT_FOUND` on GET and POST — identical body.
- [ ] An ADMIN can start a trial via `/admin/catalogs/:id/subscription/trial` with no delegation.
- [ ] A `SALES_REP` calling the admin trial route gets 403 `FORBIDDEN`.
- [ ] A newly created catalog has no `CatalogSubscription` row and `GET /catalog` returns
      `subscription: null` (AC-2.1).
- [ ] `GET /catalog/subscription` and `GET /rep/catalogs/:id/subscription` return deep-equal
      bodies for the same catalog.
- [ ] `DELETE /catalog` sets `status: 'CANCELLED'`, keeps `trialUsedAt`, and re-creating the
      catalog then `POST …/trial` returns `TRIAL_ALREADY_USED`.
- [ ] `/remote-config` includes `subscriptionPlans` with three plans and still returns 200/304
      when the store is empty.
- [ ] Owner Subscription screen renders all seven status lines from the copy table (widget test
      over fixtures) and no Pay button exists.
- [ ] Rep list chip shows `Trial 12d` for a fixture with `daysLeft: 12`.
- [ ] Rep detail Start-trial button → confirm → success updates the chip without a manual
      refresh (provider invalidation test).
- [ ] Publish screen Fix for `SUBSCRIPTION_REQUIRED` navigates to `/catalog/subscription` (owner)
      and `/rep/catalogs/:id` (rep).
- [ ] With the gate flag absent, no publish test changes.

## Testing Instructions

1. Backend: add `tests/subscription-status.test.ts` (DTO math, daysLeft, counts),
   `tests/subscription-trial.test.ts` (both doors, races, 409s, role checks),
   `tests/catalog-delete-cancels-subscription.test.ts`, extend the remote-config suite. Run
   `npm test` once at the end.
2. Client: `test/catalog/subscription_entity_test.dart` (fromMap tolerance, copy table),
   `test/rep/rep_subscription_card_test.dart`, `test/catalog/publish_fix_routing_test.dart`.
   Run `flutter test`.
3. Manual: `npm run dev`, seed a rep + delegated catalog (existing e2e helpers under
   `scripts/e2e/`), open the rep app in Chrome mobile emulation → start trial → owner logs in →
   Subscription screen shows "Free trial — 30 days left".
4. curl: `curl -X POST -H "Authorization: Bearer <rep>" localhost:3000/rep/catalogs/<id>/subscription/trial`.

## Assumptions

- Assumed: a trial may be started on a CANCELLED/PAUSED row whose `trialUsedAt` is unset (a
  comped pilot that lapsed). If trials are only for never-subscribed catalogs, change the
  `findOneAndUpdate` filter to `{ catalogId, trialUsedAt: null, status: 'CANCELLED' }`.
- Assumed: the Profile entry point is a list tile on the existing profile screen; if Profile is
  frozen, the catalog header chip alone satisfies §9.
