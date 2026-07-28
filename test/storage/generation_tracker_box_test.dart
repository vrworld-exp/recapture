// test/storage/generation_tracker_box_test.dart
//
// The REAL Hive gateway for the watched-generations set, against a temp-dir box
// — the tracker's own tests use an in-memory double, so this is the only place
// the actual persistence is exercised.
//
// Lives here rather than in a `testWidgets` file on purpose: Hive IO inside
// testWidgets has repeatedly needed `tester.runAsync` in this codebase, so the
// durable behaviour is proven in a plain `test()` and the widget layer gets a
// fake.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:recapture/data/local/box_names.dart';
import 'package:recapture/data/local/generation_tracker_box.dart';

void main() {
  late Directory dir;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('recapture_gen_tracker_test');
    Hive.init(dir.path);
  });

  tearDown(() async {
    await Hive.deleteFromDisk();
    if (dir.existsSync()) await dir.delete(recursive: true);
  });

  TrackedGenerationRecord record(String id, {String name = 'Chair'}) =>
      TrackedGenerationRecord(
        projectId: id,
        projectName: name,
        startedAt: DateTime(2026, 7, 27, 10, 30),
      );

  group('GenerationTrackerBox', () {
    test('write → read → clear round-trip', () async {
      final box = GenerationTrackerBox();
      expect(await box.read(), isEmpty);

      await box.save([record('p1'), record('p2', name: 'Lamp')]);

      final read = await box.read();
      expect(read, hasLength(2));
      expect(read[0].projectId, 'p1');
      expect(read[0].projectName, 'Chair');
      expect(read[0].startedAt, DateTime(2026, 7, 27, 10, 30));
      expect(read[1].projectName, 'Lamp');

      await box.clear();
      expect(await box.read(), isEmpty);
    });

    // The kill/relaunch case this whole box exists for.
    test('survives a restart — a new instance reads the same box', () async {
      await GenerationTrackerBox().save([record('p1')]);

      final afterRelaunch = await GenerationTrackerBox().read();
      expect(afterRelaunch.map((r) => r.projectId), ['p1']);
    });

    test('save overwrites rather than appending', () async {
      final box = GenerationTrackerBox();
      await box.save([record('p1'), record('p2')]);
      await box.save([record('p3')]);

      expect((await box.read()).map((r) => r.projectId), ['p3']);
    });

    test('a corrupt blob degrades to empty and never throws', () async {
      final raw = await Hive.openBox<String>(BoxNames.modelGenerations);
      await raw.put('generations', 'not json at all {{{');

      expect(await GenerationTrackerBox().read(), isEmpty);
    });

    test('a non-list document degrades to empty', () async {
      final raw = await Hive.openBox<String>(BoxNames.modelGenerations);
      await raw.put('generations', '{"generations": "nope"}');

      expect(await GenerationTrackerBox().read(), isEmpty);
    });

    test('one unparseable row is skipped, the rest survive', () async {
      final raw = await Hive.openBox<String>(BoxNames.modelGenerations);
      await raw.put(
        'generations',
        '[{"projectId":"p1","projectName":"Chair","startedAt":"2026-07-27T10:30:00.000"},'
            '{"projectName":"no id here"},'
            '"not even a map",'
            '{"projectId":"p2","projectName":"Lamp","startedAt":"2026-07-27T10:30:00.000"}]',
      );

      final read = await GenerationTrackerBox().read();
      expect(read.map((r) => r.projectId), ['p1', 'p2']);
    });

    test('an unparseable timestamp costs the metric, not the generation',
        () async {
      final raw = await Hive.openBox<String>(BoxNames.modelGenerations);
      await raw.put(
        'generations',
        '[{"projectId":"p1","projectName":"Chair","startedAt":"whenever"}]',
      );

      final read = await GenerationTrackerBox().read();
      // Still restored — a bad duration must not lose a run the user is
      // waiting on.
      expect(read.single.projectId, 'p1');
      expect(read.single.startedAt, isA<DateTime>());
    });
  });

  group('TrackedGenerationRecord', () {
    test('a row with no project id is worthless and returns null', () {
      expect(
        TrackedGenerationRecord.tryFromMap({'projectName': 'Chair'}),
        isNull,
      );
      expect(
        TrackedGenerationRecord.tryFromMap(
            {'projectId': '', 'projectName': 'C'}),
        isNull,
      );
    });

    test('carries no percent and no status — the server owns both', () {
      final map = record('p1').toMap();
      expect(
          map.keys, unorderedEquals(['projectId', 'projectName', 'startedAt']));
    });
  });
}
