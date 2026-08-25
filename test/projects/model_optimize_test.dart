// test/projects/model_optimize_test.dart
//
// The "Optimize" action and the `OPT` badge on the staff model-history row.
//
// The two are deliberately different KINDS of thing and this file is where that
// stays true: the button is an ACTION (rendered only when the server says
// `canOptimize`), the badge is a STATE LABEL (rendered only on a record that IS
// an optimized derivative). A row may show one or the other, never both — a row
// that offered "Optimize" while also claiming to be optimized would be lying in
// two directions at once.
//
// Also covers the entity parsers for both wire shapes, including the
// everything-absent case: an older backend must degrade to "no badge, no
// button" rather than throwing.
//
// TRAPS this file works around:
//   • a PENDING row renders a CircularProgressIndicator, so `pumpAndSettle`
//     never returns — every pump here is a bounded `pump(Duration)`;
//   • the notifier's `listModels` success path is the only path exercised, so
//     the fake must SUCCEED (a throwing fake sends the screen down the error
//     branch and nothing under test renders).
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:recapture/app/routes/app_router.dart';
import 'package:recapture/app/theme/app_theme.dart';
import 'package:recapture/application/auth/user_role_notifier.dart';
import 'package:recapture/data/repositories/live_projects_repository.dart';
import 'package:recapture/domain/entities/live_project.dart';
import 'package:recapture/domain/entities/project_model.dart';
import 'package:recapture/presentation/screens/projects/model_history_screen.dart';
import 'repo_fake_defaults.dart';

/// 5 MiB — the backend's MODEL_OPTIMIZE_THRESHOLD_BYTES default, expressed the
/// same BINARY way. Used here only to build believable fixtures; the client
/// never applies the rule itself.
const _thresholdBytes = 5 * 1024 * 1024;

/// The two sides of that gate. The server's verdict is what actually decides
/// the button — these exist so the fixtures below sit on the REAL boundary
/// rather than a number that stopped meaning anything when the threshold moved.
const _justUnderThreshold = 5138022; // 4.9 MiB
const _justOverThreshold = 5347738; // 5.1 MiB

class _FakeRepo
    with
        FakeAdminDeleteDefaults,
        FakeAutoGenerationDefaults,
        FakeOwnerModelListDefaults
    implements LiveProjectsRepository {
  _FakeRepo(this.models);

  List<ProjectModelView> models;

  /// (projectId, modelId) of every optimize request, in order.
  final List<(String, String)> optimizeCalls = [];

  /// When set, [optimizeModel] throws it instead of succeeding.
  LiveProjectsException? optimizeFailsWith;

  /// Swapped in as the new list after a successful optimize, so the test can
  /// assert the screen re-reads rather than patching its own state.
  List<ProjectModelView>? modelsAfterOptimize;

  @override
  Future<List<ProjectModelView>> listModels(String projectId) async => models;

  @override
  Future<ProjectModelView> optimizeModel(
      String projectId, String modelId) async {
    optimizeCalls.add((projectId, modelId));
    if (optimizeFailsWith case final failure?) throw failure;
    if (modelsAfterOptimize case final next?) models = next;
    return _pendingOpt(source: modelId);
  }

  @override
  Future<void> optimizeOwnerModel(String projectId, String modelId) async {
    optimizeCalls.add((projectId, modelId));
    if (optimizeFailsWith case final failure?) throw failure;
  }

  @override
  Future<ProjectModelView> createModel(String p, List<String> k,
          {required String idempotencyKey}) async =>
      throw UnimplementedError('not used here');

  @override
  Future<ProjectModelView> approveModel(String p, String m) async =>
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
  int? sizeBytes,
  int? savingPercent,
  bool approved = false,
}) =>
    ProjectModelView(
      id: id,
      source: source,
      status: status,
      glbUrl: status == ModelStatus.succeeded ? 'https://cdn/$id.glb' : null,
      approved: approved,
      createdAt: DateTime(2026, 8, 6, 11, 42),
      selectedKeys: const ['images/EYE/0.jpg', 'images/EYE/1.jpg'],
      sizeBytes: sizeBytes,
      isOptimized: isOptimized,
      canOptimize: canOptimize,
      optimizationSavingPercent: savingPercent,
    );

ProjectModelView _pendingOpt({required String source}) => ProjectModelView(
      id: 'opt-of-$source',
      source: ModelSource.optimized,
      status: ModelStatus.queued,
      isOptimized: true,
      createdAt: DateTime(2026, 8, 6, 11, 45),
    );

Widget _app(_FakeRepo repo) => ProviderScope(
      overrides: [
        liveProjectsRepositoryProvider.overrideWithValue(repo),
        isStaffProvider.overrideWithValue(true),
      ],
      child: MaterialApp.router(
        theme: AppTheme.dark,
        routerConfig: GoRouter(
          initialLocation: '/admin/projects/p1/models',
          routes: [
            GoRoute(
              path: AppRoutes.modelHistory,
              name: AppRouteNames.modelHistory,
              builder: (_, state) => ModelHistoryScreen(
                  projectId: state.pathParameters['id'] ?? ''),
            ),
          ],
        ),
      ),
    );

/// Resolves the first load WITHOUT settling — see the header: a pending row
/// keeps a progress indicator (and the poll timer) alive forever.
Future<void> _load(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 100));
}

final _optimizeButton = find.byKey(const ValueKey('model_optimize_button'));
final _optBadge = find.byKey(const ValueKey('model_opt_badge'));

void main() {
  group('_ModelRow — Optimize button visibility', () {
    testWidgets('shown when the server says canOptimize', (tester) async {
      final repo = _FakeRepo([
        _model(canOptimize: true, sizeBytes: 21 * 1024 * 1024),
      ]);
      await tester.pumpWidget(_app(repo));
      await _load(tester);

      expect(_optimizeButton, findsOneWidget);
      expect(find.text('Optimize'), findsOneWidget);
      // The badge is the OTHER thing — a row offering the action must not also
      // claim to already be optimized.
      expect(_optBadge, findsNothing);
    });

    testWidgets('hidden when the server says canOptimize is false',
        (tester) async {
      // A big model whose verdict is still false — e.g. it already has an OPT
      // child. If the client re-derived the rule from the size it would wrongly
      // show a button here, which is exactly the bug canOptimize prevents.
      final repo = _FakeRepo([
        _model(canOptimize: false, sizeBytes: 60 * 1024 * 1024),
      ]);
      await tester.pumpWidget(_app(repo));
      await _load(tester);

      expect(_optimizeButton, findsNothing);
    });

    testWidgets('4.9 MiB → no button, 5.1 MiB → button', (tester) async {
      // The 5 MiB gate as the owner meets it. The THRESHOLD itself is the
      // server's (see tests/model-optimization.test.ts for the truth table);
      // what this pins down is the pairing the row is responsible for — the
      // size it prints and the affordance it puts next to it must describe the
      // same model. A row reading "4.9 MB" beside an Optimize button, or
      // "5.1 MB" without one, is the bug this catches.
      final repo = _FakeRepo([
        _model(id: 'under', canOptimize: false, sizeBytes: _justUnderThreshold),
        _model(id: 'over', canOptimize: true, sizeBytes: _justOverThreshold),
      ]);
      await tester.pumpWidget(_app(repo));
      await _load(tester);

      expect(find.textContaining('4.9 MB'), findsOneWidget);
      expect(find.textContaining('5.1 MB'), findsOneWidget);
      // Exactly one of the two rows offers the action — the over-threshold one.
      expect(_optimizeButton, findsOneWidget);
    });

    testWidgets('an OPT row shows the badge and never the button',
        (tester) async {
      final repo = _FakeRepo([
        _model(
          id: 'opt1',
          source: ModelSource.optimized,
          isOptimized: true,
          canOptimize: false,
          sizeBytes: 6 * 1024 * 1024 + 838861, // ≈ 6.8 MB
          savingPercent: 68,
        ),
      ]);
      await tester.pumpWidget(_app(repo));
      await _load(tester);

      expect(_optBadge, findsOneWidget);
      expect(_optimizeButton, findsNothing);
      expect(find.text('OPT · 6.8 MB (−68%)'), findsOneWidget);
    });

    testWidgets('badge degrades term by term when numbers are missing',
        (tester) async {
      final repo = _FakeRepo([
        _model(id: 'opt1', source: ModelSource.optimized, isOptimized: true),
      ]);
      await tester.pumpWidget(_app(repo));
      await _load(tester);

      // No size, no saving — the label is still meaningful, and never "0 B".
      expect(find.text('OPT'), findsOneWidget);
      expect(find.textContaining('0 B'), findsNothing);
    });

    testWidgets('a pending row shows its spinner, not the button',
        (tester) async {
      final repo = _FakeRepo([
        // canOptimize could never be true on a pending record server-side, but
        // the row must be robust to it: work-in-progress outranks any action.
        _model(status: ModelStatus.queued, canOptimize: true),
      ]);
      await tester.pumpWidget(_app(repo));
      await _load(tester);

      expect(_optimizeButton, findsNothing);
      expect(find.byType(CircularProgressIndicator), findsWidgets);
    });

    testWidgets('a pending OPT row gets optimization copy, not generation copy',
        (tester) async {
      final repo = _FakeRepo([_pendingOpt(source: 'm1')]);
      await tester.pumpWidget(_app(repo));
      await _load(tester);

      expect(
        find.text('Optimizing — shrinking textures and geometry…'),
        findsOneWidget,
      );
      // The generation copy would promise a new model that is not coming.
      expect(find.textContaining('Generating'), findsNothing);
    });
  });

  group('_ModelRow — secondary line', () {
    testWidgets('shows the size beside the photo count when known',
        (tester) async {
      final repo = _FakeRepo([_model(sizeBytes: 22439034)]); // ≈ 21.4 MB
      await tester.pumpWidget(_app(repo));
      await _load(tester);

      expect(find.text('2 photos · 21.4 MB'), findsOneWidget);
    });

    testWidgets('renders no size at all when the backend does not know one',
        (tester) async {
      final repo = _FakeRepo([_model()]);
      await tester.pumpWidget(_app(repo));
      await _load(tester);

      // Absent means UNKNOWN, never zero.
      expect(find.text('2 photos'), findsOneWidget);
    });
  });

  group('Optimize request', () {
    testWidgets('tapping calls the repository for THAT model and re-reads',
        (tester) async {
      final repo = _FakeRepo([
        _model(id: 'm-big', canOptimize: true, sizeBytes: 21 * 1024 * 1024),
      ]);
      repo.modelsAfterOptimize = [
        _pendingOpt(source: 'm-big'),
        _model(id: 'm-big', canOptimize: false, sizeBytes: 21 * 1024 * 1024),
      ];
      await tester.pumpWidget(_app(repo));
      await _load(tester);

      await tester.tap(_optimizeButton);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      expect(repo.optimizeCalls, [('p1', 'm-big')]);
      // The notifier refreshed, so the new pending OPT row is on screen
      // immediately — that, not a snackbar, is the success feedback.
      expect(
        find.text('Optimizing — shrinking textures and geometry…'),
        findsOneWidget,
      );
      // …and the source row no longer offers the action.
      expect(_optimizeButton, findsNothing);
    });

    testWidgets('a refused request shows MAPPED copy, never a raw code',
        (tester) async {
      final repo = _FakeRepo([
        _model(id: 'm-big', canOptimize: true, sizeBytes: 21 * 1024 * 1024),
      ])..optimizeFailsWith =
          const LiveProjectsException(LiveProjectsFailure.notOptimizable);
      await tester.pumpWidget(_app(repo));
      await _load(tester);

      await tester.tap(_optimizeButton);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      expect(
        find.text('This model can’t be optimized — pull down to refresh the list.'),
        findsOneWidget,
      );
      // The server's rule ids are internal; none of them may reach the screen.
      expect(find.textContaining('ALREADY_OPTIMIZED'), findsNothing);
      expect(find.textContaining('MODEL_'), findsNothing);
    });
  });

  group('formatBytes', () {
    test('uses the BINARY divisor, matching the backend threshold', () {
      // 8 MiB exactly — the gate. Decimal MB would print 8.4 here and make the
      // displayed size disagree with whether the button appears.
      expect(formatBytes(8 * 1024 * 1024), '8.0 MB');
      expect(formatBytes(22439034), '21.4 MB');
      expect(formatBytes(2048), '2 KB');
      expect(formatBytes(512), '512 B');
    });

    test('an unknown or nonsense size renders NOTHING, never "0 B"', () {
      expect(formatBytes(null), isNull);
      expect(formatBytes(0), isNull);
      expect(formatBytes(-1), isNull);
    });
  });

  group('ProjectModelView parsing — staff shape', () {
    test('parses glbBytes, canOptimize and the optimization saving', () {
      final model = ProjectModelView.tryFromStaffMap({
        'id': 'm1',
        'source': 'optimized',
        'status': 'SUCCEEDED',
        'artifacts': {'glb': 'https://cdn/m1.glb'},
        'glbBytes': 4200000,
        'canOptimize': false,
        'optimization': {'sourceBytes': 21000000, 'outputBytes': 4200000},
        'createdAt': '2026-08-06T11:42:00.000Z',
      })!;

      expect(model.sizeBytes, 4200000);
      expect(model.isOptimized, isTrue);
      expect(model.canOptimize, isFalse);
      expect(model.optimizationSavingPercent, 80);
      // An OPT record must not ALSO claim an origin.
      expect(model.source.badgeLabel, isNull);
    });

    test('canOptimize true survives the round trip', () {
      final model = ProjectModelView.tryFromStaffMap({
        'id': 'm1',
        'source': 'meshy',
        'status': 'SUCCEEDED',
        'artifacts': {'glb': 'https://cdn/m1.glb'},
        'glbBytes': _thresholdBytes + 1,
        'canOptimize': true,
        'createdAt': '2026-08-06T11:42:00.000Z',
      })!;

      expect(model.canOptimize, isTrue);
      expect(model.isOptimized, isFalse);
      expect(model.optimizationSavingPercent, isNull);
    });

    test('all fields absent → safe defaults, not an exception', () {
      final model = ProjectModelView.tryFromStaffMap({
        'id': 'm1',
        'source': 'meshy',
        'status': 'SUCCEEDED',
        'artifacts': {'glb': 'https://cdn/m1.glb'},
        'createdAt': '2026-08-06T11:42:00.000Z',
      })!;

      // An older backend degrades to "no button, no badge, no size".
      expect(model.sizeBytes, isNull);
      expect(model.isOptimized, isFalse);
      expect(model.canOptimize, isFalse);
      expect(model.optimizationSavingPercent, isNull);
    });

    test('a non-saving "optimization" block yields no percent', () {
      final grew = ProjectModelView.tryFromStaffMap({
        'id': 'm1',
        'source': 'optimized',
        'status': 'SUCCEEDED',
        'artifacts': {'glb': 'https://cdn/m1.glb'},
        'optimization': {'sourceBytes': 1000, 'outputBytes': 1200},
        'createdAt': '2026-08-06T11:42:00.000Z',
      })!;
      expect(grew.optimizationSavingPercent, isNull);
    });
  });

  group('ProjectModelView parsing — owner shape', () {
    test('parses sizeBytes / isOptimized / canOptimize', () {
      final model = ProjectModelView.tryFromOwnerMap({
        'id': 'm1',
        'source': 'optimized',
        'glbUrl': 'https://cdn/m1.glb',
        'approved': false,
        'isAutoGenerated': false,
        'sizeBytes': 4200000,
        'isOptimized': true,
        'canOptimize': false,
        'createdAt': '2026-08-06T11:42:00.000Z',
      })!;

      expect(model.sizeBytes, 4200000);
      expect(model.isOptimized, isTrue);
      expect(model.canOptimize, isFalse);
    });

    test('all fields absent → safe defaults', () {
      final model = ProjectModelView.tryFromOwnerMap({
        'id': 'm1',
        'source': 'meshy',
        'glbUrl': 'https://cdn/m1.glb',
        'createdAt': '2026-08-06T11:42:00.000Z',
      })!;

      expect(model.sizeBytes, isNull);
      expect(model.isOptimized, isFalse);
      expect(model.canOptimize, isFalse);
    });

    test('the owner shape carries no before/after saving', () {
      final model = ProjectModelView.tryFromOwnerMap({
        'id': 'm1',
        'source': 'optimized',
        'glbUrl': 'https://cdn/m1.glb',
        'isOptimized': true,
        'canOptimize': false,
        'createdAt': '2026-08-06T11:42:00.000Z',
      })!;
      expect(model.optimizationSavingPercent, isNull);
    });
  });

  group('ModelSource', () {
    test('parses the optimized source and gives it NO origin badge', () {
      expect(ModelSource.parse('optimized'), ModelSource.optimized);
      expect(ModelSource.optimized.badgeLabel, isNull);
      // Regression guard: the known origins keep theirs.
      expect(ModelSource.meshy.badgeLabel, 'Created by Maya AI');
    });

    test('an unknown source still degrades rather than throwing', () {
      expect(ModelSource.parse('something-new'), ModelSource.unknown);
    });
  });
}
