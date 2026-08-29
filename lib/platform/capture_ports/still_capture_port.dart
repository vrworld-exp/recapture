// lib/platform/capture_ports/still_capture_port.dart
//
// PORT: "take a photo, and tell me about the loop that is taking them".
//
// The `capture` MethodChannel and the `captureEvents` EventChannel are two faces
// of ONE native module (CameraX ImageCapture bound to the preview session), so
// they are one port here rather than two: a web implementation that split them
// would have to invent a way to keep a canvas loop and its event stream in sync.
//
// Native drives the real ImageCapture pipeline. Web draws the live `<video>`
// frame into a canvas at the video's intrinsic resolution, crops to the
// configured [CaptureAspectRatio] so preview FOV == capture FOV, encodes JPEG at
// [CaptureResolutionPolicy.jpegQuality], and writes the bytes straight into
// IndexedDB — returning a [CapturedFrame] whose `path` is the opaque `idb://`
// handle and whose `timestampNs` comes from `performance.now()`, so the
// sensor-alignment fields stay meaningful.
import 'capture_event_models.dart';
import 'still_capture_models.dart';

export 'capture_event_models.dart';
export 'still_capture_models.dart';

/// Still capture plus its progress stream.
///
/// Every call degrades gracefully rather than throwing — an unbound session, a
/// busy capturer, a missing plugin (tests / non-Android), or a browser with no
/// running camera all resolve to null / false / a no-op, exactly as the native
/// channel wrapper always did.
abstract interface class StillCapturePort {
  /// Captures one frame; returns it (id/path/timestamp) or null on failure.
  Future<CapturedFrame?> captureSingle();

  /// Starts a burst of [count] frames (optionally with a minimum [intervalMs]
  /// spacing). Frames stream via [events]. Returns the session id ack, or null
  /// if rejected (busy / no session / invalid).
  Future<String?> startBurst(int count, {int? intervalMs});

  /// Starts continuous auto-capture until [stopAutoCapture]; frames stream via
  /// [events]. Returns the session id ack, or null if rejected.
  Future<String?> startAutoCapture({int? intervalMs});

  /// Halts an auto-capture (or burst) loop; cancels the in-flight tail.
  Future<void> stopAutoCapture();

  /// Stages a resolution/JPEG-quality policy. Takes effect on the NEXT camera
  /// bind, never mid-session. Returns whether it was accepted.
  Future<bool> configureCaptureResolution(CaptureResolutionPolicy policy);

  /// The effective capture resolution (actual once bound; else the resolved
  /// target). Null when the platform cannot report one.
  Future<ActiveCaptureResolution?> getActiveCaptureResolution();

  /// Per-frame / completion / error events from the capture loop.
  Stream<CaptureEvent> events();
}
