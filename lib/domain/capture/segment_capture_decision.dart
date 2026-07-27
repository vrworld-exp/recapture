// lib/domain/capture/segment_capture_decision.dart
//
// Pure Dart — NO Flutter/native imports. Overlap enforcement for Level A (Eye
// Ring): the typed decision returned BEFORE a capture is committed, so the flow
// rejects a capture aimed at a segment that already holds an accepted capture
// (surfacing "Already captured this angle") instead of silently overwriting or
// silently dropping it.
//
// GROUNDED on the existing ring stack (NOT a parallel ring/segment system): the
// segment indexing + yaw→segment resolution + per-segment coverage are owned by
// [RingCoverageEngine] (degrees, wraparound-safe). This file adds only the
// decision vocabulary on top — it carries the engine's segment INDEX (its native
// unit), not a separate value type. The fill state can come from the engine's
// `covered[]` or from [SegmentCoverage.filled]; this decision is agnostic — it
// takes a plain `isFilled` so whichever store is source-of-truth feeds it.

/// Result of evaluating a capture attempt against a segment's fill state. Sealed
/// so callers must handle both outcomes exhaustively (switch expression).
sealed class SegmentCaptureDecision {
  const SegmentCaptureDecision(this.segmentIndex);

  /// The ring segment the capture attempt resolved to (engine index, 0-based).
  final int segmentIndex;
}

/// The segment is empty — the capture should proceed.
final class ProceedCapture extends SegmentCaptureDecision {
  const ProceedCapture(super.segmentIndex);

  @override
  bool operator ==(Object other) =>
      other is ProceedCapture && other.segmentIndex == segmentIndex;

  @override
  int get hashCode => Object.hash(ProceedCapture, segmentIndex);

  @override
  String toString() => 'ProceedCapture(segment: $segmentIndex)';
}

/// The segment already holds an accepted capture — reject the attempt and let
/// the UI surface [warningMessage]. The capture must NOT overwrite or count.
final class RejectAlreadyFilled extends SegmentCaptureDecision {
  const RejectAlreadyFilled(super.segmentIndex);

  /// User-facing warning copy. The SINGLE source of truth — UI layers must read
  /// this constant, never hardcode the string at call sites. It is deliberately
  /// DIRECTIVE ("turn to the next section"): the only useful thing to tell a user
  /// standing at a finished segment is where to go, not what went wrong.
  static const String warningMessage =
      'Already captured this angle — turn to the next section';

  @override
  bool operator ==(Object other) =>
      other is RejectAlreadyFilled && other.segmentIndex == segmentIndex;

  @override
  int get hashCode => Object.hash(RejectAlreadyFilled, segmentIndex);

  @override
  String toString() => 'RejectAlreadyFilled(segment: $segmentIndex)';
}

/// The pure overlap decision: a capture into a filled segment is rejected, an
/// empty one proceeds. Deterministic, side-effect-free, and independent of which
/// store provides [isFilled] (engine `covered[]` or [SegmentCoverage.filled]).
/// This is a READ — it must never mutate fill state; the caller marks the
/// segment filled separately, only after the capture is actually accepted
/// downstream (blur/exposure/stability gates pass), so the full pipeline can run
/// between evaluation and commit.
SegmentCaptureDecision evaluateSegmentCapture({
  required int segmentIndex,
  required bool isFilled,
}) =>
    isFilled
        ? RejectAlreadyFilled(segmentIndex)
        : ProceedCapture(segmentIndex);
