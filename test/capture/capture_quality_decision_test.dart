// test/capture/capture_quality_decision_test.dart
//
// Pure tests for the SHARED worst-of quality decision (blur reject dominates;
// any warn → warn; else accept) over the full blur×exposure band matrix.
import 'package:flutter_test/flutter_test.dart';
import 'package:recapture/application/capture/capture_quality_decision.dart';
import 'package:recapture/domain/entities/capture_evaluation.dart';
import 'package:recapture/platform/blur_policy.dart';
import 'package:recapture/platform/exposure_policy.dart';

void main() {
  group('evaluateCaptureQuality worst-of', () {
    test('blur REJECT dominates regardless of exposure', () {
      for (final e in ExposureBand.values) {
        expect(
          evaluateCaptureQuality(BlurBand.reject, e),
          CaptureVerdict.reject,
          reason: 'reject + $e',
        );
      }
    });

    test('blur WARN → warn for every exposure', () {
      for (final e in ExposureBand.values) {
        expect(evaluateCaptureQuality(BlurBand.warn, e), CaptureVerdict.warn,
            reason: 'warn + $e');
      }
    });

    test('blur ACCEPT + exposure OK → accept', () {
      expect(
        evaluateCaptureQuality(BlurBand.accept, ExposureBand.ok),
        CaptureVerdict.accepted,
      );
    });

    test('blur ACCEPT + non-OK exposure (dark/bright/unknown) → warn', () {
      expect(evaluateCaptureQuality(BlurBand.accept, ExposureBand.dark),
          CaptureVerdict.warn);
      expect(evaluateCaptureQuality(BlurBand.accept, ExposureBand.bright),
          CaptureVerdict.warn);
      expect(evaluateCaptureQuality(BlurBand.accept, ExposureBand.unknown),
          CaptureVerdict.warn);
    });
  });

  group('CaptureQuality', () {
    test('verdict delegates to evaluateCaptureQuality', () {
      const q = CaptureQuality(blur: BlurBand.accept, exposure: ExposureBand.ok);
      expect(q.verdict, CaptureVerdict.accepted);
      const q2 =
          CaptureQuality(blur: BlurBand.reject, exposure: ExposureBand.ok);
      expect(q2.verdict, CaptureVerdict.reject);
    });

    test('value equality', () {
      const a = CaptureQuality(blur: BlurBand.warn, exposure: ExposureBand.dark);
      const b = CaptureQuality(blur: BlurBand.warn, exposure: ExposureBand.dark);
      const c = CaptureQuality(blur: BlurBand.warn, exposure: ExposureBand.ok);
      expect(a, equals(b));
      expect(a.hashCode, b.hashCode);
      expect(a, isNot(equals(c)));
    });
  });
}
