// lib/application/capture/auto_capture_controller.dart
//
// The thin async orchestrator around the pure [shouldCapture] decision. It holds
// the only mutable trigger state — `lastCaptureAt`, `isCapturing`, and the
// `wasInBand` latch for edge hysteresis — and turns a "fire now" decision into
// the side-effect chain: fire → await the native capture → run the quality gate
// → fill the segment ONLY on a quality-passing frame → update the cooldown and
// clear the in-flight flag.
//
// Everything external is INJECTED (capture, quality assessment, fill, clock) so
// the controller is unit-testable with fakes and owns none of the composed
// concerns. The decision itself stays in auto_capture_trigger.dart.
//
// SINGLE-SHOT: a fire sets `isCapturing`, which makes [shouldCapture] return
// false for every subsequent evaluation until the capture completes; completion
// then stamps `lastCaptureAt`, so the cooldown (and, on success, the segment
// becoming filled) prevents an immediate re-fire. The `_firing` guard also
// rejects re-entrancy inside a single async fire.
import 'dart:async';

import '../../domain/capture/auto_capture_trigger.dart';
import '../../domain/entities/capture_config.dart';
import '../../domain/entities/capture_evaluation.dart';
import '../../platform/method_channels.dart' show CapturedFrame;
import 'capture_lock.dart';

/// Performs the native capture for the current segment. Returns the captured
/// frame, or null when no capture happened (no bound session / busy / test host)
/// — a null is treated as a completed-but-empty attempt (cooldown still stamped,
/// nothing filled).
typedef CaptureFn = Future<CapturedFrame?> Function();

/// Assesses a captured frame's quality (blur/exposure). Defaults to "accepted"
/// when omitted (no gate wired yet). REJECT → segment not filled (retry after
/// cooldown); WARN fills per [AutoCaptureConfig.fillOnWarn].
typedef QualityFn = Future<CaptureVerdict> Function(CapturedFrame frame);

/// Fills the segment captured (snapshot-ed at fire time, NOT after the await, so
/// a mid-capture segment change can't misattribute the fill).
typedef FillFn = void Function(int segmentIndex);

/// Injectable clock for deterministic cooldown tests.
typedef NowFn = DateTime Function();

/// The outcome of one [evaluate] call — useful for tests, HUD arming, and
/// analytics.
enum AutoCaptureOutcome {
  /// Conditions not met (or in-flight) — nothing fired.
  notFired,

  /// Fired and the frame passed quality → segment filled.
  filled,

  /// Fired but the frame was REJECTED / null → not filled, retry after cooldown.
  notFilled,
}

class AutoCaptureController {
  AutoCaptureController({
    required CaptureFn capture,
    required FillFn onFilled,
    QualityFn? assessQuality,
    AutoCaptureConfig? config,
    NowFn now = DateTime.now,
    CaptureLock? lock,
  })  : _capture = capture,
        _onFilled = onFilled,
        _assessQuality = assessQuality,
        config = config ?? AutoCaptureConfig(),
        _now = now,
        _lock = lock ?? CaptureLock();

  final CaptureFn _capture;
  final FillFn _onFilled;
  final QualityFn? _assessQuality;
  final NowFn _now;

  /// Shared in-flight guard. Inject the SAME [CaptureLock] into the manual
  /// capture controller so a manual tap and an auto fire can never overlap.
  final CaptureLock _lock;

  final AutoCaptureConfig config;

  DateTime? _lastCaptureAt;
  bool _wasInBand = false;

  /// True while a fire is in flight (capture awaited / quality running). Shared
  /// with any other capture path holding the same lock.
  bool get isCapturing => _lock.isBusy;

  /// When the last capture completed (success, reject, or empty), or null if none
  /// has fired yet.
  DateTime? get lastCaptureAt => _lastCaptureAt;

  /// Whether the pitch was in band on the last [evaluate] (the hysteresis latch).
  bool get wasInBand => _wasInBand;

  /// Evaluates the conjunction for the current frame and, if it holds, fires a
  /// single capture. Returns the [AutoCaptureOutcome]. Safe to call every
  /// orientation/state tick: it self-limits to single-shot via the in-flight
  /// guard, the cooldown, and the segment-filled condition.
  ///
  /// [enabled] lets the caller gate the whole loop (auto-capture OFF, help sheet
  /// open, screen backgrounded) without tearing down state — a disabled tick is
  /// a no-op that still refreshes the [wasInBand] latch.
  Future<AutoCaptureOutcome> evaluate({
    required double pitchDegrees,
    required PitchBand band,
    required bool isStable,
    required int currentSegment,
    required bool isCurrentFilled,
    bool enabled = true,
  }) async {
    // Refresh the hysteresis latch every tick from the strict-or-widened result,
    // so it reflects the band the user is actually in regardless of firing.
    final inBand = isPitchInBand(
      band,
      pitchDegrees,
      hysteresisDeg: config.pitchEdgeHysteresisDeg,
      wasInBand: _wasInBand,
    );

    if (!enabled || _lock.isBusy) {
      _wasInBand = inBand;
      return AutoCaptureOutcome.notFired;
    }

    final fire = shouldCapture(
      currentPitch: pitchDegrees,
      pitchBand: band,
      isStable: isStable,
      isCurrentFilled: isCurrentFilled,
      lastCaptureAt: _lastCaptureAt,
      now: _now(),
      isCapturing: _lock.isBusy,
      minInterval: config.minInterval,
      bandHysteresisDeg: config.pitchEdgeHysteresisDeg,
      wasInBand: _wasInBand,
    );
    _wasInBand = inBand;

    if (!fire) return AutoCaptureOutcome.notFired;
    return _fire(currentSegment);
  }

  Future<AutoCaptureOutcome> _fire(int segmentIndex) async {
    // Acquire the shared lock; if a manual capture grabbed it first, stand down.
    if (!_lock.tryAcquire()) return AutoCaptureOutcome.notFired;
    var filled = false;
    try {
      final frame = await _capture();
      if (frame != null) {
        final verdict =
            await (_assessQuality?.call(frame) ?? Future.value(CaptureVerdict.accepted));
        if (config.verdictFills(verdict)) {
          _onFilled(segmentIndex);
          filled = true;
        }
      }
    } finally {
      // Cooldown is stamped on ANY completion (success, reject, or empty) so a
      // rejected/empty attempt waits out minInterval before retrying — never a
      // tight retry loop.
      _lastCaptureAt = _now();
      _lock.release();
    }
    return filled ? AutoCaptureOutcome.filled : AutoCaptureOutcome.notFilled;
  }

  /// Clears cooldown/in-flight/latch for a fresh run (e.g. level restart). Does
  /// not touch the injected collaborators.
  void reset() {
    _lastCaptureAt = null;
    _lock.release();
    _wasInBand = false;
  }
}
