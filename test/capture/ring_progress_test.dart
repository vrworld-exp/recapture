// test/capture/ring_progress_test.dart
//
// The Level A ring-progress resolver (item 1, the critical-path Capture Logic):
//   - PURE: ringSegmentForYaw (yaw→segment, wraparound-safe) + resolveRingDirection
//     (currentSegment + live fill state → RingDirectionState: at-target /
//     captured-here / shorter-arc direction / angular gap / allCaptured).
//   - WIRING: currentRingSegmentProvider (off the SHARED orientation stream),
//     ringDirectionStateProvider (fail-open pending before a sample / sensor off),
//     and the position binder — driven by an injected stream, no platform channels.
import 'dart:async';
import 'dart:math' as math;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:recapture/application/capture/current_tilt_provider.dart'
    show orientationSourceProvider;
import 'package:recapture/application/capture/capture_flow_variant_provider.dart';
import 'package:recapture/application/capture/ring_progress_provider.dart';
import 'package:recapture/application/capture/segment_coverage_provider.dart';
import 'package:recapture/application/config/config_notifier.dart';
import 'package:recapture/domain/capture/capture_flow_variant.dart';
import 'package:recapture/domain/capture/guidance_inputs.dart'
    show RingDirectionState;
import 'package:recapture/domain/capture/ring_progress.dart';
import 'package:recapture/domain/entities/capture_config.dart';
import 'package:recapture/domain/entities/direction_hint.dart';
import 'package:recapture/domain/entities/segment_coverage.dart';
import 'package:recapture/platform/imu_rotation_channel.dart'
    show SmoothedOrientation;

SegmentCoverage _coverage(int n, {Set<int> filled = const {}}) =>
    SegmentCoverage.of(
      segmentCount: n,
      fillCounts: [for (var i = 0; i < n; i++) filled.contains(i) ? 1 : 0],
    );

SmoothedOrientation _yaw(double deg) => SmoothedOrientation(
      yaw: deg * math.pi / 180.0,
      pitch: 0,
      roll: 0,
      qx: 0,
      qy: 0,
      qz: 0,
      qw: 1,
      timestampNs: 0,
    );

class _StubConfigNotifier extends ConfigNotifier {
  @override
  CaptureConfig build() => CaptureConfig.bundledDefault;
}

void main() {
  // ───────────────────────────── pure: ringSegmentForYaw ─────────────────────
  group('ringSegmentForYaw (N=12, 30° segments)', () {
    int seg(double yaw, {double start = 0}) =>
        ringSegmentForYaw(yawDegrees: yaw, yawStartDegrees: start, segmentCount: 12);

    test('baseline maps to segment 0; segment size buckets forward', () {
      expect(seg(0), 0);
      expect(seg(15), 0);
      expect(seg(30), 1, reason: 'boundary belongs to the higher segment');
      expect(seg(45), 1);
      expect(seg(359), 11);
    });

    test('wraparound: 360°/-30°/370° normalize correctly', () {
      expect(seg(360), 0);
      expect(seg(-30), 11);
      expect(seg(370), 0);
    });

    test('baseline offset shifts the origin', () {
      // With start=90, yaw 90 → segment 0; yaw 120 → segment 1.
      expect(seg(90, start: 90), 0);
      expect(seg(120, start: 90), 1);
    });
  });

  // ───────────────────────── pure: resolveRingDirection ──────────────────────
  group('resolveRingDirection', () {
    test('fresh ring, at an uncaptured segment → at-target capture branch', () {
      final r = resolveRingDirection(currentSegment: 5, coverage: _coverage(12));
      expect(r.atTargetPosition, isTrue);
      expect(r.currentPositionCaptured, isFalse);
      expect(r.allCaptured, isFalse);
      expect(r.angularGapDeg, 0);
    });

    test('pointing at a FILLED segment → direction branch (captured here, '
        'shorter-arc forward = clockwise)', () {
      // filled {0,1,2}; at segment 1 → nearest missing is 3 (+2 forward).
      final r = resolveRingDirection(
          currentSegment: 1, coverage: _coverage(12, filled: {0, 1, 2}));
      expect(r.currentPositionCaptured, isTrue);
      expect(r.atTargetPosition, isFalse);
      expect(r.toNext, RingDirection.clockwise);
      expect(r.angularGapDeg, closeTo(60, 1e-9)); // 2 segments * 30°
      expect(r.allCaptured, isFalse);
    });

    test('shorter arc backward → counterclockwise', () {
      // filled {6..11}; at segment 6 → nearest missing is 5 (−1 backward).
      final r = resolveRingDirection(
        currentSegment: 6,
        coverage: _coverage(12, filled: {6, 7, 8, 9, 10, 11}),
      );
      expect(r.toNext, RingDirection.counterclockwise);
      expect(r.angularGapDeg, closeTo(30, 1e-9));
    });

    test('wraparound: nearest gap across the seam takes the short way', () {
      // Only segment 11 missing; at segment 0 → gap 11 is 1 step BACKWARD (seam).
      final r = resolveRingDirection(
        currentSegment: 0,
        coverage: _coverage(12, filled: {0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10}),
      );
      expect(r.toNext, RingDirection.counterclockwise);
      expect(r.angularGapDeg, closeTo(30, 1e-9));
      expect(r.allCaptured, isFalse);
    });

    test('all captured → terminal allCaptured, no target', () {
      final all = {for (var i = 0; i < 12; i++) i};
      final r = resolveRingDirection(
          currentSegment: 3, coverage: _coverage(12, filled: all));
      expect(r.allCaptured, isTrue);
      expect(r.atTargetPosition, isFalse);
      expect(r.angularGapDeg, 0);
    });

    test('out-of-range currentSegment is normalized into the ring', () {
      // 14 mod 12 = 2 (unfilled, fresh) → at-target, no throw.
      final r = resolveRingDirection(currentSegment: 14, coverage: _coverage(12));
      expect(r.atTargetPosition, isTrue);
      expect(r.currentPositionCaptured, isFalse);
    });
  });

  // ─────────────────────────────── provider wiring ───────────────────────────
  group('providers (injected orientation stream)', () {
    late StreamController<SmoothedOrientation> source;
    late ProviderContainer container;
    late int n;
    late double segSize;
    final subs = <ProviderSubscription<Object?>>[];

    setUp(() {
      source = StreamController<SmoothedOrientation>.broadcast();
      container = ProviderContainer(overrides: [
        orientationSourceProvider.overrideWithValue(source.stream),
        captureConfigProvider.overrideWith(_StubConfigNotifier.new),
      ]);
      // The provider now sizes from the ACTIVE ring (config × variant × band)
      // — the same N source the fill state uses.
      n = container.read(activeLevelSegmentCountProvider);
      segSize = 360.0 / n;
      // Keep the autoDispose stream provider alive for the test.
      subs.add(container.listen(currentRingSegmentProvider, (_, __) {}));
    });

    tearDown(() async {
      for (final s in subs) {
        s.close();
      }
      container.dispose();
      await source.close();
    });

    /// Yaw that lands squarely in the middle of segment [k] (baseline must be 0).
    double yawForSegment(int k) => k * segSize + segSize / 2;

    test('currentRingSegmentProvider: first yaw baselines to segment 0, then '
        'maps subsequent yaw', () async {
      source.add(_yaw(0)); // baseline
      await pumpEventQueue();
      expect(
        container.read(currentRingSegmentProvider).valueOrNull?.currentSegment,
        0,
      );

      source.add(_yaw(yawForSegment(3)));
      await pumpEventQueue();
      final sample = container.read(currentRingSegmentProvider).valueOrNull;
      expect(sample?.sensorSupported, isTrue);
      expect(sample?.currentSegment, 3);
    });

    test('ringDirectionStateProvider: pending before any sample (fail-open)',
        () async {
      // No yaw yet → no segment → pending.
      expect(container.read(ringDirectionStateProvider),
          RingDirectionState.pending);
    });

    test('ringDirectionStateProvider reflects live segment + live fill state',
        () async {
      subs.add(container.listen(ringDirectionStateProvider, (_, __) {}));
      source.add(_yaw(0)); // segment 0
      await pumpEventQueue();

      // Fresh coverage: at an uncaptured target.
      var state = container.read(ringDirectionStateProvider);
      expect(state.atTargetPosition, isTrue);
      expect(state.currentPositionCaptured, isFalse);

      // Fill segment 0 → fill state flows in: captured here, target advances.
      container.read(segmentCoverageProvider.notifier).recordCapture(0);
      state = container.read(ringDirectionStateProvider);
      expect(state.currentPositionCaptured, isTrue);
      expect(state.atTargetPosition, isFalse);
    });

    test('sensor error → unsupported sample → pending state', () async {
      subs.add(container.listen(ringDirectionStateProvider, (_, __) {}));
      source.addError(Exception('SENSOR_UNAVAILABLE'));
      await pumpEventQueue();

      expect(
        container.read(currentRingSegmentProvider).valueOrNull?.sensorSupported,
        isFalse,
      );
      expect(container.read(ringDirectionStateProvider),
          RingDirectionState.pending);
    });

    test('position binder syncs SegmentCoverage.position to the live segment',
        () async {
      subs.add(container.listen(ringPositionBinderProvider, (_, __) {}));
      source.add(_yaw(0)); // baseline → segment 0
      await pumpEventQueue();
      source.add(_yaw(yawForSegment(4)));
      await pumpEventQueue();

      expect(container.read(segmentCoverageProvider).position, 4);
    });

    test('per-ring reset: a new ring re-baselines yawStart to its OWN start '
        'heading (Level C independent of Level B)', () async {
      // Ring 1 (e.g. Level B) begins facing 100°: that heading becomes segment 0.
      source.add(_yaw(100));
      await pumpEventQueue();
      expect(
        container.read(currentRingSegmentProvider).valueOrNull?.currentSegment,
        0,
      );
      // Turning to 100° + 3 segments lands on segment 3 of ring 1.
      source.add(_yaw(100 + yawForSegment(3)));
      await pumpEventQueue();
      expect(
        container.read(currentRingSegmentProvider).valueOrNull?.currentSegment,
        3,
      );

      // Ring 2 (e.g. Level C) BEGINS — the capture screen resets the baseline.
      container.read(ringYawBaselineProvider.notifier).reset();

      // First sample of ring 2, facing a DIFFERENT heading (250°): it becomes the
      // new segment 0 — NOT measured against ring 1's 100° baseline.
      source.add(_yaw(250));
      await pumpEventQueue();
      expect(
        container.read(currentRingSegmentProvider).valueOrNull?.currentSegment,
        0,
        reason: 'Level C start heading is segment 0, independent of Level B',
      );
      expect(container.read(ringYawBaselineProvider), closeTo(250, 1e-6));
    });

    test('baseline defers until a valid yaw: reset then NaN keeps it unset, '
        'first finite sample establishes it', () async {
      source.add(_yaw(40));
      await pumpEventQueue();
      container.read(ringYawBaselineProvider.notifier).reset();
      expect(container.read(ringYawBaselineProvider), isNull);

      // A broken sample must not become the reference.
      source.add(_yaw(double.nan));
      await pumpEventQueue();
      expect(container.read(ringYawBaselineProvider), isNull);

      // The first valid sample establishes it.
      source.add(_yaw(70));
      await pumpEventQueue();
      expect(container.read(ringYawBaselineProvider), closeTo(70, 1e-6));
      expect(
        container.read(currentRingSegmentProvider).valueOrNull?.currentSegment,
        0,
      );
    });

    test('regression (§eyeRingSegments-for-all-levels bug): N follows the '
        'ACTIVE band + variant — a 24-segment Top Ring buckets by 24', () async {
      // A without_bottom session capturing Level B (band "high") → N = 24.
      container
          .read(captureFlowVariantProvider.notifier)
          .restore(CaptureFlowVariant.withoutBottom);
      container.read(activeCaptureBandIdProvider.notifier).set('high');
      expect(container.read(activeLevelSegmentCountProvider), 24);
      // Let the stream provider rebuild + re-subscribe (broadcast events sent
      // during the swap would be lost) before feeding the baseline sample.
      await pumpEventQueue();

      source.add(_yaw(0)); // baseline this ring at 0°
      await pumpEventQueue();
      // Probe 50°: a 24-segment ring (15°/segment) buckets it as segment 3 —
      // under an Eye-Ring-pinned N (16 → 22.5°/segment) the same turn would
      // read segment 2, so the two Ns are distinguishable.
      source.add(_yaw(50));
      await pumpEventQueue();
      expect(
        container.read(currentRingSegmentProvider).valueOrNull?.currentSegment,
        3,
        reason: 'yaw→segment must bucket by THIS ring\'s N (24), not the Eye Ring\'s',
      );
      // …and the fill state sized itself to the same N (single source).
      expect(container.read(segmentCoverageProvider).segmentCount, 24);
    });
  });

  // ───────────────────────── RingYawBaselineNotifier (unit) ───────────────────
  group('RingYawBaselineNotifier', () {
    test('seedIfUnset sets once then is sticky; reset clears', () {
      final c = ProviderContainer();
      addTearDown(c.dispose);
      final n = c.read(ringYawBaselineProvider.notifier);

      expect(c.read(ringYawBaselineProvider), isNull);
      expect(n.seedIfUnset(33), 33);
      expect(c.read(ringYawBaselineProvider), 33);
      // A later sample does not move an established baseline.
      expect(n.seedIfUnset(99), 33);
      expect(c.read(ringYawBaselineProvider), 33);
      // Reset clears; the next seed re-establishes.
      n.reset();
      expect(c.read(ringYawBaselineProvider), isNull);
      expect(n.seedIfUnset(99), 99);
    });
  });
}
