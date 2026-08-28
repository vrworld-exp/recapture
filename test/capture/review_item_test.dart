// test/capture/review_item_test.dart
//
// Value-equality + field contract for the Screen 7A ReviewItem model.
import 'package:flutter_test/flutter_test.dart';
import 'package:recapture/domain/entities/capture_evaluation.dart';
import 'package:recapture/domain/entities/review_item.dart';

void main() {
  final at = DateTime(2026, 6, 22, 12);

  ReviewItem make({
    String captureId = 'c1',
    String filePath = '/p/c1.jpg',
    CaptureVerdict verdict = CaptureVerdict.accepted,
    List<CaptureIssue> issues = const [],
    int? ringIndex,
    DateTime? capturedAt,
  }) =>
      ReviewItem(
        captureId: captureId,
        filePath: filePath,
        verdict: verdict,
        issues: issues,
        ringIndex: ringIndex,
        capturedAt: capturedAt ?? at,
      );

  test('identical fields are equal and share a hashCode', () {
    expect(make(), make());
    expect(make().hashCode, make().hashCode);
  });

  test('differing on any field breaks equality', () {
    expect(make(captureId: 'x'), isNot(make()));
    expect(make(filePath: '/x.jpg'), isNot(make()));
    expect(make(verdict: CaptureVerdict.warn), isNot(make()));
    expect(make(ringIndex: 3), isNot(make()));
    expect(make(capturedAt: DateTime(2025)), isNot(make()));
    expect(make(issues: const [CaptureIssue.blurry]), isNot(make()));
  });

  test('issue list order is significant; same contents equal', () {
    expect(
      make(issues: const [CaptureIssue.blurry, CaptureIssue.tooDark]),
      make(issues: const [CaptureIssue.blurry, CaptureIssue.tooDark]),
    );
    expect(
      make(issues: const [CaptureIssue.blurry, CaptureIssue.tooDark]),
      isNot(make(issues: const [CaptureIssue.tooDark, CaptureIssue.blurry])),
    );
  });

  test('defaults: empty issues, null ringIndex', () {
    final r = make();
    expect(r.issues, isEmpty);
    expect(r.ringIndex, isNull);
  });
}
