# Edge cases — the complete matrix (plan A–D + hardening E)

Every edge case the subscription layer must survive, with **where it is handled**. The plan's own
list (§8, A1–D10) is reproduced only as pointers; the **E series** is what the plan did not
cover — webhooks, the job queue, payment failures, and the "did not pay for days" lifecycle.

Rows marked **PATCHED** were missing from the stage prompts as first written and have now been
added to the named stage. Rows marked **Prompt B** are built by the prompt at the bottom of this
file. Nothing here is aspirational: each row names a file, a guard, or a decision.

---

## A–D — the plan's own cases (pointer table)

| # | Case | Handled in |
|---|---|---|
| A1–A9 | rep/staff cases | Stage 2 (trial), Stage 3 (manual, no rep payment), Stage 4 (A2 copy), Stage 5 (A9 card) |
| B1 | webhook never arrived | Stage 3 reconcile scan 2 |
| B2 | webhook twice | Stage 3 `idempotencyKey` + `appliedAt` (see E1/E2 — the first draft got this half right) |
| B3 | paid twice | Stage 3 `DUPLICATE_SUSPECTED` + admin refund |
| B4 | plan no longer fits | Stage 3 (honoured) + Stage 1 gate on next publish |
| B5–B8 | refund policy, price rise, INR, key mix-up | Stage 3 (refund route, frozen snapshot, `superRefine`), Gaps G6 (price-change notice) |
| B9 | chargeback | Gaps Prompt A (dispute webhooks) |
| C1–C9 | menu changes | Stage 1 (count rule, cap gate), Stage 2 (delete → CANCELLED), Gaps G5 (dialog copy) |
| D1–D10 | lifecycle | Stage 1 (grandfather), Stage 5 (sweep, D3/D4/D5), Stage 2 (D6 server `daysLeft`), Stage 3 (D7 503), Stage 5 Part B (D9/D10) |

---

## E — webhook, queue, payment-failure and lapse cases

### E-W: Webhook and reconciliation

| # | Case | What happens | Where |
|---|---|---|---|
| E1 | Webhook processed, PAID row inserted, process dies **before** `applyPaidPeriod`; Razorpay replays → idempotency key says "seen" → owner never activated. | PAID rows carry `appliedAt`. Replay loads the existing row and runs Phase 2 if `appliedAt` is null. | **PATCHED** Stage 3 Step 4 |
| E2 | Same as E1 but Razorpay's replay also fails or the webhook is disabled. | Reconcile scan 1: PAID rows with `appliedAt: null` older than 2 min → Phase 2 re-run. No provider call needed. | **PATCHED** Stage 3 Step 5 |
| E3 | Razorpay created the order, our `CHECKOUT_CREATED` insert failed (DB blip / crash); owner pays; webhook says "unknown order". Money invisible — reconciliation only scans our rows. | Webhook reads the `notes {catalogId, planId, interval}` **we** wrote at order create, rebuilds the quote, activates if amount matches; otherwise `UNKNOWN_ORDER` row + admin alert. Never 4xx. | **PATCHED** Stage 3 Step 4 |
| E4 | Our endpoint 5xx'd repeatedly → Razorpay **disables the webhook** silently. From then on only reconciliation sees payments. | Reconcile counts `rescuedByReconcile`; > 0 in two consecutive runs → `alertAdmins('WEBHOOKS_SILENT')`. Manual fix: re-enable in Razorpay Dashboard → Webhooks. | **PATCHED** Stage 3 Step 5; runbook §3.1 |
| E5 | Payment arrives for a catalog that was **deleted** (`DELETE /catalog` while an order was open, or a late UPI collect). | `ORPHAN_PAYMENT` PAID row, no activation, admin alert. This **is** a refund case (money for nothing) — admin refunds with `override: true` + note; document it as the second legitimate refund reason beside B3. | **PATCHED** Stage 3 Step 4; decision noted below |
| E6 | `payment.authorized` arrives but never `captured` (auto-capture off in the dashboard) → funds held 5 days then auto-refunded by Razorpay; we would have activated on the wrong event. | Handler ignores `payment.authorized`. **Manual:** Razorpay Dashboard → Settings → Payment capture → **auto-capture ON**. | Stage 3 (ignores unknown events); runbook §3.1 |
| E7 | Owner completes a pending UPI collect **hours after** the 24 h order `expiresAt`. | Razorpay orders do not expire; the webhook still matches the row; quote honoured. Reconcile scan 3 covers a missed webhook on an expired order for 48 h. | **PATCHED** Stage 3 Step 5 |
| E8 | Owner's UPI fails three times; rate window 10/h on order create locks them out. | Window consumed only when a **new** Razorpay order is created; returning the open one is free. `payment.failed` webhook → analytics only, order stays open. | **PATCHED** Stage 3 Steps 3–4 |
| E9 | Owner pays early (20 days left) and loses 20 days (fresh-period rule). | Order response carries `daysForfeited`; client shows "Your current period ends in 20 days — paying now starts a new period today" above Pay. Rule itself unchanged (AC-3.5, A2). | **PATCHED** Stage 3 Step 3; client copy → Prompt B |
| E10 | Owner pays during TRIAL / COMPED. | Fresh period from `paidAt`; trial/comp ends early; `trialUsedAt` stays. | **PATCHED** Stage 3 Step 2 |
| E11 | PAUSED restaurant with 30 published 3D dishes buys **Taste** (cap 10) → resume shows all 30. The cap is only checked at publish, so "never republish" is a loophole. | Activation is not blocked (plan §3a). Owner gets an in-app notice; admin sees `subscription_over_cap_on_activate`. Product may later choose per-dish hiding (Stage 6). | **PATCHED** Stage 3 Step 2; decision noted below |
| E12 | Rep types ₹1,000 for a ₹1,199 plan in a cash request; admin verifies without noticing. | VERIFY refuses on `amountPaise ≠ quote.totalPaise` unless `override: true` + note ≥ 20 chars. | **PATCHED** Stage 3 Step 6 |
| E13 | Cash verified by admin **and** owner paid online for the same period. | Second one is flagged `DUPLICATE_SUSPECTED` (whichever lands second). If the duplicate is the cash one it cannot be refunded via Razorpay — admin refunds cash by hand and records a `REFUNDED` row with no `providerRefundId` (`override` path). | Stage 3 duplicate rule; Prompt B (manual-refund row) |
| E-W1 | `refund.processed` / `refund.failed` — an admin-issued refund fails asynchronously at Razorpay. | Webhook updates the REFUNDED row's `note`; failed → admin alert. | **PATCHED** Stage 3 Step 4 |
| E-W2 | Two workers reconcile the same order at once. | Both converge on the same `idempotencyKey`; `appliedAt` conditional write makes activation single-shot. | Stage 3 Step 4 |
| E-W3 | Webhook arrives during a Render cold start and Razorpay times out. | Razorpay retries with backoff; our handler is idempotent; reconcile is the backstop. Keep the handler free of provider calls so it answers in < 5 s. | Stage 3 Constraints |
| E-W4 | Amount in the webhook ≠ our quote (tampered client, currency drift). | `AMOUNT_MISMATCH` row, no activation, admin alert. | Stage 3 Step 4 |

### E-Q: Job queue and the sweep

| # | Case | What happens | Where |
|---|---|---|---|
| E14 | Owner did not pay for days: nothing warns them before 3D pauses, because SMS/WhatsApp reminders are Stage 6. | The sweep writes **in-app** reminders at −7 d, −1 d, on GRACE, grace-midpoint, deduped through `ReminderLog`. Rep nudge (Stage 4) covers owners who never open the app. | **PATCHED** Stage 5 Step 3 |
| E15 | Catalog is provisioned in Mirage for the first time **while PAUSED** (photo-only publish is allowed) → Mirage default `arEnabled: true` → entitled while unpaid. | Provisioning enqueues an entitlement job with the current desired state when a non-entitled row exists. | **PATCHED** Stage 5 Step 3b |
| E16 | TRIAL or COMPED expires → GRACE banner says "payment overdue" — wrong words for a trial. | `graceFrom` stored on the transition; three copy variants. | **PATCHED** Stage 5 Step 3; copy → Prompt B |
| E17 | Render instance sleeps → worker loop stops → no sweep, no reconcile for hours. | Late is the safe direction; but keep the instance awake (`axiosBackendMakeAlive.ts` / Render cron) or accept lateness. Runbook step. | **PATCHED** Stage 5 Step 3; runbook §3.2 |
| E18 | Entitlement job exhausts its attempts (Mirage down for long) → job FAILED; a **resume** that failed leaves a paid owner without 3D. | Terminal failure → admin alert; admin `resync-ar`; `arEntitlementSyncedAt` visible on the admin detail screen so staleness is seen. | **PATCHED** Stage 5 Step 2 |
| E19 | Pause job and resume job both queued (owner paid seconds after the sweep enqueued the pause). | Processor re-reads desired state and aborts as success when the payload disagrees; the later job wins. | Stage 5 Step 2 (D4) |
| E20 | Sweep runs on two instances at once / runs twice. | Conditional per-row updates; job idempotency key includes `updatedAt`. | Stage 5 Step 3 |
| E21 | Sweep tick lands while a publish is mid-run. | Sweep never reads `activePublishRunId`; publish finishes; next publish sees the new state (D5). | Stage 5 What NOT to Change |
| E22 | Admin clicks **Extend grace** at the same moment the sweep pauses. | Conditional update → 409 `NOT_IN_GRACE`; admin comps instead. | Stage 3 Step 7 |
| E23 | PAUSED forever (owner gone). Data retention? | Nothing is ever deleted (AC-4.3). Collections list gains `PAUSED_90D` for follow-up; no auto-purge. | Prompt B |
| E24 | Entitlement job for a catalog whose `mirageRestaurantId` is absent. | Succeeds as no-op. | Stage 5 Step 2 |
| E25 | Worker claims a resume job but the lease expires mid-Mirage-call. | Heartbeat renews the lease (existing `renewClaim`); worst case a second run of an idempotent `PUT`. | existing worker; Stage 5 Constraints |

### E-L: Lapse lifecycle ("did not pay for some days")

The full path, with the exact moment each side changes:

```
periodEnd − 7 d   in-app reminder (E14)              owner bell
periodEnd − 1 d   in-app reminder                    owner bell
periodEnd         sweep: → GRACE, graceEndsAt = +7 d  owner/rep banners; publish still allowed;
                  in-app reminder                    3D still live
graceEndsAt − 3 d in-app reminder (midpoint)         rep list shows "Overdue 3d"
graceEndsAt       sweep: → PAUSED, enqueue job       Mirage arEnabled=false within one poll;
                                                     photo menu live; 3D-dish publish blocked
(any time)        owner pays / admin verifies cash   → ACTIVE, fresh period, resume job,
                                                     3D back within one poll
```

| # | Case | What happens | Where |
|---|---|---|---|
| E26 | Owner pays on day 3 of GRACE. | ACTIVE at once, `periodStart = paidAt`, nothing was disabled. | Stage 3 Step 2 (AC-3.3) |
| E27 | Owner pays 1 minute after the pause job was enqueued but before it ran. | Pause aborts (desired = entitled); resume job runs → `arEnabled: true` (already true) → no-op. | Stage 5 Step 2 |
| E28 | Owner pays 1 minute **after** the pause ran. | Resume job → `arEnabled: true` within one worker poll; no republish. | Stage 5 Step 4 (AC-4.4) |
| E29 | Owner pays for a **different plan** than before while PAUSED. | `planSnapshot` replaced; cap changes; E11 notice if over cap. | Stage 3 Step 2 |
| E30 | Owner ignores everything; 3 months PAUSED; rep starts a new trial? | Refused — `trialUsedAt` set (AC-2.4). Rep must nudge or admin comps. | Stage 2 |
| E31 | GRACE → owner **deletes** the catalog. | CANCELLED; Mirage restaurant deleted by the existing delete path; no job. | Stage 2 |
| E32 | Grandfathered (COMPED) restaurant's 30-day window ends. | → GRACE (`graceFrom: COMPED`, "Complimentary period ended") → PAUSED like any plan. | Stage 5 (C4) |
| E33 | Owner on an old app build when the flag flips. | Gate rows render (Stage 1 enum) but Fix may be missing; runbook waits ≥ 48 h after the Production rollout. | Stage 5 rollout |
| E34 | Month length: 30 days flat, so a Jan 31 payment ends Mar 2; yearly is 365 days, leap years ignored. | Deliberate simplicity; stated on the checkout sheet ("30 days" / "365 days"), never "1 month". | Stage 3 Step 2; copy → Prompt B |

### E-2: Second pass — auth, identity, config, Mirage, client, ops

Found by walking the code paths a second time (auto-publish, retry, offline queue, admin roles,
Mirage's partial update, refunds made outside our API).

| # | Case | What happens | Where |
|---|---|---|---|
| E35 | **A 3D model finishes generating while the catalog is PAUSED or at its cap.** `catalogModelPromotionService` and the finalize sweep call the gated `requestPublish`; with the flag on it returns `BLOCKED` and the service only logs it — the dish is ready, nobody is told, the rep thinks it failed. | Blocked-by-subscription branch creates an owner in-app notification ("model ready — publish needs an active plan / upgrade"), deduped per product. | **PATCHED** Stage 5 Step 3a |
| E36 | The entitlement job's `updateRestaurant` body includes anything besides `arEnabled` (e.g. a well-meaning "sync the name too"). Mirage's update is partial; a `name` write renames the restaurant and **breaks every printed QR** (`customerUrl` resolves by name). | Body is exactly `{ arEnabled }`; a test asserts the argument keys. | **PATCHED** Stage 5 Step 2 |
| E37 | Rep submits a cash request; owner deletes the catalog; admin verifies a week later → `applyPaidPeriod` upserts ACTIVE onto a deleted catalog. | VERIFY refuses on a soft-deleted catalog (409 `CATALOG_DELETED`) and auto-rejects the row; `DELETE /catalog` rejects all pending requests. | **PATCHED** Stage 3 Step 6 |
| E38 | Admin refunds from the **Razorpay dashboard** instead of our route → `refund.processed` arrives for a refund we have no row for; ledger says "paid", Razorpay says "refunded". | Webhook inserts a `REFUNDED` row with `note: 'EXTERNAL_REFUND'` and alerts admins. | **PATCHED** Stage 3 Step 4 |
| E39 | The `/admin` router's default gate is `MODEL_ARTIST` — a 3D-artist role would see the revenue list and the manual-payment queue. | Every subscription admin route, **reads included**, carries `requireRole('ADMIN')`. | **PATCHED** Stage 3 Step 7 |
| E40 | Rep taps Start trial with no signal; the client's offline action queue (`offline_action.dart` / `offline_queue_box.dart`) replays it on reconnect — possibly twice, possibly after the rep left. | Subscription mutations never enter the offline queue; offline → "Needs a connection". | **PATCHED** Stage 2 What NOT to Change |
| E41 | Restaurant pays for one month, lapses to PAUSED, `trialUsedAt` was never set (they paid before any trial) → rep can start a **free 30-day trial after the paid period**. | `startTrial` refuses when any PAID / VERIFIED-MANUAL record exists (`TRIAL_NOT_ELIGIBLE`). Decision — recommended. | **PATCHED** Stage 2 Assumptions |
| E42 | Ops sets `yearlyDiscountPct: 100` (or 99) in the config override → yearly quote ₹0/₹1 → Razorpay rejects or the plan is free. | Schema bounds `0..90`; out of range → defaults served, warning logged. | **PATCHED** Stage 1 Step 2 |
| E43 | A leaked admin JWT loops the refund route. | Per-admin rate window (5/hour default) on refunds. | **PATCHED** Stage 3 Step 7 |
| E44 | Owner account was created by the rep and first opened months later → four stale "3 days left" reminders in the bell. | Reminder notifications carry `expiresAt`. | **PATCHED** Stage 5 Step 3 |
| E45 | `requestRetry` (retry failed rows) goes straight to `openRun` **without** gates. A catalog paused after a PARTIAL run can retry its failed 3D rows. | Deliberate: a retry re-sends rows of a run that was allowed when it started (plan C7 "the retry uses the same subscription", D5). Documented, not changed. | Stage 5 Step 3a |
| E46 | Mirage restaurant with `clientType: '3D_ONLY'` (no photos at all) gets paused → **every** card is a placeholder; the menu is technically "live" but useless. | Product decision: accept (D10 says placeholder) **or** admin comps such restaurants until they add photos. Flag in the admin PAUSED list: `photoCoverage: 0%`. | Decision below |
| E47 | An intermediary/CDN caches `get-data-for-new-ui` → `arEnabled: true` keeps serving after the pause. | Public reads answer `Cache-Control: no-store` (or `max-age ≤ 60`). | **PATCHED** Stage 5 Part B Step 1 |
| E48 | A chain owner with 3 outlets: one phone = one user = one catalog = one subscription (`Catalog.userId` unique). | Product constraint, not a bug: each outlet needs its own login number. Say so in the rep field guide. | Runbook §3.8 |
| E49 | Wrong owner phone fixed with `scripts/repoint-catalog-owner.ts` → catalog moves to a new `userId`. | Subscription is keyed by `catalogId` → survives; reminders/nudges read `catalog.userId` at send time → reach the new owner; an open order's `initiatedBy` points at the old user — harmless. Add one line to the script's header comment. | note only |
| E50 | Ops changes `graceDays` / `trialDays` in the override mid-period. | Stored `periodEnd` / `graceEndsAt` are unaffected; only future transitions use the new values. | by construction (Stage 1 model) |
| E51 | Owner has the app on two phones; pays on one. | The other re-reads `subscriptionProvider` on resume; until then it shows the old status — never a wrong *gate*, because gates are server-side. | Stage 3 Part B (resume re-read) |
| E52 | Dispute-grace and lapse-grace overlap (period ends during a dispute). | `disputeGraceAt` distinguishes; a lost dispute + expired period → PAUSED by the normal sweep; won + expired → GRACE stays until paid. | Gaps Prompt A Step 1 |
| E53 | Test-mode and live-mode webhooks share one URL. | Different secrets per mode; a test-mode event on the production host fails the signature (401, logged) and nothing is written. | Stage 3 Step 4; runbook §3.1 |
| E54 | Same restaurant is grandfathered COMPED **and** the rep starts a trial (rep did not notice). | `startTrial` → 409 `SUBSCRIPTION_ACTIVE`; comp continues. | Stage 2 Step 1 |
| E55 | Admin comps a catalog that is mid-GRACE from a dispute. | COMPED replaces the state; `disputeGraceAt` cleared; the dispute outcome later only writes ledger rows. | Gaps Prompt A Step 1 (clear on any apply) |

**Still not covered anywhere, on purpose (Stage 6 territory):** auto-renew mandates, SMS/WhatsApp
reminder delivery failures and DLT template rejections, per-dish "publish as image only", GST
invoice numbering, proration on upgrade, and multi-currency.

### Decisions surfaced by this pass (add to `gaps-addendum.md` § "Not buildable here")

- **E5 — orphan payment refund.** Recommend: allowed, admin `override` path, documented as the
  second exception to "non-refundable". Update plan §7 rule 9 wording.
- **E11 — over-cap on resume.** Recommend: accept for v1 (notice only). Revisit with the
  per-dish "publish without 3D" toggle in Stage 6.
- **E34 — 30/365-day periods vs calendar months.** Recommend: keep days; it is what the plan's
  copy says ("30 days").
- **E41 — trial after a paid period.** Recommend: refuse (`TRIAL_NOT_ELIGIBLE`); trials are for
  never-paid restaurants.
- **E46 — 3D-only restaurants when paused.** Recommend: accept the all-placeholder menu for v1 and
  have the rep add photos; admin may comp a partner pilot. Revisit with the Stage 6 per-dish toggle.

---

# Prompt B — HARDENING: Client copy for the E series, PAUSED_90D list, manual-refund ledger row
# Product: Mirage Menu (ReCapture backend + Flutter client)
# Scope: New Feature (small)
# Priority: Medium — run after Gaps Prompt A and before the Stage 5 flag flip

---

## Task Description

The backend halves of the E series are already inside Stages 3 and 5. This prompt adds the
pieces that are their own small unit of work:

- [ ] Client: early-renewal warning from `order.daysForfeited` (E9); three GRACE copy variants
      from `subscription.graceFrom` (E16); "30 days" / "365 days" wording on the checkout sheet
      (E34); the E11 over-cap notification renders via the existing bell (no new UI).
- [ ] Backend: `GET /admin/subscriptions?state=PAUSED_90D` (E23) — PAUSED with `pausedAt` older
      than 90 days.
- [ ] Backend: admin refund `override` path may record a **cash** refund: body
      `{ refundsPaymentId, note, override: true, manual: true, reference }` → `REFUNDED` row
      with no `providerRefundId`, no Razorpay call (E13). Only for MANUAL rows.
- [ ] Tests for every row above.

## Files to Inspect First

1. `recapture-api/src/services/subscription/checkoutService.ts`, `subscriptionService.ts`,
   `lifecycleSweep.ts` — the fields this prompt renders (`daysForfeited`, `graceFrom`).
2. `recapture-api/src/routes/admin.ts` — the refund and collections-list handlers from Stage 3.
3. `lib/domain/catalog/subscription_copy.dart` (Stage 2) — the copy table to extend.
4. `lib/presentation/screens/catalog/subscription_screen.dart`, `checkout_notifier.dart`.
5. `lib/presentation/widgets/catalog/publish_body.dart` — the GRACE banner slot (Stage 5).

## Implementation Instructions

### Step 1: Client copy

- `SubscriptionCopy.graceLine(graceFrom, daysLeft)`: `TRIAL` → "Your free trial has ended —
  choose a plan within N days to keep 3D live"; `COMPED` → "Your complimentary period has ended —
  choose a plan within N days"; `ACTIVE`/null → "Payment overdue — 3D menu pauses in N days".
  Use it on the catalog banner, publish banner, and rep chip tooltip.
- Checkout sheet: when `order.daysForfeited > 0` show an amber line above Pay: "Your current
  period ends in <n> days. Paying now starts a new <30-day|365-day> period today." Period wording
  everywhere is "30 days" / "365 days", never "month"/"year" alone.

### Step 2: `PAUSED_90D`

Extend the `state` enum of `GET /admin/subscriptions` with `PAUSED_90D` → filter
`{ status: 'PAUSED', pausedAt: { $lte: now - 90 d } }`, same DTO, sorted `pausedAt asc`. Add the
segment to the admin list screen.

### Step 3: Manual (cash) refund row

In the admin refund handler: if `manual: true`, the target row must be `kind: 'MANUAL'`,
`verificationStatus: 'VERIFIED'`; require `override: true`, `note` ≥ 30 chars, `reference`
(receipt / UPI txn id of the cash returned). Insert `REFUNDED` with `providerRefundId: undefined`,
`reference`, `note`; no Razorpay call; audit event `subscription_refund_issued { manual: true }`.
Refuse `manual: true` on a PAID (online) row → 422 `USE_PROVIDER_REFUND`.

## API / Data Contract

```
GET  /admin/subscriptions?state=PAUSED_90D
POST /admin/catalogs/:id/subscription/refund  body { refundsPaymentId, note, override?: true, manual?: true, reference?: string }
```

## What NOT to Change

- Do NOT alter `applyPaidPeriod`'s fresh-period rule — E9 is a warning, not a behaviour change.
- Do NOT add SMS/WhatsApp sends; E14 is in-app only until Stage 6.
- Do NOT auto-purge PAUSED data.

## Edge Cases to Handle

- [ ] `graceFrom` absent (row written before Stage 5 shipped) → the ACTIVE wording.
- [ ] `daysForfeited` absent (older server) → no warning line, Pay still works.
- [ ] `manual: true` without `reference` → 400 `INVALID_REQUEST`.

## Acceptance Criteria

- [ ] Widget tests render the three GRACE sentences from `graceFrom` fixtures and the amber
      early-renewal line only when `daysForfeited > 0`.
- [ ] No string "per month" / "per year" without "30 days" / "365 days" beside it on the checkout
      sheet (grep the widget tree in the test).
- [ ] `PAUSED_90D` returns only rows paused ≥ 90 days; a row paused 89 days is excluded.
- [ ] Manual refund on a VERIFIED MANUAL row creates one REFUNDED row with `reference` and no
      provider id; on a PAID row → 422; the subscription period is unchanged in both.
- [ ] `tsc --noEmit`, `npm run lint`, `flutter analyze`; suites green.

## Testing Instructions

1. `tests/subscription-paused-90d.test.ts`, `tests/subscription-manual-refund.test.ts`.
2. `test/catalog/subscription_grace_copy_test.dart`, `test/catalog/checkout_forfeit_warning_test.dart`.
3. Run each suite once at the end.
