// lib/platform/method_channels.dart
//
// Still-capture entry point. Historically this file WAS the native
// MethodChannel wrapper (CameraX ImageCapture); it is now the platform-agnostic
// face of [StillCapturePort] (capture_ports/still_capture_port.dart), which
// resolves to:
//
//   • native → the `capture` MethodChannel, unchanged (single / burst /
//     auto-capture on the existing camera session, with per-frame results
//     streaming over the EventChannel in event_channels.dart);
//   • web    → the live `<video>` frame drawn to a canvas, cropped to the
//     configured aspect ratio, JPEG-encoded at the policy's quality and written
//     straight into IndexedDB (capture_ports/still_capture_port_web.dart).
//
// Class names, the injectable [MethodChannel] constructor argument, method
// signatures and the value types are unchanged, so every call site is
// untouched. The value types now live in
// capture_ports/still_capture_models.dart and are re-exported here.
// Channel name: com.mayasabhaxr.recapture/capture
import 'package:flutter/services.dart';

import 'capture_ports/still_capture_port.dart';
import 'capture_ports/still_capture_port_stub.dart'
    if (dart.library.io) 'capture_ports/still_capture_port_io.dart'
    if (dart.library.js_interop) 'capture_ports/still_capture_port_web.dart';

export 'capture_ports/still_capture_models.dart'
    show
        CapturedFrame,
        CaptureAspectRatio,
        CaptureFallbackRule,
        CaptureResolutionPolicy,
        ActiveCaptureResolution;

/// Typed Dart API over the still-capture platform module.
///
/// All calls degrade gracefully — a missing/unbound session, a busy capturer, a
/// missing plugin (tests / non-Android), a browser with no running camera —
/// resolve without throwing: [captureSingle] returns null,
/// [startBurst]/[startAutoCapture] return null (no session id), and
/// [stopAutoCapture] is a no-op.
class CaptureChannel {
  CaptureChannel([MethodChannel? channel])
      : _port = createStillCapturePort(captureChannel: channel);

  final StillCapturePort _port;

  /// Captures one frame; returns it (id/path/timestamp) or null on failure.
  ///
  /// `path` is a filesystem path natively and an opaque `idb://…` handle on web
  /// — resolve it through `CaptureStorageClient.readFrameBytes`, never by
  /// constructing a `File`.
  Future<CapturedFrame?> captureSingle() => _port.captureSingle();

  /// Starts a burst of [count] frames (optionally with a minimum [intervalMs]
  /// spacing). Frames stream via the capture event stream. Returns the session
  /// id ack, or null if rejected (busy / no session / invalid).
  Future<String?> startBurst(int count, {int? intervalMs}) =>
      _port.startBurst(count, intervalMs: intervalMs);

  /// Starts continuous auto-capture until [stopAutoCapture]; frames stream via
  /// the capture event stream. Returns the session id ack, or null if rejected.
  Future<String?> startAutoCapture({int? intervalMs}) =>
      _port.startAutoCapture(intervalMs: intervalMs);

  /// Stages a resolution/JPEG-quality [policy]. Takes effect on the NEXT camera
  /// bind (start/rebind), never mid-session. Returns true if it was accepted;
  /// false if rejected (invalid args) or unavailable.
  Future<bool> configureCaptureResolution(CaptureResolutionPolicy policy) =>
      _port.configureCaptureResolution(policy);

  /// Reads the effective capture resolution (actual once bound; else the
  /// resolved target). Returns null when the platform cannot report one.
  Future<ActiveCaptureResolution?> getActiveCaptureResolution() =>
      _port.getActiveCaptureResolution();

  /// Halts an auto-capture (or burst) loop; cancels the in-flight tail.
  Future<void> stopAutoCapture() => _port.stopAutoCapture();
}
