// test/capture/roll_warning_provider_test.dart
//
// The roll-warning provider derives roll from the SHARED orientation stream
// (injected via [orientationSourceProvider] — no platform channels, no second
// subscription), applies the hysteretic [RollConstraint], drops broken reads,
// and degrades a stream error to an unsupported (inactive) sample.
import 'dart:async';
import 'dart:math' as math;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:recapture/application/capture/current_pitch_provider.dart';
import 'package:recapture/application/capture/roll_warning_provider.dart';
import 'package:recapture/platform/imu_rotation_channel.dart';

/// Builds a SmoothedOrientation whose `rollDegrees` equals [deg].
SmoothedOrientation _roll(double deg) {
  final rad = deg * math.pi / 180.0;
  return SmoothedOrientation(
    yaw: 0,
    pitch: 0,
    roll: rad,
    qx: 0,
    qy: 0,
    qz: 0,
    qw: 1,
    timestampNs: 0,
  );
}

void main() {
  group('rollWarningProvider', () {
    late StreamController<SmoothedOrientation> source;
    late ProviderContainer container;
    late List<RollWarningSample> samples;
    late ProviderSubscription<AsyncValue<RollWarningSample>> sub;

    setUp(() {
      source = StreamController<SmoothedOrientation>.broadcast();
      container = ProviderContainer(overrides: [
        orientationSourceProvider.overrideWithValue(source.stream),
      ]);
      samples = [];
      sub = container.listen<AsyncValue<RollWarningSample>>(
        rollWarningProvider,
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

    test('within tolerance → inactive; past 15° → active', () async {
      source.add(_roll(5));
      await pumpEventQueue();
      expect(samples.last.active, isFalse);
      expect(samples.last.sensorSupported, isTrue);

      source.add(_roll(20));
      await pumpEventQueue();
      expect(samples.last.active, isTrue);
      expect(samples.last.rollDegrees, closeTo(20, 1e-6));
    });

    test('hysteresis: stays active in the 12–15 band, clears below 12', () async {
      source.add(_roll(16)); // raise
      await pumpEventQueue();
      expect(samples.last.active, isTrue);

      source.add(_roll(13)); // in band → hold active
      await pumpEventQueue();
      expect(samples.last.active, isTrue);

      source.add(_roll(11)); // below release → clear
      await pumpEventQueue();
      expect(samples.last.active, isFalse);
    });

    test('left and right tilt are symmetric', () async {
      source.add(_roll(-20));
      await pumpEventQueue();
      expect(samples.last.active, isTrue);
      expect(samples.last.rollDegrees, closeTo(-20, 1e-6));
    });

    test('drops NaN / Infinity (holds prior state)', () async {
      source.add(_roll(20)); // active
      await pumpEventQueue();
      final before = samples.length;
      source.add(_roll(double.nan));
      source.add(_roll(double.infinity));
      await pumpEventQueue();
      // No new emission from broken reads; state still active on next valid read.
      expect(samples.length, before);

      source.add(_roll(18));
      await pumpEventQueue();
      expect(samples.last.active, isTrue);
    });

    test('a stream error degrades to unsupported + inactive', () async {
      source.add(_roll(30)); // active first
      await pumpEventQueue();
      expect(samples.last.active, isTrue);

      source.addError(Exception('SENSOR_UNAVAILABLE'));
      await pumpEventQueue();
      expect(samples.last.sensorSupported, isFalse);
      expect(samples.last.active, isFalse);
      expect(container.read(rollWarningProvider).hasError, isFalse);
    });
  });
}
