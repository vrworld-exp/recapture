# Storage cleanup on project delete (`purgeProjectCaptureData`)

When a project is deleted, its **local** capture data — the entire
`/recapture/{projectId}/` tree (every job, level, frame, sidecar, manifest) under
app-scoped storage — is purged to reclaim space. This is the cleanup hook the
[storage manager](./local-project-storage.md) reserved. It removes **local capture
data only**; the server-side project record is P1's concern.

Channel: `com.mayasabhaxr.recapture/capture_storage` (`AppConfig.channelCaptureStorage`).

```
purgeProjectCaptureData(projectId, force?)
  -> { status: "ok"|"partial"|"refused"|"noop", reclaimedBytes, failed: [paths] }

sweepOrphanedCaptureData(knownProjectIds, force?)   // optional
  -> { purgedProjects: [...], reclaimedBytes, skipped: [...] }
```

## Purge timing — reconciled with P1 soft-delete (Option A: purge-on-delete)

P1's `DELETE /projects/:id` is a **soft** delete (the server record is
recoverable). The cross-phase decision is *when* the (large, local) capture
images are reclaimed. **Confirmed: Option A — purge on delete.**

> **Restore implication (documented):** the user's delete reclaims the local
> capture images **immediately**. A later restore recovers the server project
> record but **NOT** its local capture data — that is gone. This is the accepted
> trade-off for reclaiming space at delete time. (Alternatives considered:
> Option B — retain while soft-deleted, purge on hard-delete/grace; Option C —
> retain until an explicit "free up space" action. Neither is implemented; the
> client currently surfaces no hard-delete/grace/restore signal.)

### Trigger (client flow)

`ProjectsNotifier.delete(id)` purges **after** the repo delete is confirmed
(`lib/application/projects/projects_notifier.dart` → `ProjectCaptureCleanup`):

```
await _repo.delete(id);                       // server soft-delete confirmed
await _captureCleanup.purgeProjectCaptureData(id);   // reclaim local capture NOW
```

The purge is **best-effort**: the project is already deleted server-side, so a
purge failure (refused/IO) never rolls back the delete or fails the UI — the
[orphan sweep](#orphan-sweep-optional) can reclaim it later. It is also a no-op
off Android (capture data lives only in the native Android pipeline).

## Guarantees

| Property | Behaviour |
|----------|-----------|
| **Sanitized / exact-match** | `projectId` goes through `StorageSegments.require` (strict allowlist), so `../otherProject`, separators, and null bytes are *rejected* — never traversing out or hitting another project's tree. Every resolved path is re-asserted under the base (`assertWithin`). |
| **Active-job guarded** | While **any** job in the project is active (between `markJobStart`/`markJobComplete`) the purge is **`refused`** and deletes nothing, unless `force=true`. An in-flight capture is never deleted out from under itself. (Policy: **refuse if active**, not cancel-first.) |
| **Idempotent** | A missing tree (never captured / already purged) is a **`noop`** success — no crash. |
| **Complete or honest** | Removes the whole subtree bottom-up. If some files are locked/in-use they survive and are returned as **`partial`** with their absolute paths in `failed` (retry exactly those) — never a silent partial. |
| **Reports reclaimed space** | `reclaimedBytes` = on-disk footprint of the files actually deleted (reported even on `partial`). |
| **Off-main** | All I/O runs on the storage manager's dedicated single-thread executor (the channel layer dispatches off the platform thread). |
| **Scope** | Only `/recapture/{projectId}/` is ever touched — never another project, never the whole `/recapture` tree, never outside the app-scoped base. |

## Status values

- `ok` — the whole tree was removed.
- `partial` — some files were locked/in-use and survived; see `failed` (retryable).
- `refused` — a capture job for the project is active; nothing was deleted.
- `noop` — nothing to purge (never captured / already gone); idempotent success.

## Orphan sweep (optional)

`sweepOrphanedCaptureData(knownProjectIds)` reclaims space from capture trees on
disk whose project is **not** in the caller-supplied known set — data left behind
by a project deleted while the app was off (it missed its delete hook). The known
list comes from the app (server/local project list); the native manager keeps no
project list of its own. Each orphan goes through `purgeProject`, so the **same**
guards/policy apply (sanitization, active-job refusal, idempotency, partial
reporting). A dir whose name is not a valid project id is left untouched and
reported in `skipped` — never force-deleted.

## Pieces

| Layer | File | Role |
|-------|------|------|
| Native | `android/.../storage/CaptureStorage.kt` | `purgeProject` (status/reclaimed-bytes/failed-paths, active-job guard) + `sweepOrphans`; bottom-up `purgeTree` collects file-delete failures. |
| Native | `android/.../MainActivity.kt` | Channel methods `purgeProjectCaptureData` + `sweepOrphanedCaptureData` (off-main dispatch). |
| Dart | `lib/platform/capture_storage.dart` | `CaptureStorageClient.purgeProjectCaptureData` / `sweepOrphanedCaptureData`; `PurgeResult` / `SweepResult`. |
| Dart | `lib/application/projects/project_capture_cleanup.dart` | `ProjectCaptureCleanup` seam (Android-guarded, error-swallowing) so the notifier stays platform-agnostic + testable. |
| Dart | `lib/application/projects/projects_notifier.dart` | Calls the purge hook after a confirmed delete (Option A). |

## Tests

- `CaptureStorageTest.kt` — purge removes the whole tree + reports bytes (`ok`);
  missing → `noop`; idempotent (purge twice); `refused` while active + `force`
  override; crafted id rejected (nothing escapes); `partial` with the failed path
  when a file is undeletable (POSIX parent-dir-read-only sim, skipped where the
  platform doesn't honor it); orphan sweep purges unknown projects + keeps known +
  skips an active orphan.
- `test/storage/capture_storage_test.dart` — channel arg forwarding + result
  parsing for `ok`/`partial`/`refused`/`noop` and the sweep (known-list forwarding).
- `test/projects/projects_notifier_test.dart` — delete purges local capture
  (Option A); a failed delete does **not** purge (capture retained); an
  already-gone delete still confirms + purges.

On-device acceptance (real multi-GB off-main delete, locked-file partial, active
capture refusal, restore-shows-no-local-images) is verified manually per the
task's testing steps.
