// lib/platform/capture_ports/capture_storage_port_io.dart
//
// NATIVE implementation of [CaptureStoragePort]: the `capture_storage`
// MethodChannel, with exactly the calls and argument maps
// lib/platform/capture_storage.dart made before the port existed. Android and
// iOS behaviour is unchanged.
//
// The four additive members are deliberately inert here: the native manager
// derives the project/job/level scope, the active-job flag and the manifest
// marker from the session IT owns, so re-declaring them from Dart would be a
// second source of truth. Only [readFrameBytes] does real work — it reads the
// file the native capture wrote.
import 'dart:io';

import 'package:flutter/services.dart';

import '../../utils/constants.dart';
import 'capture_storage_port.dart';

/// Selected by the conditional import in lib/platform/capture_storage.dart when
/// `dart:io` exists (Android / iOS / the unit-test host).
CaptureStoragePort createCaptureStoragePort([MethodChannel? channel]) =>
    ChannelCaptureStoragePort(channel);

/// MethodChannel-backed [CaptureStoragePort].
class ChannelCaptureStoragePort implements CaptureStoragePort {
  ChannelCaptureStoragePort([MethodChannel? channel])
      : _channel =
            channel ?? const MethodChannel(AppConfig.channelCaptureStorage);

  final MethodChannel _channel;

  @override
  Future<int> freeSpaceBytes() async {
    final v = await _channel.invokeMethod<Object?>('freeSpace');
    return (v as num?)?.toInt() ?? 0;
  }

  @override
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

  @override
  Future<List<String>> listProjects() async {
    final list = await _channel.invokeListMethod<String>('listProjects');
    return list ?? const [];
  }

  @override
  Future<List<String>> listJobs(String projectId) async {
    final list = await _channel
        .invokeListMethod<String>('listJobs', {'projectId': projectId});
    return list ?? const [];
  }

  @override
  Future<List<IncompleteJob>> listIncompleteJobs() async {
    final list = await _channel.invokeListMethod<Object?>('listIncompleteJobs');
    return (list ?? const [])
        .map(IncompleteJob.fromMap)
        .whereType<IncompleteJob>()
        .toList();
  }

  @override
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

  @override
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

  @override
  Future<StorageDeleteResult> deleteProject(
    String projectId, {
    bool force = false,
  }) =>
      _delete('deleteProject', {'projectId': projectId, 'force': force});

  @override
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

  @override
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

  /// No-op: the native manager owns the session directory and derives the
  /// project/job/level scope itself.
  @override
  void setActiveScope({
    required String projectId,
    required String jobId,
    required String level,
  }) {}

  /// No-op: the native manager tracks its own active jobs (that is what the
  /// channel's delete guard consults).
  @override
  Future<void> setJobActive(
    String projectId,
    String jobId, {
    required bool active,
  }) async {}

  /// No-op: the native side writes the job manifest marker.
  @override
  Future<void> markJobComplete(String projectId, String jobId) async {}

  @override
  Future<Uint8List?> readFrameBytes(String path) async {
    final file = File(path);
    if (!file.existsSync()) return null;
    return file.readAsBytes();
  }

  Future<StorageDeleteResult> _delete(
    String method,
    Map<String, Object?> args,
  ) async {
    final map = await _channel.invokeMapMethod<Object?, Object?>(method, args);
    return StorageDeleteResult.fromMap(map ?? const {});
  }
}
