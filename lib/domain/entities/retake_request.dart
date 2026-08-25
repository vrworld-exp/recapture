// lib/domain/entities/retake_request.dart
//
// Pure Dart — NO Flutter imports. The intent to RE-SHOOT one specific eye-ring
// position in Level A: the segment to target, the existing capture being replaced
// (null when FILLING a missing position), and what to do once an accepted retake
// lands (back to Review, or resume guided capture).
//
// It is the contract that travels from the Review grid (which builds it for a
// tile) into the Level A capture screen (which primes the forced target from it).
// The screen overrides its normal "next uncaptured" target with [ringIndex] and,
// in single-retake mode, stays on that one segment until an accepted shot.
//
// Captures are keyed by ring position (segment-indexed coverage + the per-level
// ledger), so a retake REPLACES the capture for that exact angle — [ringIndex] is
// the join key; [replacingCaptureId] disambiguates which record to discard when
// the segment already holds one.
class RetakeRequest {
  const RetakeRequest({
    required this.ringIndex,
    this.replacingCaptureId,
    this.returnToReviewAfter = true,
  });

  /// The eye-ring segment to retake / fill (0-based, the same indexing the ring
  /// coverage map + ring engine use). Validity against the live segment count is
  /// the consumer's call — see [isValidFor]; an out-of-range value must fall back
  /// to normal targeting, never crash.
  final int ringIndex;

  /// The existing capture to replace, or null when this fills a MISSING segment
  /// (no prior capture at [ringIndex]). Drives the replace-vs-add branch and the
  /// `replacing_existing` analytics flag.
  final String? replacingCaptureId;

  /// true  → single retake from Review: after ONE accepted shot, return to the
  ///          Review grid (which then shows the updated tile/verdict).
  /// false → resume guided capture: stay in capture and resume normal
  ///          next-segment targeting once this segment is filled.
  final bool returnToReviewAfter;

  /// No prior capture at this segment — a missing-position fill rather than a
  /// re-shoot of an existing one.
  bool get isFillingMissing => replacingCaptureId == null;

  /// The `return_mode` analytics value: "review" (single) or "resume".
  String get returnMode => returnToReviewAfter ? 'review' : 'resume';

  /// Whether [ringIndex] is a real segment for a ring of [segmentCount] positions.
  /// The capture screen uses this to guard the forced target: an invalid index
  /// falls back to normal next-uncaptured targeting (no crash, no retake mode).
  bool isValidFor(int segmentCount) =>
      ringIndex >= 0 && ringIndex < segmentCount;

  RetakeRequest copyWith({
    int? ringIndex,
    String? replacingCaptureId,
    bool? returnToReviewAfter,
  }) =>
      RetakeRequest(
        ringIndex: ringIndex ?? this.ringIndex,
        replacingCaptureId: replacingCaptureId ?? this.replacingCaptureId,
        returnToReviewAfter: returnToReviewAfter ?? this.returnToReviewAfter,
      );

  @override
  bool operator ==(Object other) =>
      other is RetakeRequest &&
      other.ringIndex == ringIndex &&
      other.replacingCaptureId == replacingCaptureId &&
      other.returnToReviewAfter == returnToReviewAfter;

  @override
  int get hashCode =>
      Object.hash(ringIndex, replacingCaptureId, returnToReviewAfter);

  @override
  String toString() =>
      'RetakeRequest(ringIndex: $ringIndex, replacing: $replacingCaptureId, '
      'returnMode: $returnMode)';
}
