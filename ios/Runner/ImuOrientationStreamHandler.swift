import CoreMotion
import Flutter
import UIKit

/// iOS side of the smoothed-orientation `imu_orientation` `FlutterEventChannel`
/// (`com.mayasabhaxr.recapture/imu_orientation`) — the counterpart to the Android
/// `ImuRotationStreamManager.orientationHandler`. Streams low-pass-filtered
/// yaw/pitch/roll + the smoothed quaternion at 50–100 Hz for the capture
/// level/orientation guide, decoded unchanged by the Dart `ImuOrientationStream`
/// / `SmoothedOrientation`.
///
/// Source: `CMDeviceMotion.attitude.quaternion` (CoreMotion's fused attitude),
/// fed through the shared `OrientationFilter` (ported from Android) so smoothing
/// semantics, the τ knob, and the `getOrientation`-convention Euler derivation all
/// match the Android channel. Payload per sample:
///   `{ yaw, pitch, roll, q:[qx,qy,qz,qw], timestampNs }`.
///
/// Threading: device-motion callbacks run on a dedicated serial `OperationQueue`
/// (never main, even at 100 Hz); the filter runs there (cheap quaternion ops) and
/// only the sink emit hops to main (the FlutterEventSink contract). `[weak self]`
/// + a main-thread `eventSink` re-check mean an in-flight frame never emits after
/// cancel.
///
/// Clock domain: `CMDeviceMotion.timestamp` is seconds on the mach uptime clock —
/// the same base AVFoundation capture timestamps use — so `timestampNs`
/// (`timestamp * 1e9`) is the iOS analog of Android's camera-monotonic join key.
///
/// Lifecycle: updates start on subscribe, stop on cancel; backgrounding stops them
/// and foregrounding resumes (with a filter reset) while still subscribed — no
/// battery drain or leaked callbacks. Device motion requires NO runtime permission
/// or Info.plist string (only activity/pedometer do).
///
/// Availability: if device motion is unavailable (e.g. the simulator), a single
/// `SENSOR_UNAVAILABLE` FlutterError is emitted (→ Dart stream
/// `PlatformException`), matching the Android channel — not a silent empty stream.
final class ImuOrientationStreamHandler: NSObject, FlutterStreamHandler {

  static let channelName = "com.mayasabhaxr.recapture/imu_orientation"

  private static let errUnavailable = "SENSOR_UNAVAILABLE"

  static let minRateHz = 50
  static let maxRateHz = 100
  static let defaultRateHz = 100

  /// One manager per handler (documented best practice).
  private let motionManager = CMMotionManager()
  private let queue: OperationQueue
  private let filter = OrientationFilter()

  private var eventSink: FlutterEventSink?
  /// True between onListen and onCancel; gates background→foreground resume.
  private var listening = false
  /// Resolved on listen, reused when resuming from background.
  private var rateHz = ImuOrientationStreamHandler.defaultRateHz

  #if DEBUG
  /// Frame counter for the ~1 Hz raw-vs-filtered debug log (debug builds only —
  /// compiled out of release entirely). Touched only on the motion queue + reset
  /// on cancel; diagnostic, so no cross-thread guarding.
  private var debugFrameCount = 0
  #endif

  override init() {
    queue = OperationQueue()
    queue.name = "com.mayasabhaxr.recapture.imu.orientation"
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
    rateHz = Self.resolveRate(arguments)
    filter.tauNs = Self.resolveTauNs(arguments)
    filter.reset()  // fresh subscription starts the filter clean
    listening = true

    guard motionManager.isDeviceMotionAvailable else {
      // Report unavailable (→ Dart PlatformException), parity with Android.
      events(FlutterError(
        code: Self.errUnavailable,
        message: "Device motion not available on this device.", details: nil))
      return nil
    }
    startUpdates()
    return nil
  }

  func onCancel(withArguments arguments: Any?) -> FlutterError? {
    listening = false
    stopUpdates()
    eventSink = nil
    #if DEBUG
    debugFrameCount = 0  // a re-subscription restarts the ~1 Hz log cadence
    #endif
    return nil
  }

  deinit {
    NotificationCenter.default.removeObserver(self)
    stopUpdates()
  }

  // MARK: - App lifecycle

  @objc private func appDidEnterBackground() {
    // Stop while away (CoreMotion has no background entitlement here anyway).
    stopUpdates()
  }

  @objc private func appWillEnterForeground() {
    guard listening, motionManager.isDeviceMotionAvailable else { return }
    filter.reset()  // don't blend across the background gap
    startUpdates()
  }

  // MARK: - Updates

  private func startUpdates() {
    guard motionManager.isDeviceMotionAvailable,
          !motionManager.isDeviceMotionActive else { return }
    motionManager.deviceMotionUpdateInterval = 1.0 / Double(rateHz)
    // .xArbitraryCorrectedZVertical: gyro-drift-corrected Z, no compass (avoids the
    // magnetometer calibration overlay) — a stable yaw baseline for the guide.
    motionManager.startDeviceMotionUpdates(
      using: .xArbitraryCorrectedZVertical, to: queue
    ) { [weak self] motion, error in
      guard let self = self, let motion = motion, error == nil else { return }
      let q = motion.attitude.quaternion  // (x, y, z, w)
      let tsNs = Int64(motion.timestamp * 1_000_000_000.0)
      let s = self.filter.filter(qx: q.x, qy: q.y, qz: q.z, qw: q.w, timestampNs: tsNs)
      let payload: [String: Any] = [
        "yaw": s.yaw,
        "pitch": s.pitch,
        "roll": s.roll,
        "q": [s.qx, s.qy, s.qz, s.qw],
        "timestampNs": s.timestampNs,
      ]
      DispatchQueue.main.async {
        self.eventSink?(payload)
      }

      #if DEBUG
      // Confirm filter activity: ~once per second, compare the instantaneous
      // (raw) yaw against the smoothed yaw. Both use the same toEuler convention,
      // so they are directly comparable; they diverge during motion (smoothing
      // working) and converge when still. rateHz frames ≈ 1 s at any rate.
      self.debugFrameCount += 1
      if self.debugFrameCount % self.rateHz == 0 {
        let rawYaw = OrientationMath.toEuler(q.x, q.y, q.z, q.w).yaw
        print("[ImuOrientation] raw yaw: \(rawYaw), filtered: \(s.yaw)")
      }
      #endif
    }
  }

  /// Idempotent (cancel / background / deinit / resume guard).
  private func stopUpdates() {
    if motionManager.isDeviceMotionActive {
      motionManager.stopDeviceMotionUpdates()
    }
    queue.cancelAllOperations()
  }

  // MARK: - Argument parsing

  /// `rateHz` hint, clamped to 50..100 (the Dart side also clamps).
  private static func resolveRate(_ arguments: Any?) -> Int {
    let requested = (arguments as? [String: Any])?["rateHz"] as? NSNumber
    let hz = requested?.intValue ?? defaultRateHz
    return min(maxRateHz, max(minRateHz, hz))
  }

  /// `tauMs` (smoothing time constant) → nanoseconds, coerced ≥ 0.
  private static func resolveTauNs(_ arguments: Any?) -> Double {
    let requested = (arguments as? [String: Any])?["tauMs"] as? NSNumber
    let tauMs = requested?.doubleValue ?? (OrientationFilter.defaultTauNs / 1_000_000.0)
    return max(0.0, tauMs * 1_000_000.0)
  }
}
