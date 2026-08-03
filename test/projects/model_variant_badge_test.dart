// test/projects/model_variant_badge_test.dart
//
// One generation now surfaces as TWO history rows — the untouched Meshy build
// and the web-optimized one — and a staff user has to be able to tell them
// apart at a glance and know which one customers actually load.
//
// The distinction is carried by three things, all asserted here:
//   • an "OPT" pill on the optimized row (and NOT on the original);
//   • the size on each row, which is the real difference;
//   • a "Serving" marker on whichever rendition is promoted — deliberately NOT
//     the same thing as being optimized, because producing an optimized build
//     never promotes it. An admin does.
//
// Hermetic: fake repo, no network.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:recapture/app/theme/app_theme.dart';
import 'package:recapture/application/auth/user_role_notifier.dart';
import 'package:recapture/data/repositories/live_projects_repository.dart';
import 'package:recapture/domain/entities/live_project.dart';
import 'package:recapture/domain/entities/project_model.dart';
import 'package:recapture/presentation/screens/projects/model_history_screen.dart';
import 'repo_fake_defaults.dart';

class _FakeRepo
    with
        FakeModelGenerationDefaults,
        FakeAdminDeleteDefaults,
        FakeAutoGenerationDefaults
    implements LiveProjectsRepository {
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

/// The two entries the backend returns for ONE optimized generation. Note the
/// SHARED id: this is one record, one paid generation, two renditions.
List<ProjectModelView> _bothVariants({bool webIsActive = false}) => [
      ProjectModelView(
        id: 'm1',
        source: ModelSource.meshy,
        status: ModelStatus.succeeded,
        glbUrl: 'https://cdn/models/m1/model.glb',
        createdAt: DateTime(2026, 8, 3, 17, 5),
        selectedKeys: const ['a.jpg', 'b.jpg', 'c.jpg'],
        variant: ModelVariant.original,
        isActiveVariant: !webIsActive,
        metrics: const ModelMetrics(
          bytes: 7918404,
          triangles: 7938,
          textureCount: 3,
          largestTextureBytes: 7196137,
        ),
      ),
      ProjectModelView(
        id: 'm1',
        source: ModelSource.meshy,
        status: ModelStatus.succeeded,
        glbUrl: 'https://cdn/models/m1/v1/web.glb',
        createdAt: DateTime(2026, 8, 3, 17, 5),
        selectedKeys: const ['a.jpg', 'b.jpg', 'c.jpg'],
        variant: ModelVariant.web,
        isActiveVariant: webIsActive,
        metrics: const ModelMetrics(
          bytes: 317924,
          triangles: 7938,
          textureCount: 1,
          largestTextureBytes: 286080,
        ),
      ),
    ];

Widget _app(_FakeRepo repo) => ProviderScope(
      overrides: [
        liveProjectsRepositoryProvider.overrideWithValue(repo),
        isStaffProvider.overrideWithValue(true),
      ],
      child: MaterialApp(
        theme: AppTheme.dark,
        home: const ModelHistoryScreen(projectId: 'p1'),
      ),
    );

Future<void> _load(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 50));
}

void main() {
  group('optimized-variant badge', () {
    testWidgets('badges ONLY the optimized row with OPT', (tester) async {
      await tester.pumpWidget(_app(_FakeRepo(_bothVariants())));
      await _load(tester);

      // Exactly one badge for two rows: the original is the baseline and needs
      // no label, so badging both would be ink without information.
      expect(find.text('OPT'), findsOneWidget);
    });

    testWidgets('shows no badge at all when only the original exists',
        (tester) async {
      await tester.pumpWidget(
        _app(_FakeRepo([_bothVariants().first])),
      );
      await _load(tester);

      expect(find.text('OPT'), findsNothing);
    });

    testWidgets('renders two rows for one generation despite the shared id',
        (tester) async {
      // The rows are keyed by id AND variant. Keyed by id alone these would be
      // duplicate sibling keys — a Flutter error, not a cosmetic issue.
      await tester.pumpWidget(_app(_FakeRepo(_bothVariants())));
      await _load(tester);

      expect(find.byKey(const ValueKey('model_row_m1_original')), findsOneWidget);
      expect(find.byKey(const ValueKey('model_row_m1_web')), findsOneWidget);
    });
  });

  group('size is the real differentiator', () {
    testWidgets('each row shows its own weight', (tester) async {
      await tester.pumpWidget(_app(_FakeRepo(_bothVariants())));
      await _load(tester);

      expect(find.textContaining('7.92 MB'), findsOneWidget);
      expect(find.textContaining('318 KB'), findsOneWidget);
    });

    testWidgets('a model with no measurements shows no size, never "0 B"',
        (tester) async {
      // Every record generated before the pipeline existed has no metrics. An
      // unknown size rendered as 0 would read as a spectacular fake saving.
      await tester.pumpWidget(
        _app(_FakeRepo([
          ProjectModelView(
            id: 'old',
            source: ModelSource.meshy,
            status: ModelStatus.succeeded,
            glbUrl: 'https://cdn/old.glb',
            createdAt: DateTime(2026, 7, 1),
            selectedKeys: const ['a.jpg'],
          ),
        ])),
      );
      await _load(tester);

      expect(find.textContaining('0 B'), findsNothing);
      expect(find.textContaining('1 photo'), findsOneWidget);
    });
  });

  group('"Serving" tracks the admin decision, not the badge', () {
    testWidgets('marks the ORIGINAL as serving until someone promotes',
        (tester) async {
      await tester.pumpWidget(_app(_FakeRepo(_bothVariants())));
      await _load(tester);

      // An optimized build existing is NOT the same as it being used.
      final serving = tester.widget<Text>(find.textContaining('Serving'));
      expect(serving.data, contains('7.92 MB'));
    });

    testWidgets('follows the promotion to the optimized build', (tester) async {
      await tester.pumpWidget(_app(_FakeRepo(_bothVariants(webIsActive: true))));
      await _load(tester);

      final serving = tester.widget<Text>(find.textContaining('Serving'));
      expect(serving.data, contains('318 KB'));
    });

    testWidgets('exactly one row is ever marked serving', (tester) async {
      await tester.pumpWidget(_app(_FakeRepo(_bothVariants(webIsActive: true))));
      await _load(tester);

      expect(find.textContaining('Serving'), findsOneWidget);
    });
  });

  group('parsing the staff payload', () {
    test('reads variant, isActiveVariant and metrics', () {
      final model = ProjectModelView.tryFromStaffMap({
        'id': 'm1',
        'source': 'meshy',
        'status': 'SUCCEEDED',
        'variant': 'web',
        'isActiveVariant': false,
        'artifacts': {'glb': 'https://cdn/web.glb'},
        'metrics': {
          'bytes': 317924,
          'triangles': 7938,
          'textureCount': 1,
          'largestTextureBytes': 286080,
        },
      });

      expect(model!.variant, ModelVariant.web);
      expect(model.isOptimized, isTrue);
      expect(model.isActiveVariant, isFalse);
      expect(model.metrics!.sizeLabel, '318 KB');
    });

    test('an older payload with no variant reads as the active original', () {
      // Back-compat: before the pipeline, one entry per generation, and that
      // entry was by definition the one being served.
      final model = ProjectModelView.tryFromStaffMap({
        'id': 'm1',
        'source': 'meshy',
        'status': 'SUCCEEDED',
        'artifacts': {'glb': 'https://cdn/model.glb'},
      });

      expect(model!.variant, ModelVariant.original);
      expect(model.isActiveVariant, isTrue);
      expect(model.isOptimized, isFalse);
      expect(model.metrics, isNull);
    });

    test('an unknown variant from a newer server renders unbadged', () {
      final model = ProjectModelView.tryFromStaffMap({
        'id': 'm1',
        'source': 'meshy',
        'status': 'SUCCEEDED',
        'variant': 'ktx2',
        'artifacts': {'glb': 'https://cdn/x.glb'},
      });

      expect(model!.variant, ModelVariant.unknown);
      expect(model.variant.badgeLabel, isNull);
    });
  });
}
