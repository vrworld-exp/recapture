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

  /// Selection click — fired when the shutter is tapped to start a capture.
  static Future<void> captureTap() => _safe(HapticFeedback.selectionClick);

  /// Medium impact — fired on a successful capture.
  static Future<void> captureSuccess() => _safe(HapticFeedback.mediumImpact);

  /// Heavy impact — fired when a capture fails.
  static Future<void> captureError() => _safe(HapticFeedback.heavyImpact);

  /// Light selection click — fired when a blocked shutter is tapped.
  static Future<void> blockedTap() => _safe(HapticFeedback.selectionClick);

  /// Light impact — fired when a post-shot toast reports an ACCEPTED capture.
  static Future<void> postShotAccepted() => _safe(HapticFeedback.lightImpact);

  /// Selection click — fired when a post-shot toast reports a WARN capture.
  static Future<void> postShotWarning() => _safe(HapticFeedback.selectionClick);

  /// Heavy impact — fired when a post-shot toast reports a REJECTED capture.
  static Future<void> postShotReject() => _safe(HapticFeedback.heavyImpact);

  static Future<void> _safe(Future<void> Function() action) async {
    try {
      await action();
    } catch (_) {
      // No haptic support on this device/platform — ignore.
    }
  }
}
