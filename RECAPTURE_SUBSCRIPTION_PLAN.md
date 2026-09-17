# ReCapture — Subscription Layer: The Plan (plain-English)

> **What this is:** the full plan for charging restaurants to keep their menu live, written so
> anyone on the team (sales, product, engineering) can read it. Where a decision is still open it
> is marked **DECISION NEEDED** and collected at the bottom.
>
> **What it is not:** an implementation prompt. Once the decisions are made, the engineering
> stages at the end become the task list.
>
> **This revision supersedes the earlier base+per-photo+per-3D pricing model**, and folds in a
> follow-up refinement pass that fixes: a flat 30% yearly discount, no image-dish cap on any plan,
> a 30-day trial (10 3D-dish cap) any rep can activate directly, a 30-day grandfather window,
> **in-app checkout** (Razorpay, no external payment link), and non-refundable payments with one
> admin-triggered exception for accidental duplicate payments. See §13 for the full resolved/open
> list.

---

## 1. The idea in one paragraph

Today a restaurant (or a sales rep on its behalf) builds a menu in ReCapture and presses
**Publish**; the menu goes live at a QR link for free, forever. We want to change that to: **the
3D/AR menu experience stays live only while the restaurant has an active subscription (or an
authorized trial)**; **the image-based menu, once published, stays live regardless of payment
status** (see §6). The price depends on which of three fixed plans the restaurant is on — **Taste**,
**Signature**, or **MasterChef** — each with its own cap on 3D/AR dishes (no plan caps image
dishes) and its own bundle of complimentary QR-code standees. The owner pays entirely **inside the
ReCapture app** — no external checkout page.

---

## 2. Why "subscription", not "pay per publish"

The first instinct is "charge ₹X every time they press Publish". That is a trap:

| Pay-per-publish | Subscription (recommended) |
|---|---|
| Restaurant fixes a typo in a price → pays again. They stop updating the menu, it goes stale, and stale menus get scanned less. | Republishing is free. Update the menu ten times a day. |
| The rep publishes at the table → who pays right there? | The menu is live for a **period** (month/year). Paying and publishing are separate acts. |
| A publish can fail halfway (PARTIAL run) → did they pay for a broken publish? Refund fights. | Payment buys a **period of being live**, not a single publish. A failed publish is just retried. |
| Revenue is unpredictable. | Recurring revenue, predictable. |

So: **a subscription is attached to the catalog. While it is active, the owner or the rep can
publish as often as they like, as long as the 3D/AR dish count fits the plan's cap.** Image dishes
are never capped (see §3).

---

## 3. What is the price? (the plans)

Pricing is **not** calculated from a formula. ReCapture sells three fixed monthly plans, each with
a 3D/AR dish cap and a bundled set of complimentary QR-code standees. **No plan caps image/photo
dishes.**

| Plan | Monthly price | Yearly price (30% off)* | 3D/AR dish cap | Image/photo dish cap | Complimentary QR-code standees | Other features |
|---|---|---|---|---|---|---|
| **Taste** | ₹1,199 / month | ≈ ₹10,072 / year | Up to 10 | Unlimited | **10** | Menu management (Name, Price, Category); Instant Digital QR Code; hosted on Mirage Menu domain |
| **Signature** | ₹1,799 / month | ≈ ₹15,112 / year | Up to 15 | Unlimited | **15** | Everything in Taste, plus WhatsApp & Instagram buttons |
| **MasterChef** *(most popular)* | ₹2,499 / month | ≈ ₹20,992 / year | Up to 30 | Unlimited | **30** | Everything in Signature, plus AR-menu embed on the restaurant's own website, per-dish view analytics, priority call support |

`*` **Yearly price = monthly price × 12 × 0.70** (a flat 30% discount), billed upfront. The figures
above are illustrative; the exact display-rounding convention (nearest rupee, nearest ₹10, etc.) is
an implementation detail — **TBD** (§13) — the formula is the source of truth, not the rounded
number shown here.

These are the **only three plans**. There is no base+per-dish formula, no intermediate tier, and no
per-dish add-on pricing.

Notes:

- **No plan caps image/photo dishes** — unlimited image-only dishes on Taste, Signature, or
  MasterChef alike. Only the 3D/AR dish count is capped and tiered.
- **The 10/15/30 standee counts** are the plan's included allocation, bundled into the price.
  Selling **additional or customised standees** is planned but explicitly **deferred** — pricing
  for those is undefined and expected to fluctuate; see §3a and §13.
- These counts supersede the physical-QR-card quantities shown on the current public pricing page
  (which lists 10 for Signature, 20 for MasterChef, none for Taste). Pricing-page copy must be
  updated to 10 / 15 / 30 complimentary QR-code standees on Taste / Signature / MasterChef.

### 3a. What you are actually buying: a plan tier, not a formula

A restaurant buys one of the three plan tiers above: **a fixed monthly (or yearly) price for a
3D/AR dish cap, unlimited image dishes, a QR-code standee allocation, and a feature set.** They are
not buying "these exact dishes" — inside the 3D cap they can:

- Delete a dish and add a different one — same slot, no new charge.
- Rename, reprice, reorder, or recategorize any dish — never touches the subscription.
- The only thing that costs more is **needing more 3D/AR dishes than the plan's cap**, checked at
  one moment only: **when Publish is pressed** (see §5). That requires upgrading to the next plan
  tier (Taste → Signature → MasterChef); there is no per-dish incremental charge.

A dish that is archived or deleted does not occupy a slot. Only dishes that would actually go live
count.

#### Complimentary vs. purchased standees

The 10 / 15 / 30 standees above are **included in the plan price**, issued once per plan
activation. Selling **additional standees, or customised standee designs, beyond the plan's
included count** is a planned feature but is explicitly **deferred to a later build stage** (§12
Stage 6) — pricing for extras is not yet defined and is expected to fluctuate, so no numbers are
assumed here. When built, an additional-standee order must be tracked as a **separate, priced line
item** (e.g. a `standeeOrder` record with its own quantity, unit price, and payment) — clearly
distinct from the plan's bundled allocation, in both the schema (§10) and the UI.

### 3b. Which dishes count as "3D"?

A dish counts against the plan's **3D/AR cap** if, at the moment of publishing, it has a usable 3D
model — **`modelStatus = READY`, and only that.** A dish added as "Capture now" but whose model is
still generating, or failed, is treated as an **image dish** — because that is what the customer
will actually see. (When the model finishes later and the next publish sends it, *that* publish
checks the 3D cap — see edge case C4.)

### 3c. Where the plan definitions live

The plan catalog (plan names, prices, yearly discount, 3D-dish caps, included standee counts,
feature flags, trial length, trial 3D cap, grace length) lives in **server config**, not in the app:

- Changing a price or a plan's features must not need a Play Store release.
- The app already fetches a remote config on start (`/remote-config`); plan definitions ride along.
- **Every subscription stores a frozen copy of the plan definition it was bought under.** If a
  plan's price or cap changes later, existing subscribers keep what they bought until their next
  renewal. Nobody gets a surprise mid-period.

---

## 4. Who pays, and how — the core of the rep problem

### The problem, stated plainly

A sales rep stands in a restaurant, activates a standee, photographs the dishes, and presses
Publish — all in 15 minutes, before the owner has ever opened the app. In fact:

- The owner's **account was created by the rep typing the owner's phone number**. Nobody has
  verified it. The owner might never log in.
- The rep is **not** the owner. The rep must never be the one whose card is on file — reps leave,
  get reassigned, or go on holiday, and the restaurant's menu must not die with them.
- The rep must still be able to walk out with a live menu that day — either by **activating a free
  trial themselves, on the spot, with no approval step** (Door 1), or by having the owner **pay
  immediately inside the app** if they're present and willing to log in right there (Door 2).
- **A free trial is not granted automatically.** Every onboarding requires an explicit subscription
  decision — start a trial, or activate a paid plan — before the first Publish can succeed. There is
  no default "trial starts on first publish" shortcut.

### The answer: four doors, one subscription

The subscription always belongs to the **restaurant's catalog**. There are four ways it gets a
subscription, and all of them land in the same place.

#### Door 1 — Free trial, rep-activated (explicit, but no approval needed)

Free trials are **not** granted automatically, and not every newly onboarded restaurant gets one.
Before the first Publish can succeed, the sales rep (or admin) must take one explicit action:

- **(a) Activate the free trial** for the restaurant, or
- **(b) Activate one of the three paid plans immediately** (via Door 2 in-app checkout or Door 3
  manual cash entry).

- **Any rep can activate a trial directly — no admin approval step.** The only eligibility rule is
  that the catalog must not have used its trial before (`trialUsedAt` unset).
- **Trial length: fixed at 30 days.**
- **Trial 3D/AR dish cap: fixed at 10 dishes** (matches the Taste plan's cap). Image dishes are
  uncapped during the trial too, same as the paid plans.
- One trial per catalog, ever. A restaurant that deletes its catalog and re-creates it does not get
  a second trial (the catalog slot is reused on delete — this already works that way).
- A trial does not choose a plan. When the trial ends, the restaurant must move onto one of the
  three paid plans to continue past the grace period (§6).

Before any decision is made, the rep's screen shows: **"No subscription yet — start a free trial or
activate a plan to publish."** After a decision: **"Live on trial — 30 days left, up to 10 3D
dishes."** or **"Live on <plan name>."**

#### Door 2 — In-app checkout (the owner pays without ever leaving the ReCapture app)

There is **no external payment link and no hosted checkout page.** The owner pays from inside the
ReCapture app itself, using Razorpay's SDK embedded in an in-app checkout screen — the app is the
one place an owner needs for everything about their AR menu, including paying for it.

- The owner logs into the app (OTP to the phone number on file — the same number the rep typed at
  onboarding) and opens the **Subscription** screen.
- They pick a plan (Taste / Signature / MasterChef) and a billing interval (monthly / yearly), and
  pay with UPI / card / net banking through the in-app Razorpay checkout — no browser tab, no
  separate webpage.
- When the payment succeeds, Razorpay's webhook confirms it server-side (§7 rule 1), the
  subscription flips to **ACTIVE**, and the owner's and rep's screens update within seconds.
- **A rep cannot complete this payment on the owner's behalf using the rep's own money or payment
  instrument** (see A3). A rep can only: activate a trial (Door 1), hand the owner the phone/app to
  pay in-app themselves, or record a manual cash entry for admin verification (Door 3).
- **Consequence:** an owner who never installs or logs into the app cannot pay online. Their options
  are then a rep-activated trial (Door 1) or a cash payment via Door 3 — there is no owner-only,
  no-login payment path in this revision (this replaces the earlier "pay via a shared link, no app
  needed" design).

**This is why the rep edge case dissolves:** the rep never enters the owner's payment details.
Either the rep activates a trial on the spot, or the owner pays themselves inside the app — right
then if they're standing there with the rep, or later on their own.

#### Door 3 — Offline / manual (cash, bank transfer, cheque) — admin-verified only

Field sales in India means some owners will hand over cash or say "I'll transfer it." This is a
**two-step, role-separated** workflow:

1. **The rep (or whoever collected the payment) submits a manual-payment request** against the
   catalog: plan selected, amount, method (cash / bank transfer / cheque), a reference (UPI txn id,
   receipt number, bank reference), a note, and who collected it. This creates a `PaymentRecord`
   with `verificationStatus = PENDING_VERIFICATION`. **The subscription does not activate or renew
   at this step.**
2. **An ADMIN reviews and approves (or rejects, with a reason) the request.** Only on approval does
   `verificationStatus` become `VERIFIED` and the subscription activate/renew.
3. **A rep cannot self-verify.** A REP-only user can create a request but has no permission to set
   it to `VERIFIED`. Only a user holding the ADMIN role (or a role explicitly granted an "approve
   manual payments" permission) can approve. This mirrors the existing rule that role grants and
   standee batches are admin-only.
4. If one person holds both field-sales duties and ADMIN permissions, they can create *and* approve
   — but the audit trail still separately records `collectedBy`/`initiatedBy` and `verifiedBy` even
   when it is the same person, so this stays visible in review.
5. Every manual entry is fully audited: who submitted it, when, what reference, who approved or
   rejected it, when, and any note.

See §10 for the `PaymentRecord` fields this requires, and §11 for the submit vs. approve endpoints.

#### Door 4 (staff only) — Complimentary

ADMIN can mark a catalog **COMPED** with an expiry (demo restaurants, pilots, partner deals,
"sorry we broke your menu last week"). Behaves like ACTIVE with no dish-cap enforcement until the
date.

---

## 5. What happens when Publish is pressed

Publish already runs a checklist of "gates" (no categories, duplicate dish names, missing 3D
source, and so on) and shows the user every failure at once. The subscription becomes **two more
rows on that same checklist**, on both the owner's and the rep's Publish screen:

```
Publish pressed
   │
   ├─ existing gates (categories, names, models, …)  ─ fail? ─► checklist row(s)
   │
   ├─ SUBSCRIPTION CHECK
   │     ├─ no subscription yet (no trial started,
   │     │    no plan active)                        → BLOCKED. Row: "No subscription — start a
   │     │                                              trial or activate a plan" (see §4 Door 1).
   │     │                                              Publish cannot proceed at all.
   │     ├─ TRIAL or ACTIVE or COMPED, and the
   │     │    3D/AR dish count fits the plan's cap    → continue
   │     ├─ ACTIVE but menu needs MORE 3D/AR dishes
   │     │    than the plan's cap                     → row: "Menu has grown — 17 AR dishes, your
   │     │                                               Signature plan covers 15. Upgrade to
   │     │                                               MasterChef to publish all of them."
   │     ├─ GRACE (payment overdue, within 7 days)     → continue, but show a warning banner
   │     └─ PAUSED (grace expired, unpaid) / CANCELLED → image-dish publishing still works. 3D-dish
   │                                                      publishing is blocked — row: "3D menu
   │                                                      needs an active plan — Pay in-app" / rep
   │                                                      sees "Notify owner to open the app and pay"
   │
   └─ all green → the publish job runs exactly as today
```

Plain rules:

1. **The subscription check is a gate, not a payment step.** Publish never takes money. It only
   answers "are you allowed to be live with this menu, and with 3D, right now?".
2. **The "Fix" button on the gate row does the right thing for who is looking at it.** Owner → opens
   the in-app Subscription/checkout screen (pay for the first time, renew, or upgrade). Rep → opens
   "start a trial" (if none used yet) or "notify the owner to open the app and pay" — the rep never
   handles payment here. Admin → can also submit/approve a manual payment, or comp.
3. **3D/AR dish counts are checked on the same frozen snapshot the publish uses**, so the number the
   gate quotes is the number that goes live. No "it said 15 but published 16".
4. **A publish that is already running is never interrupted** by a subscription change. The next
   publish sees the new state.

---

## 6. What happens when the subscription lapses

The QR on the table must never become a dead link, and — per policy — **the restaurant's published
image-based menu must never go offline for non-payment.** Only the **3D/AR menu and other
explicitly 3D-dependent paid features** are disabled when a subscription lapses. So "running out"
degrades functionality, not availability:

```
ACTIVE ──(period ends, no renewal)──► GRACE ──(grace ends, still unpaid)──► PAUSED ──(paid/renewed)──► ACTIVE
                                       7 calendar days                      image menu stays live,
                                       full access continues,               3D/AR disabled
                                       red warning banner                   (placeholder for
                                                                             photo-less 3D dishes),
                                                                             restores instantly,
                                                                             no re-onboarding
```

> **"PAUSED" no longer means offline.** It means the 3D/AR experience is switched off; the
> image-based menu keeps serving at the same QR link.

| State | Customer scanning the QR sees | Owner / rep sees | Can publish? | 3D/AR live? |
|---|---|---|---|---|
| **TRIAL** | The live menu (3D + image), up to 10 3D dishes | "Trial — N days left" + start-plan/pay prompt | Yes | Yes |
| **ACTIVE** | The live menu (3D + image) | "Active until <date>, plan: <name>" | Yes (within plan's 3D cap) | Yes |
| **GRACE** | The live menu (3D + image), unchanged | Red banner: "Payment overdue — 3D menu disables in N days" | Yes, with warning | Yes |
| **PAUSED** (grace expired, unpaid) | The **image-based menu**, fully accessible; 3D dishes with a photo fall back to it, 3D-only dishes with no photo show a **placeholder**; 3D-dependent features (e.g. AR-menu website embed) are off | "3D menu paused — renew <plan> in-app to restore" | Image-dish publishes: yes. New 3D-dish publishes: blocked (gate) | **No** |
| **COMPED** | The live menu (3D + image) | "Complimentary until <date>" | Yes | Yes |
| **CANCELLED** (owner asked) | Same as PAUSED | "Cancelled — resubscribe anytime" | Image-dish publishes: yes. 3D-dish publishes: blocked | No |

**Grace period: exactly 7 calendar days**, starting the day the paid period ends.

- **If payment completes during grace:** the subscription returns to (or stays) **ACTIVE**
  immediately on webhook confirmation. **A grace-period payment always starts a fresh period from
  the payment date** — the new `periodStart` is the payment timestamp, and `periodEnd` is computed
  from there (not from the original `periodEnd`). Nothing was ever disabled during GRACE, so there
  is nothing to restore.
- **If grace expires with no payment:** the subscription moves to **PAUSED**. The 3D/AR viewer is
  switched off on the public page; the image-based menu (name, price, category, photo where
  present) keeps serving from the QR link with no interruption. No dish, category, or 3D asset is
  deleted.
- **Renewing from PAUSED:** paying for (or being granted) an eligible plan flips the subscription
  back to ACTIVE and **re-enables the existing 3D menu immediately** — the same 3D assets that were
  hidden, not new ones. The restaurant does not need to recreate its catalogue or re-onboard.

Reminders go to the owner's phone (**SMS and WhatsApp**) at **7 days before**, **1 day before**, **on
expiry**, and **midway through grace (around day 3–4)**. The rep who activated the restaurant sees
the same countdown on their "My restaurants" list so they can nudge in person. **The automated
reminder schedule is deferred to a later build stage** (§12 Stage 6) — only the rep's on-demand
manual nudge ships at launch (§4 Door 2, §11).

### How "PAUSED" actually works underneath (engineering note, still plain)

Because the image-based menu must stay up and the 3D menu must restore without recreation, the only
workable design is an **entitlement/feature-flag check at render time, not an unpublish.**

- The public Mirage page (and any embed) checks the catalog's subscription state — or a cached
  entitlement flag synced from it — at render/request time.
- When the state is **PAUSED** or **CANCELLED**: dishes render using their photo (`imageUrl`)
  instead of the 3D viewer, regardless of `modelStatus`. A dish with **no photo** (3D-only) renders
  a **placeholder card** (generic "AR preview unavailable" graphic, with the dish name/price still
  shown) instead of failing to render or disappearing. The 3D asset reference is **not deleted** —
  rendering is skipped, not the data.
- "Embed AR Menu into Your Website" (MasterChef) and any other explicitly 3D-dependent feature stop
  functioning the same way — entitlement check at request time, not data deletion.
- Because no Mirage dish IDs are recreated, per-dish analytics history is unaffected by a
  pause/renew cycle.

---

## 7. Payment provider and the money-handling rules

**Provider: Razorpay** — decided, the only payment provider integrated. UPI is non-negotiable for
Indian restaurants, and Razorpay's SDK lets us build the checkout **inside the app** (no hosted page,
no PCI burden — we never see a card number).

**Prepaid periods, not auto-debit, for version 1.** Auto-renewing card/UPI mandates in India
(RBI e-mandate rules) add OTP-on-every-renewal friction and a lot of failure handling. Version 1
sells **prepaid** months/years; renewal is "pay again before the date" with reminders. Auto-renew
is a version 2 item.

Rules the code must follow, in plain words:

1. **Never trust the app about money.** The app never says "I paid". Only the provider's webhook
   (server-to-server, signature-checked) or an admin's verified manual entry can activate a
   subscription.
2. **Every payment has an idempotency key.** The provider may deliver the same webhook twice; the
   second one must do nothing. A double-tapped "Pay" must not create two orders.
3. **One open Razorpay order per catalog at a time**, and **one PENDING_VERIFICATION manual-payment
   request per catalog at a time.** If a second is requested while one is open, the existing one is
   returned, not a new one.
4. **The in-app order is frozen for 24 hours** and stores the **plan chosen** (Taste / Signature /
   MasterChef) and the plan definition it was built from. If the restaurant's 3D-dish count exceeds
   the chosen plan's cap by the time of payment, payment still goes through for the plan purchased —
   the *next publish* shows the upgrade gate for anything beyond that plan's cap.
5. **Amounts are stored in paise (integers), never rupees as decimals.**
6. **Every rupee movement is a row in a ledger** (`PaymentRecord`): amount, direction, source
   (ONLINE / MANUAL / COMP), provider ids, who initiated, when. This is what accounting and
   disputes are answered from.
7. **No GST invoicing for now.** The company is not currently GST-registered; payments generate a
   simple receipt, not a formal GST invoice. GST integration (registration, GSTIN on invoices) is
   deferred to a later stage if/when the company registers (§13).
8. **PII stays where it is today.** The provider gets only what the in-app order needs (amount, a
   description, our reference id) — no phone numbers in analytics events.
9. **Payments are non-refundable, with exactly one exception: a duplicate/double payment against an
   already-active period is refunded** (§8 B3). Every other case — cancellation, downgrade, change
   of mind — is final, no full/partial/prorated refund. The duplicate-payment refund is
   **admin-triggered**: the system flags the duplicate, an admin reviews and issues the refund via
   Razorpay's refund API — it is not an automated webhook-triggered refund, keeping a human
   checkpoint on money movement (consistent with rule 1). The checkout/terms-and-consent flow must
   state: *"all payments are final, except an accidental duplicate payment, which will be refunded
   on review."*

---

## 8. Every edge case we could think of

Grouped: **A** = rep/staff, **B** = money, **C** = menu changes, **D** = states & lifecycle.

### A. Rep / staff edge cases

| # | Situation | What happens |
|---|---|---|
| A1 | **Rep publishes; owner never opens the app.** | A trial must first be started by the rep (or admin), or a plan activated, before this first publish can succeed (§4 Door 1) — no admin approval needed, but it is not automatic. Once live, reminders go to the owner's phone once the automated schedule ships (§6); until then the rep nudges manually. If nobody pays, GRACE → PAUSED (3D off, image menu stays). Nothing is lost — paying restores 3D instantly. |
| A2 | **Rep typed the wrong owner phone number.** | Because payment now happens only after logging into the app with that number (OTP), a wrong number mostly blocks the real owner from reaching their Subscription screen, rather than sending money to a stranger. Fixing the number remains the existing engineer-run repair script. **We add:** the rep's confirmation screen says *"the owner will log in and pay using this number"* to raise the stakes of reading it back. |
| A3 | **Rep wants to pay on the owner's behalf, or with cash the owner handed over.** | **Reps cannot pay via their own UPI/card standing in for the owner** — not allowed, no exceptions. The owner must pay themselves inside the app (Door 2), on the spot if present, or later. Cash the owner hands over must go through Door 3: the rep submits a manual-payment request; an ADMIN must verify it before the subscription activates — the rep cannot self-confirm. |
| A4 | **Rep is reassigned / leaves / delegation revoked.** | Nothing happens to the subscription — it belongs to the catalog. The next rep sees the same status. |
| A5 | **Two reps act on the same restaurant.** | Both see the same subscription. Both submitting a manual payment hit the same open PENDING_VERIFICATION request; only one can start the trial (the second sees it's already used). |
| A6 | **Rep needs to demo a restaurant that will never pay.** | Admin comps it (Door 4) with an expiry. Reps cannot comp. |
| A7 | **Admin / model artist publishes on behalf of a restaurant.** | Same gate applies. Staff are not exempt; they have Door 3 and 4 instead. |
| A8 | **Rep tries to game targets by marking payments.** | Not possible — reps have no permission to move a manual-payment request to `VERIFIED`. Only ADMIN (or a role explicitly granted approval permission) can verify, and every approval is audited (who submitted, who approved, when). |
| A9 | **The owner logs in for the first time months later** (OTP with the number the rep typed). | They land on their catalog with the real subscription state. If it is PAUSED, the home screen's first card is "Your 3D menu is paused — your image menu is still live — pay in-app to restore 3D". |

### B. Money edge cases

| # | Situation | What happens |
|---|---|---|
| B1 | **Payment succeeded at the bank but our webhook never arrived** (provider outage, our server asleep on Render). | Server polls the provider for any order still "open" older than 5 minutes and reconciles. Owner sees "payment received, activating…" not "unpaid". Never show "unpaid" for money that has left the owner's account without a reconcile pass first. |
| B2 | **Webhook arrives twice.** | Idempotency key; second is a no-op. |
| B3 | **Owner pays twice for the same period** (e.g. a retried payment after a slow response). | **Refunded** — the one exception to the non-refundable policy (§7 rule 9). The system flags the duplicate; an admin reviews and issues the refund via Razorpay. The ledger keeps the original PAID entry and adds a REFUNDED entry that references it (`refundsPaymentId`). |
| B4 | **Payment for a plan that no longer fits** (menu's 3D count grew past the chosen plan's cap after the order was created). | Payment is honoured for the plan purchased. The next publish shows the upgrade gate for the extra 3D dishes. |
| B5 | **Owner wants a refund for a reason other than a duplicate payment** (change of mind, cancellation, downgrade). | **Not supported.** Non-refundable, no exceptions beyond B3 (§7 rule 9). Stated in the checkout terms/consent the owner accepts before paying. |
| B6 | **Price rise.** | Existing subscriptions keep their stored plan price (frozen snapshot) until their period ends; the renewal quote uses the new price and says so. |
| B7 | **Currency.** | INR only. The product `currency` field exists for the future; not used here. |
| B8 | **Test mode vs live mode keys mixed up.** | Provider keys are part of the fail-fast typed env loader; a live server with test keys refuses to boot, same as a missing S3 bucket today. |
| B9 | **Chargeback / dispute.** | Subscription moves to GRACE (not straight to PAUSED) and admin is alerted; a dispute is not proof the owner wants the menu down, and it is not the same as the B3 duplicate-payment refund. |

### C. Menu-change edge cases

| # | Situation | What happens |
|---|---|---|
| C1 | **Adding 3D/AR dishes beyond the plan's cap.** | Editing is always allowed (drafts are free; image dishes are never capped). Publish shows the upgrade gate: *"Needs 17 AR dishes; your Signature plan covers 15 — upgrade to MasterChef to publish all of them."* Upgrading moves the subscription to the higher plan tier in-app; whether the difference is charged immediately (prorated) or takes effect at next renewal is **TBD**. |
| C2 | **Removing dishes.** | No refund or credit mid-period (§7 rule 9). The owner sees "using 9 of 15 AR slots." Downgrading to a cheaper plan only takes effect at the next renewal — no partial credit for the current period. |
| C3 | **Swapping a dish** (delete one, add one). | Same slot, free. |
| C4 | **Photo dish gets its 3D model later** (the model finished generating). | The dish still shows as an image dish on the live page until the next publish. That publish checks the plan's 3D cap. If there's room, fine; if not, the upgrade gate appears — the owner can also choose to keep it as an image dish (a per-dish "publish without 3D" toggle — deferred to a later stage, §13). |
| C5 | **3D model fails / is removed.** | The dish counts as an image dish at the next publish. The now-freed 3D slot stays within the plan's cap until renewal. |
| C6 | **Archived / hidden dishes.** | Do not count. Unarchiving counts again at the next publish. |
| C7 | **A PARTIAL publish** (some dishes failed to reach Mirage). | The 3D cap is checked on what was *attempted*, not what succeeded — the retry uses the same subscription. No double counting. |
| C8 | **Renaming the restaurant** (changes the public link slug). | No effect on subscription. |
| C9 | **Owner deletes the whole catalog** (`DELETE /catalog`). | Subscription is CANCELLED immediately. **No refund** — fixed policy (§7 rule 9); this is not a duplicate payment, so the B3 exception does not apply. The confirm dialog for delete states this. Re-creating gets the old catalog slot back but not the old subscription or its trial. |

### D. State & lifecycle edge cases

| # | Situation | What happens |
|---|---|---|
| D1 | **Restaurants already live on Mirage Menu before this feature ships.** | There are currently **no active restaurants** on Mirage Menu, but some may onboard before release. Any that do are grandfathered onto a **COMPED** plan until a **30-day** launch window closes, with reminders. Nothing goes dark on release day. |
| D2 | **Trial abuse** (delete catalog, recreate, new trial). | One trial per catalog, and the catalog slot survives deletion, so the flag survives too. A brand-new phone number is a brand-new restaurant — that is fine. |
| D3 | **Grace ends at 3 a.m.** | The sweep that moves GRACE → PAUSED runs on a schedule (the existing worker), not at the exact second. A few hours late is fine; a few hours early is not — always disable 3D *after* grace end, never before. |
| D4 | **Owner pays while the GRACE→PAUSED sweep is mid-run.** | The sweep checks the subscription state one last time before applying the 3D-disable flag and aborts if it is now ACTIVE. If it already applied, paying re-enables 3D within a minute — no republish, no re-onboarding needed. |
| D5 | **Subscription period ends while a publish is running.** | The running publish finishes (it was allowed when it started). The next publish sees GRACE. |
| D6 | **Clock skew / timezone.** | All dates stored in UTC; "days left" computed on the server and sent to the app as a number, not computed on the phone. |
| D7 | **Provider is down when the owner tries to pay in-app.** | Show "couldn't reach the payment service, try again in a minute" — never a 500, never a broken checkout screen. A rep-started trial means nothing is blocked while this is sorted out. |
| D8 | **The owner disputes "I never got the reminder".** | Every reminder send is logged (hashed phone, template, timestamp, provider message id) — once the automated schedule ships (§6, §12 Stage 6). |
| D9 | **Someone scans the QR of a PAUSED restaurant.** | They see the restaurant's normal **image-based menu** (name, price, category, photos; a placeholder for any 3D-only dish with no photo) — never a blank page, JSON, dead link, or "unavailable" placeholder for the whole menu. Only the 3D/AR viewer and 3D-dependent features are absent. Scan analytics still count it (so we can show the owner "you missed N AR views while paused" as a nudge). |
| D10 | **A dish has only a 3D asset and no photo, and the subscription enters PAUSED.** | Resolved: the dish's public card shows a **placeholder** (generic "AR preview unavailable" graphic, dish name/price still shown). No mandatory-photo-capture requirement is introduced. |

---

## 9. What the screens look like (words, not pixels)

**Owner app — new "Subscription" screen** (reachable from the catalog header badge and Profile):
- Status line + date ("Active until 14 Oct 2026, MasterChef" / "Trial — 12 days left, up to 10 3D
  dishes" / "Paused — 3D off, image menu still live").
- 3D/AR dish usage: "3D/AR dishes 12 / 15 (Signature)". Image dishes shown as unlimited.
- Plan comparison with monthly/yearly toggle (yearly = 30% off, §3).
- One button: **Pay / Renew / Upgrade** (whichever applies) → opens the **in-app checkout** (Razorpay
  SDK) — no browser tab, no leaving the app.
- Payment history list (date, amount, method, receipt download). No refund action anywhere on this
  screen — refunds are admin-only and limited to duplicate payments (§7 rule 9).

**Owner Publish screen** — the existing checklist gains the two subscription rows from §5.

**Rep — "My restaurants" list** — each row gains a small status chip (Trial 12d / Active / Overdue /
3D Paused). **Rep restaurant detail** gains a "Subscription" card: status, 3D/AR usage, and one
button **Notify owner to pay** (SMS/WhatsApp nudge to open the app) — or, if no subscription exists
yet, **Start trial** (any rep, no approval needed) or hand the phone to the owner to **pay in-app**
on the spot. No amounts are editable by the rep, no "mark paid," and **the rep cannot pay on the
owner's behalf.**

**Rep Publish screen** — same two checklist rows; the "Fix" opens the notify/start-trial card.

**Admin (web)** — per-restaurant subscription panel: current state, ledger, buttons for **Record
manual payment** (create, `PENDING_VERIFICATION`), **Verify/reject manual payment**, **Comp
until…**, **Extend grace**, **Refund** (duplicate payments only, requires a note referencing the
original payment). Plus: a **manual-payment approval queue** and a simple list: "expiring in 7
days", "in grace", "paused" — the collections call list.

---

## 10. Data we store (plain-English schema)

**`CatalogSubscription`** — one per catalog.

| Field | Meaning |
|---|---|
| `catalogId` | Which restaurant. One-to-one. |
| `status` | TRIAL · ACTIVE · GRACE · PAUSED · CANCELLED · COMPED |
| `planId` | Which plan this subscription is on: TASTE · SIGNATURE · MASTERCHEF. |
| `planSnapshot` | Frozen copy of the plan definition (price, yearly discount, 3D-dish cap, included standee count, features) at the time this period was bought. |
| `periodStart`, `periodEnd` | The paid period. A payment made during GRACE resets `periodStart` to the payment date (fresh period), not the original `periodEnd`. |
| `graceEndsAt` | `periodEnd + 7 calendar days`, set when GRACE begins. |
| `billingInterval` | MONTHLY · YEARLY |
| `trialUsedAt` | Set once, never cleared — the "one trial ever" flag. |
| `trialActivatedBy` | Which rep or admin activated the trial (`{ userId, role }`) — required since trials are no longer automatic. |
| `source` | ONLINE · MANUAL · COMP — how the current period was paid. |
| `standeeAllocation` | Complimentary standee count included with the plan (10/15/30) and how many have been issued/delivered. Additional/custom orders are tracked separately (§3a) once that feature ships. |
| `pausedAt`, `cancelledAt` | Audit. |

**`PaymentRecord`** — the ledger, many per catalog. Never edited, only appended (except the
verification fields below, which transition once).

| Field | Meaning |
|---|---|
| `catalogId`, `subscriptionId` | Links. |
| `kind` | CHECKOUT_CREATED · PAID · MANUAL · COMP · REFUNDED · DISPUTED |
| `amountPaise`, `currency` | Integer paise, INR. |
| `quote` | Frozen: plan chosen, plan definition snapshot, interval, computed total. |
| `providerOrderId`, `providerPaymentId` | Razorpay ids (ONLINE only, in-app order). |
| `idempotencyKey` | Stops double-processing. |
| `initiatedBy` | `{ userId, role }` — who *asked* for the order or submitted the manual entry. |
| `collectedBy` | MANUAL only: who physically collected the cash/cheque/transfer, if different from `initiatedBy`. |
| `verificationStatus` | MANUAL only: PENDING_VERIFICATION · VERIFIED · REJECTED. ONLINE/COMP entries are implicitly verified by the webhook/admin action that creates them. |
| `verifiedBy`, `verifiedAt` | MANUAL only: the ADMIN (or approval-permitted role) who verified/rejected the entry, and when. The subscription activates/renews only on the transition to VERIFIED. |
| `refundsPaymentId` | REFUNDED only: the `PaymentRecord` (PAID) this refund reverses. `REFUNDED` is used **only** for the §7 rule 9 duplicate-payment exception, and always requires an ADMIN actor — never automatic on webhook receipt. |
| `reference`, `note` | For MANUAL entries: UPI txn id, receipt number, admin's note. For REFUNDED: reason. |
| `createdAt` | When. |

**`ReminderLog`** — one row per reminder sent (hashed phone, template, provider id, timestamp).
Populated once the automated reminder schedule ships (§6, §12 Stage 6); not needed for the rep's
manual on-demand nudge.

**Plan catalog** — lives in the existing remote/server config: per plan (TASTE / SIGNATURE /
MASTERCHEF) — `priceMonthlyPaise`, `yearlyDiscountPct` (fixed at 30), `threeDDishCap`,
`includedStandeeCount`, `featureFlags`. Plus shared config: `trialDays` (fixed at 30),
`trialThreeDCap` (fixed at 10), `graceDays` (fixed at 7).

**What does NOT change:** `Catalog.userId` stays the owner. `publicUrl` stays frozen.
`CatalogDelegation` is untouched. Roles are untouched — no new role is needed; the rep's rights are
"see status, start trial, notify owner, submit manual-payment request", the admin's are "verify
manual payment, comp, extend grace, refund a flagged duplicate payment".

---

## 11. New server endpoints (for the engineers; skip if you are not one)

| Route | Who | Does |
|---|---|---|
| `GET /catalog/subscription` | owner | status, plan, 3D usage, renewal quote |
| `POST /catalog/subscription/order` | owner | create-or-return the open Razorpay order for **in-app checkout** (`{planId, interval}`), consumed by the SDK — no hosted link |
| `GET /rep/catalogs/:id/subscription` | rep (delegated) | same status shape as the owner's |
| `POST /rep/catalogs/:id/subscription/notify-owner` | rep (delegated) | send an on-demand SMS/WhatsApp nudge asking the owner to open the app and pay; never itself confirms payment; rate-limited per catalog |
| `POST /rep/catalogs/:id/subscription/trial` | rep (delegated) or ADMIN | Door 1: activate the one-time free trial for this catalog — no approval step, rejected only if `trialUsedAt` is already set |
| `POST /rep/catalogs/:id/subscription/manual-payment-request` | rep (delegated) | Door 3 step 1: submit a `PENDING_VERIFICATION` manual payment; does not activate anything |
| `POST /webhooks/razorpay` | provider | signature-checked; idempotent; the only automated online path that activates |
| `POST /admin/catalogs/:id/subscription/manual-payment` | ADMIN | Door 3 step 2: verify or reject a pending request (or create+verify directly) — the only action that activates a MANUAL-source subscription |
| `POST /admin/catalogs/:id/subscription/refund` | ADMIN | issue a refund for a **flagged duplicate payment only** (§7 rule 9); requires `refundsPaymentId` |
| `POST /admin/catalogs/:id/subscription/comp` | ADMIN | Door 4 |
| `GET /admin/subscriptions?state=…` | ADMIN | the collections list |

Plus: two new publish gate codes (`SUBSCRIPTION_REQUIRED` — covers both "never started" and
"lapsed/cancelled", with different copy per state — and `SUBSCRIPTION_CAPACITY_EXCEEDED` for the
3D-cap-exceeded case), one new worker job type (`SUBSCRIPTION_PAUSE`, which flips the 3D-render
entitlement flag and selects photo-vs-placeholder per dish — it must **not** call the unpublish
processor, since the image menu must stay live), one scheduled sweep (expiry → grace → pause,
order/manual-request reconciliation; the reminder-send part of the sweep ships in Stage 6, §12), and
copy for both gate codes on the client.

---

## 12. How we build it — stages

Each stage ships on its own and is useful on its own.

| Stage | What ships | Visible to restaurants? |
|---|---|---|
| **0. Decide** | The remaining DECISION NEEDED list (§13) is answered; plan catalog (Taste/Signature/MasterChef definitions, 10/15/30 standee counts, 30% yearly discount, 30-day trial with a 10-dish 3D cap, 7-day grace, 30-day grandfather window) written into config. | No |
| **1. Foundations** | `CatalogSubscription` + `PaymentRecord` models (with manual-payment verification and refund-reference fields), plan catalog in config, 3D-dish-cap checking from the publish snapshot (no image-dish cap to enforce), the two gates **switched off** behind a flag. Grandfather every live catalog as COMPED. | No |
| **2. Trial + status screens** | Rep-activated trial (no approval step) and plan activation flows exist; owner Subscription screen and rep status chip/card show real numbers; gates still off. | Yes — they see real status but nothing is enforced. |
| **3. Payments** | Razorpay **in-app order + SDK checkout** + webhook + reconciliation (no hosted checkout page); owner in-app Pay button; admin manual-payment submit/verify, comp, and duplicate-payment refund. Gates still off. | Yes — they *can* pay; nothing forces them. |
| **4. Rep tools** | Rep's **"Notify owner"** on-demand nudge (SMS/WhatsApp) and "Start trial" ship here. **Automated scheduled reminders are deferred to Stage 6.** | Yes |
| **5. Enforcement** | Gates switched **on**; grace → PAUSED sweep (3D disabled, placeholder for photo-less 3D-only dishes, image menu stays live throughout); paused-state UI; 30-day launch window for any grandfathered restaurants. | **Yes — this is launch.** |
| **6. Later** | Automated reminder schedule (SMS + WhatsApp, configurable), in-app tier-upgrade payment flow, per-dish "publish without 3D" toggle, auto-renew, GST invoicing (if/when registered), additional/custom standee purchase flow (pricing TBD, fluctuating). | — |

Rough sizing: stages 1–5 ≈ **3–4 engineering weeks** plus QA, provider onboarding (KYC for the
Razorpay account takes days, start it in stage 0), and legal copy for terms/consent (including the
non-refundable-except-duplicate-payment notice).

---

## 13. DECISION NEEDED — the list

**Resolved:**

- ~~Rate card numbers (base, per-photo, per-3D)~~ → replaced by three fixed plans (§3).
- ~~Yearly price~~ → flat **30% discount** (monthly × 12 × 0.70) (§3).
- ~~Photo/image-dish cap~~ → **none, on any plan** (§3).
- ~~3D-dish counting rule~~ → `modelStatus = READY`, and only that (§3b).
- ~~Grace length~~ → fixed at **7 calendar days** (§6).
- ~~Grace-period payment timing~~ → **starts a fresh period from the payment date** (§6).
- ~~Refund policy~~ → non-refundable, **except a duplicate payment is refunded**, admin-triggered
  (§7 rule 9).
- ~~May cash be self-confirmed by a rep?~~ → **no**, admin verification is mandatory (§4 Door 3).
- ~~Reps paying via their own UPI/card~~ → **not allowed** (§4 Door 2, A3).
- ~~Pause mechanism~~ → entitlement/feature-flag design; 3D-only dishes without a photo show a
  **placeholder** (§6, D10) — no mandatory-photo-capture requirement.
- ~~Trial length~~ → **30 days**; ~~trial 3D-dish cap~~ → **10** (matches Taste).
- ~~Trial activation / eligibility~~ → **any rep can activate directly**, no admin approval, no
  eligibility test beyond "hasn't used a trial before."
- ~~Free tier below Taste~~ → **none**; Taste is the floor.
- ~~Payment channel~~ → **in-app checkout only** (Razorpay SDK), no external hosted payment link.
- ~~Payment provider~~ → **Razorpay**, decided.
- ~~GST~~ → **not implemented now** (company not currently registered); revisit later.
- ~~Grandfather window~~ → **30 days** (there are currently no live Mirage Menu restaurants, but
  some may onboard before release).

**Still open / explicitly deferred (not blocking v1):**

1. **Reminder automation** — channel is decided (SMS + WhatsApp) but the scheduled-reminder build
   is deferred to Stage 6; only the rep's manual on-demand nudge ships at launch.
2. **Per-dish "publish as image only" toggle** — deferred to Stage 6.
3. **Additional/custom standee purchases** — pricing undefined and expected to fluctuate; the whole
   feature is deferred to Stage 6.
4. **GST invoicing details** (registration, GSTIN on invoice) — deferred until the company
   registers.
5. **Yearly-price rounding convention** for display (nearest rupee, nearest ₹10, etc.) — a
   presentation detail, not settled yet; the `× 12 × 0.70` formula is authoritative regardless.
6. **In-app-only payment consequence** — an owner who never installs/logs into the app has no
   online payment path (trial or Door 3 cash are the only routes in that case). Flagging this as a
   confirmed trade-off of the in-app-checkout decision, not a blocker.
7. **Upgrade proration** — whether moving to a higher plan tier mid-period charges the difference
   immediately (prorated) or only takes effect at the next renewal (§8 C1).

---

## 14. One-page summary for sales

- Restaurants go on one of three plans from day one: **Taste (₹1,199/mo, up to 10 3D dishes)**,
  **Signature (₹1,799/mo, up to 15)**, or **MasterChef (₹2,499/mo, up to 30, most popular)**. No
  cap on photo-only dishes, ever. Yearly billing saves **30%**. Each plan includes complimentary
  QR-code standees — **10 / 15 / 30**.
- **Any rep can start a free trial on the spot** — 30 days, up to 10 3D dishes, no approval needed.
  No trial is automatic; you choose trial or a paid plan at onboarding, every time.
- **The owner pays entirely inside the ReCapture app** — no external link, no browser tab. If
  they're with you, hand them the phone and they pay right there; otherwise, nudge them later to
  open the app.
- **You never pay on the owner's behalf and never confirm cash yourself.** If the owner pays you
  cash, submit the details in the app; **an admin must verify it before the subscription
  activates.**
- **Payments are final — no refunds** — except a genuine accidental double payment, which an admin
  refunds on review.
- If a subscription lapses, **the menu never goes dark.** The image-based menu keeps working at the
  same QR; only the 3D/AR experience switches off (a placeholder shows for any dish with no photo)
  until the plan is renewed — and everything comes back immediately on payment.
- Editing the menu is always free. Only *more 3D/AR dishes than the plan covers* requires an
  upgrade, and only at the moment of publishing.

---

## 15. Acceptance criteria — required changes, this document

**AC-1 — QR-code standee entitlement**
- AC-1.1: Activating a Taste subscription grants exactly 10 complimentary QR-code standees;
  Signature grants 15; MasterChef grants 30. No other plan feature or price changes as a result.
- AC-1.2: The included standee count is stored as part of the frozen `planSnapshot` on the
  subscription (§10), not recomputed from a formula.
- AC-1.3: No plan enforces an image/photo-dish cap, on Taste, Signature, or MasterChef.
- AC-1.4: If additional standees ever become purchasable, they are recorded as a separate line item
  distinguishable from the plan's included allocation (§3a); this stays out of scope until §12
  Stage 6.

**AC-2 — Selective free trials**
- AC-2.1: A newly onboarded catalog has no `CatalogSubscription` row until an explicit action is
  taken — no code path starts a trial automatically on first publish.
- AC-2.2: Publish is blocked with `SUBSCRIPTION_REQUIRED` until either a trial is started or a plan
  is activated.
- AC-2.3: Any REP (delegated) or ADMIN user can call `POST .../subscription/trial` directly — no
  separate approval step. The call is rejected only if `trialUsedAt` is already set on the catalog.
- AC-2.4: A catalog can receive a trial exactly once, ever (`trialUsedAt`).
- AC-2.5: A TRIAL-status subscription enforces exactly a 30-day length and a 10-dish 3D/AR cap, with
  no image-dish cap.

**AC-3 — Grace period**
- AC-3.1: `graceEndsAt` is always `periodEnd + 7 calendar days`.
- AC-3.2: During GRACE, all features (3D + image) remain available; a warning banner is shown.
- AC-3.3: A successful payment at any point during GRACE returns the subscription to ACTIVE without
  any feature having been disabled.
- AC-3.4: If GRACE elapses with no payment, the subscription transitions to PAUSED via the
  scheduled sweep, never earlier than `graceEndsAt`.
- AC-3.5: A payment completed during GRACE sets `periodStart` to the payment timestamp (a fresh
  period), never preserving the original `periodEnd` as the new cycle anchor.

**AC-4 — Image-menu fallback**
- AC-4.1: While PAUSED, `publicUrl` continues to resolve and serves the full image-based menu with
  a 200 response — never an "unavailable" page, blank page, or error for this reason.
- AC-4.2: While PAUSED, dishes with `modelStatus = READY` and a photo render the photo, not the
  3D/AR viewer; dishes with `modelStatus = READY` and no photo render the defined placeholder card,
  never a broken or missing card. 3D-dependent features (e.g. the AR-menu website embed) are
  inaccessible.
- AC-4.3: No dish, category, or 3D asset is deleted or requires recreation when entering or leaving
  PAUSED.
- AC-4.4: Paying for (or being granted) an eligible plan from PAUSED restores the 3D viewer for
  existing dishes within the same reconciliation window used for normal payments (§7 rule 1), with
  no re-onboarding or catalogue recreation step.

**AC-5 — Refund policy**
- AC-5.1: The only path that issues a refund is `POST .../subscription/refund`, and it requires a
  `refundsPaymentId` referencing an existing PAID record; no other endpoint, job, or admin action
  moves money back.
- AC-5.2: The checkout/consent flow and the admin manual-payment verification screen both display
  the "final except duplicate payment" notice before payment/verification completes.
- AC-5.3: Cancelling a subscription or downgrading a plan never triggers a refund or credit
  computation.
- AC-5.4: A REFUNDED `PaymentRecord` always requires an ADMIN actor and a `refundsPaymentId` — it is
  never created automatically on webhook receipt or by any REP-role action.

**AC-6 — Cash/offline payments**
- AC-6.1: A REP-role user can create a manual-payment request (`verificationStatus =
  PENDING_VERIFICATION`); this action alone never changes `CatalogSubscription.status`.
- AC-6.2: Only a user with ADMIN (or explicit approval) permission can transition a manual-payment
  request to `VERIFIED`; a REP-only attempt is rejected with an authorization error.
- AC-6.3: The subscription activates/renews only on the transition to `VERIFIED`, never on request
  creation.
- AC-6.4: Every manual-payment request retains `collectedBy`/`initiatedBy`, `verifiedBy`, and
  timestamps for both creation and verification, even when the same user performs both actions.
- AC-6.5: No code path allows a rep's own payment instrument to complete an owner's subscription
  payment.

**AC-7 — In-app checkout**
- AC-7.1: No subscription endpoint returns a hosted/external checkout URL; `POST
  .../subscription/order` returns a Razorpay order object consumed by the in-app SDK only.
- AC-7.2: Completing a payment never navigates the user out of the app (no browser tab, no external
  webview page).
- AC-7.3: `POST .../subscription/notify-owner` only sends a message — it never itself activates or
  confirms a payment.

**AC-8 — Yearly discount**
- AC-8.1: The yearly price offered at checkout for any plan equals `monthly price × 12 × 0.70`,
  before the display-rounding convention (§13 item 5) is applied.
