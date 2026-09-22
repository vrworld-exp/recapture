✅ NOT STARTED
# BUG FIX: Publish-flow edge cases (F1–F10) — the silent failures after Publish
# Product: Mirage Menu (ReCapture backend + Flutter client)
# Scope: Bug Fix (10 defects, one batch)
# Priority: Critical (F1–F3), High (F4–F7), Medium (F8–F10)

Everything here is about **one press of Publish** — the header CTA on
`/catalog` (`catalog_publish_cta`) and its rep twin — and the ways that press
currently ends with the user told nothing, told the wrong thing, or wedged.

Nothing in this prompt changes what publishing *does*. Every fix is about the
run's **reporting**, its **replay safety**, and its **loop discipline**.

---

## Bug Report

### F1 — A run that fails at the RESTAURANT step shows the user nothing

**Expected:** the publish screen says the run failed and why.
**Actual:** the progress card disappears and the screen returns to its resting
state. No failure card, no success card, no sentence. The Publish button
re-enables as if nothing happened.

**Root cause chain:**
1. `mirageCatalogPublishProcessor.ts:371-377` — a FAILED `RESTAURANT` step
   `break`s out of the step walk. `recordRowFailure` returns early for it
   (`if (!step.targetId) return` — "the restaurant has no row"), so **no
   product row is ever marked FAILED**.
2. `resolveRunState` (`publishRunState.ts:293-297`) sees `synced: 0, failed: 1`
   → run state `FAILED`.
3. Client: `status.failures` is empty → `_FailureCard` is skipped
   (`publish_body.dart:291`). `status.isLive` is false → `_SuccessCard` is
   skipped (`publish_body.dart:300`).
4. `PublishRun.errorCode` / `hasError` / `errorCopy` exist
   (`publish_status.dart:161-166`) and `sync_error_copy.dart` already carries
   `PUBLISH_RESTAURANT_UNAVAILABLE` and `PUBLISH_STEP_FAILED` copy written for
   exactly this — **but no widget in `lib/presentation` reads either.** Grep
   for `errorCopy` returns zero presentation call sites.

**Repro:** stop Mirage (or unset `MIRAGE_*`), publish a valid catalog, watch
the screen.

**Also wrong in the same moment:** `publishTransitionToast`
(`publish_body.dart:1222-1227`) reads `counts.failed = 1` and says *"1 of 12
could not be published. Retry them below."* — pointing at a card that is not
rendered, for a retry that would answer `NOTHING_TO_RETRY`.

### F2 — A name collision found *during* the run is unrecoverable

**Expected:** the same one-tap rename card the synchronous 409 produces.
**Actual:** nothing — see F1 — and the suggested name is destroyed server-side.

**Root cause:** `requestPublish` (`catalogPublishService.ts:733-750`)
deliberately defers provisioning to the run when Mirage is unreachable. The
run's `restaurantExecutor` then returns
`{ outcome: 'FAILED', code: CATALOG_NAME_TAKEN, message: '… Try "<suggested>".' }`
— but the processor's `finalizeRun` call
(`mirageCatalogPublishProcessor.ts:386-396`) **overwrites every FAILED run's
error with a hardcoded `RESTAURANT_UNAVAILABLE`**, and `PublishStepResult`
(`publishExecutors.ts:72-78`) has no field to carry the suggestion anyway.

### F3 — A replayed Idempotency-Key returns 500, permanently

**Expected:** replaying a key returns the run it already made (202/409).
**Actual:** HTTP 500, and the client keeps the poisoned key for the life of the
screen, so **every** subsequent press is a 500.

**Root cause:** `openRun` (`catalogPublishService.ts:622`) calls
`CatalogPublishRun.create()` with the key and **no `E11000` handling**, against
the unique partial index `{ userId, idempotencyKey }`
(`CatalogPublishRun.ts:138-141`). That index's own comment claims *"a
double-tap's E11000 is resolved to a replay of the winner"* — no code does
this. `PublishFlow._keyForAttempt` (`publish_flow.dart:546-549`) retains the
key across any `CatalogFailure`, including the 500 it just caused.

**Repro:** POST `/catalog/publish` with `Idempotency-Key: k1` → let the run
finish → POST again with `k1`. `hasActiveRun` is false, so it reaches `create`
→ duplicate key → 500.

The existing test (`rep-publish.test.ts:449`) only asserts the key is
**stored**; it never replays it.

### F4 — A dropped status poll is announced as a failed publish

**Expected:** a flaky poll during a healthy run is silent (or says "couldn't
refresh").
**Actual:** a toast reading *"Your catalog could not be published. …"* while
the run is fine and still going.

**Root cause:** `PublishFlow._loadStatus`'s catch writes the poll error into
`actionFailure` (`publish_flow.dart:322`), which is the same field an
*action* failure uses. `publish_screen.dart:222-232` listens to it and renders
`subject: 'Your catalog could not be published'`.

### F5 — The poll loop retries non-retryable failures forever

**Root cause:** the same catch calls `_scheduleNextPoll()` unconditionally. A
404 (catalog deleted in another tab), a 401 (session expired) or a 403 keeps
polling at the 8 s ceiling for the life of the screen. `CatalogFailure` carries
`statusCode` (`catalog_failure.dart:67`) and nothing reads it here. Only the
gate path has a cap (`_gatePollCap`); the run path has none.

### F6 — The auto-start intent is burned by self-clearing gates

**Expected:** "I pressed Publish" survives a blocker that clears itself on this
very screen.
**Actual:** the user taps Publish from the catalog while a 3D preview is still
rendering, waits two minutes watching the checklist clear itself, and the run
never starts — the button just quietly enables.

**Root cause:** `_maybeAutoStart` latches `_autoStartDecided = true`
(`publish_screen.dart:72`) as soon as the status has a value and the
subscription verdict is settled. The subscription gate is deliberately exempt
(the pay-then-publish continuation); `PRODUCT_THUMBNAIL_MISSING` and
`PRODUCT_MODEL_NOT_READY` are not — and `PublishStatus.isWaitingOnGates`
(`publish_status.dart:296-297`) already names exactly that set. **The rep
screen has an independent copy of this bug** (`rep_publish_screen.dart:61-74`).

### F7 — Unpublish is not rolled back when the run fails to open

**Root cause:** `requestUnpublish` (`catalogPublishService.ts:845-870`) flips
Mirage's `isPublished: false` and writes `status: 'UNPUBLISHED'` **before**
calling `openRun`. If `openRun` loses the lock race and the winner has since
cleared, it returns `NOT_FOUND` — the page is already dark, the catalog reads
UNPUBLISHED, and no run ever removes the items. The caller gets a bare error.

### F8 — Double-tapping the catalog CTA stacks two publish screens

`AppButton` disables only on `isLoading` (`app_button.dart:59-60`) and
`_openPublish` (`catalog_screen.dart:186-193`) pushes a route. Two taps → two
`PublishScreen`s, two auto-starts (the second gets a handled 409), two
independent poll loops on one endpoint, and Back lands on a duplicate screen.

### F9 — 429 discards `Retry-After`

`POST /catalog/publish` is rate-limited per user (`routes/catalog.ts:1238-1246`).
The client has `RATE_LIMITED` copy (`catalog_error_copy.dart:253`) but it says
"try again in a moment" while the real window is `PUBLISH_WINDOW_SECONDS`. The
header is never read.

### F10 — `PublishRun.errorCopy` cannot resolve non-`PUBLISH_` codes

`errorCopy` calls `syncErrorCopy` (`publish_status.dart:166`), whose table only
holds `PUBLISH_*` keys. A run-level `CATALOG_NAME_TAKEN` (F2) would render the
unknown fallback even after F1 is fixed. `catalogErrorCopy` is the total
function — it checks `_copy` first and falls through to `syncErrorCopy` for
`PUBLISH_*` codes.

---

## Task Description

- [ ] **F1** Render a run-level failure card in `PublishBody` when a terminal
      run carries an error and no product row failed. Fix the toast so it does
      not point at a retry list that is not there.
- [ ] **F2** Carry `suggestedName` from the failing RESTAURANT step through the
      run document to the client, stop `finalizeRun` from overwriting the real
      error, and reuse the existing `_NameTakenCard` for it.
- [ ] **F3** Resolve `E11000` in `openRun` to a replay of the winning run.
      Clear the client key on a definitive server answer, including a 500 whose
      envelope names a replayed run.
- [ ] **F4** Split poll failures from action failures on `PublishScreenState`;
      never render a poll failure as "your catalog could not be published".
- [ ] **F5** Classify poll failures. Stop the loop on permanent ones
      (401/403/404 and any non-retryable envelope code); keep backing off on
      transport and 5xx. Add a run-path attempt cap.
- [ ] **F6** Keep the auto-start intent ARMED while every remaining gate is
      self-clearing (`isWaitingOnGates`). Extract the latch into one shared
      helper used by both the owner and rep screens.
- [ ] **F7** Roll back the Mirage flip and the `UNPUBLISHED` status write when
      `openRun` does not queue a run.
- [ ] **F8** Debounce navigation on the catalog Publish CTA (and its rep twin)
      so one gesture opens one screen.
- [ ] **F9** Read `Retry-After` into `CatalogFailure` and say the real wait.
- [ ] **F10** Point `PublishRun.errorCopy` at `catalogErrorCopy`.

---

## Files to Inspect First

Read all of these before editing anything. F1–F3 are cross-repo; getting the
`run.error` contract wrong in one half breaks the other silently.

**Backend**

1. `recapture-api/src/worker/processors/mirageCatalogPublishProcessor.ts:320-400`
   — the step walk, the `RESTAURANT` abort at 371, the `finalizeRun` call at
   386 that discards the real error. `recordRowFailure` at 218.
2. `recapture-api/src/services/catalog/publishRunState.ts:293-316` —
   `resolveRunState` and `finalizeRun`'s `error` parameter.
3. `recapture-api/src/services/catalog/publishExecutors.ts:72-83` —
   `PublishStepResult`, the shape you extend for `suggestedName`.
4. `recapture-api/src/models/CatalogPublishRun.ts:95-141` —
   `PublishRunErrorSchema` (the `error` subdocument) and the unique partial
   index whose comment F3 makes true.
5. `recapture-api/src/services/catalogPublishService.ts` — `openRun` (616-690),
   `requestPublish` (704-760), `requestUnpublish` (833-900), `getPublishStatus`
   (927-996, the `run.error` projection), `restaurantExecutor` (519-565).
6. `recapture-api/src/routes/catalog.ts:1229-1272` — the publish and retry
   routes, `consumeRateWindow`, and `respondToPublishRequest` (216-280).

**Client**

7. `lib/application/catalog/publish_flow.dart` — `_loadStatus` (304-330),
   `_syncPollingTo`, `_scheduleNextPoll`, `_act` (433-500), `_keyForAttempt`
   (546). This file is shared by both doors; every change here lands on the rep
   surface too.
8. `lib/presentation/widgets/catalog/publish_body.dart` — the card order in
   `build` (208-330), `_FailureCard` (487), `_SuccessCard` (591),
   `_NameTakenCard` (757), `publishAutoStartReady` (138-147),
   `publishTransitionToast` (1199-1228).
9. `lib/presentation/screens/catalog/publish_screen.dart:50-90` and
   `lib/presentation/screens/rep/rep_publish_screen.dart:55-80` — the two
   independent copies of the auto-start latch.
10. `lib/domain/catalog/publish_status.dart:139-186` — `PublishRun`,
    `errorCode`, `errorCopy`, `PublishRun.fromMap`.
11. `lib/data/repositories/catalog_failure.dart:50-120` — `CatalogFailure`,
    `statusCode`, `CatalogFailure.fromDio`.
12. `lib/domain/catalog/catalog_error_copy.dart` (tail) — `catalogErrorCopy` /
    `catalogErrorCopyOrNull` and the `PUBLISH_*` delegation.
13. `test/catalog/publish_fakes.dart:50-70` — `runPayload` **already accepts an
    `error` map**; use it rather than inventing a fixture.
14. `test/catalog/feedback_test.dart:20-45` — the test that scans the backend
    for error codes and fails CI when one has no client copy. Any new code you
    emit must be added to a copy table.

---

## Implementation Instructions

### Step 1 (F2, backend): let a step result carry a suggestion

In `publishExecutors.ts`, extend `PublishStepResult`:

```ts
export interface PublishStepResult {
  outcome: PublishOutcome;
  /** Required when `outcome` is FAILED. */
  code?: string;
  /** Our user-facing sentence, stored on the row's `syncError`. */
  message?: string;
  /**
   * A name Mirage would accept, on CATALOG_NAME_TAKEN only. Travels to the run
   * document so the client can offer the same one-tap rename the synchronous
   * 409 offers.
   */
  suggestedName?: string;
}
```

In `catalogPublishService.ts`'s `restaurantExecutor`, add
`suggestedName: result.suggestedName` to the `NAME_TAKEN` branch of the CREATE
path and `suggestedName: branding.suggestedName` to the `NAME_TAKEN` branch of
the branding path. Both already have the value in scope.

### Step 2 (F2, backend): stop `finalizeRun` discarding the real error

In `CatalogPublishRun.ts`, add to `PublishRunError` / `PublishRunErrorSchema`:

```ts
suggestedName: { type: String, maxlength: 200 },
```

Optional and unindexed. Do **not** make it required — every historical run
lacks it.

In `mirageCatalogPublishProcessor.ts`, capture the first FAILED step's result
inside the walk:

```ts
let firstFailure: { code: string; message: string; suggestedName?: string } | undefined;
```

Set it on the first `result.outcome === 'FAILED'` (do not overwrite on later
ones — the first failure is the one that explains the run, and for a
`RESTAURANT` abort it is the only one). Then replace the hardcoded finalize
error:

```ts
const state = resolveRunState(tally);
await finalizeRun(
  runId,
  state,
  state === 'FAILED'
    ? (firstFailure ?? {
        code: PublishErrorCode.RESTAURANT_UNAVAILABLE,
        message: 'Nothing could be published this time.',
      })
    : undefined
);
```

Note the trimmed fallback sentence: "See the item list for details" is a lie
when the item list is empty, which is the whole of F1.

Widen `finalizeRun`'s `error` parameter in `publishRunState.ts` to
`{ code: string; message: string; suggestedName?: string }`. The existing
`...(error ? { error } : {})` spread already carries the extra key.

**PARTIAL runs are untouched.** `state === 'FAILED'` only when `synced === 0`,
so a run where eight of ten products went live still finalises with no
run-level error and still renders the existing `_FailureCard`.

### Step 3 (F1/F2, backend): project the error

In `getPublishStatus`, the `run.error` projection currently reads:

```ts
...(run.error ? { error: { code: run.error.code, message: run.error.message } } : {}),
```

Extend it field-by-field (never a spread — that rule is in the file's own
comment):

```ts
...(run.error
  ? {
      error: {
        code: run.error.code,
        message: run.error.message,
        ...(run.error.suggestedName ? { suggestedName: run.error.suggestedName } : {}),
      },
    }
  : {}),
```

Add `suggestedName?: string` to `PublishStatusDto['run']['error']`.

### Step 4 (F3, backend): make the index comment true

In `openRun`, wrap the `CatalogPublishRun.create` and resolve a duplicate key
to the run that already owns it:

```ts
let run: ICatalogPublishRun;
try {
  run = await CatalogPublishRun.create({ /* unchanged */ });
} catch (err) {
  if (!isDuplicateKeyError(err) || !options.idempotencyKey) throw err;
  // The key has already made a run. Replay it rather than racing Mirage's
  // non-idempotent writes with a second one.
  const existing = await CatalogPublishRun.findOne({
    userId: catalog.userId,
    idempotencyKey: options.idempotencyKey,
  })
    .lean()
    .exec();
  if (!existing) throw err; // lost to a delete; nothing to replay
  return {
    outcome: 'REPLAYED',
    run: {
      runId: String(existing._id),
      state: existing.state,
      mode: existing.mode,
      snapshotRevision: existing.snapshotRevision,
    },
    publicUrl: customerUrl(catalog),
  };
}
```

Reuse the existing duplicate-key predicate rather than writing a third one —
`catalogService.ts:718-728` and `projectModelsService.ts:629` already have it.
Import one; do not copy it.

Add `REPLAYED` to `RequestPublishResult`. In `respondToPublishRequest`, answer
it as **200** (not 202 — nothing was queued by *this* request) with the same
body shape:

```json
{ "status": "success", "runId": "<id>", "queued": false, "replayed": true }
```

Track it on the existing `CATALOG_PUBLISH_REQUESTED` event — `outcome` already
carries the result string, so `REPLAYED` flows through with no new event.

**Client half:** in `publish_request_mapping.dart`, a 200 with a non-empty
`runId` currently cannot happen (only `NOTHING_TO_RETRY` returns 200 and it has
no `runId`). Keep that branch and add: when `replayed` is `true` and `runId` is
a non-empty string, return `PublishAlreadyRunning(runId)` — the screen's
existing handling for it ("a run is going, watch it") is exactly right, and it
already clears `_idempotencyKey`.

### Step 5 (F4, client): a poll failure is not an action failure

In `publish_flow.dart`, add to `PublishScreenState`:

```dart
/// The last STATUS READ failed while a run was on screen. Separate from
/// [actionFailure] because "we could not refresh" and "your publish failed"
/// are different sentences, and only one of them is about the publish.
final CatalogFailure? pollFailure;
```

Add it to the constructor, to `copyWith` (using the same `_unset` sentinel
pattern as the other nullable fields), and clear it on every successful
`_loadStatus`.

In `_loadStatus`'s catch, write `pollFailure` instead of `actionFailure`:

```dart
} on CatalogFailure catch (failure, stack) {
  if (_disposed) return;
  if (state.value == null) {
    state = state.copyWith(status: AsyncError(failure, stack));
    return;
  }
  state = state.copyWith(pollFailure: failure);
  if (_shouldKeepPolling(failure)) _scheduleNextPoll();
}
```

Do **not** add a second `ref.listen` that toasts `pollFailure`. Render it
inline instead: in `PublishBody`, under the `_RunProgress` card, when
`state.pollFailure != null`, show a muted line reusing the existing
`_Banner`:

> "Couldn't refresh just now — your publish is still running. Retrying…"

and, when `_shouldKeepPolling` returned false (see Step 6), the stopped
variant with a Refresh action:

> "Couldn't refresh. Pull down to try again."

Both get `ValueKey`s (`publish_poll_stale_note`, `publish_poll_stopped_note`)
so the widget tests can find them.

### Step 6 (F5, client): classify, and cap

In `publish_flow.dart`:

```dart
/// How many consecutive failed polls before the loop gives up on a run.
///
/// Generous: a multi-minute publish across a sleeping tier legitimately drops
/// requests, and stopping early freezes a progress line that was about to
/// move. This is the backstop for a server that will never answer, not a
/// tripwire for a flaky one.
const int _runPollFailureCap = 10;
```

```dart
/// Whether another poll could plausibly answer differently.
///
/// A 401/403/404 is a FACT about this catalog and this session — the catalog
/// was deleted in another tab, the session expired, the delegation was
/// revoked — and asking again at eight-second intervals for as long as the
/// screen is open answers the same thing every time. Transport failures and
/// 5xx are the opposite: they are about the moment, not the request.
bool _shouldKeepPolling(CatalogFailure failure) {
  if (_consecutivePollFailures >= _runPollFailureCap) return false;
  final status = failure.statusCode;
  if (status == null) return true; // transport — retry
  return status != 401 && status != 403 && status != 404;
}
```

Track `_consecutivePollFailures`, increment in the catch, and reset to zero on
every successful `_loadStatus` **and** in `refresh()` (an explicit pull-to-
refresh reopens the window, exactly as `_restartGateWait` already does for
gates — follow that precedent and its reasoning).

When `_shouldKeepPolling` returns false, also `_cancelPoll()` so a timer
already scheduled elsewhere cannot revive the loop.

### Step 7 (F1/F2/F10, client): render the run-level failure

**F10 first**, because F1 depends on it. In `publish_status.dart`:

```dart
import 'catalog_error_copy.dart';

/// OUR sentence for a run-level failure.
///
/// [catalogErrorCopy], not [syncErrorCopy]: a run-level code can be an
/// ENVELOPE code (`CATALOG_NAME_TAKEN`) as well as a per-item one, and only
/// the envelope table knows the first kind. That function is total and falls
/// through to the sync table for `PUBLISH_*`.
CatalogErrorCopy get errorCopy => catalogErrorCopy(errorCode);
```

Keep the `sync_error_copy.dart` import only if something else in the file still
needs it; `catalog_error_copy.dart` re-exports the `SyncErrorCopy` typedef as
`CatalogErrorCopy`, so the type does not change.

Add `suggestedName` to `PublishRun` and parse it in `fromMap` beside
`errorCode`, reading `error['suggestedName']` through `catalogText`.

**Then the card.** Add `_RunFailureCard` to `publish_body.dart`, rendered when:

```dart
final runFailure = !inFlight &&
        status.failures.isEmpty &&
        (run?.hasError ?? false) &&
        (run?.state.isTerminal ?? false)
    ? run
    : null;
```

Place it where `_FailureCard` sits in the card order (before the checklist,
after `_RunProgress`), and make the three cards mutually exclusive:

| condition | card |
|---|---|
| `failures.isNotEmpty` | `_FailureCard` (unchanged) |
| `failures.isEmpty && run.hasError` | `_RunFailureCard` (new) |
| `failures.isEmpty && isLive` | `_SuccessCard` (unchanged) |

The new card is red, like `_FailureCard`, and carries:
- headline: `voice.nothingPublished` — "Nothing was published" / the rep's
  wording. Add it to `PublishVoice` beside the existing lines.
- body: `run.errorCopy.message` and, when present, `run.errorCopy.action`.
- a **Try again** button wired to `onPublish`, disabled by exactly the same
  `blocked` expression `_Actions` uses. Do **not** wire it to `onRetryFailed` —
  there are no failed rows to retry, and `requestRetry` would answer
  `NOTHING_TO_RETRY`.
- `key: const ValueKey('publish_run_failure')`.

`PublishRunState.isTerminal` already exists (`publish_status.dart:68`) and is
already right for this: it is `!isInFlight`, and `unknown` deliberately counts
as in-flight, so an unrecognised state from a newer server renders no failure
card rather than a wrong one. Use it as-is; do not redefine it.

**F2's card.** When `run.errorCode == 'CATALOG_NAME_TAKEN'` and
`run.suggestedName` is non-empty, render the existing `_NameTakenCard` with
that suggestion **instead of** `_RunFailureCard`. It already has the rename
wiring (`onRename` → `renameAndPublish`), so no new callback is needed. Hoist
the suggestion so both sources feed one card:

```dart
final suggestedName = state.suggestedName ??
    (run?.errorCode == CatalogErrorCodes.catalogNameTaken ? run?.suggestedName : null);
```

Add `catalogNameTaken = 'CATALOG_NAME_TAKEN'` to `CatalogErrorCodes` — the
string is already in the copy table but not in the constants class.

**The toast.** In `publishTransitionToast`, the `(_, > 0)` arm must not say
"Retry them below" when no row failed. Change the switch to take the failed
**row** count, not the step count:

```dart
final run = after.run ?? before.run;
final failedRows = after.failures.length;
if (run?.hasError == true && failedRows == 0) {
  return 'Publishing could not finish. ${run!.errorCopy.message}';
}
return switch ((after.isLive, failedRows)) {
  (_, > 0) => '$failedRows of ${after.products.length} could not be published. Retry them below.',
  (true, _) => liveLine,
  (false, _) => offlineLine,
};
```

This also fixes a second-order lie: `counts.failed`/`counts.total` are **plan
step** counts (they include RESTAURANT and CATEGORY steps), so
"1 of 12 could not be published" was already mis-describing a twelve-step plan
over ten products.

### Step 8 (F3, client): stop poisoning the key

In `PublishFlow._act`'s catch, keep the key only for failures that could
plausibly have been delivered:

```dart
} on CatalogFailure catch (failure) {
  if (_disposed) return;
  // The key is kept ONLY when this attempt may have reached the server and
  // lost its response. A refusal the server clearly authored (4xx) means the
  // request was seen and answered, so the next press is a NEW request and
  // reusing the key would make the server replay an answer to a question the
  // user is no longer asking.
  final status = failure.statusCode;
  if (status != null && status >= 400 && status < 500 && status != 408 && status != 429) {
    _idempotencyKey = null;
  }
  state = state.copyWith(isRequesting: false, actionFailure: failure);
}
```

408 and 429 keep the key on purpose: a timeout may have been delivered, and a
rate-limited request definitely was not (so replaying it is free and correct).

Also clear the key in `refresh()`, beside the `_restartGateWait()` call:

```dart
Future<void> refresh() {
  // A pull-to-refresh is a deliberate "start over". It reopens the gate
  // window, resets the poll-failure count, and retires the replay key — which
  // is the one press that recovers a key the server can no longer replay (its
  // run was pruned) and would otherwise answer 500 forever.
  _idempotencyKey = null;
  _consecutivePollFailures = 0;
  _restartGateWait();
  return _loadStatus();
}
```

### Step 9 (F6, client): arm the intent through self-clearing gates

In `publish_body.dart`, beside `publishAutoStartReady`, add the latch decision
so both screens share one rule:

```dart
/// Whether a screen opened with [kPublishStartQuery] should stop waiting.
///
/// The intent stays ARMED — not spent — while the only thing standing between
/// the user and a run will clear ITSELF on this screen: an unsettled or
/// blocking subscription (they may be paying right now), and a gate set that
/// is entirely "wait for it" (a preview rendering, a model generating). Every
/// other gate is fixed on ANOTHER screen, and coming back from that screen to
/// find a publish already running would be a surprise — those spend the intent.
///
/// Spending it on a self-clearing gate is how a user who tapped Publish while
/// a thumbnail was rendering sat and watched the checklist empty itself and
/// the button enable, with nothing ever starting.
bool publishAutoStartSettled({
  required PublishScreenState state,
  required SubscriptionPublishCheck subscription,
}) {
  if (!state.status.hasValue) return false;
  if (!subscription.isSettled || subscription.blocks) return false;
  if (state.value?.isWaitingOnGates ?? false) return false;
  return true;
}
```

Then in **both** `publish_screen.dart:63-84` and
`rep_publish_screen.dart:63-84`, replace the inline guard:

```dart
void _maybeAutoStart(PublishScreenState state, bool isOnline, SubscriptionPublishCheck subscription) {
  if (!widget.startPublish || _autoStartDecided) return;
  if (!publishAutoStartSettled(state: state, subscription: subscription)) return;
  _autoStartDecided = true;
  if (!publishAutoStartReady(state: state, isOnline: isOnline, subscription: subscription)) return;
  WidgetsBinding.instance.addPostFrameCallback((_) {
    if (!mounted) return;
    ref.read(publishProvider.notifier).publish();   // rep: repPublishProvider(catalogId)
  });
}
```

The two bodies stay separate (different providers) but the **rule** is now in
one place. Do not try to merge the two screens.

**Bound it.** An armed intent that waits forever is a timer nobody asked for.
`isWaitingOnGates` already stops polling after `_gatePollCap` (~15 min, past
the backend's generation timeout), and once the loop stops, the gates cannot
clear — so the intent naturally expires with the loop. Add nothing further;
just confirm with a test that a screen whose gate poll has capped does not sit
armed against a dead loop.

### Step 10 (F7, backend): roll the unpublish back

Restructure `requestUnpublish` so the destructive half is only committed once
the run is queued. The Mirage flip must still go first (the page going dark
immediately is the point), so compensate rather than reorder:

```ts
const previousStatus = catalog.status;

try {
  await getMirageClient().updateRestaurant(catalog.mirageRestaurantId, { isPublished: false });
} catch (err) {
  if (!(err instanceof MirageError)) throw err;
  console.warn(`[catalog] unpublish could not clear isPublished (${err.code}); continuing`);
}

await Catalog.updateOne({ _id: catalogId }, { $set: { status: 'UNPUBLISHED' } }, { timestamps: false }).exec();

const queued = await openRun(catalog, { mode: 'UNPUBLISH' });
if (queued.outcome === 'QUEUED') return { outcome: 'QUEUED', run: queued.run };
if (queued.outcome === 'IN_PROGRESS') {
  // Someone else's run holds the catalog. Ours never started, so put the
  // catalog and the page back exactly as we found them — a page left dark
  // with no run to finish the job is the one state nothing else repairs.
  await Catalog.updateOne(
    { _id: catalogId },
    { $set: { status: previousStatus } },
    { timestamps: false }
  ).exec();
  await getMirageClient()
    .updateRestaurant(catalog.mirageRestaurantId, { isPublished: true })
    .catch((err: unknown) => {
      console.warn('[catalog] unpublish rollback could not restore isPublished', err);
    });
  return queued;
}
// openRun could not queue and could not name a winner — same compensation.
/* …identical rollback… */
return { outcome: 'NOT_FOUND' };
```

Factor the two compensations into one local `restore()` rather than writing it
twice. The `isPublished: true` restore is best-effort and logged: a Mirage that
refuses it leaves the page dark, which is recoverable by publishing, whereas
throwing here would leave the caller with no answer at all.

### Step 11 (F8, client): one gesture, one screen

In `catalog_screen.dart`, guard `_openPublish` with an in-flight flag on the
state object:

```dart
bool _openingPublish = false;

Future<void> _openPublish() async {
  if (_openingPublish) return;
  _openingPublish = true;
  try {
    await context.pushNamed(
      AppRouteNames.catalogPublish,
      queryParameters: {kPublishStartQuery: '1'},
    );
    if (!mounted) return;
    await ref.read(catalogProvider.notifier).refresh();
  } finally {
    if (mounted) _openingPublish = false;
  }
}
```

No `setState` — nothing renders from this flag, and rebuilding the header on a
navigation is waste.

Apply the identical guard to the rep's publish entry point in
`rep_catalog_detail_screen.dart`. Leave `AppButton` itself alone: a debounce
baked into the shared button would change every button in the app, which is far
outside this fix.

### Step 12 (F9): say the real wait

In `catalog_failure.dart`, add:

```dart
/// From a 429's `Retry-After`, in seconds. Null when the header was absent or
/// unparseable (it may legally be an HTTP-date, which we do not attempt).
final int? retryAfterSeconds;
```

Parse it in `fromDio` from `response?.headers.value('retry-after')` with
`int.tryParse`. Then, where the publish screen renders a `RATE_LIMITED`
failure, append the wait when it is known:

> "You've published a few times just now. Try again in about 2 minutes."

Round to whole minutes above 90 s, whole seconds below. Put the rounding in one
small helper next to the copy table, not inline in the widget, and leave the
existing `RATE_LIMITED` entry as the fallback for an unknown wait.

---

## API / Data Contract

Only one wire shape changes. `GET /catalog/publish/status` and
`GET /rep/catalogs/:id/publish/status`, in `publish.run.error`:

```jsonc
"run": {
  "id": "…",
  "state": "FAILED",
  "mode": "FULL",
  "counts": { "total": 12, "synced": 0, "failed": 1, "skipped": 0 },
  "startedAt": "…",
  "finishedAt": "…",
  "error": {
    "code": "CATALOG_NAME_TAKEN",
    "message": "…",
    "suggestedName": "blue_cafe_2"   // NEW, optional — present on name collisions only
  }
}
```

`POST /catalog/publish` gains one outcome:

```jsonc
// 200 — this key already made a run; nothing new was queued
{ "status": "success", "runId": "6710…", "queued": false, "replayed": true }
```

Both doors answer identically — `rep-publish.test.ts` asserts the payloads are
equal byte for byte, so anything added to the owner's response must be added to
the rep's.

---

## Analytics Events

No new events. Two existing ones change shape:

- `catalog_publish_requested` — `outcome` gains the value `REPLAYED`. No new
  property.
- `catalog_publish_target_failed` — unchanged; it already fires for the
  RESTAURANT step, which is how this class of failure was visible in analytics
  while being invisible on screen.

Do **not** put `suggestedName`, a catalog name, or a run error `message` into
any event — the message can name a product, and product names are owner
content (the rule is stated at `routes/catalog.ts:233-235`).

---

## What NOT to Change

- Do **NOT** change what a publish run *does*: the planner, the executors,
  `publishSnapshot`, `publishableProducts`, the lock in `openRun`
  (`activePublishRunId: null` conditional update), or the order
  run → job → lock. F3 adds a catch around one `create`; it does not touch the
  race.
- Do **NOT** mark product rows FAILED when the RESTAURANT step aborts. That
  would make `_FailureCard` appear and "Retry failed" re-run products that were
  never attempted. The fix is to *report* the run error, not to fake row
  failures.
- Do **NOT** change `resolveRunState`'s thresholds. `FAILED` vs `PARTIAL` vs
  `SUCCEEDED` is depended on by `finalizeCatalogAfterRun`, by
  `publishedRevision`, and by `hasDraftChanges`.
- Do **NOT** touch the frozen mapping fields (`mirageRestaurantId`,
  `publicUrl`, `publicUrlScheme`) or `assertMappingImmutable`. F7's rollback
  restores `status` and Mirage's `isPublished` **only**.
- Do **NOT** make the subscription check stricter anywhere. The three fail-open
  rules in `subscription_publish_gate.dart` (unsettled ≠ permission, a failed
  read is READY, an unreported row is READY) stay exactly as they are; F6 only
  changes when the *auto-start* latch is spent.
- Do **NOT** add a toast for `pollFailure`. F4 exists because the publish
  screen already says too much about failures that are not the publish's.
- Do **NOT** add a debounce inside `AppButton` — it is shared app-wide.
- Do **NOT** merge `publish_screen.dart` and `rep_publish_screen.dart`. They
  differ in provider, in `PublishVoice`, in `canFix`, and in whether unpublish
  exists at all.
- Do **NOT** change `kPublishStartQuery`'s meaning or add it to doors that only
  watch (the analytics nudge, "Publishing… see progress").
- Do **NOT** widen the rate-limit windows to make F9 easier to test.

---

## Edge Cases to Handle

- [ ] Run FAILED at RESTAURANT, zero product rows failed → `_RunFailureCard`,
      **not** `_FailureCard`, **not** `_SuccessCard`, and the toast says
      "Publishing could not finish", not "retry them below".
- [ ] Run PARTIAL (8 of 10) → unchanged behaviour: `_FailureCard` + "Retry
      failed". `_RunFailureCard` must not appear.
- [ ] Run FAILED **and** some rows FAILED (a CATEGORY step failed, then
      products failed behind it) → `_FailureCard` wins; the run error is not
      shown twice.
- [ ] Run SUCCEEDED with a stale `error` on an older run document → no card;
      gate on `state.isTerminal && state == FAILED`, not on `hasError` alone.
- [ ] `error.code` this build has never seen → `catalogErrorCopy` fallback
      ("Something went wrong. / Try again in a moment."), never a raw message.
      The server's `error.message` must **never** be rendered.
- [ ] `CATALOG_NAME_TAKEN` with no `suggestedName` (an old run document) →
      `_RunFailureCard`, not a rename card with an empty field.
- [ ] Idempotency replay where the winning run has since been pruned by
      `pruneRunHistory` → `findOne` returns null → rethrow the `E11000` → 500.
      This is the one remaining 500 on the path and it is correct: the index
      still holds the key, so there is genuinely nothing to replay and nothing
      new can be created under it. Step 8 keeps the key on a 5xx, so the press
      would repeat — make the client's escape explicit instead: **clear
      `_idempotencyKey` in `PublishFlow.refresh()`**. A pull-to-refresh is a
      deliberate "start over" gesture, it already reopens the gate window, and
      it turns a wedged screen into one press to recover. Assert this in a
      test: replay → 500 → `refresh()` → next `publish()` sends a *different*
      key.
- [ ] Two devices, one catalog, one key → second gets `REPLAYED` 200 and
      watches the same run.
- [ ] Poll fails with 404 mid-run (catalog deleted in another tab) → loop
      stops, the stopped banner shows, pull-to-refresh is still offered.
- [ ] Poll fails 10× consecutively with 503 → loop stops at the cap; a
      pull-to-refresh resets the counter and resumes.
- [ ] Poll fails once, then succeeds → `pollFailure` clears, no banner, no
      toast, counter back to zero.
- [ ] Tab hidden while `pollFailure` is set → on show, the immediate catch-up
      poll runs and clears it if the server is back.
- [ ] Auto-start opened onto `PRODUCT_THUMBNAIL_MISSING` only → stays armed,
      fires the moment the gate clears, fires **once**.
- [ ] Auto-start opened onto `CATALOG_NO_CATEGORIES` → latch spends
      immediately (the fix is on another screen), no run.
- [ ] Auto-start armed, gate poll hits `_gatePollCap` → loop stops, intent
      never fires, no timer left running.
- [ ] Auto-start armed, user presses Back before the gate clears → no request
      after dispose (`mounted` + `_disposed` guards).
- [ ] Unpublish where `openRun` answers IN_PROGRESS → `status` restored to its
      previous value and `isPublished: true` re-sent.
- [ ] Unpublish rollback where the Mirage restore itself throws → logged,
      swallowed, the IN_PROGRESS result still returned.
- [ ] Unpublish on a DRAFT catalog → unchanged: `NOT_PUBLISHED`, no Mirage
      call, no run, nothing to roll back.
- [ ] Double-tap the catalog Publish CTA → exactly one `PublishScreen` on the
      stack, exactly one auto-start.
- [ ] 429 with no `Retry-After` header → the existing generic
      `RATE_LIMITED` sentence, no "in about null minutes".

---

## Constraints

- **Hand-synced contract.** There is no shared package between
  `recapture-api` and the Flutter app (AGENTS.md §0.1). The `suggestedName`
  field and the `replayed` flag must be added on both sides in this one change,
  and `test/catalog/feedback_test.dart` scans the backend sources for error
  codes — any code you newly emit needs a client copy entry or CI fails.
- **The client holds no publish state.** Every number on the publish screen
  comes from a status read. `_RunFailureCard` renders `status.run`; it must not
  cache, derive, or remember a failure across a refresh that contradicts it.
- **No raw upstream text.** The client renders `errorCopy`, keyed off
  `error.code`. `error.message` is parsed only so it is not needed; it is never
  shown. This is the F10 guarantee and `feedback_test.dart` enforces it.
- **`PublishRunError.suggestedName` is optional forever.** Every run document
  written before this change lacks it; no migration, no backfill, no
  `required: true`.
- **Both doors or neither.** `PublishFlow`, `PublishBody` and
  `publish_request_mapping.dart` are shared by owner and rep. Every change to
  them must be checked against `rep_publish_screen.dart` and
  `rep-publish.test.ts`'s byte-equality assertion.
- **Web is in scope.** The poll loop's lifecycle pausing exists because browser
  tabs throttle timers; `_consecutivePollFailures` must survive a pause/resume
  cycle without being reset by it (only a *successful* read or an explicit
  `refresh()` resets it).
- The backend must stay clean under `npm run type-check` and `npm run lint`;
  the client under `flutter analyze`.

---

## Acceptance Criteria

- [ ] **F1** With `MIRAGE_*` pointed at an unreachable host, pressing Publish
      on a valid catalog ends with a red "Nothing was published" card naming a
      reason and offering Try again — on both the owner and rep screens.
- [ ] **F1** The same run's toast reads "Publishing could not finish…" and does
      not say "Retry them below".
- [ ] **F1** A PARTIAL run (8 of 10) still shows the old `_FailureCard` with
      "Retry failed", and no run-failure card.
- [ ] **F2** A run that fails with `CATALOG_NAME_TAKEN` shows the rename card
      with the server's suggestion, and tapping it renames and republishes.
- [ ] **F2** `run.error.code` in the status payload is the real failure code,
      not `PUBLISH_RESTAURANT_UNAVAILABLE`, when the step reported one.
- [ ] **F3** `POST /catalog/publish` twice with the same `Idempotency-Key`,
      with the first run already finished, returns **200 `replayed: true`** with
      the first run's id. No 500. Exactly one `CatalogPublishRun` exists.
- [ ] **F3** The client, on that replay, shows the run rather than an error,
      and a subsequent press uses a **fresh** key.
- [ ] **F3** After a 500 (a key whose run was pruned), one pull-to-refresh
      retires the key: the next press sends a different `Idempotency-Key` and
      succeeds. No screen exit needed.
- [ ] **F4** Killing the network for one poll during a live run shows an inline
      "couldn't refresh" line and **no** toast containing the words "could not
      be published".
- [ ] **F5** A 404 from the status endpoint mid-run stops the poll timer within
      one backoff step; DevTools Network shows no further requests.
- [ ] **F5** Ten consecutive 503s stop the loop; one pull-to-refresh resumes it.
- [ ] **F6** Tapping Publish on the catalog while a 3D preview is generating
      starts the run **by itself** the moment the gate clears, without a second
      press — on both owner and rep screens.
- [ ] **F6** Tapping Publish with a `CATALOG_NO_CATEGORIES` gate does not start
      a run when the user returns from the category manager.
- [ ] **F7** With a concurrent run holding the lock, `POST /catalog/unpublish`
      leaves `catalog.status` at its previous value and re-sends
      `isPublished: true` to Mirage.
- [ ] **F8** Rapidly double-tapping the catalog Publish CTA opens exactly one
      publish screen (verify with a widget test pumping two taps in one frame).
- [ ] **F9** A 429 with `Retry-After: 120` renders a sentence naming about two
      minutes; a 429 without the header renders the existing generic sentence.
- [ ] **F10** A run error of `CATALOG_NAME_TAKEN` resolves to real copy, not
      the unknown fallback.
- [ ] `npm run type-check` and `npm run lint` clean in `recapture-api`.
- [ ] `flutter analyze` clean.
- [ ] `npm test` green, including `catalog-publish-api`,
      `catalog-publish-processor`, `catalog-publish-idempotency`,
      `catalog-unpublish` and `rep-publish`.
- [ ] `flutter test` green, including `publish_screen_test`,
      `publish_subscription_gate_test`, `publish_fix_routing_test`,
      `feedback_test` and `rep_publish_test`.
- [ ] Reviewed against "What NOT to Change" — the planner, executors, lock
      order and frozen mapping fields are untouched.

---

## Testing Instructions

**New backend tests** (extend the existing files; do not create a parallel
suite):

1. `tests/catalog-publish-idempotency.test.ts` — add an HTTP-level describe:
   POST with `Idempotency-Key: k1` → force the run terminal → POST again with
   `k1` → expect 200, `replayed: true`, the same `runId`, and
   `CatalogPublishRun.countDocuments({ idempotencyKey: 'k1' }) === 1`.
2. `tests/catalog-publish-processor.test.ts` — register a `RESTAURANT` executor
   that returns `{ outcome: 'FAILED', code: 'CATALOG_NAME_TAKEN', message: '…',
   suggestedName: 'blue_cafe_2' }`; assert the run finalises `FAILED` with that
   exact `error` (code **and** `suggestedName`), that no `CatalogProduct` has
   `syncStatus: 'FAILED'`, and that the walk broke (no CATEGORY/PRODUCT
   entries).
3. `tests/catalog-publish-status.test.ts` — assert the status payload surfaces
   `run.error.suggestedName`, and that a run with no suggestion omits the key
   entirely rather than sending `null`.
4. `tests/catalog-unpublish.test.ts` — seed an active run, call unpublish,
   assert `status` is unchanged and the Mirage fake received
   `isPublished: true` after the `false`.
5. `tests/rep-publish.test.ts` — extend the byte-equality assertion to cover a
   run carrying an error.

**New client tests:**

6. `test/catalog/publish_screen_test.dart` — using `runPayload(error: {...})`
   (the fake already supports it):
   - terminal FAILED + no failed products → finds `publish_run_failure`, does
     **not** find `publish_failure_headline` or the success card;
   - PARTIAL + failed products → the inverse;
   - `CATALOG_NAME_TAKEN` + `suggestedName` → finds `publish_name_taken`;
   - unknown error code → the fallback sentence, and the server's raw
     `message` string appears nowhere in the rendered tree.
7. `test/catalog/publish_screen_test.dart` — a failing status read during a
   live run finds `publish_poll_stale_note` and asserts **no** SnackBar
   containing "could not be published"; a 404 read finds
   `publish_poll_stopped_note`.
8. `test/catalog/publish_subscription_gate_test.dart` — open with
   `startPublish: true` onto a `PRODUCT_THUMBNAIL_MISSING` gate, then answer a
   clean status; assert `publish()` was called exactly once. Then the
   `CATALOG_NO_CATEGORIES` case: assert it was called zero times.
9. `test/catalog/catalog_shell_test.dart` — pump two taps on
   `catalog_publish_cta` in one frame; assert one navigation.

**Manual:**

10. `npm run dev` with `MIRAGE_BASE_URL` pointed at a dead port. Publish a
    valid catalog from the Flutter app (`flutter run -d chrome` and a
    mid-range Android). Confirm the run-failure card, the Try again button, and
    that pressing it produces a second run rather than a 500.
11. With Mirage up: publish, then mid-run put the device in airplane mode for
    ~15 s and restore it. Confirm the inline stale line, no failure toast, and
    that the progress line catches up.
12. Backgrounding check (web): publish, switch tabs for 30 s, return. Confirm
    the immediate catch-up poll and that the failure counter did not trip.

---

## Assumptions

- **Assumed:** `REPLAYED` answers **200**, not 202, because nothing was queued
  by that request. If the rep client turns out to branch on 202 specifically,
  change it to 202 with `queued: false` — the client mapping in Step 4 keys off
  `replayed`, not the status code, so only the test assertions move.
- **Assumed:** the run-failure card's Try again reuses `onPublish`. If product
  wants a distinct "contact support" affordance for
  `PUBLISH_NOT_CONFIGURED` (an operator problem the user cannot fix), that is a
  follow-up — this prompt renders the existing copy's `action` line and stops
  there.
- **Assumed:** `_runPollFailureCap = 10` and the 401/403/404 set are right. If
  the deployment sees legitimate transient 404s (a read-your-writes lag behind
  a replica), move 404 to the retryable set and rely on the cap alone.
- **Assumed:** F9's rounding ("about 2 minutes") is acceptable copy. If product
  wants a live countdown, that is a separate change — the header value is the
  only new data this prompt adds.
- **Not covered here:** the subscription gates' own ops flag
  (`subscriptionGatesEnabled`) stays off. None of F1–F10 depends on it, and
  none of them changes what the paywall does.
