// test/upload/upload_progress_view_test.dart
//
// Pure tests for the phase-aware progress view (guarded derivations + phase).
import 'package:flutter_test/flutter_test.dart';
import 'package:recapture/domain/entities/upload_progress.dart';
import 'package:recapture/domain/upload/upload_progress_view.dart';

UploadProgressView _view(int b, int tb, int f, int tf,
        {UploadPhase phase = UploadPhase.uploading, int retry = 0}) =>
    UploadProgressView(
      progress: UploadProgress(
        status: UploadStatus.inProgress,
        bytesUploaded: b,
        totalBytes: tb,
        filesUploaded: f,
        totalFiles: tf,
      ),
      phase: phase,
      retryAttempt: retry,
    );

void main() {
  test('fraction + fileFraction are guarded against zero totals', () {
    expect(_view(0, 0, 0, 0).fraction, 0.0);
    expect(_view(0, 0, 0, 0).fileFraction, 0.0);
    expect(_view(0, 0, 0, 0).isBytesComplete, isTrue); // empty is trivially done
  });

  test('fractions compute + clamp within [0,1]', () {
    expect(_view(50, 100, 1, 4).fraction, 0.5);
    expect(_view(50, 100, 1, 4).fileFraction, 0.25);
    // Over-report clamps.
    expect(_view(150, 100, 9, 4).fraction, 1.0);
    expect(_view(150, 100, 9, 4).fileFraction, 1.0);
  });

  test('phase + retryAttempt carried; isRetrying derived', () {
    final v = _view(10, 100, 0, 2, phase: UploadPhase.retrying, retry: 2);
    expect(v.isRetrying, isTrue);
    expect(v.retryAttempt, 2);
    expect(v.phase, UploadPhase.retrying);
  });

  test('equality includes phase + retryAttempt', () {
    expect(_view(10, 100, 0, 2), _view(10, 100, 0, 2));
    expect(_view(10, 100, 0, 2, phase: UploadPhase.retrying),
        isNot(_view(10, 100, 0, 2)));
  });
}
