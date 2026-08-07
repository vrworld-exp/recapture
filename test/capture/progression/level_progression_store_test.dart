// test/capture/progression/level_progression_store_test.dart
//
// The Hive-backed progression store: a real temp-dir round-trip (save→load
// restores the frontier + per-level summary exactly), graceful null on absent /
// corrupt blobs, and clear. Mirrors capture_session_store_test's temp-Hive setup.
import 'dart:io';

import 'package:hive/hive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:recapture/application/capture/progression/level_progression.dart';
import 'package:recapture/application/capture/progression/level_progression_store.dart';
import 'package:recapture/domain/capture/capture_flow_variant.dart';
import 'package:recapture/domain/entities/create_project_options.dart'
    show ObjectSize;
import 'package:recapture/data/local/box_names.dart';

LevelProgression _sample() => LevelProgression.of([
      const LevelProgressState(
          levelId: 'mid', levelCode: 'A', segmentCount: 10, filledCount: 8, acceptedCount: 8),
      const LevelProgressState(
          levelId: 'high', levelCode: 'B', segmentCount: 8, filledCount: 3, acceptedCount: 3),
      const LevelProgressState(
          levelId: 'low', levelCode: 'C', segmentCount: 12),
    ], currentLevelIndex: 1);

void main() {
  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('progression_store_test');
    Hive.init(tempDir.path);
  });

  tearDown(() async {
    await Hive.close();
    if (tempDir.existsSync()) await tempDir.delete(recursive: true);
  });

  test('save → load restores frontier + per-level summary exactly', () async {
    final store = LevelProgressionStore();
    await store.save('proj1', _sample(), savedAtMs: 123);

    final loaded = await store.load('proj1');
    expect(loaded, isNotNull);
    expect(loaded!.currentLevelIndex, 1);
    expect(loaded.levels.map((l) => l.levelId).toList(), ['mid', 'high', 'low']);
    expect(loaded.stateForId('mid')!.filledCount, 8);
    expect(loaded.stateForId('high')!.filledCount, 3);
    expect(loaded.stateForId('mid')!.isComplete, isTrue); // 8/10 ≥ 80% + 8 accepted
    expect(loaded.stateForId('low')!.isComplete, isFalse);
    expect(loaded, _sample());
  });

  test('absent project → null (start fresh)', () async {
    final store = LevelProgressionStore();
    expect(await store.load('nope'), isNull);
  });

  test('corrupt blob → null, never throws', () async {
    final box = await Hive.openBox<String>(BoxNames.captureProgression);
    await box.put('proj1', '{ not valid json');
    final store = LevelProgressionStore();
    expect(await store.load('proj1'), isNull);
  });

  test('structurally invalid (no levels) → null', () async {
    final box = await Hive.openBox<String>(BoxNames.captureProgression);
    await box.put('proj1', '{"current_level_index":0}');
    final store = LevelProgressionStore();
    expect(await store.load('proj1'), isNull);
  });

  test('save → load round-trips per-level fired milestones', () async {
    final store = LevelProgressionStore();
    final p = LevelProgression.of([
      const LevelProgressState(
          levelId: 'mid',
          levelCode: 'A',
          segmentCount: 10,
          filledCount: 10,
          acceptedCount: 10,
          firedMilestones: {25, 50, 75, 100}),
      const LevelProgressState(
          levelId: 'high',
          levelCode: 'B',
          segmentCount: 8,
          filledCount: 4,
          acceptedCount: 4,
          firedMilestones: {25, 50}),
      const LevelProgressState(levelId: 'low', levelCode: 'C', segmentCount: 12),
    ], currentLevelIndex: 1);
    await store.save('proj1', p);

    final loaded = await store.load('proj1');
    expect(loaded!.stateForId('mid')!.firedMilestones, {25, 50, 75, 100});
    expect(loaded.stateForId('high')!.firedMilestones, {25, 50});
    expect(loaded.stateForId('low')!.firedMilestones, isEmpty);
    expect(loaded, p); // equality includes the fired-milestone sets
  });

  test('missing/garbage fired_milestones decode to an empty set (no throw)',
      () async {
    final box = await Hive.openBox<String>(BoxNames.captureProgression);
    // A level whose fired_milestones is garbage + an absent one.
    await box.put(
      'proj1',
      '{"current_level_index":0,"levels":['
          '{"level_id":"mid","level_code":"A","segment_count":4,'
          '"fired_milestones":["x",17,50]},'
          '{"level_id":"high","level_code":"B","segment_count":4}]}',
    );
    final store = LevelProgressionStore();
    final loaded = await store.load('proj1');
    // Only the canonical 50 survives the garbage; the absent one is empty.
    expect(loaded!.stateForId('mid')!.firedMilestones, {50});
    expect(loaded.stateForId('high')!.firedMilestones, isEmpty);
  });

  test('clear removes the snapshot', () async {
    final store = LevelProgressionStore();
    await store.save('proj1', _sample());
    await store.clear('proj1');
    expect(await store.load('proj1'), isNull);
  });

  test('projects are isolated', () async {
    final store = LevelProgressionStore();
    await store.save('p1', _sample());
    expect(await store.load('p2'), isNull);
    expect(await store.load('p1'), isNotNull);
  });

  group('flow variant persistence', () {
    test('saveVariant → loadVariant round-trips both ids', () async {
      final store = LevelProgressionStore();
      await store.saveVariant('p1', CaptureFlowVariant.withoutBottom);
      expect(await store.loadVariant('p1'), CaptureFlowVariant.withoutBottom);

      await store.saveVariant('p1', CaptureFlowVariant.withBottom);
      expect(await store.loadVariant('p1'), CaptureFlowVariant.withBottom);
    });

    test('absent variant (pre-variant project) → with_bottom, never throws',
        () async {
      final store = LevelProgressionStore();
      expect(await store.loadVariant('legacy'), CaptureFlowVariant.withBottom);
    });

    test('unknown persisted id → tolerant with_bottom fallback', () async {
      final box = await Hive.openBox<String>(BoxNames.captureProgression);
      await box.put('p1::flow_variant', 'three_and_a_half_rings');
      final store = LevelProgressionStore();
      expect(await store.loadVariant('p1'), CaptureFlowVariant.withBottom);
    });

    test('variant key does not corrupt the progression blob space', () async {
      final store = LevelProgressionStore();
      await store.saveVariant('p1', CaptureFlowVariant.withoutBottom);
      // No progression saved under 'p1' → load stays null (the sibling
      // variant key never masquerades as a progression snapshot).
      expect(await store.load('p1'), isNull);
      await store.save('p1', _sample());
      expect(await store.load('p1'), isNotNull);
      expect(await store.loadVariant('p1'), CaptureFlowVariant.withoutBottom);
    });

    test('clear removes the variant along with the snapshot', () async {
      final store = LevelProgressionStore();
      await store.save('p1', _sample());
      await store.saveVariant('p1', CaptureFlowVariant.withoutBottom);
      await store.clear('p1');
      expect(await store.load('p1'), isNull);
      expect(await store.loadVariant('p1'), CaptureFlowVariant.withBottom);
    });
  });

  group('object size persistence', () {
    test('saveObjectSize → loadObjectSizeOrNull round-trips each size',
        () async {
      final store = LevelProgressionStore();
      for (final size in ObjectSize.values) {
        await store.saveObjectSize('p1', size);
        expect(await store.loadObjectSizeOrNull('p1'), size);
      }
    });

    test('absent size (legacy/never-persisted project) → null', () async {
      final store = LevelProgressionStore();
      expect(await store.loadObjectSizeOrNull('legacy'), isNull);
    });

    test('unknown persisted value → null (upload flow keeps its own default)',
        () async {
      final box = await Hive.openBox<String>(BoxNames.captureProgression);
      await box.put('p1::object_size', 'enormous');
      final store = LevelProgressionStore();
      expect(await store.loadObjectSizeOrNull('p1'), isNull);
    });

    test('clear removes the size along with the snapshot', () async {
      final store = LevelProgressionStore();
      await store.save('p1', _sample());
      await store.saveObjectSize('p1', ObjectSize.large);
      await store.clear('p1');
      expect(await store.loadObjectSizeOrNull('p1'), isNull);
    });

    test('migrateProject carries the size from a temp id to the server id',
        () async {
      final store = LevelProgressionStore();
      await store.saveObjectSize('pending_1', ObjectSize.small);
      await store.migrateProject('pending_1', 'server_1');
      expect(await store.loadObjectSizeOrNull('pending_1'), isNull);
      expect(await store.loadObjectSizeOrNull('server_1'), ObjectSize.small);
    });
  });
}
