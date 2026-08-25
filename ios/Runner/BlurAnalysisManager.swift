import AVFoundation
import Flutter

/// Real-time blur detection on the iOS preview session — the counterpart to the
/// Android `BlurAnalysisManager` (CameraX `ImageAnalysis`). Per frame it extracts
/// the luma (Y) plane, downscales to 640px width, computes the variance of the
/// Laplacian (`BlurMetric`), and streams
/// `{ sharpnessScore, sharp, band, rejectBelow, acceptAbove, width, height,
/// timestampNs, frameIndex }` over the existing `com.mayasabhaxr.recapture/blur`
/// `FlutterEventChannel`, decoded unchanged by the Dart `BlurResult`. Provides the
/// METRIC + decision only — the accept/reject action lives in the capture flow.
///
/// ## Frame source + association
/// An `AVCaptureVideoDataOutput` is added into the SAME preview `AVCaptureSession`
/// (by `CameraPreviewManager` at configure). Its `videoSettings` request a YUV
/// biplanar **full-range** format so plane 0 is the luma in [0,255] — matching the
/// Android Y-plane luma and the threshold tuned on it. `timestampNs` is the sample
/// buffer's presentation timestamp (the mach host clock AVFoundation capture uses),
/// so the capture flow can associate a score with the right frame.
///
/// ## Backpressure + threading
/// `alwaysDiscardsLateVideoFrames = true` → slow processing DROPS frames (the
/// keep-only-latest analog of Android's STRATEGY_KEEP_ONLY_LATEST). Sample-buffer
/// callbacks run on a dedicated `analysisQueue` (never main); all handler state
/// (sink/threshold/policy/frameIndex) is confined to that queue, and only the emit
/// hops to main for the `FlutterEventSink`. When nobody is subscribed, frames are
/// dropped cheaply (no compute).
///
/// Scope is BLUR only. The Android side also shares this pass with a parallel
/// exposure channel; that is a separate iOS task — the single downscaled-luma pass
/// here is intentionally structured so it can be shared later.
final class BlurAnalysisManager: NSObject, FlutterStreamHandler,
  AVCaptureVideoDataOutputSampleBufferDelegate {

  /// Must match AppConfig.channelBlur on the Dart side.
  static let channelName = "com.mayasabhaxr.recapture/blur"

  /// Added into the preview session by `CameraPreviewManager`. Owns no session.
  let videoOutput: AVCaptureVideoDataOutput

  /// Dedicated queue for frame analysis + all handler state (serialized here).
  private let analysisQueue = DispatchQueue(
    label: "com.mayasabhaxr.recapture.blur.analysis")

  // analysisQueue-confined state.
  private var eventSink: FlutterEventSink?
  private var threshold = BlurMetric.defaultThreshold
  private var policy = BlurThresholdPolicy()
  private var frameIndex: Int64 = 0
  private var disposed = false

  override init() {
    let output = AVCaptureVideoDataOutput()
    output.alwaysDiscardsLateVideoFrames = true  // keep-only-latest
    output.videoSettings = [
      kCVPixelBufferPixelFormatTypeKey as String:
        kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
    ]
    videoOutput = output
    super.init()
    videoOutput.setSampleBufferDelegate(self, queue: analysisQueue)
  }

  // MARK: - FlutterStreamHandler (main thread)

  func onListen(
    withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink
  ) -> FlutterError? {
    let t = Self.thresholdArg(arguments)
    let p = Self.policyArg(arguments)
    // Confine all state to the analysis queue so the analyzer reads it race-free.
    analysisQueue.async { [weak self] in
      guard let self = self else { return }
      self.eventSink = events
      if let t = t { self.threshold = t }
      self.policy = p
    }
    return nil
  }

  func onCancel(withArguments arguments: Any?) -> FlutterError? {
    analysisQueue.async { [weak self] in self?.eventSink = nil }
    return nil
  }

  func dispose() {
    videoOutput.setSampleBufferDelegate(nil, queue: nil)
    analysisQueue.async { [weak self] in
      self?.disposed = true
      self?.eventSink = nil
    }
  }

  // MARK: - Sample-buffer delegate (analysisQueue)

  func captureOutput(
    _ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer,
    from connection: AVCaptureConnection
  ) {
    // Drop cheaply when nobody is subscribed (no luma copy, no compute).
    guard !disposed, let sink = eventSink else { return }
    guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer),
          let gray = Self.lumaGrayImage(from: pixelBuffer) else { return }

    let variance = BlurMetric.laplacianVariance(gray)
    let band = policy.classify(variance)
    let tsNs = Int64(
      CMSampleBufferGetPresentationTimeStamp(sampleBuffer).seconds * 1_000_000_000.0)
    let idx = frameIndex
    frameIndex += 1

    let payload: [String: Any] = [
      "sharpnessScore": variance,
      "sharp": variance >= threshold,
      "band": band.wire,
      "rejectBelow": policy.rejectBelow,
      "acceptAbove": policy.acceptAbove,
      "width": gray.width,
      "height": gray.height,
      "timestampNs": tsNs,
      "frameIndex": idx,
    ]
    DispatchQueue.main.async { sink(payload) }
  }

  // MARK: - Luma extraction

  /// Copies the YUV biplanar Y plane (plane 0) into a `BlurMetric.GrayImage`,
  /// downscaled to 640px. Reads by the plane's `bytesPerRow` (padding-safe,
  /// pixelStride 1). Returns nil if the buffer isn't the expected biplanar format.
  private static func lumaGrayImage(from pixelBuffer: CVPixelBuffer)
    -> BlurMetric.GrayImage?
  {
    guard CVPixelBufferGetPlaneCount(pixelBuffer) >= 1 else { return nil }
    CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }

    guard let base = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0) else {
      return nil
    }
    let width = CVPixelBufferGetWidthOfPlane(pixelBuffer, 0)
    let height = CVPixelBufferGetHeightOfPlane(pixelBuffer, 0)
    let rowBytes = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0)
    guard width > 0, height > 0, rowBytes > 0 else { return nil }

    let ptr = base.assumingMemoryBound(to: UInt8.self)
    let luma = [UInt8](UnsafeBufferPointer(start: ptr, count: rowBytes * height))
    return BlurMetric.downscaleLuma(
      luma, srcWidth: width, srcHeight: height, rowStride: rowBytes, pixelStride: 1)
  }

  // MARK: - Argument parsing

  private static func thresholdArg(_ arguments: Any?) -> Double? {
    guard let v = (arguments as? [String: Any])?["blurThreshold"] as? NSNumber else {
      return nil
    }
    let d = v.doubleValue
    return (d.isFinite && d >= 0) ? d : nil
  }

  private static func policyArg(_ arguments: Any?) -> BlurThresholdPolicy {
    let map = arguments as? [String: Any]
    let reject = (map?["rejectBelow"] as? NSNumber)?.doubleValue
    let accept = (map?["acceptAbove"] as? NSNumber)?.doubleValue
    return BlurThresholdPolicy(rejectBelow: reject, acceptAbove: accept)
  }
}
