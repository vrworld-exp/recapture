// lib/platform/event_channels.dart
//
// EventChannel wrapper for the native still-capture progress stream (burst /
// auto-capture). Emits per-frame, completion, and error events.
// Channel name: com.mayasabhaxr.recapture/captureEvents
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../utils/constants.dart';

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

/// Streams native capture events. Unknown/malformed events are filtered out.
class CaptureEvents {
  CaptureEvents([EventChannel? channel])
      : _channel = channel ?? const EventChannel(AppConfig.channelCaptureEvents);

  final EventChannel _channel;

  Stream<CaptureEvent> stream() => _channel
      .receiveBroadcastStream()
      .map(CaptureEvent.fromEvent)
      .where((e) => e != null)
      .cast<CaptureEvent>();
}
