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

**Everything is built — going live:** [`go-live-checklist.md`](go-live-checklist.md) — the
tick-box list of what to configure on the Razorpay account, Render, Mirage (Railway + cPanel
deploy and the `arEnabled` probe) and the Flutter build, then the flag flip in the order
[`rollout.md`](rollout.md) requires. [`how-a-user-subscribes.txt`](how-a-user-subscribes.txt)
is the plain-language owner flow.

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
| C7 | §11 "Razorpay SDK" in the app; the rep app also runs on web (`docs/next-phase/web-capability-matrix.md`) | `razorpay_flutter` is Android/iOS only. | Stage 3 shipped checkout on Android/iOS with the web build showing "pay from the mobile app". **Since resolved:** `checkout_adapter_web.dart` drives Razorpay's Checkout.js overlay (fetched on demand via `dart:js_interop`) against the same order/key/webhook, so web pays in-page too. Only desktop shows the card. |
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
| B | [Edge-cases hardening — Prompt B (grace copy, early-renewal warning, PAUSED_90D, cash refund row)](edge-cases-hardening.md) | BE + FE | A, 5A | S | nothing — ship before the Stage 5 flip |
| C | [Publish-flow edge cases — F1–F10 (silent run failures, key replay, poll discipline, auto-start latch)](publish-edge-cases-hardening.md) | BE + FE | — | L | nothing — independent of the Stage 5 flip |
| D | [Testing prices + the rep-publish payment window](testing-prices-and-pending-payment.md) | BE + FE + **Mirage** | 3, 5 | M (two features) | `SUBSCRIPTION_TESTING_PRICES` (absent = real prices); the window is inert until the rep publish route passes `publishedBy` |

[`testing-prices-and-pending-payment.md`](testing-prices-and-pending-payment.md) holds two
features asked for after launch planning. **Testing prices** quote and charge the three plans at
₹3/₹5/₹7 from an env flag, so a real Razorpay flow can be walked end to end; it re-prices only,
never a running period, and the app puts a visible badge over the cards. **The pending-payment
window** is the one place in this whole system where a live customer page can go dark: a rep or
staff member publishes a restaurant nobody has paid for, it goes live with a deadline
(`PENDING_PAYMENT`), and the sweep switches the page off when the deadline passes. That is a
DEPARTURE from AC-4 — which is kept intact for every restaurant that has ever paid — and the
doc explains why the two rules coexist and which single code path separates them. It needs a
Mirage deploy first (`paymentDueAt`), exactly as Stage 5 needed one for `arEnabled`.

[`publish-edge-cases-hardening.md`](publish-edge-cases-hardening.md) is about the **press of
Publish**, not about subscriptions: ten defects in how a run reports itself, replays itself and
polls itself. It shares no code with the paywall and depends on no flag, so it can run before,
during or after the stages above. It does touch `publish_body.dart` and `publish_flow.dart`,
which Stage 5 Part A also edits — run one, then the other, not both in parallel.

[`edge-cases-hardening.md`](edge-cases-hardening.md) is also the **complete edge-case matrix**
(plan A–D plus 34 E-series cases for webhooks, the job queue, payment failures and the lapse
lifecycle) with the stage each one is handled in. Stages 3 and 5 were patched from it — a fresh
run of those prompts already includes the fixes.

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

---

## Go-live: what to do and where (as of 2026-09-21)

All code is committed. Nothing below is coding; it is the remaining manual work, in the order it
must happen. Full detail per row in [`go-live-checklist.md`](go-live-checklist.md).

| # | What | Where | Done when |
|---|---|---|---|
| 1 | Activate the Razorpay account (KYC) so Live mode is available | Razorpay Dashboard | Live mode toggle works |
| 2 | Generate API keys; copy `Key ID` + `Key Secret` | Razorpay → Settings → API Keys | Both values saved somewhere safe |
| 3 | Create the webhook: URL `https://<recapture-api host>/webhooks/razorpay`, a secret you invent, events `order.paid`, `payment.captured`, `payment.failed`, `refund.processed`, `refund.failed`, `payment.dispute.created/won/lost/closed` | Razorpay → Settings → Webhooks (once in Test mode, once in Live) | Webhook shows as active |
| 4 | Merge `feature/same-day-qr-f-phase2` → `development`, push | `mirage-be` repo (GitHub Actions → Railway `restaurant-be`) | Action green |
| 5 | Same merge + push | `mirage-fe` repo (GitHub Actions → FTP → `mirage.mayasabhaxr.co.in`) | Action green |
| 6 | Run `node scripts/verify-ar-entitlement.js logic`, then `live` with `MIRAGE_BASE_URL` / `MIRAGE_API_KEY` / `MIRAGE_TOKEN` / `MIRAGE_RESTAURANT_ID` set; open the slug on a phone with `arEnabled:false` | Your machine → `mirage-be/scripts/` | `0 failed`; phone shows photos only, then 3D again |
| 7 | Merge `development` → `production` in both Mirage repos (check `git log production..development` first); re-run the `live` probe against prod | `mirage-be`, `mirage-fe` | Prod probe `0 failed` |
| 8 | Add `RAZORPAY_KEY_ID`, `RAZORPAY_KEY_SECRET`, `RAZORPAY_WEBHOOK_SECRET`; confirm `MIRAGE_*` are correct | Render → recapture-api → Environment | Service redeployed with them |
| 9 | Deploy `recapture-api` from branch `Ashish` with `subscriptionGatesEnabled` still absent | Render → Deploy | Log shows `[subscription-sweep] to_grace=0 to_paused=0` every 10 min |
| 10 | Keep the instance awake: cron hitting `GET /health` every 5 min | Render → Cron Jobs (or `utils/axiosBackendMakeAlive.ts` elsewhere) | Sweep line arrives overnight too |
| 11 | Ship a Flutter build that contains the subscription screens | Play Console / TestFlight / web host | New build is what owners have installed |
| 12 | Staging rehearsal with `rzp_test_` keys and the flag on — the 5 steps at the bottom of `rollout.md` | Staging Render + Atlas + one test restaurant + owner app | Every step matches; then flag back to `false` |
| 13 | Grandfather live catalogs: `npx tsx scripts/grandfather-catalogs-comped.ts --dry-run`, read, then real run | Your machine, prod `MONGODB_URI` in `.env` | `comped` = the dry-run count |
| 14 | Flip: `db.client_configs.updateOne({}, { $set: { subscriptionGatesEnabled: true } })` | Atlas → Browse collections → `client_configs` | No-row catalog's `GET /catalog/publish/status` lists `SUBSCRIPTION_REQUIRED` |
| 15 | Watch 24 h; rollback is the same update with `false` | Render logs + analytics | No `ENTITLEMENT_FAILED` alerts; blocks are explainable |
| 16 | Tick the five sign-off boxes (E5/E11/E34/E41/E46); decide G7/G8/G9 | [`edge-cases-hardening.md`](edge-cases-hardening.md), [`gaps-addendum.md`](gaps-addendum.md) | Not blocking; can follow the flip |

Rows 1–3 first (everything needs the keys); 4–7 before 9 (never the other way round); 11 before
14; weekday morning IST, not a Friday.
