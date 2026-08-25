// test/capture/preview_geometry_test.dart
//
// Pure unit tests for the screen ↔ normalized-capture-image coordinate contract.
// Covers cover/contain fit, rotation W/H swap, round-trip mapping, the visible
// preview rect, and degenerate inputs.
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:recapture/platform/camera/preview_geometry.dart';

void main() {
  // Helper: a point round-trips through screen ↔ normalized within epsilon.
  void expectOffsetClose(Offset a, Offset b, {double eps = 1e-6}) {
    expect((a.dx - b.dx).abs() < eps, isTrue, reason: 'dx $a vs $b');
    expect((a.dy - b.dy).abs() < eps, isTrue, reason: 'dy $a vs $b');
  }

  group('validity', () {
    test('empty geometry is invalid and maps to zero', () {
      expect(PreviewGeometry.empty.isValid, isFalse);
      expect(PreviewGeometry.empty.screenToNormalizedImage(const Offset(10, 10)),
          Offset.zero);
      expect(PreviewGeometry.empty.previewRectOnScreen, Rect.zero);
    });

    test('zero preview size from state is invalid (pre-resolution)', () {
      final g = PreviewGeometry.fromPreviewState(
        previewWidth: 0,
        previewHeight: 0,
        rotationDegrees: 0,
        screenSize: const Size(400, 800),
      );
      expect(g.isValid, isFalse);
    });
  });

  group('rotation', () {
    test('odd quarter-turn swaps width/height for the display image', () {
      final g = PreviewGeometry.fromPreviewState(
        previewWidth: 1920,
        previewHeight: 1080,
        rotationDegrees: 90,
        screenSize: const Size(1080, 1920),
      );
      expect(g.displayImageSize, const Size(1080, 1920));
    });

    test('even rotation keeps orientation', () {
      final g = PreviewGeometry.fromPreviewState(
        previewWidth: 1920,
        previewHeight: 1080,
        rotationDegrees: 180,
        screenSize: const Size(1920, 1080),
      );
      expect(g.displayImageSize, const Size(1920, 1080));
    });
  });

  group('cover fit (default)', () {
    // 1000x2000 image into a 500x500 screen → scale = max(0.5, 0.25) = 0.5.
    // Scaled image = 500x1000, centered → vertical overflow of 250 each side.
    final g = const PreviewGeometry(
      displayImageSize: Size(1000, 2000),
      screenSize: Size(500, 500),
      fit: BoxFit.cover,
    );

    test('scale uses the larger ratio (fills, crops)', () {
      expect(g.scale, 0.5);
    });

    test('scaled image overflows the screen vertically', () {
      expect(g.scaledImageRect, const Rect.fromLTWH(0, -250, 500, 1000));
    });

    test('visible preview rect is clamped to the full screen', () {
      expect(g.previewRectOnScreen, const Rect.fromLTWH(0, 0, 500, 500));
    });

    test('screen center maps to normalized image center', () {
      expectOffsetClose(
        g.screenToNormalizedImage(const Offset(250, 250)),
        const Offset(0.5, 0.5),
      );
    });

    test('every on-screen point maps within [0,1] (no letterbox)', () {
      final tl = g.screenToNormalizedImage(const Offset(0, 0));
      final br = g.screenToNormalizedImage(const Offset(500, 500));
      expect(tl.dx, inInclusiveRange(0, 1));
      expect(tl.dy, inInclusiveRange(0, 1));
      expect(br.dx, inInclusiveRange(0, 1));
      expect(br.dy, inInclusiveRange(0, 1));
    });

    test('round-trips screen → normalized → screen', () {
      const p = Offset(123, 456);
      expectOffsetClose(
        g.normalizedImageToScreen(g.screenToNormalizedImage(p)),
        p,
      );
    });
  });

  group('contain fit', () {
    // 1000x2000 image into a 500x500 screen → scale = min(0.5, 0.25) = 0.25.
    // Scaled image = 250x500, centered horizontally → letterbox of 125 each side.
    final g = const PreviewGeometry(
      displayImageSize: Size(1000, 2000),
      screenSize: Size(500, 500),
      fit: BoxFit.contain,
    );

    test('scale uses the smaller ratio (fits, letterboxes)', () {
      expect(g.scale, 0.25);
    });

    test('visible preview rect is the letterboxed inner rect', () {
      expect(g.previewRectOnScreen, const Rect.fromLTWH(125, 0, 250, 500));
    });

    test('a point in the letterbox maps outside [0,1]', () {
      final n = g.screenToNormalizedImage(const Offset(10, 250));
      expect(n.dx < 0, isTrue, reason: 'left letterbox is left of the image');
    });

    test('round-trips a normalized point → screen → normalized', () {
      const n = Offset(0.3, 0.7);
      expectOffsetClose(
        g.screenToNormalizedImage(g.normalizedImageToScreen(n)),
        n,
      );
    });
  });
}
