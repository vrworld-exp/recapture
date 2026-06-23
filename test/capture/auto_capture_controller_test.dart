// test/capture/auto_capture_controller_test.dart
//
// Integration tests for the async orchestrator around shouldCapture, with fakes
// for capture/quality/fill and an injected clock: single-shot firing, in-flight
// blocking, cooldown across segments, fill-only-on-quality-pass, and ring-complete.
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:recapture/application/capture/auto_capture_controller.dart';
import 'package:recapture/domain/capture/auto_capture_trigger.dart';
import 'package:recapture/domain/entities/capture_config.dart';
import 'package:recapture/domain/entities/capture_evaluation.dart';
import 'package:recapture/platform/method_channels.dart' show CapturedFrame;

void main() {
  const band = PitchBand(id: 'mid', minDegrees: 30, maxDegrees: 60, segments: 10);

  // Mutable clock the controller reads via the injected NowFn.
  late DateTime clock;
  DateTime now() => clock;

  CapturedFrame frame(String id) =>
      CapturedFrame(id: id, path: '/tmp/$id.jpg', timestampNs: 0);

  setUp(() => clock = DateTime(2024, 1, 1, 12, 0, 0));

  group('single-shot firing', () {
    test('fires exactly once when conditions hold and does not repeat', () async {
      var captures = 0;
      final filled = <int>[];
      final c = AutoCaptureController(
        capture: () async {
          captures++;
          return frame('f$captures');
        },
        onFilled: filled.add,
        now: now,
      );

      // Segment 0 is filled by the first fire; subsequent ticks see it filled
      // (and the cooldown) → no repeat.
      var isFilled = false;
      Future<AutoCaptureOutcome> tick() => c.evaluate(
            pitchDegrees: 45,
            band: band,
            isStable: true,
            currentSegment: 0,
            isCurrentFilled: isFilled,
          );

      final r1 = await tick();
      isFilled = filled.contains(0); // segment now filled
      final r2 = await tick();
      final r3 = await tick();

      expect(r1, AutoCaptureOutcome.filled);
      expect(r2, AutoCaptureOutcome.notFired);
      expect(r3, AutoCaptureOutcome.notFired);
      expect(captures, 1);
      expect(filled, [0]);
    });

    test('out-of-band / unstable ticks never fire', () async {
      var captures = 0;
      final c = AutoCaptureController(
        capture: () async {
          captures++;
          return frame('x');
        },
        onFilled: (_) {},
        now: now,
      );
      expect(
        await c.evaluate(
            pitchDegrees: 80,
            band: band,
            isStable: true,
            currentSegment: 0,
            isCurrentFilled: false),
        AutoCaptureOutcome.notFired,
      );
      expect(
        await c.evaluate(
            pitchDegrees: 45,
            band: band,
            isStable: false,
            currentSegment: 0,
            isCurrentFilled: false),
        AutoCaptureOutcome.notFired,
      );
      expect(captures, 0);
    });
  });

  group('in-flight guard (no double-fire)', () {
    test('a second tick while capturing is a no-op', () async {
      var captures = 0;
      final gate = Completer<CapturedFrame?>();
      final filled = <int>[];
      final c = AutoCaptureController(
        capture: () {
          captures++;
          return gate.future; // stays in-flight until completed
        },
        onFilled: filled.add,
        now: now,
      );

      // Fire #1 — do not await; the in-flight flag is set synchronously up to
      // the capture await.
      final firing = c.evaluate(
        pitchDegrees: 45,
        band: band,
        isStable: true,
        currentSegment: 0,
        isCurrentFilled: false,
      );
      expect(c.isCapturing, isTrue);

      // A tick while in-flight does nothing.
      final blocked = await c.evaluate(
        pitchDegrees: 45,
        band: band,
        isStable: true,
        currentSegment: 0,
        isCurrentFilled: false,
      );
      expect(blocked, AutoCaptureOutcome.notFired);
      expect(captures, 1);

      gate.complete(frame('f1'));
      expect(await firing, AutoCaptureOutcome.filled);
      expect(c.isCapturing, isFalse);
      expect(filled, [0]);
    });
  });

  group('quality gate: fill only on a passing frame', () {
    test('ACCEPT fills + stamps cooldown', () async {
      final filled = <int>[];
      final c = AutoCaptureController(
        capture: () async => frame('a'),
        onFilled: filled.add,
        assessQuality: (_) async => CaptureVerdict.accepted,
        now: now,
      );
      final r = await c.evaluate(
          pitchDegrees: 45,
          band: band,
          isStable: true,
          currentSegment: 2,
          isCurrentFilled: false);
      expect(r, AutoCaptureOutcome.filled);
      expect(filled, [2]);
      expect(c.lastCaptureAt, clock);
    });

    test('REJECT does not fill; retries after cooldown', () async {
      var captures = 0;
      final filled = <int>[];
      final c = AutoCaptureController(
        capture: () async {
          captures++;
          return frame('r$captures');
        },
        onFilled: filled.add,
        assessQuality: (_) async => CaptureVerdict.reject,
        now: now,
      );

      final r1 = await c.evaluate(
          pitchDegrees: 45,
          band: band,
          isStable: true,
          currentSegment: 0,
          isCurrentFilled: false);
      expect(r1, AutoCaptureOutcome.notFilled);
      expect(filled, isEmpty);
      expect(captures, 1);

      // Within cooldown → no retry.
      clock = clock.add(const Duration(milliseconds: 300));
      expect(
        await c.evaluate(
            pitchDegrees: 45,
            band: band,
            isStable: true,
            currentSegment: 0,
            isCurrentFilled: false),
        AutoCaptureOutcome.notFired,
      );
      expect(captures, 1);

      // After cooldown → retries (still unfilled).
      clock = clock.add(const Duration(milliseconds: 250)); // 550ms total
      final r2 = await c.evaluate(
          pitchDegrees: 45,
          band: band,
          isStable: true,
          currentSegment: 0,
          isCurrentFilled: false);
      expect(r2, AutoCaptureOutcome.notFilled);
      expect(captures, 2);
    });

    test('WARN fills by default; can be configured not to', () async {
      final filledA = <int>[];
      final warnFills = AutoCaptureController(
        capture: () async => frame('w'),
        onFilled: filledA.add,
        assessQuality: (_) async => CaptureVerdict.warn,
        now: now,
      );
      expect(
        await warnFills.evaluate(
            pitchDegrees: 45,
            band: band,
            isStable: true,
            currentSegment: 1,
            isCurrentFilled: false),
        AutoCaptureOutcome.filled,
      );
      expect(filledA, [1]);

      final filledB = <int>[];
      final warnDrops = AutoCaptureController(
        capture: () async => frame('w'),
        onFilled: filledB.add,
        assessQuality: (_) async => CaptureVerdict.warn,
        config: AutoCaptureConfig(fillOnWarn: false),
        now: now,
      );
      expect(
        await warnDrops.evaluate(
            pitchDegrees: 45,
            band: band,
            isStable: true,
            currentSegment: 1,
            isCurrentFilled: false),
        AutoCaptureOutcome.notFilled,
      );
      expect(filledB, isEmpty);
    });

    test('null frame (no capture) → notFilled, cooldown still stamped', () async {
      final filled = <int>[];
      final c = AutoCaptureController(
        capture: () async => null,
        onFilled: filled.add,
        now: now,
      );
      final r = await c.evaluate(
          pitchDegrees: 45,
          band: band,
          isStable: true,
          currentSegment: 0,
          isCurrentFilled: false);
      expect(r, AutoCaptureOutcome.notFilled);
      expect(filled, isEmpty);
      expect(c.lastCaptureAt, clock);
    });
  });

  group('cooldown measured from last capture, across segments', () {
    test('moving to a new unfilled segment within cooldown waits, then fires',
        () async {
      var captures = 0;
      final filled = <int>[];
      final c = AutoCaptureController(
        capture: () async {
          captures++;
          return frame('f$captures');
        },
        onFilled: filled.add,
        now: now,
      );

      // Fill segment 0 at t0.
      await c.evaluate(
          pitchDegrees: 45,
          band: band,
          isStable: true,
          currentSegment: 0,
          isCurrentFilled: false);
      expect(filled, [0]);

      // Move to segment 1 (unfilled) 300ms later → still within the 500ms floor.
      clock = clock.add(const Duration(milliseconds: 300));
      expect(
        await c.evaluate(
            pitchDegrees: 45,
            band: band,
            isStable: true,
            currentSegment: 1,
            isCurrentFilled: false),
        AutoCaptureOutcome.notFired,
      );
      expect(captures, 1);

      // 250ms more (550ms since last) → fires for segment 1.
      clock = clock.add(const Duration(milliseconds: 250));
      expect(
        await c.evaluate(
            pitchDegrees: 45,
            band: band,
            isStable: true,
            currentSegment: 1,
            isCurrentFilled: false),
        AutoCaptureOutcome.filled,
      );
      expect(filled, [0, 1]);
    });
  });

  group('ring complete', () {
    test('current segment always filled → never fires', () async {
      var captures = 0;
      final c = AutoCaptureController(
        capture: () async {
          captures++;
          return frame('x');
        },
        onFilled: (_) {},
        now: now,
      );
      for (var i = 0; i < 5; i++) {
        clock = clock.add(const Duration(seconds: 1));
        expect(
          await c.evaluate(
              pitchDegrees: 45,
              band: band,
              isStable: true,
              currentSegment: i,
              isCurrentFilled: true),
          AutoCaptureOutcome.notFired,
        );
      }
      expect(captures, 0);
    });
  });

  group('enabled gate + reset', () {
    test('disabled ticks never fire but refresh the band latch', () async {
      var captures = 0;
      final c = AutoCaptureController(
        capture: () async {
          captures++;
          return frame('x');
        },
        onFilled: (_) {},
        now: now,
      );
      final r = await c.evaluate(
        pitchDegrees: 45,
        band: band,
        isStable: true,
        currentSegment: 0,
        isCurrentFilled: false,
        enabled: false,
      );
      expect(r, AutoCaptureOutcome.notFired);
      expect(captures, 0);
      expect(c.wasInBand, isTrue); // latch still tracked
    });

    test('reset clears cooldown/in-flight/latch', () async {
      final c = AutoCaptureController(
        capture: () async => frame('x'),
        onFilled: (_) {},
        now: now,
      );
      await c.evaluate(
          pitchDegrees: 45,
          band: band,
          isStable: true,
          currentSegment: 0,
          isCurrentFilled: false);
      expect(c.lastCaptureAt, isNotNull);
      c.reset();
      expect(c.lastCaptureAt, isNull);
      expect(c.isCapturing, isFalse);
      expect(c.wasInBand, isFalse);
    });
  });
}
