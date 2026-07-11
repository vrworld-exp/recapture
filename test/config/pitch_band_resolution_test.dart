// test/config/pitch_band_resolution_test.dart
//
// The PURE per-level pitch-band resolver: precedence (override → remote/cache →
// bundled default), shared validation, per-band fallback, partial payloads, and
// the diagnostic hook. No Riverpod/Flutter.
import 'package:flutter_test/flutter_test.dart';
import 'package:recapture/domain/capture/pitch_band_resolution.dart';
import 'package:recapture/domain/entities/capture_config.dart';

PitchBand _band(String id, double min, double max, {int seg = 8}) =>
    PitchBand(id: id, minDegrees: min, maxDegrees: max, segments: seg);

CaptureConfig _config(List<PitchBand> bands) =>
    CaptureConfig.bundledDefault.copyWith(pitchBands: bands);

void main() {
  group('isValidPitchBand', () {
    test('accepts a finite, ordered, in-range band', () {
      expect(isValidPitchBand(_band('low', 0, 30)), isTrue);
    });
    test('rejects min >= max', () {
      expect(isValidPitchBand(_band('x', 30, 10)), isFalse);
      expect(isValidPitchBand(_band('x', 10, 10)), isFalse);
    });
    test('rejects out-of-range and NaN/Infinity', () {
      expect(isValidPitchBand(_band('x', -5, 30)), isFalse); // below 0
      expect(isValidPitchBand(_band('x', 120, 200)), isFalse); // above 180
      expect(isValidPitchBand(_band('x', double.nan, 30)), isFalse);
      expect(isValidPitchBand(_band('x', 0, double.infinity)), isFalse);
    });

    test('accepts the full 0–180° camera-tilt scale (old ≤90 rule is gone)', () {
      expect(isValidPitchBand(_band('high', 120, 180)), isTrue);
      expect(isValidPitchBand(_band('x', 60, 100)), isTrue);
    });
  });

  group('resolvePitchBand precedence', () {
    final config = _config([
      _band('low', 0, 30),
      _band('mid', 30, 60),
      _band('high', 60, 90),
    ]);

    test('override wins over a valid remote value', () {
      final r = resolvePitchBand(
        bandId: 'low',
        config: config,
        overrides: {'low': _band('low', 5, 25)},
      );
      expect(r.minDegrees, 5);
      expect(r.maxDegrees, 25);
    });

    test('no override → remote/config value', () {
      final r = resolvePitchBand(bandId: 'high', config: config);
      expect(r.minDegrees, 60);
      expect(r.maxDegrees, 90);
    });

    test('Level C default resolves to exactly the bundled low band [0,60)', () {
      // No remote band for 'low', no override → bundled default.
      final r = resolvePitchBand(
        bandId: 'low',
        config: _config([_band('high', 120, 180)]), // partial: only high
      );
      final bundledLow = CaptureConfig.bundledDefault.pitchBands
          .firstWhere((b) => b.id == 'low');
      expect(r.minDegrees, bundledLow.minDegrees); // 0
      expect(r.maxDegrees, bundledLow.maxDegrees); // 60
    });
  });

  group('validation + fallthrough (per-band, logged)', () {
    final logs = <String>[];
    void log({
      required String bandId,
      required PitchBandSource source,
      required double? minDegrees,
      required double? maxDegrees,
      required String reason,
    }) =>
        logs.add('$bandId/${source.name}/$reason/$minDegrees-$maxDegrees');

    setUp(logs.clear);

    test('invalid override is rejected + logged, falls through to remote', () {
      final r = resolvePitchBand(
        bandId: 'low',
        config: _config([_band('low', 0, 30)]),
        overrides: {'low': _band('low', 30, 10)}, // min > max
        onReject: log,
      );
      expect(r.minDegrees, 0); // remote applied
      expect(logs.single, 'low/override/invalid_override/30.0-10.0');
    });

    test('invalid remote rejected → bundled default; other levels unaffected', () {
      // 'low' remote is invalid (min>max); 'high' remote is valid.
      final cfg = _config([_band('low', 50, 10), _band('high', 60, 90)]);
      final low = resolvePitchBand(bandId: 'low', config: cfg, onReject: log);
      final high = resolvePitchBand(bandId: 'high', config: cfg, onReject: log);

      final bundledLow = CaptureConfig.bundledDefault.pitchBands
          .firstWhere((b) => b.id == 'low');
      expect(low.maxDegrees, bundledLow.maxDegrees); // fell back to default
      expect(high.minDegrees, 60); // valid remote still applies
      expect(logs.any((l) => l.startsWith('low/remote/invalid_remote')), isTrue);
    });

    test('absent remote band logs absent + uses default', () {
      resolvePitchBand(
        bandId: 'mid',
        config: _config([_band('high', 60, 90)]),
        onReject: log,
      );
      expect(logs.single, 'mid/remote/absent_remote/null-null');
    });

    test('always returns a valid band even for an unknown band id', () {
      final r = resolvePitchBand(bandId: 'nonexistent', config: _config([]));
      expect(isValidPitchBand(r) || r == CaptureConfig.bundledDefault.pitchBands.first,
          isTrue);
      expect(r, isNotNull);
    });
  });
}
