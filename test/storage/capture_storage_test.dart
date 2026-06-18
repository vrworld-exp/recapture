// test/storage/capture_storage_test.dart
//
// Verifies the Dart side of the capture-storage transport: argument forwarding and
// result parsing for accounting, free space, incomplete-job listing, and the
// (guarded) delete hooks.
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:recapture/platform/capture_storage.dart';
import 'package:recapture/utils/constants.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  const channel = MethodChannel(AppConfig.channelCaptureStorage);

  late List<MethodCall> calls;

  void mock(Object? Function(MethodCall) handler) {
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return handler(call);
    });
  }

  setUp(() => calls = []);
  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  test('freeSpaceBytes returns the native value', () async {
    mock((_) => 123456789);
    final v = await CaptureStorageClient(channel).freeSpaceBytes();
    expect(v, 123456789);
    expect(calls.single.method, 'freeSpace');
  });

  test('usage forwards scope args and parses counts', () async {
    mock((_) => {'frameCount': 36, 'byteCount': 9000});
    final u = await CaptureStorageClient(channel)
        .usage('p1', jobId: 'j1', level: '0');
    expect(u.frameCount, 36);
    expect(u.byteCount, 9000);
    expect(calls.single.arguments,
        {'projectId': 'p1', 'jobId': 'j1', 'level': '0'});
  });

  test('usage omits null scope segments', () async {
    mock((_) => {'frameCount': 1, 'byteCount': 2});
    await CaptureStorageClient(channel).usage('p1');
    expect(calls.single.arguments, {'projectId': 'p1'});
  });

  test('listIncompleteJobs parses and filters malformed entries', () async {
    mock((_) => [
          {'projectId': 'p1', 'jobId': 'j1', 'reason': 'in_progress'},
          {'projectId': 'p1', 'jobId': 'j2', 'reason': 'no_manifest'},
          {'jobId': 'missing_project'}, // filtered
        ]);
    final jobs = await CaptureStorageClient(channel).listIncompleteJobs();
    expect(jobs.length, 2);
    expect(jobs[0].jobId, 'j1');
    expect(jobs[0].reason, 'in_progress');
    expect(jobs[1].reason, 'no_manifest');
  });

  test('deleteProject forwards force and parses the result', () async {
    mock((_) => {
          'ok': true,
          'code': 'ok',
          'filesDeleted': 12,
          'bytesFreed': 4096,
        });
    final r =
        await CaptureStorageClient(channel).deleteProject('p1', force: true);
    expect(r.ok, isTrue);
    expect(r.filesDeleted, 12);
    expect(r.bytesFreed, 4096);
    expect(r.guardedByActiveJob, isFalse);
    expect(calls.single.method, 'deleteProject');
    expect(calls.single.arguments, {'projectId': 'p1', 'force': true});
  });

  test('a guarded delete surfaces the active_job code', () async {
    mock((_) => {
          'ok': false,
          'code': 'active_job',
          'filesDeleted': 0,
          'bytesFreed': 0,
        });
    final r = await CaptureStorageClient(channel).deleteJob('p1', 'j1');
    expect(r.ok, isFalse);
    expect(r.guardedByActiveJob, isTrue);
    expect(calls.single.arguments,
        {'projectId': 'p1', 'jobId': 'j1', 'force': false});
  });

  test('purgeProjectCaptureData forwards args and parses an ok result', () async {
    mock((_) => {'status': 'ok', 'reclaimedBytes': 4096, 'failed': <String>[]});
    final r = await CaptureStorageClient(channel).purgeProjectCaptureData('p1');
    expect(r.ok, isTrue);
    expect(r.reclaimedBytes, 4096);
    expect(r.failed, isEmpty);
    expect(calls.single.method, 'purgeProjectCaptureData');
    expect(calls.single.arguments, {'projectId': 'p1', 'force': false});
  });

  test('purge parses a partial result with the failed paths', () async {
    mock((_) => {
          'status': 'partial',
          'reclaimedBytes': 10,
          'failed': ['/a/locked.jpg', '/a/locked2.jpg'],
        });
    final r = await CaptureStorageClient(channel)
        .purgeProjectCaptureData('p1', force: true);
    expect(r.isPartial, isTrue);
    expect(r.reclaimedBytes, 10);
    expect(r.failed, ['/a/locked.jpg', '/a/locked2.jpg']);
    expect(calls.single.arguments, {'projectId': 'p1', 'force': true});
  });

  test('purge surfaces a refused (active-job) status', () async {
    mock((_) => {'status': 'refused', 'reclaimedBytes': 0, 'failed': <String>[]});
    final r = await CaptureStorageClient(channel).purgeProjectCaptureData('p1');
    expect(r.refusedByActiveJob, isTrue);
    expect(r.ok, isFalse);
  });

  test('purge surfaces a noop (nothing to purge) status', () async {
    mock((_) => {'status': 'noop', 'reclaimedBytes': 0, 'failed': <String>[]});
    final r = await CaptureStorageClient(channel).purgeProjectCaptureData('gone');
    expect(r.isNoop, isTrue);
  });

  test('sweepOrphanedCaptureData forwards the known list and parses results',
      () async {
    mock((_) => {
          'purgedProjects': ['orphan1', 'orphan2'],
          'reclaimedBytes': 8192,
          'skipped': ['busyOrphan'],
        });
    final r = await CaptureStorageClient(channel)
        .sweepOrphanedCaptureData(['keep1', 'keep2']);
    expect(r.purgedProjects, ['orphan1', 'orphan2']);
    expect(r.reclaimedBytes, 8192);
    expect(r.skipped, ['busyOrphan']);
    expect(calls.single.method, 'sweepOrphanedCaptureData');
    expect(calls.single.arguments,
        {'knownProjectIds': ['keep1', 'keep2'], 'force': false});
  });
}
