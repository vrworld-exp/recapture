// test/projects/image_edit_test.dart
//
// Pure math behind the Prepare-Images screen (domain/entities/image_edit.dart):
// the lighting linear map (single source of truth for preview AND export),
// polygon geometry (bounds, padded crop, point ops, scanline spans), rect
// crop pixel mapping, and the min-size tight-crop guard.
import 'package:flutter_test/flutter_test.dart';
import 'package:recapture/domain/entities/image_edit.dart';

void main() {
  group('LightingAdjust', () {
    test('neutral is the identity map', () {
      const neutral = LightingAdjust.neutral;
      expect(neutral.isNeutral, isTrue);
      expect(neutral.channelScales, [1, 1, 1]);
      expect(neutral.channelOffset, 0);
      expect(LightingAdjust.applyToChannel(37, 1, 0), 37);

      final matrix = neutral.toColorMatrix();
      expect(matrix.length, 20);
      expect(matrix[0], 1); // R scale
      expect(matrix[6], 1); // G scale
      expect(matrix[12], 1); // B scale
      expect(matrix[4], 0); // R offset
    });

    test('brightness is a pure additive shift', () {
      const bright = LightingAdjust(brightness: 0.5);
      expect(bright.channelScales, [1, 1, 1]);
      expect(bright.channelOffset, 50); // 0.5 × 100 range
      expect(LightingAdjust.applyToChannel(100, 1, bright.channelOffset), 150);
    });

    test('contrast pivots at mid-gray 128 (128 stays put)', () {
      const contrasty = LightingAdjust(contrast: 1);
      final scale = contrasty.channelScales[1];
      final offset = contrasty.channelOffset;
      expect(LightingAdjust.applyToChannel(128, scale, offset), 128);
      // Darker gets darker, lighter gets lighter.
      expect(LightingAdjust.applyToChannel(64, scale, offset), lessThan(64));
      expect(
          LightingAdjust.applyToChannel(200, scale, offset), greaterThan(200));
    });

    test('warmth tilts R up and B down symmetrically', () {
      const warm = LightingAdjust(warmth: 1);
      final scales = warm.channelScales;
      expect(scales[0], greaterThan(scales[1]));
      expect(scales[2], lessThan(scales[1]));
      expect(scales[0] - scales[1], closeTo(scales[1] - scales[2], 1e-9));

      // The matrix rows carry the same per-channel scales.
      final matrix = warm.toColorMatrix();
      expect(matrix[0], scales[0]);
      expect(matrix[6], scales[1]);
      expect(matrix[12], scales[2]);
    });

    test('applyToChannel clamps to a valid byte', () {
      expect(LightingAdjust.applyToChannel(250, 1, 100), 255);
      expect(LightingAdjust.applyToChannel(10, 1, -100), 0);
    });
  });

  group('polygon geometry', () {
    const square = [
      EditPoint(0.2, 0.2),
      EditPoint(0.8, 0.2),
      EditPoint(0.8, 0.8),
      EditPoint(0.2, 0.8),
    ];

    test('polygonBounds finds the AABB; empty input means the full image', () {
      final b = polygonBounds(square);
      expect(b.left, 0.2);
      expect(b.top, 0.2);
      expect(b.right, 0.8);
      expect(b.bottom, 0.8);

      final empty = polygonBounds(const []);
      expect(
        (empty.left, empty.top, empty.right, empty.bottom),
        (0.0, 0.0, 1.0, 1.0),
      );
    });

    test('paddedPolygonCropRect pads by the longer side and clamps', () {
      // 1000×500 image; polygon box x 200..800, y 100..400 → 600×300 px,
      // pad = 600 × 0.03 = 18 px.
      final rect = paddedPolygonCropRect(square, 1000, 500);
      // Box: x 200..800 (600 wide), y 100..400 (300 tall); pad = 18.
      expect(rect.x, 182);
      expect(rect.y, 82);
      expect(rect.width, 800 + 18 - 182);
      expect(rect.height, 400 + 18 - 82);

      // A polygon hugging the corner clamps at 0 instead of going negative.
      const cornered = [
        EditPoint(0, 0),
        EditPoint(0.5, 0),
        EditPoint(0.5, 0.5),
        EditPoint(0, 0.5),
      ];
      final clamped = paddedPolygonCropRect(cornered, 100, 100);
      expect(clamped.x, 0);
      expect(clamped.y, 0);
    });

    test('pointInPolygon: inside, outside, concave notch', () {
      expect(pointInPolygon(0.5, 0.5, square), isTrue);
      expect(pointInPolygon(0.1, 0.5, square), isFalse);

      // A U-shape: the notch's interior is OUTSIDE the polygon.
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
      expect(pointInPolygon(0.5, 0.7, u), isFalse); // inside the notch
      expect(pointInPolygon(0.2, 0.7, u), isTrue); // left arm
      expect(pointInPolygon(0.5, 0.2, u), isTrue); // bridge
    });

    test('polygonRowSpans agrees with pointInPolygon', () {
      final spans = polygonRowSpans(0.5, square);
      expect(spans, hasLength(2));
      expect(spans[0], closeTo(0.2, 1e-9));
      expect(spans[1], closeTo(0.8, 1e-9));
      // A row above the polygon has no spans.
      expect(polygonRowSpans(0.05, square), isEmpty);
    });

    test('insert / remove / move point ops', () {
      final inserted = insertMidpoint(square, 0);
      expect(inserted, hasLength(5));
      expect(inserted[1], const EditPoint(0.5, 0.2));

      // Wrapping insert: after the LAST vertex, midpoint of last→first.
      final wrapped = insertMidpoint(square, 3);
      expect(wrapped, hasLength(5));
      expect(wrapped[4], const EditPoint(0.2, 0.5));

      final removed = removePointAt(inserted, 1);
      expect(removed, square);

      // A triangle refuses to lose a vertex.
      final triangle = square.sublist(0, 3);
      expect(removePointAt(triangle, 0), same(triangle));

      final moved = movePoint(square, 0, const EditPoint(-0.5, 2));
      expect(moved[0], const EditPoint(0, 1)); // clamped into the image
      expect(moved.sublist(1), square.sublist(1));
    });
  });

  group('rect crop + guards', () {
    test('rectCropToPixels maps and clamps', () {
      const rect = RectCrop(left: 0.25, top: 0.5, width: 0.5, height: 0.25);
      final px = rectCropToPixels(rect, 400, 200);
      expect((px.x, px.y, px.width, px.height), (100, 100, 200, 50));

      // Degenerate never yields an empty window.
      const sliver =
          RectCrop(left: 0.999, top: 0.999, width: 0.0001, height: 0.0001);
      final tiny = rectCropToPixels(sliver, 100, 100);
      expect(tiny.width, greaterThanOrEqualTo(1));
      expect(tiny.height, greaterThanOrEqualTo(1));
    });

    test('isFullImage detects the no-op rect', () {
      expect(const RectCrop(left: 0, top: 0, width: 1, height: 1).isFullImage,
          isTrue);
      expect(const RectCrop(left: 0, top: 0, width: 0.9, height: 1).isFullImage,
          isFalse);
    });

    test('isTightCrop trips strictly under 1024 on the LONG side', () {
      expect(isTightCrop(1023, 500), isTrue);
      expect(isTightCrop(1024, 10), isFalse);
      expect(isTightCrop(500, 2000), isFalse);
    });
  });

  group('ImageEditState', () {
    test('isEdited flags each edit kind; none is clean', () {
      expect(ImageEditState.none.isEdited, isFalse);
      expect(const ImageEditState(quarterTurns: 1).isEdited, isTrue);
      expect(
        const ImageEditState(lighting: LightingAdjust(brightness: 0.1))
            .isEdited,
        isTrue,
      );
      expect(
        ImageEditState.none.withPolygon(const [
          EditPoint(0, 0),
          EditPoint(1, 0),
          EditPoint(1, 1),
        ]).isEdited,
        isTrue,
      );
      // A full-image rect is a no-op, not an edit.
      expect(
        ImageEditState.none
            .withRect(const RectCrop(left: 0, top: 0, width: 1, height: 1))
            .isEdited,
        isFalse,
      );
    });

    test('rotatedOnce wraps 3→0, keeps lighting, clears any crop', () {
      final state = const ImageEditState(
        quarterTurns: 3,
        lighting: LightingAdjust(warmth: 0.5),
      ).withPolygon(const [EditPoint(0, 0), EditPoint(1, 0), EditPoint(1, 1)]);

      final rotated = state.rotatedOnce();
      expect(rotated.quarterTurns, 0);
      expect(rotated.lighting, const LightingAdjust(warmth: 0.5));
      expect(rotated.polygon, isNull);
    });

    test('polygon and rect are mutually exclusive', () {
      const rect = RectCrop(left: 0.1, top: 0.1, width: 0.5, height: 0.5);
      final withRect = ImageEditState.none.withRect(rect);
      final thenPolygon = withRect.withPolygon(
          const [EditPoint(0, 0), EditPoint(1, 0), EditPoint(1, 1)]);
      expect(thenPolygon.rect, isNull);
      expect(thenPolygon.polygon, isNotNull);
      expect(thenPolygon.withRect(rect).polygon, isNull);
    });
  });
}
