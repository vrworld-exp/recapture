// test/projects/project_export_service_test.dart
//
// P7-A export action: the service fetches the manifest, writes it to a temp
// file (export_<projectId>_<ts>.json), and invokes the share seam with that
// file; failures (409 NOT_EXPORTABLE etc.) propagate as the translated
// exception WITHOUT writing or sharing anything. Hermetic: fake repository +
// fake share launcher + a real temp dir cleaned up in teardown.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:recapture/application/projects/project_export_service.dart';
import 'package:recapture/data/repositories/live_projects_repository.dart';
import 'package:recapture/domain/entities/live_project.dart';
import 'package:recapture/utils/analytics.dart';

class _FakeLiveRepo implements LiveProjectsRepository {
  Map<String, dynamic>? exportResult;
  LiveProjectsException? failWith;
  final List<String> exportedIds = [];

  @override
  Future<LiveProjectsPage> list({int limit = 20, String? cursor}) async =>
      const LiveProjectsPage(items: [], nextCursor: null);

  @override
  Future<Map<String, dynamic>> export(String projectId) async {
    exportedIds.add(projectId);
    final fail = failWith;
    if (fail != null) throw fail;
    return exportResult!;
  }
}

class _RecordingShare implements ShareLauncher {
  final List<String> sharedPaths = [];

  @override
  Future<void> shareFile(String path, {String? subject}) async {
    sharedPaths.add(path);
  }
}

void main() {
  late _FakeLiveRepo repo;
  late _RecordingShare share;
  late Directory tempDir;
  late ProjectExportService service;
  final events = <(String, Map<String, Object?>)>[];

  setUp(() async {
    repo = _FakeLiveRepo();
    share = _RecordingShare();
    tempDir = await Directory.systemTemp.createTemp('export_test');
    service = ProjectExportService(
      repository: repo,
      share: share,
      tempDirPath: () async => tempDir.path,
      now: () => DateTime.utc(2026, 7, 13, 12),
    );
    events.clear();
    Analytics.testSink = (name, props) => events.add((name, props));
  });

  tearDown(() async {
    Analytics.testSink = null;
    await tempDir.delete(recursive: true);
  });

  test('writes the manifest JSON to a temp file and shares it', () async {
    repo.exportResult = {
      'projectId': 'p1',
      'jobId': 'j1',
      'generatedAt': '2026-07-13T12:00:00.000Z',
      'expiresAt': '2026-07-13T13:00:00.000Z',
      'fileCount': 37,
      'expectedFileCount': 37,
      'files': [
        {'key': 'capture_manifest.json', 'url': 'https://signed/1', 'size': 2048},
        {'key': 'images/EYE/eye_0001.jpg', 'url': 'https://signed/2', 'size': 9},
      ],
    };

    final result = await service.exportProject('p1');

    expect(repo.exportedIds, ['p1']);
    expect(result.fileCount, 37);
    expect(result.expiresAt, DateTime.utc(2026, 7, 13, 13));

    // The shared file IS the manifest, named export_<projectId>_<ts>.json.
    expect(share.sharedPaths, hasLength(1));
    expect(share.sharedPaths.single, result.filePath);
    expect(result.filePath, contains('export_p1_'));
    expect(result.filePath, endsWith('.json'));
    final written = jsonDecode(File(result.filePath).readAsStringSync());
    expect(written, repo.exportResult);

    // Analytics: a count only — never ids or presigned URLs.
    expect(events, hasLength(1));
    expect(events.single.$1, 'project_export_requested');
    expect(events.single.$2, {'file_count': 37});
  });

  test('NOT_EXPORTABLE propagates; nothing is written or shared', () async {
    repo.failWith =
        const LiveProjectsException(LiveProjectsFailure.notExportable);

    await expectLater(
      service.exportProject('p2'),
      throwsA(isA<LiveProjectsException>().having(
        (e) => e.failure,
        'failure',
        LiveProjectsFailure.notExportable,
      )),
    );

    expect(share.sharedPaths, isEmpty);
    expect(tempDir.listSync(), isEmpty);
    expect(events, isEmpty);
  });
}
