✅✅✅✅✅✅✅✅✅✅✅

# Gaps — what the plan asks for that stages 1–5 do not build

Cross-check of `RECAPTURE_SUBSCRIPTION_PLAN.md` (§3–§11, §8 edge cases, §15 AC) against
`stage-01…05`. Everything in §11's route table, §9's screens, §10's fields and every AC has a
stage — **except the rows below.** Three are build work (Prompt A), two are copy edits folded into
Prompt A, and three are decisions/ownership the plan never assigned (§ "Not buildable here").

| # | Plan says | Where it should have landed | Status |
|---|---|---|---|
| G1 | **B9 — chargeback/dispute** → subscription to GRACE, admin alerted; `DISPUTED` ledger kind exists in §10 | Stage 3 webhook handles only `payment.captured` / `order.paid` | **Build** — Prompt A |
| G2 | **§10 `standeeAllocation`** "how many have been **issued/delivered**"; AC-1.1 grants 10/15/30 | Stage 3 sets `included`; nothing ever writes `issued`, nothing shows it | **Build** — Prompt A |
| G3 | **§7 rule 7 / §9** "receipt download" on the owner's payment history | Stage 3 has `receiptNo` only; no file | **Build** — Prompt A |
| G4 | **B1 / Step 4.3 of Stage 3** "alerted" on `AMOUNT_MISMATCH`, and B9's "admin is alerted" | Stage 3 says `console.error` + analytics — nobody gets paged | **Build** — Prompt A (in-app notification to every ADMIN) |
| G5 | **C9** "the confirm dialog for delete states this" (no refund) | Stage 2 cancels the row; `delete_catalog_dialog.dart` copy untouched | **Copy** — Prompt A |
| G6 | **B6** renewal quote "uses the new price **and says so**" | Stage 2 screen shows current plans; never compares to `planSnapshot` | **Copy** — Prompt A |
| G7 | **§6 table** `CANCELLED (owner asked)` — an owner cancel action | No route in §11, no button in §9, none in any stage | **Decision** — see below |
| G8 | **§3 note** public pricing page must read 10/15/30 standees | Not in `mirage-fe` (grep finds no plan names) — it is the marketing site | **External** — see below |
| G9 | **§13 item 7** upgrade proration is "TBD", yet Stage 3's `applyPaidPeriod` always starts a fresh full-price period | Stage 3 A2 | **Decision** — de-facto answered; confirm |

---

# Prompt A — NEW FEATURE: Dispute handling, standee issuance, receipts, admin alerts, two copy fixes
# Product: Mirage Menu (ReCapture backend + Flutter client)
# Scope: New Feature
# Priority: Medium — ship after Stage 3, before Stage 5's flag flip

---

## Task Description

- [ ] Webhook: handle `payment.dispute.created` → `PaymentRecord{kind:'DISPUTED'}`, subscription
      `ACTIVE → GRACE` (never straight to PAUSED), admin alert. Handle
      `payment.dispute.closed` with `status: 'won'|'lost'`: won → back to ACTIVE if still in the
      dispute-grace; lost → stays in GRACE and the sweep pauses it normally.
- [ ] `PATCH /admin/catalogs/:id/subscription/standees` → set `standeeAllocation.issued`
      (0 ≤ issued ≤ included), audited; shown on owner/rep/admin screens as "Standees 6 of 15
      delivered".
- [ ] `GET /catalog/subscription/payments/:paymentId/receipt` → a one-page PDF receipt built
      with `services/pdfPrimitives.ts`; owner-only; PAID/MANUAL(VERIFIED)/COMP rows only.
- [ ] `alertAdmins(kind, title, message, detail)` helper → one in-app notification to all
      users with `role: 'ADMIN'`; used for `AMOUNT_MISMATCH`, `DUPLICATE_SUSPECTED`, disputes,
      and entitlement-job terminal failures (Stage 5).
- [ ] Delete-catalog dialog: add the no-refund sentence when a subscription is ACTIVE/GRACE.
- [ ] Owner Subscription screen: when `planSnapshot.priceMonthlyPaise` differs from the current
      plan's price, the renewal card says "Your current price ₹X was locked until <periodEnd>.
      Renewals are ₹Y."

## Files to Inspect First

1. `recapture-api/src/services/subscription/webhookService.ts` — Stage 3's event switch and
   `recordOnlinePayment`.
2. `recapture-api/src/services/subscription/subscriptionService.ts` — `applyPaidPeriod`,
   `getSubscriptionStatus`; `lifecycleSweep.ts` (Stage 5) if already present.
3. `recapture-api/src/models/PaymentRecord.ts`, `CatalogSubscription.ts` — `DISPUTED` kind,
   `standeeAllocation`.
4. `recapture-api/src/services/notificationsService.ts:272` — `createNotification`; audience
   types are `ALL | USERS` only (`models/Notification.ts:21`), so admins are addressed as a
   `USERS` list.
5. `recapture-api/src/services/pdfPrimitives.ts` and `standeeSheetPdf.ts` — the PDF toolkit and a
   worked example of a generated PDF response.
6. `recapture-api/src/routes/admin.ts` — a `requireRole('ADMIN')` route with `track(...)` audit.
7. `lib/presentation/screens/catalog/delete_catalog_dialog.dart:137-200` — the bullet list of
   consequences.
8. `lib/presentation/screens/catalog/subscription_screen.dart` — plan cards + payment history.
9. `lib/domain/entities/catalog_subscription.dart` — add `standeeAllocation` and
   `planSnapshot.priceMonthlyPaise` if Stage 2 did not surface them.

## Implementation Instructions

### Step 1: Disputes (G1)

In the webhook switch add:

- `payment.dispute.created`: `paymentId = payload.dispute.entity.payment_id`. Find the PAID row
  by `providerPaymentId`; if none → 200 + `unknownOrder`-style warn. Insert
  `PaymentRecord{ kind:'DISPUTED', amountPaise: dispute.amount, providerPaymentId, idempotencyKey: 'dispute:' + dispute.id, initiatedBy: paid.initiatedBy, reference: dispute.id, note: dispute.reason_code }`
  (E11000 → 200 no-op). Then
  `findOneAndUpdate({ catalogId, status: 'ACTIVE' }, { $set: { status:'GRACE', graceEndsAt: now + graceDays } })`
  — only from ACTIVE; TRIAL/COMPED/PAUSED are untouched. `alertAdmins('DISPUTE', …)`. Emit
  `subscription_state_changed { by: 'DISPUTE' }`.
- `payment.dispute.closed`: `idempotencyKey: 'dispute-closed:' + dispute.id` row (kind
  `DISPUTED`, `note: 'CLOSED_' + status`). If `status === 'won'` and the subscription is GRACE
  with `graceEndsAt` set by the dispute (store `disputeGraceAt` on the subscription when
  entering GRACE this way; clear on any `applyPaidPeriod`) → restore `status:'ACTIVE'`,
  `graceEndsAt: null` only if `periodEnd > now`. `lost` → no state change (sweep handles it);
  alert admins either way.

### Step 2: Standee issuance (G2)

Route `PATCH /admin/catalogs/:id/subscription/standees` (ADMIN), body
`{ issued: z.number().int().min(0), note?: string }` `.strict()`. Conditional update:
`findOneAndUpdate({ catalogId, 'standeeAllocation.included': { $gte: issued } }, { $set: { 'standeeAllocation.issued': issued } })`
→ null → 422 `EXCEEDS_INCLUDED`. `track('subscription_standees_issued', { catalog_id, admin_id_hash, issued, included })`.
Surface `standeeAllocation` in `SubscriptionStatusDto` (Stage 2 already lists it) and render one
line on the owner screen, the rep card and the admin detail: "QR standees: 6 of 15 delivered".
This is a **counter set by a human**, deliberately not derived from `QrCodeAssignment` (README
C8).

### Step 3: Receipt PDF (G3)

`services/subscription/receiptPdf.ts` → `renderReceipt(record, catalog, plan): Buffer` using
`pdfPrimitives` (A4, one page): "ReCapture — Payment receipt", receipt no `RC-…`, date, catalog
display name (de-slugged via `utils/catalogNames.ts`), plan + interval, period covered, amount
`₹x,xxx.xx`, method (Online / Cash / Bank transfer / Cheque / UPI / Complimentary), reference,
and the line **"This is a payment receipt, not a tax invoice. No GST has been charged."**
(§7 rule 7). No owner phone/email on the document.
Route `GET /catalog/subscription/payments/:paymentId/receipt` (owner): the record must belong to
the owner's catalog and be `PAID`, `MANUAL` with `verificationStatus:'VERIFIED'`, or `COMP`;
anything else → 404 `PAYMENT_NOT_FOUND` (same body for not-found and not-eligible). Response
`application/pdf`, `Content-Disposition: attachment; filename="receipt-RC-xxxxxxxx.pdf"`,
`Cache-Control: no-store`. Client: a download icon per eligible history row, using the existing
`qr_download_file.dart` / share seam (io/web variants) — do not add a new file-saving path.

### Step 4: Admin alerts (G4)

`services/subscription/adminAlerts.ts` → `alertAdmins(input: { kind: 'DISPUTE'|'AMOUNT_MISMATCH'|'DUPLICATE'|'ENTITLEMENT_FAILED', catalogId, title, message })`:
`User.find({ role: 'ADMIN', deletedAt: null }).select('_id')` → if empty, `console.error` and
return; else `createNotification({ kind: 'ADMIN_ALERT' (add to the enum if closed), title,
message, action: { route: '/admin/subscriptions/' + catalogId }, audience: { type:'USERS', userIds } })`.
Replace the `console.error`-only sites in Stage 3 (`AMOUNT_MISMATCH`, `DUPLICATE_SUSPECTED`) and
Stage 5 (terminal entitlement failure) with a call to it (keep the log line too).

### Step 5: Copy (G5, G6)

- `delete_catalog_dialog.dart`: when `catalog.subscription?.status` is `active` or `grace`, add a
  bullet: "Your <Plan> subscription ends now. Payments are non-refundable — the unused days are
  not credited." When `trial`: "Your free trial ends and cannot be restarted."
- `subscription_screen.dart`: if `subscription.planSnapshot != null` and
  `planSnapshot.priceMonthlyPaise != plans[planId].priceMonthlyPaise`, show the G6 sentence
  under the current-plan card. Numbers from the server; formatting only on the client.

## API / Data Contract

```
POST /webhooks/razorpay  events payment.dispute.created | payment.dispute.closed → 200
PATCH /admin/catalogs/:id/subscription/standees   body { issued, note? } → 200 { status, subscription } | 422 EXCEEDS_INCLUDED
GET  /catalog/subscription/payments/:paymentId/receipt → 200 application/pdf | 404 PAYMENT_NOT_FOUND
CatalogSubscription gains disputeGraceAt?: Date
```

## Analytics Events

`subscription_dispute_received { catalog_id, amount_paise, previous_status }`,
`subscription_dispute_closed { catalog_id, result: 'won'|'lost' }`,
`subscription_standees_issued { catalog_id, admin_id_hash, issued, included }`,
`subscription_receipt_downloaded { catalog_id, kind }`, `admin_alert_sent { kind, recipients: number }`.

## What NOT to Change

- Do NOT move a disputed subscription to PAUSED directly, and do NOT refund on a dispute — B9
  is explicit that a dispute is not the B3 exception.
- Do NOT derive `issued` from `QrCodeAssignment` or standee activation.
- Do NOT put "invoice", "GSTIN" or a tax breakdown on the receipt.
- Do NOT broadcast alerts with `audienceType: 'ALL'`.
- Do NOT add an owner cancel route here (G7 is undecided).

## Edge Cases to Handle

- [ ] Dispute on a MANUAL/COMP row (no `providerPaymentId`) — cannot happen from Razorpay; the
      lookup misses → warn, 200.
- [ ] Dispute created while already GRACE (expired period) → no state change, ledger row + alert
      still written.
- [ ] Dispute won after the sweep already paused → stays PAUSED; alert says so; admin may comp.
- [ ] `issued` PATCH before any plan (no row / `included: 0`) → 422.
- [ ] Receipt for a `DUPLICATE_SUSPECTED` PAID row → still a receipt (money was taken); the
      refund row has none.
- [ ] Zero ADMIN users in the DB → alert is logged, not thrown; the webhook still returns 200.

## Constraints

- Webhook handlers stay under 5 s: alerts are fire-and-forget (`void alertAdmins(...)` with a
  `.catch` that logs).
- PDF ≤ 100 KB; no embedded fonts beyond what `pdfPrimitives` already ships.
- All new bodies `.strict()`; envelope everywhere; `Cache-Control: no-store` on the receipt.

## Acceptance Criteria

- [ ] `tsc --noEmit`, `npm run lint`, `flutter analyze`; suites green.
- [ ] Signed `payment.dispute.created` on an ACTIVE catalog → GRACE with `graceEndsAt = now + 7d`,
      one DISPUTED row, one notification per ADMIN user; replay → no duplicates.
- [ ] `dispute.closed` `won` before `graceEndsAt` → ACTIVE, `graceEndsAt: null`; `lost` → still
      GRACE.
- [ ] PATCH standees `issued: 16` on a 15-plan → 422; `issued: 6` → DTO shows `{ included: 15, issued: 6 }`
      and the three screens render "6 of 15 delivered".
- [ ] Receipt endpoint returns a valid PDF for a PAID row, 404 for a CHECKOUT_CREATED row, 404
      for another owner's row; the PDF text contains the receipt number and the no-GST line and
      no phone number.
- [ ] Delete dialog shows the non-refund bullet only when ACTIVE/GRACE/TRIAL (widget test over
      four fixtures).
- [ ] G6 sentence appears only when snapshot price ≠ current price (widget test).

## Testing Instructions

1. `tests/subscription-disputes.test.ts`, `tests/subscription-standees.test.ts`,
   `tests/subscription-receipt.test.ts` (parse the PDF text with the helper the standee-sheet
   tests use), `tests/admin-alerts.test.ts`. Run the backend suite once at the end.
2. `test/catalog/delete_dialog_subscription_copy_test.dart`, `test/catalog/price_change_notice_test.dart`.
3. Manual: Razorpay dashboard → test dispute on a test payment → admin bell shows the alert.

## Assumptions

- Assumed a dispute grace is the same 7 days as a lapse grace; if disputes should get longer,
  add `disputeGraceDays` to the plan catalog config.
- Assumed `Notification.kind` can gain `ADMIN_ALERT`; otherwise reuse the closest kind.

---

## Not buildable here — needs an owner

**G7 — owner-initiated cancel.** The plan's §6 table has a `CANCELLED (owner asked)` row but no
route, no screen and no rule for what "cancel" means on a prepaid period. Two coherent options:

- *(Recommended)* **No cancel action.** Prepaid periods simply are not renewed; `CANCELLED` is
  produced only by `DELETE /catalog` (C9). Rename the table row to "CANCELLED (catalog deleted)".
  Zero code.
- **Cancel = stop reminders + mark intent.** `POST /catalog/subscription/cancel` sets
  `cancelIntentAt`; the period runs to `periodEnd`, then goes straight to `CANCELLED` (skipping
  GRACE, since the owner asked) and no nudges/reminders are sent. ~½ day; would slot into Stage 4.

**G8 — public pricing page copy** (10 / 15 / 30 standees, "Taste has none" today). The page is
not in `mirage-fe`; it belongs to the marketing site. Assign to whoever owns that site; block
the Stage 5 flag flip on it so the app and the website never disagree on what a plan includes.

**E5 / E11 / E34 — from the edge-case pass** (see `edge-cases-hardening.md`): orphan-payment
refund (recommend: allowed, admin override, becomes the second refund exception), over-cap on
resume (recommend: accept for v1, notice only), and 30/365-day periods instead of calendar months
(recommend: keep days). Answer alongside G7/G9.

**G9 — upgrade proration.** Stage 3's `applyPaidPeriod` makes "Upgrade" = pay the higher plan's
full price and start a fresh period from today (unused days on the old plan are lost). That is
consistent with §7 rule 9 (no credits) and AC-3.5, and it is the simplest thing that is not
wrong — but §13 item 7 still lists it as open. Either confirm it (then close §13 item 7 and add
one sentence to the Upgrade sheet: "Your new plan starts today; the remaining days on <old plan>
are not credited") or specify a proration rule before Stage 3 Part B ships its Upgrade button.









res -------------------------------------->>>>>>>>>



1 -------------------->

The full backend suite (vitest run, ~100 files) is still running in the background; I'll post the result when it lands. Everything else is done and verified.

What was built (Prompt A)
Backend (recapture-api)

G1 Disputes — new disputeService.ts, wired into the webhook switch in webhookService.ts. payment.dispute.created → DISPUTED row keyed dispute:<id>, ACTIVE → GRACE only (with new disputeGraceAt on CatalogSubscription), admin alert, no refund. closed/won/lost → CLOSED_* row; won restores ACTIVE only when the grace was dispute-started and periodEnd > now. applyPaidPeriod/applyComp/trial-restart all clear disputeGraceAt.
G2 Standees — PATCH /admin/catalogs/:id/subscription/standees (admin.ts), conditional write on included >= issued → 422 EXCEEDS_INCLUDED, audited.
G3 Receipts — receiptPdf.ts via pdfPrimitives + GET /catalog/subscription/payments/:paymentId/receipt (owner-only, PAID / MANUAL-VERIFIED / COMP, same 404 body for everything else, no-store).
G4 — alertAdmins already existed from Stage 3; I only added the DISPUTE kind and pinned it with tests/admin-alerts.test.ts.
DTO gains planSnapshot (for G6); 5 new analytics events incl. subscription_state_changed in the Stage 5 shape.
Flutter

Standee line ("QR standees: 6 of 15 delivered") on owner usage card, rep card, admin panel; admin "Standees delivered…" dialog + repo/notifier method.
G6 locked-price notice under the current plan card; G5 delete-dialog bullets (ACTIVE/GRACE non-refund, TRIAL) — all copy in subscription_copy.dart.
Receipt download icon on eligible history rows, routed through the existing qrDelivererProvider seam (no new file path).
Verification: tsc --noEmit and npm run lint clean; flutter analyze clean (one pre-existing info); flutter test test/catalog test/admin test/rep → all pass; the four new backend suites + subscription-status/subscription-webhook → 75/75 pass.

Two things to flag
"₹" on the PDF is printed as "Rs." — the base-14 fonts pdfPrimitives ships have no rupee glyph and the prompt forbids embedding fonts. Tell me if you'd rather embed one.
G7 / G8 / G9 are still yours to decide — I did not add an owner-cancel route, touch the marketing site, or change proration; the Upgrade sheet still needs the one-sentence "remaining days not credited" copy once G9 is confirmed.




