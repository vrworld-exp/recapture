// lib/domain/capture/auto_capture_trigger.dart
//
// Pure Dart — NO Flutter/Riverpod/native imports. The auto-capture DECISION for
// Level A (Eye Ring): the conjunction that says "fire a capture now". It owns no
// stability timing, no ring math, no segment state, no native capture and no
// quality assessment — it COMPOSES booleans/values produced by those owners. The
// async side (fire → await capture → quality gate → recordCapture → cooldown) is
// the AutoCaptureController; this file is the testable heart it wraps.
//
// THE CONJUNCTION (all must hold):
//   1. inBand        — the smoothed 0–180° camera tilt is within the level's
//                      pitch band (CapturePitchGuide.isInBand: min inclusive,
//                      max exclusive, DEGREES; a [0,180] RANGE check — tilt
//                      does NOT wrap).
//   2. isStable      — the NATIVE stability gate's debounced `stable` flag (it
//                      already encodes the gyro/accel fusion + 250 ms dwell — we
//                      consume it, we do NOT re-time 250 ms here).
//   3. !isCurrentFilled — the ring engine's current segment is not yet filled
//                      (per the SegmentCoverage state).
//   4. cooldownOk    — at least `minInterval` (default 500 ms) since the LAST
//                      capture (a GLOBAL inter-capture floor, measured from the
//                      last capture, NOT from segment entry; first capture, with
//                      no prior, is always satisfied).
//   + !isCapturing   — an explicit in-flight guard (capture latency may be under
//                      or over the cooldown, so the cooldown alone is not enough).

import '../entities/capture_config.dart';
import '../entities/capture_evaluation.dart';
import '../entities/capture_pitch_guide.dart';

/// Tunable timings/policy for the trigger. Sourced (by the caller) from
/// remote-config; values are validated/clamped to sane floors so a bad remote
/// value can never disable the cooldown or invert the band.
class AutoCaptureConfig {
  AutoCaptureConfig({
    Duration minInterval = const Duration(milliseconds: 500),
    double pitchEdgeHysteresisDeg = 0,
    this.fillOnWarn = true,
  })  : minInterval =
            minInterval < Duration.zero ? Duration.zero : minInterval,
        pitchEdgeHysteresisDeg =
            pitchEdgeHysteresisDeg.isFinite && pitchEdgeHysteresisDeg > 0
                ? pitchEdgeHysteresisDeg
                : 0;

  /// Minimum time since the last capture before another may fire. Default 500 ms.
  final Duration minInterval;

  /// Optional band-edge dead-band (degrees). When > 0, a tilt already inside the
  /// band stays "in band" until it drifts more than this past an edge — absorbs
  /// residual jitter so a borderline tilt doesn't flicker the trigger. 0 = off
  /// (strict [PitchBand] membership). Given the tilt is already smoothed this is
  /// usually unnecessary; kept for tuning.
  final double pitchEdgeHysteresisDeg;

  /// Whether a WARN-band quality verdict still fills the segment. Default true
  /// (accept WARN, fill; reject only REJECT). See [verdictFills].
  final bool fillOnWarn;

  /// Whether a post-capture [verdict] should FILL the segment under this config:
  /// always for [CaptureVerdict.accepted], for [CaptureVerdict.warn] iff
  /// [fillOnWarn], never for [CaptureVerdict.reject].
  bool verdictFills(CaptureVerdict verdict) => switch (verdict) {
        CaptureVerdict.accepted => true,
        CaptureVerdict.warn => fillOnWarn,
        CaptureVerdict.reject => false,
      };
}

/// Band membership with optional edge hysteresis, over the 0–180° camera tilt.
/// With [hysteresisDeg] <= 0 this is exactly [CapturePitchGuide.isInBand] (min
/// inclusive, max exclusive). With hysteresis > 0 AND [wasInBand], the band
/// widens by [hysteresisDeg] on both edges (Schmitt) so a small dither past an
/// edge holds; entry is always strict. A NaN/Infinity tilt is never in band
/// (IEEE-754 comparisons), as in the base.
bool isPitchInBand(
  PitchBand band,
  double tiltDegrees, {
  double hysteresisDeg = 0,
  bool wasInBand = false,
}) {
  if (hysteresisDeg <= 0 || !wasInBand) {
    return CapturePitchGuide.isInBand(band, tiltDegrees);
  }
  return tiltDegrees >= band.minDegrees - hysteresisDeg &&
      tiltDegrees < band.maxDegrees + hysteresisDeg;
}

/// The pure auto-capture decision: the full conjunction (plus the in-flight
/// guard). Deterministic and side-effect-free — fully unit-testable without
/// async/UI. Returns true ONLY on the frame all conditions are first satisfied;
/// single-shot behaviour (not re-firing every frame) is enforced by the
/// controller via [isCapturing] + the cooldown + the segment becoming filled.
bool shouldCapture({
  required double currentTilt,
  required PitchBand pitchBand,
  required bool isStable,
  required bool isCurrentFilled,
  required DateTime? lastCaptureAt,
  required DateTime now,
  required bool isCapturing,
  Duration minInterval = const Duration(milliseconds: 500),
  double bandHysteresisDeg = 0,
  bool wasInBand = false,
}) {
  if (isCapturing) return false; // in-flight guard, checked first (cheap)
  final inBand = isPitchInBand(
    pitchBand,
    currentTilt,
    hysteresisDeg: bandHysteresisDeg,
    wasInBand: wasInBand,
  );
  final cooldownOk =
      lastCaptureAt == null || now.difference(lastCaptureAt) >= minInterval;
  return inBand && isStable && !isCurrentFilled && cooldownOk;
}
