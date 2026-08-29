// lib/platform/capture_ports/still_capture_models.dart
//
// The still-capture value types, moved out of lib/platform/method_channels.dart
// (which re-exports them) so the port interface and both implementations can
// share them without an import cycle. Shapes and wire strings are unchanged.
//
// [CapturedFrame.path] is worth one note: on native it is a real filesystem
// path; on web it is an OPAQUE handle (`idb://{projectId}/{jobId}/{level}/
// {frameId}.jpg`) that only CaptureStoragePort resolves. Nothing between the
// capture and the upload interprets it, which is why the same type serves both.
import 'package:flutter/foundation.dart';

/// A single captured still returned by [StillCapturePort.captureSingle].
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
/// bound), reported by [StillCapturePort.getActiveCaptureResolution].
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
