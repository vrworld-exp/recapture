import Foundation

/// Pure, framework-free core of the stability gate — magnitude/unit helpers, the
/// validated threshold config, and the dt-aware dwell state machine. The iOS
/// counterpart to the Kotlin `StabilityMath` / `StabilityGate`, kept
/// behaviourally identical so both platforms open the shutter on the same motion.
///
/// The gate opens (STABLE) when gyroscope magnitude < `gyroThresh` rad/s AND
/// gravity-removed linear-acceleration magnitude < `accelThresh` (default 0.15 g),
/// held CONTINUOUSLY for `dwellMs`. The dwell is measured from sensor timestamps
/// (dt-aware), not a sample count or wall clock.
///
/// Free of CoreMotion/Flutter so it is unit-testable in isolation (mirrors
/// `OrientationFilter` / `StorageSegments`).
enum StabilityMath {
  /// Standard gravity (m/s²) converting the g threshold to SI. Matches the Kotlin
  /// `StabilityMath.GRAVITY_MS2` exactly, so neither platform gates on a
  /// marginally different number.
  static let gravityMs2 = 9.81

  /// Euclidean magnitude of a 3-vector.
  static func magnitude(_ x: Double, _ y: Double, _ z: Double) -> Double {
    (x * x + y * y + z * z).squareRoot()
  }

  /// Converts a g value (e.g. 0.15) to m/s² (0.15 × 9.81 ≈ 1.47).
  static func gToMs2(_ g: Double) -> Double { g * gravityMs2 }

  /// Continuous stillness score in [0,1] for a UI meter: 1.0 when perfectly still,
  /// falling to 0.0 as EITHER signal reaches its threshold. The geometric mean of
  /// the two clamped proximity-to-threshold partials, so one signal alone can
  /// collapse it — mirroring the gate's AND. An INSTANTANEOUS display signal, NOT
  /// the debounced gate decision (that stays in `StabilityGate`).
  static func score(
    gyroMag: Double, linAccelMag: Double, gyroThresh: Double, accelThresh: Double
  ) -> Double {
    let g = partial(gyroMag, gyroThresh)
    let a = partial(linAccelMag, accelThresh)
    return (g * a).squareRoot()
  }

  /// A non-positive threshold ⇒ 0 (maximum penalty), never a divide-by-zero; a
  /// non-finite magnitude ⇒ 0.
  private static func partial(_ value: Double, _ threshold: Double) -> Double {
    guard value.isFinite, threshold > 0 else { return 0 }
    return 1.0 - min(max(value / threshold, 0.0), 1.0)
  }
}

/// Validated stability thresholds. Build via `build` to apply defaults/clamps.
struct StabilityConfig {
  static let defaultGyroThreshRadS = 0.8
  static let defaultAccelThreshG = 0.15
  static let defaultDwellMs: Int64 = 250

  /// Beyond this inter-sample gap, the dwell breaks (pause/dropped samples).
  static let defaultGapResetNs: Int64 = 500_000_000

  let gyroThreshRadS: Double
  /// Linear-accel threshold in **m/s²** (converted from the g input).
  let accelThreshMs2: Double
  let dwellNs: Int64
  let gapResetNs: Int64

  init(
    gyroThreshRadS: Double, accelThreshMs2: Double, dwellNs: Int64,
    gapResetNs: Int64 = StabilityConfig.defaultGapResetNs
  ) {
    self.gyroThreshRadS = gyroThreshRadS
    self.accelThreshMs2 = accelThreshMs2
    self.dwellNs = dwellNs
    self.gapResetNs = gapResetNs
  }

  static let `default` = StabilityConfig(
    gyroThreshRadS: defaultGyroThreshRadS,
    accelThreshMs2: StabilityMath.gToMs2(defaultAccelThreshG),
    dwellNs: defaultDwellMs * 1_000_000)

  /// Builds a config from optional inputs, applying defaults for any that are
  /// missing/invalid (non-finite or non-positive thresholds, negative dwell).
  /// `accelThreshG` is in g and converted to m/s² here — the single, explicit unit
  /// conversion (no silent ×9.81 elsewhere).
  static func build(
    gyroThreshRadS: Double?, accelThreshG: Double?, dwellMs: Int64?
  ) -> StabilityConfig {
    let gyro = gyroThreshRadS.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
      ?? defaultGyroThreshRadS
    let accelG = accelThreshG.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
      ?? defaultAccelThreshG
    let dwell = dwellMs.flatMap { $0 >= 0 ? $0 : nil } ?? defaultDwellMs
    return StabilityConfig(
      gyroThreshRadS: gyro,
      accelThreshMs2: StabilityMath.gToMs2(accelG),
      dwellNs: dwell * 1_000_000)
  }
}

/// A debounced stability transition: produced only when `stable` flips.
struct StabilityTransition {
  let stable: Bool
  let gyroMag: Double
  let linAccelMag: Double
  let timestampNs: Int64
}

/// An instantaneous (non-debounced) stability reading: the continuous `score` plus
/// the magnitudes it was computed from. Surfaced throttled for a UI stillness
/// meter, distinct from `StabilityTransition`.
struct StabilityReading {
  let score: Double
  let gyroMag: Double
  let linAccelMag: Double
}

/// dt-aware dwell state machine. Fed the gyro + linear-accel magnitudes of each
/// sample; returns a `StabilityTransition` only when the debounced state flips
/// (entered or left STABLE), never per sample.
///
/// Threshold comparison is strict `<` (a value exactly at the threshold is NOT
/// stable). A break in the condition, or an inter-sample gap beyond
/// `StabilityConfig.gapResetNs` (background/resume, dropped samples), resets the
/// dwell — so no false STABLE is emitted across a gap.
///
/// Unlike Android — where gyro and linear-accel are independent sensor streams and
/// the AND is evaluated on the most-recent value of EACH — iOS delivers both in one
/// fused `CMDeviceMotion` sample, so a single `onSample` entry point replaces the
/// `onGyro`/`onLinearAccel` pair. The dwell/gap/transition semantics are unchanged.
///
/// Samples arrive on the motion queue while `reset`/`setConfig` come from main, so
/// an `NSLock` guards all state (mirrors the Kotlin `@Synchronized`). The lock is
/// non-reentrant; private helpers assume the caller already holds it.
final class StabilityGate {

  private let lock = NSLock()
  private var config: StabilityConfig

  private var gyroMag = Double.nan
  private var linAccelMag = Double.nan
  private var hasSample = false

  /// Sensor timestamp when the condition first became true, or nil.
  private var conditionStartTs: Int64?
  private var stable = false
  private var lastSampleTs: Int64?

  init(config: StabilityConfig = .default) {
    self.config = config
  }

  func setConfig(_ config: StabilityConfig) {
    lock.lock()
    self.config = config
    lock.unlock()
  }

  func reset() {
    lock.lock()
    defer { lock.unlock() }
    gyroMag = .nan
    linAccelMag = .nan
    hasSample = false
    conditionStartTs = nil
    stable = false
    lastSampleTs = nil
  }

  /// Feeds one fused sample. Returns a transition only when the state flips.
  func onSample(
    gyroMag: Double, linAccelMag: Double, timestampNs: Int64
  ) -> StabilityTransition? {
    lock.lock()
    defer { lock.unlock() }
    self.gyroMag = gyroMag
    self.linAccelMag = linAccelMag
    hasSample = true
    return evaluate(timestampNs)
  }

  /// The current instantaneous stillness reading, or nil before the first sample
  /// (so an early, misleading score is never surfaced). Independent of the
  /// debounced gate state.
  func currentReading() -> StabilityReading? {
    lock.lock()
    defer { lock.unlock() }
    guard hasSample else { return nil }
    return StabilityReading(
      score: StabilityMath.score(
        gyroMag: gyroMag, linAccelMag: linAccelMag,
        gyroThresh: config.gyroThreshRadS, accelThresh: config.accelThreshMs2),
      gyroMag: gyroMag,
      linAccelMag: linAccelMag)
  }

  private func evaluate(_ ts: Int64) -> StabilityTransition? {
    let last = lastSampleTs
    lastSampleTs = ts
    // A large inter-sample gap breaks dwell continuity (pause / dropped run).
    if let last = last, ts - last > config.gapResetNs {
      conditionStartTs = nil
      if stable {
        stable = false
        return transition(false, ts)
      }
    }

    let condition = hasSample
      && gyroMag < config.gyroThreshRadS
      && linAccelMag < config.accelThreshMs2

    if !condition {
      conditionStartTs = nil
      guard stable else { return nil }
      stable = false
      return transition(false, ts)
    }

    // Condition holds: accumulate the dwell from the first satisfied timestamp.
    guard let start = conditionStartTs else {
      conditionStartTs = ts
      return nil
    }
    if !stable, ts - start >= config.dwellNs {
      stable = true
      return transition(true, ts)
    }
    return nil
  }

  private func transition(_ becameStable: Bool, _ ts: Int64) -> StabilityTransition {
    StabilityTransition(
      stable: becameStable,
      gyroMag: gyroMag.isFinite ? gyroMag : 0,
      linAccelMag: linAccelMag.isFinite ? linAccelMag : 0,
      timestampNs: ts)
  }
}
