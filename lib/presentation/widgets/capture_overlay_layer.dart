// lib/presentation/widgets/capture_overlay_layer.dart
import 'package:flutter/material.dart';

import '../../app/theme/app_colors.dart';
import '../../platform/camera/preview_geometry.dart';

/// Exposes the active [PreviewGeometry] to descendant overlays so guides/HUDs
/// align to the captured frame, not just screen pixels. Overlays read it with
/// [PreviewGeometryScope.of] / [PreviewGeometryScope.maybeOf].
class PreviewGeometryScope extends InheritedWidget {
  const PreviewGeometryScope({
    super.key,
    required this.geometry,
    required super.child,
  });

  final PreviewGeometry geometry;

  static PreviewGeometry? maybeOf(BuildContext context) => context
      .dependOnInheritedWidgetOfExactType<PreviewGeometryScope>()
      ?.geometry;

  static PreviewGeometry of(BuildContext context) {
    final geometry = maybeOf(context);
    assert(
      geometry != null,
      'No PreviewGeometryScope found. Wrap overlays in a CaptureOverlayLayer.',
    );
    return geometry!;
  }

  @override
  bool updateShouldNotify(PreviewGeometryScope oldWidget) =>
      oldWidget.geometry != geometry;
}

/// The overlay composition layer for the capture experience: the camera preview
/// as the base, with [overlays] stacked above it (bottom → top) and the active
/// [geometry] provided to all of them via a [PreviewGeometryScope].
///
/// This is the slot architecture later Level A tasks plug into (ring guide,
/// progress HUD, reticle, sensor-driven indicators) — each overlay is just a
/// widget that reads geometry from the scope. This layer owns NO camera state
/// and triggers NO captures; it is pure composition.
class CaptureOverlayLayer extends StatelessWidget {
  const CaptureOverlayLayer({
    super.key,
    required this.cameraPreview,
    required this.geometry,
    this.overlays = const [],
  });

  /// The base layer — the live camera preview widget.
  final Widget cameraPreview;

  /// Coordinate contract handed to every overlay through the scope.
  final PreviewGeometry geometry;

  /// Widgets stacked above the preview, painted bottom → top.
  final List<Widget> overlays;

  @override
  Widget build(BuildContext context) {
    return PreviewGeometryScope(
      geometry: geometry,
      child: Stack(
        fit: StackFit.expand,
        children: [cameraPreview, ...overlays],
      ),
    );
  }
}

/// A debug-only overlay that draws the [PreviewGeometry] mapping so it can be
/// eyeballed on-device: the visible preview bounds, a center crosshair, and a
/// few normalized grid markers. Proves guides align to the captured frame.
///
/// Renders nothing when geometry is unavailable/invalid. Gate inclusion behind
/// [kShowCaptureDebugReticle] + `kDebugMode` at the call site — it is not for
/// production chrome.
class CaptureDebugReticleOverlay extends StatelessWidget {
  const CaptureDebugReticleOverlay({super.key});

  @override
  Widget build(BuildContext context) {
    final geometry = PreviewGeometryScope.maybeOf(context);
    if (geometry == null || !geometry.isValid) return const SizedBox.shrink();
    return IgnorePointer(
      child: CustomPaint(
        size: Size.infinite,
        painter: _ReticlePainter(geometry),
      ),
    );
  }
}

/// Compile-time switch for the debug reticle overlay. Off by default.
const bool kShowCaptureDebugReticle = false;

class _ReticlePainter extends CustomPainter {
  _ReticlePainter(this.geometry);

  final PreviewGeometry geometry;

  @override
  void paint(Canvas canvas, Size size) {
    // Visible preview bounds (cover → full screen; contain → letterbox rect).
    final bounds = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1
      ..color = AppColors.royalGold.withValues(alpha: 0.6);
    canvas.drawRect(geometry.previewRectOnScreen, bounds);

    // Normalized grid markers (1/4, 1/2, 3/4) mapped to screen.
    final marker = Paint()..color = AppColors.royalGold.withValues(alpha: 0.5);
    for (final nx in const [0.25, 0.5, 0.75]) {
      for (final ny in const [0.25, 0.5, 0.75]) {
        canvas.drawCircle(
            geometry.normalizedImageToScreen(Offset(nx, ny)), 2.5, marker);
      }
    }

    // Center crosshair at normalized (0.5, 0.5).
    final center = geometry.normalizedImageToScreen(const Offset(0.5, 0.5));
    final cross = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5
      ..color = AppColors.mirageRed;
    const r = 16.0;
    canvas.drawLine(center.translate(-r, 0), center.translate(r, 0), cross);
    canvas.drawLine(center.translate(0, -r), center.translate(0, r), cross);
  }

  @override
  bool shouldRepaint(covariant _ReticlePainter old) =>
      old.geometry != geometry;
}
