// test/projects/preview_gallery_screen_test.dart
//
// Preview gallery screen: renders one tile per listed photo; maps failures to
// friendly copy (never a raw code/URL); the full-screen viewer's Download
// invokes the download seam exactly once; Delete (admin) confirms, removes the
// tile locally, and never re-requests the listing.
//
// The grid loads from the credential-free `/photos` listing, so RENDERING must
// never call export — several assertions below pin that, because drawing
// thumbnails from presigned export urls is exactly what exhausted the server's
// export rate limit.
//
// Hermetic: fake repo + fake downloader + a Dio that rejects every request, so
// the proxy-backed thumbnails resolve to their error placeholder without
// touching the network. Tile taps hit the GestureDetector, which exists
// regardless of image state.
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:recapture/app/theme/app_theme.dart';
import 'package:recapture/application/auth/user_role_notifier.dart';
import 'package:recapture/application/projects/preview_download_service.dart';
import 'package:recapture/data/remote/api_client.dart';
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
        FakeOwnerModelListDefaults,
        FakeModelSubmissionDefaults
    implements LiveProjectsRepository {
  Map<String, dynamic> photosResult = const {};
  LiveProjectsException? photosFail;
  int photosCalls = 0;

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
  Future<Map<String, dynamic>> photos(String projectId) async {
    photosCalls++;
    final fail = photosFail;
    if (fail != null) throw fail;
    return photosResult;
  }

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

/// A client that rejects every request, so proxy-backed thumbnails fail fast to
/// their placeholder instead of reaching the network from a widget test.
Dio _offlineDio() {
  final dio = Dio();
  dio.interceptors.add(InterceptorsWrapper(
    onRequest: (options, handler) => handler.reject(
      DioException(requestOptions: options, message: 'offline (widget test)'),
    ),
  ));
  return dio;
}

class _RecordingDownloader implements PreviewDownloader {
  final List<String> downloaded = [];

  @override
  Future<void> download(PreviewPhoto photo) async => downloaded.add(photo.key);
}

/// The credential-free `/photos` payload the grid loads from.
Map<String, dynamic> _photos(List<String> keys) => {
      'fileCount': keys.length,
      'expectedFileCount': keys.length,
      'files': [
        for (final k in keys) {'key': k, 'size': 100},
      ],
    };

/// The rate-limited `/export` payload, minted only by Download.
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
      // The tiles resolve their bytes through this client; the real one would
      // read a base url from dotenv (unloaded in tests) and throw on build.
      dioProvider.overrideWithValue(_offlineDio()),
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
  testWidgets('renders one tile per listed photo, minting no export urls',
      (tester) async {
    final repo = _FakeRepo()
      ..photosResult = _photos(['images/EYE/a.jpg', 'images/EYE/b.jpg', 'images/TOP/c.jpg']);

    await tester.pumpWidget(_app(repo, _RecordingDownloader(), admin: false));
    await tester.pump(); // resolve the async listing load
    // Let each tile's (rejected) image request settle — the offline Dio resolves
    // on a microtask timer that would otherwise still be pending at test end.
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('preview_tile_images/EYE/a.jpg')), findsOneWidget);
    expect(find.byKey(const ValueKey('preview_tile_images/EYE/b.jpg')), findsOneWidget);
    expect(find.byKey(const ValueKey('preview_tile_images/TOP/c.jpg')), findsOneWidget);
    expect(find.text('3 photos'), findsOneWidget);
    // The whole point of the listing endpoint: drawing the grid is free.
    expect(repo.exportCalls, 0);
  });

  testWidgets('maps notExportable to friendly copy (no raw code/URL)',
      (tester) async {
    final repo = _FakeRepo()
      ..photosFail =
          const LiveProjectsException(LiveProjectsFailure.notExportable);

    await tester.pumpWidget(_app(repo, _RecordingDownloader(), admin: false));
    await tester.pump();

    expect(find.textContaining('no finished upload to preview'), findsOneWidget);
  });

  testWidgets('maps network failure to offline copy', (tester) async {
    final repo = _FakeRepo()
      ..photosFail = const LiveProjectsException(LiveProjectsFailure.network);

    await tester.pumpWidget(_app(repo, _RecordingDownloader(), admin: false));
    await tester.pump();

    expect(find.textContaining('offline'), findsOneWidget);
  });

  testWidgets('viewer Download invokes the download seam exactly once',
      (tester) async {
    final repo = _FakeRepo()
      ..photosResult = _photos(['images/EYE/a.jpg'])
      ..exportResult = _manifest(['images/EYE/a.jpg']);
    final dl = _RecordingDownloader();

    await tester.pumpWidget(_app(repo, dl, admin: false));
    await tester.pump();

    await tester.tap(find.byKey(const ValueKey('preview_tile_images/EYE/a.jpg')));
    await tester.pumpAndSettle(); // viewer route opens

    await tester.tap(find.widgetWithText(ElevatedButton, 'Download'));
    await tester.pump();

    expect(dl.downloaded, ['images/EYE/a.jpg']);
  });

  testWidgets('Download mints an export url for the listed photo', (tester) async {
    // A listed photo carries no url, so Download must resolve one
    // (freshPhotoFor) before handing the photo to the downloader — that call is
    // the ONLY thing in this screen allowed to spend the export budget.
    final repo = _FakeRepo()
      ..photosResult = _photos(['images/EYE/a.jpg'])
      ..exportResult = _manifest(['images/EYE/a.jpg']);
    final dl = _RecordingDownloader();

    await tester.pumpWidget(_app(repo, dl, admin: false));
    await tester.pump();
    expect(repo.exportCalls, 0, reason: 'browsing spent nothing');

    await tester.tap(find.byKey(const ValueKey('preview_tile_images/EYE/a.jpg')));
    await tester.pumpAndSettle();

    await tester.tap(find.widgetWithText(ElevatedButton, 'Download'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 10));

    // Exactly one manifest minted, and the right key delivered.
    expect(repo.exportCalls, 1);
    expect(dl.downloaded, ['images/EYE/a.jpg']);
  });

  testWidgets('non-admin sees no Delete in the viewer', (tester) async {
    final repo = _FakeRepo()..photosResult = _photos(['images/EYE/a.jpg']);

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
      ..photosResult = _photos(['images/EYE/a.jpg', 'images/EYE/b.jpg'])
      ..deleteResult =
          const PreviewDeleteResult(deleted: ['images/EYE/a.jpg'], missing: []);

    await tester.pumpWidget(_app(repo, _RecordingDownloader(), admin: true));
    await tester.pump();
    expect(repo.photosCalls, 1);

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
    // Nothing was re-requested after the delete.
    expect(repo.photosCalls, 1);
    expect(repo.exportCalls, 0);
  });

  testWidgets(
      'Create Model goes straight to the generation screen — no editing step',
      (tester) async {
    const keys = ['images/EYE/a.jpg', 'images/EYE/b.jpg', 'images/TOP/c.jpg'];
    final repo = _FakeRepo()..photosResult = _photos(keys);

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
