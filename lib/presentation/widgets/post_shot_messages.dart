// lib/presentation/widgets/post_shot_messages.dart
//
// Presentation mapping: CaptureIssue / CaptureVerdict → terse user-facing copy
// for the post-shot toast. Pure (no Flutter), so it is trivially unit-testable.
// When several issues are present, the MOST ACTIONABLE one is surfaced (with a
// "+N more" suffix) so the toast stays a single short line.

import '../../domain/entities/capture_evaluation.dart';

abstract final class PostShotMessages {
  /// Most-actionable-first ordering. The first issue present in an evaluation is
  /// the one shown; the rest collapse into "+N more".
  static const List<CaptureIssue> priority = [
    CaptureIssue.blurry,
    CaptureIssue.offTarget,
    CaptureIssue.tooClose,
    CaptureIssue.tooFar,
    CaptureIssue.tooDark,
    CaptureIssue.overexposed,
    CaptureIssue.lowCoverage,
    CaptureIssue.unknown,
  ];

  /// Short label for a single issue.
  static String issueLabel(CaptureIssue issue) {
    switch (issue) {
      case CaptureIssue.blurry:
        return 'Too blurry';
      case CaptureIssue.tooDark:
        return 'Too dark';
      case CaptureIssue.overexposed:
        return 'Too bright';
      case CaptureIssue.offTarget:
        return 'Off target';
      case CaptureIssue.tooClose:
        return 'Move back';
      case CaptureIssue.tooFar:
        return 'Move closer';
      case CaptureIssue.lowCoverage:
        return 'Need more coverage';
      case CaptureIssue.unknown:
        return 'Try again';
    }
  }

  /// Title for an accepted shot (no issues to surface).
  static String acceptedTitle = 'Captured';

  /// Sub-label hint by verdict (null when none is useful).
  static String? statusLabel(CaptureVerdict verdict) {
    switch (verdict) {
      case CaptureVerdict.accepted:
        return null;
      case CaptureVerdict.warn:
        return 'Saved — retake?';
      case CaptureVerdict.reject:
        return 'Discarded';
    }
  }

  /// The single most actionable issue in [issues], or null if there are none.
  static CaptureIssue? primaryIssue(List<CaptureIssue> issues) {
    if (issues.isEmpty) return null;
    for (final p in priority) {
      if (issues.contains(p)) return p;
    }
    return issues.first; // all unranked (shouldn't happen) → first supplied
  }

  /// The toast's primary line. Accepted (or issue-less) → the positive title;
  /// otherwise the most actionable issue label with a "+N more" suffix when other
  /// distinct issues remain.
  static String primaryMessage(CaptureEvaluation eval) {
    final primary = primaryIssue(eval.issues);
    if (primary == null || eval.verdict == CaptureVerdict.accepted) {
      return acceptedTitle;
    }
    final distinct = eval.issues.toSet();
    final extra = distinct.length - 1;
    final base = issueLabel(primary);
    return extra > 0 ? '$base  +$extra more' : base;
  }
}
