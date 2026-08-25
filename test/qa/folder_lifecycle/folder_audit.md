# Folder Lifecycle Audit — Capture Storage

> Step 1 deliverable for the "Test Folder Creation and Cleanup Across Project
> Lifecycle" QA task. This audit documents the folder creation/cleanup strategy
> **as actually implemented**, then maps the task brief's (fictional) assumptions
> onto that reality.

## 0. Reality check — the brief's premise does not match this codebase

The task brief is written against a `lib/features/camera/` layout with a Dart
`FolderManager`/`CapturePaths` class, a `CaptureController.triggerCapture()`, and
a `FrameQualityChannel.evaluate(imagePath)`. **None of those exist in this repo**,
and several were previously evaluated and rejected as fictional:

| Brief assumption | Reality in this repo |
|---|---|
| `lib/features/camera/` | Does not exist. Clean architecture: `lib/domain`, `lib/application`, `lib/data`, `lib/platform`, `lib/presentation`. |
| Dart `FolderManager` class (`createProjectFolder`, `deleteProjectFolder`, `framePathFor`, `listProjectFolders`) | Does not exist. Folder management is **native**: `CaptureStorage.kt` (Android) and `CaptureStorage.swift` (iOS), behind a `MethodChannel`. The Dart side (`lib/platform/capture_storage.dart`, `CaptureStorageClient`) is a thin transport client — it owns no filesystem logic. |
| `<documents>/projects/<id>/frames/` + `/exports/` | Wrong path and wrong subdirs. Real tree: `<appBase>/recapture/<projectId>/<jobId>/images/<level>/`. There is no `frames/` or `exports/` directory. |
| `CaptureController.triggerCapture()` | Does not exist. Capture is `CaptureChannel.captureSingle` (native CameraX / AVFoundation), wired into `CaptureScreen`'s shutter. |
| `FrameQualityChannel.evaluate(imagePath)` (FILE_NOT_FOUND dependency) | Does not exist and was deliberately **declined** — blur/exposure are streaming `EventChannel`s over live preview frames, not a file-path method channel. There is no "evaluate a file" dependency that can throw `FILE_NOT_FOUND`. |
| Project ID generated client-side / settable per call | Project IDs are server-issued Mongo `_id` strings, passed into the storage API. The native layer never generates them. |

**Consequence for this task:** the "CRITICAL GAP — no folder manager, frames have
nowhere to land" outcome the brief anticipates is **false**. Folder management is
present, app-scoped, permission-free, traversal-guarded, idempotent, cleanup-wired,
and already unit-tested (24 JVM tests in `CaptureStorageTest.kt`, 12 Dart transport
tests in `test/storage/capture_storage_test.dart`). This audit therefore documents
the real system; the report (`folder_lifecycle_report.md`) records the real findings.

Source files:
- `android/app/src/main/kotlin/com/mayasabhaxr/recapture/storage/CaptureStorage.kt`
- `android/app/src/main/kotlin/com/mayasabhaxr/recapture/storage/StorageSegments.kt`
- `android/app/src/main/kotlin/com/mayasabhaxr/recapture/storage/JobManifest.kt`
- `ios/Runner/CaptureStorage.swift`, `StorageSegments.swift`, `JobManifest.swift`, `CaptureStorageChannelHandler.swift`
- `lib/platform/capture_storage.dart` (`CaptureStorageClient`)
- `lib/application/projects/project_capture_cleanup.dart` (delete cleanup seam)

---

## 1. Folder structure (exact relative paths)

Root: `<appBase>/recapture/` where `<appBase>` is:
- **Android:** `context.getExternalFilesDir(null)` (app-scoped external), falling
  back to `context.filesDir` (app-scoped internal) when external is unavailable.
- **iOS:** `FileManager` `.applicationSupportDirectory` (user domain), falling back
  to `NSTemporaryDirectory()`.

Both are **app-private** — no `READ/WRITE_EXTERNAL_STORAGE`, no scoped-storage
`MediaStore`, not user-visible in the Files app by default.

| Relative path (under `<appBase>`) | Contents |
|---|---|
| `recapture/` | Storage root (`StorageSegments.ROOT_DIR`). |
| `recapture/<projectId>/` | One project's capture tree. |
| `recapture/<projectId>/<jobId>/` | One capture job (session). |
| `recapture/<projectId>/<jobId>/_manifest.json` | Job manifest marker (`JobManifest.FILE_NAME`); status `in_progress` / `complete`. |
| `recapture/<projectId>/<jobId>/images/` | Fixed `images` segment (`StorageSegments.IMAGES_DIR`). |
| `recapture/<projectId>/<jobId>/images/<level>/` | One capture level (`0`, `1`, …). Created on demand. |
| `…/images/<level>/NNNNNN.jpg` or `NNNNNN_<frameId>.jpg` | Captured frame; 6-digit zero-padded atomic sequence + optional sanitized frame id. |
| `…/images/<level>/NNNNNN[...].json` | Per-frame EXIF/metadata sidecar (shares the frame base name). |

There is **no** `frames/` or `exports/` directory. The brief's `frames` maps to
`images/<level>/`; export/processing output is out of scope for the storage backbone.

## 2. Creation trigger

- `recapture/<projectId>/<jobId>/images/<level>/` is created **on demand at first
  frame allocation** for that level — `CaptureStorage.levelDir(...)` (called by
  `newFramePath(...)`) runs `ensureDir()` → `mkdirs()`. Intermediate dirs
  (`recapture`, `<projectId>`, `<jobId>`, `images`) are created recursively in the
  same call.
- The job manifest dir + `_manifest.json` are written at `markJobStart()` (job
  start), independent of frame allocation.
- Nothing is created at app launch or project open. **Creation is lazy**, tied to
  capture, so a frame write can never find a missing parent — the same call that
  needs the dir creates it.

## 3. Creation method

- **Native, recursive, idempotent:** `File.mkdirs()` (Android, in `ensureDir`) /
  `FileManager.createDirectory(withIntermediateDirectories: true)` (iOS). A second
  call is a no-op (`if (dir.isDirectory) return`). `mkdirs` races are tolerated by
  re-checking `isDirectory` after the call.
- **Not Dart.** `Directory.create` is never used for the capture tree. The Dart
  `CaptureStorageClient` never creates directories — it only queries/deletes.

## 4. Cleanup trigger

| Trigger | Mechanism |
|---|---|
| **Project deleted by user** | `ProjectsNotifier.delete()` → `ProjectCaptureCleanup.purgeProjectCaptureData(projectId)` → native `purgeProject`. Purge-on-delete (Option A): space reclaimed immediately; a later soft-delete restore recovers the server record but **not** the local images. |
| **Orphaned project tree** (project deleted while app was off, missed its hook) | `CaptureStorageClient.sweepOrphanedCaptureData(knownProjectIds)` → native `sweepOrphans`, which purges any on-disk project not in the known set. |
| **Individual level / job** | `deleteLevel` / `deleteJob` (guarded against active jobs). |
| **App uninstall** | OS removes the entire app sandbox (`<appBase>`); no app code involved. |
| **Incomplete-job cleanup** | `listIncompleteJobs()` surfaces interrupted jobs (`in_progress` manifest or `no_manifest` with frames) for the caller to resume or delete. |

⚠️ **Real gap (see report §7):** `NativeProjectCaptureCleanup.purgeProjectCaptureData`
early-returns on any platform `!= TargetPlatform.android`, so **iOS project deletion
does not purge local capture data**, even though `CaptureStorage.swift` /
`CaptureStorageChannelHandler.swift` fully implement the native purge. iOS relies
entirely on an orphan sweep that is not yet invoked from Dart on iOS either.

## 5. Cleanup method

- `purgeProject` walks the project tree **bottom-up**, deleting files then empty
  dirs. Files that cannot be deleted (locked/in-use) are collected and reported as
  `partial` with their absolute paths (retryable) — never a silent partial state.
- `deleteJob`/`deleteLevel`/`deleteProject` use a top-down accounting pass + a
  recursive delete, returning `{ok, code, filesDeleted, bytesFreed}`.
- All deletes/purges are **guarded against active jobs** (`refused`/`active_job`)
  unless `force`, and re-sanitize the project id (no traversal) before touching disk.
- Idempotent: purging an absent tree returns `noop` success; deleting an absent
  tree returns `not_found` with `ok=true`.

## 6. Base path type

| Folder | Base | Persistence semantics |
|---|---|---|
| `recapture/…` (Android) | `getExternalFilesDir(null)` (or `filesDir`) | App-private, persists across app updates; removed on uninstall/clear-data. **Not** OS-purged like cache. |
| `recapture/…` (iOS) | `.applicationSupportDirectory` | App-private, backed up by default, persists across updates; removed on uninstall. **Not** the OS-purgeable Caches dir. |

`path_provider` is **not** used for the capture tree — the base is resolved
natively. (`path_provider` is in `pubspec.yaml` and used elsewhere, e.g. Hive.) The
brief's `getApplicationCacheDirectory()`/`getTemporaryDirectory()` cache-purge
concern does not apply: capture data lives in app-support/files, not cache/temp.

## 7. Project ID

- **Source:** server-issued Mongo `_id` (24-hex string), created by the backend
  `POST /projects` endpoint. The client never mints capture-storage project ids;
  it passes the server id straight through.
- **In paths:** used verbatim as the `<projectId>` segment, **after** strict
  allowlist sanitization (`StorageSegments.require`, `[A-Za-z0-9_-]{1,128}`).
- **Collision:** server `_id`s are unique, so two distinct projects never share a
  folder. A delete targets exactly one sanitized id, re-asserted to stay under
  `recapture/` (`assertWithin`), so it cannot delete a sibling's tree.

## 8. Concurrent-project risk

- Two projects cannot share a folder (distinct server ids → distinct
  `recapture/<id>/` subtrees).
- `deleteProject`/`purgeProject` operate on a single project subtree and never
  touch siblings (verified by `CaptureStorageTest.deleteLevel_removesOnlyThatLevel`
  and `sweepOrphans_purgesUnknownProjects_keepsKnownOnes`).
- Concurrent burst writes within one level are collision-free: a per-level
  `AtomicLong` sequence, seeded past existing frames (resume-safe), guarantees
  unique frame names even under 8-thread parallelism
  (`newFramePath_isCollisionFreeUnderConcurrentBurst`, 200 frames).
- A purge while another job in the **same** project is active is `refused`
  (nothing deleted) unless forced — an in-flight capture is never deleted out from
  under itself.

## 9. Known platform issues

- **Android scoped storage (API 29+):** avoided entirely. The tree is rooted under
  app-specific external/internal storage (`getExternalFilesDir`/`filesDir`), which
  is exempt from scoped-storage restrictions and needs no permission. No `MediaStore`,
  no `WRITE_EXTERNAL_STORAGE`.
- **iOS Files app visibility:** `.applicationSupportDirectory` is not user-visible
  unless `UISupportsDocumentBrowser`/`LSSupportsOpeningDocumentsInPlace` are set
  (they are not), so capture data is private — intended.
- **iOS open-file-handle deletion:** iOS may allow deleting a file with an open
  handle (unlinks immediately, handle stays valid); Android does the same. The
  `partial` path collects only files whose `delete()` actually fails.
- **iOS purge not wired from Dart (gap):** documented in §4 / report §7.

---

## Mapping the brief's required unit-test cases to reality

The brief's 18 `FolderManager` unit cases have no Dart class to target, but every
behaviour they describe is already covered natively (Kotlin) and/or by the Dart
transport client. The table below is the traceability used in report §3.

| Brief case | Covered by |
|---|---|
| 1 creates structure | `CaptureStorageTest.levelDir_buildsTheHierarchyUnderRoot_idempotently` |
| 2 idempotent | same (second call no-op) |
| 3 recursive intermediates | same (`mkdirs` recursive) |
| 4/5 absolute frames/exports path | `levelDir_…` (frames); no exports dir (N/A) |
| 6 empty projectId throws | `StorageSegments.require` rejects empty (allowlist `{1,128}`) |
| 7 traversal projectId throws | `craftedIds_areRejected_andCannotEscapeBase`, `purgeProject_craftedId_isRejected` |
| 8 delete removes tree | `deleteProject_removesWholeTree_theP1Hook`, `purgeProject_removesWholeTree` |
| 9 delete missing = no-op | `purgeProject_missingTree_isNoopSuccess` |
| 10 no sibling impact | `deleteLevel_removesOnlyThatLevel`, `sweepOrphans_…keepsKnownOnes` |
| 11 delete-all | `sweepOrphans_purgesUnknownProjects` (delete-all = sweep with empty known set) |
| 12 delete-all empty = no-op | `purgeProject`/`sweepOrphans` on empty root |
| 13 partial write cleanup | `purgeProject_reportsPartial_whenAFileCannotBeDeleted` |
| 14 listProjectFolders | `enumeration_listsFramesLevelsJobsProjects`, Dart `listProjects` |
| 15 list empty = [] | `listProjects` returns `emptyList()` |
| 16 framePathFor naming | `newFramePath_pairsSidecarAndAllocatesSequentially` |
| 17 negative index throws | `StorageSegments.level(Int)` rejects `< 0` |
| 18 non-overlapping paths | distinct project ids → distinct subtrees (path resolution) |

Plus the Dart-side lifecycle contract (transport + sequencing) is exercised by
`test/storage/capture_storage_test.dart` and the new
`test/qa/folder_lifecycle/folder_lifecycle_contract_test.dart` added by this task.
