// lib/platform/method_channels.dart
//
// MethodChannel wrapper for the native still-capture module (CameraX
// ImageCapture). Triggers single / burst / auto-capture on the existing camera
// session; per-frame results stream over the EventChannel in event_channels.dart.
// Channel name: com.mayasabhaxr.recapture/capture
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../utils/constants.dart';

/// A single captured still returned by [CaptureChannel.captureSingle].
@immutable
class CapturedFrame {
  const CapturedFrame({
    required this.id,
    required this.path,
    required this.timestampNs,
  });

  final String id;
  final String path;

  /// Precise capture timestamp in nanoseconds (the image's sensor timestamp),
  /// suitable for later sensor/pose alignment.
  final int timestampNs;

  factory CapturedFrame.fromMap(Map<String, dynamic> map) => CapturedFrame(
        id: map['id'] as String? ?? '',
        path: map['path'] as String? ?? '',
        timestampNs: (map['timestampNs'] as num?)?.toInt() ?? 0,
      );
}

/// Typed Dart API over the native still-capture [MethodChannel].
///
/// All calls degrade gracefully — a missing/unbound session, a busy capturer, a
/// missing plugin (tests / non-Android) resolve without throwing:
/// [captureSingle] returns null, [startBurst]/[startAutoCapture] return null
/// (no session id), and [stopAutoCapture] is a no-op.
class CaptureChannel {
  CaptureChannel([MethodChannel? channel])
      : _channel = channel ?? const MethodChannel(AppConfig.channelCapture);

  final MethodChannel _channel;

  /// Captures one frame; returns it (id/path/timestamp) or null on failure.
  Future<CapturedFrame?> captureSingle() async {
    try {
      final res = await _channel.invokeMapMethod<String, dynamic>('captureSingle');
      return res == null ? null : CapturedFrame.fromMap(res);
    } on PlatformException {
      return null;
    } on MissingPluginException {
      return null;
    }
  }

  /// Starts a burst of [count] frames (optionally with a minimum [intervalMs]
  /// spacing). Frames stream via the capture EventChannel. Returns the session
  /// id ack, or null if rejected (busy / no session / invalid).
  Future<String?> startBurst(int count, {int? intervalMs}) =>
      _start('startBurst', {'count': count, 'intervalMs': intervalMs});

  /// Starts continuous auto-capture until [stopAutoCapture]; frames stream via
  /// the EventChannel. Returns the session id ack, or null if rejected.
  Future<String?> startAutoCapture({int? intervalMs}) =>
      _start('startAutoCapture', {'intervalMs': intervalMs});

  /// Halts an auto-capture (or burst) loop; cancels the in-flight tail.
  Future<void> stopAutoCapture() async {
    try {
      await _channel.invokeMethod<void>('stopAutoCapture');
    } on PlatformException {
      // Best-effort.
    } on MissingPluginException {
      // Nothing native to stop.
    }
  }

  Future<String?> _start(String method, Map<String, dynamic> args) async {
    try {
      final res = await _channel.invokeMapMethod<String, dynamic>(method, args);
      return res?['sessionId'] as String?;
    } on PlatformException {
      // BUSY / NO_CAMERA / INVALID_ARGS.
      return null;
    } on MissingPluginException {
      return null;
    }
  }
}
