// lib/platform/capture_ports/camera_preview_models.dart
//
// The camera-preview state types, moved out of
// lib/platform/camera/camera_preview_controller.dart (which re-exports them) so
// the port interface and both implementations can share them without an import
// cycle. [CameraPreviewStatus] and [CameraPreviewState] are UNCHANGED — the web
// path deliberately reuses the same status vocabulary and the same
// errorCode/errorMessage surface rather than inventing browser-specific UI
// states.
//
// [CameraPreviewBinding], [CameraPreviewPush] and [CameraPreviewFailure] are
// new, and are internal to the port boundary: they are what a `start()` resolves
// to, what the platform pushes back asynchronously, and how a start fails.
import 'package:flutter/foundation.dart';

/// Lifecycle phase of the camera preview.
///
/// [interrupted] is iOS-only: the AVCaptureSession was interrupted (incoming
/// call, another camera client, iPad multitasking) and will resume on its own —
/// the embedded preview view keeps showing so the UI need not go black.
///
/// [suspended] is iOS-only: the session was deliberately paused because the app
/// entered the background, and will auto-resume (→ [running]) on foreground.
/// Distinct from [stopped] (a deliberate teardown that does NOT auto-resume).
enum CameraPreviewStatus {
  idle,
  starting,
  running,
  interrupted,
  suspended,
  stopped,
  error
}

/// Immutable snapshot of the preview pipeline, observed by `CameraPreview`.
@immutable
class CameraPreviewState {
  const CameraPreviewState({
    this.status = CameraPreviewStatus.idle,
    this.textureId,
    this.previewWidth = 0,
    this.previewHeight = 0,
    this.rotationDegrees = 0,
    this.errorCode,
    this.errorMessage,
  });

  final CameraPreviewStatus status;

  /// Flutter external-texture id to draw via `Texture(textureId)`; null until
  /// `CameraPreviewController.start` resolves — and permanently null on iOS
  /// (platform view) and on web (`HtmlElementView` over a `<video>`).
  final int? textureId;

  /// Camera resolution (sensor orientation, before display rotation). On web
  /// this is the bound `MediaStreamTrack`'s intrinsic frame size.
  final int previewWidth;
  final int previewHeight;

  /// Clockwise degrees the texture must be rotated to display upright. With an
  /// external texture (not a PlatformView) the engine does not rotate for us, so
  /// the widget applies this. Always 0 on web — the browser orients the
  /// `<video>` element itself.
  final int rotationDegrees;

  final String? errorCode;
  final String? errorMessage;

  bool get hasTexture =>
      textureId != null && previewWidth > 0 && previewHeight > 0;

  CameraPreviewState copyWith({
    CameraPreviewStatus? status,
    int? textureId,
    int? previewWidth,
    int? previewHeight,
    int? rotationDegrees,
    String? errorCode,
    String? errorMessage,
  }) {
    return CameraPreviewState(
      status: status ?? this.status,
      textureId: textureId ?? this.textureId,
      previewWidth: previewWidth ?? this.previewWidth,
      previewHeight: previewHeight ?? this.previewHeight,
      rotationDegrees: rotationDegrees ?? this.rotationDegrees,
      errorCode: errorCode ?? this.errorCode,
      errorMessage: errorMessage ?? this.errorMessage,
    );
  }
}

/// What a successful `CameraPreviewPort.start()` resolved to.
@immutable
class CameraPreviewBinding {
  const CameraPreviewBinding({
    this.textureId,
    this.previewWidth = 0,
    this.previewHeight = 0,
    this.rotationDegrees = 0,
  });

  final int? textureId;
  final int previewWidth;
  final int previewHeight;
  final int rotationDegrees;
}

/// An asynchronous push from the platform after the preview started.
///
/// `onPreviewChanged` carries geometry, `onError` a fatal failure,
/// `onStatusChanged` an iOS interruption/suspension/resume. The web port emits
/// only `onError` (a track ending, e.g. the user revoking camera access from
/// the browser UI mid-session).
@immutable
class CameraPreviewPush {
  const CameraPreviewPush(this.method, this.arguments);

  final String method;
  final Map<String, dynamic>? arguments;
}

/// A start failure, carrying the code/message pair the UI already renders.
@immutable
class CameraPreviewFailure implements Exception {
  const CameraPreviewFailure(this.code, this.message);

  final String code;
  final String message;

  @override
  String toString() => 'CameraPreviewFailure($code): $message';
}
