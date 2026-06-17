// lib/platform/camera/camera_preview_view.dart
import 'package:flutter/material.dart';

import 'camera_preview_controller.dart';

/// Renders the live native camera preview (external texture) for a
/// [CameraPreviewController].
///
/// Handles the three observable states: a graceful error surface (camera
/// unavailable / permission missing), a placeholder while binding, and the live
/// `Texture` once running. The texture is drawn at its native resolution and
/// rotated by [CameraPreviewState.rotationDegrees], then scaled with
/// [BoxFit.cover] (FILL_CENTER) so it fills the viewport without stretching.
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

  /// Optional widget shown while the texture is being acquired.
  final Widget? placeholder;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<CameraPreviewState>(
      valueListenable: controller,
      builder: (context, state, _) {
        if (state.status == CameraPreviewStatus.error) {
          return errorBuilder?.call(context, state) ??
              _DefaultError(message: state.errorMessage);
        }
        if (!state.hasTexture) {
          return placeholder ?? const _DefaultPlaceholder();
        }
        return _TexturePreview(state: state);
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
