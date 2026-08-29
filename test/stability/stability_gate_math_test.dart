// test/stability/stability_gate_math_test.dart
//
// The Dart port of the native stability gate
// (android/.../sensors/StabilityGate.kt) — what makes "stable" mean the same
// physical steadiness in a browser as on a phone.
//
// The prompt asked for the web gate to be "calibrated to emit stable under
// roughly the same steadiness as native". The approach taken instead is
// stronger and testable: it is the SAME decision function, with the same
// thresholds, the same strict `<`, the same dt-aware dwell and the same
// gap-reset — so the only thing left to verify on the web side is the unit
// conversion feeding it (degrees/second → rad/s), not a hand-tuned constant.
import 'package:flutter_test/flutter_test.dart';
import 'package:recapture/platform/capture_ports/stability_math.dart';

const int _ms = 1000000; // nanoseconds per millisecond

void main() {
  group('StabilityConfig', () {
    test('defaults match the native gate (0.8 rad/s, 0.15 g, 250 ms)', () {
      final c = StabilityConfig.defaults;
      expect(c.gyroThreshRadS, 0.8);
      expect(c.accelThreshMs2, closeTo(0.15 * 9.81, 1e-9));
      expect(c.dwellNs, 250 * _ms);
    });

    test('the g → m/s² conversion happens exactly once, in build()', () {
      final c = StabilityConfig.build(accelThreshG: 0.5);
      expect(c.accelThreshMs2, closeTo(0.5 * 9.81, 1e-9));
    });

    test('invalid inputs fall back to defaults rather than disabling the gate',
        () {
      final c = StabilityConfig.build(
        gyroThreshRadS: -1,
        accelThreshG: double.nan,
        dwellMs: -5,
      );
      expect(c.gyroThreshRadS, StabilityConfig.defaultGyroThreshRadS);
      expect(c.accelThreshMs2,
          closeTo(StabilityConfig.defaultAccelThreshG * 9.81, 1e-9));
      expect(c.dwellNs, StabilityConfig.defaultDwellMs * _ms);
    });
  });

  group('StabilityGate — the dwell state machine', () {
    late StabilityGate gate;

    setUp(() => gate = StabilityGate());

    /// Feeds both signals at one timestamp, the way `devicemotion` delivers
    /// them (unlike Android's two independent sensor streams).
    List<StabilityTransition> feed(double gyro, double accel, int ts) =>
        <StabilityTransition?>[
          gate.onGyro(gyro, ts),
          gate.onLinearAccel(accel, ts),
        ].whereType<StabilityTransition>().toList();

    test('no transition until BOTH signals have reported', () {
      expect(gate.onGyro(0.0, 0), isNull);
      expect(gate.currentReading(), isNull);
      expect(gate.onLinearAccel(0.0, 10 * _ms), isNull);
      expect(gate.currentReading(), isNotNull);
    });

    test('a sustained calm opens the gate only after the full dwell', () {
      expect(feed(0.01, 0.05, 0), isEmpty);
      expect(feed(0.01, 0.05, 100 * _ms), isEmpty);
      expect(feed(0.01, 0.05, 249 * _ms), isEmpty, reason: 'dwell not met');
      final opened = feed(0.01, 0.05, 250 * _ms);
      expect(opened, hasLength(1));
      expect(opened.single.stable, isTrue);
      expect(gate.isStable, isTrue);
    });

    test('a break in the condition resets the dwell', () {
      feed(0.01, 0.05, 0);
      feed(0.01, 0.05, 200 * _ms);
      feed(5.0, 0.05, 210 * _ms); // a jolt
      expect(feed(0.01, 0.05, 400 * _ms), isEmpty,
          reason: 'the dwell restarted at 400 ms, so 400 is not yet stable');
      final opened = feed(0.01, 0.05, 650 * _ms);
      expect(opened.single.stable, isTrue);
    });

    test('leaving stable emits exactly one falling transition', () {
      feed(0.01, 0.05, 0);
      feed(0.01, 0.05, 300 * _ms);
      expect(gate.isStable, isTrue);
      final left = feed(5.0, 0.05, 310 * _ms);
      expect(left, hasLength(1));
      expect(left.single.stable, isFalse);
      // No repeat while it stays unstable.
      expect(feed(5.0, 0.05, 320 * _ms), isEmpty);
    });

    test('the threshold comparison is strict — exactly at it is NOT stable',
        () {
      final c = StabilityConfig.defaults;
      feed(c.gyroThreshRadS, 0.0, 0);
      expect(feed(c.gyroThreshRadS, 0.0, 500 * _ms), isEmpty);
    });

    test('a gap beyond the reset window breaks the dwell', () {
      feed(0.01, 0.05, 0);
      feed(0.01, 0.05, 300 * _ms);
      expect(gate.isStable, isTrue);
      // A tab backgrounded for a second: no samples arrive. The gate must not
      // stay "stable" across a hole it cannot vouch for.
      final afterGap = feed(0.01, 0.05, 1500 * _ms);
      expect(afterGap.first.stable, isFalse);
    });

    test('either signal alone can keep the gate closed (the AND)', () {
      feed(0.01, 5.0, 0); // still, but shaking linearly
      expect(feed(0.01, 5.0, 500 * _ms), isEmpty);
      feed(5.0, 0.01, 600 * _ms); // steady, but rotating
      expect(feed(5.0, 0.01, 1000 * _ms), isEmpty);
    });
  });

  group('StabilityMath.score — the continuous UI meter', () {
    test('perfectly still is 1.0', () {
      expect(StabilityMath.score(0, 0, 0.8, 1.47), closeTo(1.0, 1e-9));
    });

    test('either signal at its threshold collapses the score to 0', () {
      expect(StabilityMath.score(0.8, 0, 0.8, 1.47), closeTo(0, 1e-9));
      expect(StabilityMath.score(0, 1.47, 0.8, 1.47), closeTo(0, 1e-9));
    });

    test('it falls monotonically as motion rises', () {
      final calm = StabilityMath.score(0.1, 0.1, 0.8, 1.47);
      final moving = StabilityMath.score(0.4, 0.6, 0.8, 1.47);
      expect(moving, lessThan(calm));
      expect(moving, greaterThan(0));
    });

    test('a non-finite magnitude scores 0 rather than NaN', () {
      expect(StabilityMath.score(double.nan, 0, 0.8, 1.47), 0);
    });
  });

  group(
      'GravityEstimator — the fallback when the browser gives no linear accel',
      () {
    test('the first sample is assumed to be pure gravity', () {
      final e = GravityEstimator();
      expect(e.linearMagnitude(0, 0, 9.81, 0), 0);
    });

    test('steady gravity keeps reporting ~0 linear acceleration', () {
      final e = GravityEstimator();
      e.linearMagnitude(0, 0, 9.81, 0);
      var last = 0.0;
      for (var i = 1; i <= 60; i++) {
        last = e.linearMagnitude(0, 0, 9.81, i * 16 * _ms);
      }
      expect(last, closeTo(0, 1e-6));
    });

    test('a sudden shove shows up as real linear acceleration', () {
      final e = GravityEstimator();
      e.linearMagnitude(0, 0, 9.81, 0);
      for (var i = 1; i <= 30; i++) {
        e.linearMagnitude(0, 0, 9.81, i * 16 * _ms);
      }
      // The tracker is deliberately slow (~0.5 s tau) so a brief motion is not
      // absorbed into the gravity estimate.
      final shove = e.linearMagnitude(4.0, 0, 9.81, 31 * 16 * _ms);
      expect(shove, greaterThan(3.0));
    });
  });
}
