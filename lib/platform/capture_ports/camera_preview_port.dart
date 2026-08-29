// lib/platform/capture_ports/camera_preview_port.dart
//
// PORT: "give me a live camera preview surface".
//
// Native binds the CameraX/AVFoundation session over the `camera_preview`
// MethodChannel and hands back an external texture (Android) or nothing at all
// (iOS, which renders through a UiKitView). Web calls `getUserMedia` and hands
// back a `<video>` element hosted in an HtmlElementView. Both report through the
// SAME [CameraPreviewState] vocabulary, including the error code/message pair —
// no browser-specific UI state exists.
import 'camera_preview_models.dart';

export 'camera_preview_models.dart';

/// The live-preview lifecycle, identical on every platform.
abstract interface class CameraPreviewPort {
  /// Binds the rear camera and resolves with the drawable surface.
  ///
  /// Throws [CameraPreviewFailure] with a code the UI already knows how to
  /// render. The web codes map the DOMExceptions getUserMedia throws:
  /// `NotAllowedError` → PERMISSION_DENIED, `NotFoundError` → NO_CAMERA,
  /// `NotReadableError` → CAMERA_BUSY, plus INSECURE_CONTEXT for a page served
  /// over plain HTTP (where the API is simply absent).
  Future<CameraPreviewBinding> start();

  /// Releases the camera but leaves the port reusable ([start] again).
  Future<void> stop();

  /// Tears the preview down for good.
  Future<void> dispose();

  /// Registers the handler for asynchronous platform pushes, or clears it with
  /// null. At most one handler at a time (the native channel's own contract —
  /// `CameraControls` shares the channel and deliberately never registers one).
  void setPushHandler(void Function(CameraPreviewPush push)? handler);
}
