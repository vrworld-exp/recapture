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
  // Bundled defaults: low [0,60), mid [60,120), high [120,180).
  const config = CaptureConfig.bundledDefault;
  const mid = PitchBand(id: 'mid', minDegrees: 60, maxDegrees: 120, segments: 10);

  group('CapturePitchGuide.isInBand', () {
    test('tilt inside the band is true', () {
      expect(CapturePitchGuide.isInBand(mid, 90), isTrue);
    });

    test('lower bound is inclusive', () {
      expect(CapturePitchGuide.isInBand(mid, 60), isTrue);
    });

    test('upper bound is exclusive', () {
      expect(CapturePitchGuide.isInBand(mid, 120), isFalse);
    });

    test('outside the band is false', () {
      expect(CapturePitchGuide.isInBand(mid, 59.999), isFalse);
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
      expect(CapturePitchGuide.activeBand(config, 59.9)?.id, 'low');
      expect(CapturePitchGuide.activeBand(config, 60)?.id, 'mid');
      expect(CapturePitchGuide.activeBand(config, 119.9)?.id, 'mid');
      expect(CapturePitchGuide.activeBand(config, 120)?.id, 'high');
      expect(CapturePitchGuide.activeBand(config, 179.999)?.id, 'high');
    });

    test('a physically perfect 180° (clamped by the tilt primitive) → high',
        () {
      // The identity pose yields exactly 180°, which cameraTiltDegrees clamps
      // to 179.999 so the max-EXCLUSIVE high band [120, 180) still admits it.
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
