import CoreMotion
import Flutter

/// Native (iOS) device-motion source for the `com.mayasabhaxr.recapture/sensors`
/// `FlutterEventChannel` — the iOS half of the `SensorStreamChannel` contract the
/// Dart `SensorStreamPayload.fromMap` already decodes.
///
/// Reads `CMDeviceMotion.attitude` from a single `CMMotionManager`, converts the
/// attitude quaternion → yaw/pitch/roll, and streams a W3C-style payload
/// (`alpha`/`beta`/`gamma` degrees + gravity-excluded acceleration in m/s²). It
/// starts on subscribe, stops on cancel, throttles to a clamped rate, and
/// degrades cleanly (a single `deviceMotionSupported: false` marker) where device
/// motion is unavailable (e.g. the simulator).
///
/// Threading: sampling runs on a dedicated serial `OperationQueue`; sink events
/// are always delivered on the main thread (Flutter sinks require it). The motion
/// closure captures `self` weakly so a deallocated handler can't be used after
/// free, and `eventSink` is read on main so an in-flight frame never emits after
/// cancel.
///
/// CoreMotion attitude/acceleration require NO runtime permission and NO
/// `NSMotionUsageDescription` (only activity/pedometer do — see the project's iOS
/// permission decision), so this neither prompts nor reads `Info.plist`. The
/// Flutter Motion gate governs only WHETHER the app subscribes, not this handler.
///
/// Scope is device motion only — no capture/photo logic (that is a separate
/// channel).
final class SensorStreamHandler: NSObject, FlutterStreamHandler {

  static let channelName = "com.mayasabhaxr.recapture/sensors"

  /// Default sampling rate, and the hard cap a caller can request (protects
  /// battery/CPU on low-end devices). The rate is read from the optional listen
  /// argument `{ "rateHz": <num> }`, else the default; always clamped to the cap.
  static let defaultUpdateHz = 30
  static let maxUpdateHz = 60

  /// Standard gravity — converts CoreMotion's g-unit `userAcceleration` to the
  /// m/s² the Dart `AccelerometerVector` documents (W3C `acceleration`,
  /// gravity-excluded).
  private static let standardGravity = 9.80665

  /// One manager per handler (documented best practice — never several).
  private let motionManager = CMMotionManager()
  private let queue: OperationQueue
  private var eventSink: FlutterEventSink?

  override init() {
    queue = OperationQueue()
    queue.name = "com.mayasabhaxr.recapture.sensors.motion"
    queue.maxConcurrentOperationCount = 1
    super.init()
  }

  // MARK: - FlutterStreamHandler (called on the main thread)

  func onListen(
    withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink
  ) -> FlutterError? {
    eventSink = events
    startUpdates(arguments: arguments)
    return nil
  }

  func onCancel(withArguments arguments: Any?) -> FlutterError? {
    stopUpdates()
    eventSink = nil
    return nil
  }

  deinit {
    stopUpdates()
  }

  // MARK: - Updates

  private func startUpdates(arguments: Any?) {
    guard motionManager.isDeviceMotionAvailable else {
      // Simulator / restricted device: emit a single unsupported marker so Dart
      // sees deviceMotionSupported == false, then stop (no dead loop).
      eventSink?(Self.unsupportedPayload())
      return
    }

    let hz = Self.resolveRate(from: arguments)
    motionManager.deviceMotionUpdateInterval = 1.0 / Double(hz)
    motionManager.startDeviceMotionUpdates(
      using: .xArbitraryZVertical,  // fixed, gravity-aligned Z → consistent yaw baseline
      to: queue
    ) { [weak self] motion, error in
      guard let self = self, let motion = motion, error == nil else { return }
      let payload = Self.makePayload(from: motion)
      // Hop to main for the sink; re-check eventSink there so an in-flight frame
      // never emits after onCancel cleared it.
      DispatchQueue.main.async {
        self.eventSink?(payload)
      }
    }
  }

  /// Idempotent: safe to call repeatedly (cancel, deinit, rapid re-listen).
  private func stopUpdates() {
    if motionManager.isDeviceMotionActive {
      motionManager.stopDeviceMotionUpdates()
    }
    queue.cancelAllOperations()
  }

  // MARK: - Payload

  private static func resolveRate(from arguments: Any?) -> Int {
    let requested = (arguments as? [String: Any])?["rateHz"] as? NSNumber
    let hz = requested?.intValue ?? defaultUpdateHz
    return min(maxUpdateHz, max(1, hz))
  }

  private static func makePayload(from motion: CMDeviceMotion) -> [String: Any] {
    let (yaw, pitch, roll) = eulerFromQuaternion(motion.attitude.quaternion)
    let rad2deg = 180.0 / Double.pi
    let acc = motion.userAcceleration  // g, gravity-excluded
    return [
      "timestamp": Int(Date().timeIntervalSince1970 * 1000),
      "orientation": [
        "alpha": yaw * rad2deg,    // yaw   (Z)
        "beta": pitch * rad2deg,   // pitch (X/Y per convention below)
        "gamma": roll * rad2deg,   // roll
      ],
      "accelerometer": [
        "x": acc.x * standardGravity,
        "y": acc.y * standardGravity,
        "z": acc.z * standardGravity,
      ],
      "deviceMotionSupported": true,
      // Additive (Dart decoder ignores unknown keys): raw radians for any
      // downstream pitch-band / pose logic that needs them without a deg→rad trip.
      "attitude": ["yaw": yaw, "pitch": pitch, "roll": roll],
    ]
  }

  private static func unsupportedPayload() -> [String: Any] {
    return [
      "timestamp": Int(Date().timeIntervalSince1970 * 1000),
      "orientation": ["alpha": 0.0, "beta": 0.0, "gamma": 0.0],
      "accelerometer": ["x": 0.0, "y": 0.0, "z": 0.0],
      "deviceMotionSupported": false,
    ]
  }

  /// Attitude quaternion → (yaw, pitch, roll) in radians, ZYX intrinsic. NaN-free:
  /// `atan2` for yaw/roll, and `asin` clamped via `copysign` at the ±90° pitch
  /// gimbal-lock pole.
  static func eulerFromQuaternion(_ q: CMQuaternion) -> (yaw: Double, pitch: Double, roll: Double) {
    let w = q.w, x = q.x, y = q.y, z = q.z

    // roll (X)
    let sinrCosp = 2 * (w * x + y * z)
    let cosrCosp = 1 - 2 * (x * x + y * y)
    let roll = atan2(sinrCosp, cosrCosp)

    // pitch (Y) — clamp at the pole so asin never receives |v| > 1 (no NaN)
    let sinp = 2 * (w * y - z * x)
    let pitch = abs(sinp) >= 1 ? copysign(Double.pi / 2, sinp) : asin(sinp)

    // yaw (Z)
    let sinyCosp = 2 * (w * z + x * y)
    let cosyCosp = 1 - 2 * (y * y + z * z)
    let yaw = atan2(sinyCosp, cosyCosp)

    return (yaw, pitch, roll)
  }
}
