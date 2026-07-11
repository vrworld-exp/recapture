// test/capture/camera_tilt_test.dart
//
// Unit tests for the pure 0–180° camera-tilt primitive
// (lib/domain/capture/camera_tilt.dart) and its SmoothedOrientation
// convenience getter. Expected values are derived by hand per case: the back
// camera looks along device −Z, world up is +Z, and for a body→world unit
// quaternion q the camera·up dot is (qx² + qy² − qz² − qw²).
import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:recapture/domain/capture/camera_tilt.dart';
import 'package:recapture/platform/imu_rotation_channel.dart';

void main() {
  group('cameraTiltDegrees — canonical poses', () {
    test('identity (flat, screen up) → camera at the ground → 180, clamped',
        () {
      // q = (0,0,0,1): device frame == world frame, so the camera (−Z body)
      // points along −Z world (straight down). acos(−(−1)) = 180°, clamped to
      // 179.999 so the max-exclusive `high` [120, 180) band still admits it.
      final t = cameraTiltDegrees(qx: 0, qy: 0, qz: 0, qw: 1);
      expect(t, closeTo(kCameraTiltMaxDegrees, 1e-9));
      expect(t, lessThan(180.0));
    });

    test('rotated 90° about X (upright portrait) → horizon → 90', () {
      // q = (sin45, 0, 0, cos45): dot = sin²45 − cos²45 = 0 → acos(0) = 90°.
      final s = math.sin(math.pi / 4), c = math.cos(math.pi / 4);
      expect(
        cameraTiltDegrees(qx: s, qy: 0, qz: 0, qw: c),
        closeTo(90.0, 1e-9),
      );
    });

    test('rotated 180° about X (flat, screen down) → camera at the sky → 0',
        () {
      // q = (1,0,0,0): dot = 1 − 0 = 1 → acos(1) = 0°.
      expect(cameraTiltDegrees(qx: 1, qy: 0, qz: 0, qw: 0), closeTo(0.0, 1e-9));
    });

    test('rotated 120° about X (30° past vertical, leaning back) → 60', () {
      // q = (sin60, 0, 0, cos60) = (√3/2, 0, 0, 1/2):
      // dot = 3/4 − 1/4 = 1/2 → acos(1/2) = 60°.
      final s = math.sin(math.pi / 3), c = math.cos(math.pi / 3);
      expect(
        cameraTiltDegrees(qx: s, qy: 0, qz: 0, qw: c),
        closeTo(60.0, 1e-9),
      );
    });

    test('rotated 60° about X (30° short of vertical, aiming down) → 120', () {
      // q = (sin30, 0, 0, cos30) = (1/2, 0, 0, √3/2):
      // dot = 1/4 − 3/4 = −1/2 → acos(−1/2) = 120°.
      final s = math.sin(math.pi / 6), c = math.cos(math.pi / 6);
      expect(
        cameraTiltDegrees(qx: s, qy: 0, qz: 0, qw: c),
        closeTo(120.0, 1e-9),
      );
    });

    test('yaw does not change tilt (upright portrait + 90° about world Z)',
        () {
      // q_yaw(90°) ⊗ q_x(90°) = (0.5, 0.5, 0.5, 0.5):
      // dot = 0.25 + 0.25 − 0.25 − 0.25 = 0 → still 90°.
      expect(
        cameraTiltDegrees(qx: 0.5, qy: 0.5, qz: 0.5, qw: 0.5),
        closeTo(90.0, 1e-9),
      );
    });
  });

  group('cameraTiltDegrees — clamping and degeneracy', () {
    test('result never reaches 180 (max-exclusive band contract holds)', () {
      // The mathematically-exact 180° pose is the identity, covered above; a
      // near-180 pose stays untouched below the clamp.
      final nearFlat = cameraTiltDegrees(qx: 0.001, qy: 0, qz: 0, qw: 0.9999995);
      expect(nearFlat, lessThanOrEqualTo(kCameraTiltMaxDegrees));
      expect(nearFlat, greaterThan(179.0));
    });

    test('bottom end is exactly 0, never negative', () {
      expect(cameraTiltDegrees(qx: 1, qy: 0, qz: 0, qw: 0),
          greaterThanOrEqualTo(0.0));
    });

    test('NaN / Infinity components → NaN', () {
      expect(
          cameraTiltDegrees(qx: double.nan, qy: 0, qz: 0, qw: 1).isNaN, isTrue);
      expect(
          cameraTiltDegrees(qx: 0, qy: double.infinity, qz: 0, qw: 1).isNaN,
          isTrue);
    });

    test('non-unit / degenerate quaternion → NaN', () {
      // ‖q‖² = 0 (all-zero) and ‖q‖² = 4 are both far from 1.
      expect(cameraTiltDegrees(qx: 0, qy: 0, qz: 0, qw: 0).isNaN, isTrue);
      expect(cameraTiltDegrees(qx: 0, qy: 0, qz: 0, qw: 2).isNaN, isTrue);
    });

    test('slightly-off-unit quaternion (float drift) is tolerated', () {
      // ‖q‖² = 1.02 — within the tolerance window; must produce a real angle.
      final q = math.sqrt(1.02 / 2);
      expect(
        cameraTiltDegrees(qx: q, qy: 0, qz: 0, qw: q),
        closeTo(90.0, 1e-6),
      );
    });
  });

  group('SmoothedOrientation.cameraTiltDegrees', () {
    test('delegates to the pure function when a quaternion is present', () {
      final s = math.sin(math.pi / 4), c = math.cos(math.pi / 4);
      final o = SmoothedOrientation(
        yaw: 0,
        pitch: 0,
        roll: 0,
        qx: s,
        qy: 0,
        qz: 0,
        qw: c,
        timestampNs: 1,
      );
      expect(o.cameraTiltDegrees, closeTo(90.0, 1e-9));
    });

    test('event WITHOUT q parses with hasQuaternion=false → tilt is NaN '
        '(missing is distinguishable from the flat identity pose)', () {
      final o = SmoothedOrientation.fromEvent(
          {'yaw': 0.0, 'pitch': 0.0, 'roll': 0.0, 'timestampNs': 1});
      expect(o, isNotNull);
      expect(o!.hasQuaternion, isFalse);
      expect(o.cameraTiltDegrees.isNaN, isTrue);
    });

    test('event WITH q parses with hasQuaternion=true → real tilt', () {
      final o = SmoothedOrientation.fromEvent({
        'yaw': 0.0,
        'pitch': 0.0,
        'roll': 0.0,
        'q': [1.0, 0.0, 0.0, 0.0],
        'timestampNs': 1,
      });
      expect(o, isNotNull);
      expect(o!.hasQuaternion, isTrue);
      expect(o.cameraTiltDegrees, closeTo(0.0, 1e-9));
    });
  });
}
