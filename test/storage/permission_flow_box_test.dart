// test/storage/permission_flow_box_test.dart
//
// Unit tests for the Hive-backed PermissionFlowBox: safe defaults, markAsked/
// markSkipped persistence, corrupt-record resilience, and the invariant that NO
// grant status is ever stored (the OS is the authority).

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:recapture/data/local/box_names.dart';
import 'package:recapture/data/local/permission_flow_box.dart';
import 'package:recapture/domain/entities/permission_flow_state.dart';
import 'package:recapture/domain/entities/permission_item.dart';

void main() {
  late Directory dir;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('recapture_permflow_test');
    Hive.init(dir.path);
  });

  tearDown(() async {
    await Hive.deleteFromDisk();
    if (dir.existsSync()) await dir.delete(recursive: true);
  });

  test('fresh install → safe first-run defaults (not asked, not skipped)',
      () async {
    final box = PermissionFlowBox();
    for (final type in AppPermissionType.values) {
      expect(await box.get(type), PermissionFlowState.initial);
      expect((await box.get(type)).hasBeenAsked, isFalse);
      expect((await box.get(type)).userSkipped, isFalse);
    }
  });

  test('markAsked persists only hasBeenAsked', () async {
    final box = PermissionFlowBox();
    await box.markAsked(AppPermissionType.camera);

    final state = await box.get(AppPermissionType.camera);
    expect(state.hasBeenAsked, isTrue);
    expect(state.userSkipped, isFalse);
    // Other permissions are untouched.
    expect(await box.get(AppPermissionType.motion),
        PermissionFlowState.initial);
  });

  test('markSkipped persists only userSkipped; flags are independent', () async {
    final box = PermissionFlowBox();
    await box.markSkipped(AppPermissionType.motion);
    expect(await box.get(AppPermissionType.motion),
        const PermissionFlowState(userSkipped: true));

    // Asking afterwards keeps the skip flag (read-modify-write, no clobber).
    await box.markAsked(AppPermissionType.motion);
    expect(await box.get(AppPermissionType.motion),
        const PermissionFlowState(hasBeenAsked: true, userSkipped: true));
  });

  test('no grant status is ever serialized', () async {
    final box = PermissionFlowBox();
    await box.markAsked(AppPermissionType.camera);
    await box.markSkipped(AppPermissionType.photos);

    // Inspect the raw stored JSON directly — it must hold only flow flags.
    final raw = Hive.box<String>(BoxNames.permissionFlow);
    for (final key in ['camera', 'photos']) {
      final json = raw.get(key)!;
      expect(json, isNot(contains('grant')));
      expect(json, isNot(contains('status')));
      expect(json, contains('hasBeenAsked'));
      expect(json, contains('userSkipped'));
    }
  });

  test('corrupt record → safe default, no throw', () async {
    // Write garbage directly under a permission key.
    final raw = await Hive.openBox<String>(BoxNames.permissionFlow);
    await raw.put('camera', 'not-json{{{');

    final box = PermissionFlowBox();
    expect(await box.get(AppPermissionType.camera),
        PermissionFlowState.initial);
  });

  test('clear() resets all flow state', () async {
    final box = PermissionFlowBox();
    await box.markAsked(AppPermissionType.camera);
    await box.markSkipped(AppPermissionType.motion);

    await box.clear();

    for (final type in AppPermissionType.values) {
      expect(await box.get(type), PermissionFlowState.initial);
    }
  });
}
