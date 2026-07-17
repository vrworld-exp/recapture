// test/projects/model_history_test.dart
//
// The staff model-history surface — the persistent door into generations, which
// are otherwise unreachable once you leave the screen that created them:
//   • the history lists every attempt newest-first, labelled by timestamp;
//   • a record with nothing to show (FAILED / pending / GLB-less SUCCEEDED) is
//     INERT — the whole point of gating on isViewable rather than status;
//   • the Models button follows onPreview's null-means-hidden rule, so a
//     non-staff role (the fail-closed default) never sees it;
//   • a viewable row routes to the viewer for THAT model.
//
// Hermetic: fake repo, no network. The real ModelViewer needs a WebView
// platform, so the viewer's renderer is injected.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:recapture/app/routes/app_router.dart';
import 'package:recapture/app/theme/app_theme.dart';
import 'package:recapture/application/auth/user_role_notifier.dart';
import 'package:recapture/data/repositories/live_projects_repository.dart';
import 'package:recapture/domain/entities/live_project.dart';
import 'package:recapture/domain/entities/project.dart';
import 'package:recapture/domain/entities/project_model.dart';
import 'package:recapture/domain/entities/project_status.dart';
import 'package:recapture/presentation/screens/projects/model_history_screen.dart';
import 'package:recapture/presentation/screens/projects/model_viewer_screen.dart';
import 'package:recapture/presentation/widgets/project_card.dart';
import 'repo_fake_defaults.dart';

class _FakeRepo with FakeModelGenerationDefaults implements LiveProjectsRepository {
  _FakeRepo(this.models);

  List<ProjectModelView> models;

  @override
  Future<List<ProjectModelView>> listModels(String projectId) async => models;

  @override
  Future<LiveProjectsPage> list({int limit = 20, String? cursor}) async =>
      const LiveProjectsPage(items: [], nextCursor: null);

  @override
  Future<Map<String, dynamic>> export(String projectId) async =>
      throw UnimplementedError('not used here');

  @override
  Future<PreviewDeleteResult> deletePhotos(String p, List<String> k) async =>
      throw UnimplementedError('not used here');
}

ProjectModelView _succeeded({
  String id = 'm1',
  DateTime? at,
  bool approved = false,
  int photos = 4,
  String? glbUrl = 'https://cdn/model.glb',
}) =>
    ProjectModelView(
      id: id,
      source: ModelSource.meshy,
      status: ModelStatus.succeeded,
      glbUrl: glbUrl,
      approved: approved,
      createdAt: at ?? DateTime(2026, 7, 17, 11, 42),
      selectedKeys: [for (var i = 0; i < photos; i++) 'images/EYE/$i.jpg'],
    );

/// The router under test: the real history + viewer paths, with a probe
/// standing in for the viewer so we can assert WHICH model it was handed.
GoRouter _router({void Function(String)? seen}) =>
    GoRouter(
      initialLocation: '/admin/projects/p1/models',
      routes: [
        GoRoute(
          path: AppRoutes.modelHistory,
          name: AppRouteNames.modelHistory,
          builder: (_, state) =>
              ModelHistoryScreen(projectId: state.pathParameters['id'] ?? ''),
        ),
        GoRoute(
          path: AppRoutes.modelViewer,
          name: AppRouteNames.modelViewer,
          builder: (_, state) {
            seen?.call(state.pathParameters['modelId'] ?? '');
            return ModelViewerRoute(
              projectId: state.pathParameters['id'] ?? '',
              modelId: state.pathParameters['modelId'] ?? '',
              renderBuilder: (_, m) => Text('rendering ${m.glbUrl}'),
            );
          },
        ),
      ],
    );

Widget _app(_FakeRepo repo, {bool staff = true, GoRouter? router}) => ProviderScope(
      overrides: [
        liveProjectsRepositoryProvider.overrideWithValue(repo),
        isStaffProvider.overrideWithValue(staff),
      ],
      child: MaterialApp.router(
        theme: AppTheme.dark,
        routerConfig: router ?? _router(),
      ),
    );

/// Resolves the history's first load WITHOUT settling: a pending record keeps
/// the poll timer alive forever, so pumpAndSettle would hang rather than fail.
Future<void> _load(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 50));
}

void main() {
  group('ModelHistoryScreen', () {
    testWidgets('lists every attempt newest-first, labelled by timestamp',
        (tester) async {
      final repo = _FakeRepo([
        _succeeded(id: 'm2', at: DateTime(2026, 7, 17, 11, 42), photos: 4),
        _succeeded(id: 'm1', at: DateTime(2026, 7, 17, 11, 27), photos: 3),
      ]);
      await tester.pumpWidget(_app(repo));
      await _load(tester);

      // Labelled by WHEN, not by index — an index renumbers itself the moment a
      // new generation lands at the head of the list.
      expect(find.text('Jul 17, 11:42 · Succeeded'), findsOneWidget);
      expect(find.text('Jul 17, 11:27 · Succeeded'), findsOneWidget);
      // The photo count is the main thing that differs between attempts.
      expect(find.text('4 photos'), findsOneWidget);
      expect(find.text('3 photos'), findsOneWidget);

      // The backend already sorts; assert we render that order rather than
      // inventing our own.
      final rows = tester.getTopLeft(find.byKey(const ValueKey('model_row_m2')));
      final older = tester.getTopLeft(find.byKey(const ValueKey('model_row_m1')));
      expect(rows.dy, lessThan(older.dy));
    });

    testWidgets('a FAILED row shows its message and is NOT tappable',
        (tester) async {
      String? routed;
      final repo = _FakeRepo([
        ProjectModelView(
          id: 'm1',
          source: ModelSource.meshy,
          status: ModelStatus.failed,
          createdAt: DateTime(2026, 7, 17, 10, 2),
          error: const ModelError(
            code: 'MESHY_GENERATION_FAILED',
            message: 'Meshy could not generate a model from the selected photos',
          ),
        ),
      ]);
      await tester.pumpWidget(
        _app(repo, router: _router(seen: (id) => routed = id)),
      );
      await _load(tester);

      expect(find.text('Jul 17, 10:02 · Failed'), findsOneWidget);
      expect(
        find.text('Meshy could not generate a model from the selected photos'),
        findsOneWidget,
      );

      await tester.tap(find.byKey(const ValueKey('model_row_m1')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      // A failed attempt has nothing to open — the tap must go nowhere.
      expect(routed, isNull);
      expect(find.text('Jul 17, 10:02 · Failed'), findsOneWidget);
    });

    testWidgets('a SUCCEEDED row with no GLB is not tappable either',
        (tester) async {
      String? routed;
      // The reason the gate is isViewable and not `status == succeeded`.
      final repo = _FakeRepo([_succeeded(id: 'm1', glbUrl: null)]);
      await tester.pumpWidget(
        _app(repo, router: _router(seen: (id) => routed = id)),
      );
      await _load(tester);

      await tester.tap(find.byKey(const ValueKey('model_row_m1')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      expect(routed, isNull);
    });

    testWidgets('a pending row shows progress and is not tappable',
        (tester) async {
      String? routed;
      final repo = _FakeRepo([
        ProjectModelView(
          id: 'm1',
          source: ModelSource.meshy,
          status: ModelStatus.processing,
          createdAt: DateTime(2026, 7, 17, 9, 58),
        ),
      ]);
      await tester.pumpWidget(
        _app(repo, router: _router(seen: (id) => routed = id)),
      );
      await _load(tester);

      expect(find.text('Jul 17, 09:58 · Processing…'), findsOneWidget);
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('model_row_m1')),
          matching: find.byType(CircularProgressIndicator),
        ),
        findsOneWidget,
      );

      await tester.tap(find.byKey(const ValueKey('model_row_m1')));
      await tester.pump();
      expect(routed, isNull);
    });

    testWidgets('an approved row is badged', (tester) async {
      final repo = _FakeRepo([_succeeded(approved: true)]);
      await tester.pumpWidget(_app(repo));
      await _load(tester);

      expect(find.text('Approved'), findsOneWidget);
    });

    testWidgets('no generations → an empty state that points at Preview',
        (tester) async {
      await tester.pumpWidget(_app(_FakeRepo([])));
      await _load(tester);

      expect(find.text('No models yet.'), findsOneWidget);
      // An empty history with no way forward would be a dead end.
      expect(find.textContaining('Create Model'), findsOneWidget);
    });

    testWidgets('tapping a viewable row opens the viewer for THAT model',
        (tester) async {
      String? routed;
      final repo = _FakeRepo([
        _succeeded(id: 'm2', at: DateTime(2026, 7, 17, 11, 42)),
        _succeeded(id: 'm1', at: DateTime(2026, 7, 17, 11, 27)),
      ]);
      await tester.pumpWidget(
        _app(repo, router: _router(seen: (id) => routed = id)),
      );
      await _load(tester);

      // The OLDER row — an artist comparing attempts picks by timestamp, so the
      // tap must carry that row's id, not the newest record's.
      await tester.tap(find.byKey(const ValueKey('model_row_m1')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      expect(routed, 'm1');
      expect(find.text('rendering https://cdn/model.glb'), findsOneWidget);
    });
  });

  group('ModelViewerRoute — resolving by id', () {
    testWidgets('a cold deep-link resolves the model from the history',
        (tester) async {
      // No `extra`, no history screen underneath — the route must still work,
      // which is the reason it resolves by id rather than taking the entity.
      final repo = _FakeRepo([_succeeded(id: 'm1')]);
      await tester.pumpWidget(ProviderScope(
        overrides: [
          liveProjectsRepositoryProvider.overrideWithValue(repo),
          isStaffProvider.overrideWithValue(true),
        ],
        child: MaterialApp.router(
          theme: AppTheme.dark,
          routerConfig: GoRouter(
            initialLocation: '/admin/projects/p1/models/m1',
            routes: [
              GoRoute(
                path: AppRoutes.modelViewer,
                name: AppRouteNames.modelViewer,
                builder: (_, state) => ModelViewerRoute(
                  projectId: state.pathParameters['id'] ?? '',
                  modelId: state.pathParameters['modelId'] ?? '',
                  renderBuilder: (_, m) => Text('rendering ${m.glbUrl}'),
                ),
              ),
            ],
          ),
        ),
      ));
      await _load(tester);

      expect(find.text('rendering https://cdn/model.glb'), findsOneWidget);
      expect(find.text('Created by Meshy AI'), findsOneWidget);
    });

    testWidgets('an unknown model id shows the unavailable state, not a blank',
        (tester) async {
      final repo = _FakeRepo([_succeeded(id: 'm1')]);
      await tester.pumpWidget(ProviderScope(
        overrides: [
          liveProjectsRepositoryProvider.overrideWithValue(repo),
          isStaffProvider.overrideWithValue(true),
        ],
        child: MaterialApp.router(
          theme: AppTheme.dark,
          routerConfig: GoRouter(
            // A stale link to a record that isn't there.
            initialLocation: '/admin/projects/p1/models/gone',
            routes: [
              GoRoute(
                path: AppRoutes.modelViewer,
                name: AppRouteNames.modelViewer,
                builder: (_, state) => ModelViewerRoute(
                  projectId: state.pathParameters['id'] ?? '',
                  modelId: state.pathParameters['modelId'] ?? '',
                  renderBuilder: (_, m) => Text('rendering ${m.glbUrl}'),
                ),
              ),
            ],
          ),
        ),
      ));
      await _load(tester);

      expect(find.byType(ModelUnavailable), findsOneWidget);
    });
  });

  group('ProjectCard onModels', () {
    Project project(ProjectStatus status) => Project(
          id: 'proj-123',
          name: 'My Project',
          status: status,
          updatedAt: DateTime(2026, 7, 1),
        );

    Widget card({ValueChanged<Project>? onModels}) => MaterialApp(
          theme: AppTheme.dark,
          home: Scaffold(
            body: ProjectCard(
              project: project(ProjectStatus.completed),
              onResume: (_) {},
              onView: (_) {},
              onRetry: (_) {},
              onMore: (_) {},
              onModels: onModels,
            ),
          ),
        );

    testWidgets('null onModels → no Models button (non-regression)',
        (tester) async {
      await tester.pumpWidget(card());
      expect(find.text('Models'), findsNothing);
    });

    testWidgets('non-null onModels → button shows and calls back with project',
        (tester) async {
      Project? tapped;
      await tester.pumpWidget(card(onModels: (p) => tapped = p));

      expect(find.text('Models'), findsOneWidget);
      await tester.tap(find.text('Models'));
      expect(tapped?.id, 'proj-123');
    });
  });
}
