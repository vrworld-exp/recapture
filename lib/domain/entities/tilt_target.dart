// lib/domain/entities/tilt_target.dart
//
// Pure Dart — NO Flutter/Riverpod imports. The target pitch zone for the tilt
// meter and the pitch-vs-band state machine that drives the "tilt up / tilt
// down / hold steady" guidance.
//
// The target is derived from a server-tunable [PitchBand] (see
// [TiltTarget.fromBand]); it is NEVER hardcoded at the call site. Membership
// follows the SAME convention the rest of the capture pipeline uses for pitch
// bands — `minDegrees` inclusive, `maxDegrees` exclusive — so the needle and the
// highlighted band zone share one coordinate frame: the smoothed CAMERA TILT in
// degrees on the 0–180° scale (`SmoothedOrientation.cameraTiltDegrees`, 0 =
// camera at the sky, 90 = horizon, 180 = at the ground). See [CapturePitchGuide].
import 'capture_config.dart';

/// Where the current camera tilt sits relative to the target band.
///
/// On the 0–180° camera-tilt scale (0 = camera at the sky, 180 = at the
/// ground), [aboveBand] means the tilt value is higher than the band — the
/// camera is aimed too far DOWN → the user should *tilt up*. [belowBand] is
/// the mirror (aimed too far up) → *tilt down*.
enum TiltState { inBand, aboveBand, belowBand }

/// The target pitch zone for a capture level, in degrees, with the originating
/// band id retained for analytics. Built from a config [PitchBand] so retuning
/// the band server-side moves the meter zone with no app change.
class TiltTarget {
  const TiltTarget({
    required this.minDegrees,
    required this.maxDegrees,
    required this.bandId,
  });

  /// Inclusive lower bound (mirrors [PitchBand.minDegrees]).
  final double minDegrees;

  /// Exclusive upper bound (mirrors [PitchBand.maxDegrees]).
  final double maxDegrees;

  /// The source band id (e.g. "mid") — carried for the analytics payload.
  final String bandId;

  /// Mid-point of the band; the gauge centres the "ideal" hold here.
  double get center => (minDegrees + maxDegrees) / 2;

  factory TiltTarget.fromBand(PitchBand band) => TiltTarget(
        minDegrees: band.minDegrees,
        maxDegrees: band.maxDegrees,
        bandId: band.id,
      );

  /// True iff `minDegrees <= pitch < maxDegrees` — the canonical [PitchBand]
  /// contract. A `NaN`/`Infinity` pitch yields `false` by IEEE-754 semantics.
  bool contains(double pitch) => pitch >= minDegrees && pitch < maxDegrees;
}

/// A display gauge range (degrees) that frames [target] with head/foot room for
/// the out-of-band "tilt up / tilt down" excursions, scaled to the band's own
/// span. This is what makes the indicator *tuned* per band and *adaptive*: the
/// zone re-centres and re-scales to whatever band the level configures — Eye Ring
/// ('mid' [60,120) → [0,180]), Top Ring ('high' [120,180) → [60,240]), Bottom
/// Ring ('low' [0,60) → [-60,120]) — with no hardcoded bounds (the needle
/// clamps to the gauge ends).
///
/// The margin is ~one band span on each side (so an out-of-band excursion is
/// always visible), floored at [minMargin] so a very narrow band still gets
/// legible headroom. Returns `min < max`.
({double min, double max}) tiltGaugeRangeForBand(
  TiltTarget target, {
  double minMargin = 15,
}) {
  final span = (target.maxDegrees - target.minDegrees).abs();
  final margin = span < minMargin ? minMargin : span;
  return (min: target.minDegrees - margin, max: target.maxDegrees + margin);
}

/// The raw (no-hysteresis) tilt state for [pitch] against [target]. Used where a
/// stateless decision is wanted; the meter itself uses
/// [tiltStateWithHysteresis] to avoid boundary flicker.
TiltState tiltStateFor(double pitch, TiltTarget target) {
  if (target.contains(pitch)) return TiltState.inBand;
  // Split above/below at the band centre so a NaN (which fails `contains`) is
  // not silently classed as "below"; the provider already drops NaN upstream.
  return pitch >= target.center ? TiltState.aboveBand : TiltState.belowBand;
}

/// Schmitt-trigger variant of [tiltStateFor]: it is *easier to stay in-band than
/// to enter it*. Once in-band the pitch may drift [marginDegrees] past either
/// edge before flipping out; while out-of-band the pitch must sit solidly inside
/// (by [marginDegrees]) before flipping in. This kills the rapid good/warning
/// flicker when the user hovers exactly on the band edge.
///
/// [previous] is the last emitted state (`null` on first sample). A
/// `NaN`/`Infinity` pitch holds the previous state rather than jumping.
TiltState tiltStateWithHysteresis(
  TiltState? previous,
  double pitch,
  TiltTarget target, {
  double marginDegrees = 2.0,
}) {
  if (pitch.isNaN || pitch.isInfinite) return previous ?? TiltState.inBand;
  final m = marginDegrees.abs();

  if (previous == TiltState.inBand) {
    // Stay in until clearly outside (band widened by the margin).
    if (pitch >= target.minDegrees - m && pitch < target.maxDegrees + m) {
      return TiltState.inBand;
    }
  } else {
    // (Re)enter only when solidly inside. Clamp the inner window so a band
    // narrower than 2*margin still admits its own centre.
    var lowEnter = target.minDegrees + m;
    var highEnter = target.maxDegrees - m;
    if (lowEnter > highEnter) {
      lowEnter = highEnter = target.center;
    }
    if (pitch >= lowEnter && pitch <= highEnter) return TiltState.inBand;
  }
  return pitch >= target.center ? TiltState.aboveBand : TiltState.belowBand;
}
