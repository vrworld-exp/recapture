// lib/domain/capture/camera_tilt.dart
//
// Pure Dart — NO Flutter imports. The ONE tilt primitive for the guided
// capture: the angle between the BACK CAMERA's aim direction and world-up, on
// a 0–180° scale:
//
//     0° = camera aimed straight at the sky   (shooting the underside)
//    90° = camera level with the horizon      (eye-level ring)
//   180° = camera aimed straight at the ground (top-down shot)
//
// Derived from the smoothed unit quaternion (body→world, Android rotation-
// vector frames: device X right / Y up in portrait / Z out of the screen;
// world Z up), NOT from Euler pitch — pitch folds past vertical ([-90, +90])
// and cannot express this scale. The quaternion path has no fold, no
// wraparound, and no gimbal cases: the result is intrinsically [0, 180].
//
// Every consumer of "is the phone tilted right for this ring" (tilt meter,
// shutter gate, auto-capture) reads THIS scalar, so they can never disagree.
import 'dart:math' as math;

/// The tilt ceiling returned by [cameraTiltDegrees]. A physically perfect 180°
/// is clamped just below it so the `maxDegrees`-EXCLUSIVE [PitchBand] contract
/// (`high` = [110, 180)) still admits it — this is the ONE place that clamp
/// happens.
const double kCameraTiltMaxDegrees = 179.999;

/// The camera-tilt angle (degrees, [0, [kCameraTiltMaxDegrees]]) for the
/// body→world unit quaternion ([qx], [qy], [qz], [qw]).
///
/// The back camera looks along the device's −Z axis. Rotating v = (0, 0, −1)
/// by q and dotting with world-up (0, 0, 1) needs only the rotation matrix's
/// z-of-z element, so the closed form (with n = ‖q‖² for tolerance-normalized
/// input) is:
///
///   cos(tilt) = (qx² + qy² − qz² − qw²) / n
///
/// Returns [double.nan] for a degenerate quaternion: any NaN/Infinity
/// component, or ‖q‖² far from 1 (a broken/garbage reading — NOT the identity
/// (0,0,0,1), which is a valid pose: flat, screen up, camera at the ground →
/// 179.999 after the clamp). Callers already treat NaN as out-of-every-band
/// (band membership is IEEE-safe) and the tilt feed drops NaN samples.
double cameraTiltDegrees({
  required double qx,
  required double qy,
  required double qz,
  required double qw,
}) {
  if (!qx.isFinite || !qy.isFinite || !qz.isFinite || !qw.isFinite) {
    return double.nan;
  }
  final n = qx * qx + qy * qy + qz * qz + qw * qw;
  // A unit quaternion has ‖q‖² == 1; smoothing keeps it there. Anything far
  // off is a corrupt reading, not a pose — reject rather than "normalize"
  // garbage into a confident angle.
  if ((n - 1.0).abs() > 0.05) return double.nan;

  final cosTilt = ((qx * qx + qy * qy - qz * qz - qw * qw) / n)
      .clamp(-1.0, 1.0)
      .toDouble();
  final degrees = math.acos(cosTilt) * 180.0 / math.pi;
  return degrees.clamp(0.0, kCameraTiltMaxDegrees).toDouble();
}
