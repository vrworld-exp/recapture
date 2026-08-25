// lib/domain/entities/capture_progress.dart
//
// Pure Dart — NO Flutter imports. The textual progress the Level A meter renders:
// accepted-capture count vs target (N) and an overall coverage percentage
// ("Accepted: 12/36 • Coverage: 68%"). This is a DISPLAY model — counting
// captures, judging acceptance, and computing coverage are SEPARATE concerns the
// parent owns; the meter only formats and animates these supplied values.
//
// To stay consistent with the ring coverage map (the single source of truth for
// accepted/target), build this with [CaptureProgress.fromCoverage] so the two
// HUD elements can never show contradictory numbers.

import 'ring_coverage.dart';

class CaptureProgress {
  const CaptureProgress({
    required this.accepted,
    required this.target,
    required this.coveragePct,
    this.completeAtPct = 80,
  });

  /// Captures that passed quality checks (== the ring map's `filledCount`).
  final int accepted;

  /// N — total target positions (== the ring map's `segmentCount`, from
  /// CaptureConfig). May be 0 before config loads.
  final int target;

  /// Overall coverage in 0..100, supplied by the parent's coverage computation.
  /// May exceed accepted/target if coverage weights angular distribution; values
  /// out of range are clamped where used (never NaN, never overflow).
  final double coveragePct;

  /// The coverage % at which capture is considered complete (e.g. CaptureConfig's
  /// `minCoveragePct`). Latching/hysteresis around it is the meter widget's job.
  final double completeAtPct;

  /// Builds the meter model from the SAME [RingCoverage] the ring map renders so
  /// the two never disagree. [coveragePct] defaults to the ring's count progress;
  /// pass an explicit value when coverage is computed separately (e.g. angular
  /// weighting). [completeAtPct] should be CaptureConfig's `minCoveragePct`.
  factory CaptureProgress.fromCoverage(
    RingCoverage coverage, {
    double? coveragePct,
    double completeAtPct = 80,
  }) =>
      CaptureProgress(
        accepted: coverage.filledCount,
        target: coverage.segmentCount,
        coveragePct: coveragePct ?? coverage.progress * 100,
        completeAtPct: completeAtPct,
      );

  /// accepted/target in [0, 1]; 0 when [target] <= 0 (no div-by-zero).
  /// Over-capture (accepted > target) clamps to 1 — the bar never overflows.
  double get acceptedFraction =>
      target <= 0 ? 0.0 : (accepted / target).clamp(0.0, 1.0);

  /// coveragePct/100 clamped to [0, 1] (guards out-of-range coverage).
  double get coverageFraction => (coveragePct / 100).clamp(0.0, 1.0);

  /// True once coverage meets the completion threshold and the target is
  /// reachable. A 0 target is never "complete".
  bool get isComplete => target > 0 && coveragePct >= completeAtPct;

  CaptureProgress copyWith({
    int? accepted,
    int? target,
    double? coveragePct,
    double? completeAtPct,
  }) =>
      CaptureProgress(
        accepted: accepted ?? this.accepted,
        target: target ?? this.target,
        coveragePct: coveragePct ?? this.coveragePct,
        completeAtPct: completeAtPct ?? this.completeAtPct,
      );

  @override
  bool operator ==(Object other) =>
      other is CaptureProgress &&
      other.accepted == accepted &&
      other.target == target &&
      other.coveragePct == coveragePct &&
      other.completeAtPct == completeAtPct;

  @override
  int get hashCode =>
      Object.hash(accepted, target, coveragePct, completeAtPct);
}
