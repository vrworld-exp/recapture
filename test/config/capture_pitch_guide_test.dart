// test/config/capture_pitch_guide_test.dart
//
// Verifies the pure pitch-band membership helpers over the EXISTING
// config-driven PitchBand (degrees, server-tunable): min-inclusive /
// max-exclusive tiling, the active band for a pitch, and IEEE edge values.
import 'package:flutter_test/flutter_test.dart';
import 'package:recapture/domain/entities/capture_config.dart';
import 'package:recapture/domain/entities/capture_pitch_guide.dart';

void main() {
  // Bundled defaults: low [0,30), mid [30,60), high [60,90).
  const config = CaptureConfig.bundledDefault;
  const mid = PitchBand(id: 'mid', minDegrees: 30, maxDegrees: 60, segments: 10);

  group('CapturePitchGuide.isInBand', () {
    test('pitch inside the band is true', () {
      expect(CapturePitchGuide.isInBand(mid, 45), isTrue);
    });

    test('lower bound is inclusive', () {
      expect(CapturePitchGuide.isInBand(mid, 30), isTrue);
    });

    test('upper bound is exclusive', () {
      expect(CapturePitchGuide.isInBand(mid, 60), isFalse);
    });

    test('outside the band is false', () {
      expect(CapturePitchGuide.isInBand(mid, 29.999), isFalse);
      expect(CapturePitchGuide.isInBand(mid, 75), isFalse);
    });

    test('NaN and Infinity yield false (no throw)', () {
      expect(CapturePitchGuide.isInBand(mid, double.nan), isFalse);
      expect(CapturePitchGuide.isInBand(mid, double.infinity), isFalse);
      expect(CapturePitchGuide.isInBand(mid, double.negativeInfinity), isFalse);
    });
  });

  group('CapturePitchGuide.activeBand (bundled bands)', () {
    test('selects the band a pitch falls into', () {
      expect(CapturePitchGuide.activeBand(config, 0)?.id, 'low');
      expect(CapturePitchGuide.activeBand(config, 15)?.id, 'low');
      expect(CapturePitchGuide.activeBand(config, 30)?.id, 'mid');
      expect(CapturePitchGuide.activeBand(config, 59.9)?.id, 'mid');
      expect(CapturePitchGuide.activeBand(config, 60)?.id, 'high');
      expect(CapturePitchGuide.activeBand(config, 89.9)?.id, 'high');
    });

    test('returns null outside every band', () {
      expect(CapturePitchGuide.activeBand(config, -1), isNull);
      expect(CapturePitchGuide.activeBand(config, 90), isNull); // max exclusive
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
