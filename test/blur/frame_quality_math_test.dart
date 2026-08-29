// test/blur/frame_quality_math_test.dart
//
// The Dart port of the native frame-quality metrics
// (android/.../camera/BlurMetric.kt + ExposureMetric.kt), which is what makes a
// web build's blur and exposure scores comparable to a phone's.
//
// The property that actually matters is the NORMALIZATION WIDTH. Variance of
// the Laplacian scales with resolution, so the same scene analysed at 1920px
// and at 640px produces wildly different numbers against the SAME
// BlurThresholdPolicy constants. Normalizing to native's 640px width is what
// lets one threshold set serve both platforms — so the downscale, and the fact
// that scores stay in the thresholds' discriminating range, are tested here.
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:recapture/platform/blur_policy.dart';
import 'package:recapture/platform/capture_ports/frame_quality_math.dart';
import 'package:recapture/platform/exposure_policy.dart';

/// A flat grey image — zero texture, so zero Laplacian variance.
GrayImage _flat(int w, int h, int value) =>
    GrayImage(w, h, Uint8List(w * h)..fillRange(0, w * h, value));

/// A high-contrast checkerboard — maximum edge energy, so a large variance.
GrayImage _checker(int w, int h, {int cell = 1}) {
  final px = Uint8List(w * h);
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      px[y * w + x] = ((x ~/ cell) + (y ~/ cell)).isEven ? 0 : 255;
    }
  }
  return GrayImage(w, h, px);
}

/// A soft gradient — some texture, but far less edge energy than a checker.
GrayImage _gradient(int w, int h) {
  final px = Uint8List(w * h);
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      px[y * w + x] = (255 * x / (w - 1)).round();
    }
  }
  return GrayImage(w, h, px);
}

void main() {
  group('BlurMetric.laplacianVariance', () {
    test('a flat image scores ~0 and classifies as blurry', () {
      final variance = BlurMetric.laplacianVariance(_flat(64, 48, 128));
      expect(variance, closeTo(0, 1e-9));
      expect(variance >= BlurMetric.defaultThreshold, isFalse);
      expect(
        BlurThresholdPolicy.defaults.classify(variance),
        BlurBand.reject,
      );
    });

    test('a sharp checkerboard scores far above the sharp cutoff', () {
      final variance = BlurMetric.laplacianVariance(_checker(64, 48));
      expect(variance, greaterThan(BlurMetric.defaultThreshold));
      expect(
        BlurThresholdPolicy.defaults.classify(variance),
        BlurBand.accept,
      );
    });

    test('a soft gradient scores well below a hard edge', () {
      expect(
        BlurMetric.laplacianVariance(_gradient(64, 48)),
        lessThan(BlurMetric.laplacianVariance(_checker(64, 48))),
      );
    });

    test('an image with no interior scores 0 rather than throwing', () {
      expect(BlurMetric.laplacianVariance(_flat(2, 2, 200)), 0);
      expect(BlurMetric.laplacianVariance(GrayImage(0, 0, Uint8List(0))), 0);
    });
  });

  group('BlurMetric.downscale — the 640px normalization', () {
    test('scales a wide source to exactly 640, preserving aspect', () {
      final out = BlurMetric.downscale(_checker(1920, 1080, cell: 8));
      expect(out.width, BlurMetric.defaultTargetWidth);
      expect(out.height, (1080 * 640 / 1920).round());
      expect(out.pixels.length, out.width * out.height);
    });

    test('a source at or below the target is never upscaled', () {
      final src = _checker(320, 240);
      final out = BlurMetric.downscale(src);
      expect(out.width, 320);
      expect(out.height, 240);
      // Upscaling would interpolate new edges and INFLATE the variance, which
      // would make a small source look sharper than it is.
      expect(identical(out, src), isTrue);
    });

    test('portrait sources keep their aspect ratio', () {
      final out = BlurMetric.downscale(_flat(1080, 1920, 128));
      expect(out.width, 640);
      expect(out.height, (1920 * 640 / 1080).round());
    });

    test('the normalized score still discriminates sharp from blurry', () {
      // The whole reason for normalizing: one threshold set must separate a
      // textured frame from a flat one AFTER the downscale.
      final sharp = BlurMetric.laplacianVariance(
          BlurMetric.downscale(_checker(1920, 1080, cell: 2)));
      final blurry = BlurMetric.laplacianVariance(
          BlurMetric.downscale(_flat(1920, 1080, 128)));
      expect(sharp, greaterThan(BlurThresholdPolicy.defaultAcceptAbove));
      expect(blurry, lessThan(BlurThresholdPolicy.defaultRejectBelow));
    });
  });

  group('ExposureMetric.meanLuminance', () {
    test('a flat image reports exactly its value', () {
      expect(
          ExposureMetric.meanLuminance(_flat(32, 32, 200)), closeTo(200, 1e-9));
    });

    test('dark / ok / bright classify against the shared thresholds', () {
      final policy = ExposureThresholdPolicy.defaults;
      expect(policy.classify(ExposureMetric.meanLuminance(_flat(8, 8, 10))),
          ExposureBand.dark);
      expect(policy.classify(ExposureMetric.meanLuminance(_flat(8, 8, 128))),
          ExposureBand.ok);
      expect(policy.classify(ExposureMetric.meanLuminance(_flat(8, 8, 250))),
          ExposureBand.bright);
    });

    test('an empty image is NaN → unknown, never a confident "ok"', () {
      final mean = ExposureMetric.meanLuminance(GrayImage(0, 0, Uint8List(0)));
      expect(mean.isNaN, isTrue);
      expect(ExposureThresholdPolicy.defaults.classify(mean),
          ExposureBand.unknown);
    });

    test('the mean is scale-independent (survives the downscale)', () {
      // Why the exposure metric can safely reuse the blur pass's downscaled
      // buffer: averaging does not change with resolution.
      final src = _gradient(1920, 1080);
      expect(
        ExposureMetric.meanLuminance(BlurMetric.downscale(src)),
        closeTo(ExposureMetric.meanLuminance(src), 1.0),
      );
    });
  });

  group('lumaFromRgba', () {
    test('greys convert to themselves', () {
      final rgba = Uint8List.fromList(<int>[
        120, 120, 120, 255, //
        7, 7, 7, 255,
      ]);
      final gray = lumaFromRgba(rgba, 2, 1);
      expect(gray.pixels[0], closeTo(120, 1));
      expect(gray.pixels[1], closeTo(7, 1));
    });

    test('uses Rec.601 weights, matching what a YUV Y plane encodes', () {
      final rgba = Uint8List.fromList(<int>[
        255, 0, 0, 255, // red
        0, 255, 0, 255, // green
        0, 0, 255, 255, // blue
        255, 255, 255, 255, // white
      ]);
      final gray = lumaFromRgba(rgba, 4, 1);
      expect(gray.pixels[0], closeTo(0.299 * 255, 2));
      expect(gray.pixels[1], closeTo(0.587 * 255, 2));
      expect(gray.pixels[2], closeTo(0.114 * 255, 2));
      expect(gray.pixels[3], closeTo(255, 2));
    });

    test('produces exactly width × height samples', () {
      final rgba = Uint8List(16 * 9 * 4);
      final gray = lumaFromRgba(rgba, 16, 9);
      expect(gray.width, 16);
      expect(gray.height, 9);
      expect(gray.pixels.length, 16 * 9);
    });
  });

  group('a synthesized in-focus vs out-of-focus pair', () {
    test('blurring a sharp frame lowers its score across the threshold', () {
      final sharp = _checker(160, 120, cell: 4);
      final blurred = _boxBlur(sharp, radius: 3);
      final sharpScore = BlurMetric.laplacianVariance(sharp);
      final blurredScore = BlurMetric.laplacianVariance(blurred);
      expect(blurredScore, lessThan(sharpScore));
      expect(sharpScore, greaterThan(BlurMetric.defaultThreshold));
      expect(blurredScore, lessThan(sharpScore / 2));
    });
  });
}

/// A crude separable box blur — enough to simulate defocus for the metric.
GrayImage _boxBlur(GrayImage src, {required int radius}) {
  final out = Uint8List(src.width * src.height);
  for (var y = 0; y < src.height; y++) {
    for (var x = 0; x < src.width; x++) {
      var sum = 0;
      var n = 0;
      for (var dy = -radius; dy <= radius; dy++) {
        for (var dx = -radius; dx <= radius; dx++) {
          final sy = math.min(math.max(y + dy, 0), src.height - 1);
          final sx = math.min(math.max(x + dx, 0), src.width - 1);
          sum += src.pixels[sy * src.width + sx];
          n++;
        }
      }
      out[y * src.width + x] = sum ~/ n;
    }
  }
  return GrayImage(src.width, src.height, out);
}
