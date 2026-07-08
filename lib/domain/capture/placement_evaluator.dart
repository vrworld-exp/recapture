// lib/domain/capture/placement_evaluator.dart
//
// Pure Dart — only `dart:ui` for geometry (Rect/Offset), NO Flutter framework /
// Riverpod / native imports. The placement DECISION for the centre-frame guide:
// maps a detected object bounding box (normalized capture-image space, from the
// native detector) + the [PlacementBox] guide region to the [PlacementStatus]
// the overlay renders (good / offCenter / tooClose / tooFar / idle). It owns no
// detection, no streams, and no debounce timing — the reactive layer
// (placementStatusProvider) drives it per detection sample.
//
// THE RULES (checked in priority order — the FIRST violated wins, so the user
// always gets ONE actionable cue):
//   1. no detection / degenerate box / low confidence → idle (never a warning:
//      an absent detector must not paint the guide red).
//   2. fill > maxFillRatio → tooClose  ("Move back"): the object dominates the
//      guide and likely clips the frame edges.
//   3. fill < minFillRatio → tooFar    ("Move closer"): distance guidance is
//      RELATIVE by design — a phone camera cannot measure absolute cm without
//      depth hardware, but "fills the guide nicely" is exactly what the model
//      pipeline needs from a capture.
//   4. centre offset beyond tolerance → offCenter ("Center the object").
//   5. otherwise → good ("Looks good — hold steady").
//
// `fill` is objectArea / guideArea. Distance is checked BEFORE centering because
// a too-small/too-large object should be re-distanced first — re-centering a
// wrongly-sized object is wasted user effort.
//
// HYSTERESIS: when the previous status was `good`, every threshold widens by
// [PlacementTolerances.hysteresisFrac] (Schmitt trigger) so a borderline object
// doesn't flicker green/red with detector jitter. ENTRY to good is always
// strict; only STAYING good is forgiving — the same pattern as the auto-capture
// trigger's pitch-band hysteresis.

import 'dart:ui' show Offset, Rect;

import '../entities/placement_box.dart';

/// Tunable thresholds for the placement decision. Defaults are conservative
/// starting points for "single object on a surface, ~70% guide box"; validated
/// so a bad remote value can never invert a range or disable the decision.
class PlacementTolerances {
  const PlacementTolerances({
    this.minFillRatio = 0.20,
    this.maxFillRatio = 0.85,
    this.centerToleranceFrac = 0.35,
    this.hysteresisFrac = 0.15,
    this.minConfidence = 0.35,
  });

  /// Object-to-guide area ratio below which the object is TOO FAR (default 20%).
  final double minFillRatio;

  /// Object-to-guide area ratio above which the object is TOO CLOSE (default
  /// 85%). Values above 1 mean the object outgrew the guide entirely.
  final double maxFillRatio;

  /// Allowed offset of the object centre from the guide centre, per axis, as a
  /// fraction of the guide's half-extent on that axis (default 35%). 0 demands a
  /// perfect centre; 1 tolerates the object centre touching the guide edge.
  final double centerToleranceFrac;

  /// How much every threshold widens while the previous status is `good`
  /// (default 15%) — the Schmitt band that stops green/red flicker.
  final double hysteresisFrac;

  /// Detections below this confidence are treated as "no detection" → idle.
  final double minConfidence;

  /// Guarded copy: NaN/negative values fall back to defaults, and an inverted
  /// fill range is repaired by swapping. Call this once on remote-sourced input.
  PlacementTolerances sanitized() {
    double pick(double v, double fallback, {double max = double.infinity}) =>
        (v.isNaN || v < 0 || v > max) ? fallback : v;
    var minFill = pick(minFillRatio, 0.20);
    var maxFill = pick(maxFillRatio, 0.85);
    if (minFill > maxFill) (minFill, maxFill) = (maxFill, minFill);
    return PlacementTolerances(
      minFillRatio: minFill,
      maxFillRatio: maxFill,
      centerToleranceFrac: pick(centerToleranceFrac, 0.35, max: 1.0),
      hysteresisFrac: pick(hysteresisFrac, 0.15, max: 1.0),
      minConfidence: pick(minConfidence, 0.35, max: 1.0),
    );
  }
}

/// One detection sample from the native detector: the object's bounding box in
/// NORMALIZED capture-image space (0..1, same space as [PlacementBox]) and the
/// detector's confidence. [none] represents "nothing detected this frame".
class PlacementDetection {
  const PlacementDetection({required this.objectNormalized, this.confidence = 1});

  /// Detected object bounds, normalized 0..1. Null = no object this frame.
  final Rect? objectNormalized;

  /// Detector confidence 0..1 (1 when the source does not score).
  final double confidence;

  static const PlacementDetection none =
      PlacementDetection(objectNormalized: null, confidence: 0);
}

/// True when [r] is a usable, finite, positive-area normalized rect. NaN /
/// Infinity / inverted / zero-area boxes are detector glitches → not usable.
bool _isUsable(Rect r) =>
    r.left.isFinite &&
    r.top.isFinite &&
    r.right.isFinite &&
    r.bottom.isFinite &&
    r.width > 0 &&
    r.height > 0;

/// The pure placement decision — deterministic and side-effect-free. Pass the
/// [previous] status to get hysteresis (only `good` widens thresholds); omit it
/// for a strict one-shot evaluation.
PlacementStatus evaluatePlacement(
  PlacementDetection detection, {
  PlacementBox box = const PlacementBox(),
  PlacementTolerances tolerances = const PlacementTolerances(),
  PlacementStatus previous = PlacementStatus.idle,
}) {
  final t = tolerances.sanitized();
  final object = detection.objectNormalized;
  if (object == null ||
      !_isUsable(object) ||
      detection.confidence.isNaN ||
      detection.confidence < t.minConfidence) {
    return PlacementStatus.idle;
  }

  final guide = box.normalizedRect;
  // Widen every threshold only while already good (Schmitt: strict entry,
  // forgiving hold).
  final h = previous == PlacementStatus.good ? t.hysteresisFrac : 0.0;

  // 1) Distance (fill ratio) before centering.
  final fill = (object.width * object.height) / (guide.width * guide.height);
  if (fill > t.maxFillRatio * (1 + h)) return PlacementStatus.tooClose;
  if (fill < t.minFillRatio * (1 - h)) return PlacementStatus.tooFar;

  // 2) Centering: per-axis offset of the object centre from the guide centre,
  // measured against the guide's half-extent on that axis.
  final Offset delta = object.center - guide.center;
  final tolX = (guide.width / 2) * t.centerToleranceFrac * (1 + h);
  final tolY = (guide.height / 2) * t.centerToleranceFrac * (1 + h);
  if (delta.dx.abs() > tolX || delta.dy.abs() > tolY) {
    return PlacementStatus.offCenter;
  }

  return PlacementStatus.good;
}
