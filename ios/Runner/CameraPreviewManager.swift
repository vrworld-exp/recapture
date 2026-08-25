import AVFoundation
import Flutter
import UIKit

/// Native (iOS) side of the `com.mayasabhaxr.recapture/camera_preview`
/// MethodChannel — the iOS counterpart to the Android `CameraPreviewManager`
/// (CameraX).
///
/// Where Android renders the live feed into an external Flutter texture
/// (Architecture Decision A), iOS embeds an `AVCaptureVideoPreviewLayer` in a
/// `FlutterPlatformView` (`UiKitView`). So this manager owns ONLY the
/// `AVCaptureSession` + its lifecycle; the preview layer is attached to the
/// session by the platform view (see `CameraPreviewPlatformView`). The
/// Flutter-facing contract is kept identical to Android: `start` / `stop` /
/// `dispose` over the same channel.
///
/// Scope is PREVIEW only — no still/burst capture, focus/exposure lock, or
/// sensor work (those are separate iOS tasks in this phase).
///
/// Threading: every `AVCaptureSession` configuration and `startRunning()` /
/// `stopRunning()` call is blocking and runs on a dedicated serial
/// `sessionQueue`, never the main thread; the preview layer / UI are touched
/// only on main (by the platform view). CAMERA permission is assumed granted by
/// the P2 gate — this class NEVER requests it and fails gracefully (a coded
/// error, no crash) if it is missing or no back camera exists.
///
/// Lifetime: a single instance lives for the app's lifetime (created at plugin
/// registration). Unlike Android — where `dispose` is terminal — `dispose` here
/// releases the camera/input + observers but leaves the manager reusable, so the
/// capture screen can be re-opened (a fresh Dart controller calls `start` again).
final class CameraPreviewManager: NSObject {

  static let channelName = "com.mayasabhaxr.recapture/camera_preview"

  // Error codes surfaced to Dart (CameraPreviewController maps these).
  private static let errPermission = "PERMISSION_DENIED"
  private static let errNoBack = "NO_BACK_CAMERA"
  private static let errConfig = "CONFIG_FAILED"

  // Native → Flutter callbacks on the same channel. Only transitions that the
  // explicit start/stop result cannot already convey are pushed here: an
  // interruption beginning, a background suspend ("suspended"), and an automatic
  // resume ("running") after an interruption / background / recoverable runtime
  // error. Fatal errors go through `cbError`.
  private static let cbStatusChanged = "onStatusChanged"
  private static let cbError = "onError"

  /// The session the embedded `AVCaptureVideoPreviewLayer` renders. Exposed to
  /// the platform view; mutated only on `sessionQueue`.
  let session = AVCaptureSession()

  /// All session configuration + start/stop run here (blocking AVFoundation
  /// calls must stay off the main thread).
  private let sessionQueue: DispatchQueue

  private let channel: FlutterMethodChannel

  /// Manual focus / exposure lock controls layered on the SAME device, sharing
  /// this manager's session queue. The device is handed to it on configure /
  /// teardown (see `configureSession` / `teardownSession`). Preview scope owns
  /// only the session; the controls mutate the device. See CameraControlsManager.
  private let controls: CameraControlsManager

  /// Optional real-time blur analyzer. When set (by the AppDelegate), its
  /// `AVCaptureVideoDataOutput` is added into the SAME session at configure so it
  /// sees preview frames — parity with Android binding `ImageAnalysis` alongside
  /// `Preview`. Best-effort: if the output can't be added, preview still works.
  /// See BlurAnalysisManager.
  var blurAnalyzer: BlurAnalysisManager?

  /// Optional still-capture manager. When set (by the AppDelegate), its
  /// `AVCapturePhotoOutput` is added into the SAME session at configure, and it
  /// is told when the session goes live / stops (so it captures only against a
  /// running session — parity with Android's onCameraBound/Unbound). See
  /// CameraCaptureManager.
  var captureManager: CameraCaptureManager?

  // sessionQueue-only state.
  private var deviceInput: AVCaptureDeviceInput?
  private var configured = false
  private var observersAdded = false
  /// Whether the app *intends* the session to run (set by start, cleared by
  /// stop/dispose). Gates auto-resume so we never restart a session the user
  /// deliberately stopped (e.g. on background).
  private var intendedRunning = false
  /// True only while the session was auto-paused because the app entered the
  /// background (set by the background handler, cleared on foreground / stop /
  /// dispose). Distinct from `intendedRunning`: it records that *we* paused a
  /// running session for backgrounding and must restore it — vs. a deliberate
  /// stop() the user made, which must NOT auto-resume. Accessed only on the
  /// session queue, like `intendedRunning`.
  private var pausedForBackground = false

  init(channel: FlutterMethodChannel) {
    self.channel = channel
    // One queue shared with the controls layer so device config + session config
    // serialize on the same thread.
    let queue = DispatchQueue(label: "com.mayasabhaxr.recapture.camera.session")
    self.sessionQueue = queue
    self.controls = CameraControlsManager(sessionQueue: queue)
    super.init()
  }

  // MARK: - MethodChannel entry points (called on the platform/main thread)

  func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "start": start(result: result)
    case "stop": stop(result: result)
    case "dispose": dispose(result: result)

    // Focus/exposure lock controls (parity with the Android contract) — delegated
    // to the controls layer, which mutates the bound device on the session queue.
    case "getCameraControlCapabilities":
      controls.getCapabilities(result: result)
    case "setExposureLock":
      controls.setExposureLock(boolArg(call, "locked"), result: result)
    case "setAutoWhiteBalanceLock":
      controls.setAutoWhiteBalanceLock(boolArg(call, "locked"), result: result)
    case "setFocusLocked":
      controls.setFocusLocked(boolArg(call, "locked"), result: result)
    case "setManualFocusDistance":
      controls.setManualFocusDistance(doubleArg(call, "distance"), result: result)
    case "unlockAll":
      controls.unlockAll(result: result)

    default: result(FlutterMethodNotImplemented)
    }
  }

  private func boolArg(_ call: FlutterMethodCall, _ key: String) -> Bool {
    return (call.arguments as? [String: Any])?[key] as? Bool ?? false
  }

  private func doubleArg(_ call: FlutterMethodCall, _ key: String) -> Double {
    guard let value = (call.arguments as? [String: Any])?[key] as? NSNumber else {
      return 0
    }
    return value.doubleValue
  }

  private func start(result: @escaping FlutterResult) {
    // Defensive permission check — we NEVER request here (the P2 gate owns the
    // request + NSCameraUsageDescription). Not-authorized fails gracefully.
    guard AVCaptureDevice.authorizationStatus(for: .video) == .authorized else {
      result(FlutterError(
        code: Self.errPermission, message: "CAMERA permission not granted.",
        details: nil))
      return
    }

    sessionQueue.async { [weak self] in
      guard let self = self else { return }
      if !self.configured {
        if let failure = self.configureSession() {
          DispatchQueue.main.async {
            result(FlutterError(
              code: failure.code, message: failure.message, details: nil))
          }
          return
        }
      }
      self.intendedRunning = true
      if !self.session.isRunning {
        self.session.startRunning()
      }
      // Session is live → still-capture may proceed (parity with onCameraBound).
      self.captureManager?.onBound()
      // Idempotent: a second start while already running just re-reports state.
      DispatchQueue.main.async { result(["status": "running"]) }
    }
  }

  private func stop(result: @escaping FlutterResult) {
    sessionQueue.async { [weak self] in
      guard let self = self else { return }
      self.intendedRunning = false
      self.pausedForBackground = false
      if self.session.isRunning {
        self.session.stopRunning()
      }
      // Session stopped → no captures (in-flight singles fail, not hang).
      self.captureManager?.onUnbound()
      DispatchQueue.main.async { result(nil) }
    }
  }

  private func dispose(result: @escaping FlutterResult) {
    // Observer removal must happen too; do it on the queue that owns the flag.
    sessionQueue.async { [weak self] in
      guard let self = self else { return }
      self.intendedRunning = false
      self.pausedForBackground = false
      if self.session.isRunning {
        self.session.stopRunning()
      }
      self.teardownSession()
      self.removeObservers()
      DispatchQueue.main.async { result(nil) }
    }
  }

  // MARK: - Session configuration (sessionQueue only)

  private struct ConfigFailure { let code: String; let message: String }

  /// Adds the back-camera input with a preview-appropriate preset. Returns a
  /// failure (no crash) if no back camera / input is available. Adds the
  /// interruption + runtime-error observers once configured.
  private func configureSession() -> ConfigFailure? {
    session.beginConfiguration()
    // `.high` is a sensible preview preset; capture resolution is a separate
    // iOS task. Fall back to whatever the device offers if it is unsupported.
    if session.canSetSessionPreset(.high) {
      session.sessionPreset = .high
    }

    guard let device = AVCaptureDevice.default(
      .builtInWideAngleCamera, for: .video, position: .back) else {
      session.commitConfiguration()
      return ConfigFailure(code: Self.errNoBack, message: "No back camera available.")
    }

    do {
      let input = try AVCaptureDeviceInput(device: device)
      guard session.canAddInput(input) else {
        session.commitConfiguration()
        return ConfigFailure(code: Self.errConfig, message: "Cannot add camera input.")
      }
      session.addInput(input)
      deviceInput = input
    } catch {
      session.commitConfiguration()
      return ConfigFailure(code: Self.errConfig, message: error.localizedDescription)
    }

    // Attach the blur analyzer's video-data output into the SAME session (parity
    // with Android binding ImageAnalysis alongside Preview). canAddOutput-gated;
    // analysis is best-effort — preview survives if it can't be added.
    if let output = blurAnalyzer?.videoOutput, session.canAddOutput(output) {
      session.addOutput(output)
    }

    // Attach the still-capture photo output into the SAME session (parity with
    // Android binding ImageCapture alongside Preview). canAddOutput-gated.
    if let photoOutput = captureManager?.photoOutput, session.canAddOutput(photoOutput) {
      session.addOutput(photoOutput)
    }

    session.commitConfiguration()
    configured = true
    addObservers()
    // Hand the freshly bound device to the controls layer. A fresh bind resets
    // it to continuous auto (reset-to-auto on restart). We are on the session
    // queue, as the controls layer requires.
    controls.setDevice(deviceInput?.device)
    return nil
  }

  /// Releases the camera device but keeps the (empty) session reusable so a
  /// later `start` reconfigures from scratch.
  private func teardownSession() {
    // Drop the device from the controls layer first (no device ⇒ control calls
    // no-op with NO_CAMERA). We are on the session queue.
    controls.setDevice(nil)
    // Fail any in-flight capture (dispose skips stop()'s onUnbound).
    captureManager?.onUnbound()
    session.beginConfiguration()
    for input in session.inputs {
      session.removeInput(input)
    }
    // Remove the blur video-data output too (re-added on the next configure).
    for output in session.outputs {
      session.removeOutput(output)
    }
    session.commitConfiguration()
    deviceInput = nil
    configured = false
  }

  // MARK: - Interruptions + runtime errors (iOS-specific)

  private func addObservers() {
    guard !observersAdded else { return }
    let nc = NotificationCenter.default
    nc.addObserver(
      self, selector: #selector(sessionWasInterrupted(_:)),
      name: .AVCaptureSessionWasInterrupted, object: session)
    nc.addObserver(
      self, selector: #selector(sessionInterruptionEnded(_:)),
      name: .AVCaptureSessionInterruptionEnded, object: session)
    nc.addObserver(
      self, selector: #selector(sessionRuntimeError(_:)),
      name: .AVCaptureSessionRuntimeError, object: session)
    // App lifecycle: explicitly suspend a running session on background (so we
    // never hold the camera in the background) and restore it on foreground.
    // These are app-wide notifications (object: nil), not session-scoped.
    nc.addObserver(
      self, selector: #selector(appDidEnterBackground),
      name: UIApplication.didEnterBackgroundNotification, object: nil)
    nc.addObserver(
      self, selector: #selector(appWillEnterForeground),
      name: UIApplication.willEnterForegroundNotification, object: nil)
    observersAdded = true
  }

  private func removeObservers() {
    guard observersAdded else { return }
    let nc = NotificationCenter.default
    nc.removeObserver(self, name: .AVCaptureSessionWasInterrupted, object: session)
    nc.removeObserver(self, name: .AVCaptureSessionInterruptionEnded, object: session)
    nc.removeObserver(self, name: .AVCaptureSessionRuntimeError, object: session)
    nc.removeObserver(self, name: UIApplication.didEnterBackgroundNotification, object: nil)
    nc.removeObserver(self, name: UIApplication.willEnterForegroundNotification, object: nil)
    observersAdded = false
  }

  /// Session interrupted (incoming call, another camera client, iPad
  /// multitasking). Surface it so the UI can show "camera unavailable /
  /// resuming"; AVFoundation resumes automatically and posts interruptionEnded.
  @objc private func sessionWasInterrupted(_ note: Notification) {
    var reason = -1
    if let raw = note.userInfo?[AVCaptureSessionInterruptionReasonKey] as? Int {
      reason = raw
    }
    pushStatus("interrupted", extra: ["reason": reason])
  }

  @objc private func sessionInterruptionEnded(_ note: Notification) {
    resumeIfIntended()
  }

  /// A runtime error. Media-services-reset is recoverable — restart the session;
  /// anything else is surfaced as an error state for the UI.
  @objc private func sessionRuntimeError(_ note: Notification) {
    guard let error = note.userInfo?[AVCaptureSessionErrorKey] as? AVError else {
      return
    }
    if error.code == .mediaServicesWereReset {
      resumeIfIntended()
    } else {
      pushError(Self.errConfig, error.localizedDescription)
    }
  }

  /// Restart on the session queue, but only if the app still wants it running
  /// (never revive a session the user stopped/backgrounded). Reports "running"
  /// to Flutter so the UI can clear an interrupted state.
  private func resumeIfIntended() {
    sessionQueue.async { [weak self] in
      guard let self = self,
            self.intendedRunning, self.configured, !self.session.isRunning else {
        return
      }
      self.session.startRunning()
      self.pushStatus("running")
    }
  }

  // MARK: - App lifecycle (background suspend / foreground resume)

  /// App backgrounded: explicitly suspend a *running* session so we don't hold
  /// the camera in the background (iOS would otherwise interrupt it anyway, but
  /// pausing is cleaner and lets us report a definite "suspended" state). We
  /// leave `intendedRunning` intact so the foreground handler knows to restore
  /// it, and we do NOT tear down capture (`onUnbound`) — an in-flight single
  /// capture still receives its AVFoundation delegate callback and completes
  /// normally; cancelling it here would break that guarantee.
  @objc private func appDidEnterBackground() {
    sessionQueue.async { [weak self] in
      guard let self = self else { return }
      guard self.session.isRunning else { return }
      self.session.stopRunning()
      self.pausedForBackground = true
      self.pushStatus("suspended")
    }
  }

  /// App foregrounded: restore only a session we paused for the background.
  /// If the user called stop() while backgrounded, `intendedRunning` is false
  /// (and/or `pausedForBackground` was cleared), so we never revive it.
  @objc private func appWillEnterForeground() {
    sessionQueue.async { [weak self] in
      guard let self = self else { return }
      guard self.pausedForBackground else { return }
      self.pausedForBackground = false
      guard self.intendedRunning, self.configured, !self.session.isRunning else { return }
      self.session.startRunning()
      self.pushStatus("running")
    }
  }

  // MARK: - Native → Flutter pushes (main thread)

  private func pushStatus(_ status: String, extra: [String: Any] = [:]) {
    var args: [String: Any] = ["status": status]
    for (k, v) in extra { args[k] = v }
    DispatchQueue.main.async { [weak self] in
      self?.channel.invokeMethod(Self.cbStatusChanged, arguments: args)
    }
  }

  private func pushError(_ code: String, _ message: String) {
    DispatchQueue.main.async { [weak self] in
      self?.channel.invokeMethod(
        Self.cbError, arguments: ["code": code, "message": message])
    }
  }

  deinit {
    removeObservers()
  }
}
