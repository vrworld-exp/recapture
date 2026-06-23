// test/capture/capture_readiness_test.dart
//
// Pure unit tests for the shutter gating model across guided/manual mode,
// sensor on/off (fail-open), each gate combination, and the block-reason
// ordering.
import 'package:flutter_test/flutter_test.dart';
import 'package:recapture/domain/entities/capture_readiness.dart';

void main() {
  group('canCapture — guided mode', () {
    test('all gates satisfied → true', () {
      const r = CaptureReadiness(
        mode: CaptureMode.guided,
        inBand: true,
        stable: true,
        placed: true,
      );
      expect(r.canCapture, isTrue);
      expect(r.primaryBlockReason, isNull);
    });

    test('any gate failing → false', () {
      expect(
        const CaptureReadiness(mode: CaptureMode.guided, inBand: false, stable: true)
            .canCapture,
        isFalse,
      );
      expect(
        const CaptureReadiness(mode: CaptureMode.guided, inBand: true, stable: false)
            .canCapture,
        isFalse,
      );
      expect(
        const CaptureReadiness(
                mode: CaptureMode.guided, inBand: true, stable: true, placed: false)
            .canCapture,
        isFalse,
      );
    });
  });

  group('fail-open / manual', () {
    test('manual mode is always allowed regardless of gates', () {
      const r = CaptureReadiness(
        mode: CaptureMode.manual,
        inBand: false,
        stable: false,
        placed: false,
      );
      expect(r.canCapture, isTrue);
      expect(r.primaryBlockReason, isNull);
    });

    test('guided + sensors unavailable → allowed (never locks out)', () {
      const r = CaptureReadiness(
        mode: CaptureMode.guided,
        inBand: false,
        stable: false,
        sensorSupported: false,
      );
      expect(r.canCapture, isTrue);
      expect(r.primaryBlockReason, isNull);
    });
  });

  group('primaryBlockReason ordering', () {
    test('placement first, then band, then stability', () {
      expect(
        const CaptureReadiness(
                mode: CaptureMode.guided,
                inBand: false,
                stable: false,
                placed: false)
            .primaryBlockReason,
        BlockReason.notPlaced,
      );
      expect(
        const CaptureReadiness(
                mode: CaptureMode.guided, inBand: false, stable: false)
            .primaryBlockReason,
        BlockReason.outOfBand,
      );
      expect(
        const CaptureReadiness(
                mode: CaptureMode.guided, inBand: true, stable: false)
            .primaryBlockReason,
        BlockReason.unstable,
      );
    });
  });

  test('value equality', () {
    expect(
      const CaptureReadiness(mode: CaptureMode.guided, inBand: true, stable: true),
      const CaptureReadiness(mode: CaptureMode.guided, inBand: true, stable: true),
    );
    expect(
      const CaptureReadiness(mode: CaptureMode.guided, inBand: true) ==
          const CaptureReadiness(mode: CaptureMode.guided, inBand: false),
      isFalse,
    );
  });
}
