// lib/platform/camera/camera_preview_view.dart
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../utils/constants.dart';
import 'camera_preview_controller.dart';
import 'web_preview_surface_stub.dart'
    if (dart.library.js_interop) 'web_preview_surface_web.dart';

/// Renders the live camera preview for a [CameraPreviewController].
///
/// The render path is platform-specific (the lifecycle contract is not):
///  - **Web** hosts the `getUserMedia` `<video>` element in an
///    `HtmlElementView`. This branch MUST come first: on web
///    `defaultTargetPlatform` reports the HOST OS, so a phone browser would
///    otherwise take the Android `Texture` or iOS `UiKitView` path — both dead,
///    leaving `hasTexture` false and the placeholder showing forever (the
///    original black-preview bug).
///  - **Android** draws the external `Texture` at its native resolution, rotated
///    by [CameraPreviewState.rotationDegrees] and scaled with [BoxFit.cover]
///    (FILL_CENTER) so it fills the viewport without stretching.
///  - **iOS** embeds the native `AVCaptureVideoPreviewLayer` via a `UiKitView`
///    (platform view), which self-sizes and self-rotates — no Dart geometry.
///
/// All three share the three observable surfaces: a graceful error (camera
/// unavailable / permission missing), a placeholder while binding, and the live
/// feed once running.
/// Which surface [CameraPreview] draws for a given platform + state.
enum CameraPreviewRenderPath {
  /// A graceful error surface (camera unavailable / permission missing).
  error,

  /// The neutral placeholder shown while binding, or once stopped.
  placeholder,

  /// Web: the `getUserMedia` `<video>` in an `HtmlElementView`.
  webElement,

  /// iOS: the native `AVCaptureVideoPreviewLayer` in a `UiKitView`.
  iosPlatformView,

  /// Android: the external `Texture`.
  androidTexture,
}

/// The render-path decision, extracted so the rule that caused the black-preview
/// bug is directly testable.
///
/// [isWeb] is checked BEFORE [platform] and that ordering is the whole fix: on
/// web `defaultTargetPlatform` reports the HOST OS, so a phone browser reads as
/// `TargetPlatform.android` / `.iOS` and would otherwise take a native path that
/// cannot work there. No web state may ever resolve to
/// [CameraPreviewRenderPath.androidTexture] or
/// [CameraPreviewRenderPath.iosPlatformView].
@visibleForTesting
CameraPreviewRenderPath resolveCameraPreviewRenderPath({
  required bool isWeb,
  required TargetPlatform platform,
  required CameraPreviewState state,
}) {
  if (state.status == CameraPreviewStatus.error) {
    return CameraPreviewRenderPath.error;
  }
  if (isWeb) {
    // The browser composites the element itself; there is no texture to wait
    // for, so "running" is the only signal that a frame exists to show.
    return state.status == CameraPreviewStatus.running
        ? CameraPreviewRenderPath.webElement
        : CameraPreviewRenderPath.placeholder;
  }
  if (platform == TargetPlatform.iOS) {
    // An interrupted session keeps showing its last frame rather than going
    // black; a stopped/idle one tears the platform view down.
    final live = state.status == CameraPreviewStatus.running ||
        state.status == CameraPreviewStatus.interrupted;
    return live
        ? CameraPreviewRenderPath.iosPlatformView
        : CameraPreviewRenderPath.placeholder;
  }
  return state.hasTexture
      ? CameraPreviewRenderPath.androidTexture
      : CameraPreviewRenderPath.placeholder;
}

class CameraPreview extends StatelessWidget {
  const CameraPreview({
    super.key,
    required this.controller,
    this.errorBuilder,
    this.placeholder,
  });

  final CameraPreviewController controller;

  /// Optional custom error surface; falls back to [_DefaultError].
  final Widget Function(BuildContext context, CameraPreviewState state)?
      errorBuilder;

  /// Optional widget shown while the preview is being acquired.
  final Widget? placeholder;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<CameraPreviewState>(
      valueListenable: controller,
      builder: (context, state, _) {
        final path = resolveCameraPreviewRenderPath(
          isWeb: kIsWeb,
          platform: defaultTargetPlatform,
          state: state,
        );
        return switch (path) {
          CameraPreviewRenderPath.error => errorBuilder?.call(context, state) ??
              _DefaultError(message: state.errorMessage),
          CameraPreviewRenderPath.placeholder =>
            placeholder ?? const _DefaultPlaceholder(),
          CameraPreviewRenderPath.webElement => buildWebCameraPreview(),
          CameraPreviewRenderPath.iosPlatformView => const UiKitView(
              viewType: AppConfig.viewTypeCameraPreviewIos,
              creationParamsCodec: StandardMessageCodec(),
            ),
          CameraPreviewRenderPath.androidTexture =>
            _TexturePreview(state: state),
        };
      },
    );
  }
}

class _TexturePreview extends StatelessWidget {
  const _TexturePreview({required this.state});

  final CameraPreviewState state;

  @override
  Widget build(BuildContext context) {
    final turns = (state.rotationDegrees ~/ 90) % 4;
    final rotated = turns.isOdd;
    final displayWidth =
        (rotated ? state.previewHeight : state.previewWidth).toDouble();
    final displayHeight =
        (rotated ? state.previewWidth : state.previewHeight).toDouble();

    return ClipRect(
      child: FittedBox(
        fit: BoxFit.cover,
        clipBehavior: Clip.hardEdge,
        child: SizedBox(
          width: displayWidth,
          height: displayHeight,
          child: RotatedBox(
            quarterTurns: turns,
            child: Texture(textureId: state.textureId!),
          ),
        ),
      ),
    );
  }
}

class _DefaultPlaceholder extends StatelessWidget {
  const _DefaultPlaceholder();

  @override
  Widget build(BuildContext context) {
    return const ColoredBox(color: Color(0xFF0A0A0A));
  }
}

class _DefaultError extends StatelessWidget {
  const _DefaultError({this.message});

  final String? message;

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: const Color(0xFF0A0A0A),
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.videocam_off, color: Colors.white70, size: 40),
            const SizedBox(height: 12),
            Text(
              message ?? 'Camera unavailable',
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.white70),
            ),
          ],
        ),
      ),
    );
  }
}
