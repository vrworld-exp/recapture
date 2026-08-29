// lib/platform/capture_ports/orientation_math.dart
//
// Pure Dart — NO Flutter, NO dart:io, NO dart:js_interop. The orientation math
// shared by the web sensor port and its tests.
//
// Two jobs:
//
//  1. **Parity port of the native filter.** [OrientationMath] and
//     [DartOrientationFilter] are a line-for-line port of the Android
//     `OrientationMath` / `OrientationFilter`
//     (android/app/src/main/kotlin/.../sensors/OrientationFilter.kt): the same
//     alpha = 1 - exp(-dt/tau) blend, the same double-cover-safe nlerp, the
//     same gap-reset policy, and the same `SensorManager.getOrientation`
//     convention Euler derivation (yaw = atan2(R1,R4), pitch = asin(-R7),
//     roll = atan2(-R6,R8)). Identical physical motion therefore produces
//     comparable band / stability behaviour on web and on native.
//
//  2. **The browser to app coordinate-frame conversion.**
//     [deviceOrientationQuaternion] maps a `DeviceOrientationEvent`'s
//     alpha/beta/gamma (+ `screen.orientation.angle`) onto the SAME body-to-
//     world unit quaternion [x, y, z, w] the native rotation-vector sensor
//     emits, so `cameraTiltDegrees` (lib/domain/capture/camera_tilt.dart)
//     yields the documented 0-180 degree scale with no per-platform case.
//
// Frames (they already agree, which is why this conversion is a rotation and
// not a remap): the W3C deviceorientation device frame is X right, Y towards
// the top of the screen, Z out of the screen in the device's NATURAL
// orientation, with the Earth frame East/North/Up — exactly Android's
// rotation-vector convention. The back camera looks along body -Z in both.
import 'dart:math' as math;

/// Quaternion helpers, in the `[x, y, z, w]` ordering the app uses everywhere.
abstract final class OrientationMath {
  /// Dot product (its sign tells same vs opposite cover).
  static double dot(List<double> a, List<double> b) =>
      a[0] * b[0] + a[1] * b[1] + a[2] * b[2] + a[3] * b[3];

  /// Time-constant blend factor `alpha = 1 - exp(-dt/tau)`, clamped to [0, 1].
  ///
  /// Degenerate ends match native: `tau <= 0` gives 1 (passthrough, no
  /// smoothing); `dt <= 0` gives 0 (no time elapsed means no update). Both
  /// arguments are in nanoseconds — only their ratio matters.
  static double alpha(double dtNs, double tauNs) {
    if (tauNs <= 0.0) return 1.0;
    if (dtNs <= 0.0) return 0.0;
    return (1.0 - math.exp(-dtNs / tauNs)).clamp(0.0, 1.0).toDouble();
  }

  /// Normalized lerp from [a] toward [b] by [t], written into [out] (which may
  /// alias [a]). Flips [b]'s sign when `dot(a, b) < 0` so the blend takes the
  /// shortest path across the quaternion double cover.
  static void nlerp(
    List<double> a,
    List<double> b,
    double t,
    List<double> out,
  ) {
    final s = dot(a, b) < 0.0 ? -1.0 : 1.0;
    final u = 1.0 - t;
    final x = u * a[0] + t * s * b[0];
    final y = u * a[1] + t * s * b[1];
    final z = u * a[2] + t * s * b[2];
    final w = u * a[3] + t * s * b[3];
    final norm = math.sqrt(x * x + y * y + z * z + w * w);
    if (norm <= 1e-12 || !norm.isFinite) {
      normalizeInto(s * b[0], s * b[1], s * b[2], s * b[3], out);
      return;
    }
    out[0] = x / norm;
    out[1] = y / norm;
    out[2] = z / norm;
    out[3] = w / norm;
  }

  /// Writes a normalized `[x, y, z, w]` into [out] (identity if degenerate).
  static void normalizeInto(
    double x,
    double y,
    double z,
    double w,
    List<double> out,
  ) {
    final norm = math.sqrt(x * x + y * y + z * z + w * w);
    if (norm <= 1e-12 || !norm.isFinite) {
      out[0] = 0.0;
      out[1] = 0.0;
      out[2] = 0.0;
      out[3] = 1.0;
      return;
    }
    out[0] = x / norm;
    out[1] = y / norm;
    out[2] = z / norm;
    out[3] = w / norm;
  }

  /// `[yaw, pitch, roll]` in radians from a unit quaternion `[x, y, z, w]`,
  /// matching `SensorManager.getOrientation` exactly (see the native
  /// `OrientationMath.toEuler`).
  static List<double> toEuler(double x, double y, double z, double w) {
    final r1 = 2.0 * (x * y - z * w);
    final r4 = 1.0 - 2.0 * (x * x + z * z);
    final r6 = 2.0 * (x * z - y * w);
    final r7 = 2.0 * (y * z + x * w);
    final r8 = 1.0 - 2.0 * (x * x + y * y);
    return <double>[
      math.atan2(r1, r4),
      math.asin((-r7).clamp(-1.0, 1.0).toDouble()),
      math.atan2(-r6, r8),
    ];
  }
}

/// A body-to-world unit quaternion in the app's `[x, y, z, w]` ordering.
class DeviceQuaternion {
  const DeviceQuaternion(this.x, this.y, this.z, this.w);

  /// The pose a device flat on its back reports (screen up, camera at the
  /// ground) — `cameraTiltDegrees` reads it as ~180 degrees.
  static const DeviceQuaternion identity = DeviceQuaternion(0, 0, 0, 1);

  final double x;
  final double y;
  final double z;
  final double w;

  List<double> get components => <double>[x, y, z, w];

  @override
  String toString() => 'DeviceQuaternion($x, $y, $z, $w)';
}

const double _degToRad = math.pi / 180.0;

/// Converts a `DeviceOrientationEvent`'s Tait-Bryan angles into the app's
/// body-to-world unit quaternion.
///
/// [alphaDeg] / [betaDeg] / [gammaDeg] are the raw event fields (degrees; the
/// W3C intrinsic Z-X'-Y'' sequence). [screenAngleDeg] is
/// `screen.orientation.angle` — the browser's own rotation of the viewport,
/// which the event angles do NOT include because they are always expressed in
/// the device's natural frame.
///
/// The screen angle is applied as a post-multiplied rotation about the device's
/// **Z axis** (`q * Rz(-angle)`), i.e. about the camera's optical axis. That
/// choice is deliberate and load-bearing:
///  - **camera tilt is invariant** under it (rotating about the camera axis
///    cannot change where the camera points), so the 0-180 tilt scale, the
///    band gate and the Meshy `[60, 180)` window are identical in portrait and
///    landscape;
///  - **roll becomes screen-relative**, which is what the roll warning means —
///    a phone the browser has rotated into landscape is level to the user;
///  - **yaw picks up a constant offset** per screen orientation, which is
///    harmless because ring position is measured against a per-ring `yawStart`
///    baseline, never as an absolute heading.
///
/// Returns [DeviceQuaternion.identity] if any angle is non-finite — a missing
/// `alpha` (no magnetometer, or `absolute: false` on some browsers) arrives as
/// null upstream and is defaulted there, not silently here.
DeviceQuaternion deviceOrientationQuaternion({
  required double alphaDeg,
  required double betaDeg,
  required double gammaDeg,
  double screenAngleDeg = 0,
}) {
  if (!alphaDeg.isFinite ||
      !betaDeg.isFinite ||
      !gammaDeg.isFinite ||
      !screenAngleDeg.isFinite) {
    return DeviceQuaternion.identity;
  }

  // Intrinsic Z(alpha) then X'(beta) then Y''(gamma), per the spec.
  final a = alphaDeg * _degToRad / 2.0;
  final b = betaDeg * _degToRad / 2.0;
  final g = gammaDeg * _degToRad / 2.0;
  final cA = math.cos(a), sA = math.sin(a);
  final cB = math.cos(b), sB = math.sin(b);
  final cG = math.cos(g), sG = math.sin(g);

  var w = cB * cG * cA - sB * sG * sA;
  var x = sB * cG * cA - cB * sG * sA;
  var y = cB * sG * cA + sB * cG * sA;
  var z = cB * cG * sA + sB * sG * cA;

  // Post-multiply by Rz(-screenAngle) = (0, 0, -sin(t/2), cos(t/2)).
  if (screenAngleDeg != 0) {
    final h = screenAngleDeg * _degToRad / 2.0;
    final c = math.cos(h);
    final s = -math.sin(h);
    final nw = w * c - z * s;
    final nx = x * c + y * s;
    final ny = y * c - x * s;
    final nz = z * c + w * s;
    w = nw;
    x = nx;
    y = ny;
    z = nz;
  }

  final out = List<double>.filled(4, 0);
  OrientationMath.normalizeInto(x, y, z, w, out);
  return DeviceQuaternion(out[0], out[1], out[2], out[3]);
}

/// Dart port of the native `OrientationFilter`: a dt-aware low-pass in the
/// quaternion domain (nlerp toward each new sample), with the same defaults.
///
/// Feeding it the browser's ~60 Hz `deviceorientation` samples produces the
/// same smoothing response as the native 50-100 Hz rotation-vector stream,
/// because the blend is a function of elapsed time, not of sample count.
class DartOrientationFilter {
  DartOrientationFilter({
    double tauNs = defaultTauNs,
    this.gapResetNs = defaultGapResetNs,
  }) : _tauNs = tauNs < 0 ? 0 : tauNs;

  /// 100 ms — smooth but not laggy for a live guide (native default).
  static const double defaultTauNs = 100000000.0;

  /// Beyond this inter-sample gap, re-initialize instead of blending (500 ms).
  static const int defaultGapResetNs = 500000000;

  final int gapResetNs;
  double _tauNs;

  double get tauNs => _tauNs;
  set tauNs(double value) => _tauNs = value < 0 ? 0 : value;

  final List<double> _smoothed = List<double>.filled(4, 0);
  bool _hasState = false;
  int _prevTimestampNs = 0;

  /// Forget state so the next sample re-initializes (subscribe / resume).
  void reset() => _hasState = false;

  /// Filters one `[x, y, z, w]` sample; [timestampNs] rides through unchanged.
  /// Returns the smoothed quaternion as `[x, y, z, w]` (a fresh list).
  List<double> filter(List<double> q, int timestampNs) {
    final dt = timestampNs - _prevTimestampNs;
    if (!_hasState || dt < 0 || dt > gapResetNs) {
      OrientationMath.normalizeInto(q[0], q[1], q[2], q[3], _smoothed);
      _hasState = true;
    } else {
      OrientationMath.nlerp(
        _smoothed,
        q,
        OrientationMath.alpha(dt.toDouble(), _tauNs),
        _smoothed,
      );
    }
    _prevTimestampNs = timestampNs;
    return List<double>.of(_smoothed);
  }
}
