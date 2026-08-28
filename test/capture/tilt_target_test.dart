// test/capture/tilt_target_test.dart
//
// Pure unit tests for the tilt-meter domain: TiltTarget (band derivation,
// centre, membership) and the pitch-vs-band state machine — raw [tiltStateFor]
// and the Schmitt-trigger [tiltStateWithHysteresis] (no boundary flicker on a
// noisy, edge-hovering pitch).
import 'package:flutter_test/flutter_test.dart';
import 'package:recapture/domain/entities/capture_config.dart';
import 'package:recapture/domain/entities/tilt_target.dart';

void main() {
  const mid = PitchBand(id: 'mid', minDegrees: 30, maxDegrees: 60, segments: 10);
  final target = TiltTarget.fromBand(mid);

  group('TiltTarget', () {
    test('fromBand copies bounds + id', () {
      expect(target.minDegrees, 30);
      expect(target.maxDegrees, 60);
      expect(target.bandId, 'mid');
    });

    test('center is the midpoint', () {
      expect(target.center, 45);
    });

    test('contains is min-inclusive / max-exclusive', () {
      expect(target.contains(30), isTrue);
      expect(target.contains(45), isTrue);
      expect(target.contains(60), isFalse); // exclusive upper
      expect(target.contains(29.999), isFalse);
    });

    test('NaN/Infinity is never contained', () {
      expect(target.contains(double.nan), isFalse);
      expect(target.contains(double.infinity), isFalse);
    });
  });

  group('tiltStateFor (raw)', () {
    test('inside → inBand', () {
      expect(tiltStateFor(45, target), TiltState.inBand);
    });

    test('above the band → aboveBand (aimed too far down → tilt up)', () {
      expect(tiltStateFor(70, target), TiltState.aboveBand);
      expect(tiltStateFor(60, target), TiltState.aboveBand); // max exclusive
    });

    test('below the band → belowBand (aimed too far up → tilt down)', () {
      expect(tiltStateFor(10, target), TiltState.belowBand);
      expect(tiltStateFor(29.999, target), TiltState.belowBand);
    });
  });

  group('tiltStateWithHysteresis', () {
    test('with no previous state, behaves like a solid-inside check', () {
      expect(tiltStateWithHysteresis(null, 45, target), TiltState.inBand);
      expect(tiltStateWithHysteresis(null, 10, target), TiltState.belowBand);
      expect(tiltStateWithHysteresis(null, 90, target), TiltState.aboveBand);
    });

    test('once in-band, drifting slightly past the edge stays in-band', () {
      // 61 is past the (exclusive) 60 edge, but within the 2° margin → hold.
      expect(
        tiltStateWithHysteresis(TiltState.inBand, 61, target, marginDegrees: 2),
        TiltState.inBand,
      );
      expect(
        tiltStateWithHysteresis(TiltState.inBand, 29, target, marginDegrees: 2),
        TiltState.inBand,
      );
    });

    test('once in-band, clearly past the margin flips out', () {
      expect(
        tiltStateWithHysteresis(TiltState.inBand, 63, target, marginDegrees: 2),
        TiltState.aboveBand,
      );
      expect(
        tiltStateWithHysteresis(TiltState.inBand, 27, target, marginDegrees: 2),
        TiltState.belowBand,
      );
    });

    test('while out-of-band, the margin zone does NOT re-enter (Schmitt)', () {
      // 31 is inside the raw band but within the entry margin → stays out.
      expect(
        tiltStateWithHysteresis(
            TiltState.belowBand, 31, target, marginDegrees: 2),
        TiltState.belowBand,
      );
      // 33 is solidly inside (> min+margin) → enters.
      expect(
        tiltStateWithHysteresis(
            TiltState.belowBand, 33, target, marginDegrees: 2),
        TiltState.inBand,
      );
    });

    test('edge-hovering noise does not flicker good/warning', () {
      // Sequence hovering around the 60 edge while previously in-band.
      var state = TiltState.inBand;
      for (final p in [59.5, 60.5, 59.0, 61.0, 60.2, 59.8]) {
        state = tiltStateWithHysteresis(state, p, target, marginDegrees: 2);
        expect(state, TiltState.inBand, reason: 'pitch $p should hold in-band');
      }
    });

    test('narrow band (< 2*margin) still admits its centre', () {
      const narrow = TiltTarget(minDegrees: 44, maxDegrees: 46, bandId: 'n');
      expect(
        tiltStateWithHysteresis(TiltState.belowBand, 45, narrow,
            marginDegrees: 5),
        TiltState.inBand,
      );
    });

    test('NaN/Infinity holds the previous state', () {
      expect(
        tiltStateWithHysteresis(TiltState.aboveBand, double.nan, target),
        TiltState.aboveBand,
      );
      expect(
        tiltStateWithHysteresis(null, double.infinity, target),
        TiltState.inBand, // null fallback
      );
    });
  });
}
