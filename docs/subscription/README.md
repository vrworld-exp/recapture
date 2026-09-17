# Subscription Layer — Implementation Pack

One agent-ready coding prompt per build stage of
[`../../RECAPTURE_SUBSCRIPTION_PLAN.md`](../../RECAPTURE_SUBSCRIPTION_PLAN.md) §12.

**Product source of truth:** the plan. It says *what* and *why*.
**Conventions source of truth:** [`../../AGENTS.md`](../../AGENTS.md). Every prompt here defers to it.
**This folder:** *in what order, in which file, and how you know it worked.*

Stage 0 (decisions) has no prompt — its outputs are the constants in Stage 1's plan catalog.
Stage 6 (later) has no prompt — it is explicitly deferred.

**Start here:** [`implement-subscription.md`](implement-subscription.md) — the run order for the
prompts, interleaved with every manual step (Razorpay, Render, Atlas, Play Console, Mirage
deploy, marketing site) and the verification gate after each one.

---

## Corrections to the plan, verified against the working tree

The prompts already incorporate these. Read them so the plan and the code do not look like they
disagree.

| # | Plan says | Code says | What the prompts do |
|---|---|---|---|
| C1 | §5 rule 3: "3D/AR dish counts are checked on the same frozen snapshot the publish uses" | The snapshot is taken by the **worker** (`mirageCatalogPublishProcessor.ts:282`), not by `requestPublish`. Gates run at request time over `publishableProducts(products)`. | The gate counts at request time over the same `publishableProducts()` list the run will send; the processor records the snapshot's count on the run for audit and **never blocks** (D5). |
| C2 | §9 "Admin (web)" | There is no admin web. Admin surfaces are Flutter screens under `lib/presentation/screens/admin/` (which also run in the web build). | Admin UI is Flutter, mirroring `admin_standees_screen.dart`. |
| C3 | §11 "`POST /rep/catalogs/:id/subscription/trial` — rep (delegated) or ADMIN" | The rep router requires a **delegation** (`resolveDelegatedCatalog`); an admin without one gets 404. | A twin `POST /admin/catalogs/:id/subscription/trial` (ADMIN, by catalog id) exists alongside the rep route. |
| C4 | §4 Door 1 implies a trial has a grace period; §6 diagram only shows `ACTIVE → GRACE`. | — (unspecified) | **TRIAL expiry follows the same path: `TRIAL → GRACE → PAUSED`.** `COMPED` past its expiry does too. Assumption, stated in Stage 5. |
| C5 | §5/§6: while PAUSED "image-dish publishing still works, 3D-dish publishing is blocked" | A publish is one atomic run over the whole catalog. | While PAUSED/CANCELLED, a publish whose 3D-counting dish count is **≥ 1** is blocked with `SUBSCRIPTION_REQUIRED`; a publish with **0** 3D-counting dishes proceeds. Assumption, stated in Stage 1. |
| C6 | §3c: plan catalog "rides along" on `/remote-config` | `remoteConfigSchema` is `.strict()` and reject-to-defaults: an invalid stored value drops the **whole** client config to defaults. | The plan catalog has its **own** Zod schema and its own reject-to-defaults reader (`planCatalogService.ts`), stored under one key on the same `client_configs` document. It is added to the served payload as a validated, pre-parsed field in Stage 2. |
| C7 | §11 "Razorpay SDK" in the app; the rep app also runs on web (`docs/next-phase/web-capability-matrix.md`) | `razorpay_flutter` is Android/iOS only. | Stage 3 ships checkout on Android/iOS; the web build shows "pay from the mobile app". Web checkout is flagged as deferred. |
| C8 | §10 `standeeAllocation` "how many have been issued/delivered" | Standee assignment is advisory, not a reservation (`standeeAssignmentService.ts`; see AGENTS.md "Standee assignment"). | `standeeAllocation` stores only `{ included, issued }` counters set by admin; it is **not** joined to `QrCodeAssignment`. |
| C9 | §12 Stage 4 ships "Start trial" | Stage 2 cannot show a trial status without a way to start one. | "Start trial" ships in **Stage 2**; Stage 4 is the nudge + rep copy. |

---

## The five stages

| # | Stage | Side | Depends on | Size | Ships behind |
|---|---|---|---|---|---|
| 1 | [Foundations — models, plan catalog, 3D count, gates (off)](stage-01-foundations.md) | BE (+ 2 client enum values) | — | M | server flag `subscriptionGatesEnabled` (absent = off) |
| 2 | [Trial + status — service, routes, owner & rep screens](stage-02-trial-and-status.md) | BE + FE | 1 | L | nothing enforced; gates still off |
| 3 | [Payments — Razorpay in-app, webhook, manual, comp, refund](stage-03-payments.md) | BE + FE | 2 | XL (two parts) | `RAZORPAY_*` env absent = checkout unavailable |
| 4 | [Rep tools — notify-owner nudge, activation copy](stage-04-rep-tools.md) | BE + FE | 2 | S | nothing |
| 5 | [Enforcement — sweep, pause job, Mirage entitlement, flag on](stage-05-enforcement.md) | BE + FE + **Mirage** | 1–4 | L (two parts) | `subscriptionGatesEnabled: true` — **this is launch** |
| A | [Gaps addendum — disputes, standee issuance, receipts, admin alerts, 2 copy fixes](gaps-addendum.md) | BE + FE | 3 | M | nothing — ship before the Stage 5 flip |

[`gaps-addendum.md`](gaps-addendum.md) also lists three items the plan asks for that **no prompt
can build** without a decision or an owner: owner-initiated cancel (G7), the marketing site's
pricing copy (G8), and upgrade proration (G9).

Each stage is one focused session for one agent (Stage 3 and 5 are two sessions each). Run the
backend suite once at the end of a stage, not per edit.

---

## Constants (Stage 0 outputs, frozen here)

| Key | Value |
|---|---|
| `TASTE` | ₹1,199/mo → `priceMonthlyPaise: 119900`, `threeDDishCap: 10`, `includedStandeeCount: 10` |
| `SIGNATURE` | ₹1,799/mo → `179900`, cap `15`, standees `15`, features `+ whatsapp_instagram_buttons` |
| `MASTERCHEF` | ₹2,499/mo → `249900`, cap `30`, standees `30`, features `+ website_embed, per_dish_analytics, priority_support` |
| `yearlyDiscountPct` | `30` — `yearlyPaise = Math.round(priceMonthlyPaise * 12 * 0.70)` |
| `trialDays` | `30` |
| `trialThreeDCap` | `10` |
| `graceDays` | `7` |
| `grandfatherDays` | `30` |
| `orderTtlHours` | `24` |
| Currency | `INR` only; all amounts integer paise |
