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

  /// The user changed the "can you capture the bottom?" answer on the
  /// pre-capture checklist — the input that selects the capture FLOW VARIANT
  /// (with_bottom 3-ring 16-16-16 vs without_bottom 2-ring 24-24). Fires on
  /// TRANSITION only (never on re-selecting the current value or on rebuilds).
  /// Props: { flow_variant, device_type }.
  static const String bottomCaptureOptionSelected =
      'bottom_capture_option_selected';

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

  // ── Level B (Top Ring) intro ────────────────────────────────────────────────
  // Granular per-level intro events, mirroring the Level A pair above (kept
  // granular alongside the canonical `capture_level_*` funnel).
  // TODO(analytics): mirror these two names + props in the shared server schema
  // (recapture-api/src/validation/analyticsSchemas.ts) and the tracking-plan doc
  // when the analytics destination lands.

  /// The Level B (Top Ring) intro screen became visible (a REACH metric). Fires
  /// once per screen entry; NOT fired when the screen auto-skips before paint.
  /// Props: { project_id, reduce_motion, device_type }.
  static const String levelBIntroViewed = 'level_b_intro_viewed';

  /// The user left the Level B intro toward capture. Fires once per entry.
  /// Props: { method: begin|skip|auto_skip, dont_show_again, seconds_on_screen }.
  static const String levelBIntroDismissed = 'level_b_intro_dismissed';

  // ── Level C (Low Ring) intro ────────────────────────────────────────────────
  // Granular per-level intro events, mirroring the Level A/B pairs above (kept
  // granular alongside the canonical `capture_level_*` funnel).
  // TODO(analytics): mirror these two names + props in the shared server schema
  // (recapture-api/src/validation/analyticsSchemas.ts) and the tracking-plan doc
  // when the analytics destination lands.

  /// The Level C (Low Ring) intro screen became visible (a REACH metric). Fires
  /// once per screen entry; NOT fired when the screen auto-skips before paint.
  /// Props: { project_id, reduce_motion, device_type }.
  static const String levelCIntroViewed = 'level_c_intro_viewed';

  /// The user left the Level C intro toward capture. Fires once per entry.
  /// Props: { method: begin|skip|auto_skip, dont_show_again, seconds_on_screen }.
  static const String levelCIntroDismissed = 'level_c_intro_dismissed';

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

  // ── Guided Capture roll constraint (Levels B & C) ──────────────────────────
  // TODO(analytics): mirror this name + props in the shared server schema
  // (recapture-api/src/validation/analyticsSchemas.ts) and the tracking-plan doc
  // when the analytics destination lands.

  /// The roll advisory ("Keep the phone level") was raised during Guided Capture
  /// (Level B/C) — the device rolled past ±15° off level. Fires on the RISING
  /// EDGE only (inactive→active), never per frame while roll stays out of
  /// tolerance. Advisory only — capture is never blocked. Props:
  /// { level: B|C, capture_session_id, roll_degrees (signed), device_type }.
  static const String guidedCaptureRollWarningShown =
      'guided_capture_roll_warning_shown';

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

  /// A generic per-level completion-screen CTA was tapped (Levels B & C; the
  /// Level A screen uses [levelACompleteAction]). Debounced to one. Props:
  /// { action: start_next|review, level, device_type }.
  static const String levelCompleteAction = 'level_complete_action';

  // ── Level A review grid (Screen 7A) ────────────────────────────────────────
  // TODO(analytics): mirror these names + props in the shared server schema
  // (recapture-api/src/validation/analyticsSchemas.ts) and the tracking-plan doc
  // when the analytics destination lands.

  /// The review grid was shown. Fires once per screen entry. Props:
  /// { level?, total, accepted, warned, rejected, device_type }. `level` (A/B/C)
  /// is carried by the level-aware flow review screen (Eye/Top/Bottom Ring); the
  /// reusable display grid omits it (it has only a title, not a level).
  static const String reviewGridViewed = 'review_grid_viewed';

  /// A review-screen action was tapped — the level-tagged counterpart of the
  /// completion screen's [levelACompleteAction], for the in-flow review screen's
  /// CTAs. Props: { action: proceed|back_to_capture|retake, level, frame_id?,
  /// device_type }. `frame_id` is carried only for `retake` (the captured frame's
  /// stable path id that the retake re-shoots).
  static const String reviewAction = 'review_action';

  /// The user tapped a review-grid tile. Props:
  /// { capture_id, verdict: accepted|warn|reject }.
  static const String reviewTileTapped = 'review_tile_tapped';

  // ── Capture complete summary (Screen 6C-Complete) ──────────────────────────
  // The terminal post-all-levels summary. Repo-style names (capture_*, NOT the
  // brief's `guided_capture_complete_*` — the same remap precedent that kept
  // level_b_intro_* over `guided_capture_*`); the `phase: guided_capture` semantic
  // is preserved as a property.
  // TODO(analytics): mirror these names + props in the shared server schema
  // (recapture-api/src/validation/analyticsSchemas.ts) + the tracking-plan doc.

  /// The Capture complete summary became visible (once per entry). Props:
  /// { phase: guided_capture, session_id, levels_complete, levels_total,
  ///   device_type }.
  static const String captureSummaryViewed = 'capture_summary_viewed';

  /// A Capture summary secondary CTA was tapped. Props: { phase: guided_capture,
  /// session_id, action: fix_issues|save_for_later|review,
  /// target_level? (fix_issues — the most-work level routed to),
  /// level? (per-card review), device_type }. The PRIMARY Upload CTA emits the
  /// dedicated [captureSummaryProceedToUpload] instead.
  static const String captureSummaryAction = 'capture_summary_action';

  /// The aggregated warnings list on the Capture Summary was expanded. Fires on
  /// each collapsed→expanded transition (never on collapse). Props:
  /// { phase: guided_capture, session_id, warning_count, device_type }.
  /// NAMING: the brief lists `capture_session_id` / `device_type: mobile`; this
  /// funnel uses `session_id` + android/ios so the event joins the rest of the
  /// capture funnel (same remap precedent as the events above).
  static const String captureSummaryWarningsExpanded =
      'capture_summary_warnings_expanded';

  /// The proceed-to-upload CTA was tapped on the Capture Summary (once per entry —
  /// double-tap guarded). The funnel counterpart to the granular
  /// [captureSummaryAction]; fires AFTER any below-min confirmation is accepted.
  /// Props: { phase: guided_capture, session_id, any_level_below_min, device_type }.
  static const String captureSummaryProceedToUpload =
      'capture_summary_proceed_to_upload';

  // ── Capture Summary offline banner (connectivity-reactive) ──────────────────
  // The Summary step's next action is upload, which is impossible offline. These
  // fire off the CENTRALIZED connectivity source (isOnlineProvider), debounced so
  // flapping doesn't re-fire. NAMING: the brief lists `capture_session_id` /
  // `device_type: mobile`; this funnel uses `session_id` + android/ios (same remap
  // precedent as the other summary events) so they join the capture funnel.
  // TODO(analytics): mirror these two names + props in the shared server schema
  // (recapture-api/src/validation/analyticsSchemas.ts) + the tracking-plan doc.

  /// The offline banner transitioned hidden→shown (rising edge only, NOT per
  /// rebuild). Props: { session_id, phase: guided_capture, device_type }.
  static const String captureSummaryOfflineBannerShown =
      'capture_summary_offline_banner_shown';

  /// The user tapped Upload while offline and was blocked (the CTA allows the tap
  /// then blocks; a guaranteed-to-fail upload is never navigated into). Props:
  /// { session_id, phase: guided_capture, device_type }.
  static const String captureSummaryProceedBlockedOffline =
      'capture_summary_proceed_blocked_offline';

  // ── Upload hard gate (absolute-minimum accepted shots per level) ────────────
  // The HARD floor that disables Upload when any level has fewer accepted shots
  // than its absolute minimum (config `guided_capture_min_accepted_shots`) —
  // distinct from the soft completion gate. TODO(analytics): mirror these three
  // names + props in the shared server schema + tracking-plan doc.

  /// An upload was blocked by the hard gate — emitted when the Upload control is
  /// first shown disabled in a session view AND when a blocked attempt is refused
  /// at the handler. Props: { session_id, phase: upload, short_levels
  /// (comma-separated level ids), total_deficit, device_type }.
  static const String uploadGateBlocked = 'upload_gate_blocked';

  /// The hard upload gate transitioned not-eligible→eligible (every level met its
  /// absolute minimum) for a session. Fires ONCE per transition, not per
  /// evaluation. Props: { session_id, phase: upload, device_type }.
  static const String uploadGatePassed = 'upload_gate_passed';

  /// Upload actually started (the gate was eligible and the handler proceeded).
  /// Props: { session_id, phase: upload, device_type }.
  static const String uploadInitiated = 'upload_initiated';

  // ── Bundle packer (pre-upload staging) — pack DIAGNOSTICS ───────────────────
  // Emitted by the bundle packer (lib/application/upload/capture_bundle_packer.dart)
  // as it stages accepted images into the /images/{EYE|TOP|LOW}/ + capture_manifest
  // .json bundle the uploader consumes. These are diagnostics (not user-interaction
  // analytics) so the upload flow — and Screen 9F's failure mapping — can categorize
  // PRE-upload failures. `session_id` + android/ios, matching the upload funnel.
  // TODO(analytics): mirror these three names + props in the shared server schema
  // (recapture-api/src/validation/analyticsSchemas.ts) + the tracking-plan doc.

  /// A bundle pack began. Props: { session_id, phase: upload, total_images,
  ///   eye_count, top_count, low_count, device_type }.
  static const String bundlePackStarted = 'bundle_pack_started';

  /// A bundle pack completed and a verified bundle was finalized. Props:
  /// { session_id, phase: upload, total_images, total_bytes, duration_ms,
  ///   device_type }.
  static const String bundlePackSucceeded = 'bundle_pack_succeeded';

  /// A bundle pack failed or was cancelled (no bundle released). Props:
  /// { session_id, phase: upload, reason (missing_source_file|insufficient_storage|
  ///   encode_error|integrity_mismatch|cancelled|unknown), stage, device_type }.
  static const String bundlePackFailed = 'bundle_pack_failed';

  // ── Upload lifecycle (canonical session funnel) — ENGINE transitions ────────
  // THE canonical upload funnel. Emitted by ChunkedUploadManager._setStatus —
  // the engine's single status-transition point — once per genuine EDGE, never
  // per rebuild, part, or progress poll. These own the bare names; the view/tap
  // events are suffixed (_view / _tapped) so one real-world transition never
  // emits two events of the same name. A user CANCEL is deliberately NOT a
  // lifecycle failure: it emits no lifecycle event ([uploadCancelled] carries
  // the tap intent; [uploadMultipartAborted] reason:cancelled the mechanics).
  // `capture_session_id` + device_type "mobile", matching the rest of the
  // engine telemetry so all five join one funnel.
  // TODO(analytics): mirror these five names + props in the shared server schema
  // (recapture-api/src/validation/analyticsSchemas.ts) + the tracking-plan doc.

  /// The session upload began transferring (idle → uploading) — once per engine
  /// run (an auto-retry re-run is a new run; attempt context lives in
  /// [uploadAttemptStarted]). Props: { capture_session_id, total_files,
  ///   total_bytes, upload_size_mb, device_type }.
  static const String uploadStarted = 'upload_started';

  /// The upload transitioned uploading → paused — once per pause edge; multiple
  /// cycles emit multiple pairs. Props: { capture_session_id, files_uploaded,
  ///   bytes_uploaded, pause_reason (user|connectivity|other), device_type }.
  static const String uploadPaused = 'upload_paused';

  /// The upload transitioned paused → uploading — once per resume edge. Props:
  /// { capture_session_id, files_uploaded, bytes_uploaded, device_type }.
  static const String uploadResumed = 'upload_resumed';

  /// The upload reached completed (all files confirmed) — once per run. Owns
  /// the bare name (Screen 9's observation event is [uploadCompletedView]).
  /// Props: { capture_session_id, total_files, total_bytes, upload_size_mb,
  ///   duration_ms (null if no start timestamp), device_type }.
  static const String uploadCompleted = 'upload_completed';

  /// The upload entered the terminal failed state — once per run; NOT emitted
  /// for a user cancel. Props: { capture_session_id, files_uploaded,
  ///   bytes_uploaded, failure_reason, device_type }.
  static const String uploadFailed = 'upload_failed';

  /// Intra-upload byte-progress milestone: cumulative progress FIRST crossed
  /// 25/50/75/100% — at most once per milestone per engine run (highest-reached
  /// guard: pause/resume and part-retry dips never re-fire; a multi-milestone
  /// jump fires each crossed one in ascending order). Emitted from the engine's
  /// single progress point ([ChunkedUploadManager]), never from UI, and only
  /// when totalBytes > 0. The 100% milestone is a progress signal — it does NOT
  /// replace [uploadCompleted]. SUPERSEDES the reporter-level
  /// `upload_progress_milestone` (removed; it was never wired or mirrored).
  /// Props: { capture_session_id, milestone_pct (25|50|75|100), bytes_uploaded,
  ///   upload_size_mb (bytesToMb(totalBytes), same conversion as Screen 9's
  ///   total_mb), device_type }.
  static const String uploadProgress = 'upload_progress';

  // ── Upload engine (chunked multipart transfer) — part-level ENGINE telemetry ─
  // Emitted by the ChunkedUploadManager (lib/application/upload/
  // chunked_upload_manager.dart) — part-level diagnostics BELOW the lifecycle
  // events above (a part retry is not a lifecycle edge). device_type is "mobile"
  // per the engine telemetry spec (a coarse client tag, distinct from the
  // android/ios used by view events).
  // TODO(analytics): mirror these two names + props in the shared server schema
  // (recapture-api/src/validation/analyticsSchemas.ts) + the tracking-plan doc.

  /// A part upload was retried after a transient failure. Props:
  /// { capture_session_id, file_index, part_number, attempt, device_type }.
  static const String uploadPartRetry = 'upload_part_retry';

  /// A multipart upload was aborted (terminal failure or cancel) so S3 keeps no
  /// incomplete upload. Props: { capture_session_id, reason, files_completed,
  ///   device_type }.
  static const String uploadMultipartAborted = 'upload_multipart_aborted';

  // ── Upload auto-retry (session-level exponential backoff) — ENGINE telemetry ─
  // Emitted by the ResilientUploadRunner (lib/application/upload/
  // resilient_upload_runner.dart) as it auto-retries a transient session failure
  // (max 3 retries / 4 attempts). Diagnostics, NOT user-interaction analytics; the
  // categories align with Screen 9F's error_category. Distinct from 9F's own
  // user-initiated Retry (upload_retry_tapped). device_type is "mobile".
  // TODO(analytics): mirror these four names + props in the shared server schema
  // (recapture-api/src/validation/analyticsSchemas.ts) + the tracking-plan doc.

  /// An upload attempt began. Props: { session_id, attempt (1-based),
  ///   is_retry (bool), device_type }.
  static const String uploadAttemptStarted = 'upload_attempt_started';

  /// An upload attempt failed. Props: { session_id, attempt, error_category,
  ///   retryable (bool), next_delay_ms (present only when a retry follows),
  ///   device_type }.
  static const String uploadAttemptFailed = 'upload_attempt_failed';

  /// Auto-retries were exhausted (terminal). Props: { session_id, total_attempts,
  ///   error_category, device_type }.
  static const String uploadRetriesExhausted = 'upload_retries_exhausted';

  /// An upload succeeded (possibly after retries). Props: { session_id,
  ///   attempts_used, device_type }. Distinct from the lifecycle event
  ///   [uploadCompleted] and the VIEW event [uploadCompletedView].
  static const String uploadSucceeded = 'upload_succeeded';

  // NOTE: the reporter-level `upload_progress_milestone` const was removed —
  // the engine-emitted canonical [uploadProgress] supersedes it.

  // ── Offline upload queue (detect offline → queue → auto-resume) — ENGINE ────
  // Emitted by the OfflineUploadQueue coordinator (lib/application/upload/
  // offline_upload_queue.dart) when a job enters "waiting for connection" or is
  // auto-resumed on connectivity restore. Diagnostics, NOT user-interaction
  // analytics — the user tap-intent events (upload_pause_tapped/
  // upload_resume_tapped) stay the buttons' territory, and the state edges
  // themselves are the lifecycle events above. device_type is "mobile".
  // TODO(analytics): mirror these names + props in the shared server schema
  // (recapture-api/src/validation/analyticsSchemas.ts) + the tracking-plan doc.

  /// An upload job was queued to wait for connectivity instead of failing.
  /// Props: { session_id, reason (offline_at_start|network_failure),
  ///   pending_count, device_type }.
  static const String uploadOfflineQueued = 'upload_offline_queued';

  /// A previously offline-queued job was auto-resumed (connectivity restored or
  /// reachability re-probe) — continues from the persisted offset/ETags. Fires
  /// per resumed job, never for user-paused jobs. Props: { session_id,
  ///   attempt (queue-level run count, 1-based), pending_count, device_type }.
  static const String uploadOfflineAutoResumed = 'upload_offline_auto_resumed';

  // ── Uploading screen (Screen 9) — view-level upload progress ────────────────
  // VIEW-level events from the Uploading screen observing the upload pipeline's
  // progress stream — distinct from any future service-layer transfer events.
  // NAMING: the brief lists `capture_session_id` / `device_type: mobile`; this
  // funnel uses `session_id` + android/ios so these join the upload funnel
  // (capture_summary_proceed_to_upload / upload_initiated / upload_gate_*).
  // TODO(analytics): mirror in the shared server schema + tracking-plan doc.

  /// The Uploading screen became visible — fired once per entry, on the first
  /// progress snapshot (so totals are populated). Props: { session_id,
  /// phase: upload, total_files, total_mb, device_type }.
  static const String uploadStartedView = 'upload_started_view';

  /// The observed upload reached the completed state (once). RENAMED from the
  /// bare `upload_completed` — the engine lifecycle event [uploadCompleted] owns
  /// that name now; this is the Screen 9 observation, suffixed like its
  /// _view siblings. Props: { session_id, phase: upload, total_files, total_mb,
  /// duration_ms, device_type }.
  static const String uploadCompletedView = 'upload_completed_view';

  /// The observed upload reached a failed/error state (once). Props: { session_id,
  /// phase: upload, files_uploaded_at_failure, device_type }.
  static const String uploadFailedView = 'upload_failed_view';

  // ── Upload Failed screen (Screen 9F) — reason + Retry / Back to Projects ────
  // The failure DESTINATION (distinct from the observation event above): it maps
  // the pipeline failure to a friendly category + retryable classification and
  // owns the recovery actions. `error_category` is the MAPPED bucket (never raw).
  // `session_id` + android/ios, matching the rest of the upload funnel.
  // TODO(analytics): mirror these three names + props in the shared server schema
  // (recapture-api/src/validation/analyticsSchemas.ts) + the tracking-plan doc.

  /// Screen 9F became visible. Props: { session_id, phase: upload, error_category,
  /// retryable, device_type }.
  static const String uploadFailedViewed = 'upload_failed_viewed';

  /// Retry was tapped on Screen 9F (retryable failures only; double-tap guarded).
  /// Props: { session_id, error_category, device_type }.
  static const String uploadRetryTapped = 'upload_retry_tapped';

  /// Back to Projects was tapped on Screen 9F. Props: { session_id, error_category,
  /// device_type }.
  static const String uploadFailedBackToProjects =
      'upload_failed_back_to_projects';

  // ── Uploading screen (Screen 9) — Pause / Resume / Cancel controls ──────────
  // The user SIGNALLED a transfer control. These are UI-intent events (the user
  // tapped a control that passed the state + in-flight guards), distinct from the
  // pipeline's own state transitions — the pipeline owns the mechanics. Each fires
  // once per accepted tap (wrong-state / double taps are guarded and emit nothing).
  // NAMING: `session_id` + android/ios, matching the rest of the upload funnel.
  // TODO(analytics): mirror in the shared server schema + tracking-plan doc.

  /// The user signalled Pause on an in-progress upload. RENAMED from the bare
  /// `upload_paused` (now the engine lifecycle event [uploadPaused]) — this is
  /// the tap INTENT, named like 9F's [uploadRetryTapped]. Props: { session_id,
  /// phase: upload, device_type }.
  static const String uploadPauseTapped = 'upload_pause_tapped';

  /// The user signalled Resume on a paused upload (continues from the durable
  /// queue). RENAMED from the bare `upload_resumed` (now the engine lifecycle
  /// event [uploadResumed]) — tap INTENT only. Props: { session_id,
  /// phase: upload, device_type }.
  static const String uploadResumeTapped = 'upload_resume_tapped';

  /// The user CONFIRMED Cancel — the transfer is aborted but the local captured
  /// data is retained (re-uploadable), so this is NOT a delete. Fires only after
  /// the confirmation is accepted (a dismissed confirmation emits nothing). Props:
  /// { session_id, phase: upload, from_state: uploading|paused, device_type }.
  static const String uploadCancelled = 'upload_cancelled';

  // ── Cancel → Keep as Draft (Capture Summary / Uploading leave-flow) ─────────
  // The safe-leave confirmation whose primary outcome keeps the work as a draft.
  // `phase` is `capture_summary` or `upload` (whichever step the user left from);
  // `upload_in_progress` reflects whether a transfer was aborted first. Each fires
  // ONCE per resolution — the kept-draft event only after a SUCCESSFUL save (a
  // failed save keeps the user on-screen and emits nothing). `session_id` +
  // android/ios so these join the rest of the capture/upload funnel.
  // TODO(analytics): mirror these four names + props in the shared server schema
  // (recapture-api/src/validation/analyticsSchemas.ts) + the tracking-plan doc.

  /// The cancel confirmation was shown. Props: { session_id, phase,
  /// upload_in_progress, device_type }.
  static const String captureCancelOpened = 'capture_cancel_opened';

  /// Keep as Draft succeeded and the user left. Fires ONLY after a successful
  /// save. Props: { session_id, phase, device_type }.
  static const String captureCancelKeptDraft = 'capture_cancel_kept_draft';

  /// Discard completed and the user left (the only deletion path). Props:
  /// { session_id, phase, device_type }.
  static const String captureCancelDiscarded = 'capture_cancel_discarded';

  /// The user chose Keep editing / dismissed the confirmation (unchanged). Props:
  /// { session_id, phase, device_type }.
  static const String captureCancelDismissed = 'capture_cancel_dismissed';

  // ── Final completion gate (all levels → unlock Summary) ────────────────────
  // The single completion gate (lib/domain/capture/completion_gate.dart) that
  // unlocks Screen 6C-Complete. TODO(analytics): mirror these two names + props in
  // the shared server schema (recapture-api/src/validation/analyticsSchemas.ts) +
  // the tracking-plan doc when the analytics destination lands.

  /// The completion gate flipped locked→unlocked (every configured level met its
  /// threshold) for a session. Fires ONCE per transition, not per evaluation.
  /// Props: { session_id, phase: guided_capture, levels_total, device_type }.
  static const String guidedCaptureSummaryUnlocked =
      'guided_capture_summary_unlocked';

  /// A Summary-access attempt was blocked because the gate is still locked. Props:
  /// { session_id, phase: guided_capture, incomplete_levels (comma-separated level
  /// ids), device_type }.
  static const String guidedCaptureSummaryBlocked =
      'guided_capture_summary_blocked';

  /// The full guided-capture session finished — EVERY configured level (A/B/C) met
  /// its completion threshold. The funnel-end counterpart to the per-level
  /// `capture_level_completed` events. Fires EXACTLY ONCE per locked→unlocked
  /// transition (same latch as [guidedCaptureSummaryUnlocked]), never per level /
  /// per frame / on rebuild. Props: { session_id, phase: guided_capture,
  /// levels_total, levels_completed, total_frame_count, level_<code>_frame_count
  /// per level, device_type }. `session_id` is the same opaque funnel id the
  /// per-level events carry, so the funnel joins on it.
  static const String captureSessionComplete = 'capture_session_complete';

  // ── Level A review flow (Screen 7A) — funnel events ────────────────────────
  // The review-session funnel, typed in
  // lib/application/capture/analytics/review_flow_events.dart. DISTINCT from
  // [reviewGridViewed] above: that is the display/QA event carrying verdict
  // tallies; these three are the review FUNNEL (session open + the destructive
  // actions, keyed on the opaque project_id/session_id the rest of the funnel
  // uses — NOT raw PII, file paths, or image data).
  // TODO(analytics): mirror these three names + props in the shared server schema
  // (recapture-api/src/validation/analyticsSchemas.ts) + the tracking-plan doc
  // when the analytics destination lands (same deferred status as the rest of the
  // capture funnel).

  /// The review grid (Screen 7A) opened — review session start. Fires once per
  /// screen OPEN (debounced via initState; not per rebuild/rotation). Props:
  /// { level, project_id, session_id, photo_count, coverage_pct, entry_point?,
  ///   device_type }.
  static const String photoReviewOpened = 'photo_review_opened';

  /// A Retake action completed on a selection — ONE event per action (NOT per
  /// photo), on success only, with the ACTUAL count retaken. Props:
  /// { level, project_id, session_id, count, segment_indices, device_type }.
  static const String photoRetaken = 'photo_retaken';

  /// A Delete action completed on a selection — ONE event per action (NOT per
  /// photo), on success only, with the ACTUAL count deleted. Props:
  /// { level, project_id, session_id, count, resulting_coverage_pct?,
  ///   segments_now_missing, device_type }.
  static const String photoDeleted = 'photo_deleted';

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
