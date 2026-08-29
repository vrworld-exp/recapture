// lib/platform/capture_ports/capture_storage_port_web.dart
//
// WEB implementation of [CaptureStoragePort] over the IndexedDB store in
// web_capture_store.dart.
//
// Every rule the native manager enforces is reproduced, not approximated:
//  • usage is a real count + byte sum over the scope's index range;
//  • a delete whose scope contains an ACTIVE job is refused with
//    `code == 'active_job'` (and a purge with `status == 'refused'`) unless
//    forced — the project-deletion cleanup hook branches on exactly that;
//  • a purge of a project with no data is `noop`, not `ok`, so the caller can
//    tell "nothing to do" from "removed something";
//  • the orphan sweep skips projects whose jobs are active.
//
// `partial` never occurs here: IndexedDB has no per-file locking, so a delete
// either succeeds or throws — and a throw is reported as `io_error`, matching
// what a native I/O failure produces.

import 'package:flutter/services.dart';

import 'capture_storage_port.dart';
import 'web_capture_store.dart';

/// Selected by the conditional import in lib/platform/capture_storage.dart on a
/// web build. The channel argument exists only to match the factory signature.
CaptureStoragePort createCaptureStoragePort([MethodChannel? channel]) =>
    WebCaptureStoragePort();

/// IndexedDB-backed [CaptureStoragePort].
class WebCaptureStoragePort implements CaptureStoragePort {
  WebCaptureStoragePort();

  WebCaptureStore get _store => WebCaptureStore.instance;

  /// Remaining quota (`quota - usage`). Returns 0 when the Storage API is
  /// absent, which the preflight probe reports as "quota unknown" rather than
  /// letting a capture start it cannot finish.
  @override
  Future<int> freeSpaceBytes() async {
    final e = await _store.estimate();
    final quota = e.quota;
    final used = e.usage;
    if (quota == null) return 0;
    final free = quota - (used ?? 0);
    return free < 0 ? 0 : free;
  }

  @override
  Future<StorageUsage> usage(
    String projectId, {
    String? jobId,
    String? level,
  }) async {
    final frames =
        await _store.listFrames(projectId, jobId: jobId, level: level);
    var bytes = 0;
    for (final f in frames) {
      bytes += f.byteCount;
    }
    return StorageUsage(frameCount: frames.length, byteCount: bytes);
  }

  @override
  Future<List<String>> listProjects() => _store.listProjects();

  @override
  Future<List<String>> listJobs(String projectId) => _store.listJobs(projectId);

  @override
  Future<List<IncompleteJob>> listIncompleteJobs() async {
    final rows = await _store.listIncompleteJobs();
    return [
      for (final r in rows)
        IncompleteJob(
          projectId: r.projectId,
          jobId: r.jobId,
          reason: r.reason,
        ),
    ];
  }

  @override
  Future<StorageDeleteResult> deleteLevel(
    String projectId,
    String jobId,
    String level, {
    bool force = false,
  }) =>
      _guardedDelete(projectId, jobId: jobId, level: level, force: force);

  @override
  Future<StorageDeleteResult> deleteJob(
    String projectId,
    String jobId, {
    bool force = false,
  }) =>
      _guardedDelete(projectId, jobId: jobId, force: force, dropJobRows: true);

  @override
  Future<StorageDeleteResult> deleteProject(
    String projectId, {
    bool force = false,
  }) =>
      _guardedDelete(projectId, force: force, dropJobRows: true);

  @override
  Future<PurgeResult> purgeProjectCaptureData(
    String projectId, {
    bool force = false,
  }) async {
    try {
      if (!force && await _store.hasActiveJob(projectId)) {
        return const PurgeResult(status: 'refused', reclaimedBytes: 0);
      }
      final deleted = await _store.deleteFrames(projectId);
      await _store.deleteJobRows(projectId);
      if (deleted.files == 0) {
        return const PurgeResult(status: 'noop', reclaimedBytes: 0);
      }
      return PurgeResult(status: 'ok', reclaimedBytes: deleted.bytes);
    } catch (_) {
      return const PurgeResult(status: 'io_error', reclaimedBytes: 0);
    }
  }

  @override
  Future<SweepResult> sweepOrphanedCaptureData(
    List<String> knownProjectIds, {
    bool force = false,
  }) async {
    final known = knownProjectIds.toSet();
    final purged = <String>[];
    final skipped = <String>[];
    var reclaimed = 0;
    for (final projectId in await _store.listProjects()) {
      if (known.contains(projectId)) continue;
      final result = await purgeProjectCaptureData(projectId, force: force);
      if (result.ok) {
        purged.add(projectId);
        reclaimed += result.reclaimedBytes;
      } else if (!result.isNoop) {
        skipped.add(projectId);
      }
    }
    return SweepResult(
      purgedProjects: purged,
      reclaimedBytes: reclaimed,
      skipped: skipped,
    );
  }

  @override
  void setActiveScope({
    required String projectId,
    required String jobId,
    required String level,
  }) {
    _store.scope = CaptureScope(
      projectId: projectId,
      jobId: jobId,
      level: level,
    );
  }

  @override
  Future<void> setJobActive(
    String projectId,
    String jobId, {
    required bool active,
  }) =>
      _store.setJobActive(projectId, jobId, active: active);

  @override
  Future<void> markJobComplete(String projectId, String jobId) =>
      _store.markJobComplete(projectId, jobId);

  @override
  Future<Uint8List?> readFrameBytes(String path) => _store.readBytes(path);

  Future<StorageDeleteResult> _guardedDelete(
    String projectId, {
    String? jobId,
    String? level,
    bool force = false,
    bool dropJobRows = false,
  }) async {
    try {
      if (!force && await _store.hasActiveJob(projectId, jobId: jobId)) {
        return const StorageDeleteResult(
          ok: false,
          code: 'active_job',
          filesDeleted: 0,
          bytesFreed: 0,
        );
      }
      final deleted =
          await _store.deleteFrames(projectId, jobId: jobId, level: level);
      if (dropJobRows) {
        await _store.deleteJobRows(projectId, jobId: jobId);
      }
      return StorageDeleteResult(
        ok: true,
        code: 'ok',
        filesDeleted: deleted.files,
        bytesFreed: deleted.bytes,
      );
    } catch (_) {
      return const StorageDeleteResult(
        ok: false,
        code: 'io_error',
        filesDeleted: 0,
        bytesFreed: 0,
      );
    }
  }
}
