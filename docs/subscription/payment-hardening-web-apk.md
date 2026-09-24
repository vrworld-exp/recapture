# HARDENING: Instant payment activation — production-ready on Web and Android APK
# Product: Mirage Menu (ReCapture backend `recapture-api/` + Flutter client)
# Scope: Bug Fix / Hardening
# Priority: High — run before the subscription enforcement flag is flipped

---

## Background (why this exists)

On 2026-09-23 a real ₹3 TASTE payment (`order_TfXqkH4ySXbiAe` / `pay_TfXqss8f0rsgws`) was
CAPTURED at Razorpay but the catalog stayed on free: the backend ran on localhost, the webhook
could not reach it, and the instant client-verify path did not exist yet. Commit `8802ec9`
added that path (`POST /catalog/subscription/verify`) plus settle-on-read. This prompt closes
the remaining gaps so activation is reliable on **Flutter Web** and the **Android release
APK**, with the webhook and reconciler as backups only.

Already built — do NOT rebuild: signature check (`verifyCheckoutSignature`), Razorpay
captured-status check, amount-from-Razorpay-vs-frozen-quote, `payment:<id>` idempotency,
conditional `appliedAt` stamp, settle-on-read in `GET /catalog` and
`GET /catalog/subscription`, the 2-minute activation poll, the reconciler.

`.env` values (live vs test keys, `SUBSCRIPTION_TESTING_PRICES`, database URI) are handled by
the owner by hand — do NOT edit `recapture-api/.env`.

---

## Task Description

Backend
- [ ] B1. Refuse to boot when `NODE_ENV=production` and `SUBSCRIPTION_TESTING_PRICES=true`.
- [ ] B2. Make the test suite independent of the developer's local `.env` testing prices.
- [ ] B3. Rate-limit `POST /catalog/subscription/verify` per catalog.
- [ ] B4. Emit one analytics event per verify call carrying its result, so the instant path's
      success rate is measurable.

Client (shared by Web + APK)
- [ ] C1. In the `confirming` phase, give the owner a "Check again" action that re-reads the
      subscription once (which triggers settle-on-read on the server).
- [ ] C2. When the app opens (cold start or resume) with a paid-but-unrecorded order, the
      first subscription read must activate it — no new code expected; add a test proving it.

Web
- [ ] W1. Checkout script blocked (ad blocker / offline) → clear message, no stuck spinner.
- [ ] W2. Tab closed or reloaded after paying, before verify → next load shows ACTIVE.

Android APK
- [ ] A1. Release (R8/minified) build must keep Razorpay classes — add ProGuard keep rules if
      missing.
- [ ] A2. Activity killed while the owner is in a UPI app ("Don't keep activities" / low-RAM
      phone) → after returning, the plan still activates without a new payment.
- [ ] A3. Android back button while `activating` → no "failed" state, no crash; the plan is
      ACTIVE on the next visit to the Subscription screen.

## Files to Inspect First

1. `recapture-api/src/services/subscription/clientVerifyService.ts` — the instant path.
2. `recapture-api/src/routes/catalog.ts` (lines ~1308–1409) — `GET /subscription`,
   `POST /subscription/order`, `POST /subscription/verify`, and the `rateLimited()` helper
   plus an existing `consumeRateWindow` usage (~line 1263) to copy.
3. `recapture-api/src/services/subscription/reconcileService.ts` — `settleOpenOrdersOnRead`.
4. `recapture-api/src/config/env.ts` — `SUBSCRIPTION_TESTING_PRICES` (~line 736), the live-key
   guard (~line 807) whose refusal style B1 copies, the boot warning (~line 860).
5. `recapture-api/vitest.config.ts` and `recapture-api/tests/subscription-reconcile.test.ts`,
   `tests/subscription-webhook.test.ts` — the 7 tests that fail when local `.env` has
   `SUBSCRIPTION_TESTING_PRICES=true`.
6. `recapture-api/src/validation/analyticsSchemas.ts` + `recapture-api/src/utils/rateLimit.ts`.
7. `lib/application/catalog/checkout_notifier.dart` — phases, poll, lifecycle pause/resume.
8. `lib/application/catalog/checkout_adapter_web.dart` and `checkout_adapter_io.dart`.
9. `lib/application/catalog/subscription_sync.dart` — app-level resume re-read.
10. The Subscription screen widget that renders `CheckoutPhase.confirming` (find it via
    `CheckoutPhase.confirming` usages under `lib/presentation/`).
11. `android/app/build.gradle*` and `android/app/proguard-rules.pro` (may not exist).
12. `test/catalog/checkout_notifier_test.dart`, `test/catalog/payments_fakes.dart`.

## Implementation Instructions

### Step 1 (B1): Production refuses testing prices
In `env.ts`, beside the existing live-key refusal, add: if `NODE_ENV === 'production'` and
`SUBSCRIPTION_TESTING_PRICES` is true → throw at boot with a message naming the variable.
Replace the `🚨 … THIS IS PRODUCTION.` warning branch (now unreachable) — keep the non-production
warning as is. Add a test in `tests/env-razorpay-keys.test.ts` (or a sibling) covering both
production-refuses and development-allows.

### Step 2 (B2): Tests ignore local testing prices
In `recapture-api/vitest.config.ts`, set `test.env.SUBSCRIPTION_TESTING_PRICES = 'false'` so the
value is forced before `env.ts` loads. Suites that deliberately test testing prices must set it
themselves (check `tests/` for any that do and keep them passing). Verify: with
`SUBSCRIPTION_TESTING_PRICES=true` in `.env`, the full suite passes.

### Step 3 (B3): Rate-limit verify
In the `/subscription/verify` handler, after `findOwnedCatalog`, call
`consumeRateWindow(\`subscription-verify:${catalogId}\`, env.SUBSCRIPTION_VERIFY_MAX_PER_WINDOW, env.SUBSCRIPTION_VERIFY_WINDOW_SECONDS)`
and return `rateLimited(res, rate.retryAfter)` when limited. Add both vars to `env.ts` with
defaults `20` and `600`, and document them in `.env.example` (NOT `.env`). The limit must sit
BEFORE `verifyClientPayment` so a limited call never reaches Razorpay.

### Step 4 (B4): Verify analytics
Add `AnalyticsEvent.SUBSCRIPTION_CLIENT_VERIFY` (`subscription_client_verify`) to
`analyticsSchemas.ts` and track it in the route for every outcome, including rate-limited.

### Step 5 (C1): "Check again" in confirming
Add `Future<void> checkAgain()` to `CheckoutNotifier`: allowed only in `confirming`; sets
`activating`, runs one `_checkOnce()` pass with a fresh short budget (reuse the poll with
`_pollStartedAt = now`, budget = `checkoutPollBudgetProvider`). Render a "Check again" button in
the confirming UI next to the existing dismiss. Copy: "Check again". Never show "unpaid".

### Step 6 (C2 / W2 / A2): Prove recovery on next open
No production code change is expected — `GET /catalog` and `GET /catalog/subscription` already
settle. Add:
- backend test: an order paid at the (fake) provider with no verify, no webhook, no worker →
  first `GET /catalog` after a fresh process-level state reset (`resetOnReadSettleState()`)
  returns the ACTIVE summary. If an equivalent test already exists in
  `subscription-reconcile.test.ts`, extend it rather than duplicating.
- client test: notifier disposed mid-`activating` (simulates back button / killed activity) →
  a fresh `subscriptionProvider` read returning ACTIVE renders the plan; no `failed` state was
  ever emitted.

### Step 7 (W1): Blocked script
Confirm `RazorpayWebCheckoutAdapter.open` returns a non-success outcome (not a hang) when the
script fails to load, and that the notifier maps it to a visible, retryable message. Add a web
adapter test if the blocked path is not already covered in
`test/catalog/web/checkout_adapter_web_test.dart`. The next tap must re-inject the script.

### Step 8 (A1): R8 keep rules
If `android/app/build.gradle*` enables `minifyEnabled`/`isMinifyEnabled` for release, ensure
`proguard-rules.pro` is referenced and contains:
```
-keepattributes *Annotation*
-dontwarn com.razorpay.**
-keep class com.razorpay.** { *; }
-optimizations !method/inlining/
-keepclasseswithmembers class * { public void onPayment*(...); }
```
If minification is off, leave the build file unchanged and note it in the PR description.

### Step 9 (A3): Back button
Verify `CheckoutNotifier`'s `ref.onDispose` cancels the poll without writing state and that no
route pop during `activating` surfaces an error snackbar. Fix only if a failure surfaces.

## API / Data Contract

`POST /catalog/subscription/verify` — body unchanged `{ orderId, paymentId, signature }`.
New response: `429` with the existing rate-limited envelope and `Retry-After` header.
The client must treat 429 exactly like any other verify failure (log, then keep polling).

## Analytics Events

Event: `subscription_client_verify` (backend)
Trigger: every `POST /catalog/subscription/verify` response
Properties:
  - catalog_id: string
  - result: "RECORDED" | "PENDING" | "BAD_SIGNATURE" | "UNKNOWN_ORDER" | "UNAVAILABLE" | "RATE_LIMITED"
  - outcome: string | null   (the `OnlinePaymentOutcome` when RECORDED)
No payment id, order id, phone or name in the properties (PII rule) — hash ids with the
existing `hashIdentifier` if one is needed.

Event: `checkout_check_again` (client)
Trigger: owner taps "Check again" in the confirming state
Properties: `{ surface: 'owner' }`

## What NOT to Change

- Do NOT edit `recapture-api/.env` — the owner manages it.
- Do NOT change `verifyCheckoutSignature`, `verifyWebhookSignature`, `recordOnlinePayment`,
  `recordPaidRow`, `applyRecordedPayment` or `applyPaidPeriod` logic.
- Do NOT change the `PaymentRecord` schema or its unique indexes.
- Do NOT remove or weaken the webhook route or the reconciler; they stay as backups.
- Do NOT accept amount, plan or interval from the client on verify.
- Do NOT show "unpaid"/"payment failed" after the Razorpay sheet reported success.
- Do NOT touch `PublishFlow` or the offline action queue (subscription mutations never queue).
- Do NOT add a rate limit to `GET /catalog` or `GET /catalog/subscription` (settle-on-read is
  already throttled per catalog at 5 s).

## Edge Cases to Handle

- [ ] Verify rate-limited (429) → client keeps polling; plan still activates via settle-on-read.
- [ ] Verify times out on a cold backend (> 75 s `receiveTimeout`) → poll continues →
      `confirming` → "Check again" or next app open activates.
- [ ] Web: checkout script blocked → retryable message; next tap re-injects the script.
- [ ] Web: tab reloaded after paying → first load shows ACTIVE.
- [ ] APK: activity destroyed during UPI → returning to the app activates the plan; no second
      order is created for the same intent (server returns the open order).
- [ ] APK: back pressed while `activating` → no error UI; plan ACTIVE on next visit.
- [ ] "Check again" tapped twice quickly → one pass (guard with `isBusy`).
- [ ] Production boot with `SUBSCRIPTION_TESTING_PRICES=true` → process exits with a clear error.

## Constraints

- Every new route guard uses `consumeRateWindow` and the existing `rateLimited()` helper —
  no new rate-limit mechanism.
- New env vars get Zod schemas with defaults in `env.ts`; missing vars must not break boot.
- Tests use the Razorpay fake (`setRazorpayClient`) — no test may call the live API.
- Client copy never promises "instant"; the confirming line says it is being confirmed.

## Acceptance Criteria

- [ ] `cd recapture-api && npx vitest run` passes with `SUBSCRIPTION_TESTING_PRICES=true` AND
      with it `false` in the local `.env`.
- [ ] `cd recapture-api && npx tsc --noEmit` passes.
- [ ] `flutter analyze` reports no new issues; `flutter test` passes.
- [ ] Booting with `NODE_ENV=production SUBSCRIPTION_TESTING_PRICES=true` fails with a message
      naming `SUBSCRIPTION_TESTING_PRICES`.
- [ ] 21st verify call for one catalog inside 10 minutes returns 429 and does not call Razorpay
      (asserted via the fake's call count).
- [ ] `subscription_client_verify` is tracked once per verify response with the correct `result`.
- [ ] Web (Chrome desktop + Android Chrome): pay → plan shows ACTIVE within 5 s of the sheet
      closing, with no webhook reachable (localhost backend).
- [ ] Web: with an ad blocker blocking `checkout.razorpay.com`, tapping Pay shows a retryable
      message within 10 s; no spinner remains.
- [ ] Android release APK (`flutter build apk --release`) on a mid-range device: pay by UPI →
      ACTIVE within 5 s of returning to the app.
- [ ] Android with Developer options → "Don't keep activities" ON: pay by UPI → after returning,
      the plan becomes ACTIVE (on resume or on reopening the Subscription screen) without paying
      again.
- [ ] Android: back button during `activating` → no error UI; plan ACTIVE on next visit.
- [ ] "Check again" appears only in `confirming` and moves to `done` when the server is ACTIVE.
- [ ] No file listed under "What NOT to Change" was modified (`git diff --stat` reviewed).

## Testing Instructions

Run the suites once at the end of the whole batch, not after each step.

1. Backend: `cd recapture-api && npx tsc --noEmit && npx vitest run`, then again after setting
   `SUBSCRIPTION_TESTING_PRICES=true` in your shell.
2. Client: `flutter analyze && flutter test`.
3. Web live check: `npm run dev` in `recapture-api`, `flutter run -d chrome`, pay the ₹3 testing
   price as an owner, watch the plan flip to ACTIVE; check the backend log shows the verify and
   no webhook.
4. APK live check: `flutter build apk --release`, install on a mid-range Android phone pointed
   at a reachable backend, pay by UPI; repeat with "Don't keep activities" ON; repeat pressing
   back during activation.
5. Rate limit: `curl -X POST <base>/catalog/subscription/verify -H "Authorization: Bearer <owner token>" -H "Content-Type: application/json" -d '{"orderId":"order_x","paymentId":"pay_x","signature":"00"}'`
   21 times → the 21st returns 429.
6. In MongoDB, confirm exactly one `PAID` row per `pay_…` id after each live test.

## Assumptions

- Assumed: live payments during testing use the ₹3/₹5/₹7 testing prices set by the owner in
  `.env` — if the owner switches to Razorpay test keys, the live checks work the same.
- Assumed: 20 verify calls per catalog per 10 minutes is generous for a real owner (one success
  + a few retries). If Razorpay retries make owners hit it, raise the default.
- Assumed: iOS is out of scope (`checkout_adapter_io.dart` decides per-OS availability).
