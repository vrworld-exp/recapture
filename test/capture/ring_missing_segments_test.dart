// test/capture/ring_missing_segments_test.dart
//
// QA INVARIANT: while Level A coverage is BELOW the completion threshold
// (CaptureConfig.minCoveragePct, default 80%), the ring map shows which segments
// are still MISSING (uncaptured) vs FILLED (captured) vs TARGET (current), and the
// level does NOT auto-complete. Fully faked — no camera, sensors, network, or real
// files; states are constructed directly.
//
// ASSERTION SEAM (no test-only seam added): the ring map's painter consumes
// `RingCoverage.stateOf(i)` DIRECTLY (ring_coverage_map.dart paint() line ~211), so
// asserting `stateOf` per index is faithful to exactly what each segment paints —
// no @visibleForTesting accessor or golden/pixel comparison is needed. We pair that
// with a render test (the map builds + the X/N readout matches) and a gate-driven
// no-completion check.
//
// NO-COMPLETION below threshold is asserted via the REAL completion gate
// (`evaluateLevelAFromCoverage`) driving a tiny `_RingHud` harness (ring map when
// incomplete, the real LevelACompleteScreen when complete) — the same composition
// the not-yet-wired capture-screen glue must use (see the ring-auto-complete sibling
// test / the flagged coverage→navigation gap). No production behavior is changed.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:recapture/application/capture/analytics/capture_level_events.dart';
import 'package:recapture/application/capture/analytics/capture_level_session.dart';
import 'package:recapture/domain/capture/level_completion.dart';
import 'package:recapture/domain/entities/capture_config.dart';
import 'package:recapture/domain/entities/capture_progress.dart';
import 'package:recapture/domain/entities/level_a_summary.dart';
import 'package:recapture/domain/entities/ring_coverage.dart';
import 'package:recapture/domain/entities/segment_coverage.dart';
import 'package:recapture/presentation/screens/capture/level_a_complete_screen.dart';
import 'package:recapture/presentation/widgets/ring_coverage_map.dart';
import 'package:recapture/utils/analytics.dart';

/// The completion threshold read from the (bundled-default) config — NOT a hardcoded
/// 80, so the test tracks the config if it changes.
final double _threshold =
    CaptureConfig.bundledDefault.thresholds.minCoveragePct;

List<SegmentState> _states(RingCoverage r) =>
    List<SegmentState>.generate(r.segmentCount, r.stateOf);

int _count(RingCoverage r, SegmentState s) =>
    _states(r).where((x) => x == s).length;

/// The set of indices in a given [SegmentState] (handy for exact-set assertions).
Set<int> _indices(RingCoverage r, SegmentState s) => {
      for (var i = 0; i < r.segmentCount; i++)
        if (r.stateOf(i) == s) i,
    };

/// Maps a [RingCoverage] (display model) onto a [SegmentCoverage] (the gate's
/// source of truth): in-range filled indices → one capture each.
SegmentCoverage _segmentCoverage(RingCoverage r) => SegmentCoverage.of(
      segmentCount: r.segmentCount,
      fillCounts:
          List<int>.generate(r.segmentCount, (i) => r.filledIndices.contains(i) ? 1 : 0),
    );

/// The real completion decision for a ring state at [minCoveragePct].
LevelCompletion _completion(RingCoverage r, {required double minCoveragePct}) =>
    evaluateLevelAFromCoverage(
      _segmentCoverage(r),
      acceptedCount: r.filledCount,
      // Coverage is the decider below threshold (AND-gate); keep the count gate
      // trivially satisfied so we isolate the coverage criterion.
      minAcceptedCount: 1,
      minCoveragePct: minCoveragePct,
    );

/// The HUD the user sees: while incomplete, the ring map (with missing segments);
/// once complete, the real completion screen. Stands in for the capture-screen
/// coverage→navigation glue (not yet wired) so the no-completion assertion runs
/// against the REAL gate + REAL completion screen.
class _RingHud extends StatelessWidget {
  const _RingHud({required this.ring, required this.minCoveragePct});

  final RingCoverage ring;
  final double minCoveragePct;

  @override
  Widget build(BuildContext context) {
    final complete = _completion(ring, minCoveragePct: minCoveragePct).isComplete;
    if (complete) {
      return LevelACompleteScreen(
        summary: LevelASummary(
          accepted: ring.filledCount,
          target: ring.segmentCount,
          coveragePct: ring.progress * 100,
        ),
        onStartLevelB: () {},
        onReview: () {},
      );
    }
    return Scaffold(
      body: Stack(children: [RingCoverageMap(coverage: ring)]),
    );
  }
}

void main() {
  // ── Representative sub-threshold partial states (N = 10, threshold 80%) ──────
  // 70%: contiguous 0..6 filled, 7 current target, 8/9 still missing.
  const partial70 = RingCoverage(
    segmentCount: 10,
    filledIndices: {0, 1, 2, 3, 4, 5, 6},
    targetIndex: 7,
  );
  // 50%: NON-CONTIGUOUS fill with a gap at 3, target at 3.
  const gappy50 = RingCoverage(
    segmentCount: 10,
    filledIndices: {0, 1, 2, 4, 5},
    targetIndex: 3,
  );
  // 30%, NO current target (resolver hasn't picked one yet).
  const noTarget30 = RingCoverage(
    segmentCount: 10,
    filledIndices: {0, 1, 2},
  );
  // 0%: nothing captured yet.
  const allMissing = RingCoverage(segmentCount: 10);

  group('per-segment state (stateOf) below threshold', () {
    test('contiguous 7/10: 0–6 filled, 7 target, 8–9 missing', () {
      for (var i = 0; i <= 6; i++) {
        expect(partial70.stateOf(i), SegmentState.filled, reason: 'index $i');
      }
      expect(partial70.stateOf(7), SegmentState.target);
      expect(partial70.stateOf(8), SegmentState.missing);
      expect(partial70.stateOf(9), SegmentState.missing);

      // Missing is DISTINCT from target: 2 strictly-missing, 1 target.
      expect(_indices(partial70, SegmentState.missing), {8, 9});
      expect(_count(partial70, SegmentState.missing), 2);
      expect(_count(partial70, SegmentState.target), 1);
      expect(partial70.filledCount, 7);
      // Total still-to-capture (target + missing) = N − filled.
      expect(10 - partial70.filledCount, 3);
    });

    test('non-contiguous 5/10: gaps detected regardless of position', () {
      // The hole at 3 is the target; 6,7,8,9 are missing — missing detection must
      // not assume the filled run is contiguous.
      expect(gappy50.stateOf(3), SegmentState.target);
      expect(_indices(gappy50, SegmentState.filled), {0, 1, 2, 4, 5});
      expect(_indices(gappy50, SegmentState.missing), {6, 7, 8, 9});
      expect(_count(gappy50, SegmentState.missing), 4);
      expect(gappy50.filledCount, 5);
    });

    test('null target: only filled / missing, no target state, no crash', () {
      expect(noTarget30.effectiveTarget, isNull);
      expect(_count(noTarget30, SegmentState.target), 0);
      expect(_indices(noTarget30, SegmentState.filled), {0, 1, 2});
      expect(_count(noTarget30, SegmentState.missing), 7);
    });

    test('zero captured: every segment missing', () {
      expect(_count(allMissing, SegmentState.missing), 10);
      expect(_count(allMissing, SegmentState.filled), 0);
      expect(_count(allMissing, SegmentState.target), 0);
      expect(allMissing.filledCount, 0);
    });

    test('out-of-range filled/target are ignored defensively (no inflation)', () {
      const stale = RingCoverage(
        segmentCount: 10,
        filledIndices: {0, 1, 2, 12, -1}, // 12 and -1 are stale
        targetIndex: 99, // out of range
      );
      expect(stale.filledCount, 3, reason: 'only 0,1,2 are in range');
      expect(stale.effectiveTarget, isNull);
      expect(_count(stale, SegmentState.target), 0);
      // The two stale indices never appear as filled in the painted range.
      expect(_indices(stale, SegmentState.filled), {0, 1, 2});
      expect(_count(stale, SegmentState.missing), 7);
    });
  });

  group('below threshold → not complete (real gate + meter, threshold from config)',
      () {
    test('config threshold is the 80% gate', () {
      expect(_threshold, 80);
    });

    for (final entry in <String, RingCoverage>{
      '70%': partial70,
      '50% gappy': gappy50,
      '30% no-target': noTarget30,
      '0% all-missing': allMissing,
    }.entries) {
      test('${entry.key} is below threshold and does NOT complete', () {
        final r = entry.value;
        // Coverage really is under the configured threshold.
        expect(r.progress * 100, lessThan(_threshold));
        // Canonical completion gate says not complete.
        expect(_completion(r, minCoveragePct: _threshold).isComplete, isFalse);
        // The progress meter's own completion view agrees (HUD elements consistent).
        final progress =
            CaptureProgress.fromCoverage(r, completeAtPct: _threshold);
        expect(progress.isComplete, isFalse);
        // Meter numbers track the ring map exactly (single source of truth).
        expect(progress.accepted, r.filledCount);
        expect(progress.target, r.segmentCount);
        expect(progress.coveragePct, closeTo(r.progress * 100, 1e-9));
      });
    }
  });

  group('ring map renders the partial state (the HUD the user sees)', () {
    Future<void> pumpMap(WidgetTester tester, RingCoverage r) async {
      await tester.pumpWidget(
        MaterialApp(
          home: MediaQuery(
            data: const MediaQueryData(disableAnimations: true),
            child: Scaffold(body: Stack(children: [RingCoverageMap(coverage: r)])),
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('70% map builds; X/N readout reflects filled vs missing',
        (tester) async {
      await pumpMap(tester, partial70);
      expect(find.byType(RingCoverageMap), findsOneWidget);
      // 7 filled of 10 → 3 still to capture; the readout is the user-visible proof.
      expect(find.text('7/10'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('non-contiguous + all-missing maps build without error',
        (tester) async {
      await pumpMap(tester, gappy50);
      expect(find.text('5/10'), findsOneWidget);
      await pumpMap(tester, allMissing);
      expect(find.text('0/10'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });

  group('no completion screen / no analytics below threshold', () {
    final completed = <Map<String, Object?>>[];
    setUp(() {
      completed.clear();
      Analytics.testSink = (name, props) {
        if (name == AnalyticsEvents.captureLevelCompleted) completed.add({...props});
      };
    });
    tearDown(() => Analytics.testSink = null);

    Future<void> pumpHud(WidgetTester tester, RingCoverage r,
        {ProviderContainer? container}) async {
      final c = container ?? ProviderContainer();
      if (container == null) addTearDown(c.dispose);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: c,
          child: MaterialApp(
            home: MediaQuery(
              data: const MediaQueryData(disableAnimations: true),
              child: _RingHud(ring: r, minCoveragePct: _threshold),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('partial states: ring map shown, no LevelACompleteScreen, no event',
        (tester) async {
      for (final r in [partial70, gappy50, noTarget30, allMissing]) {
        await pumpHud(tester, r);
        expect(find.byType(RingCoverageMap), findsOneWidget,
            reason: 'HUD still present at ${(r.progress * 100).round()}%');
        expect(find.byType(LevelACompleteScreen), findsNothing);
      }
      expect(completed, isEmpty, reason: 'no capture_level_completed below threshold');
    });

    testWidgets('positive control: at/above threshold the SAME harness DOES '
        'complete (so the negative above is not vacuous)', (tester) async {
      // 8/10 = 80% (inclusive boundary) → complete. Start a session so the event
      // fires deterministically with a known id.
      const full = RingCoverage(
        segmentCount: 10,
        filledIndices: {0, 1, 2, 3, 4, 5, 6, 7},
      );
      expect(full.progress * 100, greaterThanOrEqualTo(_threshold));

      final container = ProviderContainer();
      addTearDown(container.dispose);
      container.read(captureLevelSessionProvider.notifier).start(
            level: CaptureLevel.a,
            projectId: 'proj-1',
            sessionId: 'sess-A',
            now: DateTime.now(),
          );

      await pumpHud(tester, full, container: container);
      expect(find.byType(LevelACompleteScreen), findsOneWidget);
      expect(find.byType(RingCoverageMap), findsNothing);
      expect(completed, hasLength(1));
      expect(completed.single['level'], 'A');
      expect(completed.single['coverage_pct'], 80);
    });
  });
}
