// test/capture/coverage_analytics_tracker_test.dart
//
// The once-semantics observer: segment_filled fires only on an unfilled→filled
// transition (threshold-aware, never on overfill); coverage_milestone fires once
// per 25/50/75/100% crossing (multi-crossing in one update, non-integer boundary,
// no re-fire after a drop); reset re-arms; emission is fire-and-forget. Plus the
// provider wiring drives it from segmentCoverageProvider while the model stays pure.
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:recapture/application/capture/analytics/capture_level_events.dart';
import 'package:recapture/application/capture/analytics/coverage_analytics_provider.dart';
import 'package:recapture/application/capture/analytics/coverage_analytics_tracker.dart';
import 'package:recapture/application/capture/analytics/capture_level_session.dart';
import 'package:recapture/application/capture/segment_coverage_provider.dart';
import 'package:recapture/application/config/config_notifier.dart';
import 'package:recapture/domain/entities/capture_config.dart';
import 'package:recapture/domain/entities/segment_coverage.dart';
import 'package:recapture/utils/analytics.dart';

class _StubConfigNotifier extends ConfigNotifier {
  @override
  CaptureConfig build() => CaptureConfig.bundledDefault;
}

void main() {
  late List<CaptureLevelEvent> emitted;
  late CoverageAnalyticsTracker tracker;

  setUp(() {
    emitted = [];
    tracker = CoverageAnalyticsTracker(emit: emitted.add);
  });

  void observe(SegmentCoverage c) => tracker.onCoverageChanged(
        c,
        level: CaptureLevel.a,
        projectId: 'proj',
        sessionId: 'sess',
        captureMode: 'guided',
        deviceType: 'android',
      );

  List<CaptureLevelEvent> ofName(String n) =>
      emitted.where((e) => e.name == n).toList();
  List<int> firedMilestones() => ofName(AnalyticsEvents.coverageMilestone)
      .map((e) => e.properties['milestone'] as int)
      .toList();

  group('segment_filled (transition-only)', () {
    test('fires once per segment as it fills (fillThreshold = 1)', () {
      var c = SegmentCoverage.initial(segmentCount: 4);
      observe(c); // baseline, nothing filled
      c = c.recordCapture(0);
      observe(c);
      c = c.recordCapture(2);
      observe(c);

      final fills = ofName(AnalyticsEvents.segmentFilled);
      expect(fills, hasLength(2));
      expect(fills[0].properties['segment_index'], 0);
      expect(fills[1].properties['segment_index'], 2);
    });

    test('overfilling an already-filled segment does NOT re-emit', () {
      var c = SegmentCoverage.initial(segmentCount: 4).recordCapture(0);
      observe(c);
      c = c.recordCapture(0); // overfill
      observe(c);

      expect(ofName(AnalyticsEvents.segmentFilled), hasLength(1));
    });

    test('fillThreshold > 1: fires when the count REACHES threshold', () {
      var c = SegmentCoverage.of(segmentCount: 4, fillThreshold: 2);
      observe(c);
      c = c.recordCapture(1); // count 1 → not yet filled
      observe(c);
      expect(ofName(AnalyticsEvents.segmentFilled), isEmpty);

      c = c.recordCapture(1); // count 2 → filled
      observe(c);
      expect(ofName(AnalyticsEvents.segmentFilled), hasLength(1));
      expect(
          ofName(AnalyticsEvents.segmentFilled).single.properties['segment_index'],
          1);
    });
  });

  group('coverage_milestone (crossing-once)', () {
    test('fires once at 25/50/75/100% in order, never twice while above', () {
      var c = SegmentCoverage.initial(segmentCount: 12);
      observe(c);
      for (var i = 0; i < 12; i++) {
        c = c.recordCapture(i);
        observe(c);
      }
      expect(firedMilestones(), [25, 50, 75, 100]);
    });

    test('a single fill crosses multiple milestones (small segmentCount)', () {
      var c = SegmentCoverage.initial(segmentCount: 2);
      observe(c);
      c = c.recordCapture(0); // 1/2 = 50% → crosses 25 AND 50
      observe(c);
      expect(firedMilestones(), [25, 50]);

      c = c.recordCapture(1); // 2/2 = 100% → crosses 75 AND 100
      observe(c);
      expect(firedMilestones(), [25, 50, 75, 100]);
    });

    test('non-integer boundary: 25% fires at filled 8 of 30, not 7', () {
      var c = SegmentCoverage.initial(segmentCount: 30);
      observe(c);
      for (var i = 0; i < 7; i++) {
        c = c.recordCapture(i);
        observe(c);
      }
      expect(firedMilestones(), isEmpty, reason: '7/30 = 23.3%');

      c = c.recordCapture(7); // 8/30 = 26.7%
      observe(c);
      expect(firedMilestones(), [25]);
      expect(
        ofName(AnalyticsEvents.coverageMilestone).single.properties['filled_count'],
        8,
      );
    });

    test('drop below a fired milestone then refill does NOT re-fire', () {
      var c = SegmentCoverage.initial(segmentCount: 4)
          .recordCapture(0)
          .recordCapture(1); // 50%
      observe(c);
      expect(firedMilestones(), [25, 50]);

      c = c.removeCapture(1); // back to 25%
      observe(c);
      c = c.recordCapture(1); // 50% again
      observe(c);

      expect(firedMilestones(), [25, 50], reason: 'no re-fire after recross');
    });

    test('100% is raw full coverage (all segments filled)', () {
      var c = SegmentCoverage.initial(segmentCount: 3);
      observe(c);
      c = c.recordCapture(0).recordCapture(1).recordCapture(2);
      observe(c);
      expect(firedMilestones(), [25, 50, 75, 100]);
    });
  });

  group('reset', () {
    test('clears fired-milestone + transition tracking for a new session', () {
      var c = SegmentCoverage.initial(segmentCount: 4).recordCapture(0);
      observe(c); // segment_filled(0) + milestone 25
      expect(emitted, isNotEmpty);

      emitted.clear();
      tracker.reset();

      // Same filled coverage re-observed → re-emitted from scratch.
      observe(c);
      expect(ofName(AnalyticsEvents.segmentFilled), hasLength(1));
      expect(firedMilestones(), [25]);
    });
  });

  group('payload + privacy', () {
    test('segment_filled carries the canonical typed fields', () {
      final c = SegmentCoverage.initial(segmentCount: 8).recordCapture(3);
      observe(SegmentCoverage.initial(segmentCount: 8));
      observe(c);

      final e = ofName(AnalyticsEvents.segmentFilled).single;
      expect(e.properties, {
        'level': 'A',
        'project_id': 'proj',
        'session_id': 'sess',
        'segment_index': 3,
        'segment_count': 8,
        'capture_mode': 'guided',
        'device_type': 'android',
      });
    });

    test('no payload key looks like PII / image / location', () {
      var c = SegmentCoverage.initial(segmentCount: 2);
      observe(c);
      c = c.recordCapture(0);
      observe(c);
      const banned = ['email', 'phone', 'name', 'token', 'path', 'image', 'lat',
        'lng', 'location'];
      for (final e in emitted) {
        for (final k in e.properties.keys) {
          for (final b in banned) {
            expect(k.toLowerCase().contains(b), isFalse, reason: '$k ~ $b');
          }
        }
      }
    });
  });

  group('fire-and-forget', () {
    tearDown(() => Analytics.testSink = null);

    test('a throwing dispatcher does not break observation', () {
      Analytics.testSink = (_, __) => throw StateError('boom');
      final real = CoverageAnalyticsTracker(); // default emit → CaptureAnalytics
      final c = SegmentCoverage.initial(segmentCount: 2).recordCapture(0);
      expect(
        () => real.onCoverageChanged(
          c,
          level: CaptureLevel.a,
          projectId: 'p',
          sessionId: 's',
          captureMode: 'guided',
          deviceType: 'android',
        ),
        returnsNormally,
      );
    });
  });

  group('observer provider (model stays pure)', () {
    test('drives the tracker from segmentCoverageProvider with session context',
        () {
      final events = <(String, Map<String, Object?>)>[];
      Analytics.testSink = (n, p) => events.add((n, p));
      addTearDown(() => Analytics.testSink = null);

      final container = ProviderContainer(overrides: [
        captureConfigProvider.overrideWith(() => _StubConfigNotifier()),
      ]);
      addTearDown(container.dispose);

      // Start a session (so the emitted context is linked) + activate the observer.
      container
          .read(captureLevelSessionProvider.notifier)
          .start(level: CaptureLevel.a, projectId: 'proj_x', sessionId: 'sess_x');
      container.read(coverageAnalyticsObserverProvider);

      // A capture fills a segment — through the notifier, NOT any analytics call
      // inside the pure model.
      container.read(segmentCoverageProvider.notifier).recordCapture(0);

      final fills =
          events.where((e) => e.$1 == AnalyticsEvents.segmentFilled).toList();
      expect(fills, hasLength(1));
      expect(fills.single.$2['segment_index'], 0);
      expect(fills.single.$2['session_id'], 'sess_x');
      expect(fills.single.$2['project_id'], 'proj_x');
      expect(fills.single.$2['capture_mode'], 'guided');
    });
  });
}
