// lib/platform/camera/camera_preview_controller.dart
//
// Dart-side driver for the live camera preview. Historically this file spoke
// straight to the native `com.mayasabhaxr.recapture/camera_preview`
// MethodChannel; it now drives [CameraPreviewPort]
// (../capture_ports/camera_preview_port.dart), which resolves to:
//
//   • native → that same MethodChannel, unchanged (Architecture Decision A's
//     Android external texture, and the iOS AVCaptureVideoPreviewLayer embedded
//     in a UiKitView);
//   • web    → `getUserMedia` into a `<video>` element hosted in an
//     HtmlElementView.
//
// Only the *rendering* differs (see [CameraPreview] in camera_preview_view.dart)
// — on iOS and on web there is no texture, so `textureId` stays null and the
// platform view shows the feed once running.
//
// Owns the start/stop/dispose contract and listens for platform-pushed
// callbacks: `onPreviewChanged` (Android texture rotation/size), `onError`
// (fatal — including web's "the camera track ended"), and `onStatusChanged`
// (iOS interruption began / auto-resumed). All failures (plugin missing in
// tests, native error codes, browser DOMExceptions) resolve to an error
// [CameraPreviewState] rather than throwing, so the UI shows a graceful state.
//
// [CameraPreviewStatus] / [CameraPreviewState] now live in
// ../capture_ports/camera_preview_models.dart and are re-exported here.
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../capture_ports/camera_preview_port.dart';
import '../capture_ports/camera_preview_port_stub.dart'
    if (dart.library.io) '../capture_ports/camera_preview_port_io.dart'
    if (dart.library.js_interop) '../capture_ports/camera_preview_port_web.dart';

export '../capture_ports/camera_preview_models.dart'
    show CameraPreviewStatus, CameraPreviewState;

/// This is the host for lifecycle policy: callers stop() on background and
/// start() on resume; dispose() tears the camera down for good.
class CameraPreviewController extends ValueNotifier<CameraPreviewState> {
  CameraPreviewController([MethodChannel? channel])
      : _port = createCameraPreviewPort(channel),
        super(const CameraPreviewState()) {
    _port.setPushHandler(_handlePush);
  }

  final CameraPreviewPort _port;
  bool _disposed = false;

  /// True once [dispose] has run; guards against use-after-dispose.
  bool get isDisposed => _disposed;

  /// Binds the back camera and resolves with a ready-to-draw surface. Safe to
  /// call when already running (re-reports state). Never throws.
  Future<void> start() async {
    if (_disposed) return;
    if (value.status == CameraPreviewStatus.starting) return;
    value = value.copyWith(status: CameraPreviewStatus.starting);
    try {
      final binding = await _port.start();
      if (_disposed) return;
      value = CameraPreviewState(
        status: CameraPreviewStatus.running,
        textureId: binding.textureId,
        previewWidth: binding.previewWidth,
        previewHeight: binding.previewHeight,
        rotationDegrees: binding.rotationDegrees,
      );
    } on CameraPreviewFailure catch (e) {
      if (_disposed) return;
      _setError(e.code, e.message);
    }
  }

  /// Releases the camera but keeps the controller reusable (call [start] again).
  Future<void> stop() async {
    if (_disposed) return;
    await _port.stop();
    if (_disposed) return;
    // Drop the texture (copyWith can't null a field) but keep last known
    // geometry so a restart can render before the first onPreviewChanged.
    value = CameraPreviewState(
      status: CameraPreviewStatus.stopped,
      previewWidth: value.previewWidth,
      previewHeight: value.previewHeight,
      rotationDegrees: value.rotationDegrees,
    );
  }

  void _handlePush(CameraPreviewPush push) {
    if (_disposed) return;
    switch (push.method) {
      case 'onPreviewChanged':
        final args = push.arguments;
        if (args == null) return;
        value = value.copyWith(
          previewWidth: (args['previewWidth'] as num?)?.toInt(),
          previewHeight: (args['previewHeight'] as num?)?.toInt(),
          rotationDegrees: (args['rotationDegrees'] as num?)?.toInt(),
        );
      case 'onError':
        final args = push.arguments;
        _setError(
          args?['code'] as String? ?? 'UNKNOWN',
          args?['message'] as String? ?? 'Camera preview error.',
        );
      case 'onStatusChanged':
        // iOS-only: interruption began ('interrupted'), the app backgrounded
        // and the session was paused ('suspended'), or the session auto-resumed
        // after an interruption / background / recoverable runtime error
        // ('running'). Ignored once stopped/error so a late push can't revive
        // a torn-down preview.
        if (value.status == CameraPreviewStatus.stopped ||
            value.status == CameraPreviewStatus.error) {
          return;
        }
        final args = push.arguments;
        switch (args?['status'] as String?) {
          case 'interrupted':
            value = value.copyWith(status: CameraPreviewStatus.interrupted);
          case 'suspended':
            value = value.copyWith(status: CameraPreviewStatus.suspended);
          case 'running':
            value = value.copyWith(status: CameraPreviewStatus.running);
        }
    }
  }

  void _setError(String code, String message) {
    value = value.copyWith(
      status: CameraPreviewStatus.error,
      errorCode: code,
      errorMessage: message,
    );
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _port.dispose();
    super.dispose();
  }
}
