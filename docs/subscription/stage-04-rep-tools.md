✅✅✅✅

# NEW FEATURE: Rep "Notify owner to pay" nudge + activation-screen payment copy
# Product: Mirage Menu (ReCapture backend + Flutter client)
# Scope: New Feature
# Priority: Medium

---

## Task Description

Give the rep the one tool §4 Door 2 / §9 promises that does not exist yet: an on-demand nudge that
asks the owner to open the app and pay. "Start trial" already shipped in Stage 2 (README C9); the
automated reminder schedule is Stage 6 and is **not** built here.

- [ ] `POST /rep/catalogs/:id/subscription/notify-owner` — sends an SMS (through the existing
      stub seam) **and** creates an in-app notification for the owner; rate-limited per catalog;
      never confirms or changes a payment (AC-7.3).
- [ ] `providers/sms.ts` gains a second, template-based entry point so the OTP call site is
      untouched.
- [ ] Rep detail card gets **Notify owner to pay** with a cooldown state read from the server.
- [ ] Rep activation CONFIRM step gains the sentence *"The owner will log in and pay using this
      number."* (A2).
- [ ] Rep "My restaurants" chip already exists (Stage 2); add the `Overdue Nd` red variant if
      Stage 2 shipped it neutral, and sort rows with GRACE first.

## Files to Inspect First

1. `recapture-api/src/providers/sms.ts` — `sendSms(phone, code)` is OTP-shaped; do not change its
   signature.
2. `recapture-api/src/services/notificationsService.ts:272` — `createNotification(input)` and
   `CreateNotificationInput` (`kind`, `title`, `message`, `detail?`, `action?`, `audience`,
   `expiresAt?`).
3. `recapture-api/src/models/Notification.ts` — allowed `kind` values and `action` shape (add a
   kind if the enum is closed).
4. `recapture-api/src/routes/rep.ts` — `/catalogs/:id/subscription/trial` from Stage 2 as the
   template; `consumeRateWindow` usage.
5. `recapture-api/src/models/User.ts` — how the owner's phone is stored (`phone`, E.164) and the
   `hashIdentifier` helper in `utils/otp.ts` for analytics.
6. `recapture-api/src/utils/rateLimit.ts` — `consumeRateWindow` returns `{ limited, retryAfter? }`;
   confirm the shape.
7. `lib/presentation/screens/rep/rep_catalog_detail_screen.dart` — the Subscription card from
   Stage 2.
8. `lib/presentation/screens/rep/rep_activation_screen.dart` — the CONFIRM step (~line 13
   comment and the widget that reads the number back).
9. `lib/presentation/screens/rep/rep_catalogs_screen.dart` — the chip and list ordering.

## Implementation Instructions

### Step 1: SMS template seam

In `providers/sms.ts` add:

```ts
export type SmsTemplate = 'SUBSCRIPTION_PAY_NUDGE';
export async function sendTemplatedSms(phone: string, template: SmsTemplate, vars: Record<string,string>): Promise<DispatchResult>
```

Stub body mirrors `sendSms` (honours `OTP_SIMULATE_DISPATCH_FAILURE`, returns a stub id, logs the
template name only — **never the phone**). Template text lives in one map in the same file:
`SUBSCRIPTION_PAY_NUDGE: "{restaurant}: your Mirage Menu {what} — open the ReCapture app to pay and keep your 3D menu live."`
where `what` is one of `"trial ends in {days} days"`, `"plan expires in {days} days"`,
`"payment is overdue"`, `"3D menu is paused"`, `"has no plan yet"` — chosen server-side from the
subscription status.

### Step 2: Service — `services/subscription/nudgeService.ts`

`notifyOwnerToPay(catalog: ICatalog, actor: Actor)`:

1. `consumeRateWindow('sub-nudge:' + catalogId, env.SUBSCRIPTION_NUDGE_MAX_PER_WINDOW (default 2), env.SUBSCRIPTION_NUDGE_WINDOW_SECONDS (default 86_400))`
   → `{ outcome: 'RATE_LIMITED', retryAfter }` when limited.
2. Load the owner `User` by `catalog.userId`; if no phone → `{ outcome: 'NO_PHONE' }`.
3. `getSubscriptionSummary(catalog._id)` → pick the `what` sentence; if `status` is ACTIVE with
   `daysLeft > 7` → `{ outcome: 'NOT_NEEDED' }` (do not let a rep spam a paid-up owner).
4. In parallel: `sendTemplatedSms(owner.phone, 'SUBSCRIPTION_PAY_NUDGE', vars)` and
   `createNotification({ kind: 'SUBSCRIPTION', title: 'Keep your 3D menu live', message: <same sentence>, action: { route: '/catalog/subscription' }, audience: { type: 'USERS', userIds: [ownerId] } })`.
   SMS failure is logged and does **not** fail the request if the in-app notification succeeded
   (the stub is what runs today); if both fail → 502 `NUDGE_FAILED`.
5. Return `{ outcome: 'SENT', channels: ['SMS','IN_APP'] | ['IN_APP'], nextAllowedAt }`.

Add the two env keys to `env.ts` with defaults.

### Step 3: Route

`POST /rep/catalogs/:id/subscription/notify-owner` (rep router, delegated, empty strict body):
`SENT` → 200 `{ status:'success', nudge: { channels, nextAllowedAt } }`; `RATE_LIMITED` → 429
`RATE_LIMITED` with `retryAfter`; `NO_PHONE` → 409 `OWNER_UNREACHABLE`; `NOT_NEEDED` → 409
`NUDGE_NOT_NEEDED`. Also expose `nudge: { nextAllowedAt }` on `GET /rep/catalogs/:id/subscription`
by peeking the rate window (read-only) so the button can show its cooldown before a tap.

### Step 4: Client

- `RepRepository.notifyOwner(catalogId)` → `NudgeResult`; map 429 → cooldown, 409s → sentence.
- Rep card: **Notify owner to pay** button; disabled with "Sent · again in Nh" while
  `nextAllowedAt > now`; hidden when `status` is ACTIVE with `daysLeft > 7`. Success snackbar:
  "Sent to the owner by SMS and in-app."
- Activation CONFIRM step: under the read-back number add the sentence from A2, in the same
  text style as the existing "is this correct?" line.
- `rep_catalogs_screen.dart`: sort by `status` priority `GRACE, PAUSED, NONE, TRIAL, ACTIVE,
  COMPED, CANCELLED`, then by `daysLeft asc`; GRACE chip uses the error colour.

## API / Data Contract

```
POST /rep/catalogs/:id/subscription/notify-owner   (SALES_REP, delegated; body {})
→ 200 { status:'success', nudge: { channels:['SMS','IN_APP'], nextAllowedAt: ISO } }
→ 429 { status:'error', code:'RATE_LIMITED', message, retryAfter }
→ 409 OWNER_UNREACHABLE | NUDGE_NOT_NEEDED
GET  /rep/catalogs/:id/subscription  → adds nudge: { nextAllowedAt: ISO | null }
```

## Analytics Events

`subscription_nudge_sent { catalog_id, actor_id_hash, owner_id_hash, subscription_status, channels: string[] }`
`subscription_nudge_refused { catalog_id, reason: 'RATE_LIMITED'|'NO_PHONE'|'NOT_NEEDED'|'FAILED' }`
Client: `rep_nudge_tapped { catalog_id }`.
No phone in any prop; `owner_id_hash` via `hashIdentifier`.

## What NOT to Change

- Do NOT change `sendSms(phone, code)`'s signature or the OTP service's call.
- Do NOT add a scheduled/cron reminder, a `ReminderLog` model, or a worker sweep — Stage 6.
- Do NOT return the owner's phone in the nudge response or anywhere on `/rep` beyond the existing
  `accountPhone` receipt on the profile routes.
- Do NOT let the nudge route touch `CatalogSubscription` or `PaymentRecord` (AC-7.3).
- Do NOT bypass the rate window for ADMIN callers.

## Edge Cases to Handle

- [ ] Owner has no phone on file (edge legacy account) → 409 `OWNER_UNREACHABLE`; the rep sees
      "This owner has no phone number on file — ask an admin."
- [ ] Two reps nudge within the window → second gets 429 and the same `nextAllowedAt`.
- [ ] SMS stub throws (`OTP_SIMULATE_DISPATCH_FAILURE=true`) → in-app still created, 200 with
      `channels:['IN_APP']`.
- [ ] Subscription ACTIVE with 30 days left → button hidden; a forged request → 409.
- [ ] Owner never installed the app → the in-app notification waits; the SMS is the only reach.
      Nothing else to do here (§13 item 6 is a known trade-off).

## Constraints

- The in-app notification `action.route` must be the owner route `/catalog/subscription` — the
  bell's tap handler already navigates by route string; confirm in
  `lib/presentation/screens/notifications/`.
- Rate window keys are per **catalog**, not per rep.

## Acceptance Criteria

- [ ] `tsc --noEmit`, `npm run lint`, `flutter analyze` pass; suites green.
- [ ] A delegated rep's nudge → 200, one `Notification` row for the owner, one stub SMS log line
      containing the template name and **no digits of the phone**.
- [ ] Second nudge inside 24 h → 429 with `retryAfter`; `nextAllowedAt` on GET matches.
- [ ] Nudge on an ACTIVE subscription with 20 days left → 409 `NUDGE_NOT_NEEDED`.
- [ ] `CatalogSubscription` and `PaymentRecord` collections are byte-for-byte unchanged before
      and after a nudge (assert counts + a hash of the rows in the test) (AC-7.3).
- [ ] Rep card button shows the cooldown after a successful tap without a manual refresh.
- [ ] Activation CONFIRM step shows the A2 sentence (widget test).
- [ ] Rep list orders a GRACE restaurant above an ACTIVE one (widget test with fixtures).

## Testing Instructions

1. Backend: `tests/subscription-nudge.test.ts` covering all outcomes and the immutability
   assertion. Run the full suite once at the end.
2. Client: `test/rep/rep_nudge_button_test.dart`, `test/rep/rep_activation_copy_test.dart`,
   `test/rep/rep_catalogs_ordering_test.dart`.
3. Manual: `npm run dev` with the stub; tap Notify in the rep app; open the owner app → bell shows
   the notification → tap → lands on `/catalog/subscription`.

## Assumptions

- Assumed a `Notification.kind` value `SUBSCRIPTION` can be added; if the enum is intentionally
  closed, reuse the closest existing informational kind and note it in the PR.
- Assumed the 2-per-24h default; it is env-tunable.
