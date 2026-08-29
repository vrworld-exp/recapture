// lib/application/projects/project_capture_cleanup.dart
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../platform/capture_storage.dart';

/// Reclaims a deleted project's LOCAL capture data — the Android
/// `/recapture/{projectId}/` tree of frames/sidecars/manifests, or the
/// equivalent IndexedDB keys on web. The seam the projects flow depends on, so
/// the notifier stays platform-agnostic and tests can inject a double. This is
/// local cleanup ONLY — the server-side project delete is P1's concern.
abstract interface class ProjectCaptureCleanup {
  /// Purges the project's local capture data. Best-effort: the project is
  /// already deleted server-side, so this MUST never throw or block the delete —
  /// a failure just means the space was not reclaimed.
  Future<void> purgeProjectCaptureData(String projectId);
}

/// Default [ProjectCaptureCleanup] backed by [CaptureStorageClient], which
/// resolves to the native capture-storage channel on Android and to the
/// IndexedDB capture store on web.
///
/// The platform check is a whitelist rather than a `!= android` bail-out
/// because the answer is now genuinely per-platform: Android and web both HOLD
/// capture data and must both purge it, while iOS does not yet have a capture
/// storage backend to purge. Skipping web here would leave a browser's captures
/// orphaned forever — the exact leak the purge exists to prevent.
///
/// Any error is swallowed (purge timing is Option A — purge-on-delete — but a
/// missed purge never fails the delete; the orphan sweep can recover it later).
class NativeProjectCaptureCleanup implements ProjectCaptureCleanup {
  NativeProjectCaptureCleanup([CaptureStorageClient? client])
      : _client = client ?? CaptureStorageClient();

  final CaptureStorageClient _client;

  @override
  Future<void> purgeProjectCaptureData(String projectId) async {
    if (!_platformHoldsCaptureData) return;
    try {
      await _client.purgeProjectCaptureData(projectId);
    } catch (_) {
      // Space not reclaimed (e.g. an active-job refusal or I/O error). The
      // orphan sweep can recover it later; never block or fail the delete.
    }
  }

  /// Whether this platform stores capture data that a project delete should
  /// reclaim. Web first — `defaultTargetPlatform` reports the HOST OS in a
  /// browser, so checking it first would classify a phone browser by the phone.
  static bool get _platformHoldsCaptureData =>
      kIsWeb || defaultTargetPlatform == TargetPlatform.android;
}

/// The cleanup seam the projects flow reads. Overridden in tests.
final projectCaptureCleanupProvider = Provider<ProjectCaptureCleanup>(
  (ref) => NativeProjectCaptureCleanup(),
);
