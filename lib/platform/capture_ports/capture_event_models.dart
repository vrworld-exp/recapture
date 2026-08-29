// lib/platform/capture_ports/capture_event_models.dart
//
// The capture-loop event types, moved out of lib/platform/event_channels.dart
// (which re-exports them) so the port interface and both implementations can
// share them without an import cycle. Shapes and the `type` discriminator are
// unchanged; the web still-capture loop constructs the same events directly.
import 'package:flutter/foundation.dart';

/// An event from the native capture loop. Discriminated by the native `type`.
@immutable
sealed class CaptureEvent {
  const CaptureEvent();

  /// Parses a native event map; returns null for an unknown/malformed shape.
  static CaptureEvent? fromEvent(Object? event) {
    if (event is! Map) return null;
    final map = event.cast<String, dynamic>();
    switch (map['type']) {
      case 'frame':
        return CaptureFrameEvent(
          id: map['id'] as String? ?? '',
          path: map['path'] as String? ?? '',
          timestampNs: (map['timestampNs'] as num?)?.toInt() ?? 0,
          index: (map['index'] as num?)?.toInt() ?? 0,
          total: (map['total'] as num?)?.toInt(),
        );
      case 'completed':
        return CaptureCompletedEvent(
          count: (map['count'] as num?)?.toInt() ?? 0,
          sessionId: map['sessionId'] as String? ?? '',
        );
      case 'error':
        return CaptureErrorEvent(
          index: (map['index'] as num?)?.toInt(),
          message: map['message'] as String? ?? 'Capture error.',
        );
      case 'metadata':
        return CaptureMetadataEvent(
          frameId: map['frameId'] as String? ?? '',
          index: (map['index'] as num?)?.toInt(),
          jpegPath: map['jpegPath'] as String? ?? '',
          sidecarPath: map['sidecarPath'] as String? ?? '',
          exifOk: map['exifOk'] as bool? ?? false,
          sidecarOk: map['sidecarOk'] as bool? ?? false,
          error: map['error'] as String?,
        );
      default:
        return null;
    }
  }
}

/// One captured frame in a burst/auto run. [total] is null for auto-capture.
@immutable
class CaptureFrameEvent extends CaptureEvent {
  const CaptureFrameEvent({
    required this.id,
    required this.path,
    required this.timestampNs,
    required this.index,
    this.total,
  });

  final String id;
  final String path;
  final int timestampNs;
  final int index;
  final int? total;
}

/// The loop finished (completed, stopped, or session ended). [count] is the
/// number of frames actually produced.
@immutable
class CaptureCompletedEvent extends CaptureEvent {
  const CaptureCompletedEvent({required this.count, required this.sessionId});

  final int count;
  final String sessionId;
}

/// A per-frame failure. The loop continues, marking the gap at [index].
@immutable
class CaptureErrorEvent extends CaptureEvent {
  const CaptureErrorEvent({this.index, required this.message});

  final int? index;
  final String message;
}

/// Result of the per-frame post-capture metadata step (EXIF normalization + JSON
/// sidecar). Emitted asynchronously, possibly slightly behind the frame event,
/// since metadata I/O runs off the capture cadence. [error] is non-null if EXIF
/// or the sidecar failed (the JPEG is never corrupted — see the native writer).
@immutable
class CaptureMetadataEvent extends CaptureEvent {
  const CaptureMetadataEvent({
    required this.frameId,
    required this.index,
    required this.jpegPath,
    required this.sidecarPath,
    required this.exifOk,
    required this.sidecarOk,
    this.error,
  });

  final String frameId;
  final int? index;
  final String jpegPath;

  /// Path to the `<frame>.json` sidecar (precise timestamp, device, resolution…).
  final String sidecarPath;

  /// Whether interop EXIF was normalized onto the JPEG.
  final bool exifOk;

  /// Whether the JSON sidecar was written.
  final bool sidecarOk;

  /// Non-null when EXIF and/or sidecar writing failed (the frame is flagged, not
  /// silently dropped).
  final String? error;
}
