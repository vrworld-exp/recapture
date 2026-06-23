// test/capture/capture_evaluation_test.dart
//
// Pure unit tests for the evaluation model + the issue→message mapping.
import 'package:flutter_test/flutter_test.dart';
import 'package:recapture/domain/entities/capture_evaluation.dart';
import 'package:recapture/presentation/widgets/post_shot_messages.dart';

void main() {
  group('CaptureEvaluation', () {
    test('retakeOffered is false only for accepted', () {
      expect(
        const CaptureEvaluation(captureId: 'a', verdict: CaptureVerdict.accepted)
            .retakeOffered,
        isFalse,
      );
      expect(
        const CaptureEvaluation(captureId: 'a', verdict: CaptureVerdict.warn)
            .retakeOffered,
        isTrue,
      );
      expect(
        const CaptureEvaluation(captureId: 'a', verdict: CaptureVerdict.reject)
            .retakeOffered,
        isTrue,
      );
    });

    test('value equality includes issues', () {
      const a = CaptureEvaluation(
        captureId: 'x',
        verdict: CaptureVerdict.reject,
        issues: [CaptureIssue.blurry, CaptureIssue.tooDark],
      );
      const b = CaptureEvaluation(
        captureId: 'x',
        verdict: CaptureVerdict.reject,
        issues: [CaptureIssue.blurry, CaptureIssue.tooDark],
      );
      const c = CaptureEvaluation(
        captureId: 'x',
        verdict: CaptureVerdict.reject,
        issues: [CaptureIssue.blurry],
      );
      expect(a, b);
      expect(a.hashCode, b.hashCode);
      expect(a, isNot(c));
    });
  });

  group('PostShotMessages', () {
    test('accepted / issue-less → positive title', () {
      const e = CaptureEvaluation(captureId: 'a', verdict: CaptureVerdict.accepted);
      expect(PostShotMessages.primaryMessage(e), PostShotMessages.acceptedTitle);
    });

    test('single issue → that label, no "+N more"', () {
      const e = CaptureEvaluation(
        captureId: 'a',
        verdict: CaptureVerdict.reject,
        issues: [CaptureIssue.tooDark],
      );
      expect(PostShotMessages.primaryMessage(e), 'Too dark');
    });

    test('multiple issues → most actionable + "+N more"', () {
      const e = CaptureEvaluation(
        captureId: 'a',
        verdict: CaptureVerdict.reject,
        // blurry outranks tooDark and offTarget in the priority list.
        issues: [CaptureIssue.tooDark, CaptureIssue.blurry, CaptureIssue.offTarget],
      );
      final msg = PostShotMessages.primaryMessage(e);
      expect(msg, startsWith('Too blurry'));
      expect(msg, contains('+2 more'));
    });

    test('primaryIssue honours priority ordering', () {
      expect(
        PostShotMessages.primaryIssue(
            [CaptureIssue.lowCoverage, CaptureIssue.offTarget]),
        CaptureIssue.offTarget,
      );
      expect(PostShotMessages.primaryIssue([]), isNull);
    });

    test('statusLabel by verdict', () {
      expect(PostShotMessages.statusLabel(CaptureVerdict.accepted), isNull);
      expect(PostShotMessages.statusLabel(CaptureVerdict.warn), isNotNull);
      expect(PostShotMessages.statusLabel(CaptureVerdict.reject), 'Discarded');
    });
  });
}
