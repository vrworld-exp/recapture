// test/persistence/auto_capture_persistence_test.dart
//
// Proves the Level A auto-capture preference round-trips and survives a cold
// restart (close Hive WITHOUT deleting, re-init on the SAME temp path, reopen).
// Mirrors the permission-flow persistence test. (No TypeAdapters — JSON-ish
// string values.)
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:recapture/data/local/auto_capture_box.dart';

void main() {
  late Directory dir;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('recapture_autocap_persist');
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

  test('no stored preference → null (caller defaults)', () async {
    expect(await AutoCaptureBox().getEnabled(), isNull);
  });

  test('false survives a restart', () async {
    await AutoCaptureBox().setEnabled(false);
    await simulateRestart();
    expect(await AutoCaptureBox().getEnabled(), isFalse);
  });

  test('true survives a restart', () async {
    await AutoCaptureBox().setEnabled(true);
    await simulateRestart();
    expect(await AutoCaptureBox().getEnabled(), isTrue);
  });

  test('last write wins', () async {
    final box = AutoCaptureBox();
    await box.setEnabled(true);
    await box.setEnabled(false);
    await box.setEnabled(true);
    await simulateRestart();
    expect(await AutoCaptureBox().getEnabled(), isTrue);
  });
}
