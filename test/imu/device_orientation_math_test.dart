// test/imu/device_orientation_math_test.dart
//
// The browser → app coordinate-frame conversion, tested as a pure function
// against a table of known device poses BEFORE it is wired to anything.
//
// This is the highest-leverage test in the web capture work: getting
// alpha/beta/gamma → (yaw, 0–180° camera tilt) wrong does not crash or log
// anything, it silently breaks band gating, ring progress and the Meshy
// [60, 180) window — a shutter that refuses valid shots, or accepts useless
// ones, with no visible symptom.
import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:recapture/domain/capture/camera_tilt.dart';
import 'package:recapture/platform/capture_ports/orientation_math.dart';

const double _radToDeg = 180.0 / math.pi;

double _tiltFor({
  required double alpha,
  required double beta,
  required double gamma,
  double screenAngle = 0,
}) {
  final q = deviceOrientationQuaternion(
    alphaDeg: alpha,
    betaDeg: beta,
    gammaDeg: gamma,
    screenAngleDeg: screenAngle,
  );
  return cameraTiltDegrees(qx: q.x, qy: q.y, qz: q.z, qw: q.w);
}

double _yawDegreesFor({
  required double alpha,
  required double beta,
  required double gamma,
  double screenAngle = 0,
}) {
  final q = deviceOrientationQuaternion(
    alphaDeg: alpha,
    betaDeg: beta,
    gammaDeg: gamma,
    screenAngleDeg: screenAngle,
  );
  return OrientationMath.toEuler(q.x, q.y, q.z, q.w)[0] * _radToDeg;
}

void main() {
  group('deviceOrientationQuaternion → camera tilt (0–180 scale)', () {
    // The app's scale: 0 = camera at the sky, 90 = horizon, 180 = at the
    // ground. In the device's natural frame with gamma = 0, tipping the phone
    // forward by `beta` from flat-on-its-back gives tilt = 180 − beta.
    test('flat on its back (beta 0) → camera at the ground', () {
      // Clamped just below 180 so the maxDegrees-EXCLUSIVE band contract still
      // admits a physically perfect top-down shot.
      expect(_tiltFor(alpha: 0, beta: 0, gamma: 0),
          closeTo(kCameraTiltMaxDegrees, 0.001));
    });

    test('upright portrait (beta 90) → horizon', () {
      expect(_tiltFor(alpha: 0, beta: 90, gamma: 0), closeTo(90, 1e-6));
    });

    test('flat on its face (beta 180) → camera at the sky', () {
      expect(_tiltFor(alpha: 0, beta: 180, gamma: 0), closeTo(0, 1e-6));
    });

    test('tilt = 180 − beta across the sweep', () {
      for (final beta in <double>[15, 30, 45, 60, 75, 105, 120, 150]) {
        expect(
          _tiltFor(alpha: 0, beta: beta, gamma: 0),
          closeTo(180 - beta, 1e-6),
          reason: 'beta=$beta',
        );
      }
    });

    test('landscape roll (gamma ±90 from flat) is level with the horizon', () {
      expect(_tiltFor(alpha: 0, beta: 0, gamma: 90), closeTo(90, 1e-6));
      expect(_tiltFor(alpha: 0, beta: 0, gamma: -90), closeTo(90, 1e-6));
    });

    test('heading (alpha) never changes tilt', () {
      for (final alpha in <double>[0, 45, 90, 180, 270, 359]) {
        expect(
          _tiltFor(alpha: alpha, beta: 60, gamma: 0),
          closeTo(120, 1e-6),
          reason: 'alpha=$alpha',
        );
      }
    });

    test('a non-finite angle degrades to the identity pose, never NaN', () {
      final tilt = _tiltFor(alpha: double.nan, beta: 45, gamma: 0);
      expect(tilt.isNaN, isFalse);
      expect(tilt, closeTo(kCameraTiltMaxDegrees, 0.001));
    });
  });

  group('screen orientation composition', () {
    // Rotating the viewport rotates about the DEVICE Z axis, which is the
    // camera's optical axis — so it cannot change where the camera points.
    // Band gating, ring progress and the Meshy window must therefore read
    // identically in portrait and in both landscapes.
    test('camera tilt is invariant under every screen angle', () {
      for (final screenAngle in <double>[0, 90, 180, 270]) {
        for (final pose in <List<double>>[
          <double>[0, 0, 0],
          <double>[30, 45, 10],
          <double>[120, 90, 0],
          <double>[200, 120, -25],
          <double>[350, 150, 40],
        ]) {
          expect(
            _tiltFor(
              alpha: pose[0],
              beta: pose[1],
              gamma: pose[2],
              screenAngle: screenAngle,
            ),
            closeTo(
              _tiltFor(alpha: pose[0], beta: pose[1], gamma: pose[2]),
              1e-6,
            ),
            reason: 'pose=$pose screenAngle=$screenAngle',
          );
        }
      }
    });

    test('yaw picks up a constant offset per screen angle', () {
      // Harmless because ring position is measured against a per-ring yawStart
      // baseline, never as an absolute heading — but it must be CONSTANT, not
      // pose-dependent, or a rotation mid-ring would smear the baseline.
      double offsetAt(double alpha) {
        final base = _yawDegreesFor(alpha: alpha, beta: 45, gamma: 0);
        final rotated =
            _yawDegreesFor(alpha: alpha, beta: 45, gamma: 0, screenAngle: 90);
        var delta = rotated - base;
        while (delta > 180) {
          delta -= 360;
        }
        while (delta <= -180) {
          delta += 360;
        }
        return delta;
      }

      for (final alpha in <double>[0, 30, 90, 200, 300]) {
        expect(offsetAt(alpha), closeTo(90, 1e-6), reason: 'alpha=$alpha');
      }
    });
  });

  group('yaw follows the compass heading', () {
    // The Euler derivation reproduces SensorManager.getOrientation exactly, so
    // (below vertical, gamma 0) azimuth is −alpha. What matters downstream is
    // that it tracks alpha monotonically: ring position is a delta.
    test('yaw = −alpha below vertical', () {
      for (final alpha in <double>[0, 30, 45, 90, 135]) {
        expect(
          _yawDegreesFor(alpha: alpha, beta: 45, gamma: 0),
          closeTo(-alpha, 1e-6),
          reason: 'alpha=$alpha',
        );
      }
    });
  });

  group('Meshy [60, 180) window boundaries', () {
    // 60 inclusive, 180 exclusive. These two boundaries decide whether the
    // Maya shutter unblocks, and the mode hard-gates on them.
    test('beta 120 lands exactly on the inclusive lower bound (tilt 60)', () {
      final tilt = _tiltFor(alpha: 0, beta: 120, gamma: 0);
      expect(tilt, closeTo(60, 1e-6));
      expect(tilt >= 60 && tilt < 180, isTrue);
    });

    test('just outside the lower bound is out of band', () {
      final tilt = _tiltFor(alpha: 0, beta: 120.5, gamma: 0);
      expect(tilt, lessThan(60));
      expect(tilt >= 60 && tilt < 180, isFalse);
    });

    test('the top of the range never reaches the exclusive 180 bound', () {
      final tilt = _tiltFor(alpha: 0, beta: 0, gamma: 0);
      expect(tilt, lessThan(180));
      expect(tilt >= 60 && tilt < 180, isTrue);
    });

    test('both landscapes admit the same in-band poses', () {
      for (final screenAngle in <double>[90, 270]) {
        expect(
          _tiltFor(alpha: 40, beta: 100, gamma: 0, screenAngle: screenAngle),
          closeTo(80, 1e-6),
        );
      }
    });
  });

  group('DartOrientationFilter (parity port of the native filter)', () {
    test('the first sample is passed through unsmoothed', () {
      final filter = DartOrientationFilter();
      final q = filter.filter(<double>[0.5, 0, 0, math.sqrt(0.75)], 0);
      expect(q[0], closeTo(0.5, 1e-9));
      expect(q[3], closeTo(math.sqrt(0.75), 1e-9));
    });

    test('a steady input converges to that input', () {
      final filter = DartOrientationFilter();
      filter.filter(<double>[0, 0, 0, 1], 0);
      final target = <double>[0.38268, 0, 0, 0.92388];
      List<double> out = const <double>[];
      for (var i = 1; i <= 40; i++) {
        out = filter.filter(target, i * 16000000); // ~60 Hz
      }
      expect(out[0], closeTo(target[0], 1e-3));
      expect(out[3], closeTo(target[3], 1e-3));
    });

    test('a gap beyond the reset window snaps instead of blending', () {
      final filter = DartOrientationFilter();
      filter.filter(<double>[0, 0, 0, 1], 0);
      final out = filter.filter(
        <double>[1, 0, 0, 0],
        DartOrientationFilter.defaultGapResetNs + 1,
      );
      expect(out[0], closeTo(1, 1e-9));
      expect(out[3], closeTo(0, 1e-9));
    });

    test('tau <= 0 is passthrough; alpha clamps into [0, 1]', () {
      expect(OrientationMath.alpha(1000, 0), 1.0);
      expect(OrientationMath.alpha(0, 1000), 0.0);
      expect(OrientationMath.alpha(-5, 1000), 0.0);
      expect(OrientationMath.alpha(1e9, 1e6), closeTo(1.0, 1e-9));
    });

    test('nlerp takes the shortest path across the double cover', () {
      // q and −q are the same rotation; blending toward the sign-flipped copy
      // must not swing the long way round.
      final out = List<double>.filled(4, 0);
      OrientationMath.nlerp(
        <double>[0, 0, 0, 1],
        <double>[0, 0, 0, -1],
        0.5,
        out,
      );
      expect(out[3].abs(), closeTo(1.0, 1e-9));
    });
  });
}
