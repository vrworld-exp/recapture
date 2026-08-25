// lib/platform/capture_storage.dart
//
// MethodChannel wrapper for the native app-scoped capture storage backbone
// (/recapture/{projectId}/{jobId}/images/{level}/). Dart uses this for accounting
// (counts/bytes), free-space checks, incomplete-job listing, and deletion — most
// importantly the P1 project-deletion cleanup hook (delete a project's capture data
// when the project is deleted). Frame path allocation + writing stay native (the
// burst task owns those). Channel: com.mayasabhaxr.recapture/capture_storage
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../utils/constants.dart';

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
        failed: (map['failed'] as List?)?.whereType<String>().toList() ?? const [],
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
        skipped: (map['skipped'] as List?)?.whereType<String>().toList() ?? const [],
      );
}

/// Dart entry point to the native capture storage manager.
class CaptureStorageClient {
  CaptureStorageClient([MethodChannel? channel])
      : _channel = channel ?? const MethodChannel(AppConfig.channelCaptureStorage);

  final MethodChannel _channel;

  /// Usable bytes on the volume holding the capture tree (for pre-burst space checks).
  Future<int> freeSpaceBytes() async {
    final v = await _channel.invokeMethod<Object?>('freeSpace');
    return (v as num?)?.toInt() ?? 0;
  }

  /// Frame count + bytes for a project, a job (`jobId`), or a level (`jobId`+`level`).
  Future<StorageUsage> usage(
    String projectId, {
    String? jobId,
    String? level,
  }) async {
    final map = await _channel.invokeMapMethod<Object?, Object?>('usage', {
      'projectId': projectId,
      if (jobId != null) 'jobId': jobId,
      if (level != null) 'level': level,
    });
    return StorageUsage.fromMap(map ?? const {});
  }

  Future<List<String>> listProjects() async {
    final list = await _channel.invokeListMethod<String>('listProjects');
    return list ?? const [];
  }

  Future<List<String>> listJobs(String projectId) async {
    final list = await _channel
        .invokeListMethod<String>('listJobs', {'projectId': projectId});
    return list ?? const [];
  }

  /// Jobs interrupted mid-capture (resumable or cleanable).
  Future<List<IncompleteJob>> listIncompleteJobs() async {
    final list = await _channel.invokeListMethod<Object?>('listIncompleteJobs');
    return (list ?? const [])
        .map(IncompleteJob.fromMap)
        .whereType<IncompleteJob>()
        .toList();
  }

  Future<StorageDeleteResult> deleteLevel(
    String projectId,
    String jobId,
    String level, {
    bool force = false,
  }) =>
      _delete('deleteLevel', {
        'projectId': projectId,
        'jobId': jobId,
        'level': level,
        'force': force,
      });

  Future<StorageDeleteResult> deleteJob(
    String projectId,
    String jobId, {
    bool force = false,
  }) =>
      _delete('deleteJob', {
        'projectId': projectId,
        'jobId': jobId,
        'force': force,
      });

  /// Deletes a project's entire capture tree — the P1 project-deletion cleanup hook.
  /// Guarded against active jobs unless [force].
  Future<StorageDeleteResult> deleteProject(
    String projectId, {
    bool force = false,
  }) =>
      _delete('deleteProject', {'projectId': projectId, 'force': force});

  Future<StorageDeleteResult> _delete(
    String method,
    Map<String, Object?> args,
  ) async {
    final map = await _channel.invokeMapMethod<Object?, Object?>(method, args);
    return StorageDeleteResult.fromMap(map ?? const {});
  }

  /// Purges a project's entire local capture tree (`/recapture/{projectId}/`) —
  /// the project-deletion cleanup hook. Reconciled with P1's soft delete as
  /// purge-on-delete (Option A): a restored project recovers its server record
  /// but NOT these local capture images. Guarded against an active capture job
  /// (`refused`) unless [force]; idempotent (`noop` when already gone); reports
  /// `partial` + the surviving paths if some files are locked.
  Future<PurgeResult> purgeProjectCaptureData(
    String projectId, {
    bool force = false,
  }) async {
    final map = await _channel.invokeMapMethod<Object?, Object?>(
      'purgeProjectCaptureData',
      {'projectId': projectId, 'force': force},
    );
    return PurgeResult.fromMap(map ?? const {});
  }

  /// Optional orphan sweep: purges capture trees for projects NOT in
  /// [knownProjectIds] (data left behind by a project deleted while the app was
  /// off). Pass the app's current project ids (server/local list). Applies the
  /// same guards/policy as a single purge.
  Future<SweepResult> sweepOrphanedCaptureData(
    List<String> knownProjectIds, {
    bool force = false,
  }) async {
    final map = await _channel.invokeMapMethod<Object?, Object?>(
      'sweepOrphanedCaptureData',
      {'knownProjectIds': knownProjectIds, 'force': force},
    );
    return SweepResult.fromMap(map ?? const {});
  }
}
