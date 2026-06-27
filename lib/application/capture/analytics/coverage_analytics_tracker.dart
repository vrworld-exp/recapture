// lib/application/capture/analytics/coverage_analytics_tracker.dart
//
// The once-semantics brain for the `segment_filled` + `coverage_milestone`
// events. It OBSERVES [SegmentCoverage] snapshots from the outside — the pure
// segment-state model carries no analytics — and emits:
//
//   segment_filled     once per unfilled→filled TRANSITION (threshold-aware via
//                      SegmentCoverage.filled, so it fires when the count reaches
//                      fillThreshold; never on overfill or a sub-threshold capture)
//   coverage_milestone once per 25/50/75/100% CROSSING (a single fill can cross
//                      several at a small segment count → all fired)
//
// PER-LEVEL INDEPENDENCE: tracking is keyed by [CaptureLevel], so Levels A, B and
// C each get their OWN previous-`filled` mask + fired-milestone set. Level B
// crossing 50% and Level C crossing 50% are two separate once-events — neither
// suppresses the other. The same tracker observes every level's coverage; the
// level passed to [onCoverageChanged] both tags the event and selects the bucket.
//
// State held here (NOT in the model): per-level previous `filled` mask + the
// per-level fired-milestone set. Drop-then-recross does NOT re-fire a milestone
// (default policy); [reset]/[resetLevel] clear tracking, and [seedLevel] restores
// it on RESUME so an already-covered level does not re-fire its passed milestones
// or re-emit `segment_filled` for already-filled segments.
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

  /// Per-level `filled` mask at the previous observation. Out-of-range (a shorter
  /// prior mask after a reconfigure) reads as "was not filled".
  final Map<CaptureLevel, List<bool>> _prevFilledByLevel = {};

  /// Per-level milestones already emitted — never re-fired (drop-then-recross
  /// stays quiet). Each level's set is independent of the others'.
  final Map<CaptureLevel, Set<int>> _firedByLevel = {};

  /// Observes a new coverage snapshot FOR [level] and emits the resulting events,
  /// tagged with that level. Each level's transitions/milestones are tracked in
  /// its own bucket, so the levels never cross-suppress.
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
    final prevFilled = _prevFilledByLevel[level] ?? const <bool>[];
    final fired = _firedByLevel.putIfAbsent(level, () => <int>{});

    // 1) segment_filled — unfilled→filled transitions only (this level's mask).
    for (var i = 0; i < filled.length; i++) {
      final wasFilled = i < prevFilled.length && prevFilled[i];
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

    // 2) coverage_milestone — each newly-crossed milestone, in order (this level's
    // fired set, so B's and C's milestones fire independently).
    final pct = coveragePercent(coverage.filledCount, coverage.segmentCount);
    for (final m in newlyCrossedMilestones(pct: pct, alreadyFired: fired)) {
      fired.add(m);
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

    _prevFilledByLevel[level] = filled;
  }

  /// The milestones already fired for [level] this run — read by the observer to
  /// PERSIST per-level fired-tracking (so a resume doesn't re-fire). A copy, so a
  /// caller can't mutate the internal set.
  Set<int> firedMilestonesFor(CaptureLevel level) =>
      Set<int>.of(_firedByLevel[level] ?? const <int>{});

  /// Seeds [level]'s tracking on RESUME so an already-covered level does not
  /// re-fire. [firedMilestones] are the milestones persisted with the level's
  /// progression state (passed ones stay quiet); [prevFilled] is the restored
  /// coverage's `filled` mask (already-filled segments don't re-emit
  /// `segment_filled`). Only valid milestones {25,50,75,100} are retained.
  void seedLevel({
    required CaptureLevel level,
    Set<int> firedMilestones = const <int>{},
    List<bool> prevFilled = const <bool>[],
  }) {
    _firedByLevel[level] = {
      for (final m in firedMilestones)
        if (kCoverageMilestones.contains(m)) m,
    };
    _prevFilledByLevel[level] = List<bool>.of(prevFilled);
  }

  /// Clears tracking for ONE [level] (e.g. a fresh start of that level): its prior
  /// fills are forgotten and its fired set emptied, leaving other levels untouched.
  void resetLevel(CaptureLevel level) {
    _prevFilledByLevel.remove(level);
    _firedByLevel.remove(level);
  }

  /// Clears tracking for EVERY level — a full re-arm (e.g. a brand-new project).
  void reset() {
    _prevFilledByLevel.clear();
    _firedByLevel.clear();
  }
}
