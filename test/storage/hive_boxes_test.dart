// test/storage/hive_boxes_test.dart
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:recapture/data/local/active_session_box.dart';
import 'package:recapture/data/local/box_names.dart';
import 'package:recapture/data/local/hive_init.dart';
import 'package:recapture/data/local/projects_cache_box.dart';
import 'package:recapture/domain/entities/active_session.dart';
import 'package:recapture/domain/entities/project.dart';
import 'package:recapture/domain/entities/project_status.dart';

void main() {
  late Directory dir;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('recapture_hive_test');
    Hive.init(dir.path);
  });

  tearDown(() async {
    await Hive.deleteFromDisk();
    if (dir.existsSync()) await dir.delete(recursive: true);
  });

  group('ActiveSessionBox', () {
    test('write → read → clear round-trip', () async {
      final box = ActiveSessionBox();
      expect(await box.read(), isNull);

      await box.save(ActiveSession(
        projectId: 'p1',
        step: 'levelA',
        updatedAt: DateTime(2026, 1, 1),
      ));

      final read = await box.read();
      expect(read, isNotNull);
      expect(read!.projectId, 'p1');
      expect(read.step, 'levelA');

      await box.clear();
      expect(await box.read(), isNull);
    });
  });

  group('ProjectsCacheBox', () {
    test('write → read → clear round-trip', () async {
      final box = ProjectsCacheBox();
      expect(await box.read(), isNull);

      final projects = [
        Project(
          id: 'a',
          name: 'Statue',
          status: ProjectStatus.completed,
          updatedAt: DateTime(2026, 1, 1),
        ),
        Project(
          id: 'b',
          name: 'Mug',
          status: ProjectStatus.failed,
          updatedAt: DateTime(2026, 1, 2),
        ),
      ];
      await box.save(projects);

      final cached = await box.read();
      expect(cached, isNotNull);
      expect(cached!.projects.map((p) => p.id), ['a', 'b']);
      expect(cached.projects.first.status, ProjectStatus.completed);

      await box.clear();
      expect(await box.read(), isNull);
    });

    test('malformed cache JSON reads as null (never throws)', () async {
      final raw = await Hive.openBox<String>(BoxNames.projectsCache);
      await raw.put('data', 'not-json {');
      await raw.close();

      final box = ProjectsCacheBox();
      expect(await box.read(), isNull);
    });

    test('concurrent open reuses a single box (no double-open error)', () async {
      final box = ProjectsCacheBox();
      await Future.wait([box.read(), box.read(), box.save(const [])]);
      expect(Hive.isBoxOpen(BoxNames.projectsCache), isTrue);
    });
  });

  group('schema version', () {
    test('version mismatch clears the box on open', () async {
      final raw = await Hive.openBox<String>(BoxNames.activeSession);
      await raw.put(BoxSchema.versionKey, '0'); // stale version
      await raw.put('session', 'stale-data');
      await raw.close();

      final box = await openStringBoxSafely(BoxNames.activeSession);
      expect(box.get('session'), isNull); // cleared on mismatch
      expect(box.get(BoxSchema.versionKey), BoxSchema.version.toString());
    });

    test('matching version preserves data on open', () async {
      final raw = await openStringBoxSafely(BoxNames.activeSession);
      await raw.put('session', 'keep-me');
      await raw.close();

      final reopened = await openStringBoxSafely(BoxNames.activeSession);
      expect(reopened.get('session'), 'keep-me');
    });
  });
}
