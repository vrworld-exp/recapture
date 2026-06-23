// test/capture/current_pitch_provider_test.dart
//
// Verifies the smoothed current-pitch provider: the EMA helper, that the
// provider low-passes the native smoothed-orientation stream, drops broken
// (NaN/Infinity) reads, and degrades a stream error (absent sensor) to an
// unsupported sample instead of an AsyncError. The native stream is injected via
// [orientationSourceProvider] — no platform channels.
import 'dart:async';
import 'dart:math' as math;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:recapture/application/capture/current_pitch_provider.dart';
import 'package:recapture/platform/imu_rotation_channel.dart';

/// Builds a SmoothedOrientation whose `pitchDegrees` equals [deg].
SmoothedOrientation _at(double deg) {
  final rad = deg * math.pi / 180.0;
  return SmoothedOrientation(
    yaw: 0,
    pitch: rad,
    roll: 0,
    qx: 0,
    qy: 0,
    qz: 0,
    qw: 1,
    timestampNs: 0,
  );
}

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

  group('currentPitchProvider', () {
    late StreamController<SmoothedOrientation> source;
    late ProviderContainer container;
    late List<PitchSample> samples;
    late ProviderSubscription<AsyncValue<PitchSample>> sub;

    setUp(() {
      source = StreamController<SmoothedOrientation>.broadcast();
      container = ProviderContainer(overrides: [
        orientationSourceProvider.overrideWithValue(source.stream),
      ]);
      samples = [];
      sub = container.listen<AsyncValue<PitchSample>>(
        currentPitchProvider,
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

    test('emits supported, low-passed pitch', () async {
      source.add(_at(10));
      await pumpEventQueue();
      source.add(_at(20));
      await pumpEventQueue();

      expect(samples, isNotEmpty);
      expect(samples.every((s) => s.sensorSupported), isTrue);
      // First sample seeds at 10; second is EMA(10,20,0.2)=12 — strictly between.
      expect(samples.first.pitchDegrees, closeTo(10, 1e-6));
      expect(samples.last.pitchDegrees, greaterThan(10));
      expect(samples.last.pitchDegrees, lessThan(20));
    });

    test('drops NaN / Infinity reads (no emission, no crash)', () async {
      source.add(_at(double.nan));
      source.add(_at(double.infinity));
      await pumpEventQueue();
      expect(samples, isEmpty);

      source.add(_at(45));
      await pumpEventQueue();
      expect(samples.single.pitchDegrees, closeTo(45, 1e-6));
    });

    test('a stream error degrades to an unsupported sample', () async {
      source.addError(Exception('SENSOR_UNAVAILABLE'));
      await pumpEventQueue();

      expect(samples.single.sensorSupported, isFalse);
      // Never surfaces as an AsyncError.
      expect(container.read(currentPitchProvider).hasError, isFalse);
    });
  });
}
