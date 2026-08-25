import AVFoundation
import Flutter

/// Manual focus / exposure **lock** controls layered onto the existing iOS
/// capture session owned by `CameraPreviewManager`. Operates on that session's
/// bound `AVCaptureDevice` — it never creates, reconfigures, or releases the
/// session/device. iOS counterpart to the Android `CameraControlsManager`
/// (Camera2 interop), kept to the same Flutter-facing contract so the capture
/// screen drives both platforms identically.
///
/// Unit difference vs Android (documented for the Dart layer): manual focus here
/// is a NORMALIZED `lensPosition` in `[0, 1]` (0 ≈ near, 1 ≈ far), NOT diopters.
/// `getCapabilities` therefore reports `focusDistanceRange { 0, 1 }`; callers use
/// the reported range and need not know the unit.
///
/// THE iOS RULE: every `AVCaptureDevice` property mutation is wrapped in
/// `lockForConfiguration()` / `unlockForConfiguration()` (the throw is handled,
/// never crashes) and runs on the shared `sessionQueue` — never the main thread.
///
/// Capabilities are device-gated: each control is offered only when the hardware
/// supports it, and a defensive call for an unsupported control no-ops with a
/// coded error (the Dart wrapper maps that to `success == false`).
///
/// Restart behavior (parallel to Android's reset-to-auto): [setDevice] is called
/// by the preview manager whenever the device binds/unbinds. A fresh bind resets
/// the device to continuous auto AF/AE/AWB, so a newly configured session always
/// starts in full auto and the capture flow re-locks as needed. (A plain
/// stop()/start() or a transient interruption does NOT reconfigure the device, so
/// locks persist across those; `unlockAll` is always available to restore auto.)
///
/// Scope is focus/exposure (+WB) control only — no permission, session lifecycle,
/// capture, or sensor work. Custom exposure (`setExposureModeCustom` duration/iso)
/// is intentionally NOT exposed: the cross-platform contract (and the Android
/// counterpart) has no field for it, so adding it would break parity. It is a
/// future capability-gated extension if the capture UX needs it.
final class CameraControlsManager {

  // Error codes surfaced to Dart (matching the Android contract; CameraControls
  // maps any PlatformException to success == false).
  private static let errNoCamera = "NO_CAMERA"
  private static let errUnsupported = "UNSUPPORTED"
  private static let errLockFailed = "CONFIG_LOCK_FAILED"

  /// Shared with `CameraPreviewManager` — all device config runs here.
  private let sessionQueue: DispatchQueue

  /// The active device. sessionQueue-only; set via [setDevice].
  private var device: AVCaptureDevice?

  init(sessionQueue: DispatchQueue) {
    self.sessionQueue = sessionQueue
  }

  // MARK: - Device binding (called by the preview manager ON the session queue)

  /// Binds/unbinds the active device. A fresh device is reset to continuous auto
  /// (the iOS analog of Android's reset-to-auto on rebind). Caller guarantees the
  /// session queue.
  func setDevice(_ device: AVCaptureDevice?) {
    self.device = device
    if let device = device {
      applyContinuousAuto(device)
    }
  }

  // MARK: - MethodChannel entry points (called on main; dispatch to sessionQueue)

  func getCapabilities(result: @escaping FlutterResult) {
    sessionQueue.async { [weak self] in
      guard let self = self, let device = self.device else {
        // No device → everything unsupported (UI hides all controls).
        Self.reply(result, [
          "aeLock": false, "awbLock": false, "manualFocus": false,
        ])
        return
      }
      let manualFocus = device.isFocusModeSupported(.locked)
        && device.isLockingFocusWithCustomLensPositionSupported
      var caps: [String: Any] = [
        "aeLock": device.isExposureModeSupported(.locked),
        "awbLock": device.isWhiteBalanceModeSupported(.locked),
        "manualFocus": manualFocus,
      ]
      if manualFocus {
        // Normalized lensPosition range (vs Android's diopter range).
        caps["focusDistanceRange"] = ["min": 0.0, "max": 1.0]
      }
      Self.reply(result, caps)
    }
  }

  func setExposureLock(_ locked: Bool, result: @escaping FlutterResult) {
    let mode: AVCaptureDevice.ExposureMode = locked ? .locked : .continuousAutoExposure
    mutate(result: result, supported: { $0.isExposureModeSupported(mode) }) {
      $0.exposureMode = mode
    }
  }

  func setAutoWhiteBalanceLock(_ locked: Bool, result: @escaping FlutterResult) {
    let mode: AVCaptureDevice.WhiteBalanceMode =
      locked ? .locked : .continuousAutoWhiteBalance
    mutate(result: result, supported: { $0.isWhiteBalanceModeSupported(mode) }) {
      $0.whiteBalanceMode = mode
    }
  }

  /// Holds the current focus (`.locked`, no hunting) or resumes continuous AF.
  func setFocusLocked(_ locked: Bool, result: @escaping FlutterResult) {
    let mode: AVCaptureDevice.FocusMode = locked ? .locked : .continuousAutoFocus
    mutate(result: result, supported: { $0.isFocusModeSupported(mode) }) {
      $0.focusMode = mode
    }
  }

  /// Manual focus via normalized `lensPosition` (clamped to `[0, 1]`). Requires
  /// `isLockingFocusWithCustomLensPositionSupported`.
  func setManualFocusDistance(_ position: Double, result: @escaping FlutterResult) {
    let clamped = Float(min(1.0, max(0.0, position)))
    mutate(
      result: result,
      supported: {
        $0.isFocusModeSupported(.locked)
          && $0.isLockingFocusWithCustomLensPositionSupported
      }
    ) {
      // Completion fires after we unlock — that is the documented pattern.
      $0.setFocusModeLocked(lensPosition: clamped, completionHandler: nil)
    }
  }

  /// Restore continuous auto AE/AF/AWB (each gated by support).
  func unlockAll(result: @escaping FlutterResult) {
    sessionQueue.async { [weak self] in
      guard let self = self, let device = self.device else {
        Self.reply(result, nil)  // nothing bound → already "auto", no-op success
        return
      }
      do {
        try device.lockForConfiguration()
        Self.setContinuousAuto(device)
        device.unlockForConfiguration()
        Self.reply(result, nil)
      } catch {
        Self.reply(result, FlutterError(
          code: Self.errLockFailed, message: error.localizedDescription, details: nil))
      }
    }
  }

  // MARK: - internals

  /// The shared lock/unlock-wrapped mutation path: dispatch to the session queue,
  /// verify a device is bound and the control is supported, then mutate inside
  /// `lockForConfiguration()` / `unlockForConfiguration()` (throw handled).
  private func mutate(
    result: @escaping FlutterResult,
    supported: @escaping (AVCaptureDevice) -> Bool,
    _ body: @escaping (AVCaptureDevice) -> Void
  ) {
    sessionQueue.async { [weak self] in
      guard let self = self, let device = self.device else {
        Self.reply(result, FlutterError(
          code: Self.errNoCamera, message: "No camera bound.", details: nil))
        return
      }
      guard supported(device) else {
        Self.reply(result, FlutterError(
          code: Self.errUnsupported,
          message: "Control not supported on this device.", details: nil))
        return
      }
      do {
        try device.lockForConfiguration()
        body(device)
        device.unlockForConfiguration()
        Self.reply(result, nil)
      } catch {
        // lockForConfiguration failed → no mutation happened, nothing to unlock.
        Self.reply(result, FlutterError(
          code: Self.errLockFailed, message: error.localizedDescription, details: nil))
      }
    }
  }

  /// Reset to continuous auto, wrapped in lock/unlock. Used on a fresh bind.
  private func applyContinuousAuto(_ device: AVCaptureDevice) {
    do {
      try device.lockForConfiguration()
      Self.setContinuousAuto(device)
      device.unlockForConfiguration()
    } catch {
      // Best-effort reset; a failure here just leaves the device at its defaults.
    }
  }

  /// Sets every supported mode back to continuous auto. Caller holds the
  /// configuration lock.
  private static func setContinuousAuto(_ device: AVCaptureDevice) {
    if device.isFocusModeSupported(.continuousAutoFocus) {
      device.focusMode = .continuousAutoFocus
    }
    if device.isExposureModeSupported(.continuousAutoExposure) {
      device.exposureMode = .continuousAutoExposure
    }
    if device.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance) {
      device.whiteBalanceMode = .continuousAutoWhiteBalance
    }
  }

  /// Delivers a FlutterResult back on the main thread.
  private static func reply(_ result: @escaping FlutterResult, _ value: Any?) {
    DispatchQueue.main.async { result(value) }
  }
}
