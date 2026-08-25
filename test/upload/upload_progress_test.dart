// test/upload/upload_progress_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:recapture/domain/entities/upload_progress.dart';

UploadProgress _p({
  UploadStatus status = UploadStatus.inProgress,
  int bytes = 0,
  int total = 0,
  int files = 0,
  int totalFiles = 0,
}) =>
    UploadProgress(
      status: status,
      bytesUploaded: bytes,
      totalBytes: total,
      filesUploaded: files,
      totalFiles: totalFiles,
    );

void main() {
  test('fraction: 0 when totals unknown (no divide-by-zero)', () {
    expect(_p(bytes: 0, total: 0).fraction, 0.0);
    expect(_p(bytes: 10, total: 0).fraction, 0.0);
  });

  test('fraction: clamped to [0,1] on transient over-report', () {
    expect(_p(bytes: 50, total: 100).fraction, 0.5);
    expect(_p(bytes: 150, total: 100).fraction, 1.0); // never > 100%
    expect(_p(bytes: -10, total: 100).fraction, 0.0); // never negative
  });

  test('display counts clamp into [0, total]', () {
    final p = _p(bytes: 999, total: 100, files: 12, totalFiles: 10);
    expect(p.displayBytesUploaded, 100);
    expect(p.displayFilesUploaded, 10);
    final n = _p(files: -3, totalFiles: 10);
    expect(n.displayFilesUploaded, 0);
  });

  test('hasTotals / status helpers', () {
    expect(UploadProgress.initial.hasTotals, isFalse);
    expect(_p(total: 1).hasTotals, isTrue);
    expect(_p(status: UploadStatus.completed).isComplete, isTrue);
    expect(_p(status: UploadStatus.failed).isFailed, isTrue);
    expect(_p(status: UploadStatus.paused).isPaused, isTrue);
    expect(_p(status: UploadStatus.cancelled).isCancelled, isTrue);
    expect(_p(status: UploadStatus.inProgress).isCancelled, isFalse);
  });
}
