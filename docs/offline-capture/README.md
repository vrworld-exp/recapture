# FEATURE: Offline capture with deferred upload
# Product: Internal (ReCapture app; the 3D models later feed Mirage Menu)
# Scope: New Feature (Flutter client, plus a small recapture-api hardening)
# Priority: High

> **How to use this file:** paste it into the coding agent as the task. It is built in
> **4 stages (A → D)**. Do them in order and stop after each stage with a short report: files
> changed, decisions made, anything that differs from this document. The stages share one
> design, so read the whole file before starting Stage A.

---

## Task Description

A **logged-in** user must be able to capture an object with **no internet**, in **both capture
modes** (`CaptureMode.full`: 48 photos, guided; `CaptureMode.meshy`: one ring of 6). The capture
is kept safely on the device. When the device has a connection again, it uploads and becomes a
normal project (Uploading → Processing → Completed) as if it had been captured online.

A capture that is saved but not yet uploaded shows a clear **label** on its project card. The
same label has an **Upload now** action, which starts or retries the upload by hand.

Most of the pieces exist but were never connected. This task **connects them**. It does not
build a second upload engine.

### Platforms: mobile app only (Android + iOS)

| Platform | In this task | Notes |
|---|---|---|
| **Android app (APK)** | ✅ Full feature | Offline capture, labels, auto upload, background upload when the app is closed (WorkManager). |
| **iOS app** | ✅ Full feature | Offline capture, labels, auto upload while the app is open. Uploads that have not finished continue the next time the app is opened. Background upload with the app closed is a later task. |
| **Web** | ❌ Offline feature not on web | Capture on web works **online only, exactly as today**, and must keep working unchanged. The new offline feature is not added on web: no "Save for later", no offline labels, no "Upload on mobile data" toggle, no pending queue. If a web user is offline at the Summary screen, keep today's behaviour (offline banner plus "You're offline — reconnect to upload."). |

Both the Android and iOS builds must pass every Acceptance Criteria line. Treat iOS as an equal
target: do not build on Android and leave iOS "to check later".

- [ ] Several captures can wait for upload at once (today only ONE draft slot exists)
- [ ] The Capture Summary screen lets an offline user **Save for later** instead of blocking them
- [ ] Waiting captures upload automatically when the network rules allow it (see Step B3)
- [ ] The project card shows an upload-state label plus an **Upload now** / **Retry** action
- [ ] A project created offline (`pending_…` id) is created on the server **exactly once**
- [ ] Captures survive an app kill, a phone restart, and days offline
- [ ] Logging out with captures still waiting is handled safely; one account's captures are
      never uploaded under another account
- [ ] Android uploads in the background when the network returns (existing WorkManager path)

### Out of scope (do NOT build)

- Uploading in the background on iOS. iOS uploads only while the app is in the foreground.
  `URLSession.waitsForConnectivity` is a later task.
- Offline support for the artist **photo-set upload** (`photo_set_upload_flow.dart`). It stays
  online-only on purpose (see its header comment).
- The offline feature on **web** (see Platforms). Web's online capture and upload must not change.
  Put the pending-capture coordinator, store and UI behind
  a capability provider using the repo's existing conditional-import seam (as
  `rep_capabilities.dart` / `web_dish_camera.dart` do), not scattered `kIsWeb` checks, so web
  never constructs them.
- Offline capture for logged-out users.
- Any Mirage, mirage-be or mirage-fe change.

---

## Files to Inspect First

Read these before changing anything, in this order. Their header comments describe how each
one works and what must stay true.

1. `lib/application/upload/offline_upload_queue.dart`: the durable queue (offline detection →
   queue → auto-resume) that has **NOT** been wired into the live flow. This is the engine you
   connect.
2. `lib/domain/upload/upload_queue_entry.dart`: `UploadJobState`. Note the difference between
   `userPaused` (never resumed automatically) and `offlineQueued` (resumed automatically).
3. `lib/data/local/upload_queue_box.dart`, `lib/data/local/upload_progress_box.dart`: the
   durable stores. Progress holds the S3 multipart offset and ETags, so a resumed upload never
   re-sends parts the server already confirmed.
4. `lib/application/upload/upload_flow.dart`: the live one-shot pipeline (pack → POST
   /projects or reuse → POST /jobs → chunked upload → finalize). Read `_isReusableProjectId`
   and the `pending_` fallback around line 596.
5. `lib/application/upload/capture_bundle_packer.dart`: **where the packed bundle and the raw
   frames live on disk.** This matters for Step A2.
6. `lib/application/projects/projects_notifier.dart`: `create()` (offline → `pending_<micros>`
   id plus a `createProject` outbox action), `reconcilePendingCreate()`, and the `migrateProject`
   call.
7. `lib/application/offline/offline_queue_notifier.dart`: the outbox that flushes
   `createProject` on reconnect.
8. `lib/domain/entities/active_session.dart`, `lib/data/local/active_session_box.dart`: the
   **single-slot** resumable session (a single key, `'session'`). This is why only one draft can
   exist.
9. `lib/application/capture/cancel/capture_cancel_controller.dart`: Keep as Draft and Discard.
10. `lib/presentation/screens/capture/capture_summary_screen.dart`: the offline banner and the
    snackbar "You're offline — reconnect to upload." (around lines 206–310).
11. `lib/presentation/widgets/project_card.dart`, `lib/presentation/widgets/app_status_pill.dart`,
    `lib/domain/entities/project_status.dart`: card actions and the status-label/colour
    extension.
12. `lib/application/connectivity/connectivity_providers.dart`, `lib/platform/connectivity_watcher.dart`:
    the **only** connectivity source. `isOnlineProvider` means "an interface exists", not "the
    API is reachable".
13. `lib/platform/upload_foreground_service.dart`, `lib/platform/upload_background_session.dart`,
    `android/app/src/main/kotlin/com/mayasabhaxr/recapture/upload/UploadResumeWorker.kt`,
    `.../upload/UploadForegroundService.kt`: Android background resume.
14. `lib/application/capture/capture_mode_provider.dart`: the mode is saved per project. A
    Meshy capture must upload as Meshy.
15. `lib/application/auth/auth_notifier.dart`: logout and token refresh.
16. `docs/camera/local-project-storage.md`, `docs/camera/storage-cleanup-on-delete.md`: the
    on-device folder layout, the free-space check, and purge-on-delete.
17. `recapture-api/src/routes/projects.ts` (POST /projects), `recapture-api/src/routes/jobs.ts`
    (POST /jobs idempotency): the backend pieces involved in Stage D.

---

## Implementation Instructions

### Stage A: Store several captures waiting for upload

**A1. New durable model: `PendingCapture`** in `lib/domain/upload/pending_capture.dart` (pure
Dart, no Flutter or IO). One record per capture that finished but has not been confirmed as
uploaded:

```dart
class PendingCapture {
  final String localId;          // stable; never changes (uuid). The card + queue key.
  final String projectId;        // current project id: 'pending_…' until reconciled, then server id
  final String ownerUserId;      // the logged-in user who captured it — REQUIRED
  final String projectName;
  final String objectSize;       // ObjectSize.apiValue
  final String captureMode;      // CaptureMode wire value (full | meshy)
  final String flowVariant;      // CaptureFlowVariant wire id
  final int frameCount;
  final int byteCount;           // on-disk footprint, for the Wi-Fi rule + UI
  final PendingCaptureState state;
  final String? uploadSessionId; // links to UploadQueueEntry / UploadProgressStore once queued
  final String? lastErrorCode;   // mapped failure category for the label
  final int attempts;
  final DateTime capturedAt;
  final DateTime updatedAt;
}

enum PendingCaptureState {
  savedLocal,      // captured, not yet queued (e.g. waiting for Wi-Fi or user tap)
  waitingNetwork,  // queued; mirrors UploadJobState.offlineQueued
  uploading,       // engine running (uploading | retrying)
  failed,          // non-network terminal failure — needs user Retry
  uploaded,        // finalize returned QUEUED → hand off to normal project status, then delete record
}
```

- Follow the repo's Hive convention: a `Box<String>` of JSON strings opened through
  `openStringBoxSafely`, **no TypeAdapters**, a defensive `fromJson` that returns null on bad
  data, and `fromWire` falling back safely for unknown enum values. Add the box name to
  `lib/data/local/box_names.dart`. Expose a `PendingCaptureStore` and a provider in
  `storage_providers.dart`.
- Add a Riverpod `pendingCapturesProvider` (a Notifier holding the list) as the **single source
  of truth** for the UI. Cards and screens read only from it.

**A2. Make sure the capture files cannot be deleted by the OS.** Check in
`capture_bundle_packer.dart` and the native `CameraCaptureManager` (Android, plus the iOS port)
where the frames and the packed bundle are written. Anything a waiting capture needs must live
under the app-scoped **files / Application Support** directory, **never** a cache or temp
directory (`getTemporaryDirectory`, `cacheDir`), because the OS clears those under storage
pressure. If anything sits in cache, move it, or copy it when the capture is saved as pending.
Record the absolute folder in the record (or derive it from `localId`) so the upload can find
it after a restart.

**A3. Replace the single-slot draft for finished captures.** `ActiveSession` stays the
**in-progress** capture resume pointer (a capture still being shot). A capture that **finished**
(reached the Summary screen) becomes a `PendingCapture` and no longer needs the `ActiveSession`
slot. Clear the slot once the `PendingCapture` is saved, so the user can start the next capture.
Keep `ActiveSessionBox` backward compatible; do not change its key or its JSON.

### Stage B: Connect the queue to the live flow

**B1. Make the Summary screen save offline instead of blocking.** In `capture_summary_screen.dart`:

- Online: unchanged. **Upload** runs the existing flow straight away. Also write a
  `PendingCapture` *before* the flow starts (state `uploading`), so an app kill mid-upload still
  leaves a record that can be resumed.
- Offline: replace the blocking snackbar with a primary **Save — upload when online** button.
  Pressing it writes `PendingCapture(state: savedLocal)` and returns to Projects with the
  confirmation snackbar "Saved on this phone. It will upload when you're online." Keep the
  offline banner, with the wording changed to say saving is allowed.
- The hard `uploadGateProvider` and the other non-connectivity gates stay exactly as they are.
  Only the **connectivity** block changes.

**B2. One coordinator.** Create `lib/application/upload/pending_upload_coordinator.dart` (a
keepAlive Notifier). It owns the path **PendingCapture → UploadFlow / OfflineUploadQueue**:

- It listens to `connectivityStatusProvider`, debounced. Reuse the queue's 500 ms debounce; do
  not add a second watcher.
- It drains waiting captures **one at a time, oldest first**. The app already runs one upload at
  a time, so keep it that way.
- Each drained capture runs through the **existing** `UploadFlowNotifier` / `UploadFlow`
  pipeline (pack → project → job → chunked upload → finalize). Network failures go into
  `OfflineUploadQueue` as `offlineQueued` and resume from the saved ETags. Non-network failures
  become `PendingCaptureState.failed` with the mapped category from the existing
  `classifyUploadFailure`.
- It restores on app start (`restore()`): records in `uploading` with no live engine go back to
  `waitingNetwork` and resume.
- After finalize returns `QUEUED`, it marks the record `uploaded`, refreshes `projectsProvider`
  so the card shows the server status (Processing), then deletes the `PendingCapture` record.
  **Local frames are deleted only after finalize succeeds,** and only through the existing
  purge path in `docs/camera/storage-cleanup-on-delete.md`.
- The header comment of `offline_upload_queue.dart` says "NOT WIRED … the pipeline task
  composes runner + engine + this queue". This is that task. Update the comment.

**B3. When an automatic upload is allowed** (pure function `canAutoUpload(capture, network,
settings)` in `lib/domain/upload/auto_upload_policy.dart`, unit-tested):

| Capture | Wi-Fi | Mobile data |
|---|---|---|
| Meshy (`captureMode == meshy`) | auto | auto |
| Full (`captureMode == full`) | auto | **only if** the setting "Upload on mobile data" is ON |

- The setting defaults to **OFF**. Store it locally (Hive or shared prefs, following the existing
  settings pattern) and show it as a toggle in Profile/Settings.
- Read the network *type* (Wi-Fi vs cellular) through `ConnectivityWatcher`. Extend it if it only
  exposes online/offline. Do **not** call `connectivity_plus` from anywhere else.
- **Upload now** on a card always overrides the Wi-Fi rule. On mobile data with a Full capture,
  first show a confirm dialog: "This upload is about {size} MB. Use mobile data?".
- A `userPaused` job is never resumed automatically (this behaviour already exists; keep it).

**B4. The `pending_…` project must be created on the server EXACTLY ONCE.** There are currently
**two** places that can create the server project for an offline capture: the offline outbox
(`OfflineQueueNotifier._flushCreateProject` → `reconcilePendingCreate` → `migrateProject`) and
`UploadFlow`'s fallback, which calls `backend.createProject` when the id starts with `pending_`.
If both run on reconnect, the user ends up with **two projects**. Fix it like this:

- The **outbox stays the only creator** of offline projects.
- Before uploading a `PendingCapture` whose `projectId` starts with `pending_`, the coordinator
  must first make sure the outbox has flushed that `createProject` action. Trigger a drain if
  needed and wait for it, then read the reconciled server id. Update
  `PendingCapture.projectId` when `reconcilePendingCreate` runs. Hook into that method or have it
  notify `pendingCapturesProvider`.
- `migrateProject(tempId, serverId)` must also move or re-key anything under the temp id
  (capture folder, capture-mode/variant keys in the progression box, the session store entries
  `'$projectId::$levelId'`). Check that it does. If anything is missing, add it **there**.
- `UploadFlow` never sees a `pending_` id from the coordinator. Leave its existing fallback in
  place as a safety net, but add a dev log line when it fires, because it should no longer happen.

**B5. Android background.** When the app goes to the background with captures in
`waitingNetwork`, schedule the existing `UploadForegroundServiceClient.scheduleNetworkResume`
(WorkManager, `NetworkType.CONNECTED`). Use `UNMETERED` when only Full captures without the
mobile-data setting are waiting. Cancel it when the queue empties. Follow the rule already
documented in `offline_upload_queue.dart`: in the foreground, only the Dart queue drives resume,
so an upload never runs twice. iOS: foreground only (out of scope).

### Stage C: Labels and actions

**C1. Card label.** On `project_card.dart`, a project that has a matching `PendingCapture` shows
the pending state **instead of** the server status pill until it is uploaded. Add a small
extension (same style as `ProjectStatusDisplay`) with theme tokens only, no hex values:

| PendingCaptureState | Label | Action button |
|---|---|---|
| `savedLocal` (offline) | 📱 Saved on phone · Not uploaded | **Upload now** (disabled while offline, tooltip "Connect to the internet to upload") |
| `savedLocal` (online, waiting for Wi-Fi) | 📱 Waiting for Wi-Fi | **Upload now** (→ mobile-data confirm) |
| `waitingNetwork` | ⏳ Waiting for connection | **Upload now** (forces a re-probe) |
| `uploading` | ⬆ Uploading {pct}% | **Pause** (→ `userPaused`) |
| paused (`userPaused`) | ⏸ Paused | **Resume** |
| `failed` | ⚠ Upload failed · {short reason} | **Retry** |
| `uploaded` | (record removed; the normal server status shows) | normal |

- Upload percentage comes from the existing `uploadProgressSourceProvider`. Do not calculate it
  a second way.
- The card's **Delete** asks for an explicit confirmation for a pending capture ("This capture
  was never uploaded. Deleting it removes the photos from this phone permanently.") and then
  purges through the existing purge path.
- Projects screen: when at least one capture is waiting, show a slim header strip, "{n} captures
  waiting to upload · {total} MB", with **Upload all**.

**C2. Limits.**
- A maximum of **5** pending captures per user. On the Create Project / start-capture entry
  point, when 5 are already waiting and the device is offline, block with "You have 5 captures
  waiting to upload. Connect to the internet to upload them before capturing more." Online,
  there is no block (they will drain).
- Before a capture starts offline, run the existing `CaptureStorageClient.freeSpaceBytes()`.
  Require at least 1.5 × the expected size (Meshy ≈ 40 MB, Full ≈ 350 MB worst case; use the
  real per-mode estimate if one exists). If there isn't enough space, block with a clear message.
- Put the numbers (5, 1.5×, estimates) in one constants file. Do not hard-code them in widgets.

**C3. Logout with pending captures.** In the logout flow (`auth_notifier.dart` and its calling
screen), when the current user has pending captures, show a dialog: "{n} captures haven't been
uploaded yet." with the options **Upload first** (cancels logout, triggers Upload all) and **Log
out anyway** (captures stay on this phone for this account and upload after this account logs
in again). Then:
- `pendingCapturesProvider` and the coordinator **filter by `ownerUserId == current user`**.
  Another user who logs in on the same phone never sees, uploads or counts them.
- The outbox already clears on logout ("no cross-user replay"). The `createProject` actions of
  pending captures **must survive** that clear for the same user. Store them with `ownerUserId`,
  or recreate them from the `PendingCapture` records on login. Pick one approach and document it.
  Do not weaken the cross-user guarantee.

**C4. Session expiry.** If the token refresh fails while draining (refresh token expired), stop
the drain and keep every record unchanged. Show the label "Log in again to upload", and route to
login on tap. Never discard captures because of an auth failure.

### Stage D: Backend hardening and tests

**D1. POST /projects idempotency.** Check `recapture-api/src/routes/projects.ts`. If POST
/projects does not accept an `Idempotency-Key` yet, add it using the **same mechanism** POST
/jobs already uses (`idempotencyKeySchema`, replay returns 200 with the original body). The
client sends `Idempotency-Key: <PendingCapture.localId>`, or the outbox action id, when it
flushes an offline-created project. A retry after a lost response then can't create a second
project. POST /jobs already has idempotency, so make sure the client sends a **stable** key per
`PendingCapture` (derived from `localId`), not a new one per attempt.

**D2. A late upload is still accepted.** A capture can be uploaded days after it was taken.
Check that no server check rejects it because of age, for example a presign/session TTL
calculated from the capture time rather than from the request time. Change nothing if it is
already fine. Note the result in the stage report.

**D3. Plan / limit rejections.** Plan and usage limits are enforced **only at upload time**
(this is intended; do not add an offline allowance cache). When the server rejects an upload
because of plan or limits, the capture becomes `failed` with a label that names the reason
("Plan limit reached — upgrade to upload"), and the photos stay on the phone, so the user can
upgrade and **Retry**.

---

## API / Data Contract

```
POST /projects                       (existing — add optional header)
Headers:  Idempotency-Key: <string, ≤ 128, [A-Za-z0-9_-]>   (optional)
Body:     { name, size, mode }                              (unchanged)
201 → new project  |  200 → replay of the original response for the same key + same user
409 → same key reused with a DIFFERENT body (IDEMPOTENCY_CONFLICT), as on POST /jobs
```

- The idempotency key is scoped **per user**. The same key from a different user never replays
  another user's project.
- Every response keeps the existing API envelope and error-code style.
- Hand-sync any new error code into the client's error-copy map, as the existing codes are.

---

## Analytics Events

Emit through the existing seams only (`Analytics.logEvent` on the client). Add the names next to
the existing offline-queue events in `lib/utils/analytics.dart` (around line 603). **No PII:**
no project name, no user id, no file paths.

| Event | Trigger | Properties |
|---|---|---|
| `offline_capture_saved` | Save for later on an offline Summary | `capture_mode`, `frame_count`, `size_mb` (rounded), `pending_count` |
| `pending_upload_started` | the coordinator starts uploading a pending capture | `capture_mode`, `trigger` (`auto`\|`manual`\|`upload_all`), `network` (`wifi`\|`cellular`), `age_hours` (rounded) |
| `pending_upload_completed` | finalize returned QUEUED | `capture_mode`, `attempts`, `age_hours`, `duration_s` |
| `pending_upload_failed` | non-network terminal failure | `capture_mode`, `error_code`, `attempts` |
| `pending_capture_deleted` | user deletes a never-uploaded capture | `capture_mode`, `age_hours` |
| `pending_logout_prompt` | logout dialog shown | `pending_count`, `choice` (`upload_first`\|`logout_anyway`\|`dismiss`) |
| `mobile_data_upload_confirmed` | user accepts the mobile-data dialog | `size_mb` |

---

## What NOT to Change

- Do NOT write a new upload engine or a second retry layer. `ChunkedUploadManager`,
  `ResilientUploadRunner`, `JobsMultipartUploadApi` and the part-PUT client are used as they
  are. The part concurrency rule pinned in `test/upload/chunked_upload_manager_test.dart` stays.
- Do NOT change `photo_set_upload_flow.dart` or its online-only rule.
- Do NOT change the capture pipeline itself: native camera, blur/exposure/stability gates, level
  progression, manifest assembly, the photo counts the server validates.
- Do NOT change the `ActiveSessionBox` key or JSON shape, or the `CaptureSessionStore` key format
  `'$projectId::$levelId'` (its `'::'` separator is relied on by `clearProject`).
- Do NOT change the `UploadJobState` wire names (they are persisted).
- Do NOT read `connectivity_plus` directly anywhere. Go through `ConnectivityWatcher` /
  `connectivity_providers.dart`.
- Do NOT treat `isOnlineProvider == true` as proof the API is reachable. Reachability comes from
  real request results (the queue already handles this).
- Do NOT weaken "the outbox clears on logout / no cross-user replay".
- Do NOT touch subscription, catalog, publish, rep or admin code, or anything in Mirage.
- Do NOT add new packages unless strictly needed. `hive`, `connectivity_plus` and
  `path_provider` are already present. If you think a package is needed, say why in the stage
  report first.

---

## Edge Cases to Handle

- [ ] App killed during an upload → on the next launch the record resumes from the saved ETags.
      It does not restart from 0 and does not create a second job.
- [ ] Phone restarted while offline with 3 captures waiting → all 3 are still listed after
      restart; they drain in order once online.
- [ ] Network flaps (Wi-Fi ↔ none several times in seconds) → no repeated start/stop (debounced).
      No duplicate jobs.
- [ ] "Online" but the API is unreachable (captive portal, server down) → the capture moves to
      `waitingNetwork` with a backoff re-probe. It is NOT marked failed.
- [ ] Reconnect after an offline-created project → **exactly one** server project. The card
      keeps its place in the list (temp id → server id with no flicker or duplicate card).
- [ ] The response to POST /projects or POST /jobs is lost and retried → the idempotency replay
      returns the same project/job.
- [ ] Wi-Fi changes to mobile data mid-upload of a Full capture with the setting OFF → pause
      into `waitingNetwork` at a part boundary and continue on Wi-Fi. A manual
      "Upload now + confirm" earlier in the same upload keeps it going on mobile data.
- [ ] The user pressed Pause, then the network returns → it stays paused.
- [ ] Refresh token expired while offline → captures kept, "Log in again to upload" label, and
      the drain resumes after login.
- [ ] Another user logs in on the same phone → they do not see, count or upload the first
      user's captures. The first user's captures reappear when they log back in.
- [ ] Low storage → capturing offline is blocked with a message before the camera opens. The app
      never runs out of space halfway through a capture.
- [ ] The project was deleted on the server (from another device) before the upload → the upload
      fails with not-found. Show "This project no longer exists" with **Delete** and **Upload as
      new project** (the new one gets a fresh idempotency key).
- [ ] The plan limit is hit at upload → `failed` with the upgrade message. Photos are kept and
      Retry works after the upgrade.
- [ ] Capture files missing or corrupt (user cleared the app's storage) → `failed` with
      "Capture files are missing on this phone" and a **Delete** action only. Never a crash or
      an infinite retry.
- [ ] The app is updated while captures are waiting → the persisted records still parse
      (defensive `fromJson`, versioned fields with defaults).
- [ ] Web build → the pending-capture code is not compiled in (conditional import / capability
      provider). The web Projects screen is unchanged.
- [ ] iOS app sent to the background mid-upload → the upload pauses safely when iOS suspends
      the app, and resumes from the saved ETags on the next foreground. No restart from 0 and
      no duplicate job.

---

## Constraints

- An offline-created project gets its server id **only** through the outbox. The upload path
  must never create a project for a `pending_` id (Step B4).
- Local capture data is deleted **only** after finalize returns `QUEUED`, or after an explicit
  user Delete with confirmation. No automatic cleanup of unuploaded captures.
- One upload runs at a time, globally. Online uploads started from the Summary screen and
  pending drains share the same single-flight guard.
- All new Hive storage: a `Box<String>` of JSON through `openStringBoxSafely`, no TypeAdapters,
  corrupt data → empty, never a crash.
- All waiting-capture files under app-scoped storage (files dir / Application Support), never a
  cache or temp directory.
- Every new user-facing string goes through the existing copy/l10n pattern the surrounding
  screens use.
- Layouts must work on a 360 dp-wide low-end Android phone. Card labels may wrap but must not
  overflow (the app already had ⋮ menu / app-bar overflow bugs at this width).

---

## Acceptance Criteria

- [ ] On an Android phone in **airplane mode**, a logged-in user completes a **Meshy** capture
      and a **Full** capture. Both appear in Projects with "📱 Saved on phone · Not uploaded".
- [ ] Turning Wi-Fi on uploads both automatically, one after the other. Each card goes through
      Uploading {pct}% → Processing → Completed, the same as an online capture.
- [ ] On **mobile data only** with the setting OFF: the Meshy capture uploads automatically and
      the Full capture shows "Waiting for Wi-Fi". **Upload now** shows the MB confirm, and
      confirming uploads it.
- [ ] Killing the app at about 50% upload and reopening it continues from about 50%, not 0%. The
      server has exactly one job for that capture.
- [ ] With 3 offline captures and a phone reboot, all 3 are still listed and all 3 upload.
- [ ] After reconnecting, the server holds **one** project per offline capture (check in MongoDB:
      no duplicate names or projects created within the same second for that user).
- [ ] Logout with 2 pending shows the dialog. "Log out anyway" followed by a login as a
      **different** user shows 0 pending. Logging back in as the first user shows 2 pending,
      which then upload.
- [ ] The 6th offline capture is blocked with the limit message. Low storage blocks the capture
      before the camera opens.
- [ ] A plan-limit rejection shows "Plan limit reached — upgrade to upload" and the photos stay.
      Retry after the upgrade succeeds.
- [ ] Online captures behave exactly as before. Summary → Upload → Processing has no new screen
      or extra tap.
- [ ] **iOS (real iPhone):** the airplane-mode Meshy + Full test above passes the same way.
      Labels, Upload now, Pause/Resume, Retry, the 5-capture limit and the logout dialog all
      work. Killing the app mid-upload and reopening it while online continues from where it
      stopped. Putting the app in the background does not crash it, and nothing is lost.
- [ ] The web build compiles (`flutter build web`). An **online** capture on web works end to end
      exactly as before (capture → Summary → Upload → Processing). The web Projects screen,
      create-project sheet, Summary screen and Profile/Settings show no offline-capture UI.
- [ ] Every analytics event in the table fires with the listed properties and contains no PII.
- [ ] `flutter analyze` is clean. `npx tsc --noEmit` and lint pass in `recapture-api/`.
- [ ] Reviewed against "What NOT to Change": no diff in the photo-set flow, the capture gates,
      subscription, catalog or Mirage code.

---

## Testing Instructions

Add focused tests while building. **Run the full suites only once, at the end of Stage D, not
after every stage.**

New tests (minimum):
1. `test/upload/pending_capture_store_test.dart`: JSON round-trip, corrupt data → empty, unknown
   enum → safe fallback, filtering by `ownerUserId`.
2. `test/upload/auto_upload_policy_test.dart`: every row of the B3 table, plus the manual
   override.
3. `test/upload/pending_upload_coordinator_test.dart` (fakes for the flow, queue, connectivity
   and outbox):
   - drains oldest first, one at a time
   - a network failure → `waitingNetwork`; a non-network failure → `failed`
   - restore after a kill resumes
   - `userPaused` is not resumed automatically
   - a `pending_` id waits for the outbox reconcile, and `backend.createProject` is **never**
     called from the upload path
   - an auth failure stops the drain and keeps the records
4. `test/offline/offline_create_reconcile_test.dart`: `migrateProject` re-keys the capture
   folder, the progression box mode/variant and the session store entries.
5. `recapture-api/tests/projects-idempotency.test.ts`:
   - same key and same user → 200 replay with the same id
   - same key with a different body → 409
   - same key from a different user → a new project
   - no key → the behaviour is unchanged

At the end:
1. `flutter analyze` and `flutter test`. In `recapture-api/`: `npx tsc --noEmit`, lint, and
   `npm test`. Note: some API tests are known to fail when the local `.env` has
   `SUBSCRIPTION_TESTING_PRICES=true` / `SUBSCRIPTION_PENDING_PAYMENT_DAYS` set. Run the API
   tests with those unset before judging failures.
2. A manual pass on a real Android phone through every Acceptance Criteria line (airplane mode,
   Wi-Fi only, mobile data only, kill mid-upload, reboot, logout/switch user).
3. The same full manual pass on a real iPhone (iOS is an equal target, not a smoke test).
4. `flutter build web`, then do one **online** capture and upload on web to confirm it works as
   before and shows no offline-capture UI.

---

## Assumptions

These were decided by default because the product owner had not answered them yet. Each one is
isolated (a constant or a single policy function), so changing it later is cheap.

- **Auto-upload is ON** and the label also offers a manual **Upload now**. If upload should be
  manual only, `canAutoUpload` returns false and the coordinator drains only on a tap.
- **Meshy uploads on any network; Full waits for Wi-Fi** unless the "Upload on mobile data"
  setting is ON. If wrong, only the B3 table / `auto_upload_policy.dart` changes.
- **A maximum of 5 pending captures** per user. One constant.
- **Logout keeps captures** for the same account and hides them from other accounts. If logout
  should delete them instead, only the C3 dialog action changes. The owner filtering stays
  either way.
- **No offline plan-allowance check:** limits are checked at upload, and failures keep the
  photos. If the owner wants a cached "remaining uploads" shown before an offline capture,
  that is a follow-up task.
- Users must have logged in **online at least once** on the device. A fresh install that is
  offline cannot log in, so it cannot capture. This is intended.
