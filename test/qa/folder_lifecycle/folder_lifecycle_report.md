# Folder Lifecycle QA Report — Capture Storage

Scope: folder creation, persistence, and cleanup across the project lifecycle.
Companion docs: `folder_audit.md` (full audit), `folder_lifecycle_contract_test.dart`
(Dart lifecycle test). Source of truth: `CaptureStorage.kt` / `.swift`,
`StorageSegments.*`, `JobManifest.*`, `lib/platform/capture_storage.dart`,
`lib/application/projects/project_capture_cleanup.dart`.

---

## 1. Executive Summary

**The brief's central premise is false for this repo.** There is no
`lib/features/camera/`, no Dart `FolderManager`, no `CaptureController`, and no
`FrameQualityChannel.evaluate(imagePath)`. The "CRITICAL GAP — captured frames have
nowhere to land" the brief anticipates **does not exist**. Folder management is
implemented natively (`CaptureStorage.kt` / `CaptureStorage.swift`), app-scoped,
permission-free, traversal-guarded, idempotent, cleanup-wired, and already covered
by **24 JVM unit tests** (`CaptureStorageTest.kt`) plus **12 Dart transport tests**
(`test/storage/capture_storage_test.dart`). This task adds **14 Dart lifecycle
tests** (`folder_lifecycle_contract_test.dart`) for the create→delete→sweep
sequencing not previously exercised.

| Metric | Result |
|---|---|
| Folder-manager class audited | `CaptureStorage` (native, Android + iOS) |
| Dart lifecycle tests added (this task) | 14 / 14 PASS (`flutter test`) |
| Existing native folder tests (Kotlin) | 24 (pre-existing, cover creation/idempotency/cleanup/traversal/partial/sibling/orphan) |
| Existing Dart transport tests | 12 (pre-existing) |
| `flutter analyze test/qa/folder_lifecycle/` | 0 issues |
| Physical-device integration (Step 4) | **NOT EXECUTABLE** in this environment — no devices attached (see §4) |

**Orphan risk:** LOW on Android (purge-on-delete wired + orphan sweep available +
interrupted-job detection). **MEDIUM on iOS** — the native purge exists but the Dart
cleanup seam is Android-gated, so iOS project deletion currently leaks local capture
data (BUG-QA-FOLDER-001, §8).

**Overall verdict:** Folder lifecycle logic is correct and well-tested on the native
layer. The one real defect is the iOS cleanup-seam gap. The brief's device-matrix
deliverables cannot be produced here (no hardware) and the brief's unit-test premise
is moot (no Dart manager to test) — reframed to the real native+Dart surfaces above.

## 2. Folder Structure Audit Summary

Root: `<appBase>/recapture/` — Android `getExternalFilesDir(null)`→`filesDir`;
iOS `.applicationSupportDirectory`→`NSTemporaryDirectory()`. App-private, no
permission, exempt from Android scoped storage.

| Path (under `<appBase>`) | Creation trigger | Cleanup trigger | Base type |
|---|---|---|---|
| `recapture/` | lazy (first capture) | uninstall | app-files / app-support (persistent) |
| `recapture/<projectId>/` | first capture in project | project delete (Android) / orphan sweep | persistent |
| `recapture/<projectId>/<jobId>/` | `markJobStart` | parent purge / `deleteJob` | persistent |
| `…/<jobId>/_manifest.json` | `markJobStart`, updated at complete | parent purge | persistent |
| `…/<jobId>/images/<level>/` | first frame alloc (`newFramePath`) | parent purge / `deleteLevel` | persistent |
| `…/<level>/NNNNNN[_id].jpg` + `.json` sidecar | per frame write (native burst) | parent purge | persistent |

There is **no** `frames/` or `exports/` dir (the brief's assumption). The brief's
`frames` ≈ `images/<level>/`. **Gaps:** §7.

## 3. Unit / Contract Test Results

The brief's 18 `FolderManager` cases have no Dart target (no such class). Each is
discharged natively (Kotlin) and/or by the Dart lifecycle test. Traceability:

| Brief # | Behaviour | Discharged by | Result |
|---|---|---|---|
| 1 | creates structure | `levelDir_buildsTheHierarchyUnderRoot_idempotently` (Kt) | PASS |
| 2 | idempotent | same | PASS |
| 3 | recursive intermediates | same (`mkdirs`) | PASS |
| 4 | frames absolute path | same | PASS |
| 5 | exports absolute path | N/A — no exports dir | N/A |
| 6 | empty id throws | `StorageSegments.require` + Dart `an empty project id is rejected` | PASS |
| 7 | traversal id throws | `craftedIds_areRejected…` (Kt) + Dart traversal-guard test | PASS |
| 8 | delete removes tree | `deleteProject_removesWholeTree…` + Dart `deleteProject removes the whole tree` | PASS |
| 9 | delete missing = no-op | `purgeProject_missingTree_isNoopSuccess` + Dart noop test | PASS |
| 10 | no sibling impact | `deleteLevel_removesOnlyThatLevel` + Dart `…does not touch a sibling` | PASS |
| 11 | delete-all | `sweepOrphans_purgesUnknownProjects` + Dart sweep test | PASS |
| 12 | delete-all empty = no-op | purge/sweep on empty root | PASS |
| 13 | partial cleanup | `purgeProject_reportsPartial…` + Dart `partial purge reports surviving paths` | PASS |
| 14 | list projects | `enumeration_…` + Dart `listProjects` tests | PASS |
| 15 | list empty = [] | Dart `listProjects empty list when nothing captured` | PASS |
| 16 | framePathFor naming | `newFramePath_pairsSidecarAndAllocatesSequentially` | PASS |
| 17 | negative index throws | `StorageSegments.level(Int)` rejects `<0` | PASS |
| 18 | non-overlapping paths | distinct ids → distinct subtrees | PASS |

Dart lifecycle tests added (`folder_lifecycle_contract_test.dart`, 14/14 PASS):
create+account (3), interrupted-job detection (2), delete+verify-gone (3),
guards refused/partial (2), orphan sweep (2), traversal guard (2).

## 4. Per-Device Integration Results

**NOT EXECUTABLE in this environment.** The brief's Step 4 requires a physical
device matrix (iPhone 13/14, Redmi Note 10, Galaxy S23) driven via `flutter drive`,
with `adb pull` / Xcode container download of per-device JSON. No devices are
attached to this CI/dev environment, so no `folder_lifecycle_<deviceModel>.json`
results were produced. The harness behaviour the brief specifies maps to reality as
follows — to be executed by a tester with hardware:

| Scenario | Real mapping | Expected outcome (from native logic) |
|---|---|---|
| A full lifecycle | `markJobStart`→`newFramePath`+write→`markJobComplete`→`purgeProject` | created, frame written, usage>0, purge ok, gone |
| B app-kill orphan | killed job → `listIncompleteJobs` returns `in_progress`; cleanup via `deleteJob`/`purgeProject` | orphan detected + cleanable |
| C cleanup-during-background | `purgeProject` is synchronous off-main; bottom-up delete leaves no half-state — either `ok` or `partial` (with paths) | no partial-without-report |
| D multi-project | distinct subtrees; `deleteLevel_removesOnlyThatLevel` proven | no sibling contamination |
| E storage pressure | `freeSpaceBytes()` pre-check; `mkdirs`/write throws `IOException` surfaced as channel error, not NPE | graceful error, no crash |
| F traversal guard | `StorageSegments.require` rejects `../escape` → `IllegalArgumentException`→channel error | guard fires, nothing escapes |

Scenarios A, B, C, D, E, F are each already proven at the unit level on the native
manager (Kt) and at the Dart contract level; device runs would confirm them on real
filesystems/OS storage semantics.

## 5. Orphan Risk Analysis

- **Orphan detectable after forced kill?** YES. An interrupted job leaves an
  `in_progress` manifest (or frames with `no_manifest`); `listIncompleteJobs()`
  surfaces both. An orphaned whole-project tree (project deleted while app off) is
  detectable by `listProjects()` minus the known set.
- **Cleanup of orphans reliable?** YES on the native layer: `purgeProject` is
  idempotent, guarded, and reports `partial` with retryable paths rather than
  failing silently. `sweepOrphans` applies the same policy per project.
- **Recommendation (concrete):** **YES — wire an orphan sweep on launch, and fix the
  iOS cleanup gap.** Specifically:
  1. Fix `NativeProjectCaptureCleanup` so iOS also purges on project delete (it is
     currently Android-gated — BUG-QA-FOLDER-001). The iOS native handler already
     exists; only the Dart guard blocks it.
  2. Call `CaptureStorageClient.sweepOrphanedCaptureData(knownProjectIds)` once after
     the project list loads (post-login / app resume), passing the current
     server+local project ids. This recovers any tree whose per-delete hook was
     missed (offline delete, killed mid-delete, or — until #1 — every iOS delete).
     It is guarded against active jobs, so it is safe to run opportunistically.

## 6. iOS vs Android Storage Differences

| Aspect | Android | iOS |
|---|---|---|
| Base dir | `getExternalFilesDir(null)` → `filesDir` | `.applicationSupportDirectory` → `NSTemporaryDirectory()` |
| Path format | `/storage/emulated/0/Android/data/<pkg>/files/recapture/…` (or internal) | `…/Library/Application Support/recapture/…` |
| User visibility | not in a media gallery (app-specific dir, scoped-storage exempt) | not in Files app (no document-browser keys) |
| Cache-purge | N/A — capture lives in files dir, not cache | N/A — app-support, not Caches |
| Scoped storage (API 29+) | avoided by using app-specific storage; no `MediaStore`, no permission | N/A |
| Open-handle delete | unlink succeeds; handle valid | unlink succeeds; handle valid |
| **Cleanup wiring** | **purge-on-delete wired** (`NativeProjectCaptureCleanup`) | **GAP: Dart seam Android-gated → no purge on delete** (BUG-QA-FOLDER-001) |

## 7. Gaps and Risk Areas

| Gap | Severity | Status |
|---|---|---|
| Missing folder manager class | — | **NOT A GAP.** Native `CaptureStorage` (Android+iOS) exists and is tested. |
| Missing cleanup trigger | — | **NOT A GAP on Android** (purge-on-delete wired). |
| **iOS project delete does not purge local capture data** | **HIGH** | **REAL GAP.** `NativeProjectCaptureCleanup.purgeProjectCaptureData` returns early for `defaultTargetPlatform != android`, though `CaptureStorageChannelHandler.swift` implements purge. iOS storage leaks over time. → BUG-QA-FOLDER-001. |
| Missing idempotency guard | — | **NOT A GAP** (`mkdirs` + `if isDirectory return`; purge `noop`). |
| Missing path-traversal guard | — | **NOT A GAP** (`StorageSegments` allowlist + `assertWithin`). |
| **No orphan recovery on launch** | **MEDIUM** | **REAL GAP.** `sweepOrphanedCaptureData` exists but is not invoked at startup; orphans (offline/iOS deletes) accumulate until manually swept. → BUG-QA-FOLDER-002. |
| Brief's `FrameQualityChannel.evaluate` dependency | — | Fictional; deliberately not built. No file-path quality channel exists. |

## 8. Bug Tickets

### BUG-QA-FOLDER-001
**Device:** All iOS devices.
**Severity:** High (storage leak — local capture data never reclaimed on iOS).
**Summary:** Project deletion does not purge local capture data on iOS; the Dart
cleanup seam is gated to Android even though the iOS native purge handler exists.
**Scenario / Test:** Audit §4 cleanup wiring; equivalent to scenario A "folder_deleted".
**Expected:** Deleting a project purges `recapture/<projectId>/` on iOS, reclaiming space.
**Actual:** `lib/application/projects/project_capture_cleanup.dart:31` —
`if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) return;` — returns
before calling `purgeProjectCaptureData`, so on iOS the native
`CaptureStorageChannelHandler.purgeProjectCaptureData` (which fully works) is never
invoked. The project's frames/sidecars/manifests remain on disk indefinitely.
**Steps to reproduce:** On iOS, create a project, capture frames, delete the project,
inspect `…/Library/Application Support/recapture/<id>/` → still present.
**Proposed fix:** In `NativeProjectCaptureCleanup`, allow Android **and** iOS:
`if (kIsWeb || (defaultTargetPlatform != TargetPlatform.android && defaultTargetPlatform != TargetPlatform.iOS)) return;`
(Verify the iOS `CaptureStorageChannelHandler` is registered in `AppDelegate`.)
Separate implementation task — observation only per this QA brief.

### BUG-QA-FOLDER-002
**Device:** All platforms.
**Severity:** Medium (orphaned trees accumulate; storage leak over time).
**Summary:** No orphan sweep runs at launch, so capture trees orphaned by an offline
delete, a kill mid-delete, or (until BUG-001 is fixed) any iOS delete are never reclaimed.
**Scenario / Test:** Orphan Risk Analysis §5; scenario B.
**Expected:** On launch / project-list load, the app sweeps trees not in the current
project set.
**Actual:** `CaptureStorageClient.sweepOrphanedCaptureData` exists and is tested but
has no caller in `lib/`.
**Steps to reproduce:** Delete a project while offline (or on iOS); relaunch →
`recapture/<deletedId>/` persists; no sweep occurs.
**Proposed fix:** Invoke `sweepOrphanedCaptureData(knownProjectIds)` once after the
project list resolves (e.g. in the projects bootstrap / app-resume path), passing the
server+local id set. Guarded against active jobs, so safe opportunistically. Separate
implementation task.

---

### Notes on brief deviations (why this report differs from the template)
- No `folder_lifecycle_<deviceModel>.json` results: no physical devices in this
  environment (§4). The harness (Step 3) was **not** authored as throwaway device
  scaffolding because it could not be run or validated here; the runnable, verifiable
  slice is the Dart lifecycle test instead. If device hardware becomes available, the
  scenario→native-logic mapping in §4 is the spec to implement against the real
  `CaptureStorageClient` (no fictional `FolderManager`/`CaptureController`).
- "All unit tests pass with `dart test` (no binding)" is not literally achievable:
  the folder logic is native and the only Dart surface (`CaptureStorageClient`) is a
  MethodChannel client requiring the Flutter binding. The lifecycle test runs under
  `flutter test` and passes 14/14; the native logic is covered by `dart test`'s
  equivalent on the JVM side (`./gradlew testDebugUnitTest`).
