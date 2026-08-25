// test/persistence/project_hive_persistence_test.dart
//
// Proves locally-persisted project state survives an app restart. The restart is
// REAL: we close Hive (releasing in-memory handles) and re-init it on the SAME
// on-disk temp path, then reopen — forcing a reload from disk rather than an
// in-memory hand-off. The temp dir is NOT deleted between the two phases.
//
// NOTE ON ARCHITECTURE: this app stores Hive values as JSON strings (every box
// is `Box<String>`; see lib/data/local/hive_init.dart) — it deliberately uses NO
// generated TypeAdapters. So there is nothing to `registerAdapter`; "project
// state" round-trips through the real gateways (ProjectsCacheBox /
// ActiveSessionBox) and Project.toMap/fromMap, exactly as the app does. The
// spec's adapter/typeId assumptions don't apply to this codebase.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:recapture/data/local/active_session_box.dart';
import 'package:recapture/data/local/projects_cache_box.dart';
import 'package:recapture/domain/entities/active_session.dart';
import 'package:recapture/domain/entities/project.dart';
import 'package:recapture/domain/entities/project_status.dart';

void main() {
  late Directory dir;

  setUp(() async {
    // A unique temp dir per test → full isolation; never the app's real Hive path.
    dir = await Directory.systemTemp.createTemp('recapture_persist_test');
    Hive.init(dir.path);
  });

  tearDown(() async {
    // Close all boxes + Hive AND remove the box files, then drop the temp dir, so
    // no handles leak and no temp directories remain. Repeat/random-order safe.
    await Hive.deleteFromDisk();
    if (dir.existsSync()) await dir.delete(recursive: true);
  });

  /// The critical step: a genuine cold restart. Close Hive (release handles)
  /// WITHOUT deleting anything from disk, then re-init on the SAME path so the
  /// next open must read persisted bytes back from disk. (No adapters to
  /// re-register — this app uses none.)
  Future<void> simulateRestart() async {
    await Hive.close();
    Hive.init(dir.path);
  }

  void expectProjectEquals(Project actual, Project expected) {
    expect(actual.id, expected.id);
    expect(actual.name, expected.name);
    expect(actual.status, expected.status); // enum value, not index/string
    expect(actual.thumbnailUrl, expected.thumbnailUrl); // nullable round-trips
    // DateTime: same instant + identical serialization (no precision/tz drift).
    expect(actual.updatedAt.isAtSameMomentAs(expected.updatedAt), isTrue);
    expect(actual.updatedAt.toIso8601String(), expected.updatedAt.toIso8601String());
  }

  group('ProjectsCacheBox survives restart', () {
    test('empty state → after restart the cache is empty, not null-erroring', () async {
      // Nothing written. (Open once so a box file exists on disk pre-restart.)
      expect(await ProjectsCacheBox().read(), isNull);

      await simulateRestart();

      // Reads back as "no cached projects" — empty, no exception.
      final reopened = ProjectsCacheBox();
      expect(await reopened.read(), isNull);
    });

    test('single project survives intact, field-for-field', () async {
      final project = Project(
        id: 'proj_1',
        name: 'Living Room Sofa',
        status: ProjectStatus.completed,
        thumbnailUrl: 'https://cdn.example.com/t/proj_1.jpg',
        updatedAt: DateTime(2026, 3, 14, 9, 30, 15, 123),
      );
      await ProjectsCacheBox().save([project]);

      final before = await ProjectsCacheBox().read();
      expect(before, isNotNull);

      await simulateRestart();

      final after = await ProjectsCacheBox().read();
      expect(after, isNotNull);
      expect(after!.projects, hasLength(1));
      expectProjectEquals(after.projects.single, project);
      // The cache timestamp persists exactly (stored as epoch millis).
      expect(
        after.cachedAt.millisecondsSinceEpoch,
        before!.cachedAt.millisecondsSinceEpoch,
      );
    });

    test('nullable thumbnail round-trips as null', () async {
      final project = Project(
        id: 'no_thumb',
        name: 'Draft Scan',
        status: ProjectStatus.draft,
        updatedAt: DateTime(2026, 1, 2, 3, 4, 5),
      );
      await ProjectsCacheBox().save([project]);

      await simulateRestart();

      final after = await ProjectsCacheBox().read();
      expect(after!.projects.single.thumbnailUrl, isNull);
    });

    test('multiple projects all survive, correctly ordered, none lost/duplicated',
        () async {
      final projects = <Project>[
        Project(
          id: 'a',
          name: 'Statue',
          status: ProjectStatus.completed,
          updatedAt: DateTime(2026, 1, 1, 8),
        ),
        Project(
          id: 'b',
          name: 'Mug',
          status: ProjectStatus.capturing, // in-progress enum
          updatedAt: DateTime(2026, 1, 2, 9, 15),
        ),
        Project(
          id: 'c',
          name: 'Chair',
          status: ProjectStatus.failed,
          updatedAt: DateTime(2026, 1, 3, 10, 30, 45),
        ),
      ];
      await ProjectsCacheBox().save(projects);

      await simulateRestart();

      final after = await ProjectsCacheBox().read();
      expect(after, isNotNull);
      expect(after!.projects, hasLength(3));
      expect(after.projects.map((p) => p.id).toList(), ['a', 'b', 'c']);
      // No duplication.
      expect(after.projects.map((p) => p.id).toSet(), {'a', 'b', 'c'});
      for (var i = 0; i < projects.length; i++) {
        expectProjectEquals(after.projects[i], projects[i]);
      }
      // Every enum value deserialized to the correct member.
      expect(
        after.projects.map((p) => p.status).toList(),
        [ProjectStatus.completed, ProjectStatus.capturing, ProjectStatus.failed],
      );
    });

    test('update-then-restart persists the UPDATED value, not the stale one',
        () async {
      final original = Project(
        id: 'p',
        name: 'Old Name',
        status: ProjectStatus.draft,
        updatedAt: DateTime(2026, 5, 1, 12),
      );
      final box = ProjectsCacheBox();
      await box.save([original]);

      // Update a field and re-save (rename + status advance + new timestamp).
      final updated = original.copyWith(
        name: 'New Name',
        status: ProjectStatus.completed,
        updatedAt: DateTime(2026, 5, 2, 13, 30),
      );
      await box.save([updated]);

      await simulateRestart();

      final after = await ProjectsCacheBox().read();
      final read = after!.projects.single;
      expect(read.name, 'New Name'); // updated, not 'Old Name'
      expect(read.status, ProjectStatus.completed); // updated, not draft
      expectProjectEquals(read, updated);
    });
  });

  group('ActiveSessionBox (in-progress/draft state) survives restart', () {
    test('active session round-trips across restart', () async {
      final session = ActiveSession(
        projectId: 'proj_42',
        step: 'levelB',
        updatedAt: DateTime(2026, 6, 1, 7, 8, 9),
      );
      await ActiveSessionBox().save(session);

      await simulateRestart();

      final after = await ActiveSessionBox().read();
      expect(after, isNotNull);
      expect(after!.projectId, 'proj_42');
      expect(after.step, 'levelB');
      expect(after.updatedAt.isAtSameMomentAs(session.updatedAt), isTrue);
    });

    test('null step round-trips as null', () async {
      await ActiveSessionBox().save(
        ActiveSession(projectId: 'proj_99', updatedAt: DateTime(2026, 6, 2)),
      );

      await simulateRestart();

      final after = await ActiveSessionBox().read();
      expect(after, isNotNull);
      expect(after!.projectId, 'proj_99');
      expect(after.step, isNull);
    });

    test('empty session state → null after restart, no error', () async {
      expect(await ActiveSessionBox().read(), isNull);
      await simulateRestart();
      expect(await ActiveSessionBox().read(), isNull);
    });
  });
}
