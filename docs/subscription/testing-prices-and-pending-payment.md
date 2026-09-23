# Testing prices, and the rep-publish payment window

Two features, four repos, one deploy order. Both were asked for in `learn.txt`:

1. **Testing prices** — an env flag that quotes and charges the three plans at ₹3 / ₹5 / ₹7
   while a real Razorpay flow is being tested.
2. **The pending-payment window** — a rep or staff member publishes a restaurant nobody has
   paid for; it goes live with a deadline, and the customer page switches off when the
   deadline passes.

They are independent. Either can ship without the other.

---

## 1. Testing prices

### What it is

`SUBSCRIPTION_TESTING_PRICES=true` re-prices the plan catalog at
`SUBSCRIPTION_TESTING_PRICE_{TASTE,SIGNATURE,MASTERCHEF}_PAISE` (default 300 / 500 / 700).
Everything downstream reads the catalog through `getPlanCatalog()`, so the numbers a screen
shows, the number `quoteFor` mints an order for, and the snapshot frozen onto the row all
come from one function and cannot drift.

```
env ──► planCatalogService.resolve() ──┬──► remoteConfigService  (what the app renders)
        (ops override applied FIRST,   ├──► checkoutService      (what Razorpay charges)
         testing prices LAST)          └──► subscriptionService  (the frozen snapshot)
```

### Why env and not a `client_configs` flag

Every other knob in this layer is a database edit, deliberately. This one is not: the amount
a shop charges must not be flippable without a deploy and a log line. Boot warns on every
start while it is on, and warns harder under `NODE_ENV=production`.

A stored `testingPrices: true` on the override **parses** (so an operator who round-trips the
served catalog is not punished for it) and is then **overwritten** by the env-resolved value.
Nobody can start charging three rupees with a one-line database edit.

### What it deliberately does not touch

- **Caps, standees, features, durations.** A testing price is a price. A testing mode that
  also relaxed a cap would be testing a plan nobody sells, and every cap bug would hide
  behind it.
- **The yearly discount.** Yearly stays `monthly × 12 × (100 − 30) / 100` over the testing
  figure — ₹25.20 / ₹42 / ₹58.80 — so the arithmetic a real yearly order goes through is the
  arithmetic being tested. The env schema floors each price at 100 paise because Razorpay
  refuses an order under ₹1.
- **A period that is already running.** Every subscription freezes `planSnapshot` at purchase.
  A restaurant that paid ₹3 keeps a ₹3 snapshot until its next renewal, and the existing
  "your price was locked; renewals are X" notice (B6) is what surfaces it. **Turning the flag
  off retro-bills nobody.**

### The badge is not optional

The served catalog carries `testingPrices: boolean`, and the subscription screen renders
`_TestingPricesBadge` above the plan cards whenever it is true. The failure this exists to
prevent is not technical: it is a rep showing a real restaurant a ₹3 card during a test
window, and that restaurant reasonably expecting ₹3. An old app build that has never heard
of the field reads it as `false` — which is correct for an old *server*, and is the one gap
to keep in mind if a new server is ever pointed at old clients with the flag on.

---

## 2. The pending-payment window

### The state

A new subscription status, `PENDING_PAYMENT`, with `source: 'REP_PUBLISH'`.

| | trial | pending-payment window |
|---|---|---|
| who starts it | a rep, from a button, on purpose | a rep's **Publish**, automatically |
| length | `trialDays` (30) | `SUBSCRIPTION_PENDING_PAYMENT_DAYS` (7) |
| 3D cap | `trialThreeDCap` (10) | the same 10 |
| one-ever flag | `trialUsedAt` | `pendingPaymentUsedAt` |
| when it runs out | → GRACE → PAUSED, **photo menu stays live** (AC-4) | → PAUSED, **customer page goes dark** |

**Why it is not just a trial.** The one free trial a restaurant gets is something a rep grants
deliberately. Spending it as a side effect of pressing Publish would silently consume it. So
the window is its own state, and the trial is still there to be started afterwards — a trial
started later *supersedes* the window and clears the debt (`rowAllowsTrial` lists
`PENDING_PAYMENT` beside `CANCELLED` and `PAUSED`). That is the "(or free trial limit)" half
of the requirement.

**Why its expiry is harsher than a lapse.** AC-4 promises a restaurant that has **paid** that
its photo menu never goes dark. A restaurant that has never paid a rupee was never given that
promise, and "pay or the link dies" is the only lever a rep has once they have left the table.
The two rules coexist because exactly one code path sets `pageDeactivatedAt`:
`lifecycleSweep.sweepToPageOff`, reachable only from `status: 'PENDING_PAYMENT'`, a status
only `startPendingPayment` writes, and only for an owner with no payment in their history.

### The flow

```
rep taps Publish
   └─ POST /rep/catalogs/:id/publish  (passes `publishedBy`: the rep's actor)
       └─ requestPublish
           ├─ openPendingPaymentWindowForPublish   ← BEFORE the gates, because it
           │    · role >= SALES_REP?                  writes the row the gate reads
           │    · catalog already entitled? → no-op
           │    · owner already had a window / has paid? → no-op
           │    · else: PENDING_PAYMENT row + SUBSCRIPTION_PAGE_STATE job
           └─ evaluatePublishGates → passes (capped, but not blocked)

… 7 days, nobody pays …

worker sweep (every SUBSCRIPTION_SWEEP_INTERVAL_MS)
   └─ sweepToPageOff
       ├─ PENDING_PAYMENT → PAUSED, pageDeactivatedAt = now   (conditional update: D4)
       ├─ SUBSCRIPTION_PAGE_STATE  { isPublished: false }
       └─ SUBSCRIPTION_AR_ENTITLEMENT { enabled: false }

… the owner pays …

applyPaidPeriod
   ├─ CLEARED_ON_NEW_PERIOD clears pageDeactivatedAt  (the ROW is the truth)
   ├─ SUBSCRIPTION_PAGE_STATE  { isPublished: true, paymentDueAt: null }
   └─ SUBSCRIPTION_AR_ENTITLEMENT { enabled: true }
```

### Two jobs, not one

`SUBSCRIPTION_AR_ENTITLEMENT`'s contract is that its Mirage body is **exactly** `{ arEnabled }`,
pinned by a test on the call's argument keys (E36) — because anything extra in that body, a
`name` above all, would rewrite the restaurant behind every printed QR. Widening it to
sometimes also unpublish would break the one invariant that makes it safe to run unattended.

So `SUBSCRIPTION_PAGE_STATE` is a separate type with a separate processor and a separate body,
`{ isPublished, paymentDueAt }`. Two jobs, two blast radii.

### Three guards against taking down a paid page

This is the expensive failure, so it is guarded three times:

1. **The sweep's conditional update** repeats the eligibility in the filter, so a row the owner
   paid a second ago matches nothing and no job is enqueued.
2. **The processor recomputes** the desired state from the row (`desiredPageStateFor`) and
   drops a payload that no longer matches — as a success.
3. **The processor refuses to revive** a catalog whose own `Catalog.status` is not `PUBLISHED`,
   so a payment cannot undo an owner's own unpublish (feature 39 writes the same Mirage field).

### Mirage

- `restaurant.paymentDueAt: Date | null` — written only by the admin update route, only by
  ReCapture's page-state job. `parseClearableDateField` gives it three outcomes: absent leaves
  it alone, `""` clears it, an ISO string sets it. The transport is multipart, so there is no
  `null` on the wire and `""` is how "nothing is due" is spelled.
- The public payload carries it **verbatim**. Mirage interprets nothing: a deadline in the past
  with the page still serving is a normal state (ReCapture's sweep has not run yet).
- `PaymentDueBanner` on the public menu renders the countdown. **Diners see it** — a deliberate
  product decision, and a deliberate departure from the rule the rest of this feature follows
  (`ArUnavailableCard`: "the diner is not the customer of that message"). The copy is
  constrained to compensate: it never says *unpaid*, *overdue*, *bill* or names a price, it
  addresses the owner in the second person, and it never claims the menu is broken — because
  it is not. A past deadline reads as "switches off shortly", never as a dead link.

---

## Deploy order

`paymentDueAt` must exist on Mirage before ReCapture can write it, exactly as `arEnabled` had
to for Stage 5.

1. **mirage-be** — the schema field, `parseClearableDateField`, the admin write, the public
   payload. Harmless on its own: nothing writes the field yet and it serves `null`.
2. **mirage-fe** — the banner. Harmless on its own: nothing sets a deadline, so it never
   renders.
3. **recapture-api** — the status, the service, the sweep scan, the job and its processor.
   Ship with `SUBSCRIPTION_TESTING_PRICES` unset.
4. **The Flutter app** — the new status, the banners, the badge. An older build treats
   `PENDING_PAYMENT` as `unknown`, which falls through the client gate to "no gate" — the same
   verdict this build reaches. It simply shows no banner.

Then, when testing begins: set `SUBSCRIPTION_TESTING_PRICES=true` and redeploy the API. Check
the boot log says so. Turn it **off before the first real customer pays**, and remember that
anybody who paid at a testing price keeps that price until their next renewal.

## Rollback

- **Testing prices:** unset the env var and redeploy. Nothing is retro-billed.
- **The window:** the feature is inert without `publishedBy`, which only the rep publish route
  passes. Rows already in `PENDING_PAYMENT` would then never expire (the sweep scan would be
  gone with it), which fails in the safe direction — pages stay up. To clear them deliberately,
  comp or trial each one.

## Ops notes

- `[subscription-sweep] to_page_off=N` in the sweep's log line is the count of live links that
  died for non-payment. It is tracked separately from `to_paused` on purpose: one means a plan
  lapsed, the other means a QR code stopped working, and a dashboard must never average them.
- `subscription_page_state_synced` with `skipped: true` is the D4 guard doing its job, not an
  error.
- The alert to watch for is **"A paid restaurant's page is still switched off"** — that is the
  only state in this feature that actively costs a paying customer, and it needs the admin
  resync.
