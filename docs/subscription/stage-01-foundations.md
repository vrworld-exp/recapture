# NEW FEATURE: Subscription foundations — models, plan catalog, 3D-dish count, publish gates (switched off)
# Product: Mirage Menu (ReCapture backend + 2 client enum values)
# Scope: New Feature
# Priority: High

---

## Task Description

Lay the data and rule foundations for the catalog subscription layer described in
`RECAPTURE_SUBSCRIPTION_PLAN.md` §3, §3b, §3c, §5, §10, §11. Nothing is user-visible after this
stage: the two new publish gates exist but only run when a server flag is `true`, and the flag is
absent in every environment.

- [ ] Add `CatalogSubscription` and `PaymentRecord` Mongoose models with the fields in §10.
- [ ] Add the plan catalog (three plans + shared constants) as typed server config with an
      optional, validated override on the `client_configs` document.
- [ ] Add a pure `countThreeDDishes()` and a pure `evaluateSubscriptionGate()`.
- [ ] Add gate codes `SUBSCRIPTION_REQUIRED` and `SUBSCRIPTION_CAPACITY_EXCEEDED` to
      `PublishGateCode`, wired into `evaluatePublishGates` **behind** the server flag
      `subscriptionGatesEnabled`.
- [ ] Record the snapshot's 3D-dish count on `CatalogPublishRun` for audit (never blocking).
- [ ] Add a one-shot script that grandfathers every provisioned catalog as `COMPED` for 30 days.
- [ ] Add the two gate codes + copy to the Flutter `PublishGateCode` enum so an app already in the
      store renders the rows correctly when Stage 5 flips the flag.
- [ ] Tests for all of the above.

## Files to Inspect First

1. `recapture-api/src/services/catalogPublishService.ts` — `PublishGateCode` (line ~55),
   `PublishGate`, `publishableProducts()`, `evaluatePublishGates()` (line ~385), and how
   `requestPublish` returns `{ outcome: 'BLOCKED', gates }`.
2. `recapture-api/src/models/types/catalog.types.ts` — `effectiveModelStatus()`,
   `isModelPending()`, `PRODUCT_TYPES`. **Never read `modelStatus` raw.**
3. `recapture-api/src/models/Catalog.ts` and `CatalogPublishRun.ts` — field/index/comment style
   to match; note `activePublishRunId` and revision counters are worker-owned.
4. `recapture-api/src/services/remoteConfigService.ts` — `getServerFlag()` (the ops-flag
   pattern you will reuse) and why `remoteConfigSchema` must NOT gain unvalidated keys.
5. `recapture-api/src/models/ClientConfig.ts` — the `strict: false` store document.
6. `recapture-api/src/worker/processors/mirageCatalogPublishProcessor.ts` line ~282 — where
   `takeCatalogSnapshot` is called; you add one audit write after it.
7. `recapture-api/src/services/catalog/publishSnapshot.ts` — `CatalogSnapshotProduct` shape.
8. `recapture-api/scripts/set-user-role.ts` and `scripts/normalize-catalog-names.ts` — script
   conventions (env load, connect, dry-run flag, summary print).
9. `recapture-api/tests/catalog-publish-api.test.ts` and `tests/helpers/` — how a catalog with
   products is seeded and how gates are asserted.
10. `lib/domain/catalog/publish_gate.dart` — the client enum you extend; note `unknown` fallback.
11. `lib/presentation/widgets/catalog/publish_body.dart` — `PublishVoice` and `_GateChecklist`
    (only to find where per-code copy lives; do not restyle).

## Implementation Instructions

### Step 1: Types — `src/models/types/subscription.types.ts`

Create the file. Export, as `as const` tuples + derived types, in the house style of
`catalog.types.ts`:

```ts
export const SUBSCRIPTION_STATUSES = ['TRIAL','ACTIVE','GRACE','PAUSED','CANCELLED','COMPED'] as const;
export const PLAN_IDS = ['TASTE','SIGNATURE','MASTERCHEF'] as const;
export const BILLING_INTERVALS = ['MONTHLY','YEARLY'] as const;
export const SUBSCRIPTION_SOURCES = ['ONLINE','MANUAL','COMP','TRIAL'] as const;
export const PAYMENT_KINDS = ['CHECKOUT_CREATED','PAID','MANUAL','COMP','REFUNDED','DISPUTED'] as const;
export const VERIFICATION_STATUSES = ['PENDING_VERIFICATION','VERIFIED','REJECTED'] as const;
export const MANUAL_METHODS = ['CASH','BANK_TRANSFER','CHEQUE','UPI'] as const;
export const PLAN_FEATURES = ['whatsapp_instagram_buttons','website_embed','per_dish_analytics','priority_support'] as const;

export interface PlanDefinition {
  planId: PlanId;
  displayName: string;
  priceMonthlyPaise: number;   // integer
  yearlyDiscountPct: number;   // 30
  threeDDishCap: number;
  includedStandeeCount: number;
  features: readonly PlanFeature[];
}
export interface PlanCatalog {
  plans: Record<PlanId, PlanDefinition>;
  trialDays: number; trialThreeDCap: number; graceDays: number;
  grandfatherDays: number; orderTtlHours: number;
}
export interface Actor { userId: Types.ObjectId; role: UserRole; }
```

`SUBSCRIPTION_SOURCES` gains `TRIAL` (the plan lists ONLINE/MANUAL/COMP; a trial period needs a
source value too — do not overload `COMP`).

Add `yearlyPricePaise(plan: PlanDefinition): number` =
`Math.round(plan.priceMonthlyPaise * 12 * (100 - plan.yearlyDiscountPct) / 100)`. Integer paise,
no display rounding here (AC-8.1).

### Step 2: Plan catalog — `src/config/subscriptionPlans.ts` + `src/services/subscription/planCatalogService.ts`

- `subscriptionPlans.ts`: `DEFAULT_PLAN_CATALOG: PlanCatalog` with the README constants, and
  `planCatalogSchema` (Zod, `.strict()`, every number `.int().positive()`, `plans` keyed by
  `z.enum(PLAN_IDS)` — all three required).
- `planCatalogService.ts`: `getPlanCatalog(): Promise<PlanCatalog>`. Read
  `ClientConfig.findOne().sort({ updatedAt: -1 }).lean()`, take `doc?.subscriptionPlans`; if
  absent → defaults; if present but fails `planCatalogSchema.safeParse` → `console.warn` with the
  issue path and serve defaults (reject-to-defaults, whole-object, exactly like
  `getRemoteConfig`). **Never throw for a store problem.** Do not touch `remoteConfigSchema` or
  the served `candidate` object in `getRemoteConfig` — that is Stage 2.

### Step 3: `CatalogSubscription` model — `src/models/CatalogSubscription.ts`

Fields (all from §10; comment each like `Catalog.ts` does):

| Field | Type / rule |
|---|---|
| `catalogId` | ObjectId ref Catalog, required, **unique index** (one per catalog) |
| `status` | enum `SUBSCRIPTION_STATUSES`, required |
| `planId` | enum `PLAN_IDS`, optional (absent on TRIAL and COMPED) |
| `planSnapshot` | `PlanDefinition` subdocument (`_id: false`), optional; **required when `status` is ACTIVE or GRACE-from-ACTIVE** — enforce in the service, not the schema |
| `billingInterval` | enum, optional |
| `periodStart`, `periodEnd` | Date, required |
| `graceEndsAt` | Date, optional; set only when status becomes GRACE, always `periodEnd + graceDays` calendar days (UTC) |
| `trialUsedAt` | Date, optional — set once, never cleared |
| `trialActivatedBy` | `{ userId, role }` subdoc, optional |
| `source` | enum `SUBSCRIPTION_SOURCES`, required |
| `threeDDishCap` | Number, required — the cap **in force** (trial cap, plan cap, or `null` for COMPED = uncapped; store `-1` for uncapped and expose a helper `isUncapped`) |
| `standeeAllocation` | `{ included: Number, issued: Number }`, default `{0,0}` |
| `pausedAt`, `cancelledAt`, `arEntitlementSyncedAt` | Date, optional (the last is used in Stage 5) |
| timestamps | yes |

Indexes: `{ catalogId: 1 }` unique; `{ status: 1, periodEnd: 1 }`; `{ status: 1, graceEndsAt: 1 }`
(the Stage 5 sweeps).

Export `isEntitledTo3D(status)` → `true` for TRIAL/ACTIVE/GRACE/COMPED, `false` otherwise.

### Step 4: `PaymentRecord` model — `src/models/PaymentRecord.ts`

Append-only ledger. Fields per §10: `catalogId`, `subscriptionId`, `kind`, `amountPaise` (int,
`min: 0`), `currency` (default `'INR'`), `quote` (`{ planId, planSnapshot, interval, totalPaise }`,
optional), `providerOrderId`, `providerPaymentId`, `providerRefundId`, `idempotencyKey`
(**unique, partial on `$type: 'string'`**), `initiatedBy: Actor`, `collectedBy?: Actor`,
`method?` (enum `MANUAL_METHODS`), `verificationStatus?`, `verifiedBy?: Actor`, `verifiedAt?`,
`refundsPaymentId?` (ObjectId ref PaymentRecord), `reference?` (max 200), `note?` (max 1000),
`expiresAt?` (CHECKOUT_CREATED only; Stage 3 sets `+orderTtlHours`), timestamps.

Indexes: `{ catalogId: 1, createdAt: -1 }`; `{ providerOrderId: 1 }` unique partial;
`{ kind: 1, verificationStatus: 1 }`; `{ catalogId: 1, kind: 1, verificationStatus: 1 }`.

No `pre('save')` hooks. Immutability is a service rule (Stage 3), not a schema hook.

### Step 5: 3D count — `src/services/subscription/threeDDishCount.ts`

```ts
export function countsAsThreeD(p: { modelStatus?: ProductModelStatus; assets?: { glbUrl?: string } }): boolean
  // effectiveModelStatus(p) === 'READY' — and ONLY that (§3b)
export function countThreeDDishes(products: readonly <same shape>[]): number
```

Pure; no IO. Callers pass an already-filtered list (`publishableProducts()` at request time,
`snapshot.products` in the worker). Do **not** re-filter `deletedAt`/`archivedAt` inside — that
keeps the two callers' counts derived from the same list the publish sends (README C1).

### Step 6: The gate — `src/services/subscription/subscriptionGate.ts`

```ts
export type SubscriptionGateInput = {
  subscription: Pick<ICatalogSubscription,'status'|'threeDDishCap'|'planId'|'planSnapshot'> | null;
  threeDDishCount: number;
};
export function evaluateSubscriptionGate(input): PublishGate[]   // 0 or 1 gates
```

Rules, in order:

1. `subscription === null` → `SUBSCRIPTION_REQUIRED`, message
   `"No subscription yet — start a free trial or activate a plan to publish."` (blocks
   regardless of dish mix, §5).
2. `status` PAUSED or CANCELLED: if `threeDDishCount >= 1` → `SUBSCRIPTION_REQUIRED`, message
   `"Your 3D menu needs an active plan. Photo-only menus can still be published."`; if `0` →
   no gate (README C5).
3. `status` TRIAL/ACTIVE/GRACE/COMPED: if `threeDDishCap >= 0 && threeDDishCount > threeDDishCap`
   → `SUBSCRIPTION_CAPACITY_EXCEEDED`, message built as
   `"Menu has ${count} 3D dishes; your ${planLabel} covers ${cap}. Upgrade to publish all of them."`
   where `planLabel` is `planSnapshot.displayName` or `"free trial"`. Include a `meta`
   object on the gate: `{ threeDDishCount, threeDDishCap, planId }` — extend `PublishGate` with an
   optional `meta?: Record<string, string | number>` for this.
4. Otherwise no gate. GRACE never produces a gate (the banner is a status concern, Stage 2).

Add `SUBSCRIPTION_REQUIRED` and `SUBSCRIPTION_CAPACITY_EXCEEDED` to `PublishGateCode` in
`catalogPublishService.ts` with a one-line doc comment each.

### Step 7: Wire into `evaluatePublishGates` behind the flag

In `evaluatePublishGates`, after the existing `Promise.all` of DB gates:

```ts
if (await isSubscriptionGateEnabled()) {
  const subscription = await CatalogSubscription.findOne({ catalogId: catalog._id }).lean();
  gates.push(...evaluateSubscriptionGate({ subscription, threeDDishCount: countThreeDDishes(live) }));
}
```

`isSubscriptionGateEnabled()` lives in `subscriptionGate.ts`: `getServerFlag('subscriptionGatesEnabled') === true`,
and — because `getServerFlag` throws on a store failure — catch, `console.warn`, and return
`false`. A config outage must never block publishing (this is the opposite fallback from
`PUBLISHING_UNAVAILABLE`, deliberately: an outage should not invent a paywall).

Order matters: the subscription gate is **last** so the checklist keeps its existing row order.

### Step 8: Audit count on the run

In `CatalogPublishRun.ts` add `threeDDishCount?: number` (worker-owned, comment it). In
`mirageCatalogPublishProcessor.ts` right after `takeCatalogSnapshot`, compute
`countThreeDDishes(snapshot.products)` and write it onto the run with the same update style used
for the run's other worker writes. No branching on it.

### Step 9: Grandfather script — `scripts/grandfather-catalogs-comped.ts`

For every `Catalog` with `deletedAt: null` and `mirageRestaurantId: { $type: 'string' }` and **no**
`CatalogSubscription` row: insert `{ status: 'COMPED', source: 'COMP', periodStart: now,
periodEnd: now + grandfatherDays, threeDDishCap: -1 }`. Use `insertOne` inside a try/catch on
E11000 (a concurrent run is a no-op, not an error). `--dry-run` prints the list and inserts
nothing. Print a summary `{ scanned, comped, skipped }`. Do not run it in this stage — it runs
at Stage 5 launch.

### Step 10: Client enum + copy

In `lib/domain/catalog/publish_gate.dart` add `subscriptionRequired` and
`subscriptionCapacityExceeded` to `PublishGateCode`, `apiValue`, `fromApiValue`. Wherever the
checklist derives a title/label per code (find it in `publish_body.dart` / the gate copy
switch), add rows: "Subscription needed" and "Plan limit reached". The Fix destination for both
codes is **`canFix: false` in this stage** (the screens do not exist yet); Stage 2 wires it.
`evaluateDraftGates` (client preview) must NOT attempt these codes — they are server-only.

## API / Data Contract

No new endpoints. Existing `POST /catalog/publish` 422 body gains two possible gate codes:

```json
{ "status": "error", "code": "PUBLISH_BLOCKED", "gates": [
  { "code": "SUBSCRIPTION_CAPACITY_EXCEEDED",
    "message": "Menu has 17 3D dishes; your Signature plan covers 15. Upgrade to publish all of them.",
    "meta": { "threeDDishCount": 17, "threeDDishCap": 15, "planId": "SIGNATURE" } }
]}
```

(Confirm the exact 422 envelope shape from `catalogPublishService`/`routes/catalog.ts` and keep it;
only the array element gains `meta`.)

## Analytics Events

Event: `publish_blocked_by_subscription`
Trigger: `evaluatePublishGates` emits ≥1 subscription gate (server side, in the gate wiring).
Properties: `catalog_id: string` (opaque), `gate_code: 'SUBSCRIPTION_REQUIRED' | 'SUBSCRIPTION_CAPACITY_EXCEEDED'`,
`subscription_status: SubscriptionStatus | 'NONE'`, `three_d_dish_count: number`,
`three_d_dish_cap: number`. Add the schema to `validation/analyticsSchemas.ts` (the
`satisfies Record<AnalyticsEventName, …>` clause will fail to compile until you do).

## What NOT to Change

- Do NOT change any existing `PublishGateCode` value, message, or order.
- Do NOT touch `remoteConfigSchema.ts`, `DEFAULT_REMOTE_CONFIG`, or the `candidate` object in
  `getRemoteConfig` — a new key there changes the client wire payload (Stage 2's job).
- Do NOT add fields to `Catalog.ts` — the subscription is its own document, one-to-one.
- Do NOT modify `publishableProducts()` or `isAwaitingFirstModel()`.
- Do NOT change `requestPublish`'s result union or the 422 mapping in `routes/catalog.ts` /
  `routes/rep.ts` beyond the optional `meta` field on a gate.
- Do NOT add Razorpay, SMS, or any provider code — Stage 3/4.
- Do NOT add the plan catalog to `env.ts` — it is data, not a secret.
- Do NOT run the grandfather script against any real database.

## Edge Cases to Handle

- [ ] `getServerFlag` throws (store down) → gate disabled for that request, `console.warn`,
      publish proceeds.
- [ ] `client_configs.subscriptionPlans` present but invalid → defaults served, warning logged,
      no throw.
- [ ] Legacy product with `modelStatus` undefined and a `glbUrl` → counts as 3D
      (`effectiveModelStatus` handles it; test it explicitly).
- [ ] THREE_D product with `modelStatus: 'PROCESSING'` and a previous `glbUrl` (replacement
      generating) → `effectiveModelStatus` returns PROCESSING → does **not** count. Test it.
- [ ] `threeDDishCap: -1` (COMPED) → never `SUBSCRIPTION_CAPACITY_EXCEEDED`.
- [ ] `subscription.status === 'GRACE'` with count over cap → still `SUBSCRIPTION_CAPACITY_EXCEEDED`
      (grace keeps full access, not extra capacity).
- [ ] Grandfather script: catalog already has a subscription → skipped, counted in `skipped`.

## Constraints

- All money fields are integer paise; a `Number` schema field for paise gets `validate:
  Number.isInteger`.
- All dates UTC; `graceEndsAt` = `periodEnd` + 7 × 86 400 000 ms — no timezone math.
- `evaluateSubscriptionGate` and `countThreeDDishes` are pure: no imports from `models/` other
  than types, no clock, no IO.
- Use `getServerFlag` for the switch; do not add a new env var for it (ops flips it without a
  deploy, matching the existing pattern).

## Acceptance Criteria

- [ ] `tsc --noEmit` and `npm run lint` pass with zero errors in `recapture-api`.
- [ ] `flutter analyze` passes at repo root.
- [ ] With no `subscriptionGatesEnabled` flag, every existing test in `tests/catalog-publish-*.test.ts`
      passes unchanged.
- [ ] With the flag `true` and no `CatalogSubscription` row, `POST /catalog/publish` returns 422
      containing exactly one `SUBSCRIPTION_REQUIRED` gate in addition to any other gates.
- [ ] With the flag `true`, status ACTIVE, cap 15, and 17 READY-model products, the 422 contains
      `SUBSCRIPTION_CAPACITY_EXCEEDED` with `meta.threeDDishCount === 17`.
- [ ] With the flag `true`, status PAUSED, and 0 READY-model products, publish is **not** blocked
      by a subscription gate.
- [ ] `countThreeDDishes` returns the same number for `publishableProducts(products)` and for
      `takeCatalogSnapshot(...).products` on the same seeded catalog (one test proves C1).
- [ ] `yearlyPricePaise(TASTE) === 1_007_160`, `SIGNATURE === 1_511_160`, `MASTERCHEF === 2_099_160`.
- [ ] `CatalogSubscription` rejects a second row for the same `catalogId` (E11000).
- [ ] `PaymentRecord` rejects a duplicate `idempotencyKey` and allows many rows with no key.
- [ ] `getPlanCatalog()` serves defaults when the doc key is absent and when it is malformed, and
      serves the override when valid.
- [ ] Grandfather script `--dry-run` against mongodb-memory-server inserts nothing and reports the
      correct counts; a real run inserts one COMPED row per provisioned catalog with
      `periodEnd - periodStart === 30 days`.
- [ ] Client: `PublishGateCode.fromApiValue('SUBSCRIPTION_REQUIRED')` round-trips; the checklist
      renders the server's sentence for both codes (widget test).

## Testing Instructions

1. `cd recapture-api && npm test` — add `tests/subscription-models.test.ts`,
   `tests/subscription-three-d-count.test.ts`, `tests/subscription-gate.test.ts`,
   `tests/subscription-plan-catalog.test.ts`, `tests/grandfather-comped.test.ts`. Seed the flag by
   inserting a `ClientConfig` doc with `subscriptionGatesEnabled: true` (it is `strict: false`).
2. Run the full backend suite once at the end; it must be green.
3. `flutter test test/catalog/` for the enum round-trip and checklist copy.
4. `tsc --noEmit`, `npm run lint`, `flutter analyze`.

## Assumptions

- Assumed: while PAUSED/CANCELLED, a publish with ≥1 3D-counting dish is blocked outright (README
  C5). If instead the product decision is "publish always proceeds, Mirage hides 3D", delete rule 2
  in Step 6 and nothing else changes.
- Assumed: `SUBSCRIPTION_SOURCES` includes `TRIAL`. If the plan's three-value list is required,
  store trials as `source: 'COMP'` and distinguish by `trialUsedAt` — the gate does not care.
- Assumed: `threeDDishCap: -1` encodes "uncapped". If a nullable field is preferred, change the
  schema and `isUncapped`; the gate reads only the helper.
