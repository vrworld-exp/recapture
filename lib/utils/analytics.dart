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

  // ── Level A (Eye Ring) intro ────────────────────────────────────────────────
  // TODO(analytics): mirror these two names + props in the shared server schema
  // (recapture-api/src/validation/analyticsSchemas.ts) and the tracking-plan doc
  // when the analytics destination lands.

  /// The Level A (Eye Ring) intro screen became visible (a REACH metric). Fires
  /// once per screen entry; NOT fired when the screen auto-skips before paint.
  /// Props: { project_id, reduce_motion, device_type }.
  static const String levelAIntroViewed = 'level_a_intro_viewed';

  /// The user left the Level A intro toward capture. Fires once per entry.
  /// Props: { method: begin|skip|auto_skip, dont_show_again, seconds_on_screen }.
  static const String levelAIntroDismissed = 'level_a_intro_dismissed';

  // ── Level A camera preview ──────────────────────────────────────────────────
  // TODO(analytics): mirror these two names + props in the shared server schema
  // (recapture-api/src/validation/analyticsSchemas.ts) and the tracking-plan doc
  // when the analytics destination lands.

  /// The Level A camera preview reached the ready/running state.
  /// Props: { project_id, resolution_preset, device_type }.
  static const String levelACameraOpened = 'level_a_camera_opened';

  /// The Level A camera failed to initialize, was lost at runtime, or its
  /// permission was revoked (detected on resume).
  /// Props: { reason: init_failed|permission_revoked|no_camera, device_type }.
  static const String levelACameraError = 'level_a_camera_error';

  // ── Capture decision pipeline ──────────────────────────────────────────────
  // Exactly ONE of [photoCaptured] / [photoRejectedBlur] / [photoRejectedMotion]
  // fires per capture attempt; [photoWarnedExposure] may fire IN ADDITION to any
  // of them (exposure is warn-only and never gates the capture). The mutual
  // exclusivity is the call site's responsibility — the event layer does not
  // enforce it. The capture accept/reject decision is currently native-driven;
  // these constants + the typed event layer in lib/application/capture/ are the
  // emit contract a future wiring task binds to.

  /// A capture attempt succeeded: a frame was written to disk.
  static const String photoCaptured = 'photo_captured';

  /// A capture attempt was rejected because the frame's sharpness score fell in
  /// the blur REJECT band (below the configured reject threshold).
  static const String photoRejectedBlur = 'photo_rejected_blur';

  /// A capture attempt was rejected because the device was moving (the stability
  /// gate was not open — gyro/linear-accel above the configured thresholds).
  static const String photoRejectedMotion = 'photo_rejected_motion';

  /// The frame's exposure was DARK or BRIGHT at the capture attempt. Fires
  /// independently of (and possibly alongside) the capture/rejection outcome.
  static const String photoWarnedExposure = 'photo_warned_exposure';
}
