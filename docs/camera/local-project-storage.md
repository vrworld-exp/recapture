# Local project folder management (`/recapture/{projectId}/{jobId}/images/{level}/`)

The filesystem backbone for capture output: resolves an app-scoped base, creates the
nested capture tree on demand, allocates collision-free frame (+ sidecar) paths under
concurrent burst writes, enumerates + accounts for size/space, marks + detects
incomplete jobs, and deletes levels/jobs/projects (guarded against active jobs). It is
the **storage layer only** — it captures nothing, writes no metadata *content* (the
burst + EXIF tasks do), and does no processing/upload. It provides paths, structure,
accounting, and cleanup.

Channel (Dart-facing ops): `com.mayasabhaxr.recapture/capture_storage`
(`AppConfig.channelCaptureStorage`).

## App-scoped storage — no permission (reconciles with P2)

Base = `context.getExternalFilesDir(null)` (larger capacity for capture data), falling
back to internal `filesDir` if external is unavailable; the `/recapture` tree is rooted
under that base. App-scoped storage needs **no** `READ/WRITE_EXTERNAL_STORAGE`, so
**capture output is decoupled from the storage permission**. The P2 storage permission,
if used at all, is for importing user media — never for capture output. The tree is
never rooted at filesystem root or shared/public storage.

```
<getExternalFilesDir|filesDir>/recapture/<projectId>/<jobId>/images/<level>/<frame>.jpg
                                                                           /<frame>.json   (sidecar)
<...>/recapture/<projectId>/<jobId>/_manifest.json                          (job marker)
```

## Security — no path traversal

`projectId`/`jobId`/`level`/`frameId` come from outside, so `StorageSegments` is a
strict **allowlist** (`[A-Za-z0-9_-]`, 1..128). That inherently rejects `..`, `/`, `\`,
null bytes, whitespace, dots, and every encoding trick — an invalid segment is
*rejected*, not "stripped". Defence in depth: every resolved dir/file is re-asserted to
stay under the base via canonical-path containment (`assertWithin`), so even a future
allowlist bug cannot write outside `/recapture`. An int `level` canonicalizes to a
stable decimal segment (`0`,`1`,…) so int and string forms map to one dir.

## Concurrency — collision-free allocation

Directory creation is `mkdirs` (idempotent, race-tolerant; re-checked after a possible
race). Frame allocation (`newFramePath`) draws from a per-level **`AtomicLong`** seeded
**past existing frames** (scanned once), so:

- concurrent burst writes never collide (atomic sequence), and
- a **resumed** job continues at `maxSeq+1` — it never overwrites earlier frames.

Names: `<seq6>_<frameId>.jpg` (a valid `frameId` is appended for traceability; an
invalid/blank one is dropped and the seq alone names the file). The sidecar shares the
base name with `.json` — exactly the pairing the EXIF/sidecar task derives
(`<frame>.json` alongside the frame).

## Accounting + free space

`usage(projectId[, jobId[, level]])` returns `{ frameCount, byteCount }`, walking the
scope lazily (`walkTopDown`) so a job with thousands of frames is streamed, not loaded
into memory. `frameCount` counts `.jpg` only; `byteCount` is the real on-disk footprint
(frames + sidecars + manifest). `freeSpaceBytes()` returns the volume's usable bytes
(walking up to the nearest existing ancestor) so the burst flow can stop gracefully
before filling storage.

## Incomplete-job detection

A per-job `_manifest.json` (in the job dir, above the `images/` levels) is written
`in_progress` at `markJobStart` and finalized `complete` at `markJobComplete`. A job is
**incomplete** if its manifest is missing but it holds frames (`no_manifest`) or its
manifest is not complete (`in_progress`) — `listIncompleteJobs()` returns those so the
flow can resume or clean them. An app killed mid-burst therefore leaves a detectable,
cleanable partial job.

## Deletion — complete + guarded

`deleteLevel`/`deleteJob`/`deleteProject` remove the whole subtree (no orphans) and
report `{ ok, code, filesDeleted, bytesFreed }`. They are **guarded** against active
jobs (a job between start/complete): a delete in scope of an active job is refused with
`active_job` unless `force=true`, so a capture is never deleted out from under itself.
`deleteProject` is the **P1 project-deletion cleanup hook** — when a project is deleted,
its capture data is removed (no orphaned `/recapture` subtree).

The project-deletion cleanup is driven by `purgeProject` (richer reporting:
`ok`/`partial`/`refused`/`noop`, reclaimed bytes, and the surviving paths on a
partial), plus an optional `sweepOrphans` for data a deleted project left behind.
Purge timing is reconciled with P1's soft-delete as **purge-on-delete (Option A)** —
see [storage-cleanup-on-delete.md](./storage-cleanup-on-delete.md).

## Threading

All methods do blocking file I/O and MUST run off the main thread. They are synchronous
(the native burst task already runs on its capture executor); the MethodChannel layer
dispatches Dart-initiated calls to a dedicated single-thread executor and replies on the
platform thread. I/O errors (full/denied/missing) return clear results/errors, never a
crash.

## Pieces

| Layer | File | Role |
|-------|------|------|
| Native | `android/.../storage/StorageSegments.kt` | Pure: allowlist sanitization, frame/sidecar naming, sequence parse, containment. JVM-testable. |
| Native | `android/.../storage/JobManifest.kt` | Pure: job manifest model + encode/parse (incomplete detection). JVM-testable. |
| Native | `android/.../storage/CaptureStorage.kt` | The manager: resolve/create, allocate, enumerate, account, mark/detect incomplete, delete (guarded). Injectable base ⇒ JVM-testable; `fromContext` resolves the app-scoped base. |
| Native | `android/.../MainActivity.kt` | Registers the capture-storage MethodChannel (off-main dispatch). |
| Native (iOS) | `ios/Runner/StorageSegments.swift` | Port of `StorageSegments.kt`: allowlist sanitization, frame/sidecar naming, sequence parse, canonical-path containment. Flutter-free. |
| Native (iOS) | `ios/Runner/JobManifest.swift` | Port of `JobManifest.kt`: wire-compatible manifest model + encode/parse (`in_progress`/`complete`, `_manifest.json`). |
| Native (iOS) | `ios/Runner/CaptureStorage.swift` | Port of `CaptureStorage.kt`: resolve/create, allocate, enumerate, account, mark/detect incomplete, delete/purge/sweep (guarded). Injectable root ⇒ testable; `fromApplicationSupport` resolves the iOS app-scoped base (Application Support, matching `CameraCaptureManager`). |
| Native (iOS) | `ios/Runner/CaptureStorageChannelHandler.swift` + `AppDelegate.swift` | Registers + dispatches the SAME `capture_storage` MethodChannel off the platform thread (serial I/O queue, replies on main); same error codes (`INVALID_ARGS`/`SECURITY`/`STORAGE_ERROR`). |
| Dart | `lib/platform/capture_storage.dart` | `CaptureStorageClient` — accounting, free space, incomplete jobs, delete hooks. Platform-agnostic (drives both Android + iOS). |

## Coordination (out of scope here)

- **Burst task** (`CameraCaptureManager`): currently writes to its own `captures/<sessionId>`
  scheme. This manager supplies the `/recapture/...` paths + collision-free allocation +
  job markers it can adopt; the write/allocate handoff (passing `projectId`/`jobId`/`level`
  through the capture MethodChannel) is a follow-up wiring, not this task.
- **EXIF/sidecar task**: the sidecar naming/pairing here (`<frame>.json` alongside) matches
  what `CaptureMetadataWriter` derives — kept consistent.

## Tests

- `StorageSegmentsTest.kt` — allowlist accepts valid ids; rejects `..`/separators/null
  bytes/whitespace/over-length; naming uniqueness + sidecar pairing; sequence parse;
  containment escape → `SecurityException`.
- `JobManifestTest.kt` — encode/parse round-trip (in-progress/complete), malformed → null.
- `CaptureStorageTest.kt` (temp dir) — hierarchy + idempotent create; traversal rejected
  with nothing written outside base; collision-free concurrent allocation (200 parallel);
  resume seeding past existing frames; enumeration; usage counts/bytes; positive free
  space; incomplete detection; guarded + complete deletes (incl. the project hook).
- `test/storage/capture_storage_test.dart` — channel arg forwarding + result parsing,
  incomplete-job filtering, guarded-delete `active_job` surfacing.

On-device acceptance (no-permission write, real concurrent burst, storage-full graceful
stop, app-killed resume, large-job enumeration profiling, off-main I/O) is verified
manually per the task's testing steps.
