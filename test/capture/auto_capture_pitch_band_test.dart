// test/capture/auto_capture_pitch_band_test.dart
//
// QA CONTRACT (isolated to the pitch-band gate): with ALL other auto-capture
// conditions satisfied (stable, current segment unfilled, cooldown elapsed, not
// in-flight), auto-capture MUST NOT fire when device pitch is OUTSIDE Level A's
// band — and MUST fire when it is inside. Only PITCH is varied; the other three
// conditions are held true, so every fire/no-fire is attributable to `inBand`.
//
// The negative assertion (no fire out of band) is the point; the POSITIVE CONTROL
// (fires in band, all else equal) is what gives it teeth — without it, a trigger
// that never fires at all would pass a no-fire-only test. Sabotage-verified
// (see the doc block at the bottom): dropping the `inBand` term makes the
// out-of-band cases fire (negative tests fail); a never-firing trigger makes the
// positive control fail.
//
// Hermetic + deterministic: pure `shouldCapture` + the real `AutoCaptureController`
// with a fake capture (counts fires) and an injected clock. No sensors/camera/
// timers/UI. This is a TEST ONLY — it verifies the existing trigger, changes nothing.
import 'package:flutter_test/flutter_test.dart';
import 'package:recapture/application/capture/auto_capture_controller.dart';
import 'package:recapture/domain/capture/auto_capture_trigger.dart';
import 'package:recapture/domain/entities/capture_config.dart';
import 'package:recapture/platform/method_channels.dart' show CapturedFrame;

// A representative 'mid'-shaped band, [60, 120): min inclusive, max exclusive.
// Literal on purpose — these tests pin membership SEMANTICS, not the tuning
// (the bundled tuning is pinned by the per-ring acceptance tests).
const _band = PitchBand(id: 'mid', minDegrees: 60, maxDegrees: 120, segments: 10);
final _t0 = DateTime(2024, 1, 1, 12, 0, 0);

/// `shouldCapture` with EVERY other condition held satisfied — only [pitch]
/// (and the edge knobs) vary, so the result is attributable solely to the band.
bool decide(
  double pitch, {
  double hysteresis = 0,
  bool wasInBand = false,
}) =>
    shouldCapture(
      currentTilt: pitch,
      pitchBand: _band,
      isStable: true, // held true
      isCurrentFilled: false, // held true (unfilled)
      lastCaptureAt: null, // cooldown trivially satisfied
      now: _t0,
      isCapturing: false, // held true (not in-flight)
      bandHysteresisDeg: hysteresis,
      wasInBand: wasInBand,
    );

void main() {
  // ─────────────────────────── pure decision ────────────────────────────────
  group('shouldCapture isolates the band gate (all else satisfied)', () {
    test('below band.min → no fire', () {
      expect(decide(10), isFalse);
      expect(decide(20), isFalse);
      expect(decide(29.999), isFalse);
    });

    test('above band.max → no fire', () {
      expect(decide(120.001), isFalse);
      expect(decide(150), isFalse);
      expect(decide(120), isFalse);
    });

    test('inside band → fires (POSITIVE CONTROL: all else true)', () {
      expect(decide(90), isTrue);
      expect(decide(61), isTrue);
      expect(decide(119), isTrue);
    });

    test('band edges: min inclusive, max exclusive', () {
      expect(decide(60), isTrue, reason: 'min inclusive');
      expect(decide(120), isFalse, reason: 'max exclusive');
      expect(decide(119.999), isTrue);
    });

    test('flipping ONLY pitch out↔in toggles the decision (attributable)', () {
      // Same all-else-true inputs; the single varied term decides the outcome.
      expect(decide(90), isTrue);
      expect(decide(150), isFalse, reason: 'only pitch changed');
      expect(decide(90), isTrue);
    });

    test('hysteresis: a small dither past the edge while latched does not flip '
        'out (no flicker); a real excursion does', () {
      // Strict (no hysteresis): 122 is out.
      expect(decide(122), isFalse);
      // Latched inside with a 5° dead-band: 122 holds in-band (no flicker-out)...
      expect(decide(122, hysteresis: 5, wasInBand: true), isTrue);
      // ...but a genuine excursion past the dead-band is out.
      expect(decide(126, hysteresis: 5, wasInBand: true), isFalse);
      // Entry is always strict — the dead-band only widens once already inside.
      expect(decide(122, hysteresis: 5, wasInBand: false), isFalse);
    });
  });

  // ───────────────────────── controller level ──────────────────────────────
  group('AutoCaptureController — pitch-band isolation with a fake capture', () {
    late DateTime clock;
    DateTime now() => clock;
    late int captures;
    late List<int> filled;

    setUp(() {
      clock = _t0;
      captures = 0;
      filled = [];
    });

    AutoCaptureController build({AutoCaptureConfig? config}) =>
        AutoCaptureController(
          capture: () async {
            captures++;
            return CapturedFrame(id: 'f$captures', path: '/tmp/f.jpg', timestampNs: 0);
          },
          onFilled: filled.add,
          now: now,
          config: config,
        );

    test('steady out-of-band (both sides) → ZERO fires; entering the band fires '
        '(positive control); leaving stops', () async {
      final c = build();

      // 1) A run of OUT-OF-BAND stable ticks, unfilled segment, cooldown ok —
      //    below-min and above-max. Nothing must fire.
      for (final pitch in [10.0, 30.0, 55.0, 122.0, 150.0, 179.0]) {
        clock = clock.add(const Duration(seconds: 1)); // cooldown never the blocker
        final r = await c.evaluate(
          tiltDegrees: pitch,
          band: _band,
          isStable: true,
          currentSegment: 0,
          isCurrentFilled: false,
        );
        expect(r, AutoCaptureOutcome.notFired, reason: 'out of band at $pitch');
      }
      expect(captures, 0, reason: 'band gate blocked every out-of-band tick');

      // 2) POSITIVE CONTROL — move INTO the band, all else unchanged → it fires.
      //    Proves the trigger CAN fire, so the zero above was due to the band.
      clock = clock.add(const Duration(seconds: 1));
      final inBand = await c.evaluate(
        tiltDegrees: 90,
        band: _band,
        isStable: true,
        currentSegment: 0,
        isCurrentFilled: false,
      );
      expect(inBand, AutoCaptureOutcome.filled);
      expect(captures, 1);
      expect(filled, [0]);

      // 3) Leave the band again (fresh UNFILLED segment, cooldown elapsed, stable)
      //    → the only blocker is the band → no further fires.
      for (final pitch in [150.0, 15.0]) {
        clock = clock.add(const Duration(seconds: 1));
        final r = await c.evaluate(
          tiltDegrees: pitch,
          band: _band,
          isStable: true,
          currentSegment: 1, // unfilled
          isCurrentFilled: false,
        );
        expect(r, AutoCaptureOutcome.notFired, reason: 'left the band at $pitch');
      }
      expect(captures, 1, reason: 'no extra fires after leaving the band');
    });

    test('out→in transition fires once (single-shot); in→out stops', () async {
      final c = build();

      // Out → no fire.
      expect(
        await c.evaluate(
            tiltDegrees: 10,
            band: _band,
            isStable: true,
            currentSegment: 0,
            isCurrentFilled: false),
        AutoCaptureOutcome.notFired,
      );

      // Enter band → fires once.
      expect(
        await c.evaluate(
            tiltDegrees: 90,
            band: _band,
            isStable: true,
            currentSegment: 0,
            isCurrentFilled: false),
        AutoCaptureOutcome.filled,
      );

      // Still in band but the segment is now filled → single-shot, no re-fire.
      clock = clock.add(const Duration(seconds: 1));
      expect(
        await c.evaluate(
            tiltDegrees: 90,
            band: _band,
            isStable: true,
            currentSegment: 0,
            isCurrentFilled: true),
        AutoCaptureOutcome.notFired,
      );

      // Leave the band → still nothing.
      expect(
        await c.evaluate(
            tiltDegrees: 150,
            band: _band,
            isStable: true,
            currentSegment: 1,
            isCurrentFilled: false),
        AutoCaptureOutcome.notFired,
      );
      expect(captures, 1);
    });

    test('in-band but cooldown NOT elapsed → no fire (the harness honors the '
        'other gates, so "all else true" is real)', () async {
      final c = build();

      // Fire at t0 on segment 0.
      expect(
        await c.evaluate(
            tiltDegrees: 90,
            band: _band,
            isStable: true,
            currentSegment: 0,
            isCurrentFilled: false),
        AutoCaptureOutcome.filled,
      );

      // Only 300ms later, in band, a fresh unfilled segment → cooldown blocks it.
      clock = clock.add(const Duration(milliseconds: 300));
      expect(
        await c.evaluate(
            tiltDegrees: 90,
            band: _band,
            isStable: true,
            currentSegment: 1,
            isCurrentFilled: false),
        AutoCaptureOutcome.notFired,
      );
      expect(captures, 1);
    });

    test('out-of-band AND also unstable → still no fire (band blocks regardless, '
        'not masking the other gates)', () async {
      final c = build();
      expect(
        await c.evaluate(
            tiltDegrees: 150,
            band: _band,
            isStable: false,
            currentSegment: 0,
            isCurrentFilled: false),
        AutoCaptureOutcome.notFired,
      );
      expect(
        await c.evaluate(
            tiltDegrees: 150,
            band: _band,
            isStable: true,
            currentSegment: 0,
            isCurrentFilled: false),
        AutoCaptureOutcome.notFired,
      );
      expect(captures, 0);
    });

    test('band edges through the controller: 60 fires (min incl), 120 does not '
        '(max excl)', () async {
      final atMin = build();
      expect(
        await atMin.evaluate(
            tiltDegrees: 60,
            band: _band,
            isStable: true,
            currentSegment: 0,
            isCurrentFilled: false),
        AutoCaptureOutcome.filled,
      );
      expect(captures, 1);

      captures = 0;
      filled = [];
      final atMax = build();
      expect(
        await atMax.evaluate(
            tiltDegrees: 120,
            band: _band,
            isStable: true,
            currentSegment: 0,
            isCurrentFilled: false),
        AutoCaptureOutcome.notFired,
      );
      expect(captures, 0);
    });

    test('hysteresis through the controller: a within-dead-band dither keeps '
        'firing (no flicker-out); a real excursion blocks', () async {
      final c = build(config: AutoCaptureConfig(pitchEdgeHysteresisDeg: 5));

      // Enter the band → fires, latching wasInBand=true.
      expect(
        await c.evaluate(
            tiltDegrees: 90,
            band: _band,
            isStable: true,
            currentSegment: 0,
            isCurrentFilled: false),
        AutoCaptureOutcome.filled,
      );
      expect(c.wasInBand, isTrue);

      // Dither to 122 (past max 120 but within the 5° dead-band) on a fresh segment
      // after cooldown → still treated as in band → fires (no flicker-out).
      clock = clock.add(const Duration(seconds: 1));
      expect(
        await c.evaluate(
            tiltDegrees: 122,
            band: _band,
            isStable: true,
            currentSegment: 1,
            isCurrentFilled: false),
        AutoCaptureOutcome.filled,
      );

      // A genuine excursion past the dead-band (126) → out of band → no fire.
      clock = clock.add(const Duration(seconds: 1));
      expect(
        await c.evaluate(
            tiltDegrees: 126,
            band: _band,
            isStable: true,
            currentSegment: 2,
            isCurrentFilled: false),
        AutoCaptureOutcome.notFired,
      );
      expect(captures, 2);
    });
  });

  // SABOTAGE CHECKS (run manually to prove the test has teeth — see the meta
  // instructions in the task):
  //  1. In auto_capture_trigger.dart, drop `inBand` from the conjunction
  //     (`return isStable && !isCurrentFilled && cooldownOk;`) → the steady
  //     out-of-band controller test FIRES → it fails. (inBand term guarded.)
  //  2. Make the decision never fire (`return false;`) → the POSITIVE CONTROL
  //     fails (entering the band no longer fires) → proves the no-fire results
  //     were meaningful, not a dead trigger.
  //  3. Weaken the band (`isPitchInBand(...) => true`) → out-of-band cases fire
  //     → the negative tests fail.
}
