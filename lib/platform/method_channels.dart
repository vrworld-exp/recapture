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

/// Aspect ratio for capture; MUST match the preview/analysis FOV.
enum CaptureAspectRatio {
  ratio4x3('4:3'),
  ratio16x9('16:9');

  const CaptureAspectRatio(this.wire);

  /// The string the native side parses (`aspectRatio` arg / reports back).
  final String wire;

  static CaptureAspectRatio fromWire(String? value) =>
      CaptureAspectRatio.values.firstWhere(
        (r) => r.wire == value,
        orElse: () => CaptureAspectRatio.ratio4x3,
      );
}

/// How an unsupported target maps to a supported size (deterministic).
enum CaptureFallbackRule {
  closestHigherThenLower('closest-higher-then-lower'),
  closestLower('closest-lower'),
  exact('none');

  const CaptureFallbackRule(this.wire);

  final String wire;
}

/// Configurable resolution + JPEG-quality policy for captured stills.
///
/// Supply EITHER an exact [targetWidth] + [targetHeight] OR a [targetLongEdge]
/// (with [aspectRatio]); the native side maps the intent to the closest supported
/// size deterministically. The policy is bind-time: it takes effect on the next
/// camera bind (start/rebind), never mid-session.
@immutable
class CaptureResolutionPolicy {
  const CaptureResolutionPolicy({
    this.aspectRatio = CaptureAspectRatio.ratio4x3,
    this.fallbackRule = CaptureFallbackRule.closestHigherThenLower,
    this.jpegQuality = 90,
    this.targetWidth,
    this.targetHeight,
    this.targetLongEdge,
  });

  final CaptureAspectRatio aspectRatio;
  final CaptureFallbackRule fallbackRule;

  /// JPEG encode quality, 1..100. Clamped natively if out of range.
  final int jpegQuality;

  /// Exact target dimensions (supply both, or neither and use [targetLongEdge]).
  final int? targetWidth;
  final int? targetHeight;

  /// Target long edge in px (used when [targetWidth]/[targetHeight] are null).
  final int? targetLongEdge;

  Map<String, dynamic> toMap() => {
        'aspectRatio': aspectRatio.wire,
        'fallbackRule': fallbackRule.wire,
        'jpegQuality': jpegQuality,
        if (targetWidth != null) 'targetWidth': targetWidth,
        if (targetHeight != null) 'targetHeight': targetHeight,
        if (targetLongEdge != null) 'targetLongEdge': targetLongEdge,
      };
}

/// The ACTUAL capture resolution in effect (or the resolved target if not yet
/// bound), reported by [CaptureChannel.getActiveCaptureResolution].
@immutable
class ActiveCaptureResolution {
  const ActiveCaptureResolution({
    required this.width,
    required this.height,
    required this.jpegQuality,
    required this.aspectRatio,
    required this.fellBack,
    required this.bound,
    this.targetWidth,
    this.targetHeight,
    this.targetLongEdge,
  });

  /// Actual chosen output size when [bound]; otherwise the resolved target.
  final int width;
  final int height;
  final int jpegQuality;
  final CaptureAspectRatio aspectRatio;

  /// True if the actual size differs from the requested target.
  final bool fellBack;

  /// True once a session is bound (so [width]/[height] are the real output size).
  final bool bound;

  final int? targetWidth;
  final int? targetHeight;
  final int? targetLongEdge;

  factory ActiveCaptureResolution.fromMap(Map<String, dynamic> map) {
    final target = (map['target'] as Map?)?.cast<String, dynamic>();
    return ActiveCaptureResolution(
      width: (map['width'] as num?)?.toInt() ?? 0,
      height: (map['height'] as num?)?.toInt() ?? 0,
      jpegQuality: (map['jpegQuality'] as num?)?.toInt() ?? 0,
      aspectRatio: CaptureAspectRatio.fromWire(map['aspectRatio'] as String?),
      fellBack: map['fellBack'] as bool? ?? false,
      bound: map['bound'] as bool? ?? false,
      targetWidth: (target?['width'] as num?)?.toInt(),
      targetHeight: (target?['height'] as num?)?.toInt(),
      targetLongEdge: (target?['longEdge'] as num?)?.toInt(),
    );
  }
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

  /// Stages a resolution/JPEG-quality [policy]. Takes effect on the NEXT camera
  /// bind (start/rebind), never mid-session. Returns true if the native side
  /// accepted it; false if it was rejected (invalid args) or unavailable.
  Future<bool> configureCaptureResolution(CaptureResolutionPolicy policy) async {
    try {
      final res = await _channel.invokeMapMethod<String, dynamic>(
        'configureCaptureResolution',
        policy.toMap(),
      );
      return res?['accepted'] as bool? ?? false;
    } on PlatformException {
      // INVALID_ARGS — the prior policy stands.
      return false;
    } on MissingPluginException {
      return false;
    }
  }

  /// Reads the effective capture resolution (actual once bound; else the resolved
  /// target). Returns null when the channel is unavailable (tests / non-Android).
  Future<ActiveCaptureResolution?> getActiveCaptureResolution() async {
    try {
      final res =
          await _channel.invokeMapMethod<String, dynamic>('getActiveCaptureResolution');
      return res == null ? null : ActiveCaptureResolution.fromMap(res);
    } on PlatformException {
      return null;
    } on MissingPluginException {
      return null;
    }
  }

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
