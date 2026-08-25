// test/capture/retake_request_test.dart
//
// Pure unit coverage for the RetakeRequest contract: the replace-vs-fill branch,
// the return-mode mapping, and the index guard (isValidFor) the capture screen
// uses to decide whether to enter retake mode or fall back to normal targeting.
import 'package:flutter_test/flutter_test.dart';
import 'package:recapture/domain/entities/retake_request.dart';

void main() {
  group('RetakeRequest', () {
    test('replacing an existing capture is not a missing-segment fill', () {
      const r = RetakeRequest(ringIndex: 4, replacingCaptureId: 'cap_4');
      expect(r.isFillingMissing, isFalse);
      expect(r.replacingCaptureId, 'cap_4');
    });

    test('a null replacingCaptureId is a missing-segment fill', () {
      const r = RetakeRequest(ringIndex: 7);
      expect(r.isFillingMissing, isTrue);
    });

    test('returnToReviewAfter defaults to true (single retake)', () {
      const r = RetakeRequest(ringIndex: 0);
      expect(r.returnToReviewAfter, isTrue);
      expect(r.returnMode, 'review');
    });

    test('resume mode reports the resume return_mode', () {
      const r = RetakeRequest(ringIndex: 0, returnToReviewAfter: false);
      expect(r.returnMode, 'resume');
    });

    group('isValidFor', () {
      test('an in-range index is valid', () {
        const r = RetakeRequest(ringIndex: 5);
        expect(r.isValidFor(30), isTrue);
      });

      test('the last segment is valid', () {
        const r = RetakeRequest(ringIndex: 29);
        expect(r.isValidFor(30), isTrue);
      });

      test('an out-of-range index is invalid (count boundary is exclusive)', () {
        const r = RetakeRequest(ringIndex: 30);
        expect(r.isValidFor(30), isFalse);
      });

      test('a negative index is invalid', () {
        const r = RetakeRequest(ringIndex: -1);
        expect(r.isValidFor(30), isFalse);
      });
    });

    test('copyWith overrides only the given fields', () {
      const r = RetakeRequest(ringIndex: 1, replacingCaptureId: 'a');
      final resumed = r.copyWith(returnToReviewAfter: false);
      expect(resumed.ringIndex, 1);
      expect(resumed.replacingCaptureId, 'a');
      expect(resumed.returnToReviewAfter, isFalse);
    });

    test('value equality + hashCode', () {
      const a = RetakeRequest(ringIndex: 2, replacingCaptureId: 'x');
      const b = RetakeRequest(ringIndex: 2, replacingCaptureId: 'x');
      const c = RetakeRequest(ringIndex: 3, replacingCaptureId: 'x');
      expect(a, b);
      expect(a.hashCode, b.hashCode);
      expect(a, isNot(c));
    });
  });
}
