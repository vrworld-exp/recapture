// test/capture/progression/level_progression_provider_test.dart
//
// The reactive controller around the pure core, with an in-memory fake store (no
// Hive). Covers: start builds A→B→C from config + persists; advance is gated (no
// skip) and persists on success; recordLevelProgress drives completion + the
// un-complete edge; resume restores from the store (incl. mid-level partial
// coverage) and reconciles with config; corrupt persisted state recovers fresh.
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:recapture/application/capture/analytics/capture_level_events.dart';
import 'package:recapture/application/capture/analytics/capture_level_session.dart';
import 'package:recapture/application/capture/analytics/coverage_analytics_provider.dart';
import 'package:recapture/application/capture/progression/level_progression.dart';
import 'package:recapture/application/capture/progression/level_progression_provider.dart';
import 'package:recapture/application/capture/progression/level_progression_store.dart';
import 'package:recapture/application/capture/segment_coverage_provider.dart';
import 'package:recapture/application/config/config_notifier.dart';
import 'package:recapture/domain/capture/capture_flow_variant.dart';
import 'package:recapture/domain/entities/capture_config.dart';
import 'package:recapture/domain/entities/segment_coverage.dart';
import 'package:recapture/utils/analytics.dart';

/// In-memory [LevelProgressionStore] — overrides the IO methods, no Hive.
class _FakeStore extends LevelProgressionStore {
  final Map<String, LevelProgression> saved = {};
  final Map<String, CaptureFlowVariant> variants = {};
  bool throwOnLoad = false;

  @override
  Future<void> save(String projectId, LevelProgression p, {int? savedAtMs}) async {
    saved[projectId] = p;
  }

  @override
  Future<LevelProgression?> load(String projectId) async {
    if (throwOnLoad) throw StateError('boom');
    return saved[projectId];
  }

  @override
  Future<void> clear(String projectId) async {
    saved.remove(projectId);
    variants.remove(projectId);
  }

  @override
  Future<void> saveVariant(String projectId, CaptureFlowVariant variant) async {
    variants[projectId] = variant;
  }

  @override
  Future<CaptureFlowVariant> loadVariant(String projectId) async =>
      variants[projectId] ?? CaptureFlowVariant.withBottom;
}

class _StubConfig extends ConfigNotifier {
  @override
  CaptureConfig build() => CaptureConfig.bundledDefault;
}

ProviderContainer _container(_FakeStore store) {
  final c = ProviderContainer(overrides: [
    levelProgressionStoreProvider.overrideWithValue(store),
    captureConfigProvider.overrideWith(_StubConfig.new),
  ]);
  addTearDown(c.dispose);
  return c;
}

void main() {
  test('start builds A→B→C from config and persists', () async {
    final store = _FakeStore();
    final c = _container(store);
    final ctrl = c.read(levelProgressionControllerProvider.notifier);

    await ctrl.start('p1');
    final p = c.read(levelProgressionControllerProvider)!;
    expect(p.levels.map((l) => l.levelCode).toList(), ['A', 'B', 'C']);
    expect(p.currentLevelIndex, 0);
    expect(store.saved['p1'], isNotNull);
  });

  test('advance is gated (no skip) until the current level completes', () async {
    final store = _FakeStore();
    final c = _container(store);
    final ctrl = c.read(levelProgressionControllerProvider.notifier);
    await ctrl.start('p1');

    // A incomplete → rejected.
    expect(await ctrl.advance(), isFalse);
    expect(c.read(levelProgressionControllerProvider)!.currentLevelIndex, 0);

    // Complete A (mid: 16 segments under with_bottom) → advance succeeds, persists.
    await ctrl.recordLevelProgress('mid', filledCount: 16, acceptedCount: 16);
    expect(await ctrl.advance(), isTrue);
    expect(c.read(levelProgressionControllerProvider)!.currentLevel.levelCode, 'B');
    expect(store.saved['p1']!.currentLevelIndex, 1);
  });

  test('un-complete a prior level → overallComplete false, frontier holds', () async {
    final store = _FakeStore();
    final c = _container(store);
    final ctrl = c.read(levelProgressionControllerProvider.notifier);
    await ctrl.start('p1');

    // Complete all three (16 segments each under with_bottom), advancing to C.
    await ctrl.recordLevelProgress('mid', filledCount: 16, acceptedCount: 16);
    await ctrl.advance();
    await ctrl.recordLevelProgress('high', filledCount: 16, acceptedCount: 16);
    await ctrl.advance();
    await ctrl.recordLevelProgress('low', filledCount: 16, acceptedCount: 16);
    expect(ctrl.overallComplete, isTrue);

    // Delete drops B below the gate.
    await ctrl.recordLevelProgress('high', filledCount: 0, acceptedCount: 0);
    expect(ctrl.overallComplete, isFalse);
    expect(c.read(levelProgressionControllerProvider)!.currentLevel.levelCode, 'C');
    expect(ctrl.canReview('high'), isTrue);
  });

  test('resume restores frontier + mid-level partial coverage from the store',
      () async {
    final store = _FakeStore();
    // Simulate a prior session persisted at B with partial coverage.
    store.saved['p1'] = LevelProgression.of([
      const LevelProgressState(
          levelId: 'mid', levelCode: 'A', segmentCount: 16, filledCount: 16, acceptedCount: 16),
      const LevelProgressState(
          levelId: 'high', levelCode: 'B', segmentCount: 16, filledCount: 3, acceptedCount: 3),
      const LevelProgressState(levelId: 'low', levelCode: 'C', segmentCount: 16),
    ], currentLevelIndex: 1);

    final c = _container(store);
    final ctrl = c.read(levelProgressionControllerProvider.notifier);
    final restored = await ctrl.resume('p1');

    expect(restored.currentLevel.levelCode, 'B');
    expect(restored.stateForId('high')!.filledCount, 3); // partial coverage kept
    expect(restored.stateForId('mid')!.isComplete, isTrue); // A intact
  });

  test('corrupt/missing persisted state → fresh start, no crash', () async {
    final store = _FakeStore()..throwOnLoad = true;
    final c = _container(store);
    final ctrl = c.read(levelProgressionControllerProvider.notifier);

    final restored = await ctrl.resume('p1');
    expect(restored.currentLevelIndex, 0);
    expect(restored.levels.map((l) => l.levelCode).toList(), ['A', 'B', 'C']);
  });

  test('recordLevelProgress persists per-level fired milestones', () async {
    final store = _FakeStore();
    final c = _container(store);
    final ctrl = c.read(levelProgressionControllerProvider.notifier);
    await ctrl.start('p1');

    await ctrl.recordLevelProgress('high', firedMilestones: {25, 50});
    expect(
      c.read(levelProgressionControllerProvider)!.stateForId('high')!.firedMilestones,
      {25, 50},
    );
    expect(store.saved['p1']!.stateForId('high')!.firedMilestones, {25, 50});
  });

  // End-to-end: the coverage observer reads its per-level fired-tracking from the
  // progression controller on a new session, so RESUMING a partially-covered level
  // does NOT re-fire the milestones it already crossed (only new ones fire).
  test('observer resume: seeded milestones do not re-fire; new ones do', () async {
    final events = <(String, Map<String, Object?>)>[];
    Analytics.testSink = (n, p) => events.add((n, p));
    addTearDown(() => Analytics.testSink = null);

    final store = _FakeStore();
    final c = _container(store);
    final ctrl = c.read(levelProgressionControllerProvider.notifier);

    // A prior run of Level B (band "high") reached 50% and persisted {25,50}.
    await ctrl.start('p1');
    await ctrl.recordLevelProgress('high', firedMilestones: {25, 50});

    // Restore Level B's partial coverage (2/4 filled) BEFORE the observer reads,
    // so the observer seeds prevFilled from it (no spurious segment_filled).
    c.read(segmentCoverageProvider.notifier).restore(
          SegmentCoverage.initial(segmentCount: 4)
              .recordCapture(0)
              .recordCapture(1),
        );

    // Activate the observer, then (re)enter the Level B session → seeds from
    // the persisted progression for band "high".
    c.read(coverageAnalyticsObserverProvider);
    c.read(captureLevelSessionProvider.notifier).start(
        level: CaptureLevel.b, projectId: 'p1', sessionId: 'resume_B');

    // Continue capturing → 3/4 = 75%. Only 75 should fire; 25/50 stay quiet.
    c.read(segmentCoverageProvider.notifier).recordCapture(2);

    final milestones = events
        .where((e) => e.$1 == AnalyticsEvents.coverageMilestone)
        .map((e) => e.$2['milestone'])
        .toList();
    expect(milestones, [75], reason: '25/50 were seeded from persistence');

    final fills =
        events.where((e) => e.$1 == AnalyticsEvents.segmentFilled).toList();
    expect(fills, hasLength(1));
    expect(fills.single.$2['segment_index'], 2);
    expect(fills.single.$2['level'], 'B');

    // The newly-crossed milestone is persisted back for the next resume.
    expect(
      c.read(levelProgressionControllerProvider)!.stateForId('high')!.firedMilestones,
      {25, 50, 75},
    );
  });
}
