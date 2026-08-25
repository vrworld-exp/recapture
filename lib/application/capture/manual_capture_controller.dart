// lib/application/capture/manual_capture_controller.dart
//
// The manual capture path: the user taps to capture the CURRENT segment, the
// frame runs the blur + exposure quality checks, and the worst-of verdict
// (shared with auto-capture via [evaluateCaptureQuality]) drives what happens:
//
//   ACCEPT → fill the current segment (recordCapture), confirm.
//   WARN   → ASK the user keep-or-retake (manual is in the loop, no silent
//            default): keep → fill (optionally flagged warn); retake → discard.
//   REJECT → do not fill; discard; prompt a retake (too blurry).
//
// Manual capture deliberately BYPASSES the pitch-band / stability / cooldown
// gates that auto-capture enforces — the user tapped on purpose, so QUALITY is
// the only safeguard. It shares the one [CaptureLock] with the auto-capture
// controller, so a tap and an auto fire (or a rapid double tap) can never run
// overlapping captures; an unavailable quality result FAILS SAFE (never a silent
// accept). Discarded/rejected frames are never counted; on-disk cleanup is an
// injected seam (single-frame deletion isn't exposed by the storage client yet).
//
// The DECISION is pure ([evaluateCaptureQuality]); this is the thin async
// orchestration around it.
import 'dart:async';

import '../../domain/entities/capture_evaluation.dart';
import '../../platform/method_channels.dart' show CapturedFrame;
import 'capture_lock.dart';
import 'capture_quality_decision.dart';

/// Fires a single native capture for the current segment. Null = no capture
/// happened (no bound session / native error / test host) → surfaced as
/// [ManualCaptureOutcome.error], never a fill.
typedef SingleCaptureFn = Future<CapturedFrame?> Function();

/// Runs blur + exposure on the frame and returns the two bands, or null when the
/// scores are unavailable (analysis error / no sidecar) → FAIL SAFE (not
/// accepted).
typedef AssessQualityFn = Future<CaptureQuality?> Function(CapturedFrame frame);

/// Fills the given segment (the SegmentCoverage `recordCapture`).
typedef SegmentFillFn = void Function(int segmentIndex);

/// Asks the user to keep (true) or retake (false) a WARN frame, given its
/// verdict/quality for the message copy.
typedef KeepOrRetakeFn = Future<bool> Function(CaptureQuality quality);

/// Discards a frame that does not count (REJECT or retake): the seam for on-disk
/// cleanup. Optional — when absent the frame is left on disk (no single-frame
/// delete exists in the storage client yet); it is never counted regardless.
typedef DiscardFrameFn = Future<void> Function(CapturedFrame frame);

/// The result of one [capture] call.
enum ManualCaptureOutcome {
  /// A capture was already in flight (auto or a previous tap) → tap ignored.
  ignored,

  /// The native capture returned nothing (error / no session) → no fill.
  error,

  /// ACCEPT → segment filled.
  accepted,

  /// WARN and the user chose to keep → segment filled.
  warnKept,

  /// WARN and the user chose to retake → discarded, not counted.
  warnRetaken,

  /// REJECT → discarded, not counted, retake prompted.
  rejected,
}

extension ManualCaptureOutcomeX on ManualCaptureOutcome {
  /// Whether this outcome filled the segment (counts toward coverage).
  bool get filled =>
      this == ManualCaptureOutcome.accepted ||
      this == ManualCaptureOutcome.warnKept;
}

class ManualCaptureController {
  ManualCaptureController({
    required SingleCaptureFn capture,
    required AssessQualityFn assessQuality,
    required SegmentFillFn onFilled,
    required KeepOrRetakeFn promptKeepOrRetake,
    DiscardFrameFn? discardFrame,
    CaptureLock? lock,
    this.flagKeptWarn = false,
  })  : _capture = capture,
        _assessQuality = assessQuality,
        _onFilled = onFilled,
        _promptKeepOrRetake = promptKeepOrRetake,
        _discardFrame = discardFrame,
        _lock = lock ?? CaptureLock();

  final SingleCaptureFn _capture;
  final AssessQualityFn _assessQuality;
  final SegmentFillFn _onFilled;
  final KeepOrRetakeFn _promptKeepOrRetake;
  final DiscardFrameFn? _discardFrame;
  final CaptureLock _lock;

  /// Whether a kept-WARN frame should be recorded with a warn flag (for later
  /// analytics/quality review). Reserved for the fill seam; default false.
  final bool flagKeptWarn;

  /// True while this (or any lock-sharing) capture is in flight.
  bool get isCapturing => _lock.isBusy;

  /// The last frame captured, regardless of decision — exposed for the UI to
  /// preview/confirm. Cleared at the start of each tap.
  CapturedFrame? get lastFrame => _lastFrame;
  CapturedFrame? _lastFrame;

  /// The verdict of the last completed capture, or null if none / errored.
  CaptureVerdict? get lastVerdict => _lastVerdict;
  CaptureVerdict? _lastVerdict;

  /// Handles a capture tap on [currentSegment]. Snapshots the segment up front so
  /// a mid-capture position change cannot misattribute the fill. Single-shot via
  /// the shared in-flight guard: a tap while a capture (manual or auto) is in
  /// flight returns [ManualCaptureOutcome.ignored] — this also debounces rapid
  /// double taps. Holds the lock through the WARN prompt so no second capture can
  /// clobber the pending frame while the user decides.
  Future<ManualCaptureOutcome> capture(int currentSegment) async {
    if (!_lock.tryAcquire()) return ManualCaptureOutcome.ignored;
    _lastFrame = null;
    _lastVerdict = null;
    try {
      final frame = await _capture();
      if (frame == null) return ManualCaptureOutcome.error;
      _lastFrame = frame;

      // Fail safe: unavailable quality is NEVER a silent accept — treat as a
      // REJECT (discard, not counted, retake) so a bad/missing analysis can't
      // sneak an unverified frame into coverage.
      final quality = await _assessQuality(frame);
      final verdict = quality?.verdict ?? CaptureVerdict.reject;
      _lastVerdict = verdict;

      switch (verdict) {
        case CaptureVerdict.accepted:
          _onFilled(currentSegment);
          return ManualCaptureOutcome.accepted;
        case CaptureVerdict.warn:
          final keep = await _promptKeepOrRetake(quality!);
          if (keep) {
            _onFilled(currentSegment);
            return ManualCaptureOutcome.warnKept;
          }
          await _discard(frame);
          return ManualCaptureOutcome.warnRetaken;
        case CaptureVerdict.reject:
          await _discard(frame);
          return ManualCaptureOutcome.rejected;
      }
    } finally {
      _lock.release();
    }
  }

  Future<void> _discard(CapturedFrame frame) async {
    final discard = _discardFrame;
    if (discard != null) await discard(frame);
  }
}
