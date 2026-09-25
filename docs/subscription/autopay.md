# Autopay: plans that renew by themselves

**Asked for in:** `learn.txt` item 7, on 2026-09-25. The payment was one-time; it has to be
**autopay**, so a monthly plan is charged every month and a yearly one every year until the
owner turns it off. This applies to both the app and the web build.

**Built as:** Razorpay **Subscriptions**. When the owner presses Pay, the app creates a mandate
(`sub_…`) instead of a one-time order (`order_…`), and the owner approves it once with UPI,
card or net banking in the same in-app Razorpay sheet. After that, Razorpay charges on schedule.

---

## How it flows

```
Owner taps "Pay / Renew / Upgrade / Turn on autopay"
  → POST /catalog/subscription/autopay          creates a CREATED mandate (charges nothing)
  → Razorpay sheet opens with subscription_id   owner approves the mandate
      ├─ charged now   (no paid plan running, or a different plan)
      └─ charged later (inside a paid period of the SAME plan: the first charge is at that
                        period's end, so the owner never pays twice for the same days)
  → POST /catalog/subscription/autopay/verify   signature checked, then SYNC
  → the app polls GET /catalog/subscription until the plan flips (or autopay shows "on")

Every month / year after that:
  Razorpay charges → webhook `subscription.charged` → SYNC → the new period is applied
```

**SYNC** (`autopayService.syncMandate`) is the only path, and five things call it: the verify
call, the webhook (`subscription.*`), the reconciler, the owner's own read of the status, and
the admin journal. It asks Razorpay for the subscription and its **paid invoices**. Each paid
invoice becomes a `PAID` ledger row keyed `payment:<id>`, like every online payment, and is
applied through the one activation primitive. A mandate that is merely "active" is never
counted as a payment; only a paid invoice is.

## Decisions (and why)

| # | Decision | Why |
|---|---|---|
| A1 | The period **starts at `paidAt`** as before, but an autopay charge's period **ends on Razorpay's billing end** (its next charge date), not at `paidAt + 30/365 days`. | A calendar month is not 30 days. Without this, the catalog would lapse a day before the next charge, every 31-day month. The admin journal's CATALOG check (`periodStart === appliedAt`) is unchanged. |
| A2 | **Same plan and interval as the running paid period** → the first charge is **deferred** to that period's end (`start_at`). **Any other case** → charged now, forfeiting the rest of the period exactly as a one-time early renewal did (E9, `daysForfeited`). | Switching an existing payer to autopay must not charge them twice. A plan change is a purchase *now*, so the existing forfeit rule and warning apply. |
| A3 | **At most one live mandate per catalog.** When a new mandate goes live (approved or charged), every other live or halted one is **cancelled at Razorpay**. | A plan change must never leave two mandates charging one restaurant. The old one is cancelled only once the new one is approved, so a failed checkout never leaves the owner with no autopay at all. |
| A4 | **Turning autopay off cancels at Razorpay immediately.** The paid period is not shortened. | The catalog's period is ours, not Razorpay's. Nothing else to track ("cancel at cycle end" would add a state and gain nothing). |
| A5 | **The sweep holds a catalog with a healthy mandate out of GRACE** for `AUTOPAY_RENEWAL_WAIT_HOURS` (48 h) past `periodEnd`. The "renew in 7 days" reminder is skipped, and the 1-day one says it renews by itself. | A UPI debit can land hours after the cycle boundary. Otherwise every autopay owner would be told "payment overdue" once a month for a charge that is merely in flight. Past the wait, it lapses like any other plan. |
| A6 | A failing renewal (`pending`) and a stop (`halted`, `completed`, or cancelled from the payer's bank/UPI app) each **notify the owner once**. Our own cancels (turned off, superseded) do not say "stopped". | The owner needs to act only in the first group. |
| A7 | `payment.captured` / `order.paid` for an **invoice** payment is **ignored** by the one-time handler. | Recording it there would rebuild it as a one-time payment with the wrong period. The mandate sync records it. |
| A8 | The app falls back to the **one-time order** if the server has no `/autopay` route (a 404 with no error code). | If the app ships before the server deploy, owners must still be able to pay. |
| A9 | Deleting a catalog **cancels its mandates first**. If Razorpay is down, the delete still goes through and admins get an `AUTOPAY_CANCEL_FAILED` alert. | A mandate left running would keep charging a restaurant that no longer exists. |

## Owner screen

- **Autopay card** under the status card:
  - On: "Autopay is on · ₹X every month · next charge on DATE", with **Turn off autopay**.
  - Failing: amber, "could not take the last payment…".
  - Stopped: red, "…turn it on again".
  - Off while a paid plan is running: "Autopay is off — your plan won't renew by itself".
- **The button** says *Turn on autopay* when nothing is charged today; otherwise Pay / Renew /
  Upgrade as before. It is replaced by "Autopay is on for this plan" when a healthy mandate
  already charges exactly the selected plan and interval.
- **The confirm sheet** says when the first charge is (now, or on DATE) and that it repeats
  every month / year until turned off.
- **Admin detail** shows the same autopay line (or "Autopay is off.").
- **Payment journal:** each autopay charge is its own entry ("Autopay charge on sub_… (invoice
  inv_…)"), and it appears under **All**.

## Going live: what to configure (no code)

1. **Razorpay: enable Subscriptions** on the account (Dashboard → Subscriptions). On some
   accounts it needs activation by Razorpay support. Without it,
   `POST /catalog/subscription/autopay` answers 503 `PAYMENTS_UNAVAILABLE`.
2. **Razorpay webhook: add the subscription events** to the existing webhook (same URL, same
   secret): `subscription.authenticated`, `subscription.activated`, `subscription.charged`,
   `subscription.pending`, `subscription.halted`, `subscription.cancelled`,
   `subscription.completed`, `subscription.paused`, `subscription.resumed`,
   `subscription.updated`. Keep the existing order/payment/refund/dispute events.
3. **Register the website and app** in Razorpay (Settings → Website & App). Live payments from
   an unregistered origin are refused with "website does not match registered website(s)".
   That was the cause of the 17 failed attempts on 2026-09-24.
4. **Render env** (all optional, defaults shown):
   `AUTOPAY_TOTAL_CYCLES_MONTHLY=60`, `AUTOPAY_TOTAL_CYCLES_YEARLY=5`,
   `AUTOPAY_RENEWAL_WAIT_HOURS=48`.
5. **Deploy the backend first, then the app.** An older app build keeps using one-time orders,
   which still work. A newer app on an older server falls back to them (A8).

## Limits to know about

- **₹15,000 per debit for UPI Autopay and card mandates.** Above that, each renewal needs the
  payer to authenticate again, so a silent renewal can fail. At real prices the **yearly
  Signature (₹15,112) and yearly MasterChef (₹20,992)** renewals are above the limit.
  Net-banking / debit-card e-mandates (eNACH) are not capped this way. Options, not yet decided:
  price those two yearly plans at or under ₹15,000, or accept that their renewals go to
  PENDING → the owner is told → they pay again.
- **Mandates end.** Razorpay needs a finite charge count. After 60 months / 5 years the mandate
  COMPLETES, the owner is told, and they turn autopay on again.
- **Testing prices** (₹3 / ₹5 / ₹7) work with autopay (Razorpay's minimum is ₹1). Each price is
  its own Razorpay plan (`RazorpayPlan` collection), so flipping the flag later does not change
  what an existing mandate charges.

## Test it end to end (live keys, testing prices)

1. On a catalog with no plan: **Pay → approve with UPI**. The plan goes ACTIVE, the card says
   "Autopay is on · next charge on <one month later>", and the admin journal shows an
   "Autopay charge" entry.
2. **Turn off autopay.** The plan stays ACTIVE to the same date. The Razorpay dashboard shows
   the subscription cancelled.
3. **Turn it on again** (same plan). The sheet says "Nothing is charged today… on <period
   end>". After approval the card says "Autopay is on" and the period end has not moved.
4. **Switch plan** (e.g. Taste → Signature). It is charged now and the forfeit warning is
   shown. The old mandate is cancelled in the dashboard.
5. For the renewal itself: create a **daily** test plan by hand in Razorpay test mode if you
   need to watch a real renewal land. Our plans are monthly/yearly only.

## Code map

- `recapture-api/src/models/AutopayMandate.ts`: one row per Razorpay subscription.
- `recapture-api/src/models/RazorpayPlan.ts`: one Razorpay plan per plan, interval and price.
- `recapture-api/src/services/subscription/autopayService.ts`: start, sync, verify, off,
  reconcile.
- `recapture-api/src/services/subscription/autopayReadModel.ts`: the DTO summary and the
  sweep's "healthy autopay" set.
- `recapture-api/src/services/subscription/webhookService.ts`: `recordAutopayCharge`; the
  invoice-payment skip.
- `recapture-api/src/routes/webhooks.ts`: routes `subscription.*` events to the sync.
- `recapture-api/src/routes/catalog.ts`: `POST /subscription/autopay[/verify|/cancel]`.
- `recapture-api/tests/subscription-autopay.test.ts`: 23 tests.
- `lib/application/catalog/checkout_notifier.dart`: autopay first, one-time fallback.
- `lib/application/catalog/checkout_adapter_{io,web}.dart`: `subscription_id` in the sheet.
- `lib/presentation/screens/catalog/subscription_screen.dart`: autopay card, button, sheet.
