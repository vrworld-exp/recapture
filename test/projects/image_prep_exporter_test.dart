// test/projects/image_prep_exporter_test.dart
//
// The export pipeline on tiny synthetic images: polygon crop fills OUTSIDE
// with solid white and crops to the padded bounding box; rect crop maps to
// the same pixels rectCropToPixels promises; rotation swaps dimensions;
// lighting bakes the exact LightingAdjust linear map the preview shows; output
// is alpha-free JPEG; the tight-crop guard flags small results without
// upscaling. Pixel assertions use tolerances because JPEG is lossy.
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:recapture/application/projects/image_prep_exporter.dart';
import 'package:recapture/domain/entities/image_edit.dart';

/// A [width]×[height] JPEG of solid [r]/[g]/[b].
Uint8List _solidJpeg(int width, int height, int r, int g, int b) {
  final image = img.Image(width: width, height: height, numChannels: 3);
  img.fill(image, color: img.ColorRgb8(r, g, b));
  return img.encodeJpg(image, quality: 100);
}

img.Image _decode(ExportedImage exported) => img.decodeJpg(exported.jpegBytes)!;

bool _isWhite(img.Pixel p) => p.r > 240 && p.g > 240 && p.b > 240;

void main() {
  group('exportEditedImage', () {
    test('no edits: pass-through re-encode keeps dimensions and color', () {
      final result = exportEditedImage(
          _solidJpeg(120, 80, 200, 40, 40), ImageEditState.none);
      expect((result.width, result.height), (120, 80));
      final decoded = _decode(result);
      final p = decoded.getPixel(60, 40);
      expect(p.r, greaterThan(180));
      expect(p.g, lessThan(80));
    });

    test('rotation swaps dimensions (and 4 turns is a full circle)', () {
      final bytes = _solidJpeg(100, 60, 128, 128, 128);
      final once =
          exportEditedImage(bytes, const ImageEditState(quarterTurns: 1));
      expect((once.width, once.height), (60, 100));
      final twice =
          exportEditedImage(bytes, const ImageEditState(quarterTurns: 2));
      expect((twice.width, twice.height), (100, 60));
    });

    test('polygon crop: bbox+padding window, white OUTSIDE, original INSIDE',
        () {
      // 200×100 solid red; polygon = the centered square x 0.25..0.75 of width,
      // y 0.2..0.8 of height → px x 50..150, y 20..80.
      final bytes = _solidJpeg(200, 100, 220, 30, 30);
      const polygon = [
        EditPoint(0.25, 0.2),
        EditPoint(0.75, 0.2),
        EditPoint(0.75, 0.8),
        EditPoint(0.25, 0.8),
      ];
      final result = exportEditedImage(
        bytes,
        ImageEditState.none.withPolygon(polygon),
      );

      // Window: box 100×60 px, pad = 3 px of the 100 longer side.
      final expected = paddedPolygonCropRect(polygon, 200, 100);
      expect((result.width, result.height), (expected.width, expected.height));

      final decoded = _decode(result);
      // Corners of the window are outside the polygon → solid white.
      expect(_isWhite(decoded.getPixel(0, 0)), isTrue);
      expect(_isWhite(decoded.getPixel(decoded.width - 1, decoded.height - 1)),
          isTrue);
      // The window's center is deep inside the polygon → still red.
      final center = decoded.getPixel(decoded.width ~/ 2, decoded.height ~/ 2);
      expect(center.r, greaterThan(180));
      expect(center.g, lessThan(80));
      expect(result.isTight, isTrue); // 106 px long side < 1024
    });

    test('polygon white fill hugs a concave notch', () {
      // U-shape on a 100×100 blue image: the notch (center-top area between
      // the arms) must come out white even though it is inside the bbox.
      final bytes = _solidJpeg(100, 100, 30, 30, 220);
      const u = [
        EditPoint(0.1, 0.1),
        EditPoint(0.9, 0.1),
        EditPoint(0.9, 0.9),
        EditPoint(0.6, 0.9),
        EditPoint(0.6, 0.4),
        EditPoint(0.4, 0.4),
        EditPoint(0.4, 0.9),
        EditPoint(0.1, 0.9),
      ];
      final result =
          exportEditedImage(bytes, ImageEditState.none.withPolygon(u));
      final decoded = _decode(result);
      final window = paddedPolygonCropRect(u, 100, 100);

      img.Pixel at(double normX, double normY) => decoded.getPixel(
            (normX * 100 - window.x).round(),
            (normY * 100 - window.y).round(),
          );
      expect(_isWhite(at(0.5, 0.7)), isTrue); // the notch
      expect(_isWhite(at(0.2, 0.7)), isFalse); // left arm keeps its blue
      expect(at(0.2, 0.7).b, greaterThan(180));
    });

    test('rect crop maps exactly like rectCropToPixels (no white fill)', () {
      final bytes = _solidJpeg(200, 100, 60, 180, 60);
      const rect = RectCrop(left: 0.25, top: 0.5, width: 0.5, height: 0.25);
      final result =
          exportEditedImage(bytes, ImageEditState.none.withRect(rect));
      final px = rectCropToPixels(rect, 200, 100);
      expect((result.width, result.height), (px.width, px.height));
      // Rect crop keeps every pixel — nothing whitened.
      final decoded = _decode(result);
      expect(_isWhite(decoded.getPixel(0, 0)), isFalse);
    });

    test('lighting bakes the exact preview linear map (within JPEG tolerance)',
        () {
      const lighting =
          LightingAdjust(brightness: 0.4, contrast: 0.3, warmth: 0.5);
      final result = exportEditedImage(
        _solidJpeg(64, 64, 100, 100, 100),
        const ImageEditState(lighting: lighting),
      );
      final decoded = _decode(result);
      final p = decoded.getPixel(32, 32);

      final scales = lighting.channelScales;
      final offset = lighting.channelOffset;
      expect(
        p.r.toDouble(),
        closeTo(LightingAdjust.applyToChannel(100, scales[0], offset), 4),
      );
      expect(
        p.g.toDouble(),
        closeTo(LightingAdjust.applyToChannel(100, scales[1], offset), 4),
      );
      expect(
        p.b.toDouble(),
        closeTo(LightingAdjust.applyToChannel(100, scales[2], offset), 4),
      );
    });

    test('white fill stays pure white even under darkening lighting', () {
      // Lighting is applied BEFORE the fill: a -1 brightness must not turn the
      // removed background gray.
      final result = exportEditedImage(
        _solidJpeg(100, 100, 128, 128, 128),
        const ImageEditState(lighting: LightingAdjust(brightness: -1))
            .withPolygon(const [
          EditPoint(0.3, 0.3),
          EditPoint(0.7, 0.3),
          EditPoint(0.7, 0.7),
          EditPoint(0.3, 0.7),
        ]),
      );
      final decoded = _decode(result);
      expect(_isWhite(decoded.getPixel(0, 0)), isTrue);
      // Inside got the darkening.
      final center = decoded.getPixel(decoded.width ~/ 2, decoded.height ~/ 2);
      expect(center.r, lessThan(80));
    });

    test('alpha input is flattened onto white; output decodes with 3 channels',
        () {
      final png = img.Image(width: 40, height: 40, numChannels: 4);
      img.fill(png, color: img.ColorRgba8(255, 0, 0, 0)); // fully transparent
      final result = exportEditedImage(
        Uint8List.fromList(img.encodePng(png)),
        ImageEditState.none,
      );
      final decoded = _decode(result);
      expect(decoded.numChannels, 3);
      expect(_isWhite(decoded.getPixel(20, 20)), isTrue);
    });

    test(
        'tight-crop guard: flags small output, NEVER upscales; big output clean',
        () {
      final small = exportEditedImage(
          _solidJpeg(500, 300, 10, 10, 10), ImageEditState.none);
      expect(small.isTight, isTrue);
      expect((small.width, small.height), (500, 300)); // untouched size

      final big = exportEditedImage(
          _solidJpeg(1100, 200, 10, 10, 10), ImageEditState.none);
      expect(big.isTight, isFalse);
    });

    test('undecodable bytes throw FormatException', () {
      expect(
        () => exportEditedImage(
            Uint8List.fromList([1, 2, 3, 4]), ImageEditState.none),
        throwsFormatException,
      );
    });
  });
}
