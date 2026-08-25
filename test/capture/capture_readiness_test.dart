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

  group('alreadyCaptured — the gate that never fails open', () {
    test('blocks a guided shot even with every other gate satisfied', () {
      const r = CaptureReadiness(
        mode: CaptureMode.guided,
        inBand: true,
        stable: true,
        placed: true,
        alreadyCaptured: true,
      );
      expect(r.canCapture, isFalse);
      expect(r.primaryBlockReason, BlockReason.alreadyCaptured);
    });

    test('blocks despite the sensor fail-open (checked first)', () {
      // Sensors unavailable would normally allow the shot (full mode's rule);
      // a duplicate is refused regardless of what the sensors are doing.
      const r = CaptureReadiness(
        mode: CaptureMode.guided,
        sensorSupported: false,
        alreadyCaptured: true,
      );
      expect(r.canCapture, isFalse);
      expect(r.primaryBlockReason, BlockReason.alreadyCaptured);
    });

    test('blocks in MANUAL mode too (checked before the manual allowance)', () {
      const r = CaptureReadiness(
        mode: CaptureMode.manual,
        alreadyCaptured: true,
      );
      expect(r.canCapture, isFalse);
      expect(r.primaryBlockReason, BlockReason.alreadyCaptured);
    });

    test('defaults false — every pre-existing construction is unchanged', () {
      const r = CaptureReadiness(
        mode: CaptureMode.guided,
        inBand: true,
        stable: true,
      );
      expect(r.alreadyCaptured, isFalse);
      expect(r.canCapture, isTrue);
    });
  });

  group('primaryBlockReason ordering', () {
    test('placement first, then already-captured, then band, then stability',
        () {
      // Placement still outranks it: with nothing placed there is no meaningful
      // wedge to be duplicating.
      expect(
        const CaptureReadiness(
                mode: CaptureMode.guided,
                inBand: true,
                stable: true,
                placed: false,
                alreadyCaptured: true)
            .primaryBlockReason,
        BlockReason.notPlaced,
      );
      // Already-captured outranks band + stability: "turn to the next section"
      // is the action that resolves it; steadying an unusable shot is a dead end.
      expect(
        const CaptureReadiness(
                mode: CaptureMode.guided,
                inBand: false,
                stable: false,
                alreadyCaptured: true)
            .primaryBlockReason,
        BlockReason.alreadyCaptured,
      );
    });

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
    // alreadyCaptured participates in equality/hashCode like every other gate.
    expect(
      const CaptureReadiness(
              mode: CaptureMode.guided, alreadyCaptured: true) ==
          const CaptureReadiness(mode: CaptureMode.guided),
      isFalse,
    );
    expect(
      const CaptureReadiness(mode: CaptureMode.guided, alreadyCaptured: true)
          .hashCode,
      const CaptureReadiness(mode: CaptureMode.guided, alreadyCaptured: true)
          .hashCode,
    );
  });
}
