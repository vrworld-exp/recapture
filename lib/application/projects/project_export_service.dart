// lib/application/projects/project_export_service.dart
//
// The staff "Export" action: fetch the presigned-URL export manifest for a
// live project, write it to a temp file (export_<projectId>_<ts>.json), and
// hand it to the platform share sheet so the artist can move it to their
// desktop (AirDrop/Drive/email) and pull the files with curl/scripts there.
//
// The share plugin sits behind [ShareLauncher] so tests stay hermetic, and
// the manifest JSON (which contains presigned URLs — bearer credentials) is
// only ever written to the file being shared: never logged, never put in
// analytics.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../../data/repositories/live_projects_repository.dart';
import '../../utils/analytics.dart';

/// Seam over the platform share sheet (production: share_plus).
abstract interface class ShareLauncher {
  Future<void> shareFile(String path, {String? subject});
}

/// share_plus-backed [ShareLauncher].
class SharePlusLauncher implements ShareLauncher {
  const SharePlusLauncher();

  @override
  Future<void> shareFile(String path, {String? subject}) async {
    await SharePlus.instance.share(ShareParams(
      files: [XFile(path, mimeType: 'application/json')],
      subject: subject,
    ));
  }
}

/// What the UI needs for its confirmation snackbar after a share.
class ProjectExportResult {
  const ProjectExportResult({
    required this.fileCount,
    required this.expiresAt,
    required this.filePath,
  });

  final int fileCount;

  /// When the manifest's presigned URLs stop working (null if unparsable).
  final DateTime? expiresAt;

  final String filePath;
}

/// Orchestrates one export: manifest → temp file → share sheet.
class ProjectExportService {
  ProjectExportService({
    required LiveProjectsRepository repository,
    required ShareLauncher share,
    required Future<String> Function() tempDirPath,
    DateTime Function()? now,
  })  : _repository = repository,
        _share = share,
        _tempDirPath = tempDirPath,
        _now = now ?? DateTime.now;

  final LiveProjectsRepository _repository;
  final ShareLauncher _share;
  final Future<String> Function() _tempDirPath;
  final DateTime Function() _now;

  /// Exports [projectId]. Throws [LiveProjectsException] (notExportable /
  /// rateLimited / network / …) — the caller maps it to friendly copy.
  Future<ProjectExportResult> exportProject(String projectId) async {
    final export = await _repository.export(projectId);

    final dir = await _tempDirPath();
    final path =
        '$dir/export_${projectId}_${_now().millisecondsSinceEpoch}.json';
    final file = File(path);
    await file.writeAsString(jsonEncode(export), flush: true);

    await _share.shareFile(path, subject: 'ReCapture capture export');

    final rawCount = export['fileCount'];
    final fileCount = rawCount is num ? rawCount.toInt() : 0;
    // Non-PII by construction: a count only — never ids or URLs (the manifest
    // content stays in the shared file).
    Analytics.logEvent('project_export_requested', {'file_count': fileCount});

    return ProjectExportResult(
      fileCount: fileCount,
      expiresAt: DateTime.tryParse((export['expiresAt'] ?? '').toString()),
      filePath: path,
    );
  }
}

/// App-wide export service (staff-only surface).
final projectExportServiceProvider = Provider<ProjectExportService>(
  (ref) => ProjectExportService(
    repository: ref.watch(liveProjectsRepositoryProvider),
    share: const SharePlusLauncher(),
    tempDirPath: () async => (await getTemporaryDirectory()).path,
  ),
);
