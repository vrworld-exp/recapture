import Foundation

/// Pure, framework-free quaternion math for the orientation low-pass filter — a
/// line-for-line Swift port of the Android `OrientationMath` (Kotlin) so the iOS
/// `imu_orientation` stream produces numerically identical yaw/pitch/roll for a
/// given quaternion.
///
/// The Euler derivation reproduces Android's `SensorManager.getOrientation`
/// convention exactly (azimuth/pitch/roll in radians) from a quaternion-built
/// rotation matrix, computed from the *smoothed* quaternion (never by low-passing
/// Euler scalars). See android/.../sensors/OrientationFilter.kt.
///
/// NOTE: identical math does NOT guarantee identical absolute angles across
/// platforms — Android's `TYPE_ROTATION_VECTOR` and iOS CoreMotion attitude use
/// different world reference frames, so the yaw/pitch/roll BASELINE can differ.
/// The capture UX should zero/relative-reference per platform if it needs an
/// absolute heading. The payload shape + Euler convention are what match here.
enum OrientationMath {

  /// Dot product (sign indicates same vs opposite quaternion cover).
  static func dot(_ a: [Double], _ b: [Double]) -> Double {
    return a[0] * b[0] + a[1] * b[1] + a[2] * b[2] + a[3] * b[3]
  }

  /// Time-constant blend factor `α = 1 − exp(−dt/τ)`, clamped to [0,1].
  /// Degenerate ends: `τ ≤ 0` → 1 (passthrough); `dt ≤ 0` → 0 (no update).
  static func alpha(dtNs: Double, tauNs: Double) -> Double {
    if tauNs <= 0.0 { return 1.0 }
    if dtNs <= 0.0 { return 0.0 }
    return min(1.0, max(0.0, 1.0 - exp(-dtNs / tauNs)))
  }

  /// Normalized lerp from [a] toward [b] by [t], handling quaternion double-cover
  /// (shortest path on a `q`/`−q` flip). Returns a unit quaternion; falls back to
  /// the sign-corrected [b] if the norm collapses (defensive — shouldn't happen).
  static func nlerp(_ a: [Double], _ b: [Double], _ t: Double) -> [Double] {
    let s = dot(a, b) < 0.0 ? -1.0 : 1.0
    let u = 1.0 - t
    let x = u * a[0] + t * s * b[0]
    let y = u * a[1] + t * s * b[1]
    let z = u * a[2] + t * s * b[2]
    let w = u * a[3] + t * s * b[3]
    let norm = (x * x + y * y + z * z + w * w).squareRoot()
    if norm <= 1e-12 || !norm.isFinite {
      return normalize(s * b[0], s * b[1], s * b[2], s * b[3])
    }
    return [x / norm, y / norm, z / norm, w / norm]
  }

  /// Returns a normalized `[x,y,z,w]` (identity if degenerate).
  static func normalize(_ x: Double, _ y: Double, _ z: Double, _ w: Double) -> [Double] {
    let norm = (x * x + y * y + z * z + w * w).squareRoot()
    if norm <= 1e-12 || !norm.isFinite {
      return [0.0, 0.0, 0.0, 1.0]
    }
    return [x / norm, y / norm, z / norm, w / norm]
  }

  /// Derives `(yaw, pitch, roll)` (radians) from a unit quaternion `[x,y,z,w]`,
  /// matching `SensorManager.getOrientation`: yaw = atan2(R1,R4),
  /// pitch = asin(−R7) (clamped), roll = atan2(−R6,R8).
  static func toEuler(_ x: Double, _ y: Double, _ z: Double, _ w: Double)
    -> (yaw: Double, pitch: Double, roll: Double)
  {
    let r1 = 2.0 * (x * y - z * w)
    let r4 = 1.0 - 2.0 * (x * x + z * z)
    let r6 = 2.0 * (x * z - y * w)
    let r7 = 2.0 * (y * z + x * w)
    let r8 = 1.0 - 2.0 * (x * x + y * y)
    let yaw = atan2(r1, r4)
    let pitch = asin(min(1.0, max(-1.0, -r7)))
    let roll = atan2(-r6, r8)
    return (yaw, pitch, roll)
  }
}

/// A smoothed orientation sample: the filtered quaternion + derived YPR + ts.
struct SmoothedOrientationSample {
  let qx, qy, qz, qw: Double
  /// Yaw/pitch/roll in radians (SensorManager.getOrientation convention).
  let yaw, pitch, roll: Double
  /// Unchanged from the source sample (the downstream join key).
  let timestampNs: Int64
}

/// Stateful, dt-aware low-pass orientation filter operating in the quaternion
/// domain (nlerp toward each new sample), then deriving yaw/pitch/roll from the
/// smoothed quaternion — a Swift port of the Android `OrientationFilter`.
///
/// Policy mirrors Android: first sample / non-monotonic dt / large gap (> 500 ms)
/// re-initializes to the new sample; otherwise blends with `α = 1 − exp(−dt/τ)`
/// from consecutive sample timestamps (rate-independent). The smoothed quaternion
/// is re-normalized every step.
///
/// Thread-safety: the stream handler calls [filter] on its motion `OperationQueue`
/// and [reset] / `tauNs` from the main thread, so an `NSLock` guards all state
/// (mirrors the Kotlin `@Synchronized`). The lock is non-reentrant; internal code
/// touches the backing field directly while holding it.
final class OrientationFilter {

  /// Default time constant: 100 ms (matches `OrientationFilter.DEFAULT_TAU_NS`).
  static let defaultTauNs = 100_000_000.0

  /// Beyond this inter-sample gap, re-initialize instead of blending (500 ms).
  static let defaultGapResetNs: Int64 = 500_000_000

  private let lock = NSLock()
  private var _tauNs: Double
  private let gapResetNs: Int64

  private var smoothedQ: [Double] = [0.0, 0.0, 0.0, 1.0]
  private var hasState = false
  private var prevTimestampNs: Int64 = 0

  init(tauNs: Double = OrientationFilter.defaultTauNs,
       gapResetNs: Int64 = OrientationFilter.defaultGapResetNs) {
    _tauNs = max(0.0, tauNs)
    self.gapResetNs = gapResetNs
  }

  /// Smoothing time constant (ns), always coerced ≥ 0 (`τ = 0` ⇒ passthrough).
  var tauNs: Double {
    get { lock.lock(); defer { lock.unlock() }; return _tauNs }
    set { lock.lock(); _tauNs = max(0.0, newValue); lock.unlock() }
  }

  /// Forget state so the next sample re-initializes (subscribe / resume).
  func reset() {
    lock.lock()
    hasState = false
    lock.unlock()
  }

  /// Filters one source unit quaternion `[qx,qy,qz,qw]`; [timestampNs] is
  /// preserved unchanged on the output.
  func filter(qx: Double, qy: Double, qz: Double, qw: Double, timestampNs: Int64)
    -> SmoothedOrientationSample
  {
    lock.lock()
    defer { lock.unlock() }

    let dt = timestampNs - prevTimestampNs
    if !hasState || dt < 0 || dt > gapResetNs {
      // First sample / non-monotonic / large gap → snap to the new sample.
      smoothedQ = OrientationMath.normalize(qx, qy, qz, qw)
      hasState = true
    } else {
      let a = OrientationMath.alpha(dtNs: Double(dt), tauNs: _tauNs)
      smoothedQ = OrientationMath.nlerp(smoothedQ, [qx, qy, qz, qw], a)
    }
    prevTimestampNs = timestampNs

    let e = OrientationMath.toEuler(smoothedQ[0], smoothedQ[1], smoothedQ[2], smoothedQ[3])
    return SmoothedOrientationSample(
      qx: smoothedQ[0], qy: smoothedQ[1], qz: smoothedQ[2], qw: smoothedQ[3],
      yaw: e.yaw, pitch: e.pitch, roll: e.roll,
      timestampNs: timestampNs)
  }
}
