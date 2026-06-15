// test/config/capture_config_validator_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:recapture/domain/entities/capture_config.dart';
import 'package:recapture/domain/entities/capture_config_validator.dart';

CaptureConfig _cfg(List<PitchBand> bands, {CaptureThresholds? thresholds}) =>
    CaptureConfig(
      version: 1,
      pitchBands: bands,
      thresholds: thresholds ?? CaptureConfig.bundledDefault.thresholds,
    );

void main() {
  group('pitch bands', () {
    test('drops bands with non-positive segments', () {
      final out = sanitizeCaptureConfig(_cfg(const [
        PitchBand(id: 'a', minDegrees: 0, maxDegrees: 30, segments: 0),
        PitchBand(id: 'b', minDegrees: 30, maxDegrees: 60, segments: -4),
        PitchBand(id: 'c', minDegrees: 60, maxDegrees: 90, segments: 6),
      ]));
      expect(out.pitchBands.map((b) => b.id), ['c']);
    });

    test('drops inverted / zero-width bands', () {
      final out = sanitizeCaptureConfig(_cfg(const [
        PitchBand(id: 'inv', minDegrees: 60, maxDegrees: 30, segments: 8),
        PitchBand(id: 'zero', minDegrees: 40, maxDegrees: 40, segments: 8),
        PitchBand(id: 'ok', minDegrees: 0, maxDegrees: 45, segments: 8),
      ]));
      expect(out.pitchBands.map((b) => b.id), ['ok']);
    });

    test('clamps out-of-range degrees and segments', () {
      final out = sanitizeCaptureConfig(_cfg(const [
        PitchBand(id: 'a', minDegrees: -10, maxDegrees: 120, segments: 999),
      ]));
      final band = out.pitchBands.single;
      expect(band.minDegrees, 0);
      expect(band.maxDegrees, 90);
      expect(band.segments, 64);
    });

    test('falls back to bundled bands when nothing valid remains', () {
      final out = sanitizeCaptureConfig(_cfg(const [
        PitchBand(id: 'x', minDegrees: 90, maxDegrees: 10, segments: 0),
      ]));
      expect(out.pitchBands, CaptureConfig.bundledDefault.pitchBands);
    });
  });

  group('thresholds', () {
    test('clamps above range', () {
      final out = sanitizeCaptureConfig(_cfg(
        CaptureConfig.bundledDefault.pitchBands,
        thresholds: const CaptureThresholds(
          minSharpness: 5,
          minCoveragePct: 150,
          maxTiltDeltaDeg: 100,
        ),
      ));
      expect(out.thresholds.minSharpness, 1);
      expect(out.thresholds.minCoveragePct, 100);
      expect(out.thresholds.maxTiltDeltaDeg, 45);
    });

    test('clamps below range', () {
      final out = sanitizeCaptureConfig(_cfg(
        CaptureConfig.bundledDefault.pitchBands,
        thresholds: const CaptureThresholds(
          minSharpness: -1,
          minCoveragePct: -20,
          maxTiltDeltaDeg: 0,
        ),
      ));
      expect(out.thresholds.minSharpness, 0);
      expect(out.thresholds.minCoveragePct, 0);
      expect(out.thresholds.maxTiltDeltaDeg, 1);
    });
  });

  test('preserves an already-valid config', () {
    final out = sanitizeCaptureConfig(CaptureConfig.bundledDefault);
    expect(out.totalSegments, CaptureConfig.bundledDefault.totalSegments);
    expect(out.pitchBands.length, 3);
  });
}
