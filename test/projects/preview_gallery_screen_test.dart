// test/projects/preview_gallery_screen_test.dart
//
// Preview gallery screen: renders one tile per manifest file; maps failures to
// friendly copy (never a raw code/URL); the full-screen viewer's Download
// invokes the download seam exactly once; Delete (admin) confirms, removes the
// tile locally, and never re-requests the manifest. Hermetic: fake repo + fake
// downloader; images are not loaded (tile taps hit the GestureDetector, which
// exists regardless of network image state).
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:recapture/app/theme/app_theme.dart';
import 'package:recapture/application/auth/user_role_notifier.dart';
import 'package:recapture/application/projects/preview_download_service.dart';
import 'package:recapture/application/projects/preview_gallery_notifier.dart';
import 'package:recapture/data/repositories/live_projects_repository.dart';
import 'package:recapture/domain/entities/live_project.dart';
import 'package:recapture/domain/entities/preview_manifest.dart';
import 'package:recapture/presentation/screens/projects/preview_gallery_screen.dart';

class _FakeRepo implements LiveProjectsRepository {
  Map<String, dynamic> exportResult = const {};
  LiveProjectsException? exportFail;
  int exportCalls = 0;
  PreviewDeleteResult deleteResult =
      const PreviewDeleteResult(deleted: [], missing: []);

  @override
  Future<LiveProjectsPage> list({int limit = 20, String? cursor}) async =>
      const LiveProjectsPage(items: [], nextCursor: null);

  @override
  Future<Map<String, dynamic>> export(String projectId) async {
    exportCalls++;
    final fail = exportFail;
    if (fail != null) throw fail;
    return exportResult;
  }

  @override
  Future<PreviewDeleteResult> deletePhotos(
      String projectId, List<String> keys) async => deleteResult;
}

class _RecordingDownloader implements PreviewDownloader {
  final List<String> downloaded = [];

  @override
  Future<void> download(PreviewPhoto photo) async => downloaded.add(photo.key);
}

Map<String, dynamic> _manifest(List<String> keys) => {
      'expiresAt': '2026-07-15T13:00:00.000Z',
      'fileCount': keys.length,
      'expectedFileCount': keys.length,
      'files': [
        for (final k in keys)
          {'key': k, 'url': 'https://signed/$k', 'size': 100},
      ],
    };

Widget _app(_FakeRepo repo, _RecordingDownloader dl, {required bool admin}) {
  return ProviderScope(
    overrides: [
      liveProjectsRepositoryProvider.overrideWithValue(repo),
      previewDownloaderProvider.overrideWithValue(dl),
      isAdminProvider.overrideWithValue(admin),
    ],
    child: MaterialApp(
      theme: AppTheme.dark,
      home: const PreviewGalleryScreen(projectId: 'p1'),
    ),
  );
}

void main() {
  testWidgets('renders one tile per manifest file', (tester) async {
    final repo = _FakeRepo()
      ..exportResult = _manifest(['images/EYE/a.jpg', 'images/EYE/b.jpg', 'images/TOP/c.jpg']);

    await tester.pumpWidget(_app(repo, _RecordingDownloader(), admin: false));
    await tester.pump(); // resolve the async manifest load

    expect(find.byKey(const ValueKey('preview_tile_images/EYE/a.jpg')), findsOneWidget);
    expect(find.byKey(const ValueKey('preview_tile_images/EYE/b.jpg')), findsOneWidget);
    expect(find.byKey(const ValueKey('preview_tile_images/TOP/c.jpg')), findsOneWidget);
    expect(find.text('3 photos'), findsOneWidget);
  });

  testWidgets('maps notExportable to friendly copy (no raw code/URL)',
      (tester) async {
    final repo = _FakeRepo()
      ..exportFail =
          const LiveProjectsException(LiveProjectsFailure.notExportable);

    await tester.pumpWidget(_app(repo, _RecordingDownloader(), admin: false));
    await tester.pump();

    expect(find.textContaining('no finished upload to preview'), findsOneWidget);
  });

  testWidgets('maps network failure to offline copy', (tester) async {
    final repo = _FakeRepo()
      ..exportFail = const LiveProjectsException(LiveProjectsFailure.network);

    await tester.pumpWidget(_app(repo, _RecordingDownloader(), admin: false));
    await tester.pump();

    expect(find.textContaining('offline'), findsOneWidget);
  });

  testWidgets('viewer Download invokes the download seam exactly once',
      (tester) async {
    final repo = _FakeRepo()..exportResult = _manifest(['images/EYE/a.jpg']);
    final dl = _RecordingDownloader();

    await tester.pumpWidget(_app(repo, dl, admin: false));
    await tester.pump();

    await tester.tap(find.byKey(const ValueKey('preview_tile_images/EYE/a.jpg')));
    await tester.pumpAndSettle(); // viewer route opens

    await tester.tap(find.widgetWithText(ElevatedButton, 'Download'));
    await tester.pump();

    expect(dl.downloaded, ['images/EYE/a.jpg']);
  });

  testWidgets('non-admin sees no Delete in the viewer', (tester) async {
    final repo = _FakeRepo()..exportResult = _manifest(['images/EYE/a.jpg']);

    await tester.pumpWidget(_app(repo, _RecordingDownloader(), admin: false));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('preview_tile_images/EYE/a.jpg')));
    await tester.pumpAndSettle();

    expect(find.widgetWithText(OutlinedButton, 'Delete'), findsNothing);
    expect(find.widgetWithText(ElevatedButton, 'Download'), findsOneWidget);
  });

  testWidgets('admin Delete confirms, removes the tile locally, no re-fetch',
      (tester) async {
    final repo = _FakeRepo()
      ..exportResult = _manifest(['images/EYE/a.jpg', 'images/EYE/b.jpg'])
      ..deleteResult =
          const PreviewDeleteResult(deleted: ['images/EYE/a.jpg'], missing: []);

    await tester.pumpWidget(_app(repo, _RecordingDownloader(), admin: true));
    await tester.pump();
    expect(repo.exportCalls, 1);

    await tester.tap(find.byKey(const ValueKey('preview_tile_images/EYE/a.jpg')));
    await tester.pumpAndSettle();

    // Viewer Delete → platform confirmation dialog → confirm.
    await tester.tap(find.widgetWithText(OutlinedButton, 'Delete'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(TextButton, 'Delete'));
    await tester.pumpAndSettle(); // delete completes, viewer pops

    // The deleted tile is gone; the other remains; count updated.
    expect(find.byKey(const ValueKey('preview_tile_images/EYE/a.jpg')), findsNothing);
    expect(find.byKey(const ValueKey('preview_tile_images/EYE/b.jpg')), findsOneWidget);
    expect(find.text('1 photo'), findsOneWidget);
    // Manifest was NOT re-requested after the delete.
    expect(repo.exportCalls, 1);
  });
}
