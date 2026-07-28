// test/projects/model_generation_test.dart
//
// The client half of the Meshy "Create Model" flow:
//   • the Preview gallery's selection gate — the CTA is live ONLY at 3–4 photos
//     (mirroring the server's authority), so a staff user can't spend credits on
//     a selection the backend will reject;
//   • the generation status view's pending → succeeded/failed transitions;
//   • the viewer's origin badge, driven by `source` alone.
//
// Hermetic: fake repo, no network. Images/ModelViewer are never loaded — taps
// hit the GestureDetector/button, which exist regardless of network state.
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image/image.dart' as img;
import 'package:recapture/app/theme/app_theme.dart';
import 'package:recapture/application/auth/user_role_notifier.dart';
import 'package:recapture/application/projects/image_prep_image_loader.dart';
import 'package:recapture/application/projects/preview_download_service.dart';
import 'package:recapture/data/repositories/live_projects_repository.dart';
import 'package:recapture/domain/entities/live_project.dart';
import 'package:recapture/domain/entities/preview_manifest.dart';
import 'package:recapture/domain/entities/project_model.dart';
import 'package:recapture/presentation/screens/projects/model_generation_screen.dart';
import 'package:recapture/presentation/screens/projects/model_viewer_screen.dart';
import 'package:recapture/presentation/screens/projects/preview_gallery_screen.dart';

import 'repo_fake_defaults.dart';

class _FakeRepo
    with FakeAdminDeleteDefaults,
        FakeModelImageUploadDefaults,
        FakeAutoGenerationDefaults
    implements LiveProjectsRepository {
  _FakeRepo({this.models = const []});

  Map<String, dynamic> exportResult = const {};
  List<ProjectModelView> models;

  /// Every createModel call, as (keys, idempotencyKey).
  final List<(List<String>, String)> created = [];
  LiveProjectsException? createFail;

  @override
  Future<LiveProjectsPage> list({int limit = 20, String? cursor}) async =>
      const LiveProjectsPage(items: [], nextCursor: null);

  @override
  Future<Map<String, dynamic>> export(String projectId) async => exportResult;

  @override
  Future<PreviewDeleteResult> deletePhotos(String p, List<String> k) async =>
      const PreviewDeleteResult(deleted: [], missing: []);

  @override
  Future<ProjectModelView> createModel(
    String projectId,
    List<String> keys, {
    required String idempotencyKey,
  }) async {
    created.add((keys, idempotencyKey));
    final fail = createFail;
    if (fail != null) throw fail;
    final model = ProjectModelView(
      id: 'm1',
      source: ModelSource.meshy,
      status: ModelStatus.queued,
    );
    models = [model];
    return model;
  }

  @override
  Future<List<ProjectModelView>> listModels(String projectId) async => models;

  @override
  Future<ProjectModelView> approveModel(String p, String modelId) async =>
      throw UnimplementedError('not used here');
}

class _NoopDownloader implements PreviewDownloader {
  @override
  Future<void> download(PreviewPhoto photo) async {}
}

/// Prepare-Images sits between selection and the create request now — feed it
/// a real (tiny) PNG plus its dimensions so Generate enables.
class _FakePrepLoader implements PrepImageLoader {
  static final Uint8List _png = Uint8List.fromList(
    img.encodePng(img.Image(width: 8, height: 6, numChannels: 3)),
  );

  @override
  Future<LoadedPrepImage> load(String projectId, PreviewPhoto photo) async =>
      LoadedPrepImage(bytes: _png, width: 8, height: 6);
}

Map<String, dynamic> _manifest(List<String> keys) => {
      'expiresAt': '2099-01-01T00:00:00.000Z',
      'fileCount': keys.length,
      'expectedFileCount': keys.length,
      'files': [
        for (final k in keys)
          {'key': k, 'url': 'https://signed/$k', 'size': 100},
      ],
    };

/// [instance] forces a genuinely fresh tree when a test pumps the gallery more
/// than once: without a differing key, pumpWidget reuses the element tree and
/// the previously pushed route (and its endless spinner) survives.
Widget _gallery(_FakeRepo repo, {bool staff = true, int instance = 0}) =>
    ProviderScope(
      key: ValueKey('gallery_$instance'),
      overrides: [
        liveProjectsRepositoryProvider.overrideWithValue(repo),
        previewDownloaderProvider.overrideWithValue(_NoopDownloader()),
        prepImageLoaderProvider.overrideWithValue(_FakePrepLoader()),
        isStaffProvider.overrideWithValue(staff),
        isAdminProvider.overrideWithValue(false),
      ],
      child: MaterialApp(
        theme: AppTheme.dark,
        home: const PreviewGalleryScreen(projectId: 'p1'),
      ),
    );

/// The default 800x600 test surface puts the grid's second row under the
/// Create Model bar, so taps there land on the bar instead of the tile. Give
/// the gallery tests room rather than making the assertions dodge the layout.
void _useRoomySurface(WidgetTester tester) {
  tester.view.physicalSize = const Size(1000, 2000);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

/// Taps into selection mode and picks [n] tiles.
Future<void> _select(WidgetTester tester, List<String> keys, int n) async {
  await tester.tap(find.byKey(const ValueKey('preview_select_toggle')));
  await tester.pump();
  for (var i = 0; i < n; i++) {
    await tester.tap(find.byKey(ValueKey('preview_tile_${keys[i]}')));
    await tester.pump();
  }
}

/// Taps Create Model — which now opens Prepare-Images — then taps Generate
/// there without editing anything, and lets the request + navigation resolve.
///
/// Deliberately NOT pumpAndSettle: a successful create pushes the generation
/// status screen, whose progress indicator animates forever — settling would
/// time out rather than tell us anything.
Future<void> _tapCreate(WidgetTester tester) async {
  await tester.tap(find.byKey(const ValueKey('create_model_cta')));
  // Prepare-Images push + photo loads. Safe to settle: nothing loops once
  // the (fake) loads land.
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(const ValueKey('prep_generate_cta')));
  for (var i = 0; i < 6; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

const _keys = [
  'images/EYE/a.jpg',
  'images/EYE/b.jpg',
  'images/TOP/c.jpg',
  'images/TOP/d.jpg',
  'images/LOW/e.jpg',
];

void main() {
  group('Preview gallery — Create Model selection gate', () {
    testWidgets('the CTA is hidden for a non-staff caller', (tester) async {
      final repo = _FakeRepo()..exportResult = _manifest(_keys);
      _useRoomySurface(tester);
      await tester.pumpWidget(_gallery(repo, staff: false));
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('preview_select_toggle')), findsNothing);
    });

    testWidgets('below 3 selected the CTA stays disabled and nothing is sent',
        (tester) async {
      final repo = _FakeRepo()..exportResult = _manifest(_keys);
      _useRoomySurface(tester);
      await tester.pumpWidget(_gallery(repo));
      await tester.pumpAndSettle();

      await _select(tester, _keys, 2);

      // The hint says WHY rather than leaving a dead button.
      expect(
        find.text('Select 3–4 photos from different angles (2 selected)'),
        findsOneWidget,
      );
      await tester.tap(find.byKey(const ValueKey('create_model_cta')));
      await tester.pump();
      expect(repo.created, isEmpty);
    });

    testWidgets('at 3 selected the CTA sends exactly the picked keys',
        (tester) async {
      final repo = _FakeRepo()..exportResult = _manifest(_keys);
      _useRoomySurface(tester);
      await tester.pumpWidget(_gallery(repo));
      await tester.pumpAndSettle();

      await _select(tester, _keys, 3);
      expect(find.text('3 of 4 selected'), findsOneWidget);

      await _tapCreate(tester);

      expect(repo.created, hasLength(1));
      expect(repo.created.first.$1, _keys.take(3));
      // An Idempotency-Key always rides along — it is what stops a double-tap
      // from paying for a second generation.
      expect(repo.created.first.$2, isNotEmpty);
    });

    testWidgets('a 5th tap cannot exceed the 4-photo maximum', (tester) async {
      final repo = _FakeRepo()..exportResult = _manifest(_keys);
      _useRoomySurface(tester);
      await tester.pumpWidget(_gallery(repo));
      await tester.pumpAndSettle();

      await _select(tester, _keys, 5);

      // The 5th selection is refused rather than silently replacing one.
      expect(find.text('4 of 4 selected'), findsOneWidget);
      await _tapCreate(tester);
      expect(repo.created.first.$1, hasLength(4));
    });

    testWidgets('the same selection always yields the SAME idempotency key',
        (tester) async {
      final repo = _FakeRepo()..exportResult = _manifest(_keys);

      // Two independent visits to the gallery, picking the same three photos —
      // the key must depend only on (project, selection), never on screen
      // state, or a retry after a dropped response would pay twice.
      for (var visit = 0; visit < 2; visit++) {
        _useRoomySurface(tester);
        await tester.pumpWidget(_gallery(repo, instance: visit));
        await tester.pumpAndSettle();
        await _select(tester, _keys, 3);
        await _tapCreate(tester);
      }

      expect(repo.created, hasLength(2));
      expect(repo.created[0].$2, repo.created[1].$2);
    });

    testWidgets('a failed create shows mapped copy, never a raw error',
        (tester) async {
      final repo = _FakeRepo()
        ..exportResult = _manifest(_keys)
        ..createFail =
            const LiveProjectsException(LiveProjectsFailure.rateLimited);
      _useRoomySurface(tester);
      await tester.pumpWidget(_gallery(repo));
      await tester.pumpAndSettle();

      await _select(tester, _keys, 3);
      await _tapCreate(tester);

      expect(find.textContaining('limit reached'), findsOneWidget);
      expect(find.textContaining('LiveProjectsException'), findsNothing);
    });
  });

  group('ModelGenerationScreen — status transitions', () {
    Widget app(_FakeRepo repo) => ProviderScope(
          overrides: [
            liveProjectsRepositoryProvider.overrideWithValue(repo),
            isStaffProvider.overrideWithValue(true),
          ],
          child: MaterialApp(
            theme: AppTheme.dark,
            home: const ModelGenerationScreen(projectId: 'p1', modelId: 'm1'),
          ),
        );

    testWidgets('a PROCESSING record shows progress, not a CTA',
        (tester) async {
      final repo = _FakeRepo(models: [
        const ProjectModelView(
          id: 'm1',
          source: ModelSource.meshy,
          status: ModelStatus.processing,
        ),
      ]);
      await tester.pumpWidget(app(repo));
      await tester.pump();

      expect(find.byKey(const ValueKey('model_gen_pending')), findsOneWidget);
      expect(find.byKey(const ValueKey('view_model_cta')), findsNothing);
    });

    testWidgets('a PROCESSING record with live progress shows the percent',
        (tester) async {
      final repo = _FakeRepo(models: [
        const ProjectModelView(
          id: 'm1',
          source: ModelSource.meshy,
          status: ModelStatus.processing,
          progress: ModelProgress(
            phase: ModelProgressPhase.generating,
            percent: 42,
          ),
        ),
      ]);
      await tester.pumpWidget(app(repo));
      await tester.pump();

      expect(find.byKey(const ValueKey('model_gen_percent')), findsOneWidget);
      expect(find.text('42%'), findsOneWidget);
      // The timeline names the step that is running right now.
      expect(find.text('Generating 3D model'), findsOneWidget);
    });

    testWidgets('a SUCCEEDED record offers View 3D Model', (tester) async {
      final repo = _FakeRepo(models: [
        const ProjectModelView(
          id: 'm1',
          source: ModelSource.meshy,
          status: ModelStatus.succeeded,
          glbUrl: 'https://cdn/model.glb',
        ),
      ]);
      await tester.pumpWidget(app(repo));
      await tester.pump();

      expect(find.byKey(const ValueKey('view_model_cta')), findsOneWidget);
      expect(find.byKey(const ValueKey('model_gen_pending')), findsNothing);
    });

    testWidgets('a FAILED record shows mapped copy + a way back',
        (tester) async {
      final repo = _FakeRepo(models: [
        const ProjectModelView(
          id: 'm1',
          source: ModelSource.meshy,
          status: ModelStatus.failed,
        ),
      ]);
      await tester.pumpWidget(app(repo));
      await tester.pump();

      expect(find.byKey(const ValueKey('model_gen_failed')), findsOneWidget);
      expect(find.text('Choose photos again'), findsOneWidget);
    });

    testWidgets('follows ITS OWN record, not merely the newest',
        (tester) async {
      // A regenerate is in flight (m2, newest) while m1 already succeeded — the
      // screen was opened for m1 and must keep showing m1.
      final repo = _FakeRepo(models: [
        const ProjectModelView(
          id: 'm2',
          source: ModelSource.meshy,
          status: ModelStatus.processing,
        ),
        const ProjectModelView(
          id: 'm1',
          source: ModelSource.meshy,
          status: ModelStatus.succeeded,
          glbUrl: 'https://cdn/model.glb',
        ),
      ]);
      await tester.pumpWidget(app(repo));
      await tester.pump();

      expect(find.byKey(const ValueKey('view_model_cta')), findsOneWidget);
    });
  });

  group('ModelViewerScreen — the origin badge', () {
    // The real renderer is a WebView, which has no platform implementation in a
    // widget test — inject a stand-in so the screen's own chrome is testable.
    Widget app(ProjectModelView model) => ProviderScope(
          // The screen's Export action watches the role — without this
          // override the real userRoleProvider chain would open Hive.
          overrides: [isStaffProvider.overrideWithValue(false)],
          child: MaterialApp(
            theme: AppTheme.dark,
            home: ModelViewerScreen(
              model: model,
              renderBuilder: (_, m) => Text('rendering ${m.glbUrl}'),
            ),
          ),
        );

    testWidgets('a meshy model is badged "Created by Maya AI"',
        (tester) async {
      await tester.pumpWidget(app(const ProjectModelView(
        id: 'm1',
        source: ModelSource.meshy,
        status: ModelStatus.succeeded,
        glbUrl: 'https://cdn/model.glb',
      )));
      await tester.pump();

      expect(find.text('Created by Maya AI'), findsOneWidget);
    });

    testWidgets('a manual model carries no Meshy attribution', (tester) async {
      await tester.pumpWidget(app(const ProjectModelView(
        id: 'm1',
        source: ModelSource.manual,
        status: ModelStatus.succeeded,
        glbUrl: 'https://cdn/model.glb',
      )));
      await tester.pump();

      expect(find.text('Created by Maya AI'), findsNothing);
    });
  });
}
