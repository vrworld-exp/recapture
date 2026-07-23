// lib/application/capture/analytics/capture_level_events.dart
//
// The canonical, `level`-parameterized capture-level lifecycle analytics events —
// the single funnel source of truth reused across Levels A/B/C:
//
//   capture_level_started    guided capture for a level begins
//   capture_level_completed  the level meets its completion criteria
//   capture_level_retake     a retake is initiated for a segment
//
// These SUPERSEDE the earlier ad-hoc, level-specific names (`level_a_completed`,
// `retake_started`) from the overlay tasks. Granular UI events (intro viewed,
// blocked-shutter tap, completion-CTA action, retake_completed, …) stay as-is —
// only these three lifecycle events are consolidated here.
//
// Each event is a typed class so call sites never hand-assemble stringly-typed
// maps; the names come from [AnalyticsEvents] (one constant source) and the
// property maps use real int/bool/String types for clean downstream querying.
// Emission goes through [CaptureAnalytics.log] → the existing `Analytics`
// dispatcher. PRIVACY: only opaque ids (project_id/session_id), enum values, and
// counts — never names, emails, phones, file paths, or tokens.
import '../../../domain/capture/capture_flow_variant.dart';
import '../../../domain/capture/capture_mode.dart';
import '../../../utils/analytics.dart';

/// The capture level this event belongs to. Serializes to "A"/"B"/"C".
enum CaptureLevel { a, b, c }

extension CaptureLevelX on CaptureLevel {
  /// Canonical wire value — uppercase letter.
  String get code => name.toUpperCase();
}

/// Maps a screen's level label ('A'/'B'/'C', any case) to [CaptureLevel].
/// Unknown labels fall back to [CaptureLevel.a] (Level A is the only built flow).
CaptureLevel captureLevelFromLabel(String label) =>
    switch (label.trim().toUpperCase()) {
      'B' => CaptureLevel.b,
      'C' => CaptureLevel.c,
      _ => CaptureLevel.a,
    };

/// The config `PitchBand.id` each level targets — the SINGLE source for the
/// level→band mapping, shared by the capture ledger/session key, the pitch gate
/// (shutter + auto-capture `isInPitchBand`), and the tilt indicator, so none of
/// them can disagree on which band a level enforces. The bands tile the capture
/// sphere: A = Eye Ring (`mid`), B = Top Ring (`high`), C = Bottom Ring (`low`).
///
/// Only the band ID is mapped here — the DEGREES live in
/// `CaptureConfig.pitchBands` (remote-config-overridable), so retuning a band
/// (or the Top/Bottom ranges) needs no code change.
String pitchBandIdForLevel(CaptureLevel level) => switch (level) {
      CaptureLevel.a => 'mid',
      CaptureLevel.b => 'high',
      CaptureLevel.c => 'low',
    };

/// The ACTIVE level list for a flow variant — the taxonomy-side view of
/// [CaptureFlowVariant.bandIds] (the domain type speaks band ids only; the
/// CaptureLevel enum lives in this layer). This is the SINGLE source every
/// flow-shaping iteration uses instead of `CaptureLevel.values`: gates, the
/// progression/machine builders, the summary, and the upload gate all follow
/// it, so a 2-ring session never demands (or lists) Level C anywhere.
extension CaptureFlowVariantLevels on CaptureFlowVariant {
  /// This variant's levels in flow order (A→B[→C]) — always a prefix of
  /// [CaptureLevel.values], so flow order never changes between variants.
  ///
  /// This is the FULL-mode (variant-shaped) list. Flow consumers must NOT read
  /// it directly — they go through [activeCaptureLevels], which also collapses
  /// Meshy mode to its single ring. Reading `.levels` unqualified would run a
  /// Meshy capture against the full A→B[→C] sequence.
  List<CaptureLevel> get levels => switch (this) {
        CaptureFlowVariant.withBottom =>
          const [CaptureLevel.a, CaptureLevel.b, CaptureLevel.c],
        CaptureFlowVariant.withoutBottom =>
          const [CaptureLevel.a, CaptureLevel.b],
      };
}

/// The ACTIVE level list for a ([variant], [mode]) pair — the SINGLE source
/// every flow-shaping iteration (progression builder, segment machines, upload
/// gate, completion gate, summary, upload snapshot, post-Level-A routing) goes
/// through instead of [CaptureFlowVariantLevels.levels].
///
/// - FULL mode → the variant's levels (A→B with bottom, A→B[→C]).
/// - MESHY mode → ALWAYS just [CaptureLevel.a] (the single eye ring), regardless
///   of variant: Meshy is variant-independent (see [CaptureMode]), so no TOP or
///   LOW ring is ever active and the flow ends at Summary after Level A.
///
/// Centralising this is what keeps a Meshy session from demanding — or the
/// upload snapshot from counting — Level B/C anywhere.
List<CaptureLevel> activeCaptureLevels(
  CaptureFlowVariant variant,
  CaptureMode mode,
) =>
    mode == CaptureMode.meshy ? const [CaptureLevel.a] : variant.levels;

/// A typed capture-level lifecycle event: its dispatcher [name] + its [properties].
abstract class CaptureLevelEvent {
  /// The canonical event name (an [AnalyticsEvents] constant).
  String get name;

  /// The property payload — opaque ids, enums, and counts only.
  Map<String, Object?> get properties;
}

/// Guided capture for [level] began. Fires once per capture session.
class CaptureLevelStarted implements CaptureLevelEvent {
  const CaptureLevelStarted({
    required this.level,
    required this.projectId,
    required this.sessionId,
    required this.captureMode,
    required this.targetSegments,
    required this.sensorSupported,
    required this.deviceType,
  });

  final CaptureLevel level;
  final String projectId;
  final String sessionId;

  /// "guided" (auto-capture) | "manual" (tap).
  final String captureMode;

  /// Target capture positions (N) for the level, from CaptureConfig (bundled
  /// default if config has not loaded — never null/NaN).
  final int targetSegments;
  final bool sensorSupported;

  /// "android" | "ios".
  final String deviceType;

  @override
  String get name => AnalyticsEvents.captureLevelStarted;

  @override
  Map<String, Object?> get properties => {
        'level': level.code,
        'project_id': projectId,
        'session_id': sessionId,
        'capture_mode': captureMode,
        'target_segments': targetSegments,
        'sensor_supported': sensorSupported,
        'device_type': deviceType,
      };
}

/// The level met its completion criteria. Fires once per session completion.
class CaptureLevelCompleted implements CaptureLevelEvent {
  const CaptureLevelCompleted({
    required this.level,
    required this.projectId,
    required this.sessionId,
    required this.accepted,
    required this.target,
    required this.rejected,
    required this.coveragePct,
    required this.durationSeconds,
    required this.deviceType,
  });

  final CaptureLevel level;
  final String projectId;
  final String sessionId;
  final int accepted;
  final int target;
  final int rejected;

  /// Coverage 0..100 (rounded).
  final int coveragePct;

  /// Wall-clock seconds from the level's `started` to this completion (0 when the
  /// start was not observed — e.g. a deep-link/restart; never negative/null).
  final int durationSeconds;
  final String deviceType;

  @override
  String get name => AnalyticsEvents.captureLevelCompleted;

  @override
  Map<String, Object?> get properties => {
        'level': level.code,
        'project_id': projectId,
        'session_id': sessionId,
        'accepted': accepted,
        'target': target,
        'rejected': rejected,
        'coverage_pct': coveragePct,
        'duration_seconds': durationSeconds,
        'device_type': deviceType,
      };
}

/// A retake was initiated for a segment. Fires once per retake initiation.
class CaptureLevelRetake implements CaptureLevelEvent {
  const CaptureLevelRetake({
    required this.level,
    required this.projectId,
    required this.sessionId,
    required this.ringIndex,
    required this.replacingExisting,
    required this.returnMode,
    required this.deviceType,
  });

  final CaptureLevel level;
  final String projectId;
  final String sessionId;
  final int ringIndex;

  /// True when an existing capture is replaced; false when filling a missing one.
  final bool replacingExisting;

  /// "review" (single retake) | "resume" (continue guided capture).
  final String returnMode;
  final String deviceType;

  @override
  String get name => AnalyticsEvents.captureLevelRetake;

  @override
  Map<String, Object?> get properties => {
        'level': level.code,
        'project_id': projectId,
        'session_id': sessionId,
        'ring_index': ringIndex,
        'replacing_existing': replacingExisting,
        'return_mode': returnMode,
        'device_type': deviceType,
      };
}

/// A ring segment transitioned unfilled→filled. Fires once per transition
/// (threshold-aware, never on overfill) — see [CoverageAnalyticsTracker].
class CaptureSegmentFilled implements CaptureLevelEvent {
  const CaptureSegmentFilled({
    required this.level,
    required this.projectId,
    required this.sessionId,
    required this.segmentIndex,
    required this.segmentCount,
    required this.captureMode,
    required this.deviceType,
  });

  final CaptureLevel level;
  final String projectId;
  final String sessionId;
  final int segmentIndex;
  final int segmentCount;

  /// "guided" (auto-capture) | "manual" (tap).
  final String captureMode;
  final String deviceType;

  @override
  String get name => AnalyticsEvents.segmentFilled;

  @override
  Map<String, Object?> get properties => {
        'level': level.code,
        'project_id': projectId,
        'session_id': sessionId,
        'segment_index': segmentIndex,
        'segment_count': segmentCount,
        'capture_mode': captureMode,
        'device_type': deviceType,
      };
}

/// A user shutter tap INITIATED a capture (at trigger time, before acceptance).
/// Fires once per non-blocked tap; never on a blocked tap. Mutually exclusive
/// with [CaptureAutoTriggered] for one physical capture.
class CaptureManualTriggered implements CaptureLevelEvent {
  const CaptureManualTriggered({
    required this.level,
    required this.projectId,
    required this.sessionId,
    required this.attemptNumber,
    required this.ringIndex,
    required this.inBand,
    required this.stable,
    required this.sensorSupported,
    required this.wasBlockedOverride,
    required this.deviceType,
  });

  final CaptureLevel level;
  final String projectId;
  final String sessionId;

  /// Session-shared monotonic attempt sequence number.
  final int attemptNumber;

  /// The targeted ring segment, or null when free/unaligned (manual).
  final int? ringIndex;
  final bool inBand;
  final bool stable;
  final bool sensorSupported;

  /// True when the capture fired despite the guided gates not being satisfied
  /// (fail-open: sensors off / manual mode) — for QA of the fail-open policy.
  final bool wasBlockedOverride;
  final String deviceType;

  @override
  String get name => AnalyticsEvents.manualCaptureTriggered;

  @override
  Map<String, Object?> get properties => {
        'level': level.code,
        'project_id': projectId,
        'session_id': sessionId,
        'attempt_number': attemptNumber,
        'ring_index': ringIndex,
        'in_band': inBand,
        'stable': stable,
        'sensor_supported': sensorSupported,
        'was_blocked_override': wasBlockedOverride,
        'device_type': deviceType,
      };
}

/// The auto-capture loop INITIATED a capture (at trigger time). Fires once per
/// auto-fired shot. Mutually exclusive with [CaptureManualTriggered].
class CaptureAutoTriggered implements CaptureLevelEvent {
  const CaptureAutoTriggered({
    required this.level,
    required this.projectId,
    required this.sessionId,
    required this.attemptNumber,
    required this.ringIndex,
    required this.inBand,
    required this.stable,
    required this.sensorSupported,
    required this.deviceType,
  });

  final CaptureLevel level;
  final String projectId;
  final String sessionId;
  final int attemptNumber;
  final int? ringIndex;
  final bool inBand;
  final bool stable;
  final bool sensorSupported;
  final String deviceType;

  @override
  String get name => AnalyticsEvents.autocaptureTriggered;

  @override
  Map<String, Object?> get properties => {
        'level': level.code,
        'project_id': projectId,
        'session_id': sessionId,
        'attempt_number': attemptNumber,
        'ring_index': ringIndex,
        'in_band': inBand,
        'stable': stable,
        'sensor_supported': sensorSupported,
        'device_type': deviceType,
      };
}

/// Ring coverage first crossed a milestone (25/50/75/100%). Fires once per
/// crossing per session. RAW coverage — not the completion gate.
class CaptureCoverageMilestone implements CaptureLevelEvent {
  const CaptureCoverageMilestone({
    required this.level,
    required this.projectId,
    required this.sessionId,
    required this.milestone,
    required this.filledCount,
    required this.segmentCount,
    required this.deviceType,
  });

  final CaptureLevel level;
  final String projectId;
  final String sessionId;

  /// 25 | 50 | 75 | 100.
  final int milestone;
  final int filledCount;
  final int segmentCount;
  final String deviceType;

  @override
  String get name => AnalyticsEvents.coverageMilestone;

  @override
  Map<String, Object?> get properties => {
        'level': level.code,
        'project_id': projectId,
        'session_id': sessionId,
        'milestone': milestone,
        'filled_count': filledCount,
        'segment_count': segmentCount,
        'device_type': deviceType,
      };
}
