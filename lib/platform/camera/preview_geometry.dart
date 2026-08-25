// lib/platform/camera/preview_geometry.dart
import 'dart:math' as math;

import 'package:flutter/widgets.dart';

/// The coordinate contract between the on-screen camera preview and the actual
/// captured frame. Overlays (ring guide, reticle, HUD) place themselves against
/// this so a guide lines up with what the camera *captures*, not just with
/// screen pixels.
///
/// Pure value type — no plugin/IO. Build it from a native preview state with
/// [PreviewGeometry.fromPreviewState], passing the laid-out [screenSize].
///
/// Coordinate spaces:
///  - **screen**: logical pixels in the preview widget's box (origin top-left).
///  - **normalized image**: `[0,1]×[0,1]` over the upright (post-rotation)
///    captured frame — `(0,0)` top-left, `(1,1)` bottom-right of the full frame.
///
/// The on-screen preview is the captured frame scaled by [fit] and centered:
///  - [BoxFit.cover] (default, immersive): the frame fills the screen and is
///    center-cropped — every on-screen point maps to an in-frame point
///    (normalized ∈ [0,1]), but frame edges can fall off-screen.
///  - [BoxFit.contain]: the whole frame is visible, letterboxed — normalized
///    points are always on-screen, but on-screen letterbox regions map outside
///    [0,1].
@immutable
class PreviewGeometry {
  const PreviewGeometry({
    required this.displayImageSize,
    required this.screenSize,
    this.fit = BoxFit.cover,
  });

  /// The upright (post display-rotation) captured-frame size. Normalized image
  /// coordinates are defined over this space.
  final Size displayImageSize;

  /// The laid-out size of the preview widget on screen.
  final Size screenSize;

  /// How the frame is fitted into [screenSize]. `cover` or `contain`.
  final BoxFit fit;

  /// An invalid/empty geometry — safe to construct before the preview reports a
  /// resolution. All mappings return zero and [isValid] is false.
  static const PreviewGeometry empty = PreviewGeometry(
    displayImageSize: Size.zero,
    screenSize: Size.zero,
  );

  /// Builds geometry from a native preview state.
  ///
  /// [previewWidth]/[previewHeight] are the SENSOR resolution (before display
  /// rotation); [rotationDegrees] is the clockwise rotation applied to show the
  /// frame upright — an odd quarter-turn swaps width/height. This mirrors the
  /// rotation the texture preview applies, so the normalized space matches what
  /// the user sees.
  factory PreviewGeometry.fromPreviewState({
    required int previewWidth,
    required int previewHeight,
    required int rotationDegrees,
    required Size screenSize,
    BoxFit fit = BoxFit.cover,
  }) {
    final turns = (rotationDegrees ~/ 90) % 4;
    final rotated = turns.isOdd;
    final w = (rotated ? previewHeight : previewWidth).toDouble();
    final h = (rotated ? previewWidth : previewHeight).toDouble();
    return PreviewGeometry(
      displayImageSize: Size(w, h),
      screenSize: screenSize,
      fit: fit,
    );
  }

  /// True once both the frame and the screen have non-zero dimensions, so the
  /// mappings below are meaningful.
  bool get isValid =>
      displayImageSize.width > 0 &&
      displayImageSize.height > 0 &&
      screenSize.width > 0 &&
      screenSize.height > 0;

  /// Uniform scale applied to [displayImageSize] to satisfy [fit] within
  /// [screenSize]. cover → the larger ratio (fills, crops); contain → the
  /// smaller (fits, letterboxes).
  double get scale {
    if (!isValid) return 1;
    final sx = screenSize.width / displayImageSize.width;
    final sy = screenSize.height / displayImageSize.height;
    return fit == BoxFit.contain ? math.min(sx, sy) : math.max(sx, sy);
  }

  /// The scaled frame rect, centered on screen. For `cover` it overflows the
  /// screen (negative offset, larger than the screen); for `contain` it is inset.
  Rect get scaledImageRect {
    if (!isValid) return Rect.zero;
    final s = scale;
    final scaled =
        Size(displayImageSize.width * s, displayImageSize.height * s);
    final dx = (screenSize.width - scaled.width) / 2;
    final dy = (screenSize.height - scaled.height) / 2;
    return Rect.fromLTWH(dx, dy, scaled.width, scaled.height);
  }

  /// The on-screen region actually showing preview content — [scaledImageRect]
  /// clipped to the screen. For `cover` this is the full screen; for `contain`
  /// it is the letterboxed inner rect. Useful as an overlay's drawing bounds.
  Rect get previewRectOnScreen {
    if (!isValid) return Rect.zero;
    final screen = Rect.fromLTWH(0, 0, screenSize.width, screenSize.height);
    return scaledImageRect.intersect(screen);
  }

  /// Maps an on-screen point to normalized `[0,1]` coordinates in the captured
  /// frame. Values outside `[0,1]` indicate a letterbox region (`contain`).
  Offset screenToNormalizedImage(Offset screenPoint) {
    if (!isValid) return Offset.zero;
    final r = scaledImageRect;
    return Offset(
      (screenPoint.dx - r.left) / r.width,
      (screenPoint.dy - r.top) / r.height,
    );
  }

  /// Maps a normalized `[0,1]` captured-frame point to an on-screen point. For
  /// `cover`, points near the frame edges can fall outside the screen (cropped).
  Offset normalizedImageToScreen(Offset normalized) {
    if (!isValid) return Offset.zero;
    final r = scaledImageRect;
    return Offset(
      r.left + normalized.dx * r.width,
      r.top + normalized.dy * r.height,
    );
  }

  PreviewGeometry copyWith({
    Size? displayImageSize,
    Size? screenSize,
    BoxFit? fit,
  }) =>
      PreviewGeometry(
        displayImageSize: displayImageSize ?? this.displayImageSize,
        screenSize: screenSize ?? this.screenSize,
        fit: fit ?? this.fit,
      );

  @override
  bool operator ==(Object other) =>
      other is PreviewGeometry &&
      other.displayImageSize == displayImageSize &&
      other.screenSize == screenSize &&
      other.fit == fit;

  @override
  int get hashCode => Object.hash(displayImageSize, screenSize, fit);

  @override
  String toString() =>
      'PreviewGeometry(image: $displayImageSize, screen: $screenSize, fit: $fit)';
}
