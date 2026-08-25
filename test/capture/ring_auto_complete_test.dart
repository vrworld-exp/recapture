// test/capture/ring_auto_complete_test.dart
//
// QA INVARIANT: 360° eye-ring fully covered → Level A auto-completes — the
// completion screen is shown and `capture_level_completed` fires EXACTLY ONCE;
// one segment short does NOT complete; staying at/above the threshold does not
// re-fire. Fully faked: no camera, sensors, network, or real files.
//
// ──────────────────────────────────────────────────────────────────────────────
// IMPORTANT — what is and isn't wired (flagged per the task's "do not implement
// completion logic here, flag missing seams" rule):
//
//   • The pure DECISION exists and is production code: `evaluateLevelAFromCoverage`
//     (lib/domain/capture/level_completion.dart) over `SegmentCoverage` (the
//     coverage source of truth) — coverage(filled ≥ minCoveragePct%) AND
//     accepted ≥ minAcceptedCount.
//   • The completion OUTCOME exists and is production code: `LevelACompleteScreen`
//     fires `capture_level_completed` once on show, latched per-session by
//     `captureLevelSessionProvider.claimCompletion()`.
//   • The GLUE that watches live coverage in `CaptureScreen` and NAVIGATES to the
//     completion screen on full coverage is NOT built yet: `CaptureScreen` advances
//     on a hardcoded demo counter (`_captureCount >= 5`) and its ring-coverage HUD
//     is unwired (no filled segments). The "ring-progress resolver" is an explicit
//     later task in that file's comments.
//
// So this test composes the REAL production units (gate + SegmentCoverage + session
// latch + completion screen + analytics) the way that glue MUST compose them, via a
// tiny test-only harness (`_RingFlow`) standing in for the unbuilt navigation. It
// changes NO production behavior — it pins the contract the glue has to satisfy.
// When the capture-screen coverage→navigation wiring lands, the assertions here are
// exactly what an end-to-end `CaptureScreen` test should also hold.
// ──────────────────────────────────────────────────────────────────────────────
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:recapture/application/capture/analytics/capture_level_events.dart';
import 'package:recapture/application/capture/analytics/capture_level_session.dart';
import 'package:recapture/domain/capture/level_completion.dart';
import 'package:recapture/domain/entities/level_a_summary.dart';
import 'package:recapture/domain/entities/segment_coverage.dart';
import 'package:recapture/presentation/screens/capture/level_a_complete_screen.dart';
import 'package:recapture/utils/analytics.dart';

/// Drives a [SegmentCoverage] + accepted count and, on each tick, runs the REAL
/// completion gate. Complete → renders the REAL [LevelACompleteScreen]; not
/// complete → a keyed capture-HUD stand-in. This is the seam the not-yet-built
/// capture-screen coverage→navigation glue will own; here the test drives it.
class _RingFlow extends ConsumerWidget {
  const _RingFlow({
    required this.coverage,
    required this.accepted,
    required this.rejected,
    required this.minCoveragePct,
    required this.minAcceptedCount,
  });

  final ValueListenable<SegmentCoverage> coverage;
  final ValueListenable<int> accepted;
  final ValueListenable<int> rejected;
  final double minCoveragePct;
  final int minAcceptedCount;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return AnimatedBuilder(
      animation: Listenable.merge([coverage, accepted, rejected]),
      builder: (context, _) {
        final cov = coverage.value;
        final completion = evaluateLevelAFromCoverage(
          cov,
          acceptedCount: accepted.value,
          minAcceptedCount: minAcceptedCount,
          minCoveragePct: minCoveragePct,
        );
        if (!completion.isComplete) {
          // The live capture HUD (shutter/ring map) — replaced on completion.
          return const Scaffold(
            key: Key('capture_hud'),
            body: Center(child: Text('capturing')),
          );
        }
        return LevelACompleteScreen(
          // Stable key: while coverage stays complete, Flutter reuses this State,
          // so initState (the event emit) runs once — not per rebuild.
          key: const ValueKey('complete'),
          summary: LevelASummary(
            accepted: accepted.value,
            target: cov.segmentCount,
            coveragePct: completion.coverageRatio * 100,
            rejected: rejected.value,
          ),
          onStartLevelB: () {},
          onReview: () {},
        );
      },
    );
  }
}

/// A tiny driver: holds the mutable coverage/accepted/rejected the test ticks.
class _Driver {
  _Driver({required int segmentCount})
      : coverage = ValueNotifier(SegmentCoverage.initial(segmentCount: segmentCount)),
        accepted = ValueNotifier(0),
        rejected = ValueNotifier(0);

  final ValueNotifier<SegmentCoverage> coverage;
  final ValueNotifier<int> accepted;
  final ValueNotifier<int> rejected;

  /// An ACCEPTED capture of segment [i]: fills the segment AND counts as accepted.
  void captureAccepted(int i) {
    coverage.value = coverage.value.recordCapture(i);
    accepted.value += 1;
  }

  /// A REJECTED capture: by the acceptance model it neither fills a segment nor
  /// counts as accepted — it only bumps the discarded tally.
  void captureRejected() => rejected.value += 1;

  void dispose() {
    coverage.dispose();
    accepted.dispose();
    rejected.dispose();
  }
}

void main() {
  /// Records every `capture_level_completed` payload via the analytics test sink.
  late List<Map<String, Object?>> completed;

  setUp(() {
    completed = [];
    Analytics.testSink = (name, props) {
      if (name == AnalyticsEvents.captureLevelCompleted) completed.add({...props});
    };
  });
  tearDown(() => Analytics.testSink = null);

  /// Pumps [_RingFlow] in an [UncontrolledProviderScope] over [container] (so the
  /// completion screen shares the started session + its once-per-session latch),
  /// with animations disabled (the celebrate anim is static → no pending timers).
  Future<void> pumpFlow(
    WidgetTester tester,
    ProviderContainer container,
    _Driver d, {
    double minCoveragePct = 80,
    int minAcceptedCount = 1,
  }) async {
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          home: Builder(
            builder: (ctx) => MediaQuery(
              data: MediaQuery.of(ctx).copyWith(disableAnimations: true),
              child: _RingFlow(
                coverage: d.coverage,
                accepted: d.accepted,
                rejected: d.rejected,
                minCoveragePct: minCoveragePct,
                minAcceptedCount: minAcceptedCount,
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
  }

  /// A container with a deterministic, started analytics session so the emitted
  /// `capture_level_completed` carries a known session_id (and a real, >= 0
  /// duration) — exercising the funnel stitch, not just the empty-session path.
  ProviderContainer startedContainer(WidgetTester tester) {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    container.read(captureLevelSessionProvider.notifier).start(
          level: CaptureLevel.a,
          projectId: 'proj-1',
          sessionId: 'sess-A',
          now: DateTime.now(),
        );
    return container;
  }

  group('full coverage → auto-completes', () {
    testWidgets('all N segments → completion screen shown, HUD replaced, '
        'capture_level_completed fires once with correct props', (tester) async {
      final container = startedContainer(tester);
      final d = _Driver(segmentCount: 4);
      addTearDown(d.dispose);
      await pumpFlow(tester, container, d, minAcceptedCount: 4);

      // Incomplete at start: HUD present, no completion, no event.
      expect(find.byKey(const Key('capture_hud')), findsOneWidget);
      expect(find.byType(LevelACompleteScreen), findsNothing);
      expect(completed, isEmpty);

      // Drive 0 → full coverage, one accepted capture per segment.
      for (var i = 0; i < 4; i++) {
        d.captureAccepted(i);
        await tester.pump();
      }
      await tester.pumpAndSettle();

      // Auto-completed: completion screen up, capture HUD gone.
      expect(find.byType(LevelACompleteScreen), findsOneWidget);
      expect(find.byKey(const Key('capture_hud')), findsNothing);
      expect(find.text('Level A complete'), findsOneWidget);
      // Summary reflects the coverage source: accepted == target, 100% coverage.
      expect(find.text('4/4'), findsOneWidget);
      expect(find.text('100%'), findsOneWidget);

      // Exactly one event, correct props, no PII.
      expect(completed, hasLength(1));
      final e = completed.single;
      expect(e['level'], 'A');
      expect(e['accepted'], 4);
      expect(e['target'], 4);
      expect(e['coverage_pct'], 100);
      expect(e['session_id'], 'sess-A');
      expect(e['project_id'], 'proj-1');
      expect((e['duration_seconds'] as int) >= 0, isTrue);
      _expectNoPii(e);
    });

    testWidgets('over-capture (more accepted than target) still completes once',
        (tester) async {
      final container = startedContainer(tester);
      final d = _Driver(segmentCount: 4);
      addTearDown(d.dispose);
      await pumpFlow(tester, container, d, minAcceptedCount: 4);

      for (var i = 0; i < 4; i++) {
        d.captureAccepted(i);
        await tester.pump();
      }
      // Extra accepted shots arrive AFTER completion (re-capturing filled segments).
      d.captureAccepted(0);
      await tester.pump();
      d.captureAccepted(1);
      await tester.pumpAndSettle();

      expect(find.byType(LevelACompleteScreen), findsOneWidget);
      expect(completed, hasLength(1), reason: 'no duplicate completion event');
      // The event latches the COMPLETION-MOMENT count (4 — when the ring first
      // completed), not the later over-captured total; the extra shots only
      // re-render the screen, they do not re-fire the event.
      expect(completed.single['accepted'], 4);
      expect(completed.single['target'], 4);
    });
  });

  group('near-miss (N−1) → does NOT complete', () {
    testWidgets('one segment short: no completion screen, no event',
        (tester) async {
      final container = startedContainer(tester);
      final d = _Driver(segmentCount: 4);
      addTearDown(d.dispose);
      await pumpFlow(tester, container, d, minAcceptedCount: 4);

      // Fill only 3 of 4 (80% of 4 needs all 4 → 3 is short).
      for (var i = 0; i < 3; i++) {
        d.captureAccepted(i);
        await tester.pump();
      }
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('capture_hud')), findsOneWidget);
      expect(find.byType(LevelACompleteScreen), findsNothing);
      expect(completed, isEmpty);
    });

    testWidgets('rejected last shot does NOT count toward coverage → no complete',
        (tester) async {
      final container = startedContainer(tester);
      final d = _Driver(segmentCount: 4);
      addTearDown(d.dispose);
      await pumpFlow(tester, container, d, minAcceptedCount: 4);

      // 3 accepted fills, then the 4th attempt is REJECTED (no fill, not accepted).
      for (var i = 0; i < 3; i++) {
        d.captureAccepted(i);
        await tester.pump();
      }
      d.captureRejected();
      await tester.pumpAndSettle();

      // Coverage is still 3/4 → not complete; the reject didn't fill segment 3.
      expect(find.byType(LevelACompleteScreen), findsNothing);
      expect(find.byKey(const Key('capture_hud')), findsOneWidget);
      expect(completed, isEmpty);
    });
  });

  group('coverage threshold boundary (minCoveragePct = 80, N = 5)', () {
    testWidgets('exactly at threshold (4/5) completes; just below (3/5) does not',
        (tester) async {
      // Just below: 3/5 = 60% < 80% → no completion.
      final c1 = startedContainer(tester);
      final below = _Driver(segmentCount: 5);
      addTearDown(below.dispose);
      await pumpFlow(tester, c1, below, minAcceptedCount: 1);
      for (var i = 0; i < 3; i++) {
        below.captureAccepted(i);
        await tester.pump();
      }
      await tester.pumpAndSettle();
      expect(find.byType(LevelACompleteScreen), findsNothing);
      expect(completed, isEmpty);

      // Exactly at threshold: 4/5 = 80% (inclusive) → completes, fires once.
      final c2 = startedContainer(tester);
      final at = _Driver(segmentCount: 5);
      addTearDown(at.dispose);
      await pumpFlow(tester, c2, at, minAcceptedCount: 1);
      for (var i = 0; i < 4; i++) {
        at.captureAccepted(i);
        await tester.pump();
      }
      await tester.pumpAndSettle();
      expect(find.byType(LevelACompleteScreen), findsOneWidget);
      expect(completed, hasLength(1));
      expect(completed.single['coverage_pct'], 80);
    });
  });

  group('idempotency (latch holds at/above threshold)', () {
    testWidgets('extra ticks while staying complete do not re-fire or re-push',
        (tester) async {
      final container = startedContainer(tester);
      final d = _Driver(segmentCount: 4);
      addTearDown(d.dispose);
      await pumpFlow(tester, container, d, minAcceptedCount: 4);

      for (var i = 0; i < 4; i++) {
        d.captureAccepted(i);
        await tester.pump();
      }
      await tester.pumpAndSettle();
      expect(completed, hasLength(1));

      // Several more state ticks at full coverage (re-capturing filled segments).
      for (var i = 0; i < 5; i++) {
        d.captureAccepted(i % 4);
        await tester.pump();
      }
      await tester.pumpAndSettle();

      expect(find.byType(LevelACompleteScreen), findsOneWidget);
      expect(completed, hasLength(1), reason: 'completion event did not re-fire');
    });

    testWidgets('dropping below then back to full re-mounts the screen for the '
        'SAME session but does NOT re-fire (session latch)', (tester) async {
      final container = startedContainer(tester);
      final d = _Driver(segmentCount: 4);
      addTearDown(d.dispose);
      await pumpFlow(tester, container, d, minAcceptedCount: 4);

      for (var i = 0; i < 4; i++) {
        d.captureAccepted(i);
        await tester.pump();
      }
      await tester.pumpAndSettle();
      expect(completed, hasLength(1));
      expect(find.byType(LevelACompleteScreen), findsOneWidget);

      // Drop coverage below threshold → completion screen unmounts (HUD returns).
      d.coverage.value = d.coverage.value.removeCapture(3);
      await tester.pumpAndSettle();
      expect(find.byType(LevelACompleteScreen), findsNothing);
      expect(find.byKey(const Key('capture_hud')), findsOneWidget);

      // Back to full → the completion screen re-mounts (fresh initState) for the
      // SAME session. The per-session latch suppresses a second emit.
      d.captureAccepted(3);
      await tester.pumpAndSettle();
      expect(find.byType(LevelACompleteScreen), findsOneWidget);
      expect(completed, hasLength(1),
          reason: 'session latch: re-entry of completion does not double-count');
    });
  });
}

/// Asserts a completion payload carries no raw PII / image / path / location key.
void _expectNoPii(Map<String, Object?> props) {
  const banned = [
    'email', 'phone', 'name', 'token', 'path', 'image', 'file', 'lat', 'lng',
    'location'
  ];
  for (final k in props.keys) {
    for (final b in banned) {
      expect(k.toLowerCase().contains(b), isFalse, reason: '$k ~ $b');
    }
  }
}
