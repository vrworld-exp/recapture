// lib/application/capture/analytics/coverage_analytics_tracker.dart
//
// The once-semantics brain for the `segment_filled` + `coverage_milestone`
// events. It OBSERVES [SegmentCoverage] snapshots from the outside — the pure
// segment-state model carries no analytics — and emits:
//
//   segment_filled     once per unfilled→filled TRANSITION (threshold-aware via
//                      SegmentCoverage.filled, so it fires when the count reaches
//                      fillThreshold; never on overfill or a sub-threshold capture)
//   coverage_milestone once per 25/50/75/100% CROSSING this session (a single fill
//                      can cross several at a small segment count → all fired)
//
// State held here (NOT in the model): the previous `filled` mask + the fired
// milestone set. Drop-then-recross does NOT re-fire a milestone (default policy);
// [reset] clears tracking for a new level-session.
//
// Emission is fire-and-forget: it routes through [CaptureAnalytics.log] (the
// guarded `Analytics` seam), so an analytics failure can never block or crash the
// capture hot path.
import '../../../domain/capture/coverage_milestones.dart';
import '../../../domain/entities/segment_coverage.dart';
import 'capture_analytics.dart';
import 'capture_level_events.dart';

class CoverageAnalyticsTracker {
  CoverageAnalyticsTracker({void Function(CaptureLevelEvent)? emit})
      : _emit = emit ?? CaptureAnalytics.log;

  final void Function(CaptureLevelEvent) _emit;

  /// The `filled` mask at the previous observation. Out-of-range (a shorter prior
  /// mask after a reconfigure) reads as "was not filled".
  List<bool> _prevFilled = const [];

  /// Milestones already emitted this session — never re-fired (drop-then-recross
  /// stays quiet).
  final Set<int> _firedMilestones = <int>{};

  /// Observes a new coverage snapshot and emits the resulting lifecycle events.
  ///
  /// [captureMode] is "guided"/"manual" (only `segment_filled` carries it); the
  /// remaining context stitches the funnel (shared with the other capture-level
  /// events). Emits `segment_filled` for each newly-filled segment (ascending),
  /// then every newly-crossed milestone (ascending).
  void onCoverageChanged(
    SegmentCoverage coverage, {
    required CaptureLevel level,
    required String projectId,
    required String sessionId,
    required String captureMode,
    required String deviceType,
  }) {
    final filled = coverage.filled;

    // 1) segment_filled — unfilled→filled transitions only.
    for (var i = 0; i < filled.length; i++) {
      final wasFilled = i < _prevFilled.length && _prevFilled[i];
      if (filled[i] && !wasFilled) {
        _emit(CaptureSegmentFilled(
          level: level,
          projectId: projectId,
          sessionId: sessionId,
          segmentIndex: i,
          segmentCount: coverage.segmentCount,
          captureMode: captureMode,
          deviceType: deviceType,
        ));
      }
    }

    // 2) coverage_milestone — each newly-crossed milestone, in order.
    final pct = coveragePercent(coverage.filledCount, coverage.segmentCount);
    for (final m in newlyCrossedMilestones(pct: pct, alreadyFired: _firedMilestones)) {
      _firedMilestones.add(m);
      _emit(CaptureCoverageMilestone(
        level: level,
        projectId: projectId,
        sessionId: sessionId,
        milestone: m,
        filledCount: coverage.filledCount,
        segmentCount: coverage.segmentCount,
        deviceType: deviceType,
      ));
    }

    _prevFilled = filled;
  }

  /// Clears tracking for a new level-session: prior fills forgotten and the fired
  /// milestone set emptied, so the next run re-emits from scratch.
  void reset() {
    _prevFilled = const [];
    _firedMilestones.clear();
  }
}
