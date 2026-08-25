// lib/platform/camera/camera_preview_controller.dart
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../../utils/constants.dart';

/// Lifecycle phase of the native camera preview.
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

/// Immutable snapshot of the preview pipeline, observed by [CameraPreview].
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
  /// [CameraPreviewController.start] resolves.
  final int? textureId;

  /// Native camera resolution (sensor orientation, before display rotation).
  final int previewWidth;
  final int previewHeight;

  /// Clockwise degrees the texture must be rotated to display upright. With an
  /// external texture (not a PlatformView) the engine does not rotate for us, so
  /// the widget applies this.
  final int rotationDegrees;

  final String? errorCode;
  final String? errorMessage;

  bool get hasTexture => textureId != null && previewWidth > 0 && previewHeight > 0;

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

/// Dart-side driver for the native `com.mayasabhaxr.recapture/camera_preview`
/// channel. Platform-agnostic: the same start/stop/dispose contract drives both
/// the Android external-texture path (Architecture Decision A) and the iOS
/// `AVCaptureVideoPreviewLayer` embedded in a `UiKitView`. Only the *rendering*
/// differs (see [CameraPreview]) — on iOS there is no texture, so `textureId`
/// stays null and the platform view shows the feed once running.
///
/// Owns the start/stop/dispose contract and listens for native-pushed
/// callbacks: `onPreviewChanged` (Android texture rotation/size), `onError`
/// (fatal), and `onStatusChanged` (iOS interruption began / auto-resumed). All
/// failures (plugin missing in tests, native error codes) resolve to an error
/// [CameraPreviewState] rather than throwing, so the UI shows a graceful state.
///
/// This is the host for lifecycle policy: callers stop() on background and
/// start() on resume; dispose() tears the camera down for good.
class CameraPreviewController extends ValueNotifier<CameraPreviewState> {
  CameraPreviewController([MethodChannel? channel])
      : _channel = channel ?? const MethodChannel(AppConfig.channelCameraPreview),
        super(const CameraPreviewState()) {
    _channel.setMethodCallHandler(_handleNativeCall);
  }

  final MethodChannel _channel;
  bool _disposed = false;

  /// True once [dispose] has run; guards against use-after-dispose.
  bool get isDisposed => _disposed;

  /// Binds the back camera and resolves with a ready-to-draw texture. Safe to
  /// call when already running (re-reports state). Never throws.
  Future<void> start() async {
    if (_disposed) return;
    if (value.status == CameraPreviewStatus.starting) return;
    value = value.copyWith(status: CameraPreviewStatus.starting);
    try {
      final res = await _channel.invokeMapMethod<String, dynamic>('start');
      if (_disposed) return;
      if (res == null) {
        _setError('NULL_RESULT', 'Native preview returned no texture.');
        return;
      }
      value = CameraPreviewState(
        status: CameraPreviewStatus.running,
        textureId: (res['textureId'] as num?)?.toInt(),
        previewWidth: (res['previewWidth'] as num?)?.toInt() ?? 0,
        previewHeight: (res['previewHeight'] as num?)?.toInt() ?? 0,
        rotationDegrees: (res['rotationDegrees'] as num?)?.toInt() ?? 0,
      );
    } on PlatformException catch (e) {
      _setError(e.code, e.message ?? 'Failed to start camera preview.');
    } on MissingPluginException {
      // Channel not registered (unit-test host, or a non-Android platform).
      _setError('NO_PLUGIN', 'Camera preview channel unavailable.');
    }
  }

  /// Releases the camera but keeps the controller reusable (call [start] again).
  Future<void> stop() async {
    if (_disposed) return;
    try {
      await _channel.invokeMethod<void>('stop');
    } on PlatformException {
      // Ignore — teardown is best-effort.
    } on MissingPluginException {
      // Ignore — nothing native to stop.
    }
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

  Future<void> _handleNativeCall(MethodCall call) async {
    if (_disposed) return;
    switch (call.method) {
      case 'onPreviewChanged':
        final args = (call.arguments as Map?)?.cast<String, dynamic>();
        if (args == null) return;
        value = value.copyWith(
          previewWidth: (args['previewWidth'] as num?)?.toInt(),
          previewHeight: (args['previewHeight'] as num?)?.toInt(),
          rotationDegrees: (args['rotationDegrees'] as num?)?.toInt(),
        );
      case 'onError':
        final args = (call.arguments as Map?)?.cast<String, dynamic>();
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
        final args = (call.arguments as Map?)?.cast<String, dynamic>();
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
    _channel.setMethodCallHandler(null);
    // Fire-and-forget native teardown; the controller is going away.
    _channel.invokeMethod<void>('dispose').catchError((_) {});
    super.dispose();
  }
}
