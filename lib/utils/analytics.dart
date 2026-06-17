// lib/utils/analytics.dart
import 'package:flutter/foundation.dart';

/// Minimal no-op analytics sink.
///
/// TODO(analytics): forward events to a real dispatcher when the analytics
/// layer lands. Until then events are only echoed in debug builds so call
/// sites can be verified without building out a full analytics system.
///
/// The canonical event-name + property contract lives server-side in
/// `recapture-api/src/validation/analyticsSchemas.ts` (mirrored in
/// docs/analytics-tracking-plan.md). Client-emitted events validate against that
/// shared schema and send directly to the destination — there is no backend
/// ingest endpoint. [AnalyticsEvents] holds the client-side name constants so
/// call sites never scatter raw string literals.
abstract final class Analytics {
  /// Test seam: when set, every [logEvent] call is forwarded here so tests can
  /// assert emissions. Production leaves it null (debug echo only). Reset it in
  /// `tearDown`.
  @visibleForTesting
  static void Function(String name, Map<String, Object?> properties)? testSink;

  static void logEvent(
    String name, [
    Map<String, Object?> properties = const {},
  ]) {
    // Fire-and-forget: never let an analytics observer break a call site.
    try {
      testSink?.call(name, properties);
    } catch (_) {
      // Swallow — analytics must not affect app behavior.
    }
    if (kDebugMode) {
      debugPrint('[analytics] $name $properties');
    }
  }
}

/// Canonical client-emitted event names. Mirrors the server `AnalyticsEvent`
/// const; keep the string values identical to the shared schema.
abstract final class AnalyticsEvents {
  /// Camera (required) transitioned to granted (via prompt or settings return).
  static const String permissionCameraGranted = 'permission_camera_granted';

  /// Motion (recommended) transitioned to granted.
  static const String permissionMotionGranted = 'permission_motion_granted';

  /// A permission transitioned to a non-granted state (request resolved
  /// non-granted, or a granted→denied revocation detected on resume).
  static const String permissionDenied = 'permission_denied';

  /// The pre-capture checklist (Screen 4) was entered — a REACH metric. Fires
  /// once per screen entry, never on rebuilds (and not on the Start CTA, which
  /// would be a separate conversion event).
  static const String precaptureChecklistStarted = 'precapture_checklist_started';

  /// A checklist item's tip surface (bottom sheet / popover) was opened. Carries
  /// the item id; fires once per genuine open (the tip surface guards stacking).
  static const String precaptureTipOpened = 'precapture_tip_opened';
}
