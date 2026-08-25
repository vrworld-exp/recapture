// test/upload/upload_queue_store_test.dart
//
// HiveUploadQueueStore against a real Hive temp dir (repo Box<String>/JSON
// convention): survive-restart persistence (the durability the offline queue
// leans on), FIFO listing, corrupt recovery, and remove. Mirrors
// upload_progress_store_test.dart.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:recapture/data/local/box_names.dart';
import 'package:recapture/data/local/upload_queue_box.dart';
import 'package:recapture/domain/upload/upload_queue_entry.dart';
import 'package:recapture/domain/upload/upload_session_spec.dart';

UploadQueueEntry entry(
  String id, {
  UploadJobState state = UploadJobState.offlineQueued,
  int seq = 0,
}) =>
    UploadQueueEntry(
      jobId: id,
      spec: UploadSessionSpec(sessionId: id, files: [
        UploadFileSpec(path: '/c/$id.jpg', key: 'k/$id', size: 10),
      ]),
      state: state,
      seq: seq,
    );

void main() {
  late Directory tempDir;
  late HiveUploadQueueStore store;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('upload_queue_hive_');
    Hive.init(tempDir.path);
    store = HiveUploadQueueStore();
  });

  tearDown(() async {
    await Hive.close();
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  test('put then get round-trips an entry', () async {
    await store.put(entry('j1', state: UploadJobState.userPaused, seq: 4));

    final loaded = await store.get('j1');
    expect(loaded!.jobId, 'j1');
    expect(loaded.state, UploadJobState.userPaused);
    expect(loaded.seq, 4);
    expect(loaded.spec.files.single.key, 'k/j1');
  });

  test('queue survives a store restart (new instance, same box)', () async {
    await store.put(entry('j1', seq: 0));
    await store.put(entry('j2', state: UploadJobState.userPaused, seq: 1));

    // Simulate relaunch: a brand-new store instance reading the same box.
    final reopened = HiveUploadQueueStore();
    final all = await reopened.list();
    expect(all.map((e) => e.jobId), ['j1', 'j2']);
    expect(all[0].state, UploadJobState.offlineQueued); // still waiting
    expect(all[1].state, UploadJobState.userPaused); // intent survived
  });

  test('list returns FIFO (seq-ascending) order regardless of insert order',
      () async {
    await store.put(entry('late', seq: 9));
    await store.put(entry('first', seq: 1));
    await store.put(entry('mid', seq: 5));

    final all = await store.list();
    expect(all.map((e) => e.jobId), ['first', 'mid', 'late']);
  });

  test('put replaces (state transition persisted under the same key)', () async {
    await store.put(entry('j1'));
    await store.put(entry('j1', state: UploadJobState.userPaused));

    expect((await store.get('j1'))!.state, UploadJobState.userPaused);
    expect(await store.list(), hasLength(1));
  });

  test('remove deletes the entry; idempotent on a missing key', () async {
    await store.put(entry('j1'));
    await store.remove('j1');
    await store.remove('j1'); // no throw

    expect(await store.get('j1'), isNull);
    expect(await store.list(), isEmpty);
  });

  test('corrupt blob → skipped by list, null from get (never throws)', () async {
    await store.put(entry('good'));
    final box = await Hive.openBox<String>(BoxNames.uploadQueue);
    await box.put('bad', '{not json');

    expect(await store.get('bad'), isNull);
    final all = await store.list();
    expect(all.map((e) => e.jobId), ['good']);
  });

  test('InMemoryUploadQueueStore honors the same contract', () async {
    final mem = InMemoryUploadQueueStore();
    await mem.put(entry('b', seq: 2));
    await mem.put(entry('a', seq: 1));

    expect((await mem.list()).map((e) => e.jobId), ['a', 'b']);
    expect((await mem.get('a'))!.jobId, 'a');
    await mem.remove('a');
    expect(await mem.get('a'), isNull);
  });
}
