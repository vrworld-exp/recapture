# ReCapture — Subscription Layer: The Plan (plain-English)

> **What this is:** the full plan for charging restaurants to keep their menu live, written so
> anyone on the team (sales, product, engineering) can read it. Where a decision is still open it
> is marked **DECISION NEEDED** and collected at the bottom.
>
> **What it is not:** an implementation prompt. Once the decisions are made, the engineering
> stages at the end become the task list.

---

## 1. The idea in one paragraph

Today a restaurant (or a sales rep on its behalf) builds a menu in ReCapture and presses
**Publish**; the menu goes live at a QR link for free, forever. We want to change that to: **the
menu stays live only while the restaurant has an active subscription**, and the price of that
subscription depends on **how big the menu is** — how many dishes, and how many of them are 3D/AR
dishes versus plain photo dishes.

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
publish as often as they like, as long as the menu fits what was paid for.**

---

## 3. What is the price? (the "X")

The price is calculated from the menu itself. Three ingredients:

```
monthly price = BASE FEE
              + (number of PHOTO dishes  × photo-dish rate)
              + (number of 3D/AR dishes  × 3D-dish rate)
```

Example rate card (placeholder numbers — **DECISION NEEDED**):

| Item | Rate |
|---|---|
| Base fee (the live page, the QR, the hosting) | ₹299 / month |
| Each photo-only dish | ₹10 / month |
| Each 3D / AR dish | ₹40 / month |
| Yearly plan | pay for 10 months, get 12 |

So a restaurant with 30 photo dishes and 12 AR dishes pays `299 + 300 + 480 = ₹1,079 / month`, or
`₹10,790 / year`.

### 3a. What you are actually buying: "slots", not "these exact dishes"

This is the single most important design choice, so read it twice.

When a restaurant pays, they are **not** buying "these 30 photo dishes and these 12 AR dishes".
They are buying **capacity**: *"up to 30 photo slots and up to 12 AR slots for this period."*

Why it matters:

- They can delete "Paneer Tikka" and add "Paneer Butter Masala" — same slot, no new charge.
- They can rename, reprice, reorder, change category — none of that touches the subscription.
- The only thing that can cost more is **needing more slots than they paid for**, and that is
  checked at one moment only: **when Publish is pressed** (see §5).

A dish that is archived or deleted does not occupy a slot. Only dishes that would actually go live
count.

### 3b. Which dishes count as "3D"?

A dish counts as a **3D slot** if, at the moment of publishing, it has a usable 3D model
(`modelStatus = READY`). A dish that was added as "Capture now" but whose model is still
generating, or failed, counts as a **photo slot** — because that is what the customer will actually
see. (When the model finishes later and the next publish sends it, *that* publish will ask for a 3D
slot. See edge case E7.)

### 3c. Where the rate card lives

The rate card (base, per-photo, per-3D, yearly discount, trial length, grace length) lives in
**server config**, not in the app. Reasons:

- Changing a price must not need a Play Store release.
- The app already fetches a remote config on start (`/remote-config`); prices ride along.
- **Every subscription stores a copy of the rate card it was bought under.** If we raise prices
  next year, existing subscribers keep their price until their next renewal. Nobody gets a
  surprise mid-period.

---

## 4. Who pays, and how — the core of the rep problem

### The problem, stated plainly

A sales rep stands in a restaurant, activates a standee, photographs the dishes, and presses
Publish — all in 15 minutes, before the owner has ever opened the app. In fact:

- The owner's **account was created by the rep typing the owner's phone number**. Nobody has
  verified it. The owner might never log in.
- The rep is **not** the owner. The rep must never be the one whose card is on file — reps leave,
  get reassigned, or go on holiday, and the restaurant's menu must not die with them.
- The rep **must** still be able to walk out with a live menu that day. That is the whole point of
  same-day activation.

### The answer: three doors, one subscription

The subscription always belongs to the **restaurant's catalog**. There are three ways money can
arrive at it, and all three land in the same place.

#### Door 1 — The free trial (this is what makes same-day still work)

**Every catalog gets one free trial, automatically, the first time it is published.** During the
trial, publishing works exactly as it does today, with no slot limits (or a generous cap —
**DECISION NEEDED**, suggest 100 dishes). The rep does nothing special.

- Trial length: **DECISION NEEDED** — suggest **30 days**. Long enough for the restaurant to see
  scans on the dashboard and *want* to keep it; short enough that a "never going to pay"
  restaurant does not cost us hosting forever.
- One trial per catalog, ever. A restaurant that deletes its catalog and re-creates it does not get
  a second trial (the catalog slot is reused on delete — this already works that way).

The rep's screen shows: **"Live on trial — 30 days left. Owner pays at: [link]"**.

#### Door 2 — The payment link (the owner pays, from anywhere, without the app)

The owner does not need the app, an account, or a login to pay. They need a link.

- ReCapture creates a **hosted checkout page** through the payment provider (Razorpay — see §7).
  The page says *"Blue Cafe — 30 photo dishes, 12 AR dishes — ₹1,079/month or ₹10,790/year"* and
  takes UPI / card / net banking.
- The link is **tied to the catalog**, not to a person. **Anyone with the link can pay for that
  restaurant** — the same way anyone can pay a friend's bill. The money attaches to the catalog,
  and we record *who* initiated the link (owner / rep / admin) for the audit trail, not who typed
  the card number.
- The link can be:
  - **Sent by the rep** from the rep screen → SMS/WhatsApp to the owner's number (the same number
    the rep typed at activation). The rep sees "Link sent — waiting for payment" and can re-send.
  - **Opened by the owner** from their own "Subscription" screen after they log in.
  - **Shown as a QR** on the rep's phone for the owner to scan on the spot.
- When the payment succeeds the provider tells our server (a "webhook"), the subscription flips to
  **ACTIVE**, and both the owner's and the rep's screens update within seconds (the app already
  polls the publish status; the subscription status rides along).

**This is why the rep edge case dissolves:** the rep never enters payment details and never needs
the owner's login. The rep's only job is to make sure the owner gets the link — and the trial means
there is no pressure to do it at the table.

#### Door 3 — Offline / manual payment (cash, bank transfer, cheque)

Field sales in India means some owners will hand over cash or say "I'll transfer it". We need a
door for that or reps will improvise.

- An **ADMIN** (not the rep) records a manual payment against the catalog: amount, method, a
  reference (UPI txn id / receipt number), and a note. This activates the same subscription with
  `source = MANUAL`.
- The rep **cannot** do this themselves — it would be too easy to mark "paid" to hit a target. The
  rep raises it; admin confirms. (Same trust boundary as today: role grants are script-only, standee
  batches are admin-only.)
- Every manual entry is audited: who, when, what reference.

#### Door 4 (staff only) — Complimentary

ADMIN can mark a catalog **COMPED** with an expiry (demo restaurants, pilots, partner deals,
"sorry we broke your menu last week"). Behaves like ACTIVE with unlimited slots until the date.

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
   │     ├─ never published, no subscription yet   → start the free trial silently, continue
   │     ├─ TRIAL or ACTIVE or COMPED, and the
   │     │    menu fits the paid slots             → continue
   │     ├─ ACTIVE but menu needs MORE slots       → row: "Menu has grown — 14 AR dishes, plan
   │     │                                            covers 12. Upgrade (₹+80/month, prorated)"
   │     ├─ GRACE (payment overdue, still live)    → continue, but show a warning banner
   │     └─ EXPIRED / PAUSED / CANCELLED           → row: "Subscription needed — Pay ₹1,079" /
   │                                                  rep sees "Send payment link to owner"
   │
   └─ all green → the publish job runs exactly as today
```

Plain rules:

1. **The subscription check is a gate, not a payment step.** Publish never takes money. It only
   answers "are you allowed to be live with this menu right now?".
2. **The "Fix" button on the gate row does the right thing for who is looking at it.** Owner → opens
   the pay/upgrade page. Rep → opens "send the payment link to the owner" (and shows the link's
   QR). Admin → can also record a manual payment or comp.
3. **Slots are counted on the same frozen snapshot the publish uses**, so the number the gate quotes
   is the number that goes live. No "it said 12 but published 13".
4. **A publish that is already running is never interrupted** by a subscription change. The next
   publish sees the new state.

---

## 6. What happens when the subscription runs out

The QR on the table must never become a dead link — `publicUrl` is frozen for exactly this reason.
So "running out" is a **sequence**, not a switch:

```
ACTIVE ──(period ends, no renewal)──► GRACE ──(grace ends)──► PAUSED ──(paid)──► ACTIVE
                                       7 days                  menu shows a
                                       still live,             "menu is paused"
                                       reminders               page at the same QR
```

| State | Customer scanning the QR sees | Owner / rep sees | Can publish? |
|---|---|---|---|
| **TRIAL** | The live menu | "Trial — N days left" + pay link | Yes |
| **ACTIVE** | The live menu | "Active until <date>" | Yes (within slots) |
| **GRACE** | The live menu | Red banner "Payment overdue — menu pauses in N days" | Yes, with warning |
| **PAUSED** | A polite page: restaurant name, logo, "This menu is temporarily unavailable" and the restaurant's phone number | "Menu paused — pay to restore" | No (gate) |
| **COMPED** | The live menu | "Complimentary until <date>" | Yes |
| **CANCELLED** (owner asked) | Same as PAUSED | "Cancelled — resubscribe anytime" | No (gate) |

Reminders go to the owner's phone (SMS/WhatsApp) at **7 days before**, **1 day before**, **on
expiry**, and **midway through grace**. The rep who activated the restaurant sees the same
countdown on their "My restaurants" list so they can nudge in person.

### How "paused" actually works underneath (engineering note, still plain)

Two options. **Recommend option A for version 1.**

- **Option A — pause = unpublish.** When grace ends, ReCapture runs the *existing* unpublish job:
  the dishes are removed from the public Mirage page and the QR resolves to a "paused" page (we
  already have a "not live yet" fallback page; this is a sibling of it). Paying again runs a normal
  publish, which re-creates the dishes. **Cost:** Mirage's per-dish analytics history restarts,
  because the dishes get new ids. **Benefit:** zero changes to Mirage; uses two jobs we already
  trust.
- **Option B — a real "paused" flag on the Mirage restaurant.** Dishes stay where they are; the
  public page shows a "paused" banner and hides the menu. Keeps analytics history. **Cost:** a
  small change to both Mirage backend and frontend, and Mirage is a separate deploy.

---

## 7. Payment provider and the money-handling rules

**Recommendation: Razorpay** — UPI is non-negotiable for Indian restaurants, and Razorpay's hosted
checkout and payment links avoid us ever seeing a card number (so no PCI burden).

**Prepaid periods, not auto-debit, for version 1.** Auto-renewing card/UPI mandates in India
(RBI e-mandate rules) add OTP-on-every-renewal friction and a lot of failure handling. Version 1
sells **prepaid** months/years; renewal is "pay again before the date" with reminders. Auto-renew
is a version 2 item.

Rules the code must follow, in plain words:

1. **Never trust the app about money.** The app never says "I paid". Only the provider's webhook
   (server-to-server, signature-checked) or an admin's manual entry can activate a subscription.
2. **Every payment has an idempotency key.** The provider may deliver the same webhook twice; the
   second one must do nothing. A double-tapped "Pay" must not create two checkouts.
3. **One open checkout per catalog at a time.** If a second checkout is requested while one is
   open (owner *and* rep both pressed the button), the same link is returned, not a new one.
4. **The quote on the checkout is frozen for 24 hours** and stores the slot counts and the rate
   card it was built from. If the menu grew in between, the payment still goes through for what was
   quoted — the *next publish* will simply ask for the extra slots (an upgrade, prorated).
5. **Amounts are stored in paise (integers), never rupees as decimals.**
6. **Every rupee movement is a row in a ledger** (`PaymentRecord`): amount, direction, source
   (ONLINE / MANUAL / COMP / REFUND), provider ids, who initiated, when. This is what accounting,
   refunds and disputes are answered from.
7. **GST invoice** is generated per successful payment (provider can do this, or we template it —
   **DECISION NEEDED** whether the company is GST-registered and whether the invoice needs the
   restaurant's GSTIN).
8. **PII stays where it is today.** The payment link goes to the owner's phone, which the server
   already has; the app still never sees the raw number. The provider gets only what the checkout
   needs (amount, a description, our reference id). No phone numbers in analytics events.

---

## 8. Every edge case we could think of

Grouped: **A** = rep/staff, **B** = money, **C** = menu changes, **D** = states & lifecycle.

### A. Rep / staff edge cases

| # | Situation | What happens |
|---|---|---|
| A1 | **Rep publishes; owner never opens the app.** | Trial starts on first publish. Reminders go to the owner's phone. Rep sees the countdown. Owner can pay from the link with no login. If nobody pays, GRACE → PAUSED. Nothing is lost — the data stays; paying restores it. |
| A2 | **Rep typed the wrong owner phone number.** | The payment link goes to a stranger. They *could* pay for a menu that is not theirs (harmless to us; the stranger is out of pocket — mitigated by the checkout page naming the restaurant). Fixing the number is the existing engineer-run repair script; this feature does not make that worse. **We add:** the rep's confirmation screen now also says *"payment reminders will go to this number"* to raise the stakes of reading it back. |
| A3 | **Rep wants to pay on the spot from their own phone / with cash the owner handed over.** | Allowed via the link (money attaches to the catalog regardless of whose UPI it came from). Cash goes through Door 3 (admin records it). Company policy question: **DECISION NEEDED** whether reps may pay through their own accounts at all. |
| A4 | **Rep is reassigned / leaves / delegation revoked.** | Nothing happens to the subscription — it belongs to the catalog. The next rep sees the same status. |
| A5 | **Two reps act on the same restaurant.** | Both see the same subscription. Both pressing "send link" returns the same open checkout (rule 7.3). |
| A6 | **Rep needs to demo a restaurant that will never pay.** | Admin comps it (Door 4) with an expiry. Reps cannot comp. |
| A7 | **Admin / model artist publishes on behalf of a restaurant.** | Same gate applies. Staff are not exempt; they have Door 3 and 4 instead. |
| A8 | **Rep tries to game targets by marking payments.** | Not possible — reps have no "mark paid" control. Only ADMIN records manual payments, and each entry carries who did it. |
| A9 | **The owner logs in for the first time months later** (OTP with the number the rep typed). | They land on their catalog with the real subscription state. If it is PAUSED, the home screen's first card is "Your menu is paused — pay ₹X to restore". |

### B. Money edge cases

| # | Situation | What happens |
|---|---|---|
| B1 | **Payment succeeded at the bank but our webhook never arrived** (provider outage, our server asleep on Render). | Server polls the provider for any checkout still "open" older than 5 minutes and reconciles. Owner sees "payment received, activating…" not "unpaid". Never show "unpaid" for money that has left the owner's account without a reconcile pass first. |
| B2 | **Webhook arrives twice.** | Idempotency key; second is a no-op. |
| B3 | **Owner and rep both pay** (link forwarded, both tapped). | The second payment against an already-active period is auto-refunded by the provider API, and a ledger row records it. (Alternative: credit it to the next period — **DECISION NEEDED**.) |
| B4 | **Payment for a quote that is now out of date** (menu grew after the link was sent). | Payment is honoured for the quoted slots. Next publish shows the upgrade gate for the extra dishes. |
| B5 | **Owner wants a refund.** | Manual, admin-only, via the ledger; policy **DECISION NEEDED** (suggest: pro-rata for yearly within 14 days, none for monthly). |
| B6 | **Price rise.** | Existing subscriptions keep their stored rate card until their period ends; the renewal quote uses the new card and says so. |
| B7 | **Currency.** | INR only. The product `currency` field exists for the future; not used here. |
| B8 | **Test mode vs live mode keys mixed up.** | Provider keys are part of the fail-fast typed env loader; a live server with test keys refuses to boot, same as a missing S3 bucket today. |
| B9 | **Chargeback / dispute.** | Subscription moves to GRACE (not straight to PAUSED) and admin is alerted; a dispute is not proof the owner wants the menu down. |

### C. Menu-change edge cases

| # | Situation | What happens |
|---|---|---|
| C1 | **Adding dishes beyond paid slots.** | Editing is always allowed (drafts are free). Publish shows the upgrade gate: *"Needs 2 more AR slots — ₹80 for the remaining 20 days"*. Prorated upgrade, instant. |
| C2 | **Removing dishes.** | No refund mid-period; the slot count on the *next renewal quote* is lower. The owner sees "you are using 10 of 12 AR slots". |
| C3 | **Swapping a dish** (delete one, add one). | Same slot, free. |
| C4 | **Photo dish gets its 3D model later** (the model finished generating). | The dish still shows as a photo dish on the live page until the next publish. That publish asks for a 3D slot. If the plan has a free 3D slot, fine; if not, the upgrade gate appears — the owner can also choose to keep it as a photo dish (there is a per-dish "publish without 3D" toggle — **DECISION NEEDED** whether to build this in v1 or just show the gate). |
| C5 | **3D model fails / is removed.** | The dish counts as a photo slot at the next publish. The now-unused 3D slot remains paid for until renewal. |
| C6 | **Archived / hidden dishes.** | Do not count. Unarchiving counts again at the next publish. |
| C7 | **A PARTIAL publish** (some dishes failed to reach Mirage). | Slots are counted on what was *attempted*, not what succeeded — the retry uses the same subscription. No double counting. |
| C8 | **Renaming the restaurant** (changes the public link slug). | No effect on subscription. |
| C9 | **Owner deletes the whole catalog** (`DELETE /catalog`). | Subscription is CANCELLED immediately, no refund by default (**DECISION NEEDED**). The confirm dialog for delete now says so. Re-creating gets the old catalog slot back but not the old subscription. |

### D. State & lifecycle edge cases

| # | Situation | What happens |
|---|---|---|
| D1 | **Restaurants that are already live today**, before this feature ships. | Grandfathered: they are put on a **COMPED** plan until a launch date (e.g. 60 days after release), with reminders. Nothing goes dark on release day. |
| D2 | **Trial abuse** (delete catalog, recreate, new trial). | One trial per catalog, and the catalog slot survives deletion, so the flag survives too. A brand-new phone number is a brand-new restaurant — that is fine. |
| D3 | **Grace ends at 3 a.m.** | The pause job runs on a schedule (the existing worker), not at the exact second. A few hours late is fine; a few hours early is not — always pause *after* the grace end, never before. |
| D4 | **Owner pays while a pause job is mid-run.** | The pause job checks the subscription state one last time before touching Mirage and aborts if it is now ACTIVE. If it already paused, the payment's normal "restore = publish" path brings it back within a minute. |
| D5 | **Subscription period ends while a publish is running.** | The running publish finishes (it was allowed when it started). The next publish sees GRACE. |
| D6 | **Clock skew / timezone.** | All dates stored in UTC; "days left" computed on the server and sent to the app as a number, not computed on the phone. |
| D7 | **Provider is down when the rep presses "send link".** | Same pattern as Mirage being asleep during publish: show "couldn't reach the payment service, try again in a minute" — never a 500, never a fake link. The trial means nothing is blocked. |
| D8 | **The owner disputes "I never got the reminder".** | Every reminder send is logged (hashed phone, template, timestamp, provider message id). |
| D9 | **Someone scans the QR of a paused restaurant.** | The paused page — restaurant name, logo, phone. Never a blank, never JSON, never a redirect loop. Scan analytics still count it (so we can show the owner "you missed 340 scans while paused" — a strong nudge). |

---

## 9. What the screens look like (words, not pixels)

**Owner app — new "Subscription" screen** (reachable from the catalog header badge and Profile):
- Status line + date ("Active until 14 Oct 2026" / "Trial — 12 days left" / "Paused").
- Slot usage: "Photo dishes 24 / 30 · AR dishes 12 / 12".
- Price breakdown for renewal, monthly vs yearly toggle.
- One button: **Pay / Renew / Upgrade** (whichever applies) → opens hosted checkout in a browser tab.
- Payment history list (date, amount, method, invoice download).

**Owner Publish screen** — the existing checklist gains the two subscription rows from §5.

**Rep — "My restaurants" list** — each row gains a small status chip (Trial 12d / Active / Overdue /
Paused). **Rep restaurant detail** gains a "Subscription" card: status, slot usage, and one button
**Send payment link** (SMS/WhatsApp to the owner's number, plus a QR of the link to show on the
spot). No amounts are editable by the rep. No "mark paid".

**Rep Publish screen** — same two checklist rows; the "Fix" opens the send-link card.

**Admin (web)** — per-restaurant subscription panel: current state, ledger, buttons for **Record
manual payment**, **Comp until…**, **Extend grace**, **Refund** (each requiring a note). Plus a
simple list: "expiring in 7 days", "in grace", "paused" — the collections call list.

---

## 10. Data we store (plain-English schema)

**`CatalogSubscription`** — one per catalog.

| Field | Meaning |
|---|---|
| `catalogId` | Which restaurant. One-to-one. |
| `status` | TRIAL · ACTIVE · GRACE · PAUSED · CANCELLED · COMPED |
| `photoSlots`, `threeDSlots` | What the current period covers. |
| `periodStart`, `periodEnd` | The paid period. |
| `graceEndsAt` | Set when GRACE begins. |
| `rateCard` | A frozen copy of the prices this period was bought at. |
| `billingInterval` | MONTHLY · YEARLY |
| `trialUsedAt` | Set once, never cleared — the "one trial ever" flag. |
| `source` | ONLINE · MANUAL · COMP — how the current period was paid. |
| `pausedAt`, `cancelledAt` | Audit. |

**`PaymentRecord`** — the ledger, many per catalog. Never edited, only appended.

| Field | Meaning |
|---|---|
| `catalogId`, `subscriptionId` | Links. |
| `kind` | CHECKOUT_CREATED · PAID · REFUNDED · MANUAL · COMP · DISPUTED |
| `amountPaise`, `currency` | Integer paise, INR. |
| `quote` | Frozen: slot counts, rate card, interval, computed total. |
| `providerCheckoutId`, `providerPaymentId` | Razorpay ids. |
| `idempotencyKey` | Stops double-processing. |
| `initiatedBy` | `{ userId, role }` — owner / rep / admin. Who *asked* for the link, not who paid. |
| `reference`, `note` | For MANUAL entries: UPI txn id, receipt number, admin's note. |
| `createdAt` | When. |

**`ReminderLog`** — one row per reminder sent (hashed phone, template, provider id, timestamp).

**Rate card** — lives in the existing remote/server config: `basePaise`, `photoDishPaise`,
`threeDDishPaise`, `yearlyMonthsCharged`, `trialDays`, `graceDays`, `trialSlotCap`.

**What does NOT change:** `Catalog.userId` stays the owner. `publicUrl` stays frozen.
`CatalogDelegation` is untouched. Roles are untouched — no new role is needed; the rep's rights are
"see status, send link", the admin's are "record, comp, refund".

---

## 11. New server endpoints (for the engineers; skip if you are not one)

| Route | Who | Does |
|---|---|---|
| `GET /catalog/subscription` | owner | status, slots, usage, renewal quote |
| `POST /catalog/subscription/checkout` | owner | create-or-return the open checkout link (`{interval}`) |
| `GET /rep/catalogs/:id/subscription` | rep (delegated) | same status shape as the owner's |
| `POST /rep/catalogs/:id/subscription/send-link` | rep (delegated) | create-or-return checkout, send SMS/WhatsApp to the owner; rate-limited per catalog |
| `POST /webhooks/razorpay` | provider | signature-checked; idempotent; the ONLY online path that activates |
| `POST /admin/catalogs/:id/subscription/manual-payment` | ADMIN | Door 3 |
| `POST /admin/catalogs/:id/subscription/comp` | ADMIN | Door 4 |
| `POST /admin/catalogs/:id/subscription/refund` | ADMIN | ledger + provider refund |
| `GET /admin/subscriptions?state=…` | ADMIN | the collections list |

Plus: two new publish gate codes (`SUBSCRIPTION_REQUIRED`, `SUBSCRIPTION_CAPACITY_EXCEEDED`), one
new worker job type (`SUBSCRIPTION_PAUSE`, which reuses the unpublish processor), one scheduled
sweep (expiry → grace → pause, reminders, checkout reconciliation), and copy for both gate codes on
the client. The webhook route joins `/r/:code` as a non-envelope exception (the provider expects a
bare 200) and must be written up in `AGENTS.md` as such.

---

## 12. How we build it — stages

Each stage ships on its own and is useful on its own.

| Stage | What ships | Visible to restaurants? |
|---|---|---|
| **0. Decide** | The DECISION NEEDED list below is answered; rate card written down. | No |
| **1. Foundations** | `CatalogSubscription` + `PaymentRecord` models, rate card in config, slot counting from the publish snapshot, the two gates **switched off** behind a flag. Grandfather every live catalog as COMPED. | No |
| **2. Trial + status screens** | Trial starts on first publish; owner Subscription screen and rep status chip/card show real numbers; gates still off. | Yes — they see "Trial — N days" but nothing is enforced. |
| **3. Payments** | Razorpay checkout + webhook + reconciliation; owner "Pay" button; admin manual-payment & comp. Gates still off. | Yes — they *can* pay; nothing forces them. |
| **4. Rep send-link + reminders** | Rep's "Send payment link" (SMS/WhatsApp), reminder schedule, `ReminderLog`. | Yes |
| **5. Enforcement** | Gates switched **on**; grace → pause sweep; paused page on the QR; launch date for grandfathered restaurants. | **Yes — this is launch.** |
| **6. Later** | Prorated upgrades in-app, per-dish "publish without 3D", auto-renew, yearly invoices with GSTIN, Option B "true pause" on Mirage. | — |

Rough sizing: stages 1–5 ≈ **3–4 engineering weeks** plus QA, provider onboarding (KYC for the
Razorpay account takes days, start it in stage 0), and legal copy for terms/refunds.

---

## 13. DECISION NEEDED — the list

1. **Rate card numbers** (base, per-photo, per-3D, yearly discount). Placeholder in §3.
2. **Trial length** (suggest 30 days) and **trial slot cap** (suggest 100 dishes, or none).
3. **Grace length** (suggest 7 days).
4. **Is there a free tier** (e.g. up to 5 photo dishes free forever)? Suggest *no* for v1 — it
   complicates the pitch and the gate; a trial does the same job.
5. **Refund policy** (suggest: yearly pro-rata within 14 days; monthly none; always admin-manual).
6. **Double payment** → auto-refund or credit next period? (suggest refund).
7. **May reps pay through their own UPI** when the owner hands them cash, or must cash go via admin
   manual entry only? (suggest admin only, for audit).
8. **GST** — is the company registered, do invoices need the restaurant's GSTIN?
9. **Delete catalog while subscribed** — cancel without refund? (suggest yes, stated in the dialog).
10. **Pause mechanism** — Option A (unpublish, no Mirage change) for v1? (suggest yes).
11. **Per-dish "publish as photo only"** toggle in v1 or later? (suggest later).
12. **Grandfather window** for already-live restaurants (suggest 60 days from release).
13. **Reminder channel** — SMS, WhatsApp, or both? (The SMS provider is still a stub today; this
    feature needs a real one — that is a prerequisite, not an option.)

---

## 14. One-page summary for sales

- Restaurants get **30 days free** from their first publish. Nothing changes on activation day.
- After that it costs **a base fee + a small amount per dish**, more for AR dishes. Bigger menu,
  bigger price; the app shows the exact number.
- The **owner pays by link** — UPI/card — no app needed. You can send the link from your phone.
- **You never handle payment details.** Cash goes to the office, the office records it.
- If they don't pay, the menu **pauses** (the QR shows "temporarily unavailable" with their phone
  number). Nothing is deleted. Paying brings it back within a minute.
- Editing the menu is always free. Only *more dishes than they paid for* costs more, and only when
  they publish.
