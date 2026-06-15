// test/config/capture_config_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:recapture/domain/entities/capture_config.dart';

void main() {
  group('CaptureConfig.fromMap', () {
    test('parses a full, well-formed payload', () {
      final cfg = CaptureConfig.fromMap(const {
        'version': 3,
        'pitchBands': [
          {'id': 'low', 'minDegrees': 0, 'maxDegrees': 45, 'segments': 16},
        ],
        'thresholds': {
          'minSharpness': 0.6,
          'minCoveragePct': 90,
          'maxTiltDeltaDeg': 8,
        },
      });
      expect(cfg.version, 3);
      expect(cfg.pitchBands.single.id, 'low');
      expect(cfg.pitchBands.single.segments, 16);
      expect(cfg.thresholds.minSharpness, 0.6);
    });

    test('missing fields fall back to bundled values', () {
      final cfg = CaptureConfig.fromMap(const {});
      expect(cfg.version, 0);
      expect(cfg.pitchBands, CaptureConfig.bundledDefault.pitchBands);
      expect(cfg.thresholds.minSharpness,
          CaptureConfig.bundledDefault.thresholds.minSharpness);
    });

    test('empty pitchBands fall back to bundled bands', () {
      final cfg = CaptureConfig.fromMap(const {'version': 2, 'pitchBands': []});
      expect(cfg.version, 2);
      expect(cfg.pitchBands, CaptureConfig.bundledDefault.pitchBands);
    });

    test('wrong types degrade defensively (no throw)', () {
      final cfg = CaptureConfig.fromMap(const {
        'version': 'not-a-number',
        'pitchBands': 'nope',
        'thresholds': 'nope',
      });
      expect(cfg.version, 0);
      expect(cfg.pitchBands, CaptureConfig.bundledDefault.pitchBands);
      expect(cfg.thresholds.maxTiltDeltaDeg,
          CaptureConfig.bundledDefault.thresholds.maxTiltDeltaDeg);
    });

    test('skips non-map band rows', () {
      final cfg = CaptureConfig.fromMap(const {
        'pitchBands': [
          {'id': 'low', 'minDegrees': 0, 'maxDegrees': 30, 'segments': 5},
          'garbage',
          42,
        ],
      });
      expect(cfg.pitchBands.length, 1);
      expect(cfg.pitchBands.single.segments, 5);
    });
  });

  test('toMap → fromMap round-trips', () {
    const original = CaptureConfig.bundledDefault;
    final restored = CaptureConfig.fromMap(original.toMap());
    expect(restored.version, original.version);
    expect(restored.totalSegments, original.totalSegments);
    expect(restored.pitchBands.length, original.pitchBands.length);
    expect(restored.thresholds.minCoveragePct,
        original.thresholds.minCoveragePct);
  });

  test('totalSegments sums all bands', () {
    expect(CaptureConfig.bundledDefault.totalSegments, 12 + 10 + 8);
  });
}
