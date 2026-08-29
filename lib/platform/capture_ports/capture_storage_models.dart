// lib/platform/capture_ports/capture_storage_models.dart
//
// The capture-storage result types, moved out of lib/platform/capture_storage.dart
// (which re-exports them) so the port interface and both implementations can
// share them without an import cycle. Shapes, field names and the `fromMap`
// parsing are unchanged — the web IndexedDB port fills in exactly the same
// vocabulary, including the `active_job` / `refused` guard codes the project
// deletion cleanup hook branches on.
import 'package:flutter/foundation.dart';

/// Frame count + on-disk bytes for a level/job/project scope.
@immutable
class StorageUsage {
  const StorageUsage({required this.frameCount, required this.byteCount});

  final int frameCount;
  final int byteCount;

  static StorageUsage fromMap(Map<Object?, Object?> map) => StorageUsage(
        frameCount: (map['frameCount'] as num?)?.toInt() ?? 0,
        byteCount: (map['byteCount'] as num?)?.toInt() ?? 0,
      );
}

/// A job interrupted mid-capture (manifest missing or not complete).
@immutable
class IncompleteJob {
  const IncompleteJob({
    required this.projectId,
    required this.jobId,
    required this.reason,
  });

  final String projectId;
  final String jobId;

  /// `no_manifest` (data but no marker) or `in_progress` (started, not finalized).
  final String reason;

  static IncompleteJob? fromMap(Object? value) {
    if (value is! Map) return null;
    final projectId = value['projectId'] as String?;
    final jobId = value['jobId'] as String?;
    if (projectId == null || jobId == null) return null;
    return IncompleteJob(
      projectId: projectId,
      jobId: jobId,
      reason: value['reason'] as String? ?? 'unknown',
    );
  }
}

/// Result of a delete (level/job/project). [ok] false with [code] `active_job`
/// means the delete was guarded because a job in scope is actively capturing.
@immutable
class StorageDeleteResult {
  const StorageDeleteResult({
    required this.ok,
    required this.code,
    required this.filesDeleted,
    required this.bytesFreed,
  });

  final bool ok;
  final String code;
  final int filesDeleted;
  final int bytesFreed;

  /// Whether the delete was refused because a job in scope is active.
  bool get guardedByActiveJob => code == 'active_job';

  static StorageDeleteResult fromMap(Map<Object?, Object?> map) =>
      StorageDeleteResult(
        ok: map['ok'] as bool? ?? false,
        code: map['code'] as String? ?? 'io_error',
        filesDeleted: (map['filesDeleted'] as num?)?.toInt() ?? 0,
        bytesFreed: (map['bytesFreed'] as num?)?.toInt() ?? 0,
      );
}

/// Result of purging a project's local capture data
/// ([CaptureStorageClient.purgeProjectCaptureData]).
@immutable
class PurgeResult {
  const PurgeResult({
    required this.status,
    required this.reclaimedBytes,
    this.failed = const [],
  });

  /// `ok` (whole tree removed), `partial` (some files locked/in-use survived —
  /// see [failed]), `refused` (a capture job for the project is active, nothing
  /// deleted), or `noop` (nothing to purge — never captured / already gone).
  final String status;

  /// On-disk bytes of the files actually deleted (still reported on `partial`).
  final int reclaimedBytes;

  /// Absolute paths that could not be deleted — retry exactly these. Non-empty
  /// only when [status] is `partial`.
  final List<String> failed;

  bool get ok => status == 'ok';
  bool get isPartial => status == 'partial';
  bool get refusedByActiveJob => status == 'refused';
  bool get isNoop => status == 'noop';

  static PurgeResult fromMap(Map<Object?, Object?> map) => PurgeResult(
        status: map['status'] as String? ?? 'io_error',
        reclaimedBytes: (map['reclaimedBytes'] as num?)?.toInt() ?? 0,
        failed:
            (map['failed'] as List?)?.whereType<String>().toList() ?? const [],
      );
}

/// Result of an orphan sweep ([CaptureStorageClient.sweepOrphanedCaptureData]).
@immutable
class SweepResult {
  const SweepResult({
    this.purgedProjects = const [],
    this.reclaimedBytes = 0,
    this.skipped = const [],
  });

  /// Project ids whose orphaned capture trees were purged.
  final List<String> purgedProjects;
  final int reclaimedBytes;

  /// Project ids left untouched (a job was active, the purge was partial, or the
  /// dir name was not a valid project id).
  final List<String> skipped;

  static SweepResult fromMap(Map<Object?, Object?> map) => SweepResult(
        purgedProjects:
            (map['purgedProjects'] as List?)?.whereType<String>().toList() ??
                const [],
        reclaimedBytes: (map['reclaimedBytes'] as num?)?.toInt() ?? 0,
        skipped:
            (map['skipped'] as List?)?.whereType<String>().toList() ?? const [],
      );
}
