# Stage 3 — Payments

Two prompts, two sessions. **Part A (backend)** ships alone and is inert without `RAZORPAY_*` env.
**Part B (client)** depends on A being deployed to the environment the app points at.

Product source: `RECAPTURE_SUBSCRIPTION_PLAN.md` §4 Doors 2–4, §7, §8-B, §10, §11, AC-5/6/7/8.
Gates stay **off** throughout this stage.

---

# Part A — NEW FEATURE: Razorpay in-app order + webhook, manual payments, comp, refund, collections list
# Product: Mirage Menu (ReCapture backend)
# Scope: New Feature
# Priority: Critical

---

## Task Description

- [ ] Razorpay provider seam (`providers/razorpay.ts`) with an injectable client for tests, keys
      in the fail-fast env loader, and a live/test key sanity check (B8).
- [ ] `POST /catalog/subscription/order` — create-or-return the one open order per catalog,
      frozen for 24 h, storing the quote.
- [ ] `POST /webhooks/razorpay` — signature-checked, idempotent, the **only** automated path that
      activates or renews.
- [ ] Reconciliation: `reconcileOpenOrders()` polls Razorpay for CHECKOUT_CREATED rows older than
      5 min (B1); expires rows past `expiresAt`.
- [ ] Manual payments: rep submits `PENDING_VERIFICATION`; ADMIN verifies/rejects; only VERIFIED
      activates (Door 3, AC-6).
- [ ] Comp (Door 4), duplicate-payment refund (AC-5), extend-grace, and
      `GET /admin/subscriptions?state=` (collections list).
- [ ] One activation primitive, `applyPaidPeriod()`, used by webhook, manual-verify and comp —
      so "fresh period from payment date" (AC-3.5) and "PAUSED → ACTIVE restores 3D" (AC-4.4) are
      implemented once.

## Files to Inspect First

1. `recapture-api/src/services/subscription/subscriptionService.ts` and the two models —
   Stage 1/2 output.
2. `recapture-api/src/config/env.ts` — Zod env; the `MESHY_API_KEY … .optional()` pattern and
   how a required-in-production check is expressed (search `superRefine`/`NODE_ENV`).
3. `recapture-api/src/worker/engine/meshy/meshyClient.ts:67-240` — the injectable-client seam
   (`MeshyClient` interface, `setMeshyClient`, `getMeshyClient`, `resetMeshyClient`) to copy for
   Razorpay.
4. `recapture-api/src/app.ts:68-105` — `express.json` is mounted **before** routers; the webhook
   needs the raw body for HMAC. See how `routes/rep.ts` imports `raw` from express for the logo
   bytes route.
5. `recapture-api/src/models/Job.ts` + `src/services/jobsService.ts` — idempotency-key replay
   pattern (E11000 → replay the winner).
6. `recapture-api/src/routes/admin.ts` — `requireRole('ADMIN')` per route; `services/adminUsersService.ts`
   for the audited-admin-action style (`track` with hashed ids).
7. `recapture-api/src/utils/rateLimit.ts` — `consumeRateWindow`.
8. `recapture-api/src/validation/repSchemas.ts`, `adminSchemas.ts` — where the new Zod bodies go.
9. `recapture-api/src/worker/worker.ts` — the `while + sleep` loop; where a periodic call to
   `reconcileOpenOrders` can be added (guard with an interval env, run at most every N ms).
10. `recapture-api/tests/jobs-create.test.ts` (idempotency), `tests/admin-project-owner.test.ts`
    (role + audit assertions).

## Implementation Instructions

### Step 1: Env + provider seam

`env.ts`: `RAZORPAY_KEY_ID: z.string().optional()`, `RAZORPAY_KEY_SECRET: z.string().optional()`,
`RAZORPAY_WEBHOOK_SECRET: z.string().optional()`, `SUBSCRIPTION_ORDER_RECONCILE_INTERVAL_MS`
(default `300_000`). Add a `superRefine`: in `NODE_ENV === 'production'`, if `RAZORPAY_KEY_ID` is
set it must start with `rzp_live_`; outside production it must **not** start with `rzp_live_`
(B8 — boot refuses either mix-up). All three keys present-or-absent together.

`providers/razorpay.ts`:

```ts
export interface RazorpayClient {
  createOrder(input: { amountPaise: number; currency: 'INR'; receipt: string; notes: Record<string,string> }): Promise<{ id: string; amount: number; status: string }>;
  fetchOrder(orderId: string): Promise<{ id: string; status: 'created'|'attempted'|'paid'; amount: number }>;
  fetchPaymentsForOrder(orderId: string): Promise<Array<{ id: string; status: string; amount: number }>>;
  createRefund(paymentId: string, input: { amountPaise: number; notes: Record<string,string> }): Promise<{ id: string; status: string }>;
}
export function isRazorpayConfigured(): boolean
export function setRazorpayClient / getRazorpayClient / resetRazorpayClient
export function verifyWebhookSignature(rawBody: Buffer, signature: string): boolean  // HMAC-SHA256 hex, timing-safe compare
```

Default implementation uses the official `razorpay` npm package (add to `package.json`), with
`key_id`/`key_secret` from env. `notes` carries only `{ catalogId, planId, interval }` — no phone,
no name (§7 rule 8).

### Step 2: The activation primitive — `subscriptionService.applyPaidPeriod`

```ts
export async function applyPaidPeriod(input: {
  catalogId: Types.ObjectId; planId: PlanId; interval: BillingInterval;
  source: 'ONLINE' | 'MANUAL' | 'COMP'; paidAt: Date; planSnapshot: PlanDefinition;
  standeeIncluded: number;
}): Promise<{ previousStatus: SubscriptionStatus | 'NONE'; subscription: ICatalogSubscription; needsArResume: boolean }>
```

- `periodStart = paidAt` **always** (AC-3.5 — never anchor on the old `periodEnd`, even when
  paying early; the plan says fresh period from payment date and this keeps one rule).
- `periodEnd = paidAt + (interval === 'YEARLY' ? 365 : 30) days` (calendar days, UTC).
- `$set`: `status: 'ACTIVE'`, `planId`, `planSnapshot`, `billingInterval`, `source`,
  `threeDDishCap: planSnapshot.threeDDishCap`, `graceEndsAt: null`, `pausedAt: null`,
  `cancelledAt: null`, `standeeAllocation.included: standeeIncluded` (issued untouched).
  `trialUsedAt` untouched. Upsert if no row (an owner may pay before any trial).
- `needsArResume = previousStatus in ['PAUSED','CANCELLED']` — Stage 5 consumes it by enqueueing
  the resume job; in this stage just return it and log.
- Paying while TRIAL or COMPED also starts a fresh period from `paidAt` (the trial/comp simply
  ends early; `trialUsedAt` stays). Stated once here so no caller special-cases it (E10).
- **Over-cap on resume (E11):** after the write, if the catalog's *published* 3D count
  (`countThreeDDishes` over products with `mirageItemId` set, not archived) exceeds
  `planSnapshot.threeDDishCap`, create an owner in-app notification "Your menu has N 3D dishes;
  <Plan> covers M. The next publish will ask you to upgrade." and `track('subscription_over_cap_on_activate')`.
  Do **not** block the activation or hide dishes — the cap is enforced at publish only (§3a);
  this is the honest nudge for the loophole.
- COMP variant: `applyComp({ catalogId, until, actor, note })` → `status: 'COMPED'`,
  `source: 'COMP'`, `threeDDishCap: -1`, `periodStart: now`, `periodEnd: until`, plus a
  `PaymentRecord{ kind:'COMP', amountPaise: 0, initiatedBy: actor, note }`.

### Step 3: In-app order — `services/subscription/checkoutService.ts`

`createOrReturnOrder(catalogId, actor, { planId, interval })`:

1. If `!isRazorpayConfigured()` → `{ outcome: 'UNAVAILABLE' }` (D7 → 503 `PAYMENTS_UNAVAILABLE`).
2. Open order = `PaymentRecord.findOne({ catalogId, kind: 'CHECKOUT_CREATED', expiresAt: { $gt: now } })`.
   If found → return it unchanged (§7 rule 3), even if the plan differs — the client shows the
   frozen quote and offers "cancel and re-quote" only after expiry. (Assumption A1.)
3. Else build the quote from `getPlanCatalog()`: `totalPaise = interval === 'YEARLY' ? yearlyPricePaise(plan) : plan.priceMonthlyPaise`.
4. `createOrder` at Razorpay with `receipt: 'cat_' + catalogId + '_' + Date.now()`.
5. Insert `PaymentRecord{ kind: 'CHECKOUT_CREATED', amountPaise: totalPaise, quote, providerOrderId,
   idempotencyKey: 'order:' + providerOrderId, initiatedBy: actor, expiresAt: now + orderTtlHours }`.
   On E11000 for `providerOrderId` (a double-tap that raced step 2) → re-read and return the
   winner (rule 2).
6. Return `{ outcome: 'OK', order: { providerOrderId, amountPaise, currency, keyId: env.RAZORPAY_KEY_ID, quote, expiresAt, currentPeriodEnd, daysForfeited } }`
   — `daysForfeited` = days left on the current ACTIVE/TRIAL/COMPED period that a payment now
   would discard (0 when GRACE/PAUSED/NONE); the client shows a warning above the Pay button
   when it is > 0 (E9).

Route `POST /catalog/subscription/order` (owner only — **not** on `/rep`, AC-6.5), body
`z.object({ planId: z.enum(PLAN_IDS), interval: z.enum(BILLING_INTERVALS) }).strict()`, rate
window `checkout:${catalogId}` 10/hour — **consumed only when a new Razorpay order is created**,
not when the open one is returned, so an owner retrying a failed UPI attempt is never locked out
(E8).

### Step 4: Webhook — `routes/webhooks.ts` + `services/subscription/webhookService.ts`

- Mount in `app.ts` **above** `express.json`: `app.use('/webhooks/razorpay', raw({ type: '*/*', limit: '256kb' }), webhooksRouter)`.
  Never let the JSON parser touch it — the HMAC is over the exact bytes.
- Handler: read `X-Razorpay-Signature`; if `!verifyWebhookSignature(req.body, sig)` → 401
  `INVALID_SIGNATURE`, and `track('razorpay_webhook_rejected', …)`. Then `JSON.parse` the body.
- Handle `event === 'payment.captured'` and `'order.paid'` (either can arrive first; both mean
  the same thing). Extract `orderId = payload.payment.entity.order_id`, `paymentId`, `amount`.
  Ignore every other event with 200 `{ status: 'success', ignored: true }`.
- `recordOnlinePayment({ orderId, paymentId, amountPaise, notes })` — **two phases, each
  idempotent on its own**, because the process can die between them:
  1. `checkout = PaymentRecord.findOne({ providerOrderId: orderId, kind: 'CHECKOUT_CREATED' })`.
     **If none** → do NOT give up: this is the "our insert failed after Razorpay created the
     order" case (E3 in `edge-cases-hardening.md`). Read `notes.catalogId / planId / interval`
     (we wrote them at order create). If all three parse and the catalog exists (not deleted),
     synthesise the quote from `getPlanCatalog()` and continue with `orphanOrder: true`; if the
     amount does not equal that quote, or notes are missing → insert a PAID row with
     `note: 'UNKNOWN_ORDER'`, `alertAdmins('UNKNOWN_ORDER')`, return 200. Never 4xx (Razorpay
     would retry, then disable the webhook).
  2. **Phase 1 — record.** Insert `PaymentRecord{ kind: 'PAID', idempotencyKey: 'payment:' + paymentId,
     providerOrderId, providerPaymentId, amountPaise, quote, initiatedBy, appliedAt: null }`.
     On E11000 → load the existing row instead of returning; **do not** return yet.
  3. **Phase 2 — apply, guarded by `appliedAt`.** If `paid.appliedAt` is set → 200, done (B2).
     Otherwise decide the outcome:
     - `amountPaise !== quote.totalPaise` → `note: 'AMOUNT_MISMATCH'`, no activation, `alertAdmins`.
     - catalog `deletedAt` set → `note: 'ORPHAN_PAYMENT'`, no activation, `alertAdmins` (this
       is a legitimate refund case — see the hardening file, E5).
     - subscription already ACTIVE with `periodStart >= checkout.createdAt` → `note: 'DUPLICATE_SUSPECTED'`,
       `track('subscription_duplicate_payment_flagged')`, no extension.
     - else `applyPaidPeriod({ source: 'ONLINE', paidAt: now, ... })`.
     Then **one** conditional write: `findOneAndUpdate({ _id: paid._id, appliedAt: null }, { $set: { appliedAt: now, note } })`.
     If that returns null another worker applied it first — fine, both paths are idempotent
     (`applyPaidPeriod` is an upsert-by-catalog with the same values).
  4. Close the CHECKOUT_CREATED row: `expiresAt: now`. (`appliedAt` and `expiresAt` are the two
     allowed post-insert writes on a ledger row, plus the MANUAL verification fields.)
- Always answer 200 once the signature is valid; failures after that are logged and left to
  reconciliation, which also scans **PAID rows with `appliedAt: null`** older than 2 min and
  re-runs Phase 2 on them (E2).
- Also handle `payment.failed` → `track('subscription_payment_failed', { catalog_id, error_code: payload.payment.entity.error_code })`,
  no ledger row, no state change (the open order stays open so the owner can retry; the client
  gets its failure from the SDK). And `refund.processed` / `refund.failed` → find the REFUNDED
  row by `providerRefundId` and set `note` to `REFUND_PROCESSED` / `REFUND_FAILED:<reason>`;
  failed → `alertAdmins('REFUND_FAILED')`. A `refund.processed` whose `providerRefundId` matches
  **no** REFUNDED row means someone refunded from the Razorpay dashboard directly: insert a
  REFUNDED row with `note: 'EXTERNAL_REFUND'`, `refundsPaymentId` resolved from the payment id,
  and alert admins — the ledger must never be less true than Razorpay's (E38).

### Step 5: Reconciliation — `services/subscription/reconcileService.ts`

`reconcileOpenOrders(now)` does three scans, in this order:

1. **Half-applied payments:** `PAID` rows with `appliedAt: null` and `createdAt < now - 2 min` →
   re-run Phase 2 of `recordOnlinePayment` (E2). This is the crash-recovery path; it needs no
   Razorpay call.
2. **Open orders:** each `CHECKOUT_CREATED` with `createdAt < now - 5 min` and `expiresAt > now`
   → `fetchOrder`; if `status === 'paid'` → `fetchPaymentsForOrder`, take the captured one, call
   `recordOnlinePayment` (idempotent, so a late webhook is harmless). Count these as
   `rescuedByReconcile`.
3. **Late payments on expired orders:** `CHECKOUT_CREATED` with `expiresAt` in the last 48 h and
   no PAID row for the same `providerOrderId` → same `fetchOrder` check (a UPI collect can be
   approved hours later; the quote is honoured, E7).

Rows with `expiresAt <= now` older than 48 h are left as-is. If `rescuedByReconcile > 0` in **two
consecutive** runs → `alertAdmins('WEBHOOKS_SILENT')`: Razorpay disables a webhook after repeated
non-2xx responses, and reconciliation catching payments is the only symptom (E4). Called from
the worker loop at most every `SUBSCRIPTION_ORDER_RECONCILE_INTERVAL_MS`; skipped entirely when
`!isRazorpayConfigured()`.

### Step 6: Manual payments (Door 3)

- Rep: `POST /rep/catalogs/:id/subscription/manual-payment-request`, body
  `{ planId, interval, amountPaise: int > 0, method: MANUAL_METHODS, reference: string(1..200), note?: string(≤1000), collectedByUserId?: ObjectId }`
  `.strict()`. If a `PENDING_VERIFICATION` row already exists for the catalog → return it with
  200 and `existing: true` (§7 rule 3, A5). Else insert
  `PaymentRecord{ kind:'MANUAL', verificationStatus:'PENDING_VERIFICATION', quote (frozen from
  plan catalog now), initiatedBy: rep, collectedBy: collectedByUserId ? {…} : rep }`. **No
  subscription write** (AC-6.1). Rate window `manual-request:${catalogId}` 5/hour.
- Admin: `POST /admin/catalogs/:id/subscription/manual-payment`, `requireRole('ADMIN')`, body
  `{ action: 'VERIFY' | 'REJECT', paymentRecordId, note? }` **or** `{ action: 'CREATE_AND_VERIFY', …request fields }`.
  VERIFY: `findOneAndUpdate({ _id, kind:'MANUAL', verificationStatus:'PENDING_VERIFICATION' }, { $set: { verificationStatus:'VERIFIED', verifiedBy: admin, verifiedAt: now } })`
  — if it returns null → 409 `ALREADY_DECIDED`. **Before** the update: if the catalog is
  soft-deleted → 409 `CATALOG_DELETED` and the request is auto-`REJECTED` with
  `note: 'CATALOG_DELETED'` (and `DELETE /catalog` itself rejects every pending request the same
  way — E37); if
  `record.amountPaise !== record.quote.totalPaise` the request must carry `override: true` and a
  `note` ≥ 20 chars, else 422 `AMOUNT_MISMATCH` (a rep typing ₹1,000 for a ₹1,199 plan is caught
  here, not after activation — E12). Only on that transition call
  `applyPaidPeriod(source:'MANUAL', paidAt: now, planSnapshot: record.quote.planSnapshot)` (AC-6.3).
  REJECT: same conditional update to `REJECTED` with `note`; no subscription write.
  Even when `initiatedBy.userId === verifiedBy.userId`, both are stored (AC-6.4).
- `GET /admin/subscriptions/manual-payments?status=PENDING_VERIFICATION` — the approval queue,
  newest first, with opaque `catalogId` + catalog display name; **no owner contact**.

### Step 7: Comp, extend grace, refund

- `POST /admin/catalogs/:id/subscription/comp` (ADMIN) body `{ until: ISO date > now, note: string }`
  → `applyComp`.
- `POST /admin/catalogs/:id/subscription/extend-grace` (ADMIN) body `{ days: int 1..30, note }` —
  only when `status === 'GRACE'`; `$set graceEndsAt: graceEndsAt + days`. Else 409 `NOT_IN_GRACE`.
- `POST /admin/catalogs/:id/subscription/refund` (ADMIN) body `{ refundsPaymentId, note: string(≥10) }`:
  1. Load the PAID row; it must belong to this catalog, have `providerPaymentId`, and carry
     `note: 'DUPLICATE_SUSPECTED'` **or** the admin body must include `override: true` with a
     note ≥ 30 chars (an escape hatch that is still ADMIN + audited, never automatic).
  2. Refuse if a REFUNDED row already references it (409 `ALREADY_REFUNDED`).
  3. `createRefund` at Razorpay for the full `amountPaise`; insert
     `PaymentRecord{ kind:'REFUNDED', amountPaise, refundsPaymentId, providerRefundId, initiatedBy: admin, note }`.
  4. **Never** touch the subscription period (the duplicate did not extend it).
  A MANUAL/COMP row is not refundable here (no provider id) → 422 `NOT_REFUNDABLE`.
  Rate window `admin-refund:${adminUserId}` — `ADMIN_REFUND_MAX_PER_WINDOW` (default 5) per
  `ADMIN_REFUND_WINDOW_SECONDS` (default 3600): a leaked admin token cannot drain the account in
  one loop, and a real admin never needs six refunds an hour (E43).
- `GET /admin/subscriptions?state=EXPIRING_7D|GRACE|PAUSED|TRIAL` — **`requireRole('ADMIN')`,
  including this read and the manual-payment queue.** The `/admin` router's default is
  MODEL_ARTIST, which is a 3D-artist role; revenue state is not theirs to see (E39) → list of `{ catalogId, catalogName, status, periodEnd, graceEndsAt, daysLeft, planId }`,
  cursor-paginated with `utils/cursor.ts`, sorted by `periodEnd asc`.

### Step 8: Ledger read for the owner

`GET /catalog/subscription/payments` (owner) → last 50 `PaymentRecord`s for the catalog as
`{ id, kind, amountPaise, currency, createdAt, method?, verificationStatus?, planId, interval, receiptNo }`
where `receiptNo = 'RC-' + last 8 of _id` (a simple receipt, §7 rule 7 — no GST). Refund rows
included so history is honest; no refund **action** anywhere on owner routes (AC-5.1).

## API / Data Contract

```
POST /catalog/subscription/order   (owner)   body { planId, interval }
→ 201 { status:'success', order: { providerOrderId, amountPaise, currency:'INR', keyId, quote:{planId, interval, totalPaise, planSnapshot}, expiresAt } }
→ 200 same shape when returning the existing open order (header X-Order-Reused: 1)
→ 503 { status:'error', code:'PAYMENTS_UNAVAILABLE', message:"Couldn't reach the payment service. Try again in a minute." }

POST /webhooks/razorpay   (raw body; header X-Razorpay-Signature)
→ 200 { status:'success' } | 401 INVALID_SIGNATURE

POST /rep/catalogs/:id/subscription/manual-payment-request → 201 { status, paymentRecord } | 200 {…, existing:true}
POST /admin/catalogs/:id/subscription/manual-payment       → 200 { status, paymentRecord, subscription? }
POST /admin/catalogs/:id/subscription/comp                 → 200 { status, subscription }
POST /admin/catalogs/:id/subscription/extend-grace         → 200 { status, subscription }
POST /admin/catalogs/:id/subscription/refund               → 201 { status, paymentRecord }
GET  /admin/subscriptions?state=…&cursor=…                 → 200 { status, items:[…], nextCursor }
GET  /admin/subscriptions/manual-payments?status=…         → 200 { status, items:[…] }
GET  /catalog/subscription/payments                        → 200 { status, payments:[…] }
```

## Analytics Events

`subscription_order_created` `{ catalog_id, plan_id, interval, amount_paise, reused: boolean }`
`subscription_payment_recorded` `{ catalog_id, source:'ONLINE'|'MANUAL'|'COMP', plan_id, amount_paise, previous_status, via:'WEBHOOK'|'RECONCILE'|'ADMIN' }`
`subscription_duplicate_payment_flagged` `{ catalog_id, payment_id_hash }`
`subscription_manual_payment_submitted` `{ catalog_id, actor_id_hash, method, amount_paise }`
`subscription_manual_payment_decided` `{ catalog_id, decision:'VERIFIED'|'REJECTED', admin_id_hash, same_actor: boolean }`
`subscription_refund_issued` `{ catalog_id, admin_id_hash, amount_paise, override: boolean }`
`razorpay_webhook_rejected` `{ reason:'SIGNATURE'|'UNKNOWN_ORDER'|'AMOUNT_MISMATCH' }`
Add each to `analyticsSchemas.ts`. No phone/email/name props anywhere.

## What NOT to Change

- Do NOT add any payment or refund route under `/rep` beyond `manual-payment-request` (AC-5.1,
  AC-6.5).
- Do NOT let any route other than the webhook, `reconcileOpenOrders`, admin manual-VERIFY, and
  admin comp call `applyPaidPeriod` — grep for it in the test.
- Do NOT move `express.json` in `app.ts`; mount the raw webhook route above it.
- Do NOT store card/UPI details, Razorpay `contact`/`email` fields, or the raw webhook body in
  Mongo — store ids and amounts only.
- Do NOT edit a `PaymentRecord` except: `verificationStatus/verifiedBy/verifiedAt` (once) and
  `expiresAt` on CHECKOUT_CREATED (close). Enforce in the service; no generic update helper.
- Do NOT touch `evaluatePublishGates` or the flag.
- Do NOT add Redis or a queue for webhooks; the unique `idempotencyKey` is the dedupe.

## Edge Cases to Handle

- [ ] Same webhook delivered twice → second inserts nothing, returns 200 (B2).
- [ ] `payment.captured` and `order.paid` both arrive → one PAID row (same `paymentId`).
- [ ] Webhook for an order created in Razorpay test mode against a prod DB → `unknownOrder`, 200,
      warned, nothing written.
- [ ] Owner double-taps Pay → second `createOrReturnOrder` returns the same `providerOrderId`.
- [ ] Owner pays while ACTIVE (early renewal) → fresh period from `paidAt` (documented cost: the
      unused days are lost — matches "fresh period from payment date"; see Assumption A2).
- [ ] Owner pays twice for the same period → second PAID row flagged `DUPLICATE_SUSPECTED`, period
      not extended, admin queue shows it.
- [ ] Payment amount differs from the quote → recorded, not activated, alerted.
- [ ] Razorpay unreachable on order create → 503 `PAYMENTS_UNAVAILABLE`, never a 500 (D7).
- [ ] Manual request when a pending one exists → the existing one returned, `existing: true`.
- [ ] Admin VERIFY twice → second gets 409 `ALREADY_DECIDED`; period applied once.
- [ ] Rep calls the admin verify route → 403 `FORBIDDEN` (AC-6.2).
- [ ] Refund on a row already refunded → 409; on a MANUAL row → 422.
- [ ] `RAZORPAY_KEY_ID=rzp_live_…` with `NODE_ENV=development` → boot fails with a clear message
      (B8), and vice versa.
- [ ] Reconcile finds `paid` for an order whose webhook is also in flight → both paths converge on
      the same `idempotencyKey`; exactly one activation.

## Constraints

- Amounts: integer paise end to end; Razorpay's `amount` is already paise — do not multiply.
- Signature check uses `crypto.timingSafeEqual` on equal-length buffers.
- The webhook route must be reachable without auth, without CORS preflight issues, and must
  return within 5 s (do the Razorpay `fetch*` calls only in reconciliation, never in the webhook).
- All new bodies `.strict()`; all new routes use the envelope.
- Ledger rows are inserted with `create`, never `updateOne … upsert`.

## Acceptance Criteria

- [ ] `tsc --noEmit`, `npm run lint` pass; `npm test` green.
- [ ] Boot with only `RAZORPAY_KEY_ID` set (no secret) fails fast with a message naming the
      missing keys; boot with none set succeeds and `POST …/order` returns 503.
- [ ] Order create → PaymentRecord `CHECKOUT_CREATED` with `expiresAt` 24 h out; second call within
      24 h returns the same `providerOrderId` (AC-7.1 — the body contains **no URL**).
- [ ] A correctly signed `payment.captured` webhook activates: `status:'ACTIVE'`,
      `periodStart === paidAt`, `periodEnd === paidAt + 30 d` (monthly) / `+ 365 d` (yearly),
      `planSnapshot.includedStandeeCount === 10/15/30` (AC-1.1, AC-1.2), `standeeAllocation.included` set.
- [ ] A tampered signature → 401 and no rows written.
- [ ] Webhook replay → no second PAID row, 200.
- [ ] Payment while GRACE → ACTIVE, `graceEndsAt: null`, `periodStart === paidAt` (AC-3.3, AC-3.5).
- [ ] Payment while PAUSED → ACTIVE and `needsArResume === true` in the service result (AC-4.4
      groundwork).
- [ ] Rep manual request → `PENDING_VERIFICATION`, subscription unchanged (AC-6.1); admin VERIFY →
      ACTIVE with `source:'MANUAL'`, `verifiedBy` and `initiatedBy` both present even when equal
      (AC-6.3, AC-6.4); rep VERIFY attempt → 403 (AC-6.2).
- [ ] Refund requires `refundsPaymentId` and ADMIN; creates exactly one REFUNDED row; subscription
      period unchanged (AC-5.1, AC-5.3, AC-5.4).
- [ ] `GET /admin/subscriptions?state=GRACE` lists only GRACE rows, paginated.
- [ ] Yearly quote `totalPaise === Math.round(priceMonthlyPaise * 12 * 0.70)` for all three plans
      (AC-8.1).
- [ ] `grep -rn applyPaidPeriod src/` shows callers only in webhookService, reconcileService, and
      the admin manual-payment / comp handlers (assert in a test by listing the import sites, or
      leave as a review checklist item).

## Testing Instructions

1. Fake the provider: `setRazorpayClient({...})` with scripted `createOrder`/`fetchOrder`/
   `createRefund`; generate webhook signatures in the test with the test secret from
   `vitest.config.ts`.
2. Suites: `tests/subscription-checkout.test.ts`, `tests/subscription-webhook.test.ts`,
   `tests/subscription-reconcile.test.ts`, `tests/subscription-manual-payment.test.ts`,
   `tests/subscription-admin-actions.test.ts`, `tests/env-razorpay-keys.test.ts`.
3. Run the full backend suite once at the end.
4. Manual (Razorpay test mode, `rzp_test_…` keys, `NODE_ENV=development`): create an order via
   curl, pay it in Razorpay's test checkout page, point a tunnel (e.g. `ngrok`) at
   `/webhooks/razorpay`, confirm ACTIVE. Then replay the webhook from the Razorpay dashboard and
   confirm no change.

## Assumptions

- A1: an open order is returned unchanged even if the owner picks a different plan within 24 h.
  If the product prefers "re-quote replaces the open order", close the old row (`expiresAt: now`)
  and create a new one — the idempotency rules do not change.
- A2: an early renewal starts a fresh period from `paidAt` (unused days lost). If "extend from
  current `periodEnd` when ACTIVE" is preferred, branch in `applyPaidPeriod` on
  `previousStatus === 'ACTIVE'` only — GRACE/PAUSED keep the fresh-period rule per AC-3.5.
- A3: `order.paid` and `payment.captured` are both subscribed in the Razorpay dashboard; the
  handler tolerates either.

---

# Part B — NEW FEATURE: In-app Razorpay checkout (owner), payment history, admin subscription screens
# Product: Mirage Menu (Flutter client)
# Scope: New Feature
# Priority: High

---

## Task Description

- [ ] Owner Subscription screen: fill `_CheckoutSlot` with **Pay / Renew / Upgrade** → in-app
      Razorpay checkout (`razorpay_flutter`) on Android/iOS; web build shows "Pay from the
      ReCapture mobile app" (README C7).
- [ ] Consent line + terms sheet before checkout: *"All payments are final, except an accidental
      duplicate payment, which will be refunded on review."* (AC-5.2).
- [ ] After the SDK reports success: show "Payment received, activating…" and poll
      `GET /catalog/subscription` (backoff 2 s → 10 s, up to 2 min) until `status` changes; never
      claim success from the SDK callback alone (§7 rule 1).
- [ ] Payment history list on the Subscription screen from `GET /catalog/subscription/payments`.
- [ ] Rep detail card: **Record cash payment** form → `manual-payment-request`; shows "Awaiting
      admin verification" while pending. No "mark paid".
- [ ] Admin screens (Flutter, under `/admin/subscriptions`): approval queue, per-catalog panel
      (state, ledger, Verify/Reject with the AC-5.2 notice, Comp until…, Extend grace, Refund
      duplicate), and the collections list by state.

## Files to Inspect First

1. `lib/presentation/screens/catalog/subscription_screen.dart` — Stage 2's `_CheckoutSlot`.
2. `lib/application/rep/rep_capabilities*.dart` — the conditional-import (io/web/stub) pattern
   you copy for the checkout adapter.
3. `lib/data/repositories/catalog_repository.dart`, `rep_repository.dart`,
   `admin_standee_repository.dart` (admin repo style), `catalog_failure.dart`.
4. `lib/presentation/screens/admin/admin_standees_screen.dart`, `admin_batch_detail_screen.dart`
   — admin list/detail style; `lib/presentation/screens/profile/` (~line 795) — where the admin
   entry tile lives.
5. `lib/application/catalog/publish_flow.dart` — the poll loop with backoff and lifecycle pausing
   to reuse for "activating…".
6. `lib/utils/analytics.dart` — `Analytics.logEvent`.
7. `android/app/build.gradle`, `ios/Podfile` — minSdk / platform for `razorpay_flutter`.

## Implementation Instructions

### Step 1: Checkout adapter (conditional import)

`lib/application/catalog/checkout_adapter.dart` (interface) + `checkout_adapter_io.dart`
(`razorpay_flutter`) + `checkout_adapter_web.dart` + `checkout_adapter_stub.dart`.
Interface: `Future<CheckoutOutcome> open({ required String keyId, required String orderId, required int amountPaise, required String description })`
→ `success(paymentId)` / `cancelled` / `failed(code, message)` / `unsupported`. `description`
= "<Plan> plan · monthly/yearly"; **no** `prefill.contact`/`email` (PII rule).

### Step 2: Notifier

`checkout_notifier.dart`: states `idle → quoting → showingSdk → activating → done | failed`.
Flow: `POST …/order` → adapter `open` → on `success` enter `activating` and poll
`subscriptionProvider` until `status` is ACTIVE (or `periodStart` changed) → `done`. Timeout →
show "Payment is being confirmed. You'll see it here shortly." and stop (the server reconciles;
never show "unpaid", B1).

### Step 3: Screen changes

- Button label: `Pay` when NONE/TRIAL/CANCELLED/PAUSED, `Renew` when ACTIVE/GRACE, `Upgrade`
  when the selected plan is higher than `planId`. One button, per §9.
- The selected plan/interval come from the comparison cards + toggle from Stage 2.
- On 503 `PAYMENTS_UNAVAILABLE` → inline "Couldn't reach the payment service, try again in a
  minute." (D7).
- Web: replace the button with a card "Pay from the ReCapture app on your phone."
- Payment history: `ListView` of `date · ₹amount · method · receipt no`; a REFUNDED row is shown
  as "Refund" in a muted style.

### Step 4: Rep cash form

Bottom sheet on the rep card: plan, interval, amount (₹ with two decimals → paise ×100,
integer), method (Cash / Bank transfer / Cheque / UPI), reference, note. Sends
`manual-payment-request`. Existing pending → sheet shows it read-only.

### Step 5: Admin screens

Routes `adminSubscriptions = '/admin/subscriptions'`, `adminSubscriptionDetail = '/admin/subscriptions/:catalogId'`.
- List: segmented filter Pending / Expiring 7d / In grace / Paused / Trial (maps to the two GET
  routes). Row: catalog name, chip, `daysLeft`.
- Detail: status card, ledger table, action buttons per Part A. Verify/Reject dialog shows the
  AC-5.2 notice and requires a note on Reject. Refund dialog requires a note ≥ 10 chars and shows
  the original payment.

## Analytics Events

Client: `checkout_opened { plan_id, interval, amount_paise, surface:'owner' }`,
`checkout_result { result:'success'|'cancelled'|'failed'|'unsupported' }`,
`checkout_activation_confirmed { seconds_to_confirm }`,
`rep_manual_payment_submitted { catalog_id, method }`,
`admin_manual_payment_decided { decision }`, `admin_refund_issued {}`.

## What NOT to Change

- Do NOT open a browser tab, `url_launcher`, or a WebView for payment (AC-7.2).
- Do NOT put a Pay/refund control on any rep screen.
- Do NOT persist order or payment data to Hive.
- Do NOT touch `PublishFlow`; copy its backoff shape into the checkout notifier instead.
- Do NOT add `accountPhone` to the checkout `prefill`.

## Edge Cases to Handle

- [ ] SDK success but poll never sees ACTIVE within 2 min → "being confirmed" state, screen stays
      usable, next open re-polls once.
- [ ] SDK cancelled → back to idle with the same open order (server returns it again).
- [ ] App backgrounded mid-checkout → on resume re-read `subscriptionProvider` before deciding
      state.
- [ ] Owner on web → no SDK call; card shown; `checkout_result: unsupported` logged.
- [ ] Rep enters ₹1,199.999 → reject at validation (two decimals max).
- [ ] Admin taps Verify twice → second shows the 409 sentence; list refreshes.

## Constraints

- `razorpay_flutter` only in `*_io.dart`; the web entry must compile without it.
- Amount display: `₹${(paise / 100).toStringAsFixed(2)}` unless whole rupees.
- Admin screens reuse the existing admin theme/components; no new design tokens.

## Acceptance Criteria

- [ ] `flutter analyze` and `flutter test` pass; web build (`flutter build web`) compiles.
- [ ] Android (mid-range, test keys): Pay → Razorpay sheet opens **inside the app** → test UPI
      success → "activating…" → status flips to Active within 30 s without leaving the app
      (AC-7.2).
- [ ] Consent line visible above the Pay button and in the pre-checkout sheet (AC-5.2).
- [ ] Rep app shows no Pay, no refund, no "mark paid"; cash form creates a pending request and
      the card says "Awaiting admin verification".
- [ ] Admin queue lists the pending request; Verify shows the AC-5.2 notice; after Verify the
      owner's screen shows Active on next refresh.
- [ ] Web build owner screen shows the "pay from the phone" card and no crash.
- [ ] No console errors during the full flow on Android Chrome remote-debug and on device.

## Testing Instructions

1. `flutter test` — `test/catalog/checkout_notifier_test.dart` with a fake adapter and a fake
   repository; `test/admin/admin_subscriptions_test.dart`; `test/rep/rep_cash_form_test.dart`.
2. Device run with `rzp_test_` keys against a dev backend; use Razorpay test UPI `success@razorpay`.
3. `flutter build web` to prove the conditional import compiles.

## Assumptions

- Assumed the admin screens live in the Flutter app (README C2). If a web admin is planned,
  Part A's routes are unchanged; only this part moves.
