// lib/utils/analytics.dart
import 'package:flutter/foundation.dart';

/// Minimal no-op analytics sink.
///
/// TODO(analytics): forward events to a real dispatcher when the analytics
/// layer lands. Until then events are only echoed in debug builds so call
/// sites can be verified without building out a full analytics system.
abstract final class Analytics {
  static void logEvent(
    String name, [
    Map<String, Object?> properties = const {},
  ]) {
    if (kDebugMode) {
      debugPrint('[analytics] $name $properties');
    }
  }
}
