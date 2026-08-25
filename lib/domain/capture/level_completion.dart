// lib/domain/capture/level_completion.dart
//
// Pure Dart — NO Flutter/native imports. The Level A (Eye Ring) completion gate:
// the ring is "complete enough to advance" iff BOTH
//   1. COVERAGE — filled segments ≥ minCoveragePct of segmentCount (angular
//      SPREAD: you went most of the way around), AND
//   2. COUNT    — accepted photos ≥ minAcceptedCount (total VOLUME: enough frames
//      for reconstruction even if some concentrate).
// Two complementary criteria (AND). 80% (not 100%) lets the ring finish without
// every hard-to-reach segment.
//
// GROUNDED on the existing stack (not recomputed here):
//   • Coverage comes from the segment-state model
//     ([SegmentCoverage.filledCount]/[SegmentCoverage.segmentCount], which already
//     honours `fillThreshold`) — the SINGLE SOURCE OF TRUTH. Use
//     [evaluateLevelAFromCoverage] to read it directly.
//   • The threshold is a PERCENT, matching the repo's `CaptureConfig.thresholds
//     .minCoveragePct` / `CaptureProgress.completeAtPct` (both percent, default 80)
//     — NOT a 0–1 ratio. Per-level/remote-tunable; validated here.
//   • "accepted" = ACCEPT + WARN-kept, EXCLUDING REJECT — i.e. the count of
//     `LevelCaptureLedger.accepted` (the same frames that fill segments). There is
//     no Dart `minAcceptedCount` config yet (the backend has per-object-size min
//     photos), so it is an explicit, validated input.
//
// The COVERAGE gate uses an exact INTEGER ratio comparison (`filledCount * 100 >=
// pct * segmentCount`) — no rounding, inclusive at exactly the threshold. A
// `requiredSegments` integer is derived (ceil) for "N more segments" guidance ONLY
// and is equivalent to the gate at the boundary; documented below.

import 'dart:math' as math;

import '../entities/segment_coverage.dart';

/// Default coverage threshold (PERCENT), mirroring `CaptureConfig.thresholds
/// .minCoveragePct` and `CaptureProgress.completeAtPct`.
const double kDefaultMinCoveragePct = 80;

/// The filled-segment floor [minCoveragePct] demands of a ring of
/// [segmentCount] segments = `ceil(pct/100 * segmentCount)` — the ONE ceil
/// every coverage consumer (this gate's guidance, the upload gate's floor)
/// shares, so no two layers can disagree on "how many segments is 80%".
/// Same guards as [evaluateLevelA]: a pct outside `(0, 100]` (or non-finite)
/// falls back to [kDefaultMinCoveragePct]; a non-positive [segmentCount] → 0.
int requiredSegmentsFor(double minCoveragePct, int segmentCount) {
  if (segmentCount <= 0) return 0;
  final pct =
      (minCoveragePct.isFinite && minCoveragePct > 0 && minCoveragePct <= 100)
          ? minCoveragePct
          : kDefaultMinCoveragePct;
  return (pct / 100.0 * segmentCount).ceil();
}

/// Structured completion result — both criteria reported independently plus the
/// per-criterion shortfall, so the UI can guide ("X more segments", "Y more
/// photos"). Immutable value type.
class LevelCompletion {
  const LevelCompletion({
    required this.isComplete,
    required this.coverageMet,
    required this.countMet,
    required this.coverageRatio,
    required this.minCoveragePct,
    required this.filledCount,
    required this.segmentCount,
    required this.requiredSegments,
    required this.acceptedCount,
    required this.minAcceptedCount,
    required this.segmentsShort,
    required this.photosShort,
  });

  /// `coverageMet && countMet`.
  final bool isComplete;

  /// Coverage criterion: `filledCount/segmentCount >= minCoveragePct/100`.
  final bool coverageMet;

  /// Count criterion: `acceptedCount >= minAcceptedCount`.
  final bool countMet;

  /// `filledCount / segmentCount` in [0, 1] (0 when segmentCount <= 0). For
  /// display; the GATE uses the exact integer comparison, not this double.
  final double coverageRatio;

  /// The validated coverage threshold actually applied (percent).
  final double minCoveragePct;

  final int filledCount;
  final int segmentCount;

  /// Segments needed to reach [minCoveragePct] = `ceil(pct/100 * segmentCount)`.
  /// Guidance only (equivalent to the gate at the boundary). 0 when segmentCount
  /// <= 0.
  final int requiredSegments;

  final int acceptedCount;
  final int minAcceptedCount;

  /// `max(0, requiredSegments - filledCount)` — 0 when coverage is met.
  final int segmentsShort;

  /// `max(0, minAcceptedCount - acceptedCount)` — 0 when count is met.
  final int photosShort;

  @override
  bool operator ==(Object other) =>
      other is LevelCompletion &&
      other.isComplete == isComplete &&
      other.coverageMet == coverageMet &&
      other.countMet == countMet &&
      other.coverageRatio == coverageRatio &&
      other.minCoveragePct == minCoveragePct &&
      other.filledCount == filledCount &&
      other.segmentCount == segmentCount &&
      other.requiredSegments == requiredSegments &&
      other.acceptedCount == acceptedCount &&
      other.minAcceptedCount == minAcceptedCount &&
      other.segmentsShort == segmentsShort &&
      other.photosShort == photosShort;

  @override
  int get hashCode => Object.hash(
        isComplete,
        coverageMet,
        countMet,
        coverageRatio,
        minCoveragePct,
        filledCount,
        segmentCount,
        requiredSegments,
        acceptedCount,
        minAcceptedCount,
        segmentsShort,
        photosShort,
      );

  @override
  String toString() => 'LevelCompletion(complete: $isComplete, '
      'coverage: $filledCount/$segmentCount '
      '${(coverageRatio * 100).toStringAsFixed(1)}% '
      '(met: $coverageMet, need $requiredSegments, short $segmentsShort), '
      'count: $acceptedCount/$minAcceptedCount '
      '(met: $countMet, short $photosShort))';
}

/// The pure completion decision. [filledCount]/[segmentCount] come from the
/// segment state (do NOT recompute from yaw); [acceptedCount] is the accepted
/// ledger size (ACCEPT + WARN-kept, never REJECT).
///
/// Config is validated/guarded: [minCoveragePct] outside `(0, 100]` (or
/// non-finite) falls back to [kDefaultMinCoveragePct]; a negative
/// [minAcceptedCount] is clamped to 0. [segmentCount] <= 0 is guarded — coverage
/// can never be met (no divide-by-zero).
LevelCompletion evaluateLevelA({
  required int filledCount,
  required int segmentCount,
  required int acceptedCount,
  required int minAcceptedCount,
  double minCoveragePct = kDefaultMinCoveragePct,
}) {
  final pct = (minCoveragePct.isFinite && minCoveragePct > 0 && minCoveragePct <= 100)
      ? minCoveragePct
      : kDefaultMinCoveragePct;
  final minCount = minAcceptedCount < 0 ? 0 : minAcceptedCount;
  final filled = filledCount < 0 ? 0 : filledCount;
  final accepted = acceptedCount < 0 ? 0 : acceptedCount;

  final hasSegments = segmentCount > 0;

  // Exact integer ratio comparison — no rounding, inclusive at the threshold.
  final coverageMet = hasSegments && filled * 100.0 >= pct * segmentCount;
  final coverageRatio = hasSegments ? filled / segmentCount : 0.0;

  // Guidance-only required count (equivalent to the gate at the boundary).
  final requiredSegments = requiredSegmentsFor(pct, segmentCount);
  final segmentsShort = math.max(0, requiredSegments - filled);

  final countMet = accepted >= minCount;
  final photosShort = math.max(0, minCount - accepted);

  return LevelCompletion(
    isComplete: coverageMet && countMet,
    coverageMet: coverageMet,
    countMet: countMet,
    coverageRatio: coverageRatio,
    minCoveragePct: pct,
    filledCount: filled,
    segmentCount: segmentCount,
    requiredSegments: requiredSegments,
    acceptedCount: accepted,
    minAcceptedCount: minCount,
    segmentsShort: segmentsShort,
    photosShort: photosShort,
  );
}

/// Convenience: evaluate directly from the [SegmentCoverage] single-source-of-
/// truth (reads its `filledCount`/`segmentCount`, honouring `fillThreshold`) plus
/// the accepted-ledger count.
LevelCompletion evaluateLevelAFromCoverage(
  SegmentCoverage coverage, {
  required int acceptedCount,
  required int minAcceptedCount,
  double minCoveragePct = kDefaultMinCoveragePct,
}) =>
    evaluateLevelA(
      filledCount: coverage.filledCount,
      segmentCount: coverage.segmentCount,
      acceptedCount: acceptedCount,
      minAcceptedCount: minAcceptedCount,
      minCoveragePct: minCoveragePct,
    );
