// test/projects/owner_model_history_test.dart
//
// The OWNER's per-project model list — what a normal user gets when they tap
// "Models" on their own project, replacing the old "open the newest model
// straight in the viewer" shortcut.
//
// What these tests actually protect, in order:
//   1. ROUTING: a non-staff tap lands on the LIST, not on the viewer; a staff
//      tap is untouched. This is the whole behaviour change, and it is the one
//      thing a reader of the diff cannot verify by inspection.
//   2. The owner surface talks to the OWNER endpoints only. Asserted by making
//      the staff members of the fake repository THROW: if the screen ever
//      reaches `listModels` or `optimizeModel`, the test fails loudly instead
//      of passing because a 403 never happens in a fake.
//   3. NO staff-only action is reachable — no Approve, no Export — on the list
//      or on the viewer the list pushes.
//
// TRAPS worked around here (both already cost time on the staff screen):
//   • a PENDING row renders a CircularProgressIndicator, so `pumpAndSettle`
//     never returns — every pump is a bounded `pump(Duration)`;
//   • the projects screen's processing card spins forever for the same reason.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:recapture/app/routes/app_router.dart';
import 'package:recapture/application/auth/profile_provider.dart';
import 'package:recapture/application/auth/user_role_notifier.dart';
import 'package:recapture/application/projects/live_projects_notifier.dart';
import 'package:recapture/application/projects/projects_notifier.dart';
import 'package:recapture/data/repositories/live_projects_repository.dart';
import 'package:recapture/domain/entities/live_project.dart';
import 'package:recapture/domain/entities/project.dart';
import 'package:recapture/domain/entities/project_model.dart';
import 'package:recapture/domain/entities/project_status.dart';
import 'package:recapture/presentation/screens/projects/model_history_screen.dart';
import 'package:recapture/presentation/screens/projects/model_viewer_screen.dart';
import 'package:recapture/presentation/screens/projects/owner_model_history_screen.dart';
import 'package:recapture/presentation/screens/projects/projects_screen.dart';
import 'repo_fake_defaults.dart';

/// A repository whose OWNER members work and whose STAFF members throw.
///
/// The throwing halves are the point: in a fake there is no server to answer
/// 403, so "the owner screen never touches the admin route" can only be pinned
/// by making that call an immediate, unmistakable failure.
class _FakeRepo
    with
        FakeAdminDeleteDefaults,
        FakeAutoGenerationDefaults,
        FakeModelOptimizeDefaults
    implements LiveProjectsRepository {
  _FakeRepo(this.models);

  List<ProjectModelView> models;

  /// (projectId, modelId) of every OWNER optimize request, in order.
  final List<(String, String)> ownerOptimizeCalls = [];

  /// Swapped in as the next list after a successful optimize, so a test can
  /// assert the screen RE-READS rather than patching its own state.
  List<ProjectModelView>? modelsAfterOptimize;

  /// When set, [optimizeOwnerModel] throws it instead of succeeding.
  LiveProjectsException? optimizeFailsWith;

  int listOwnerCalls = 0;

  @override
  Future<List<ProjectModelView>> listOwnerModels(String projectId) async {
    listOwnerCalls++;
    return models;
  }

  @override
  Future<void> optimizeOwnerModel(String projectId, String modelId) async {
    ownerOptimizeCalls.add((projectId, modelId));
    if (optimizeFailsWith case final failure?) throw failure;
    if (modelsAfterOptimize case final next?) models = next;
  }

  // ── staff-only members: reaching any of these is a test failure ───────────
  @override
  Future<List<ProjectModelView>> listModels(String projectId) async =>
      throw StateError('owner surface must not call the STAFF list route');

  @override
  Future<ProjectModelView> optimizeModel(String p, String m) async =>
      throw StateError('owner surface must not call the STAFF optimize route');

  @override
  Future<ProjectModelView> approveModel(String p, String m) async =>
      throw StateError('owner surface must not call approve');

  @override
  Future<ProjectModelView> createModel(String p, List<String> k,
          {required String idempotencyKey}) async =>
      throw UnimplementedError('not used here');

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

ProjectModelView _model({
  String id = 'm1',
  ModelSource source = ModelSource.meshy,
  ModelStatus status = ModelStatus.succeeded,
  bool canOptimize = false,
  bool isOptimized = false,
  bool approved = false,
  int? sizeBytes,
  DateTime? createdAt,
}) =>
    ProjectModelView(
      id: id,
      source: source,
      status: status,
      glbUrl: status == ModelStatus.succeeded ? 'https://cdn/$id.glb' : null,
      approved: approved,
      createdAt: createdAt ?? DateTime(2026, 8, 7, 11, 42),
      // The owner payload carries NO selectedKeys — leaving this empty is what
      // makes the fixture honest about the shape the screen really receives.
      sizeBytes: sizeBytes,
      isOptimized: isOptimized,
      canOptimize: canOptimize,
    );

/// A stand-in for the 3D render surface: the real one drives a WebView, which
/// has no platform implementation in a widget test.
Widget _stubRender(BuildContext _, ProjectModelView model) =>
    Text('RENDER:${model.id}');

Widget _screen(_FakeRepo repo, {bool isStaff = false}) => ProviderScope(
      overrides: [
        liveProjectsRepositoryProvider.overrideWithValue(repo),
        isStaffProvider.overrideWithValue(isStaff),
      ],
      child: MaterialApp(
        home: OwnerModelHistoryScreen(
          projectId: 'p1',
          projectName: 'My vase',
          renderBuilder: _stubRender,
        ),
      ),
    );

/// Resolves the first load WITHOUT settling — a pending row keeps a progress
/// indicator (and the poll timer) alive forever.
Future<void> _load(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 100));
}

final _optimizeButton = find.byKey(const ValueKey('model_optimize_button'));
final _optBadge = find.byKey(const ValueKey('model_opt_badge'));
final _sourceBadge = find.byKey(const ValueKey('model_source_badge'));
final _exportButton = find.byKey(const ValueKey('model_export_btn'));

// ── the projects-screen harness, for the routing tests ──────────────────────

class _FakeProjectsNotifier extends ProjectsNotifier {
  _FakeProjectsNotifier(this.modelCount);
  final int modelCount;

  @override
  Future<List<Project>> build() async => [
        Project(
          id: 'p1',
          name: 'My vase',
          status: ProjectStatus.processing,
          updatedAt: DateTime(2026, 8, 7),
          totalPhotos: 36,
          modelCount: modelCount,
        ),
      ];
}

class _EmptyLiveNotifier extends LiveProjectsNotifier {
  @override
  Future<LiveProjectsState> build() async =>
      const LiveProjectsState(items: <LiveProject>[], nextCursor: null);
}

/// Sentinel for the STAFF history route, so "staff went to /admin" is an
/// assertion rather than an absence.
const _staffHistoryMarker = 'STAFF_HISTORY_ROUTE';

Widget _projectsApp(_FakeRepo repo, {required bool isStaff}) => ProviderScope(
      overrides: [
        projectsProvider.overrideWith(() => _FakeProjectsNotifier(1)),
        liveProjectsProvider.overrideWith(_EmptyLiveNotifier.new),
        liveProjectsRepositoryProvider.overrideWithValue(repo),
        isStaffProvider.overrideWithValue(isStaff),
        isAdminProvider.overrideWithValue(false),
        avatarBytesProvider.overrideWith((ref) async => null),
      ],
      // Router-backed, because the STAFF branch navigates by NAME — a plain
      // MaterialApp would make that path throw rather than be observed.
      child: MaterialApp.router(
        routerConfig: GoRouter(
          initialLocation: '/',
          routes: [
            GoRoute(path: '/', builder: (_, __) => const ProjectsScreen()),
            GoRoute(
              path: AppRoutes.modelHistory,
              name: AppRouteNames.modelHistory,
              builder: (_, __) => const Scaffold(
                body: Center(child: Text(_staffHistoryMarker)),
              ),
            ),
          ],
        ),
      ),
    );

Future<void> _pumpFrames(WidgetTester tester) async {
  for (var i = 0; i < 5; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

void main() {
  group('routing — where "Models" goes', () {
    testWidgets('a NON-STAFF owner lands on the model LIST, not the viewer',
        (tester) async {
      final repo = _FakeRepo([_model(canOptimize: true, sizeBytes: 21000000)]);
      await tester.pumpWidget(_projectsApp(repo, isStaff: false));
      await _pumpFrames(tester);

      await tester.tap(find.text('Models'));
      await _pumpFrames(tester);

      expect(find.byType(OwnerModelHistoryScreen), findsOneWidget);
      // The regression this whole change is about: the old behaviour pushed
      // the single viewer straight from the card.
      expect(find.byType(ModelViewerScreen), findsNothing);
      // And it read the OWNER route to populate itself.
      expect(repo.listOwnerCalls, greaterThan(0));
    });

    testWidgets('STAFF are untouched — never the owner screen', (tester) async {
      final repo = _FakeRepo([_model()]);
      await tester.pumpWidget(_projectsApp(repo, isStaff: true));
      await _pumpFrames(tester);

      await tester.tap(find.text('Models'));
      await _pumpFrames(tester);

      // Staff still land on the /admin history route, unchanged...
      expect(find.text(_staffHistoryMarker), findsOneWidget);
      // ...and never on the owner screen or the owner endpoint.
      expect(find.byType(OwnerModelHistoryScreen), findsNothing);
      expect(repo.listOwnerCalls, 0);
    });
  });

  group('the list', () {
    testWidgets('renders every model, newest first, with status + origin',
        (tester) async {
      final repo = _FakeRepo([
        _model(id: 'm2', createdAt: DateTime(2026, 8, 7, 12, 0)),
        _model(id: 'm1', createdAt: DateTime(2026, 8, 6, 9, 0)),
      ]);
      await tester.pumpWidget(_screen(repo));
      await _load(tester);

      expect(find.byKey(const ValueKey('owner_model_row_m1')), findsOneWidget);
      expect(find.byKey(const ValueKey('owner_model_row_m2')), findsOneWidget);

      // Server order is preserved rather than re-sorted client-side.
      final newer =
          tester.getTopLeft(find.byKey(const ValueKey('owner_model_row_m2')));
      final older =
          tester.getTopLeft(find.byKey(const ValueKey('owner_model_row_m1')));
      expect(newer.dy, lessThan(older.dy));

      // Status, and the origin badge the owner surface adds.
      expect(find.textContaining('Succeeded'), findsNWidgets(2));
      expect(_sourceBadge, findsNWidgets(2));
      expect(find.text('Created by Maya AI'), findsNWidgets(2));
    });

    testWidgets('shows pending and failed rows, not just finished ones',
        (tester) async {
      final repo = _FakeRepo([
        _model(id: 'q1', status: ModelStatus.queued),
        _model(id: 'f1', status: ModelStatus.failed),
        _model(id: 's1'),
      ]);
      await tester.pumpWidget(_screen(repo));
      await _load(tester);

      expect(find.byKey(const ValueKey('owner_model_row_q1')), findsOneWidget);
      expect(find.byKey(const ValueKey('owner_model_row_f1')), findsOneWidget);
      expect(find.textContaining('Queued'), findsOneWidget);
      expect(find.textContaining('Failed'), findsOneWidget);
    });

    testWidgets('an OPT row shows the OPT badge', (tester) async {
      final repo = _FakeRepo([
        _model(
          id: 'opt1',
          source: ModelSource.optimized,
          isOptimized: true,
          sizeBytes: 6 * 1024 * 1024,
        ),
      ]);
      await tester.pumpWidget(_screen(repo));
      await _load(tester);

      expect(_optBadge, findsOneWidget);
      expect(find.textContaining('OPT'), findsOneWidget);
      // An optimized record has no ORIGIN to claim — the model it came from
      // holds that fact — so it must not also say "Created by Maya AI".
      expect(_sourceBadge, findsNothing);
    });

    testWidgets('an approved model shows the Approved state label',
        (tester) async {
      final repo = _FakeRepo([_model(approved: true)]);
      await tester.pumpWidget(_screen(repo));
      await _load(tester);

      expect(find.text('Approved'), findsOneWidget);
    });

    testWidgets('empty history renders the owner empty state, no staff copy',
        (tester) async {
      final repo = _FakeRepo([]);
      await tester.pumpWidget(_screen(repo));
      await _load(tester);

      expect(find.text('No models yet.'), findsOneWidget);
      // The staff empty state points into the Preview gallery, which an owner
      // would only 403 on.
      expect(find.textContaining('Open Preview'), findsNothing);
    });
  });

  group('opening a model', () {
    testWidgets('tapping a viewable row opens the viewer for THAT model',
        (tester) async {
      final repo = _FakeRepo([_model(id: 'm1'), _model(id: 'm2')]);
      await tester.pumpWidget(_screen(repo));
      await _load(tester);

      await tester.tap(find.byKey(const ValueKey('owner_model_row_m2')));
      await _load(tester);

      expect(find.byType(ModelViewerScreen), findsOneWidget);
      // Resolved to the tapped record, not simply "the newest".
      expect(find.text('RENDER:m2'), findsOneWidget);
    });

    testWidgets('a pending row is inert — nothing to open', (tester) async {
      final repo = _FakeRepo([_model(id: 'q1', status: ModelStatus.queued)]);
      await tester.pumpWidget(_screen(repo));
      await _load(tester);

      await tester.tap(find.byKey(const ValueKey('owner_model_row_q1')));
      await _load(tester);

      expect(find.byType(ModelViewerScreen), findsNothing);
    });
  });

  group('owner-safe Optimize', () {
    testWidgets('shown when the server says canOptimize, and calls the OWNER route',
        (tester) async {
      final repo = _FakeRepo([
        _model(canOptimize: true, sizeBytes: 21 * 1024 * 1024),
      ]);
      await tester.pumpWidget(_screen(repo));
      await _load(tester);

      expect(_optimizeButton, findsOneWidget);

      await tester.tap(_optimizeButton);
      await _load(tester);

      // The staff members of the fake THROW, so reaching this line at all
      // proves the owner route was the one used.
      expect(repo.ownerOptimizeCalls, [('p1', 'm1')]);
    });

    testWidgets('hidden when the server says canOptimize is false',
        (tester) async {
      // A big model whose verdict is still false — if the client re-derived
      // the rule from the size it would wrongly show a button here.
      final repo = _FakeRepo([
        _model(canOptimize: false, sizeBytes: 60 * 1024 * 1024),
      ]);
      await tester.pumpWidget(_screen(repo));
      await _load(tester);

      expect(_optimizeButton, findsNothing);
    });

    testWidgets('a successful optimize RE-READS the list', (tester) async {
      final repo = _FakeRepo([
        _model(canOptimize: true, sizeBytes: 21 * 1024 * 1024),
      ])
        ..modelsAfterOptimize = [
          _model(id: 'm1', canOptimize: false, sizeBytes: 21 * 1024 * 1024),
          _model(
            id: 'opt-of-m1',
            source: ModelSource.optimized,
            status: ModelStatus.queued,
            isOptimized: true,
          ),
        ];
      await tester.pumpWidget(_screen(repo));
      await _load(tester);

      await tester.tap(_optimizeButton);
      await _load(tester);

      // The new pending OPT row is present, which is the feedback that
      // replaces a success snackbar.
      expect(
        find.byKey(const ValueKey('owner_model_row_opt-of-m1')),
        findsOneWidget,
      );
      expect(find.textContaining('Optimizing'), findsOneWidget);
    });

    testWidgets('a refused optimize shows MAPPED copy, never a raw code',
        (tester) async {
      final repo = _FakeRepo([
        _model(canOptimize: true, sizeBytes: 21 * 1024 * 1024),
      ])..optimizeFailsWith =
          const LiveProjectsException(LiveProjectsFailure.notOptimizable);
      await tester.pumpWidget(_screen(repo));
      await _load(tester);

      await tester.tap(_optimizeButton);
      await _load(tester);

      expect(find.byType(SnackBar), findsOneWidget);
      expect(find.textContaining('NOT_OPTIMIZABLE'), findsNothing);
      expect(find.textContaining('BELOW_THRESHOLD'), findsNothing);
    });
  });

  group('no staff-only actions reach an owner', () {
    testWidgets('the list has no Approve and no Export', (tester) async {
      final repo = _FakeRepo([
        _model(canOptimize: true, sizeBytes: 21 * 1024 * 1024),
      ]);
      await tester.pumpWidget(_screen(repo));
      await _load(tester);

      expect(find.widgetWithText(ElevatedButton, 'Approve'), findsNothing);
      expect(find.text('Export'), findsNothing);
      expect(_exportButton, findsNothing);
    });

    testWidgets('nor does the viewer the list pushes', (tester) async {
      final repo = _FakeRepo([_model(id: 'm1')]);
      await tester.pumpWidget(_screen(repo));
      await _load(tester);

      await tester.tap(find.byKey(const ValueKey('owner_model_row_m1')));
      await _load(tester);

      expect(find.byType(ModelViewerScreen), findsOneWidget);
      // Export gates itself on isStaffProvider (false here); Approve is simply
      // never wired by the owner screen.
      expect(_exportButton, findsNothing);
      expect(find.text('Approve'), findsNothing);
    });

    testWidgets(
        'even if the role flag were WRONG, the owner screen cannot approve',
        (tester) async {
      // Belt and braces: mount the owner screen with isStaff TRUE. Export
      // reappears (it reads the flag), but Approve still cannot — the owner
      // screen never passes an onApprove, so the action does not exist on this
      // path regardless of role.
      final repo = _FakeRepo([_model(id: 'm1')]);
      await tester.pumpWidget(_screen(repo, isStaff: true));
      await _load(tester);

      await tester.tap(find.byKey(const ValueKey('owner_model_row_m1')));
      await _load(tester);

      expect(find.text('Approve'), findsNothing);
    });
  });

  group('ProjectModelView.tryFromOwnerListMap', () {
    test('parses the owner list shape', () {
      final model = ProjectModelView.tryFromOwnerListMap({
        'id': 'm1',
        'source': 'meshy',
        'status': 'SUCCEEDED',
        'glbUrl': 'https://cdn/m1.glb',
        'usdzUrl': 'https://cdn/m1.usdz',
        'previewUrl': 'https://cdn/m1.png',
        'approved': true,
        'isAutoGenerated': true,
        'sizeBytes': 22439034,
        'isOptimized': false,
        'canOptimize': true,
        'createdAt': '2026-08-07T11:42:00.000Z',
      })!;

      expect(model.id, 'm1');
      expect(model.source, ModelSource.meshy);
      expect(model.status, ModelStatus.succeeded);
      expect(model.glbUrl, 'https://cdn/m1.glb');
      expect(model.usdzUrl, 'https://cdn/m1.usdz');
      expect(model.approved, isTrue);
      expect(model.isAutoGenerated, isTrue);
      expect(model.sizeBytes, 22439034);
      expect(model.canOptimize, isTrue);
      expect(model.isViewable, isTrue);
      // Staff-only fields are not in this payload and must stay at their
      // empty defaults rather than being invented.
      expect(model.selectedKeys, isEmpty);
      expect(model.generationTrace, isNull);
      expect(model.optimizationSavingPercent, isNull);
    });

    test('KEEPS a pending record that has no glbUrl yet', () {
      // The difference from tryFromOwnerMap, and the reason this parser
      // exists: dropping this row would hide the OPT record the user just
      // created by tapping Optimize.
      final model = ProjectModelView.tryFromOwnerListMap({
        'id': 'opt1',
        'source': 'optimized',
        'status': 'QUEUED',
        'isOptimized': true,
        'canOptimize': false,
        'createdAt': '2026-08-07T11:45:00.000Z',
      })!;

      expect(model.status, ModelStatus.queued);
      expect(model.status.isPending, isTrue);
      expect(model.glbUrl, isNull);
      expect(model.isViewable, isFalse);
      expect(model.isOptimized, isTrue);
    });

    test('turns progressPercent into a phase-less ModelProgress', () {
      final model = ProjectModelView.tryFromOwnerListMap({
        'id': 'p1',
        'status': 'PROCESSING',
        'progressPercent': 42,
        'createdAt': '2026-08-07T11:45:00.000Z',
      })!;

      expect(model.progress, isNotNull);
      expect(model.progress!.percent, 42);
      // The owner is never told the phase NAME.
      expect(model.progress!.phase, ModelProgressPhase.unknown);
    });

    test('all fields absent → safe defaults, never a throw', () {
      final model = ProjectModelView.tryFromOwnerListMap({'id': 'm1'})!;

      expect(model.source, ModelSource.unknown);
      expect(model.status, ModelStatus.unknown);
      expect(model.glbUrl, isNull);
      expect(model.approved, isFalse);
      expect(model.isOptimized, isFalse);
      expect(model.canOptimize, isFalse);
      expect(model.sizeBytes, isNull);
      expect(model.progress, isNull);
      expect(model.error, isNull);
    });

    test('a row with no id is dropped, not half-parsed', () {
      expect(ProjectModelView.tryFromOwnerListMap({'status': 'SUCCEEDED'}),
          isNull);
      expect(ProjectModelView.tryFromOwnerListMap('nope'), isNull);
      expect(ProjectModelView.tryFromOwnerListMap(null), isNull);
    });

    test('carries the owner-safe error copy on a FAILED row', () {
      final model = ProjectModelView.tryFromOwnerListMap({
        'id': 'f1',
        'status': 'FAILED',
        'error': {'code': 'MESHY_FAILED', 'message': 'We couldn’t build this.'},
        'createdAt': '2026-08-07T11:45:00.000Z',
      })!;

      expect(model.status, ModelStatus.failed);
      expect(model.error!.message, 'We couldn’t build this.');
    });
  });

  group('formatBytes shares one definition with the staff row', () {
    test('binary divisor, and null for an unknown size', () {
      expect(formatBytes(8 * 1024 * 1024), '8.0 MB');
      expect(formatBytes(null), isNull);
      expect(formatBytes(0), isNull);
    });
  });
}
