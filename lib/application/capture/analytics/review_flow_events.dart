// lib/application/capture/analytics/review_flow_events.dart
//
// The three Screen 7A review-flow analytics events, typed onto the existing
// canonical [CaptureLevelEvent] family (so they share the funnel's level/
// project_id/session_id/device_type shape and emit through [CaptureAnalytics.log]
// — never hand-assembled name+map):
//
//   photo_review_opened  the review grid opened (review session start). Once per
//                        screen OPEN (debounced by the screen's initState, not
//                        per rebuild/rotation).
//   photo_retaken        the Retake action completed on a selection. ONE event per
//                        action carrying `count` = photos actually retaken (NOT
//                        one event per photo) + the freed segment targets.
//   photo_deleted        the Delete action completed on a selection. ONE event per
//                        action carrying `count` = photos actually deleted + the
//                        segments that became missing as a result.
//
// GROUNDING (matches the rest of the capture funnel, NOT the brief's field names):
//   * Identifiers are the opaque `project_id` + `session_id` already used across
//     capture_level_events — these are server ObjectIds/session ids, not PII, so
//     they are passed through directly. The brief's `projectIdHash`/`jobIdHash` are
//     deliberately NOT used: the client has no hashing util (that is a backend-only
//     concern per AGENTS.md) and the funnel keys on `session_id`, which IS the
//     capture job. Keeping these consistent with segment_filled/coverage_milestone
//     matters more than mirroring the brief verbatim.
//   * Payloads carry only enums, counts, segment indices, and those opaque ids —
//     never names, emails, phones, FILE PATHS, image bytes, or location.
//
// PRIVACY / fire-and-forget: emission routes through [CaptureAnalytics.log] → the
// guarded `Analytics` dispatcher, so an analytics failure can never block or crash
// the review action or the screen open.
//
// TODO(analytics): mirror these three names + props in the shared server schema
// (recapture-api/src/validation/analyticsSchemas.ts) + the tracking-plan doc when
// the analytics destination lands — same deferred status as the rest of the
// capture funnel (segment_filled, coverage_milestone, capture_level_*).
import '../../../utils/analytics.dart';
import 'capture_analytics.dart';
import 'capture_level_events.dart';

/// The review grid (Screen 7A) was opened — a review-session-start REACH metric.
/// Fires once per screen OPEN (the screen debounces via `initState`, so a rebuild
/// or orientation change does NOT re-fire). Fires even with zero photos
/// ([photoCount] = 0).
class PhotoReviewOpened implements CaptureLevelEvent {
  const PhotoReviewOpened({
    required this.level,
    required this.projectId,
    required this.sessionId,
    required this.photoCount,
    required this.coveragePct,
    required this.deviceType,
    this.entryPoint,
  });

  final CaptureLevel level;
  final String projectId;
  final String sessionId;

  /// Number of captures shown in the grid at open (0 is valid).
  final int photoCount;

  /// Ring coverage 0..100 at open.
  final int coveragePct;

  /// Where the review was opened from: "capture" (from the capture/completion
  /// flow) | "project" (resume/view-later). Optional context — omitted when null.
  final String? entryPoint;

  /// "android" | "ios".
  final String deviceType;

  @override
  String get name => AnalyticsEvents.photoReviewOpened;

  @override
  Map<String, Object?> get properties => {
        'level': level.code,
        'project_id': projectId,
        'session_id': sessionId,
        'photo_count': photoCount,
        'coverage_pct': coveragePct,
        if (entryPoint != null) 'entry_point': entryPoint,
        'device_type': deviceType,
      };
}

/// A Retake action completed on a selection. ONE event per completed action;
/// [count] is the number of photos actually retaken (the selection size that was
/// processed — on partial failure this is the count that actually succeeded, NOT
/// the attempted size). NOT emitted on a cancelled confirm or a fully-failed
/// action. NOT one event per photo.
class PhotoRetaken implements CaptureLevelEvent {
  const PhotoRetaken({
    required this.level,
    required this.projectId,
    required this.sessionId,
    required this.count,
    required this.segmentIndices,
    required this.deviceType,
  });

  final CaptureLevel level;
  final String projectId;
  final String sessionId;

  /// Photos actually retaken in this action (>= 1; the action does not emit at 0).
  final int count;

  /// The ring segments freed by the retake (the targets guidance returns to),
  /// ascending. May be empty if no segment dropped below threshold.
  final List<int> segmentIndices;
  final String deviceType;

  @override
  String get name => AnalyticsEvents.photoRetaken;

  @override
  Map<String, Object?> get properties => {
        'level': level.code,
        'project_id': projectId,
        'session_id': sessionId,
        'count': count,
        'segment_indices': segmentIndices,
        'device_type': deviceType,
      };
}

/// A Delete action completed on a selection. ONE event per completed action;
/// [count] is the number of photos actually deleted (on partial failure this is
/// the count that actually succeeded, NOT the attempted size). NOT emitted on a
/// cancelled confirm. NOT one event per photo.
class PhotoDeleted implements CaptureLevelEvent {
  const PhotoDeleted({
    required this.level,
    required this.projectId,
    required this.sessionId,
    required this.count,
    required this.segmentsNowMissing,
    required this.deviceType,
    this.resultingCoveragePct,
  });

  final CaptureLevel level;
  final String projectId;
  final String sessionId;

  /// Photos actually deleted in this action (>= 1; the action does not emit at 0).
  final int count;

  /// The ring segments that became MISSING as a result of this delete, ascending.
  final List<int> segmentsNowMissing;

  /// Ring coverage 0..100 AFTER the delete. Optional — omitted when the caller
  /// cannot cheaply read post-action coverage.
  final int? resultingCoveragePct;
  final String deviceType;

  @override
  String get name => AnalyticsEvents.photoDeleted;

  @override
  Map<String, Object?> get properties => {
        'level': level.code,
        'project_id': projectId,
        'session_id': sessionId,
        'count': count,
        if (resultingCoveragePct != null)
          'resulting_coverage_pct': resultingCoveragePct,
        'segments_now_missing': segmentsNowMissing,
        'device_type': deviceType,
      };
}

/// Context + emit seam the review screen supplies so [PhotoReviewOpened] carries
/// the funnel ids/coverage the reusable grid widget itself does not know. Built by
/// the screen owner (which has project/session/coverage in hand). Emit defaults to
/// the guarded [CaptureAnalytics.log]; tests inject a capturing fn.
class ReviewOpenAnalytics {
  ReviewOpenAnalytics({
    required this.level,
    required this.projectId,
    required this.sessionId,
    required this.coveragePct,
    this.entryPoint,
    void Function(CaptureLevelEvent)? emit,
  }) : _emit = emit ?? CaptureAnalytics.log;

  final CaptureLevel level;
  final String projectId;
  final String sessionId;
  final int coveragePct;
  final String? entryPoint;
  final void Function(CaptureLevelEvent) _emit;

  /// Emit `photo_review_opened` for an open showing [photoCount] photos. Guarded —
  /// called once per screen open from the grid's `initState`.
  void opened(int photoCount, {required String deviceType}) {
    _emit(PhotoReviewOpened(
      level: level,
      projectId: projectId,
      sessionId: sessionId,
      photoCount: photoCount,
      coveragePct: coveragePct,
      entryPoint: entryPoint,
      deviceType: deviceType,
    ));
  }
}

/// Context + emit seam the screen owner supplies to [ReviewActionsController] so a
/// completed delete/retake emits `photo_deleted`/`photo_retaken` with the ACTUAL
/// affected count. Emit defaults to the guarded [CaptureAnalytics.log]; tests
/// inject a capturing fn. Both methods are no-ops at [count] 0 (a cancelled or
/// fully-failed action never reports).
class ReviewActionsAnalytics {
  ReviewActionsAnalytics({
    required this.level,
    required this.projectId,
    required this.sessionId,
    required this.deviceType,
    this.resultingCoveragePct,
    void Function(CaptureLevelEvent)? emit,
  }) : _emit = emit ?? CaptureAnalytics.log;

  final CaptureLevel level;
  final String projectId;
  final String sessionId;
  final String deviceType;

  /// Live read of ring coverage% (0..100) AFTER an action, for `photo_deleted`'s
  /// resulting_coverage_pct. Null → the field is omitted.
  final int Function()? resultingCoveragePct;
  final void Function(CaptureLevelEvent) _emit;

  void deleted({required int count, required List<int> segmentsNowMissing}) {
    if (count <= 0) return;
    _emit(PhotoDeleted(
      level: level,
      projectId: projectId,
      sessionId: sessionId,
      count: count,
      segmentsNowMissing: segmentsNowMissing,
      resultingCoveragePct: resultingCoveragePct?.call(),
      deviceType: deviceType,
    ));
  }

  void retaken({required int count, required List<int> segmentIndices}) {
    if (count <= 0) return;
    _emit(PhotoRetaken(
      level: level,
      projectId: projectId,
      sessionId: sessionId,
      count: count,
      segmentIndices: segmentIndices,
      deviceType: deviceType,
    ));
  }
}
