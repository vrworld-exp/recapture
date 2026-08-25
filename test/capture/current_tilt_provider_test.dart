// test/capture/current_tilt_provider_test.dart
//
// Verifies the smoothed current camera-tilt provider: the EMA helper, that the
// provider derives the 0–180° tilt from the smoothed QUATERNION (not Euler
// pitch), low-passes it, drops broken (NaN/degenerate-quaternion) reads, and
// degrades a stream error (absent sensor) to an unsupported sample instead of
// an AsyncError. The native stream is injected via [orientationSourceProvider]
// — no platform channels.
import 'dart:async';
import 'dart:math' as math;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:recapture/application/capture/current_tilt_provider.dart';
import 'package:recapture/platform/imu_rotation_channel.dart';

/// Builds a SmoothedOrientation whose `cameraTiltDegrees` equals [tiltDeg]: a
/// rotation of (180° − tilt) about device X (identity = flat screen-up = tilt
/// 180, upright portrait = 90° about X = tilt 90 — see camera_tilt_test.dart).
SmoothedOrientation _atTilt(double tiltDeg) {
  final theta = (180.0 - tiltDeg) * math.pi / 180.0;
  return SmoothedOrientation(
    yaw: 0,
    pitch: 0,
    roll: 0,
    qx: math.sin(theta / 2),
    qy: 0,
    qz: 0,
    qw: math.cos(theta / 2),
    timestampNs: 0,
  );
}

/// A broken read: quaternion components that produce a NaN tilt.
SmoothedOrientation _broken({double qx = double.nan, double qw = 1}) =>
    SmoothedOrientation(
      yaw: 0,
      pitch: 0,
      roll: 0,
      qx: qx,
      qy: 0,
      qz: 0,
      qw: qw,
      timestampNs: 0,
    );

void main() {
  group('emaStep', () {
    test('seeds with the first raw value', () {
      expect(emaStep(null, 42), 42);
    });

    test('moves toward the new value by alpha', () {
      // prev=0, raw=10, alpha=0.2 → 2.0
      expect(emaStep(0, 10, alpha: 0.2), closeTo(2.0, 1e-9));
    });

    test('a constant input converges to that value', () {
      double? s;
      for (var i = 0; i < 100; i++) {
        s = emaStep(s, 30);
      }
      expect(s, closeTo(30, 1e-6));
    });
  });

  group('currentTiltProvider', () {
    late StreamController<SmoothedOrientation> source;
    late ProviderContainer container;
    late List<TiltSample> samples;
    late ProviderSubscription<AsyncValue<TiltSample>> sub;

    setUp(() {
      source = StreamController<SmoothedOrientation>.broadcast();
      container = ProviderContainer(overrides: [
        orientationSourceProvider.overrideWithValue(source.stream),
      ]);
      samples = [];
      sub = container.listen<AsyncValue<TiltSample>>(
        currentTiltProvider,
        (_, next) {
          final v = next.asData?.value;
          if (v != null) samples.add(v);
        },
        fireImmediately: true,
      );
    });

    tearDown(() async {
      sub.close();
      container.dispose();
      await source.close();
    });

    test('emits supported, low-passed tilt derived from the quaternion',
        () async {
      source.add(_atTilt(70));
      await pumpEventQueue();
      source.add(_atTilt(80));
      await pumpEventQueue();

      expect(samples, isNotEmpty);
      expect(samples.every((s) => s.sensorSupported), isTrue);
      // First sample seeds at 70; second is EMA(70,80,0.2)=72 — strictly between.
      expect(samples.first.tiltDegrees, closeTo(70, 1e-6));
      expect(samples.last.tiltDegrees, greaterThan(70));
      expect(samples.last.tiltDegrees, lessThan(80));
    });

    test('drops NaN-tilt reads — broken/degenerate quaternion (no emission, '
        'no crash)', () async {
      source.add(_broken()); // NaN component
      source.add(_broken(qx: 0, qw: 0)); // zero quaternion (non-unit)
      await pumpEventQueue();
      expect(samples, isEmpty);

      source.add(_atTilt(90));
      await pumpEventQueue();
      expect(samples.single.tiltDegrees, closeTo(90, 1e-6));
    });

    test('an event that carried no quaternion is dropped, not read as flat',
        () async {
      final noQ = SmoothedOrientation.fromEvent(
          {'yaw': 0.0, 'pitch': 0.5, 'roll': 0.0, 'timestampNs': 1});
      source.add(noQ!);
      await pumpEventQueue();
      expect(samples, isEmpty);
    });

    test('a stream error degrades to an unsupported sample', () async {
      source.addError(Exception('SENSOR_UNAVAILABLE'));
      await pumpEventQueue();

      expect(samples.single.sensorSupported, isFalse);
      // Never surfaces as an AsyncError.
      expect(container.read(currentTiltProvider).hasError, isFalse);
    });
  });
}
