// lib/domain/capture/ring_progress.dart
//
// Pure Dart — NO Flutter/Riverpod/native imports. The Level A ring-progress
// resolver: it turns the user's live ring position (a segment index derived from
// smoothed yaw) plus the live fill state into the single [RingDirectionState] the
// guidance engine + direction arrow consume.
//
// DIVISION OF LABOUR (the repo's existing contract):
//   - The ring ENGINE / [RingMath] owns the ANGULAR math: yaw → segment index
//     ([ringSegmentForYaw]), wraparound-aware distance, and nearest-in-set. This
//     file CONSUMES that math — it never reimplements it.
//   - [SegmentCoverage] is the SINGLE SOURCE OF TRUTH for FILL state (filled /
//     missing). This resolver READS it; it never marks captures.
//
// The target is the NEAREST MISSING segment from the user's current segment by the
// engine's wraparound-aware distance (forward/index-increasing ties), computed
// from [currentSegment] directly — independent of [SegmentCoverage.position] — so
// the output is correct regardless of when the position was last synced.
import '../entities/direction_hint.dart' show RingDirection;
import '../entities/segment_coverage.dart';
import 'guidance_inputs.dart' show RingDirectionState;
import 'ring_coverage_engine.dart' show RingMath;

/// Maps a smoothed [yawDegrees] to an eye-ring segment index in `[0, segmentCount)`,
/// relative to [yawStartDegrees] (the session baseline = segment 0's start).
/// Wraparound-safe: ring position is the normalized `(yaw − yawStart)` in [0, 360),
/// NOT a shortest-path ±180° delta. Guards `segmentCount >= 1`.
int ringSegmentForYaw({
  required double yawDegrees,
  required double yawStartDegrees,
  required int segmentCount,
}) {
  final n = segmentCount < 1 ? 1 : segmentCount;
  final normalized = RingMath.normalizeDegrees(yawDegrees - yawStartDegrees);
  return RingMath.assignSegment(normalized, n);
}

/// The pure ring-progress decision for [currentSegment] given the live [coverage]
/// fill state. Deterministic and side-effect-free.
///
///   - `atTargetPosition`     — the user points at the current target segment
///                              (i.e. the segment they're in is the nearest gap).
///   - `currentPositionCaptured` — the segment they point at is already filled.
///   - `toNext`               — shorter-arc direction to the nearest missing gap.
///   - `angularGapDeg`        — degrees to that gap (0 when at it).
///   - `allCaptured`          — no missing segments remain (terminal cue).
///
/// An out-of-range [currentSegment] (a stale value) is normalized into range — it
/// can never throw or escape the ring.
RingDirectionState resolveRingDirection({
  required int currentSegment,
  required SegmentCoverage coverage,
}) {
  final n = coverage.segmentCount; // always >= 1
  final cur = ((currentSegment % n) + n) % n;
  final filledHere = coverage.filled[cur];
  final target = RingMath.nearestInSet(cur, coverage.missingSegments.toSet(), n);

  // No missing segment to guide toward → the whole ring is covered (terminal).
  if (target == null) {
    return RingDirectionState(
      atTargetPosition: false,
      currentPositionCaptured: filledHere,
      toNext: RingDirection.clockwise, // moot at completion
      angularGapDeg: 0,
      allCaptured: true,
    );
  }

  // Shorter arc from cur → target. Forward = index-increasing = clockwise (the
  // ring's sweep convention); equal distance resolves FORWARD (clockwise), matching
  // RingMath.nearestInSet's forward-tie rule.
  final stepsForward = (target - cur + n) % n;
  final stepsBackward = n - stepsForward;
  final toNext = stepsForward <= stepsBackward
      ? RingDirection.clockwise
      : RingDirection.counterclockwise;

  return RingDirectionState(
    atTargetPosition: cur == target,
    currentPositionCaptured: filledHere,
    toNext: toNext,
    angularGapDeg: RingMath.segmentDistance(cur, target, n) * (360.0 / n),
    allCaptured: false,
  );
}
