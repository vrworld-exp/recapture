// lib/platform/upload_background_session.dart
//
// Dart client for the native iOS BACKGROUND upload transport (URLSession with a
// background configuration — see ios/Runner/BackgroundUploadManager.swift). An
// enqueued upload keeps transferring while the app is suspended or killed; the
// OS relaunches the app to deliver the outcome, which the native side BUFFERS
// until [events] is subscribed — so a background completion is never lost.
//
// iOS-ONLY: the background session exists only in the iOS host, so [enqueueUpload]
// is a no-op and [events] is an empty stream on other targets (Android's
// counterpart is the foreground service + WorkManager pair). Channel names:
// AppConfig.channelUploadEngine / AppConfig.channelUploadEvents.
//
// SCOPE: this is the thin transport trigger + typed event decoding. It performs
// no queueing/retry itself — the OfflineUploadQueue / upload pipeline composes
// it. Enqueue validation errors surface as [PlatformException] with stable codes
// (INVALID_ARGS / BAD_URL / FILE_NOT_FOUND) so the caller can react; the event
// stream's `errorDescription` is DIAGNOSTIC ONLY (feed the shared
// classifyUploadFailure/category mapping — never show it raw, the 9F privacy
// invariant).
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../utils/constants.dart';

/// One typed event off the native upload_events channel. Unknown/garbled
/// payloads decode to null and are dropped by the stream (tolerant contract).
sealed class BackgroundUploadEvent {
  const BackgroundUploadEvent(this.taskId);

  /// The caller-supplied job id (`taskID` on the wire) — stable across app
  /// relaunches, unlike the session-scoped native task identifier.
  final String taskId;

  static BackgroundUploadEvent? fromPayload(Object? raw) {
    if (raw is! Map) return null;
    final taskId = raw['taskID'];
    if (taskId is! String) return null;
    switch (raw['type']) {
      case 'progress':
        return BackgroundUploadProgress(
          taskId,
          bytesSent: (raw['bytesSent'] as num?)?.toInt() ?? 0,
          totalBytes: (raw['totalBytes'] as num?)?.toInt() ?? -1,
          progress: (raw['progress'] as num?)?.toDouble() ?? -1.0,
        );
      case 'success':
        return BackgroundUploadSuccess(
          taskId,
          statusCode: (raw['statusCode'] as num?)?.toInt() ?? -1,
          localPath: raw['localPath'] as String? ?? '',
          completedAt: raw['completedAt'] as String? ?? '',
        );
      case 'failure':
        return BackgroundUploadFailure(
          taskId,
          errorCode: (raw['errorCode'] as num?)?.toInt() ?? 0,
          errorDescription: raw['errorDescription'] as String? ?? '',
          retryRecommended: raw['retryRecommended'] as bool? ?? false,
        );
      default:
        return null; // unknown type from a newer/older native side → dropped
    }
  }
}

/// Transfer progress. [progress] is -1 when the total is unknown (no
/// Content-Length) — render indeterminate, don't divide.
class BackgroundUploadProgress extends BackgroundUploadEvent {
  const BackgroundUploadProgress(
    super.taskId, {
    required this.bytesSent,
    required this.totalBytes,
    required this.progress,
  });

  final int bytesSent;
  final int totalBytes;
  final double progress;

  bool get isIndeterminate => progress < 0;
}

/// Transport-level success. [statusCode] still needs classification (a 4xx/5xx
/// response completes the TRANSFER successfully) — the pipeline judges it.
class BackgroundUploadSuccess extends BackgroundUploadEvent {
  const BackgroundUploadSuccess(
    super.taskId, {
    required this.statusCode,
    required this.localPath,
    required this.completedAt,
  });

  final int statusCode;
  final String localPath;

  /// ISO8601 completion timestamp stamped natively.
  final String completedAt;
}

/// Transport failure (or cancellation). [errorDescription] is diagnostics for
/// the classifier — never user-facing copy. [retryRecommended] mirrors the
/// native transient-network judgment (false for cancellation).
class BackgroundUploadFailure extends BackgroundUploadEvent {
  const BackgroundUploadFailure(
    super.taskId, {
    required this.errorCode,
    required this.errorDescription,
    required this.retryRecommended,
  });

  final int errorCode;
  final String errorDescription;
  final bool retryRecommended;
}

/// Drives the iOS background upload session. Inject channels in tests.
class UploadBackgroundSessionClient {
  UploadBackgroundSessionClient({MethodChannel? channel, EventChannel? events})
      : _channel = channel ?? const MethodChannel(AppConfig.channelUploadEngine),
        _events = events ?? const EventChannel(AppConfig.channelUploadEvents);

  final MethodChannel _channel;
  final EventChannel _events;

  /// True only where the native background session exists (iOS, non-web).
  /// Elsewhere every method short-circuits so callers need no platform branch.
  bool get _supported => !kIsWeb && defaultTargetPlatform == TargetPlatform.iOS;

  /// Enqueues one background PUT of the file at [localPath] to [uploadUrl].
  /// Resolves when the task is handed to the OS (NOT when the upload finishes —
  /// watch [events] for that). Validation failures throw [PlatformException]
  /// with code INVALID_ARGS / BAD_URL / FILE_NOT_FOUND before any task is
  /// created. No-op off iOS.
  Future<void> enqueueUpload({
    required String taskId,
    required String localPath,
    required String uploadUrl,
    Map<String, String> headers = const {},
  }) async {
    if (!_supported) return;
    await _channel.invokeMethod<void>('enqueueUpload', {
      'taskID': taskId,
      'localPath': localPath,
      'uploadURL': uploadUrl,
      'headers': headers,
    });
  }

  /// The typed progress/success/failure stream for ALL enqueued uploads
  /// (correlate by [BackgroundUploadEvent.taskId]). Events fired while the app
  /// was relaunched in the background are buffered natively and delivered on
  /// subscribe. Unknown payload shapes are dropped, never thrown. Empty stream
  /// off iOS.
  Stream<BackgroundUploadEvent> events() {
    if (!_supported) return const Stream<BackgroundUploadEvent>.empty();
    return _events
        .receiveBroadcastStream()
        .map(BackgroundUploadEvent.fromPayload)
        .where((e) => e != null)
        .cast<BackgroundUploadEvent>();
  }
}
