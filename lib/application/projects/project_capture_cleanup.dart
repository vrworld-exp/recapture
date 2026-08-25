// lib/application/projects/project_capture_cleanup.dart
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../platform/capture_storage.dart';

/// Reclaims a deleted project's LOCAL capture data (the native Android
/// `/recapture/{projectId}/` tree of frames/sidecars/manifests). The seam the
/// projects flow depends on, so the notifier stays platform-agnostic and tests
/// can inject a double. This is local cleanup ONLY — the server-side project
/// delete is P1's concern.
abstract interface class ProjectCaptureCleanup {
  /// Purges the project's local capture data. Best-effort: the project is
  /// already deleted server-side, so this MUST never throw or block the delete —
  /// a failure just means the space was not reclaimed.
  Future<void> purgeProjectCaptureData(String projectId);
}

/// Default [ProjectCaptureCleanup] backed by the native capture-storage channel.
/// Capture data exists only in the native Android pipeline, so this is a no-op
/// on every other platform, and any channel error is swallowed (purge timing is
/// Option A — purge-on-delete — but a missed purge never fails the delete).
class NativeProjectCaptureCleanup implements ProjectCaptureCleanup {
  NativeProjectCaptureCleanup([CaptureStorageClient? client])
      : _client = client ?? CaptureStorageClient();

  final CaptureStorageClient _client;

  @override
  Future<void> purgeProjectCaptureData(String projectId) async {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) return;
    try {
      await _client.purgeProjectCaptureData(projectId);
    } catch (_) {
      // Space not reclaimed (e.g. an active-job refusal or I/O error). The
      // orphan sweep can recover it later; never block or fail the delete.
    }
  }
}

/// The cleanup seam the projects flow reads. Overridden in tests.
final projectCaptureCleanupProvider = Provider<ProjectCaptureCleanup>(
  (ref) => NativeProjectCaptureCleanup(),
);
