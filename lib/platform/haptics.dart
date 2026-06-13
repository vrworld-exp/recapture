// lib/platform/haptics.dart
import 'package:flutter/services.dart';

/// Wraps [HapticFeedback] so the UI never calls it directly.
///
/// Every call is guarded — devices without a haptic motor (some Android
/// phones, iPads) silently no-op instead of throwing.
abstract final class Haptics {
  /// Medium impact — fired when a blocking modal appears.
  static Future<void> appeared() => _safe(HapticFeedback.mediumImpact);

  /// Selection click — fired on a Retry / confirm tap.
  static Future<void> retryTapped() => _safe(HapticFeedback.selectionClick);

  /// Heavy impact — fired when an action fails.
  static Future<void> failed() => _safe(HapticFeedback.heavyImpact);

  static Future<void> _safe(Future<void> Function() action) async {
    try {
      await action();
    } catch (_) {
      // No haptic support on this device/platform — ignore.
    }
  }
}
