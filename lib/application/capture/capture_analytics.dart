// lib/application/capture/capture_analytics.dart
//
// Thin emitter for the capture-decision analytics events. Dispatches through the
// EXISTING [Analytics.logEvent] seam — NOT a second `AnalyticsSink`/service. That
// seam is already fire-and-forget and exception-safe (a thrown observer is
// swallowed; debug builds echo), so a broken analytics path can never break the
// capture flow. Tests assert emissions via [Analytics.testSink], the established
// pattern for every other client-emitted event in this app.
import 'capture_analytics_event.dart';
import '../../utils/analytics.dart';

/// Emits capture-decision analytics events. Stateless: it neither deduplicates
/// nor enforces mutual exclusivity — exactly one of `photo_captured` /
/// `photo_rejected_blur` / `photo_rejected_motion` per attempt (with an optional
/// `photo_warned_exposure` alongside) is the CALL SITE's responsibility.
abstract final class CaptureAnalytics {
  CaptureAnalytics._();

  /// Dispatches [event] (its canonical name + merged property map) to the
  /// analytics sink. Never throws — [Analytics.logEvent] is exception-safe.
  static void emit(CaptureAnalyticsEvent event) =>
      Analytics.logEvent(event.name, event.toMap());
}
