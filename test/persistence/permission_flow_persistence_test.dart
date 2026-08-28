// test/persistence/permission_flow_persistence_test.dart
//
// Proves permission FLOW state survives a real cold restart: close Hive
// (release handles) WITHOUT deleting from disk, re-init on the SAME temp path,
// then reopen — forcing a reload from disk. Mirrors the project-persistence
// test pattern. (No TypeAdapters — values are JSON strings.)

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:recapture/data/local/permission_flow_box.dart';
import 'package:recapture/domain/entities/permission_flow_state.dart';
import 'package:recapture/domain/entities/permission_item.dart';

void main() {
  late Directory dir;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('recapture_permflow_persist');
    Hive.init(dir.path);
  });

  tearDown(() async {
    await Hive.deleteFromDisk();
    if (dir.existsSync()) await dir.delete(recursive: true);
  });

  Future<void> simulateRestart() async {
    await Hive.close();
    Hive.init(dir.path);
  }

  test('empty flow state → after restart still safe first-run, no error',
      () async {
    expect(await PermissionFlowBox().get(AppPermissionType.camera),
        PermissionFlowState.initial);

    await simulateRestart();

    expect(await PermissionFlowBox().get(AppPermissionType.camera),
        PermissionFlowState.initial);
  });

  test('asked + skipped flags survive a restart intact', () async {
    final box = PermissionFlowBox();
    await box.markAsked(AppPermissionType.camera);
    await box.markSkipped(AppPermissionType.motion);

    await simulateRestart();

    final reopened = PermissionFlowBox();
    expect(await reopened.get(AppPermissionType.camera),
        const PermissionFlowState(hasBeenAsked: true));
    expect(await reopened.get(AppPermissionType.motion),
        const PermissionFlowState(userSkipped: true));
    // Untouched permission stays at the safe default after restart.
    expect(await reopened.get(AppPermissionType.photos),
        PermissionFlowState.initial);
  });
}
