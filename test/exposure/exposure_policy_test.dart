// test/exposure/exposure_policy_test.dart
//
// Verifies the Dart-side dark/ok/bright exposure policy mirrors the native
// semantics: boundary precision (40/220 → ok), validation/fallback (invalid AND
// equal → defaults), and the non-finite → unknown (never ok) guard.
import 'package:flutter_test/flutter_test.dart';
import 'package:recapture/platform/exposure_policy.dart';

void main() {
  group('ExposureThresholdPolicy.classify', () {
    test('boundary table with defaults (40/220)', () {
      const p = ExposureThresholdPolicy.defaults;
      expect(p.classify(0), ExposureBand.dark); // all-black
      expect(p.classify(39.9), ExposureBand.dark);
      expect(p.classify(40), ExposureBand.ok); // boundary → ok
      expect(p.classify(128), ExposureBand.ok);
      expect(p.classify(220), ExposureBand.ok); // boundary → ok
      expect(p.classify(220.1), ExposureBand.bright);
      expect(p.classify(255), ExposureBand.bright); // all-white
    });

    test('custom thresholds shift bands', () {
      final p = ExposureThresholdPolicy(darkBelow: 50, brightAbove: 200);
      expect(p.classify(49.9), ExposureBand.dark);
      expect(p.classify(50), ExposureBand.ok);
      expect(p.classify(200), ExposureBand.ok);
      expect(p.classify(200.1), ExposureBand.bright);
    });

    test('invalid (dark >= bright) falls back to defaults', () {
      final p = ExposureThresholdPolicy(darkBelow: 230, brightAbove: 50);
      expect(p.darkBelow, 40);
      expect(p.brightAbove, 220);
      expect(p.classify(128), ExposureBand.ok);
    });

    test('equal thresholds fall back to defaults (no OK band allowed)', () {
      final p = ExposureThresholdPolicy(darkBelow: 100, brightAbove: 100);
      expect(p.darkBelow, 40);
      expect(p.brightAbove, 220);
    });

    test('non-finite → unknown (never ok)', () {
      const p = ExposureThresholdPolicy.defaults;
      expect(p.classify(double.nan), ExposureBand.unknown);
      expect(p.classify(double.infinity), ExposureBand.unknown);
      expect(p.classify(double.negativeInfinity), ExposureBand.unknown);
    });
  });

  group('ExposureBand', () {
    test('fromWire parses known forms (incl. unknown); null otherwise', () {
      expect(ExposureBand.fromWire('dark'), ExposureBand.dark);
      expect(ExposureBand.fromWire('ok'), ExposureBand.ok);
      expect(ExposureBand.fromWire('bright'), ExposureBand.bright);
      expect(ExposureBand.fromWire('unknown'), ExposureBand.unknown);
      expect(ExposureBand.fromWire('mystery'), isNull);
      expect(ExposureBand.fromWire(null), isNull);
    });

    test('isWarning is true only for dark and bright', () {
      expect(ExposureBand.dark.isWarning, isTrue);
      expect(ExposureBand.bright.isWarning, isTrue);
      expect(ExposureBand.ok.isWarning, isFalse);
      expect(ExposureBand.unknown.isWarning, isFalse);
    });
  });
}
