// test/capture/guidance_resolver_test.dart
//
// Pure truth-table tests for the instruction engine's priority resolver:
// complete > tilt > stability > direction > capture, sensor-unavailable
// fall-through, the direction threshold, and stable instruction ids.
import 'package:flutter_test/flutter_test.dart';
import 'package:recapture/application/capture/stability_provider.dart';
import 'package:recapture/domain/capture/guidance_inputs.dart';
import 'package:recapture/domain/capture/guidance_resolver.dart';
import 'package:recapture/domain/entities/capture_instruction.dart';
import 'package:recapture/domain/entities/capture_readiness.dart';
import 'package:recapture/domain/entities/direction_hint.dart';
import 'package:recapture/domain/entities/tilt_target.dart';

RingDirectionState ring({
  bool atTargetPosition = true,
  bool currentPositionCaptured = false,
  RingDirection toNext = RingDirection.clockwise,
  double angularGapDeg = 0,
  bool allCaptured = false,
}) =>
    RingDirectionState(
      atTargetPosition: atTargetPosition,
      currentPositionCaptured: currentPositionCaptured,
      toNext: toNext,
      angularGapDeg: angularGapDeg,
      allCaptured: allCaptured,
    );

GuidanceInputs inputs({
  bool sensorSupported = true,
  TiltState tilt = TiltState.inBand,
  Stability stability = Stability.stable,
  RingDirectionState? ringState,
  CaptureMode mode = CaptureMode.guided,
}) =>
    GuidanceInputs(
      sensorSupported: sensorSupported,
      tilt: tilt,
      stability: stability,
      ring: ringState ?? ring(),
      mode: mode,
    );

void main() {
  group('priority order', () {
    test('out-of-band + unstable → TILT wins (not Hold steady)', () {
      final out = resolveGuidance(inputs(
        tilt: TiltState.aboveBand,
        stability: Stability.unstable,
      ));
      expect(out.instruction.id, 'tilt');
      // aboveBand = tilt value too high = aimed too far down → tilt up.
      expect(out.instruction.message, 'Tilt up');
      expect(out.instruction.severity, InstructionSeverity.warning);
      expect(out.direction.visible, isFalse);
    });

    test('belowBand → Tilt down (aimed too far up on the 0–180 scale)', () {
      expect(resolveGuidance(inputs(tilt: TiltState.belowBand)).instruction.message,
          'Tilt down');
    });

    test('in-band + unstable → STABILITY (arrow hidden), even off-position', () {
      final out = resolveGuidance(inputs(
        stability: Stability.unstable,
        ringState: ring(atTargetPosition: false, angularGapDeg: 90),
      ));
      expect(out.instruction.id, 'stability');
      expect(out.instruction.message, 'Hold steady');
      expect(out.direction.visible, isFalse);
    });

    test('in-band + stable + off-position → DIRECTION with arrow', () {
      final out = resolveGuidance(inputs(
        ringState: ring(
            atTargetPosition: false,
            angularGapDeg: 90,
            toNext: RingDirection.counterclockwise),
      ));
      expect(out.instruction.id, 'direction');
      expect(out.instruction.message, 'Move left around the object');
      expect(out.direction.visible, isTrue);
      expect(out.direction.direction, RingDirection.counterclockwise);
      expect(out.direction.urgency, closeTo(90 / 180, 1e-9));
    });

    test('clockwise direction → Move right', () {
      final out = resolveGuidance(inputs(
        ringState: ring(
            atTargetPosition: false,
            angularGapDeg: 45,
            toNext: RingDirection.clockwise),
      ));
      expect(out.instruction.message, 'Move right around the object');
      expect(out.direction.direction, RingDirection.clockwise);
    });
  });

  group('capture branch (lowest)', () {
    test('at uncaptured position, guided → "Capturing…", arrow hidden', () {
      final out = resolveGuidance(inputs(mode: CaptureMode.guided));
      expect(out.instruction.id, 'capture');
      expect(out.instruction.message, 'Capturing…');
      expect(out.direction.visible, isFalse);
    });

    test('at uncaptured position, manual → "Tap to capture"', () {
      final out = resolveGuidance(inputs(mode: CaptureMode.manual));
      expect(out.instruction.id, 'capture');
      expect(out.instruction.message, 'Tap to capture');
    });

    test('at an already-captured position → "Move to the next position"', () {
      final out = resolveGuidance(
          inputs(ringState: ring(currentPositionCaptured: true)));
      expect(out.instruction.id, 'capture-next');
      expect(out.instruction.message, 'Move to the next position');
      expect(out.direction.visible, isFalse);
    });
  });

  group('completion (terminal)', () {
    test('allCaptured → complete, suppresses everything else', () {
      final out = resolveGuidance(inputs(
        tilt: TiltState.aboveBand, // would otherwise win
        stability: Stability.unstable,
        ringState: ring(allCaptured: true, atTargetPosition: false, angularGapDeg: 90),
      ));
      expect(out.instruction.id, 'complete');
      expect(out.instruction.message, 'All angles captured');
      expect(out.direction.visible, isFalse);
    });
  });

  group('direction threshold', () {
    test('gap below threshold while off-target → falls through to capture (no arrow)',
        () {
      final out = resolveGuidance(inputs(
        ringState: ring(atTargetPosition: false, angularGapDeg: kDirectionThresholdDeg - 1),
      ));
      expect(out.instruction.id, 'capture');
      expect(out.direction.visible, isFalse);
    });

    test('gap above threshold → direction', () {
      final out = resolveGuidance(inputs(
        ringState: ring(atTargetPosition: false, angularGapDeg: kDirectionThresholdDeg + 1),
      ));
      expect(out.instruction.id, 'direction');
    });

    test('urgency clamps to [0,1] for large gaps', () {
      final out = resolveGuidance(inputs(
        ringState: ring(atTargetPosition: false, angularGapDeg: 300),
      ));
      expect(out.direction.urgency, 1.0);
    });
  });

  group('sensor-unavailable fall-through', () {
    test('tilt/stability skipped → never stranded on tilt; reaches direction', () {
      final out = resolveGuidance(inputs(
        sensorSupported: false,
        tilt: TiltState.aboveBand, // would win if sensors trusted
        stability: Stability.unstable,
        ringState: ring(atTargetPosition: false, angularGapDeg: 90),
      ));
      expect(out.instruction.id, 'direction'); // not 'tilt'/'stability'
    });

    test('sensors off + at position → capture branch, not tilt', () {
      final out = resolveGuidance(inputs(
        sensorSupported: false,
        tilt: TiltState.belowBand,
        stability: Stability.unstable,
        mode: CaptureMode.manual,
      ));
      expect(out.instruction.id, 'capture');
      expect(out.instruction.message, 'Tap to capture');
    });
  });

  group('stable ids', () {
    test('same logical state across ticks yields the same id and equal output', () {
      final a = resolveGuidance(inputs(tilt: TiltState.aboveBand));
      final b = resolveGuidance(inputs(tilt: TiltState.aboveBand));
      expect(a.instruction.id, b.instruction.id);
      expect(a, equals(b));
    });

    test('tilt up vs down share the id "tilt" (no re-animate) but differ in text',
        () {
      final up = resolveGuidance(inputs(tilt: TiltState.belowBand));
      final down = resolveGuidance(inputs(tilt: TiltState.aboveBand));
      expect(up.instruction.id, 'tilt');
      expect(down.instruction.id, 'tilt');
      expect(up.instruction.message, isNot(down.instruction.message));
    });
  });
}
