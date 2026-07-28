// lib/domain/entities/image_edit.dart
//
// Pure edit-state + math for the Prepare-Images screen (staff Meshy flow):
// polygon crop ("manual background remover"), rectangle crop, lighting
// adjustments, and 90° rotation — everything the live preview AND the export
// pass share, so what the user sees is exactly what Meshy receives.
//
// Pure Dart on purpose (no Flutter/dart:ui imports): the exporter runs this in
// a background isolate and unit tests exercise it without a widget tree.
//
// COORDINATE CONTRACT: every point/rect here is NORMALIZED to [0,1] in the
// space of the ROTATED image (rotation is applied first in both the preview
// and the export pipeline). Pixel conversion happens only at the edges — the
// overlay painter and the exporter.
import 'dart:math' as math;

/// A crop below this on its LONGEST side is flagged "very tight" — the export
/// still proceeds (never upscale: invented pixels hurt Meshy geometry more
/// than small inputs), but the UI warns on the thumbnail.
const int kMinExportLongSidePx = 1024;

/// Exports are downscaled to this long side before upload. Matches the
/// MESHY_TEXTURE_RESOLUTION ('2k') budget the worker requests — larger inputs
/// cost upload time and Meshy discards the extra detail anyway. Only ever
/// shrinks: a source already under this is left alone (never upscale, same
/// reasoning as [kMinExportLongSidePx]).
const int kMaxExportLongSidePx = 2048;

/// The [width]×[height] an export should be resized to so its longest side is
/// at most [kMaxExportLongSidePx], preserving aspect ratio (each side at least
/// 1px). Returns null when the image is already within budget — the caller
/// skips the resize entirely rather than round-tripping identical pixels.
({int width, int height})? downscaleTarget(
  int width,
  int height, {
  int maxLongSide = kMaxExportLongSidePx,
}) {
  final longSide = math.max(width, height);
  if (longSide <= maxLongSide) return null;
  final scale = maxLongSide / longSide;
  return (
    width: math.max(1, (width * scale).round()),
    height: math.max(1, (height * scale).round()),
  );
}

/// Padding added around a polygon's bounding box on export, as a fraction of
/// the box's longer side — a small breathing margin so the white fill never
/// clips the object's own outline.
const double kPolygonCropPaddingFraction = 0.03;

/// One polygon vertex, normalized to [0,1] × [0,1] of the rotated image.
class EditPoint {
  const EditPoint(this.x, this.y);

  final double x;
  final double y;

  EditPoint clamped() =>
      EditPoint(x.clamp(0.0, 1.0).toDouble(), y.clamp(0.0, 1.0).toDouble());

  double distanceTo(EditPoint other) {
    final dx = x - other.x;
    final dy = y - other.y;
    return math.sqrt(dx * dx + dy * dy);
  }

  @override
  bool operator ==(Object other) =>
      other is EditPoint && other.x == x && other.y == y;

  @override
  int get hashCode => Object.hash(x, y);

  @override
  String toString() => 'EditPoint($x, $y)';
}

/// A normalized axis-aligned rectangle crop ([left]/[top]/[width]/[height]
/// all in [0,1] of the rotated image).
class RectCrop {
  const RectCrop({
    required this.left,
    required this.top,
    required this.width,
    required this.height,
  });

  final double left;
  final double top;
  final double width;
  final double height;

  /// Whether this rect is effectively the whole image (a no-op crop).
  bool get isFullImage =>
      left <= 0.0005 && top <= 0.0005 && width >= 0.999 && height >= 0.999;
}

/// Brightness / contrast / warmth, each in [-1, 1] with 0 = untouched.
///
/// The SINGLE source of lighting truth: [channelScales] + [channelOffset]
/// define the per-channel linear map `out = in * scale + offset`, consumed
/// verbatim by BOTH the preview's ColorFilter.matrix and the exporter's
/// per-pixel pass — they cannot drift apart.
class LightingAdjust {
  const LightingAdjust({
    this.brightness = 0,
    this.contrast = 0,
    this.warmth = 0,
  });

  static const neutral = LightingAdjust();

  /// Additive brightness at full slider = ±[_brightnessRange] (0–255 scale).
  static const double _brightnessRange = 100;

  /// Contrast slider maps to a multiplicative factor 1 ± [_contrastRange],
  /// pivoted at mid-gray 128 so it doesn't double as brightness.
  static const double _contrastRange = 0.6;

  /// Warmth tilts R up / B down (or the inverse) by at most this fraction.
  static const double _warmthRange = 0.2;

  final double brightness;
  final double contrast;
  final double warmth;

  bool get isNeutral => brightness == 0 && contrast == 0 && warmth == 0;

  double get _contrastFactor => 1 + contrast * _contrastRange;

  /// Per-channel multiplicative scales [r, g, b].
  List<double> get channelScales {
    final c = _contrastFactor;
    return [
      c * (1 + warmth * _warmthRange),
      c,
      c * (1 - warmth * _warmthRange),
    ];
  }

  /// The shared additive term (contrast pivot + brightness), 0–255 scale.
  double get channelOffset =>
      128 * (1 - _contrastFactor) + brightness * _brightnessRange;

  /// One channel value through the linear map, clamped to a valid byte —
  /// exactly what ColorFilter.matrix computes for the same matrix.
  static int applyToChannel(num value, double scale, double offset) =>
      (value * scale + offset).round().clamp(0, 255);

  /// The 4×5 row-major color matrix (ColorFilter.matrix layout) implementing
  /// the same linear map for the live preview.
  List<double> toColorMatrix() {
    final scales = channelScales;
    final offset = channelOffset;
    return [
      scales[0], 0, 0, 0, offset, //
      0, scales[1], 0, 0, offset, //
      0, 0, scales[2], 0, offset, //
      0, 0, 0, 1, 0, //
    ];
  }

  LightingAdjust copyWith(
          {double? brightness, double? contrast, double? warmth}) =>
      LightingAdjust(
        brightness: brightness ?? this.brightness,
        contrast: contrast ?? this.contrast,
        warmth: warmth ?? this.warmth,
      );

  @override
  bool operator ==(Object other) =>
      other is LightingAdjust &&
      other.brightness == brightness &&
      other.contrast == contrast &&
      other.warmth == warmth;

  @override
  int get hashCode => Object.hash(brightness, contrast, warmth);
}

/// The full per-image edit: rotation, lighting, and at most ONE crop shape
/// (applying a polygon clears a rectangle and vice versa — mixing the two has
/// no meaningful preview).
class ImageEditState {
  const ImageEditState({
    this.quarterTurns = 0,
    this.lighting = LightingAdjust.neutral,
    this.polygon,
    this.rect,
  });

  static const none = ImageEditState();

  /// Clockwise 90° steps, always kept in 0..3.
  final int quarterTurns;
  final LightingAdjust lighting;

  /// A CLOSED polygon (≥ 3 points, no closing duplicate vertex), or null.
  final List<EditPoint>? polygon;
  final RectCrop? rect;

  bool get isEdited =>
      quarterTurns != 0 ||
      !lighting.isNeutral ||
      polygon != null ||
      (rect != null && !rect!.isFullImage);

  ImageEditState rotatedOnce() => ImageEditState(
        quarterTurns: (quarterTurns + 1) % 4,
        lighting: lighting,
        // A crop is defined in the PRE-rotation display space; rather than
        // remapping (surprising results for a polygon the user can no longer
        // see), rotation clears it — the UI states this before rotating.
        polygon: null,
        rect: null,
      );

  ImageEditState withLighting(LightingAdjust next) => ImageEditState(
        quarterTurns: quarterTurns,
        lighting: next,
        polygon: polygon,
        rect: rect,
      );

  ImageEditState withPolygon(List<EditPoint>? points) => ImageEditState(
        quarterTurns: quarterTurns,
        lighting: lighting,
        polygon: points == null ? null : List.unmodifiable(points),
        rect: null,
      );

  ImageEditState withRect(RectCrop? next) => ImageEditState(
        quarterTurns: quarterTurns,
        lighting: lighting,
        polygon: null,
        rect: next,
      );
}

/// A polygon's axis-aligned normalized bounding box as `(left, top, right,
/// bottom)`. Empty input → the full image.
({double left, double top, double right, double bottom}) polygonBounds(
  List<EditPoint> points,
) {
  if (points.isEmpty) return (left: 0, top: 0, right: 1, bottom: 1);
  var minX = points.first.x, maxX = points.first.x;
  var minY = points.first.y, maxY = points.first.y;
  for (final p in points) {
    minX = math.min(minX, p.x);
    maxX = math.max(maxX, p.x);
    minY = math.min(minY, p.y);
    maxY = math.max(maxY, p.y);
  }
  return (left: minX, top: minY, right: maxX, bottom: maxY);
}

/// An integer pixel crop window `(x, y, width, height)`.
typedef PixelRect = ({int x, int y, int width, int height});

/// The polygon's padded bounding box in PIXELS of a [imageWidth]×[imageHeight]
/// image: normalized bounds → pixels → + [kPolygonCropPaddingFraction] margin
/// of the box's longer side → clamped to the image. Never returns an empty
/// rect (minimum 1×1).
PixelRect paddedPolygonCropRect(
  List<EditPoint> points,
  int imageWidth,
  int imageHeight, {
  double paddingFraction = kPolygonCropPaddingFraction,
}) {
  final b = polygonBounds(points);
  final leftPx = b.left * imageWidth;
  final topPx = b.top * imageHeight;
  final rightPx = b.right * imageWidth;
  final bottomPx = b.bottom * imageHeight;
  final pad = math.max(rightPx - leftPx, bottomPx - topPx) * paddingFraction;

  final x0 = (leftPx - pad).floor().clamp(0, imageWidth - 1);
  final y0 = (topPx - pad).floor().clamp(0, imageHeight - 1);
  final x1 = (rightPx + pad).ceil().clamp(x0 + 1, imageWidth);
  final y1 = (bottomPx + pad).ceil().clamp(y0 + 1, imageHeight);
  return (x: x0, y: y0, width: x1 - x0, height: y1 - y0);
}

/// [RectCrop] → integer pixels, clamped, never empty.
PixelRect rectCropToPixels(RectCrop rect, int imageWidth, int imageHeight) {
  final x0 = (rect.left * imageWidth).floor().clamp(0, imageWidth - 1);
  final y0 = (rect.top * imageHeight).floor().clamp(0, imageHeight - 1);
  final x1 =
      ((rect.left + rect.width) * imageWidth).ceil().clamp(x0 + 1, imageWidth);
  final y1 = ((rect.top + rect.height) * imageHeight)
      .ceil()
      .clamp(y0 + 1, imageHeight);
  return (x: x0, y: y0, width: x1 - x0, height: y1 - y0);
}

/// Whether a [width]×[height] export lands under the [kMinExportLongSidePx]
/// guard — the "Very tight crop" warning condition.
bool isTightCrop(int width, int height) =>
    math.max(width, height) < kMinExportLongSidePx;

/// Even-odd point-in-polygon (ray cast). Vertices are the CLOSED polygon
/// without a duplicated closing vertex. Used by tests and small fills; the
/// exporter's hot path uses [polygonRowSpans] instead.
bool pointInPolygon(double x, double y, List<EditPoint> polygon) {
  var inside = false;
  for (var i = 0, j = polygon.length - 1; i < polygon.length; j = i++) {
    final pi = polygon[i];
    final pj = polygon[j];
    final crosses = (pi.y > y) != (pj.y > y);
    if (crosses && x < (pj.x - pi.x) * (y - pi.y) / (pj.y - pi.y) + pi.x) {
      inside = !inside;
    }
  }
  return inside;
}

/// Scanline form of [pointInPolygon]: the sorted x-intersections of the
/// horizontal line `y = [y]` with the polygon's edges, in the same normalized
/// space. Consecutive pairs bound the INSIDE spans (even-odd rule) — the
/// exporter walks one row at a time and whitens everything outside the pairs,
/// which is O(rows × vertices) instead of O(pixels × vertices).
List<double> polygonRowSpans(double y, List<EditPoint> polygon) {
  final xs = <double>[];
  for (var i = 0, j = polygon.length - 1; i < polygon.length; j = i++) {
    final pi = polygon[i];
    final pj = polygon[j];
    if ((pi.y > y) != (pj.y > y)) {
      xs.add((pj.x - pi.x) * (y - pi.y) / (pj.y - pi.y) + pi.x);
    }
  }
  xs.sort();
  return xs;
}

/// Inserts the midpoint of the segment [afterIndex] → [afterIndex]+1 (wrapping)
/// as a new draggable vertex. Returns a new list.
List<EditPoint> insertMidpoint(List<EditPoint> points, int afterIndex) {
  final next = (afterIndex + 1) % points.length;
  final a = points[afterIndex];
  final b = points[next];
  final mid = EditPoint((a.x + b.x) / 2, (a.y + b.y) / 2);
  return [
    ...points.sublist(0, afterIndex + 1),
    mid,
    ...points.sublist(afterIndex + 1)
  ];
}

/// Removes the vertex at [index]; refuses (returns the input) when the polygon
/// would drop below 3 vertices.
List<EditPoint> removePointAt(List<EditPoint> points, int index) {
  if (points.length <= 3) return points;
  return [...points.sublist(0, index), ...points.sublist(index + 1)];
}

/// Replaces the vertex at [index] with [position] (clamped inside the image).
List<EditPoint> movePoint(
    List<EditPoint> points, int index, EditPoint position) {
  final next = [...points];
  next[index] = position.clamped();
  return next;
}
