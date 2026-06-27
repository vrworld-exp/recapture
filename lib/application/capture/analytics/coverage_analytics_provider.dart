// lib/application/capture/analytics/coverage_analytics_provider.dart
//
// Wires the [CoverageAnalyticsTracker] as an EXTERNAL observer of the segment
// coverage state — the pure [SegmentCoverage] model + its notifier stay
// analytics-free. Reading/watching this provider activates the listeners; the
// capture screen should `ref.watch` it for the duration of a capture session so
// the events fire as captures fill segments.
//
// ALL LEVELS, not just A: the live capture flow reuses the SAME segment-coverage
// notifier across Levels A/B/C (the capture screen is parameterized per level),
// and the active level comes from [captureLevelSessionProvider]. So this one
// observer covers every level — it tags each event with the session's level AND
// keys the tracker's once-tracking by that level, so B's and C's milestones fire
// independently of A's (and of each other).
//
// RESUME-SAFE: on a new session it seeds the tracker for that level from the
// PERSISTED per-level fired-milestones (in the progression controller) + the
// current (restored) coverage mask, so resuming a partially-covered level does
// NOT re-fire milestones it already crossed or re-emit `segment_filled` for
// already-filled segments. After each change it writes the level's fired set back
// to the controller (best-effort) so the persistence stays current.
//
// NOTE: this is the integration seam. The capture→coverage write path
// (segmentCoverageProvider.recordCapture on an accepted capture) is owned by a
// separate wiring task, so today this observer is dormant in-app until that lands
// — it is fully exercised in tests by driving the coverage notifier directly.
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../domain/entities/capture_readiness.dart' show CaptureMode;
import '../guidance_engine.dart' show captureModeProvider;
import '../progression/level_progression_provider.dart';
import '../segment_coverage_provider.dart';
import 'capture_level_events.dart';
import 'capture_level_session.dart';
import 'coverage_analytics_tracker.dart';

/// Activates the coverage-analytics observer. Listens to [segmentCoverageProvider]
/// transitions (so the model stays pure) and re-arms/seeds the tracker per level
/// when the analytics session changes. Returns the tracker (mostly for tests); the
/// value matters less than the side-effect of the registered listeners.
final coverageAnalyticsObserverProvider =
    Provider<CoverageAnalyticsTracker>((ref) {
  final tracker = CoverageAnalyticsTracker();

  /// Seeds [session]'s level from the persisted progression + current coverage so
  /// a resumed level does not re-fire its already-passed milestones / fills.
  void seedFor(CaptureLevelSession? session) {
    if (session == null) return;
    final levelId = pitchBandIdForLevel(session.level);
    final persisted = ref
        .read(levelProgressionControllerProvider)
        ?.stateForId(levelId)
        ?.firedMilestones;
    tracker.seedLevel(
      level: session.level,
      firedMilestones: persisted ?? const <int>{},
      prevFilled: ref.read(segmentCoverageProvider).filled,
    );
  }

  // Seed for the session already in progress when this observer is first read
  // (the listen below only fires on subsequent changes).
  seedFor(ref.read(captureLevelSessionProvider));

  // New analytics session → re-arm that level fresh, then seed from persistence.
  ref.listen<CaptureLevelSession?>(captureLevelSessionProvider, (prev, next) {
    if (prev?.sessionId == next?.sessionId) return;
    if (next != null) {
      tracker.resetLevel(next.level);
      seedFor(next);
    }
  });

  // Observe coverage transitions from the outside — emission context is pulled
  // from the session + capture-mode providers at emit time.
  ref.listen(segmentCoverageProvider, (prev, next) {
    final session = ref.read(captureLevelSessionProvider);
    final level = session?.level ?? CaptureLevel.a;
    final mode = ref.read(captureModeProvider);
    tracker.onCoverageChanged(
      next,
      level: level,
      projectId: session?.projectId ?? '',
      sessionId: session?.sessionId ?? '',
      captureMode: mode == CaptureMode.manual ? 'manual' : 'guided',
      deviceType:
          defaultTargetPlatform == TargetPlatform.iOS ? 'ios' : 'android',
    );
    // Persist this level's fired milestones so a later resume won't re-fire them.
    // Best-effort + a no-op when unchanged (recordLevelProgress skips an equal
    // update); never blocks the capture path.
    ref.read(levelProgressionControllerProvider.notifier).recordLevelProgress(
          pitchBandIdForLevel(level),
          firedMilestones: tracker.firedMilestonesFor(level),
        );
  });

  return tracker;
});
