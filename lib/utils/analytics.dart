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
  // ── Capture level lifecycle (canonical funnel — Levels A/B/C) ───────────────
  // The single, `level`-parameterized source of truth for the capture funnel.
  // Emitted via the typed event layer (lib/application/capture/analytics/), never
  // as hand-assembled maps. These SUPERSEDE the earlier ad-hoc level-specific
  // names (`level_a_completed` → [captureLevelCompleted], `retake_started` →
  // [captureLevelRetake]); the granular UI events below stay as-is.
  // TODO(analytics): mirror these three names + props in the shared server schema
  // (recapture-api/src/validation/analyticsSchemas.ts) + the tracking-plan doc
  // when the analytics destination lands.

  /// Guided capture for a level began (once per capture session). Props:
  /// { level, project_id, session_id, capture_mode, target_segments,
  ///   sensor_supported, device_type }.
  static const String captureLevelStarted = 'capture_level_started';

  /// A level met its completion criteria (once per session completion). Props:
  /// { level, project_id, session_id, accepted, target, rejected, coverage_pct,
  ///   duration_seconds, device_type }.
  static const String captureLevelCompleted = 'capture_level_completed';

  /// A retake was initiated for a segment (once per initiation). Props:
  /// { level, project_id, session_id, ring_index, replacing_existing,
  ///   return_mode, device_type }.
  static const String captureLevelRetake = 'capture_level_retake';

  /// A ring segment transitioned unfilled→filled (once per transition; NOT on
  /// overfill, and threshold-aware — fires when the count reaches fillThreshold).
  /// Props: { level, project_id, session_id, segment_index, segment_count,
  ///   capture_mode, device_type }.
  static const String segmentFilled = 'segment_filled';

  /// Ring coverage first crossed a milestone (once per 25/50/75/100% crossing).
  /// Raw coverage — DISTINCT from the Level A completion gate (minCoveragePct +
  /// min accepted count). Props: { level, project_id, session_id, milestone,
  ///   filled_count, segment_count, device_type }.
  static const String coverageMilestone = 'coverage_milestone';

  /// A user tap INITIATED a capture (trigger time, before acceptance; once per
  /// non-blocked tap). NOT on blocked taps ([levelABlockedShutterTap] covers
  /// those). Props: { level, project_id, session_id, attempt_number, ring_index,
  ///   in_band, stable, sensor_supported, was_blocked_override, device_type }.
  static const String manualCaptureTriggered = 'manual_capture_triggered';

  /// The auto-capture loop INITIATED a capture (once per auto-fired shot). Mutually
  /// exclusive with [manualCaptureTriggered] for one physical capture; shares the
  /// session `attempt_number`. Props: { level, project_id, session_id,
  ///   attempt_number, ring_index, in_band, stable, sensor_supported, device_type }.
  static const String autocaptureTriggered = 'autocapture_triggered';

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

  // ── Level A tilt meter ─────────────────────────────────────────────────────
  // TODO(analytics): mirror this name + props in the shared server schema
  // (recapture-api/src/validation/analyticsSchemas.ts) and the tracking-plan doc
  // when the analytics destination lands.

  /// The user held the device OUT of the target pitch band for a sustained
  /// period during Level A capture. Throttled (max ~once per few seconds), never
  /// emitted per frame. Props: { direction: above|below, target_band_id,
  /// device_type }.
  static const String tiltMeterOutOfBand = 'tilt_meter_out_of_band';

  /// The device stayed UNSTABLE (the native stability gate held un-calm) for a
  /// sustained period during Level A capture — the "Hold steady" guidance was
  /// shown long enough to matter. Throttled (once per unstable stretch), never
  /// per frame. Props: { device_type }.
  static const String captureHoldSteady = 'capture_hold_steady';

  // ── Level A shutter ────────────────────────────────────────────────────────

  /// A shutter capture attempt resolved. Props: { result: success|error, mode:
  /// guided|manual, sensor_supported: bool, device_type }.
  static const String levelACaptureTriggered = 'level_a_capture_triggered';

  /// The user tapped the shutter while it was blocked. Throttled. Props:
  /// { reason: out_of_band|unstable|not_placed }.
  static const String levelABlockedShutterTap = 'level_a_blocked_shutter_tap';

  /// The user toggled the Level A auto-capture mode. Props: { new_state: on|off,
  /// device_type }. (Auto-capture FIRE analytics belong with the auto-capture
  /// logic task, not the indicator pill.)
  static const String autoCaptureToggled = 'auto_capture_toggled';

  /// The user tapped a recent-capture thumbnail in the Level A strip. Props:
  /// { capture_id, device_type }.
  static const String thumbnailTapped = 'thumbnail_tapped';

  // ── Capture top bar ────────────────────────────────────────────────────────
  // TODO(analytics): mirror this name + props in the shared server schema
  // (recapture-api/src/validation/analyticsSchemas.ts) and the tracking-plan doc
  // when the analytics destination lands.

  /// A capture top-bar control was tapped. Debounced upstream so a single open
  /// intent is emitted. Props: { action: back|help|settings, level, device_type }.
  static const String captureTopbarAction = 'capture_topbar_action';

  // ── Post-shot toast ────────────────────────────────────────────────────────
  // TODO(analytics): mirror these names + props in the shared server schema
  // (recapture-api/src/validation/analyticsSchemas.ts) and the tracking-plan doc
  // when the analytics destination lands.

  /// A post-shot feedback toast was shown for a capture (fires once per shot —
  /// identical re-emits are suppressed upstream). Props: { verdict:
  /// accepted|warn|reject, issues: string[], device_type }.
  static const String postShotResult = 'post_shot_result';

  /// The user tapped Retake on a warn/reject toast. Debounced to a single fire.
  /// Props: { verdict: warn|reject, capture_id }.
  static const String postShotRetake = 'post_shot_retake';

  // ── Level A help sheet ─────────────────────────────────────────────────────
  // TODO(analytics): mirror these names + props in the shared server schema
  // (recapture-api/src/validation/analyticsSchemas.ts) and the tracking-plan doc
  // when the analytics destination lands.

  /// The Level A Help sheet (quick tips) was shown. Props: { device_type }.
  static const String levelAHelpOpened = 'level_a_help_opened';

  /// A Help-sheet footer action was tapped. Props: { action: replay_intro|close }.
  static const String levelAHelpAction = 'level_a_help_action';

  // ── Level A settings sheet ─────────────────────────────────────────────────
  // TODO(analytics): mirror this name + props in the shared server schema
  // (recapture-api/src/validation/analyticsSchemas.ts) and the tracking-plan doc
  // when the analytics destination lands.

  /// A capture setting was toggled/selected in the Settings sheet. Props:
  /// { setting: auto_capture|save_to_gallery|quality_mode,
  ///   value: on|off|standard|high, device_type }.
  static const String captureSettingChanged = 'capture_setting_changed';

  // ── Level A save & exit ────────────────────────────────────────────────────
  // TODO(analytics): mirror these names + props in the shared server schema
  // (recapture-api/src/validation/analyticsSchemas.ts) and the tracking-plan doc
  // when the analytics destination lands.

  /// The Save & Exit confirmation modal was shown (unsaved progress on leave).
  /// Props: { captured_count, device_type }.
  static const String saveExitPromptShown = 'save_exit_prompt_shown';

  /// The user resolved the Save & Exit modal (including dismissal-as-cancel).
  /// Props: { choice: save_exit|discard_exit|cancel, captured_count }.
  static const String saveExitChoice = 'save_exit_choice';

  // ── Level A completion ─────────────────────────────────────────────────────
  // NOTE: the completion lifecycle event is the canonical [captureLevelCompleted]
  // (`capture_level_completed`) above — the former `level_a_completed` was
  // reconciled into it. The CTA-tap event below stays granular.
  // TODO(analytics): mirror this name + props in the shared server schema
  // (recapture-api/src/validation/analyticsSchemas.ts) and the tracking-plan doc
  // when the analytics destination lands.

  /// A completion-screen CTA was tapped (debounced to one). Props:
  /// { action: start_level_b|review|done_exit }.
  static const String levelACompleteAction = 'level_a_complete_action';

  // ── Level A review grid (Screen 7A) ────────────────────────────────────────
  // TODO(analytics): mirror these names + props in the shared server schema
  // (recapture-api/src/validation/analyticsSchemas.ts) and the tracking-plan doc
  // when the analytics destination lands.

  /// The Level A review grid was shown. Fires once per screen entry. Props:
  /// { total, accepted, warned, rejected, device_type }.
  static const String reviewGridViewed = 'review_grid_viewed';

  /// The user tapped a review-grid tile. Props:
  /// { capture_id, verdict: accepted|warn|reject }.
  static const String reviewTileTapped = 'review_tile_tapped';

  // ── Level A retake (Review → Capture) ──────────────────────────────────────
  // NOTE: retake INITIATION is the canonical lifecycle event [captureLevelRetake]
  // (`capture_level_retake`) above — the former `retake_started` was reconciled
  // into it. The acceptance event below stays granular.
  // TODO(analytics): mirror this name + props in the shared server schema
  // (recapture-api/src/validation/analyticsSchemas.ts) and the tracking-plan doc
  // when the analytics destination lands.

  /// A retake capture was accepted — the targeted segment was filled/replaced.
  /// Props: { ring_index, new_verdict: accepted|warn, device_type }.
  static const String retakeCompleted = 'retake_completed';

  // ── Level A guidance engine ────────────────────────────────────────────────
  // TODO(analytics): mirror this name + props in the shared server schema
  // (recapture-api/src/validation/analyticsSchemas.ts) and the tracking-plan doc
  // when the analytics destination lands.

  /// The committed (post-dwell) active HUD instruction changed. Throttled — fires
  /// only on a real instruction-id change, never per tick. Props:
  /// { instruction: tilt|stability|direction|capture|capture-next|complete,
  ///   sensor_supported, device_type }.
  static const String guidanceInstructionChanged = 'guidance_instruction_changed';
}
