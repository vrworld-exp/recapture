// lib/platform/capture_ports/capture_storage_port_stub.dart
//
// Compile-time fallback for the platform-split [CaptureStoragePort]. Only
// reachable on a target with neither `dart:io` nor `dart:js_interop`. It reports
// an empty, immutable store rather than throwing, so a stray build shows
// "nothing captured" instead of crashing the project-deletion cleanup hook.

import 'package:flutter/services.dart';

import 'capture_storage_port.dart';

CaptureStoragePort createCaptureStoragePort([MethodChannel? channel]) =>
    const _UnsupportedCaptureStoragePort();

class _UnsupportedCaptureStoragePort implements CaptureStoragePort {
  const _UnsupportedCaptureStoragePort();

  @override
  Future<int> freeSpaceBytes() async => 0;

  @override
  Future<StorageUsage> usage(String projectId,
          {String? jobId, String? level}) async =>
      const StorageUsage(frameCount: 0, byteCount: 0);

  @override
  Future<List<String>> listProjects() async => const [];

  @override
  Future<List<String>> listJobs(String projectId) async => const [];

  @override
  Future<List<IncompleteJob>> listIncompleteJobs() async => const [];

  @override
  Future<StorageDeleteResult> deleteLevel(
    String projectId,
    String jobId,
    String level, {
    bool force = false,
  }) async =>
      _noop;

  @override
  Future<StorageDeleteResult> deleteJob(
    String projectId,
    String jobId, {
    bool force = false,
  }) async =>
      _noop;

  @override
  Future<StorageDeleteResult> deleteProject(
    String projectId, {
    bool force = false,
  }) async =>
      _noop;

  @override
  Future<PurgeResult> purgeProjectCaptureData(
    String projectId, {
    bool force = false,
  }) async =>
      const PurgeResult(status: 'noop', reclaimedBytes: 0);

  @override
  Future<SweepResult> sweepOrphanedCaptureData(
    List<String> knownProjectIds, {
    bool force = false,
  }) async =>
      const SweepResult();

  @override
  void setActiveScope({
    required String projectId,
    required String jobId,
    required String level,
  }) {}

  @override
  Future<void> setJobActive(
    String projectId,
    String jobId, {
    required bool active,
  }) async {}

  @override
  Future<void> markJobComplete(String projectId, String jobId) async {}

  @override
  Future<Uint8List?> readFrameBytes(String path) async => null;

  static const StorageDeleteResult _noop = StorageDeleteResult(
    ok: true,
    code: 'ok',
    filesDeleted: 0,
    bytesFreed: 0,
  );
}
