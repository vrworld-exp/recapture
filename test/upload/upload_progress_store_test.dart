// test/upload/upload_progress_store_test.dart
//
// HiveUploadProgressStore against a real Hive temp dir (repo Box<String>/JSON
// convention): atomic recordPartComplete, survive-restart persistence, corrupt
// recovery, per-file isolation, concurrent confirms, and clear.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:recapture/data/local/box_names.dart';
import 'package:recapture/data/local/upload_progress_box.dart';
import 'package:recapture/domain/entities/upload_progress.dart';

void main() {
  late Directory tempDir;
  late HiveUploadProgressStore store;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('upload_progress_hive_');
    Hive.init(tempDir.path);
    store = HiveUploadProgressStore();
  });

  tearDown(() async {
    await Hive.close();
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  test('begin then recordPartComplete persists uploadId, ETag, offset atomically',
      () async {
    await store.begin('s1', 'f0',
        uploadId: 'u-1', objectKey: 'k0', totalParts: 3, totalBytes: 300);
    await store.recordPartComplete('s1', 'f0',
        partNumber: 1, etag: 'e1', offset: 100);

    final p = await store.get('s1', 'f0');
    expect(p!.uploadId, 'u-1');
    expect(p.completedParts.single, isNotNull);
    expect(p.completedParts.single.etag, 'e1');
    expect(p.offset, 100);
    expect(p.status, UploadStatus.inProgress);
  });

  test('progress survives a store restart (new instance, same box)', () async {
    await store.begin('s1', 'f0',
        uploadId: 'u-1', objectKey: 'k0', totalParts: 2, totalBytes: 200);
    await store.recordPartComplete('s1', 'f0',
        partNumber: 1, etag: 'e1', offset: 100);

    // Simulate relaunch: a brand-new store instance reading the same box.
    final reopened = HiveUploadProgressStore();
    final p = await reopened.get('s1', 'f0');
    expect(p!.uploadId, 'u-1');
    expect(p.completedPartNumbers, {1});
    expect(p.offset, 100);
  });

  test('concurrent recordPartComplete for one file keeps every part (no clobber)',
      () async {
    await store.begin('s1', 'f0',
        uploadId: 'u-1', objectKey: 'k0', totalParts: 5, totalBytes: 500);
    await Future.wait([
      for (var n = 1; n <= 5; n++)
        store.recordPartComplete('s1', 'f0',
            partNumber: n, etag: 'e$n', offset: n * 100),
    ]);
    final p = await store.get('s1', 'f0');
    expect(p!.completedPartNumbers, {1, 2, 3, 4, 5});
  });

  test('re-recording a part (crash-window) replaces, never duplicates', () async {
    await store.begin('s1', 'f0',
        uploadId: 'u-1', objectKey: 'k0', totalParts: 1, totalBytes: 100);
    await store.recordPartComplete('s1', 'f0',
        partNumber: 1, etag: 'e1', offset: 100);
    await store.recordPartComplete('s1', 'f0',
        partNumber: 1, etag: 'e1-again', offset: 100);
    final p = await store.get('s1', 'f0');
    expect(p!.completedParts.length, 1);
    expect(p.completedParts.single.etag, 'e1-again');
  });

  test('markFileComplete and clearSession', () async {
    await store.begin('s1', 'f0',
        uploadId: 'u', objectKey: 'k', totalParts: 1, totalBytes: 1);
    await store.markFileComplete('s1', 'f0');
    expect((await store.get('s1', 'f0'))!.status, UploadStatus.completed);

    await store.clearSession('s1');
    expect(await store.get('s1', 'f0'), isNull);
  });

  test('per-file + per-session isolation; listSession scopes correctly', () async {
    await store.begin('s1', 'f0', uploadId: 'a', objectKey: 'k', totalParts: 1, totalBytes: 1);
    await store.begin('s1', 'f1', uploadId: 'b', objectKey: 'k', totalParts: 1, totalBytes: 1);
    await store.begin('s2', 'f0', uploadId: 'c', objectKey: 'k', totalParts: 1, totalBytes: 1);

    final s1 = await store.listSession('s1');
    expect(s1.length, 2);
    expect(await store.get('s2', 'f0'), isNotNull);

    await store.clearFile('s1', 'f0');
    expect(await store.get('s1', 'f0'), isNull);
    expect(await store.get('s1', 'f1'), isNotNull); // sibling untouched
    expect(await store.get('s2', 'f0'), isNotNull); // other session untouched
  });

  test('corrupt persisted blob → get returns null (start fresh), no throw', () async {
    // Write raw garbage under the store's key directly.
    final box = await Hive.openBox<String>(BoxNames.uploadProgress);
    await box.put('s1::f0', '{not json');
    expect(await store.get('s1', 'f0'), isNull);
  });
}
