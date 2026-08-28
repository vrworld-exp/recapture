// test/config/capture_pitch_guide_test.dart
//
// Verifies the pure band membership helpers over the EXISTING config-driven
// PitchBand (0–180° camera-tilt degrees, server-tunable): min-inclusive /
// max-exclusive tiling, the active band for a tilt, and IEEE edge values.
import 'package:flutter_test/flutter_test.dart';
import 'package:recapture/domain/capture/camera_tilt.dart';
import 'package:recapture/domain/entities/capture_config.dart';
import 'package:recapture/domain/entities/capture_pitch_guide.dart';

void main() {
  // Bundled defaults: low [0,40), mid [40,110), high [110,180).
  const config = CaptureConfig.bundledDefault;
  const mid = PitchBand(id: 'mid', minDegrees: 40, maxDegrees: 110, segments: 10);

  group('CapturePitchGuide.isInBand', () {
    test('tilt inside the band is true', () {
      expect(CapturePitchGuide.isInBand(mid, 90), isTrue);
    });

    test('lower bound is inclusive', () {
      expect(CapturePitchGuide.isInBand(mid, 40), isTrue);
    });

    test('upper bound is exclusive', () {
      expect(CapturePitchGuide.isInBand(mid, 110), isFalse);
    });

    test('outside the band is false', () {
      expect(CapturePitchGuide.isInBand(mid, 39.999), isFalse);
      expect(CapturePitchGuide.isInBand(mid, 150), isFalse);
    });

    test('NaN and Infinity yield false (no throw)', () {
      expect(CapturePitchGuide.isInBand(mid, double.nan), isFalse);
      expect(CapturePitchGuide.isInBand(mid, double.infinity), isFalse);
      expect(CapturePitchGuide.isInBand(mid, double.negativeInfinity), isFalse);
    });
  });

  group('CapturePitchGuide.activeBand (bundled bands)', () {
    test('band membership sweep across the 0–180° scale', () {
      expect(CapturePitchGuide.activeBand(config, 0)?.id, 'low');
      expect(CapturePitchGuide.activeBand(config, 39.9)?.id, 'low');
      expect(CapturePitchGuide.activeBand(config, 40)?.id, 'mid');
      expect(CapturePitchGuide.activeBand(config, 90)?.id, 'mid');
      expect(CapturePitchGuide.activeBand(config, 109.9)?.id, 'mid');
      expect(CapturePitchGuide.activeBand(config, 110)?.id, 'high');
      expect(CapturePitchGuide.activeBand(config, 179.999)?.id, 'high');
    });

    test('new band edges land in exactly ONE band each (no gap, no overlap)',
        () {
      // The retuned boundaries: 40 and 110. Each probe must match exactly one
      // bundled band — this is the tiling contract, asserted at the seams.
      for (final tilt in <double>[39.999, 40.0, 109.999, 110.0]) {
        final hits =
            config.pitchBands.where((b) => CapturePitchGuide.isInBand(b, tilt));
        expect(hits, hasLength(1), reason: 'tilt $tilt matched ${hits.length}');
      }
      expect(CapturePitchGuide.activeBand(config, 39.999)?.id, 'low');
      expect(CapturePitchGuide.activeBand(config, 40.0)?.id, 'mid');
      expect(CapturePitchGuide.activeBand(config, 109.999)?.id, 'mid');
      expect(CapturePitchGuide.activeBand(config, 110.0)?.id, 'high');
    });

    test('a physically perfect 180° (clamped by the tilt primitive) → high',
        () {
      // The identity pose yields exactly 180°, which cameraTiltDegrees clamps
      // to 179.999 so the max-EXCLUSIVE high band [110, 180) still admits it.
      final flatScreenUp = cameraTiltDegrees(qx: 0, qy: 0, qz: 0, qw: 1);
      expect(CapturePitchGuide.activeBand(config, flatScreenUp)?.id, 'high');
    });

    test('returns null outside every band', () {
      expect(CapturePitchGuide.activeBand(config, -1), isNull);
      expect(CapturePitchGuide.activeBand(config, 180), isNull); // max exclusive
      expect(CapturePitchGuide.activeBand(config, double.nan), isNull);
    });
  });

  group('CapturePitchGuide is config-driven (not hardcoded)', () {
    test('honours a custom, server-style band set', () {
      const custom = CaptureConfig(
        version: 1,
        pitchBands: [PitchBand(id: 'shelf', minDegrees: 10, maxDegrees: 20, segments: 6)],
        thresholds: CaptureThresholds(
          minSharpness: 0.45,
          minCoveragePct: 80,
          maxTiltDeltaDeg: 12,
        ),
      );
      expect(CapturePitchGuide.activeBand(custom, 15)?.id, 'shelf');
      expect(CapturePitchGuide.activeBand(custom, 25), isNull);
      // A bundled-default band id is NOT present in the custom config.
      expect(CapturePitchGuide.activeBand(custom, 5), isNull);
    });
  });
}
