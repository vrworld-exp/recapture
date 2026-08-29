// test/capture/capture_readiness_web_regression_test.dart
//
// The two rules most likely to be "fixed" by mistake while making capture work
// in a browser, asserted on WEB-SHAPED inputs — i.e. the state a browser with no
// usable motion sensor actually produces (`sensorSupported: false`, `inBand`
// and `stable` both false, because nothing ever set them).
//
//   1. `full` must still FAIL OPEN. A browser that cannot read tilt must not
//      lock the user out of Full Capture; the parent surfaces the existing
//      "guidance unavailable" note instead.
//
//   2. `meshy` must still HARD-GATE. A Maya shot outside the eye→top window is
//      worthless to the model, so the fail-open is disabled by design. A
//      sensor-less browser therefore cannot take a Maya shot — that is the
//      intended behaviour, and the honest fix is to give web a real tilt source
//      (which the orientation port does), never to relax this.
//
// Both are stated as explicit tests so that "the Maya shutter is stuck on web"
// is answered by a red test rather than by weakening the gate.
import 'package:flutter_test/flutter_test.dart';
import 'package:recapture/domain/capture/capture_mode.dart' as modes;
import 'package:recapture/domain/entities/capture_readiness.dart';

/// Readiness exactly as the capture screen composes it on a browser whose
/// motion sensors are absent or denied.
CaptureReadiness _sensorlessWebReadiness({
  required modes.CaptureMode mode,
  bool alreadyCaptured = false,
}) =>
    CaptureReadiness(
      mode: CaptureMode.guided,
      inBand: false,
      stable: false,
      sensorSupported: false,
      hardGate: mode.usesHardTiltGate,
      alreadyCaptured: alreadyCaptured,
    );

void main() {
  group('full mode fails open on a sensor-less browser', () {
    test('capture is ALLOWED with sensorSupported: false', () {
      final readiness = _sensorlessWebReadiness(mode: modes.CaptureMode.full);
      expect(readiness.hardGate, isFalse);
      expect(readiness.canCapture, isTrue);
      expect(readiness.primaryBlockReason, isNull);
    });

    test('still allowed even with both gates reading false', () {
      // The browser never emitted a tilt or a stability sample, so these are
      // false because they are UNKNOWN, not because they are violated.
      const readiness = CaptureReadiness(
        mode: CaptureMode.guided,
        inBand: false,
        stable: false,
        sensorSupported: false,
      );
      expect(readiness.canCapture, isTrue);
    });

    test('the fail-open covers placement too, and deliberately so', () {
      // Placement is derived from the same sensor feed the band is, so with no
      // sensors it is unknown rather than violated — blocking on it would lock
      // the user out for a condition nothing can report. Pinned here because it
      // is surprising enough to be "fixed" by mistake.
      const readiness = CaptureReadiness(
        mode: CaptureMode.guided,
        placed: false,
        sensorSupported: false,
      );
      expect(readiness.canCapture, isTrue);
    });

    test('placement DOES gate once sensors are usable', () {
      const readiness = CaptureReadiness(
        mode: CaptureMode.guided,
        inBand: true,
        stable: true,
        placed: false,
        sensorSupported: true,
      );
      expect(readiness.canCapture, isFalse);
      expect(readiness.primaryBlockReason, BlockReason.notPlaced);
    });
  });

  group('meshy mode hard-gates on a sensor-less browser', () {
    test('capture is BLOCKED with sensorSupported: false', () {
      final readiness = _sensorlessWebReadiness(mode: modes.CaptureMode.meshy);
      expect(readiness.hardGate, isTrue);
      expect(readiness.canCapture, isFalse);
      expect(readiness.primaryBlockReason, BlockReason.outOfBand);
    });

    test('granting motion unblocks it — the fix is a real tilt source', () {
      // What the web orientation port delivers once DeviceOrientationEvent is
      // granted: a real in-band tilt and a real stable reading.
      const readiness = CaptureReadiness(
        mode: CaptureMode.guided,
        inBand: true,
        stable: true,
        sensorSupported: true,
        hardGate: true,
      );
      expect(readiness.canCapture, isTrue);
    });

    test('in band but unsteady is still blocked, on stability', () {
      const readiness = CaptureReadiness(
        mode: CaptureMode.guided,
        inBand: true,
        stable: false,
        sensorSupported: true,
        hardGate: true,
      );
      expect(readiness.canCapture, isFalse);
      expect(readiness.primaryBlockReason, BlockReason.unstable);
    });

    test('one-shot-per-wedge outranks everything, sensors or not', () {
      final readiness = _sensorlessWebReadiness(
        mode: modes.CaptureMode.meshy,
        alreadyCaptured: true,
      );
      expect(readiness.canCapture, isFalse);
      expect(readiness.primaryBlockReason, BlockReason.alreadyCaptured);
    });
  });

  group('the mode flags the web branch reads are unchanged', () {
    test('only meshy hard-gates', () {
      expect(modes.CaptureMode.meshy.usesHardTiltGate, isTrue);
      expect(modes.CaptureMode.full.usesHardTiltGate, isFalse);
    });

    test('only meshy is one-shot-per-segment', () {
      expect(modes.CaptureMode.meshy.oneShotPerSegment, isTrue);
      expect(modes.CaptureMode.full.oneShotPerSegment, isFalse);
    });
  });
}
