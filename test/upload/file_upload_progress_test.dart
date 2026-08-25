// test/upload/file_upload_progress_test.dart
//
// Pure model tests for the durable per-file upload progress.
import 'package:flutter_test/flutter_test.dart';
import 'package:recapture/domain/entities/upload_progress.dart';
import 'package:recapture/domain/upload/file_upload_progress.dart';

void main() {
  test('round-trips through JSON losslessly', () {
    const p = FileUploadProgress(
      fileId: 'file_0.jpg',
      objectKey: 'prod/u/p/j/file_0.jpg',
      uploadId: 'u-123',
      completedParts: [
        UploadPart(partNumber: 1, etag: 'a1'),
        UploadPart(partNumber: 2, etag: 'b2'),
      ],
      offset: 10 * 1024 * 1024,
      totalParts: 3,
      totalBytes: 15 * 1024 * 1024,
      status: UploadStatus.inProgress,
    );
    final decoded = FileUploadProgress.fromJson(p.toJson());
    expect(decoded, p);
  });

  test('withPart adds/replaces a part idempotently and advances offset', () {
    const p = FileUploadProgress(fileId: 'f', objectKey: 'f', totalParts: 2);
    final a = p.withPart(const UploadPart(partNumber: 1, etag: 'e1'), offset: 5);
    expect(a.completedPartNumbers, {1});
    expect(a.offset, 5);
    expect(a.status, UploadStatus.inProgress);
    // Re-recording part 1 (crash-window re-upload) replaces, does not duplicate.
    final b = a.withPart(const UploadPart(partNumber: 1, etag: 'e1b'), offset: 5);
    expect(b.completedParts.length, 1);
    expect(b.completedParts.single.etag, 'e1b');
  });

  test('allPartsComplete only when 1..totalParts are all present', () {
    const p = FileUploadProgress(
      fileId: 'f',
      objectKey: 'f',
      totalParts: 3,
      completedParts: [
        UploadPart(partNumber: 1, etag: 'a'),
        UploadPart(partNumber: 3, etag: 'c'),
      ],
    );
    expect(p.allPartsComplete, isFalse); // gap at part 2
    final full = p.withPart(const UploadPart(partNumber: 2, etag: 'b'), offset: 0);
    expect(full.allPartsComplete, isTrue);
  });

  test('orderedParts sorts ascending for finalize', () {
    const p = FileUploadProgress(
      fileId: 'f',
      objectKey: 'f',
      totalParts: 3,
      completedParts: [
        UploadPart(partNumber: 3, etag: 'c'),
        UploadPart(partNumber: 1, etag: 'a'),
        UploadPart(partNumber: 2, etag: 'b'),
      ],
    );
    expect(p.orderedParts.map((e) => e.partNumber).toList(), [1, 2, 3]);
  });

  test('tolerant parse: bad rows skipped, missing identity → null', () {
    expect(FileUploadProgress.fromJson('nope'), isNull);
    expect(FileUploadProgress.fromJson({'objectKey': 'x'}), isNull); // no fileId
    final p = FileUploadProgress.fromJson({
      'fileId': 'f',
      'objectKey': 'k',
      'completedParts': [
        {'partNumber': 1, 'etag': 'a'},
        {'partNumber': 2}, // bad row — skipped
        'garbage',
      ],
    });
    expect(p, isNotNull);
    expect(p!.completedParts.length, 1);
  });
}
