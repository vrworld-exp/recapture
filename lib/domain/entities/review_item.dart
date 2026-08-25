// lib/domain/entities/review_item.dart
//
// Pure Dart — NO Flutter imports. One captured photo as shown in the Level A
// review grid (Screen 7A): its file, its already-computed quality [verdict], and
// optional context for a future detail view. The grid DISPLAYS these — it does
// not evaluate quality, discard frames, or mutate the capture set; the parent
// supplies the list (ordered by capture time or ring index) and owns all of that.
import 'capture_evaluation.dart';

class ReviewItem {
  const ReviewItem({
    required this.captureId,
    required this.filePath,
    required this.verdict,
    this.issues = const [],
    this.ringIndex,
    required this.capturedAt,
  });

  /// Stable id of this capture — the grid keys tiles by it so they reuse
  /// correctly as the list shifts, and a re-capture of the same id updates
  /// rather than duplicating.
  final String captureId;

  /// Local path to the captured image. The grid downscale-decodes it; a
  /// missing/corrupt path falls back to a neutral tile (still badged).
  final String filePath;

  /// The already-computed quality outcome. Display-only — drives the badge.
  final CaptureVerdict verdict;

  /// Detected issues (empty for a clean accept). Carried for a future
  /// tooltip/detail view; the grid itself does not surface them.
  final List<CaptureIssue> issues;

  /// Position around the eye ring, if known — shown as a small tile label.
  final int? ringIndex;

  /// When it was captured.
  final DateTime capturedAt;

  @override
  bool operator ==(Object other) =>
      other is ReviewItem &&
      other.captureId == captureId &&
      other.filePath == filePath &&
      other.verdict == verdict &&
      other.ringIndex == ringIndex &&
      other.capturedAt == capturedAt &&
      _listEquals(other.issues, issues);

  @override
  int get hashCode => Object.hash(
        captureId,
        filePath,
        verdict,
        ringIndex,
        capturedAt,
        Object.hashAll(issues),
      );
}

bool _listEquals(List<CaptureIssue> a, List<CaptureIssue> b) {
  if (identical(a, b)) return true;
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}
