// lib/platform/placement_channel.dart
//
// EventChannel wrapper for the native object-placement detector
// (PlacementAnalysisManager: ML Kit stream-mode most-prominent-object over the
// shared camera analysis frames, ~10 Hz). Emits the object's bounding box
// NORMALIZED to the upright image frame — the same 0..1 space as the Dart
// [PlacementBox] guide — as a [PlacementDetection] the pure placement evaluator
// consumes directly. Detection only: no placement decision is made here or
// natively. Channel name: com.mayasabhaxr.recapture/placement.
import 'package:flutter/services.dart';

import '../domain/capture/placement_evaluator.dart' show PlacementDetection;
import '../utils/constants.dart';

/// Streams native placement detections over the [EventChannel].
///
/// "Nothing detected this frame" arrives as [PlacementDetection.none] (an
/// explicit event, so a consumer can settle the guide back to idle). Malformed
/// events are dropped. An unavailable detector (PLACEMENT_UNAVAILABLE, missing
/// plugin on a test host / iOS until ported) surfaces as a stream ERROR — the
/// provider layer maps it to a permanent idle, never a crash.
class PlacementDetectionStream {
  PlacementDetectionStream([EventChannel? channel])
      : _channel = channel ?? const EventChannel(AppConfig.channelPlacement);

  final EventChannel _channel;

  /// Parses a native event map into a [PlacementDetection]; null for an
  /// unknown/malformed shape (dropped upstream).
  static PlacementDetection? fromEvent(Object? event) {
    if (event is! Map) return null;
    final map = event.cast<String, dynamic>();
    final hasObject = map['hasObject'];
    if (hasObject is! bool) return null;
    if (!hasObject) return PlacementDetection.none;
    final left = (map['left'] as num?)?.toDouble();
    final top = (map['top'] as num?)?.toDouble();
    final right = (map['right'] as num?)?.toDouble();
    final bottom = (map['bottom'] as num?)?.toDouble();
    if (left == null || top == null || right == null || bottom == null) {
      return null;
    }
    return PlacementDetection(
      objectNormalized: Rect.fromLTRB(left, top, right, bottom),
      // The stream detector does not classify, so it carries no score; treat a
      // detection as fully confident (the evaluator's floor still applies to
      // sources that do score).
      confidence: (map['confidence'] as num?)?.toDouble() ?? 1,
    );
  }

  /// The live detection stream. Malformed events are filtered; errors (absent
  /// detector / non-device host) are the CALLER's to map to a degraded state.
  Stream<PlacementDetection> detections() => _channel
      .receiveBroadcastStream()
      .map(fromEvent)
      .where((e) => e != null)
      .cast<PlacementDetection>();
}
