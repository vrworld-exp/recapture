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
import 'package:recapture/data/repositories/live_projects_repository.dart';
import 'package:recapture/domain/entities/live_project.dart';
import 'package:recapture/domain/entities/preview_manifest.dart';
import 'package:recapture/domain/entities/project_model.dart';
import 'package:recapture/presentation/screens/projects/preview_gallery_screen.dart';
import 'repo_fake_defaults.dart';

class _FakeRepo
    with
        FakeModelGenerationDefaults,
        FakeAdminDeleteDefaults,
        FakeAutoGenerationDefaults,
        FakeModelOptimizeDefaults,
        FakeOwnerModelListDefaults
    implements LiveProjectsRepository {
  Map<String, dynamic> exportResult = const {};
  LiveProjectsException? exportFail;
  int exportCalls = 0;
  PreviewDeleteResult deleteResult =
      const PreviewDeleteResult(deleted: [], missing: []);

  /// The keys of every createModel call — the CTA now issues the request
  /// itself, so this is what proves nothing sits between selection and Meshy.
  final List<List<String>> createdKeys = [];

  static const _queued = ProjectModelView(
    id: 'm1',
    source: ModelSource.meshy,
    status: ModelStatus.queued,
  );

  @override
  Future<LiveProjectsPage> list({int limit = 20, String? cursor}) async =>
      const LiveProjectsPage(items: [], nextCursor: null);

  @override
  Future<ProjectModelView> createModel(
    String projectId,
    List<String> keys, {
    required String idempotencyKey,
  }) async {
    createdKeys.add(keys);
    return _queued;
  }

  // The generation screen the CTA pushes polls this straight away.
  @override
  Future<List<ProjectModelView>> listModels(String projectId) async =>
      const [_queued];

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

Map<String, dynamic> _manifest(List<String> keys, {String expiresAt = '2099-01-01T00:00:00.000Z'}) => {
      'expiresAt': expiresAt,
      'fileCount': keys.length,
      'expectedFileCount': keys.length,
      'files': [
        for (final k in keys)
          {'key': k, 'url': 'https://signed/$k', 'size': 100},
      ],
    };

Widget _app(
  _FakeRepo repo,
  _RecordingDownloader dl, {
  required bool admin,
  bool staff = true,
}) {
  return ProviderScope(
    overrides: [
      liveProjectsRepositoryProvider.overrideWithValue(repo),
      previewDownloaderProvider.overrideWithValue(dl),
      isAdminProvider.overrideWithValue(admin),
      // Required, not optional: the screen's Create Model action watches this,
      // and the real provider chain reads the role from Hive — unopened in a
      // widget test, so leaving it un-overridden throws before anything renders.
      isStaffProvider.overrideWithValue(staff),
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

  testWidgets('Download refreshes an expired manifest, then downloads fresh url',
      (tester) async {
    // Manifest already expired → the download must re-fetch (freshPhotoFor)
    // before handing the photo to the downloader, so no dead url is used.
    final repo = _FakeRepo()
      ..exportResult =
          _manifest(['images/EYE/a.jpg'], expiresAt: '2000-01-01T00:00:00.000Z');
    final dl = _RecordingDownloader();

    await tester.pumpWidget(_app(repo, dl, admin: false));
    await tester.pump();
    expect(repo.exportCalls, 1);

    await tester.tap(find.byKey(const ValueKey('preview_tile_images/EYE/a.jpg')));
    await tester.pumpAndSettle();

    await tester.tap(find.widgetWithText(ElevatedButton, 'Download'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 10));

    // Re-fetched once (the refresh) and still downloaded the same key.
    expect(repo.exportCalls, 2);
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

  testWidgets(
      'Create Model goes straight to the generation screen — no editing step',
      (tester) async {
    const keys = ['images/EYE/a.jpg', 'images/EYE/b.jpg', 'images/TOP/c.jpg'];
    final repo = _FakeRepo()..exportResult = _manifest(keys);

    await tester.pumpWidget(_app(repo, _RecordingDownloader(), admin: false));
    await tester.pump();

    await tester.tap(find.byKey(const ValueKey('preview_select_toggle')));
    await tester.pump();
    for (final k in keys) {
      await tester.tap(find.byKey(ValueKey('preview_tile_$k')));
      await tester.pump();
    }

    await tester.tap(find.byKey(const ValueKey('create_model_cta')));
    // Not pumpAndSettle: the pushed generation screen spins forever.
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }

    // The request carried exactly the picked keys, in manifest order…
    expect(repo.createdKeys, [keys]);
    // …and the removed Prepare-Images step never appeared in between.
    expect(find.byKey(const ValueKey('prep_generate_cta')), findsNothing);
    expect(find.byKey(const ValueKey('prep_save_edit')), findsNothing);
    expect(find.byKey(const ValueKey('model_gen_pending')), findsOneWidget);
  });
}
