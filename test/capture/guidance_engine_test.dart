// test/capture/guidance_engine_test.dart
//
// Tests the dwell wrapper (anti-thrash on lower-priority id changes; warnings/
// complete preempt; same-id content commits immediately) and the engine's
// throttled analytics on committed-id changes. Deterministic via an injected clock.
import 'package:flutter_test/flutter_test.dart';
import 'package:recapture/application/capture/guidance_engine.dart';
import 'package:recapture/application/capture/stability_provider.dart';
import 'package:recapture/domain/capture/guidance_inputs.dart';
import 'package:recapture/domain/entities/capture_readiness.dart';
import 'package:recapture/domain/entities/direction_hint.dart';
import 'package:recapture/domain/entities/tilt_target.dart';
import 'package:recapture/utils/analytics.dart';

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
  late DateTime clock;
  DateTime now() => clock;

  setUp(() => clock = DateTime(2024, 1, 1, 12, 0, 0));

  group('GuidanceDwell', () {
    test('first tick commits immediately', () {
      final d = GuidanceDwell(now: now);
      final out = d.tick(inputs(tilt: TiltState.aboveBand));
      expect(out.instruction.id, 'tilt');
    });

    test('warning preempts a lower-priority committed instruction immediately', () {
      final d = GuidanceDwell(now: now)..tick(inputs(mode: CaptureMode.manual));
      // capture committed; now tilt appears → preempts without waiting the dwell
      final out = d.tick(inputs(tilt: TiltState.aboveBand, mode: CaptureMode.manual));
      expect(out.instruction.id, 'tilt');
    });

    test('lower-priority change waits out the dwell before committing', () {
      final d = GuidanceDwell(
          minDwell: const Duration(milliseconds: 300), now: now);
      // commit 'capture-next'
      d.tick(inputs(ringState: ring(currentPositionCaptured: true)));
      // candidate switches to 'capture' (lower-priority id change)
      final held = d.tick(inputs());
      expect(held.instruction.id, 'capture-next', reason: 'held during dwell');

      clock = clock.add(const Duration(milliseconds: 150));
      expect(d.tick(inputs()).instruction.id, 'capture-next');

      clock = clock.add(const Duration(milliseconds: 200)); // 350ms total
      expect(d.tick(inputs()).instruction.id, 'capture');
    });

    test('oscillation near a boundary does not flicker (holds previous)', () {
      final d = GuidanceDwell(
          minDwell: const Duration(milliseconds: 300), now: now);
      d.tick(inputs(ringState: ring(currentPositionCaptured: true))); // capture-next
      // oscillate capture <-> capture-next every 50ms; never persists 300ms
      for (var i = 0; i < 6; i++) {
        clock = clock.add(const Duration(milliseconds: 50));
        final usePrev = i.isEven;
        final out = d.tick(usePrev
            ? inputs()
            : inputs(ringState: ring(currentPositionCaptured: true)));
        expect(out.instruction.id, 'capture-next', reason: 'no flicker at tick $i');
      }
    });

    test('same-id content change commits immediately (no dwell, no thrash)', () {
      final d = GuidanceDwell(now: now);
      expect(d.tick(inputs(tilt: TiltState.belowBand)).instruction.message,
          'Tilt up');
      // same id 'tilt', different text → immediate
      expect(d.tick(inputs(tilt: TiltState.aboveBand)).instruction.message,
          'Tilt down');
    });

    test('complete preempts immediately', () {
      final d = GuidanceDwell(now: now)..tick(inputs(mode: CaptureMode.manual));
      expect(d.tick(inputs(ringState: ring(allCaptured: true))).instruction.id,
          'complete');
    });
  });

  group('GuidanceEngine analytics', () {
    final events = <Map<String, Object?>>[];

    setUp(() {
      events.clear();
      Analytics.testSink = (name, props) {
        if (name == AnalyticsEvents.guidanceInstructionChanged) {
          events.add({'name': name, ...props});
        }
      };
    });
    tearDown(() => Analytics.testSink = null);

    test('emits only on committed id change, not per tick', () {
      final e = GuidanceEngine(now: now);
      e.tick(inputs(tilt: TiltState.aboveBand), deviceType: 'android'); // tilt → emit
      e.tick(inputs(tilt: TiltState.aboveBand), deviceType: 'android'); // same id → no emit
      e.tick(inputs(tilt: TiltState.belowBand), deviceType: 'android'); // same id 'tilt' → no emit
      // tilt → capture is a lower-priority id change: it must persist past the
      // dwell before committing (and thus emitting). Advance the clock so it does.
      e.tick(inputs(mode: CaptureMode.manual), deviceType: 'android'); // pending 'capture' (dwelling)
      clock = clock.add(const Duration(milliseconds: 350));
      e.tick(inputs(mode: CaptureMode.manual), deviceType: 'android'); // capture → emit

      expect(events.length, 2);
      expect(events.first['instruction'], 'tilt');
      expect(events.first['sensor_supported'], true);
      expect(events.first['device_type'], 'android');
      expect(events.last['instruction'], 'capture');
    });

    test('sensor_supported reflects the inputs', () {
      final e = GuidanceEngine(now: now);
      e.tick(inputs(sensorSupported: false, mode: CaptureMode.manual),
          deviceType: 'ios');
      expect(events.single['instruction'], 'capture');
      expect(events.single['sensor_supported'], false);
      expect(events.single['device_type'], 'ios');
    });
  });
}
