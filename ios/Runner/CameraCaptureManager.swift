import AVFoundation
import Flutter

/// Still-capture on the existing iOS preview session — the counterpart to the
/// Android `CameraCaptureManager`. Owns an `AVCapturePhotoOutput` that
/// `CameraPreviewManager` adds into the SAME `AVCaptureSession` as the preview
/// (no second session — that would fight the preview for the back camera), and
/// implements the existing `com.mayasabhaxr.recapture/capture` contract so the
/// Dart `CaptureChannel`/`CapturedFrame` decode unchanged.
///
/// Scope here is `captureSingle` (single still). It returns `{ id, path,
/// timestampNs }`: a JPEG — always, see `makeSettings` — written to an app-scoped
/// `captures/{sessionId}/` dir (Application Support — the iOS analog of Android's
/// app-scoped external files dir, NOT the system temp dir, NOT the photo
/// library). The Dart layer owns the file's fate.
///
/// Capture quality is set up in `configureOutput`, which the preview manager
/// calls while configuring the session: full-resolution stills on the `.photo`
/// preset with `.quality` prioritization. Those opt-ins are what make a capture
/// match the system camera rather than a dim, soft video-pipeline frame.
///
/// `timestampNs` is the photo's capture time (`AVCapturePhoto.timestamp`, the mach
/// host clock AVFoundation uses) so it aligns with the IMU/blur stream timestamps.
///
/// Burst / auto-capture / resolution-policy (the rest of the Android contract) and
/// the per-frame EXIF + sidecar metadata are deferred follow-ups; those methods
/// report `notImplemented` and the `captureEvents` EventChannel sink is managed
/// here ready for the burst task. No analytics is fired from Swift — the repo's
/// analytics seam is Dart/backend, so the Dart layer emits `photo_captured` after
/// it receives the path (per the task's own fallback assumption).
///
/// Threading: capture submission runs on a dedicated `captureQueue`; the
/// AVFoundation delegate callbacks land on an internal queue and every
/// `FlutterResult` is dispatched to main (FlutterResult is not thread-safe). All
/// mutable state is guarded by one `lock`. Camera permission is assumed granted
/// (P2 / preview); not-bound fails gracefully with `NO_CAMERA`.
final class CameraCaptureManager: NSObject, FlutterStreamHandler,
  AVCapturePhotoCaptureDelegate {

  // Must match AppConfig.channelCapture / channelCaptureEvents on the Dart side.
  static let channelName = "com.mayasabhaxr.recapture/capture"
  static let eventsChannelName = "com.mayasabhaxr.recapture/captureEvents"

  // Error codes (parity with the Android contract).
  private static let errNoCamera = "NO_CAMERA"
  private static let errBusy = "BUSY"
  private static let errWrite = "WRITE_FAILED"
  private static let errCapture = "CAPTURE_FAILED"

  /// Added into the preview session by `CameraPreviewManager`. Owns no session.
  let photoOutput = AVCapturePhotoOutput()

  private let captureQueue = DispatchQueue(label: "com.mayasabhaxr.recapture.capture")

  /// Guards all mutable state below (set/read across main, captureQueue, the
  /// preview's sessionQueue, and the photo delegate's internal queue).
  private let lock = NSLock()
  private var bound = false
  private var singleInFlight = false
  private var eventSink: FlutterEventSink?
  /// In-flight single captures keyed by `AVCapturePhotoSettings.uniqueID`.
  private var pending: [Int64: PendingCapture] = [:]

  private struct PendingCapture {
    let sessionId: String
    let dir: URL
    let result: FlutterResult
  }

  // MARK: - Session wiring (called by the preview manager on its session queue)

  /// The session is live (running) — captures may proceed.
  func onBound() {
    lock.lock()
    bound = true
    lock.unlock()
  }

  /// The session stopped/tore down. Fail any in-flight single so the Dart future
  /// never hangs; a late delegate callback then finds no pending entry and no-ops.
  func onUnbound() {
    lock.lock()
    bound = false
    singleInFlight = false
    let inflight = pending
    pending.removeAll()
    lock.unlock()
    for (_, pc) in inflight {
      reply(pc.result, FlutterError(
        code: Self.errNoCamera, message: "Session ended before capture completed.",
        details: nil))
    }
  }

  // MARK: - MethodChannel (main thread)

  func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "captureSingle":
      captureSingle(result: result)
    case "startBurst", "startAutoCapture", "stopAutoCapture",
      "configureCaptureResolution", "getActiveCaptureResolution":
      // Deferred follow-up (single-capture parity first).
      result(FlutterMethodNotImplemented)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private func captureSingle(result: @escaping FlutterResult) {
    lock.lock()
    if !bound {
      lock.unlock()
      result(FlutterError(
        code: Self.errNoCamera, message: "No bound camera session.", details: nil))
      return
    }
    if singleInFlight {
      lock.unlock()
      result(FlutterError(
        code: Self.errBusy, message: "A single capture is already in flight.",
        details: nil))
      return
    }
    singleInFlight = true
    lock.unlock()

    let sessionId = Self.newSessionId()
    let dir = Self.sessionDir(sessionId)
    captureQueue.async { [weak self] in
      guard let self = self else { return }
      let settings = self.makeSettings()
      self.lock.lock()
      self.pending[Int64(settings.uniqueID)] =
        PendingCapture(sessionId: sessionId, dir: dir, result: result)
      self.lock.unlock()
      self.photoOutput.capturePhoto(with: settings, delegate: self)
    }
  }

  /// Session-configuration-time setup of the photo output, called by
  /// `CameraPreviewManager` inside its begin/commitConfiguration block once the
  /// output is attached. It MUST run there: `maxPhotoQualityPrioritization` is a
  /// configuration-time property, and a per-capture request above the ceiling it
  /// sets raises an exception.
  func configureOutput(for device: AVCaptureDevice) {
    // Opt into the still pipeline's best work — multi-frame fusion and the
    // longer effective exposure that makes a hand-held indoor capture usable.
    // Left at the `.balanced` default, stills came out dark and soft; the cost
    // is added latency per shot, which this flow can afford because it already
    // waits for the user to hold steady.
    photoOutput.maxPhotoQualityPrioritization = .quality

    // Full sensor resolution rather than the active format's default, which is
    // often binned. More pixels on the object is directly more detail for the
    // reconstruction to work from.
    if #available(iOS 16.0, *) {
      let supported = device.activeFormat.supportedMaxPhotoDimensions
      if let largest = supported.max(by: {
        Int($0.width) * Int($0.height) < Int($1.width) * Int($1.height)
      }) {
        photoOutput.maxPhotoDimensions = largest
      }
    } else {
      photoOutput.isHighResolutionCaptureEnabled = true
    }
  }

  /// Fresh settings per capture (reusing an `AVCapturePhotoSettings` is illegal).
  ///
  /// JPEG, deliberately NOT HEIC. Every downstream layer assumes JPEG — the
  /// `StorageSegments` frame contract, the bundle packer that names each file
  /// `<ring>_NNNN.jpg` and copies the source bytes VERBATIM, and the upload's
  /// declared content type. Capturing HEVC therefore shipped HEIC bytes inside
  /// `.jpg` files, which is why Meshy rejected in-app captures while photos
  /// picked from the library (real JPEGs) reconstructed fine. It also matches
  /// Android, whose CameraX ImageCapture already produces JPEG.
  private func makeSettings() -> AVCapturePhotoSettings {
    let settings = AVCapturePhotoSettings(
      format: [AVVideoCodecKey: AVVideoCodecType.jpeg])

    // Mirror the ceiling `configureOutput` set (never exceed it — that throws).
    settings.photoQualityPrioritization = photoOutput.maxPhotoQualityPrioritization
    if #available(iOS 16.0, *) {
      settings.maxPhotoDimensions = photoOutput.maxPhotoDimensions
    } else {
      settings.isHighResolutionPhotoEnabled = photoOutput.isHighResolutionCaptureEnabled
    }

    // A capture ring needs CONSISTENT lighting. The default is `.auto`, so a
    // flash could fire on some frames of a ring and not others, handing the
    // reconstruction contradictory shading for the same surface.
    settings.flashMode = .off
    return settings
  }

  // MARK: - AVCapturePhotoCaptureDelegate (AVFoundation internal queue)

  func photoOutput(
    _ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto,
    error: Error?
  ) {
    let key = Int64(photo.resolvedSettings.uniqueID)
    lock.lock()
    let pc = pending.removeValue(forKey: key)
    singleInFlight = false
    lock.unlock()
    guard let pending = pc else { return }  // already failed via onUnbound/dispose

    if let error = error {
      reply(pending.result, FlutterError(
        code: Self.errCapture, message: error.localizedDescription, details: nil))
      return
    }
    guard let data = photo.fileDataRepresentation() else {
      reply(pending.result, FlutterError(
        code: Self.errCapture, message: "No photo data.", details: nil))
      return
    }

    // Always JPEG — see makeSettings for why the pipeline requires it.
    let ext = "jpg"
    let tsNs = Int64(photo.timestamp.seconds * 1_000_000_000.0)
    // id mirrors Android: "{sessionId}_{index:05}"; index 0 for a single capture.
    let id = String(format: "%@_%05d", pending.sessionId, 0)
    let fileName = String(format: "%@_%lld.%@", id, tsNs, ext)
    let url = pending.dir.appendingPathComponent(fileName)

    do {
      try FileManager.default.createDirectory(
        at: pending.dir, withIntermediateDirectories: true)
      try data.write(to: url, options: .atomic)
      reply(pending.result, [
        "id": id,
        "path": url.path,
        "timestampNs": tsNs,
      ])
    } catch {
      reply(pending.result, FlutterError(
        code: Self.errWrite, message: error.localizedDescription, details: nil))
    }
  }

  // MARK: - captureEvents StreamHandler (main) — for the burst/auto follow-up

  func onListen(
    withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink
  ) -> FlutterError? {
    lock.lock()
    eventSink = events
    lock.unlock()
    return nil
  }

  func onCancel(withArguments arguments: Any?) -> FlutterError? {
    lock.lock()
    eventSink = nil
    lock.unlock()
    return nil
  }

  func dispose() {
    lock.lock()
    let inflight = pending
    pending.removeAll()
    singleInFlight = false
    bound = false
    eventSink = nil
    lock.unlock()
    for (_, pc) in inflight {
      reply(pc.result, FlutterError(
        code: Self.errCapture, message: "Capture manager disposed.", details: nil))
    }
  }

  // MARK: - helpers

  private func reply(_ result: @escaping FlutterResult, _ value: Any?) {
    DispatchQueue.main.async { result(value) }
  }

  private static func newSessionId() -> String {
    return "cap_\(Int(Date().timeIntervalSince1970 * 1000))"
  }

  /// App-scoped, persistent, not user-visible — the iOS analog of Android's
  /// `getExternalFilesDir`. Falls back to the temp dir if Application Support is
  /// somehow unavailable. The Dart layer owns cleanup (no auto-purge here).
  private static func sessionDir(_ sessionId: String) -> URL {
    let base = FileManager.default
      .urls(for: .applicationSupportDirectory, in: .userDomainMask).first
      ?? URL(fileURLWithPath: NSTemporaryDirectory())
    return base.appendingPathComponent("captures").appendingPathComponent(sessionId)
  }
}
