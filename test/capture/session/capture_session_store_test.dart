// test/capture/session/capture_session_store_test.dart
//
// CaptureSessionStore against a real Hive instance pointed at a temp dir (the
// repo's Box<String>/JSON convention). Covers save/load/clear/clearProject,
// per-level isolation, overwrite, and corrupt-data → null.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:recapture/application/capture/ledger/captured_photo_record.dart';
import 'package:recapture/application/capture/session/capture_session_state.dart';
import 'package:recapture/application/capture/session/capture_session_store.dart';
import 'package:recapture/data/local/box_names.dart';

CaptureSessionState state({
  String projectId = 'p1',
  String levelId = 'mid',
  List<CapturedPhotoRecord> accepted = const [],
  int savedAtMs = 1700000000000,
}) =>
    CaptureSessionState(
      projectId: projectId,
      levelId: levelId,
      segmentCount: 12,
      fillThreshold: 1,
      fillCounts: const [1, 0, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0],
      position: 2,
      accepted: accepted,
      warned: const [],
      rejected: const [],
      savedAtMs: savedAtMs,
    );

CapturedPhotoRecord acc(String framePath) => CapturedPhotoRecord(
      segmentIndex: 0,
      framePath: framePath,
      blurScore: 80,
      meanLuminance: 128,
      yawDegrees: 0,
      pitchDegrees: 45,
      sensorTimestampNs: 1000,
    );

void main() {
  late Directory tempDir;
  late CaptureSessionStore store;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('capture_session_hive_');
    Hive.init(tempDir.path);
    store = CaptureSessionStore();
  });

  tearDown(() async {
    await Hive.close();
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  test('save then load returns an equivalent state', () async {
    final s = state(accepted: [acc('a.jpg')]);
    await store.save(s);
    final loaded = await store.load(s.projectId, s.levelId);
    expect(loaded, equals(s));
  });

  test('load returns null for an unknown project/level', () async {
    expect(await store.load('nope', 'mid'), isNull);
  });

  test('hasSession is false before save, true after', () async {
    expect(await store.hasSession('p1', 'mid'), isFalse);
    await store.save(state());
    expect(await store.hasSession('p1', 'mid'), isTrue);
  });

  test('save overwrites a prior snapshot for the same project+level', () async {
    await store.save(state(accepted: [acc('old.jpg')]));
    await store.save(state(accepted: [acc('new.jpg')]));
    final loaded = await store.load('p1', 'mid');
    expect(loaded!.accepted.single.framePath, 'new.jpg');
  });

  test('different levels of the same project do not collide', () async {
    await store.save(state(levelId: 'mid', accepted: [acc('mid.jpg')]));
    await store.save(state(levelId: 'high', accepted: [acc('high.jpg')]));
    expect((await store.load('p1', 'mid'))!.accepted.single.framePath, 'mid.jpg');
    expect((await store.load('p1', 'high'))!.accepted.single.framePath, 'high.jpg');
  });

  test('clear removes the snapshot; load then returns null', () async {
    await store.save(state());
    await store.clear('p1', 'mid');
    expect(await store.load('p1', 'mid'), isNull);
  });

  test('clear on a nonexistent key does not throw', () async {
    await expectLater(store.clear('ghost', 'mid'), completes);
  });

  test('clearProject removes all levels for that project, leaves others', () async {
    await store.save(state(projectId: 'p1', levelId: 'mid'));
    await store.save(state(projectId: 'p1', levelId: 'high'));
    await store.save(state(projectId: 'p2', levelId: 'mid'));
    await store.clearProject('p1');
    expect(await store.hasSession('p1', 'mid'), isFalse);
    expect(await store.hasSession('p1', 'high'), isFalse);
    expect(await store.hasSession('p2', 'mid'), isTrue);
  });

  test('load returns null (not throws) on corrupt stored data', () async {
    await store.save(state()); // ensures the box is open
    final box = Hive.box<String>(BoxNames.captureSessions);
    await box.put('p1::mid', '{"garbage":"data"}'); // valid JSON, invalid schema
    expect(await store.load('p1', 'mid'), isNull);

    await box.put('p1::mid', 'not even json'); // invalid JSON
    expect(await store.load('p1', 'mid'), isNull);
  });
}
