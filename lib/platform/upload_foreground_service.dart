// lib/platform/upload_foreground_service.dart
//
// MethodChannel wrapper for the native Android upload FOREGROUND SERVICE (STUB).
// The upload pipeline calls this so a long upload keeps running while the app is
// backgrounded — Android's background-execution limits would otherwise kill it.
//
// SCOPE: this is the Dart trigger for the foreground-service + notification
// scaffolding. The actual transport is STUBBED on the native side
// (UploadForegroundService.runUploadStub); the pipeline replaces that with the
// real transfer + progress. This wrapper is display/lifecycle only — it performs
// no transfer and holds no progress state.
//
// ANDROID-ONLY: the service exists only in the Android pipeline, so every call is
// a no-op on iOS/web/other targets (iOS has its own background-upload story). All
// invocations are best-effort — a missing plugin / platform error is swallowed so
// the stub can never break the pipeline. Channel: matches
// UploadForegroundService.CHANNEL_NAME.
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../utils/constants.dart';

/// Drives the Android upload foreground service. Inject a [MethodChannel] in tests.
class UploadForegroundServiceClient {
  UploadForegroundServiceClient([MethodChannel? channel])
      : _channel =
            channel ?? const MethodChannel(AppConfig.channelUploadService);

  final MethodChannel _channel;

  /// True only where the native service exists (Android, non-web). Elsewhere every
  /// method short-circuits to a no-op so callers need no platform branch.
  bool get _supported =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  /// Starts (or refreshes) the foreground service + its persistent "uploading"
  /// notification. Call when an upload begins (or the app backgrounds during one).
  /// The pipeline should only call this while an upload is actually active.
  Future<void> start({int done = 0, int total = 0}) =>
      _invoke('startUploadService', {'done': done, 'total': total});

  /// Updates the ongoing notification's progress ("done of total"). No-op natively
  /// if the service is not running. The pipeline wires real byte/file progress here.
  Future<void> updateProgress({required int done, required int total}) =>
      _invoke('updateProgress', {'done': done, 'total': total});

  /// Stops the service + removes the notification. Call on complete/cancel so
  /// nothing lingers. Idempotent — safe to call when already stopped.
  Future<void> stop() => _invoke('stopUploadService');

  /// Schedules the OS-side BACKGROUND auto-resume: a unique WorkManager request
  /// constrained to network-CONNECTED (see UploadResumeWorker), so offline-queued
  /// uploads resume when connectivity returns even if the app is backgrounded or
  /// killed. Re-scheduling REPLACES the pending request (never stacks). The
  /// foreground counterpart is the Dart OfflineUploadQueue — the pipeline calls
  /// this when the app leaves the foreground with queued jobs, and
  /// [cancelNetworkResume] when the queue drains/cancels, so the two never
  /// double-run.
  Future<void> scheduleNetworkResume() => _invoke('scheduleNetworkResume');

  /// Cancels the pending background auto-resume request (queue drained, or the
  /// user cancelled the upload). Idempotent — a no-op when nothing is scheduled.
  Future<void> cancelNetworkResume() => _invoke('cancelNetworkResume');

  /// Whether the upload notification can currently be DISPLAYED (POST_NOTIFICATIONS
  /// granted on API 33+; always true below 33). False on unsupported platforms. The
  /// service RUNS regardless — this only lets the UI surface "notifications off".
  Future<bool> hasNotificationsPermission() async {
    if (!_supported) return false;
    try {
      return await _channel.invokeMethod<bool>('hasNotificationsPermission') ??
          false;
    } on PlatformException {
      return false;
    } on MissingPluginException {
      return false;
    }
  }

  Future<void> _invoke(String method, [Map<String, Object?>? args]) async {
    if (!_supported) return; // no native service off Android → no-op
    try {
      await _channel.invokeMethod<void>(method, args);
    } on PlatformException {
      // Best-effort: a native error must never break the upload pipeline.
    } on MissingPluginException {
      // Channel not registered (e.g. a non-Android host) — ignore.
    }
  }
}
