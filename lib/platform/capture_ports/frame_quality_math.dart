// lib/platform/capture_ports/frame_quality_math.dart
//
// Pure Dart — NO Flutter, NO dart:io, NO dart:js_interop. A port of the native
// frame-quality metrics (android/app/src/main/kotlin/.../camera/BlurMetric.kt
// and ExposureMetric.kt) so the browser produces scores on the SAME scale the
// existing thresholds were tuned against.
//
// Why that matters more than it looks: variance-of-Laplacian scales with
// resolution, so a "512 long edge" web downscale would have silently shifted
// every blur score away from `BlurThresholdPolicy`'s 100/40/220 constants and
// forced a web-specific threshold set. Normalizing to the SAME 640px **width**
// native uses keeps one threshold set valid on both platforms — no config fork,
// no code fork of the decision logic in CaptureQualityDecision.
//
// The one honest difference: a browser hands us RGBA, not a YUV Y plane, so
// [lumaFromRgba] converts with the Rec.601 coefficients the Y plane encodes.
// Mean luminance and Laplacian variance are then computed over exactly the same
// 8-bit grayscale the native code sees.
import 'dart:typed_data';

/// An 8-bit contiguous grayscale image (luma 0..255).
class GrayImage {
  const GrayImage(this.width, this.height, this.pixels);

  final int width;
  final int height;
  final Uint8List pixels;
}

/// Blur metric: variance of the Laplacian at a normalized width.
abstract final class BlurMetric {
  /// Normalization width; the thresholds are tuned at this scale (native
  /// `BlurMetric.DEFAULT_TARGET_WIDTH`).
  static const int defaultTargetWidth = 640;

  /// Default sharp/blurry cutoff at 640px width (native
  /// `BlurMetric.DEFAULT_THRESHOLD`).
  static const double defaultThreshold = 100.0;

  /// Nearest-neighbour downscale of [src] to [targetWidth] (aspect preserved),
  /// centre-sampling each destination pixel. Sources at or below [targetWidth]
  /// are NOT upscaled, so the metric is never inflated by interpolation.
  static GrayImage downscale(
    GrayImage src, {
    int targetWidth = defaultTargetWidth,
  }) {
    if (src.width <= 0 || src.height <= 0) {
      return GrayImage(0, 0, Uint8List(0));
    }
    final outW = src.width <= targetWidth ? src.width : targetWidth;
    final outH = _max(1, (src.height * outW / src.width).round());
    if (outW == src.width && outH == src.height) return src;
    final out = Uint8List(outW * outH);
    for (var oy = 0; oy < outH; oy++) {
      final sy = _clampInt(
          ((oy + 0.5) * src.height / outH).toInt(), 0, src.height - 1);
      final rowBase = sy * src.width;
      final outBase = oy * outW;
      for (var ox = 0; ox < outW; ox++) {
        final sx = _clampInt(
            ((ox + 0.5) * src.width / outW).toInt(), 0, src.width - 1);
        out[outBase + ox] = src.pixels[rowBase + sx];
      }
    }
    return GrayImage(outW, outH, out);
  }

  /// Variance of a 3×3 4-connected Laplacian (`[[0,1,0],[1,-4,1],[0,1,0]]`) over
  /// the interior of [gray]. Returns 0 for images too small to have an interior.
  static double laplacianVariance(GrayImage gray) {
    final w = gray.width;
    final h = gray.height;
    if (w < 3 || h < 3) return 0.0;
    final p = gray.pixels;
    var sum = 0.0;
    var sumSq = 0.0;
    var n = 0;
    for (var y = 1; y < h - 1; y++) {
      final row = y * w;
      for (var x = 1; x < w - 1; x++) {
        final i = row + x;
        final lap =
            (p[i - w] + p[i + w] + p[i - 1] + p[i + 1] - 4 * p[i]).toDouble();
        sum += lap;
        sumSq += lap * lap;
        n++;
      }
    }
    if (n == 0) return 0.0;
    final mean = sum / n;
    return (sumSq / n) - (mean * mean);
  }
}

/// Exposure metric: mean luminance on the 0–255 scale.
abstract final class ExposureMetric {
  /// Mean luminance of [gray] in `[0, 255]`; `NaN` for an empty image so the
  /// caller emits an explicit "unknown" band rather than a confident "ok".
  static double meanLuminance(GrayImage gray) {
    final pixels = gray.pixels;
    if (pixels.isEmpty) return double.nan;
    var sum = 0;
    for (final b in pixels) {
      sum += b;
    }
    return sum / pixels.length;
  }
}

/// Converts a browser `ImageData` RGBA buffer into the 8-bit grayscale the
/// metrics operate on, using the Rec.601 luma coefficients a YUV Y plane
/// already encodes (`Y = 0.299R + 0.587G + 0.114B`).
///
/// Integer weights (77/150/29 over 256) are used so the result is bit-stable
/// across dart2js/dartdevc numeric paths and cheap in the inner loop.
GrayImage lumaFromRgba(Uint8List rgba, int width, int height) {
  final count = width * height;
  final out = Uint8List(count);
  for (var i = 0, j = 0; i < count; i++, j += 4) {
    out[i] = (rgba[j] * 77 + rgba[j + 1] * 150 + rgba[j + 2] * 29) >> 8;
  }
  return GrayImage(width, height, out);
}

int _max(int a, int b) => a > b ? a : b;

int _clampInt(int v, int lo, int hi) => v < lo ? lo : (v > hi ? hi : v);
