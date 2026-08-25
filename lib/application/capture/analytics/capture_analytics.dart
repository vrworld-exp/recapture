// lib/application/capture/analytics/capture_analytics.dart
//
// The thin emit helper for the typed capture-level lifecycle events: it forwards
// a [CaptureLevelEvent] to the existing `Analytics` dispatcher so call sites pass
// a typed event, never a hand-assembled name+map. `Analytics.logEvent` is already
// fire-and-forget and swallows observer errors, so a logging failure can never
// crash or block the capture flow.
import '../../../utils/analytics.dart';
import 'capture_level_events.dart';

abstract final class CaptureAnalytics {
  /// Forwards [event].name + [event].properties to the dispatcher. Guarded
  /// (the underlying [Analytics.logEvent] never throws to the caller).
  static void log(CaptureLevelEvent event) =>
      Analytics.logEvent(event.name, event.properties);
}
