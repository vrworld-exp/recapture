// test/capture/manual_capture_controller_test.dart
//
// Integration tests for the manual capture path: tap → capture → quality →
// ACCEPT/WARN(keep|retake)/REJECT, the manual bypass of pitch/stability/cooldown,
// fail-safe on unavailable quality, in-flight/double-tap guarding, and the shared
// lock with auto-capture.
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:recapture/application/capture/auto_capture_controller.dart';
import 'package:recapture/application/capture/capture_lock.dart';
import 'package:recapture/application/capture/capture_quality_decision.dart';
import 'package:recapture/application/capture/manual_capture_controller.dart';
import 'package:recapture/domain/entities/capture_config.dart';
import 'package:recapture/platform/blur_policy.dart';
import 'package:recapture/platform/exposure_policy.dart';
import 'package:recapture/platform/method_channels.dart' show CapturedFrame;

CapturedFrame frame([String id = 'f']) =>
    CapturedFrame(id: id, path: '/tmp/$id.jpg', timestampNs: 0);

const _sharp = CaptureQuality(blur: BlurBand.accept, exposure: ExposureBand.ok);
const _soft = CaptureQuality(blur: BlurBand.warn, exposure: ExposureBand.ok);
const _blurry =
    CaptureQuality(blur: BlurBand.reject, exposure: ExposureBand.ok);

/// Builds a controller with sensible fakes; override per test.
ManualCaptureController build({
  SingleCaptureFn? capture,
  AssessQualityFn? assessQuality,
  required List<int> filled,
  KeepOrRetakeFn? prompt,
  List<CapturedFrame>? discarded,
  CaptureLock? lock,
}) {
  return ManualCaptureController(
    capture: capture ?? (() async => frame()),
    assessQuality: assessQuality ?? ((_) async => _sharp),
    onFilled: filled.add,
    promptKeepOrRetake: prompt ?? ((_) async => true),
    discardFrame: discarded == null ? null : ((f) async => discarded.add(f)),
    lock: lock,
  );
}

void main() {
  group('decision → action', () {
    test('ACCEPT fills the current segment', () async {
      final filled = <int>[];
      final c = build(assessQuality: (_) async => _sharp, filled: filled);
      final r = await c.capture(4);
      expect(r, ManualCaptureOutcome.accepted);
      expect(r.filled, isTrue);
      expect(filled, [4]);
    });

    test('REJECT does not fill; discards the frame', () async {
      final filled = <int>[];
      final discarded = <CapturedFrame>[];
      final c = build(
        assessQuality: (_) async => _blurry,
        filled: filled,
        discarded: discarded,
      );
      final r = await c.capture(0);
      expect(r, ManualCaptureOutcome.rejected);
      expect(r.filled, isFalse);
      expect(filled, isEmpty);
      expect(discarded.length, 1);
    });

    test('WARN + keep → fills', () async {
      final filled = <int>[];
      final c = build(
        assessQuality: (_) async => _soft,
        filled: filled,
        prompt: (_) async => true, // keep
      );
      final r = await c.capture(2);
      expect(r, ManualCaptureOutcome.warnKept);
      expect(filled, [2]);
    });

    test('WARN + retake → not filled, discarded', () async {
      final filled = <int>[];
      final discarded = <CapturedFrame>[];
      final c = build(
        assessQuality: (_) async => _soft,
        filled: filled,
        discarded: discarded,
        prompt: (_) async => false, // retake
      );
      final r = await c.capture(2);
      expect(r, ManualCaptureOutcome.warnRetaken);
      expect(filled, isEmpty);
      expect(discarded.length, 1);
    });
  });

  group('fail-safe', () {
    test('native capture returns null → error, no fill, no prompt', () async {
      final filled = <int>[];
      var prompted = false;
      final c = build(
        capture: () async => null,
        filled: filled,
        prompt: (_) async {
          prompted = true;
          return true;
        },
      );
      final r = await c.capture(1);
      expect(r, ManualCaptureOutcome.error);
      expect(filled, isEmpty);
      expect(prompted, isFalse);
    });

    test('unavailable quality (null bands) → treated as reject, never accepts',
        () async {
      final filled = <int>[];
      final discarded = <CapturedFrame>[];
      final c = build(
        assessQuality: (_) async => null, // scores unavailable
        filled: filled,
        discarded: discarded,
      );
      final r = await c.capture(0);
      expect(r, ManualCaptureOutcome.rejected);
      expect(filled, isEmpty);
      expect(discarded.length, 1);
    });
  });

  group('manual bypass', () {
    test('captures regardless of pitch/stability/cooldown (quality decides)',
        () async {
      // The controller has NO pitch/stability/cooldown inputs at all — a tap
      // always proceeds to capture+quality. A sharp frame is accepted.
      final filled = <int>[];
      final c = build(assessQuality: (_) async => _sharp, filled: filled);
      expect((await c.capture(0)), ManualCaptureOutcome.accepted);
      // immediate second tap on a new segment — no cooldown blocks it
      expect((await c.capture(1)), ManualCaptureOutcome.accepted);
      expect(filled, [0, 1]);
    });

    test('overfill: tapping an already-filled segment fills again', () async {
      final filled = <int>[];
      final c = build(filled: filled);
      await c.capture(3);
      await c.capture(3); // deliberate recapture
      expect(filled, [3, 3]);
    });
  });

  group('in-flight / double-tap guard', () {
    test('a tap while capturing is ignored (no overlap)', () async {
      var captures = 0;
      final gate = Completer<CapturedFrame?>();
      final filled = <int>[];
      final c = build(
        capture: () {
          captures++;
          return gate.future;
        },
        filled: filled,
      );

      final first = c.capture(0); // do not await — holds the lock
      expect(c.isCapturing, isTrue);
      final second = await c.capture(0); // ignored while in flight
      expect(second, ManualCaptureOutcome.ignored);
      expect(captures, 1);

      gate.complete(frame());
      expect(await first, ManualCaptureOutcome.accepted);
      expect(c.isCapturing, isFalse);
      expect(filled, [0]);
    });

    test('lock is held through the WARN prompt (no clobber while deciding)',
        () async {
      final filled = <int>[];
      final promptGate = Completer<bool>();
      final c = build(
        assessQuality: (_) async => _soft,
        filled: filled,
        prompt: (_) async => promptGate.future,
      );
      final first = c.capture(0); // awaits the prompt, holding the lock
      // let the capture+quality microtasks run
      await Future<void>.delayed(Duration.zero);
      expect(c.isCapturing, isTrue);
      expect((await c.capture(0)), ManualCaptureOutcome.ignored);

      promptGate.complete(true); // keep
      expect(await first, ManualCaptureOutcome.warnKept);
      expect(filled, [0]);
    });
  });

  group('shared lock with auto-capture', () {
    const band =
        PitchBand(id: 'mid', minDegrees: 60, maxDegrees: 120, segments: 10);

    test('a manual capture in flight blocks an auto fire', () async {
      final lock = CaptureLock();
      final manualGate = Completer<CapturedFrame?>();
      final manualFilled = <int>[];
      final autoFilled = <int>[];
      var autoCaptures = 0;

      final manual = build(
        capture: () => manualGate.future,
        filled: manualFilled,
        lock: lock,
      );
      final auto = AutoCaptureController(
        capture: () async {
          autoCaptures++;
          return frame('a');
        },
        onFilled: autoFilled.add,
        lock: lock,
      );

      final manualFuture = manual.capture(0); // holds the shared lock
      expect(lock.isBusy, isTrue);

      // Auto tick with all conditions satisfied → blocked by the shared lock.
      final autoOutcome = await auto.evaluate(
        tiltDegrees: 90,
        band: band,
        isStable: true,
        currentSegment: 1,
        isCurrentFilled: false,
      );
      expect(autoOutcome, AutoCaptureOutcome.notFired);
      expect(autoCaptures, 0);

      manualGate.complete(frame());
      await manualFuture;
      expect(lock.isBusy, isFalse);
      expect(manualFilled, [0]);
    });
  });

  group('exposed state', () {
    test('lastFrame / lastVerdict reflect the last capture', () async {
      final c = build(assessQuality: (_) async => _soft, filled: <int>[]);
      await c.capture(0);
      expect(c.lastFrame, isNotNull);
      expect(c.lastVerdict, isNotNull);
    });
  });
}
