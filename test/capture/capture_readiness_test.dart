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

  // The one-shot-per-segment gate (Meshy): unlike every other gate here it is a
  // HARD block — it survives manual mode AND unavailable sensors, because it is a
  // positively-known duplicate rather than a "can't tell" state, and the user
  // always has a way out (turn to an unfilled segment).
  group('alreadyCaptured', () {
    test('guided mode with every other gate satisfied → blocked', () {
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

    test('manual mode is blocked too (the one gate manual does not bypass)', () {
      const r = CaptureReadiness(
        mode: CaptureMode.manual,
        alreadyCaptured: true,
      );
      expect(r.canCapture, isFalse);
      expect(r.primaryBlockReason, BlockReason.alreadyCaptured);
    });

    test('sensors unavailable does NOT fail open past it', () {
      const r = CaptureReadiness(
        mode: CaptureMode.guided,
        inBand: false,
        stable: false,
        sensorSupported: false,
        alreadyCaptured: true,
      );
      expect(r.canCapture, isFalse);
      expect(r.primaryBlockReason, BlockReason.alreadyCaptured);
    });

    test('outranks band + stability, but placement still wins', () {
      // A finished segment: "turn to the next angle" is the only useful cue, so
      // tilt/steadiness advice must not pre-empt it.
      expect(
        const CaptureReadiness(
          mode: CaptureMode.guided,
          inBand: false,
          stable: false,
          alreadyCaptured: true,
        ).primaryBlockReason,
        BlockReason.alreadyCaptured,
      );
      expect(
        const CaptureReadiness(
          mode: CaptureMode.guided,
          placed: false,
          alreadyCaptured: true,
        ).primaryBlockReason,
        BlockReason.notPlaced,
      );
    });

    test('defaults false — every existing construction is unaffected', () {
      const r = CaptureReadiness(
        mode: CaptureMode.guided,
        inBand: true,
        stable: true,
      );
      expect(r.alreadyCaptured, isFalse);
      expect(r.canCapture, isTrue);
    });

    test('participates in == / hashCode', () {
      const filled =
          CaptureReadiness(mode: CaptureMode.manual, alreadyCaptured: true);
      const open = CaptureReadiness(mode: CaptureMode.manual);
      expect(filled == open, isFalse);
      expect(
        filled,
        const CaptureReadiness(mode: CaptureMode.manual, alreadyCaptured: true),
      );
      expect(
        filled.hashCode,
        const CaptureReadiness(mode: CaptureMode.manual, alreadyCaptured: true)
            .hashCode,
      );
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
