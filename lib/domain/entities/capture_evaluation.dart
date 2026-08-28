// lib/domain/entities/capture_evaluation.dart
//
// Pure Dart — NO Flutter imports. The result of evaluating a single Level A
// capture (the parent computes this from sharpness/exposure/coverage/placement
// checks against CaptureConfig.thresholds). The post-shot toast DISPLAYS this —
// it does not judge quality, discard frames, or mutate ring progress.

/// Overall capture outcome. [accepted] = kept clean; [warn] = kept but flagged;
/// [reject] = discarded (does not count toward accepted/coverage).
enum CaptureVerdict { accepted, warn, reject }

/// A specific quality problem the parent detected. Maps to terse user copy in
/// the presentation layer (see `PostShotMessages`).
enum CaptureIssue {
  blurry,
  tooDark,
  overexposed,
  offTarget,
  tooClose,
  tooFar,
  lowCoverage,
  unknown,
}

class CaptureEvaluation {
  const CaptureEvaluation({
    required this.captureId,
    required this.verdict,
    this.issues = const [],
  });

  /// Stable id of the shot this verdict is for. Drives single-instance, latest
  /// wins behaviour: a changed id re-triggers the toast/animation/haptic, an
  /// identical re-emit is a no-op.
  final String captureId;

  final CaptureVerdict verdict;

  /// Detected issues (empty for a clean accepted shot). Order is not significant;
  /// the presentation layer picks the most actionable one to surface.
  final List<CaptureIssue> issues;

  /// Whether a Retake CTA should be offered (anything but a clean accept).
  bool get retakeOffered => verdict != CaptureVerdict.accepted;

  @override
  bool operator ==(Object other) =>
      other is CaptureEvaluation &&
      other.captureId == captureId &&
      other.verdict == verdict &&
      _listEquals(other.issues, issues);

  @override
  int get hashCode =>
      Object.hash(captureId, verdict, Object.hashAll(issues));
}

bool _listEquals(List<CaptureIssue> a, List<CaptureIssue> b) {
  if (identical(a, b)) return true;
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}
