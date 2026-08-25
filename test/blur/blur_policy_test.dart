// test/blur/blur_policy_test.dart
//
// Verifies the Dart-side three-band blur policy mirrors the native semantics:
// boundary precision (40/80 → warn), validation/fallback, and fail-safe handling
// of non-finite scores.
import 'package:flutter_test/flutter_test.dart';
import 'package:recapture/platform/blur_policy.dart';

void main() {
  group('BlurThresholdPolicy.classify', () {
    test('boundary table with defaults (40/80)', () {
      const p = BlurThresholdPolicy.defaults;
      expect(p.classify(0), BlurBand.reject);
      expect(p.classify(39.9), BlurBand.reject);
      expect(p.classify(40), BlurBand.warn); // inclusive lower
      expect(p.classify(60), BlurBand.warn);
      expect(p.classify(80), BlurBand.warn); // inclusive upper
      expect(p.classify(80.1), BlurBand.accept);
      expect(p.classify(200), BlurBand.accept);
    });

    test('custom thresholds shift bands', () {
      final p = BlurThresholdPolicy(rejectBelow: 30, acceptAbove: 70);
      expect(p.classify(29), BlurBand.reject);
      expect(p.classify(30), BlurBand.warn);
      expect(p.classify(70), BlurBand.warn);
      expect(p.classify(71), BlurBand.accept);
    });

    test('invalid (reject > accept) falls back to defaults', () {
      final p = BlurThresholdPolicy(rejectBelow: 90, acceptAbove: 50);
      expect(p.rejectBelow, 40);
      expect(p.acceptAbove, 80);
      expect(p.classify(60), BlurBand.warn);
    });

    test('equal thresholds give an empty warn band', () {
      final p = BlurThresholdPolicy(rejectBelow: 50, acceptAbove: 50);
      expect(p.classify(49.9), BlurBand.reject);
      expect(p.classify(50), BlurBand.warn);
      expect(p.classify(50.1), BlurBand.accept);
    });

    test('non-finite / negative fails safe to reject (never accept)', () {
      const p = BlurThresholdPolicy.defaults;
      expect(p.classify(double.nan), BlurBand.reject);
      expect(p.classify(double.infinity), BlurBand.reject);
      expect(p.classify(double.negativeInfinity), BlurBand.reject);
      expect(p.classify(-5), BlurBand.reject);
    });
  });

  group('BlurBand.fromWire', () {
    test('parses known wire forms; null otherwise', () {
      expect(BlurBand.fromWire('reject'), BlurBand.reject);
      expect(BlurBand.fromWire('warn'), BlurBand.warn);
      expect(BlurBand.fromWire('accept'), BlurBand.accept);
      expect(BlurBand.fromWire('mystery'), isNull);
      expect(BlurBand.fromWire(null), isNull);
    });
  });
}
