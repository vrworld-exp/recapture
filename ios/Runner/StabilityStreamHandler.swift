import CoreMotion
import Flutter
import UIKit

/// iOS side of the stability-gate `FlutterEventChannel`
/// (`com.mayasabhaxr.recapture/stability`) — the counterpart to the Android
/// `StabilityStreamManager`. Streams a debounced STABLE/UNSTABLE state, a "stable"
/// trigger for the auto-capture flow, and a throttled continuous stillness score,
/// decoded unchanged by the Dart `StabilityGateStream` / `StabilityEvent`.
///
/// This is what opens the capture shutter: the Dart `stabilityProvider` feeds both
/// the shutter's readiness gate and the auto-capture trigger conjunction, so
/// without this channel neither guided auto-capture nor the Meshy shutter (whose
/// hard gate disables the sensor fail-open) can ever fire.
///
/// ## The gate
/// gyro magnitude < `gyroThresh` (default 0.8 rad/s) AND gravity-removed
/// linear-accel magnitude < `accelThresh` (default 0.15 g ≈ 1.47 m/s²), held
/// continuously for `dwellMs` (default 250) — see `StabilityGate`.
///
/// ## Source: one fused device-motion sample
/// `CMDeviceMotion` carries BOTH `rotationRate` (rad/s, bias-corrected) and
/// `userAcceleration` (g, gravity already removed) at one timestamp, so — unlike
/// Android, which fuses two independent sensor streams and needs a low-pass
/// gravity estimator where `TYPE_LINEAR_ACCELERATION` is missing — there is no
/// gravity removal to approximate and no fallback path. `userAcceleration` is
/// converted g → m/s² so the emitted `linAccelMag` is in the same unit the Dart
/// side documents and Android emits. The attitude reference frame is immaterial
/// here (neither signal depends on it), so the cheapest one is used.
///
/// ## Clock domain
/// `CMDeviceMotion.timestamp` is seconds on the mach uptime clock — the same base
/// AVFoundation capture timestamps use — so `timestampNs` joins against capture
/// frames exactly as the IMU channel's does.
///
/// ## Threading / lifecycle
/// Motion callbacks run on a dedicated serial `OperationQueue` (never main); the
/// gate runs there and only sink emits hop to main (the FlutterEventSink contract).
/// Updates start on subscribe and stop on cancel; backgrounding stops them and
/// foregrounding resumes while still subscribed. Every (re)start resets the dwell,
/// so a stale condition never carries across a pause. Device motion requires NO
/// runtime permission or Info.plist string.
///
/// ## Availability
/// If device motion is unavailable (e.g. the simulator), a single
/// `STABILITY_UNAVAILABLE` FlutterError is emitted (→ Dart `PlatformException`,
/// which degrades to an unsupported sample) rather than a silently dead stream —
/// parity with the Android channel.
final class StabilityStreamHandler: NSObject, FlutterStreamHandler {

  // Must match AppConfig.channelStability on the Dart side.
  static let channelName = "com.mayasabhaxr.recapture/stability"

  private static let errUnavailable = "STABILITY_UNAVAILABLE"

  /// Min spacing between continuous "score" events (~10 Hz) — a UI-meter cadence,
  /// well below the sample rate, so the channel isn't flooded.
  private static let scoreIntervalNs: Int64 = 100_000_000

  /// Sampling rate. Matches Android's `SENSOR_DELAY_GAME` (~50 Hz) — ample for a
  /// 250 ms dwell without the battery cost of the 100 Hz orientation stream.
  private static let updateHz = 50

  /// One manager per handler (documented best practice).
  private let motionManager = CMMotionManager()
  private let queue: OperationQueue
  private let gate = StabilityGate()

  private var eventSink: FlutterEventSink?
  /// True between onListen and onCancel; gates the background→foreground resume.
  private var listening = false
  /// Sensor timestamp of the last emitted score (0 = none this session). Written
  /// on the motion queue, and on main only before updates are running.
  private var lastScoreEmitNs: Int64 = 0

  override init() {
    queue = OperationQueue()
    queue.name = "com.mayasabhaxr.recapture.stability"
    queue.maxConcurrentOperationCount = 1
    super.init()
    NotificationCenter.default.addObserver(
      self, selector: #selector(appDidEnterBackground),
      name: UIApplication.didEnterBackgroundNotification, object: nil)
    NotificationCenter.default.addObserver(
      self, selector: #selector(appWillEnterForeground),
      name: UIApplication.willEnterForegroundNotification, object: nil)
  }

  // MARK: - FlutterStreamHandler (main thread)

  func onListen(
    withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink
  ) -> FlutterError? {
    eventSink = events
    gate.setConfig(Self.configFrom(arguments))
    listening = true

    guard motionManager.isDeviceMotionAvailable else {
      // Report unavailable (→ Dart PlatformException), parity with Android.
      events(FlutterError(
        code: Self.errUnavailable,
        message: "Stability sensors unavailable: device motion.", details: nil))
      return nil
    }
    startUpdates()
    return nil
  }

  func onCancel(withArguments arguments: Any?) -> FlutterError? {
    listening = false
    stopUpdates()
    eventSink = nil
    return nil
  }

  deinit {
    NotificationCenter.default.removeObserver(self)
    stopUpdates()
  }

  // MARK: - App lifecycle

  @objc private func appDidEnterBackground() {
    stopUpdates()
  }

  @objc private func appWillEnterForeground() {
    guard listening, motionManager.isDeviceMotionAvailable else { return }
    startUpdates()
  }

  // MARK: - Updates

  private func startUpdates() {
    guard motionManager.isDeviceMotionAvailable,
          !motionManager.isDeviceMotionActive else { return }
    // Fresh sensor session ⇒ no stale dwell carried across the pause, and a score
    // emitted promptly. Set before updates run, so the queue never races these.
    gate.reset()
    lastScoreEmitNs = 0
    motionManager.deviceMotionUpdateInterval = 1.0 / Double(Self.updateHz)
    motionManager.startDeviceMotionUpdates(
      using: .xArbitraryZVertical, to: queue
    ) { [weak self] motion, error in
      guard let self = self, let motion = motion, error == nil else { return }
      self.onMotion(motion)
    }
  }

  /// Idempotent (cancel / background / deinit / resume guard).
  private func stopUpdates() {
    if motionManager.isDeviceMotionActive {
      motionManager.stopDeviceMotionUpdates()
    }
    queue.cancelAllOperations()
  }

  // MARK: - Sampling (motion queue)

  private func onMotion(_ motion: CMDeviceMotion) {
    let tsNs = Int64(motion.timestamp * 1_000_000_000.0)
    let rate = motion.rotationRate  // rad/s, bias-corrected
    let acc = motion.userAcceleration  // g, gravity already removed
    let gyroMag = StabilityMath.magnitude(rate.x, rate.y, rate.z)
    let linAccelMag = StabilityMath.gToMs2(
      StabilityMath.magnitude(acc.x, acc.y, acc.z))

    if let transition = gate.onSample(
      gyroMag: gyroMag, linAccelMag: linAccelMag, timestampNs: tsNs) {
      emit(transition)
    }
    maybeEmitScore(tsNs)
  }

  // MARK: - Emit (sink touched on main)

  private func emit(_ t: StabilityTransition) {
    let state: [String: Any] = [
      "type": "state",
      "stable": t.stable,
      "gyroMag": t.gyroMag,
      "linAccelMag": t.linAccelMag,
      "timestampNs": t.timestampNs,
    ]
    // On entering STABLE, also emit the auto-capture trigger.
    let trigger: [String: Any]? = t.stable
      ? ["type": "trigger", "event": "stable", "timestampNs": t.timestampNs]
      : nil
    DispatchQueue.main.async { [weak self] in
      guard let sink = self?.eventSink else { return }
      sink(state)
      if let trigger = trigger { sink(trigger) }
    }
  }

  /// Emits the continuous (non-debounced) stillness score, throttled to
  /// `scoreIntervalNs`, once a sample has landed. For a UI meter — the debounced
  /// state/trigger remain the source of truth for auto-capture.
  private func maybeEmitScore(_ ts: Int64) {
    if lastScoreEmitNs != 0, ts - lastScoreEmitNs < Self.scoreIntervalNs { return }
    guard let reading = gate.currentReading() else { return }
    lastScoreEmitNs = ts
    let event: [String: Any] = [
      "type": "score",
      "score": reading.score,
      "gyroMag": reading.gyroMag,
      "linAccelMag": reading.linAccelMag,
      "timestampNs": ts,
    ]
    DispatchQueue.main.async { [weak self] in
      self?.eventSink?(event)
    }
  }

  // MARK: - Argument parsing

  /// `{ gyroThresh: rad/s, accelThresh: g, dwellMs }` — invalid/missing values fall
  /// back to the native defaults inside `StabilityConfig.build`.
  private static func configFrom(_ arguments: Any?) -> StabilityConfig {
    guard let map = arguments as? [String: Any] else { return .default }
    return StabilityConfig.build(
      gyroThreshRadS: (map["gyroThresh"] as? NSNumber)?.doubleValue,
      accelThreshG: (map["accelThresh"] as? NSNumber)?.doubleValue,
      dwellMs: (map["dwellMs"] as? NSNumber)?.int64Value)
  }
}
