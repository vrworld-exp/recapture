// lib/native/capture_events.dart
import '../utils/constants.dart';
import 'event_channel.dart';

/// All event type values sent over the capture-events channel.
enum CaptureEventType {
  screenshotTaken('captureEvents.screenshotTaken'),
  arSessionStart('captureEvents.arSessionStart'),
  arSessionEnd('captureEvents.arSessionEnd'),
  modelInteraction('captureEvents.modelInteraction');

  const CaptureEventType(this.wireValue);

  final String wireValue;

  static CaptureEventType? fromWireValue(String value) {
    for (final t in CaptureEventType.values) {
      if (t.wireValue == value) return t;
    }
    return null;
  }
}

/// Payload emitted for every capture event.
final class CaptureEventPayload {
  const CaptureEventPayload({
    required this.type,
    required this.timestamp,
    this.modelId,
    this.metadata,
  });

  factory CaptureEventPayload.fromMap(dynamic raw) {
    final map = raw as Map<dynamic, dynamic>;
    final wireType = map['type'] as String? ?? '';
    return CaptureEventPayload(
      type: CaptureEventType.fromWireValue(wireType) ??
          CaptureEventType.screenshotTaken,
      timestamp: map['timestamp'] as int,
      modelId: map['modelId'] as String?,
      metadata: (map['metadata'] as Map<dynamic, dynamic>?)
          ?.cast<String, Object?>(),
    );
  }

  final CaptureEventType type;

  /// Epoch milliseconds when the event occurred.
  final int timestamp;

  /// ID of the model involved, if applicable.
  final String? modelId;

  /// Arbitrary additional event metadata.
  final Map<String, Object?>? metadata;
}

/// Typed [NativeEventChannel] for AR/capture lifecycle events.
class CaptureEventsChannel extends NativeEventChannel<CaptureEventPayload> {
  CaptureEventsChannel()
      : super(AppConfig.channelCaptureEvents, CaptureEventPayload.fromMap);
}
