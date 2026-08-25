// test/catalog/change_product_model_test.dart
//
// Re-pointing a product at a different model.
//
// The round trip is the contract: the screen has to open on the product's OWN
// capture with its OWN model marked and selected, refuse to save until the pick
// actually differs, and then send exactly the id that was picked. Save-on-open
// would bump the catalog's draft revision and light the "unpublished changes"
// badge for a change nobody made.
//
// The failure path is pinned too. MODEL_NOT_FOUND and MODEL_NOT_READY already
// carry owner-safe copy from the backend, so the screen must show THAT and
// never a code or a raw exception string.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:recapture/application/catalog/catalog_notifier.dart';
import 'package:recapture/application/projects/owner_model_history_notifier.dart';
import 'package:recapture/application/projects/projects_notifier.dart';
import 'package:recapture/data/repositories/catalog_failure.dart';
import 'package:recapture/data/repositories/catalog_products_repository.dart';
import 'package:recapture/domain/entities/catalog.dart';
import 'package:recapture/domain/entities/catalog_product.dart';
import 'package:recapture/domain/entities/product_availability.dart';
import 'package:recapture/domain/entities/product_type.dart';
import 'package:recapture/domain/entities/project.dart';
import 'package:recapture/domain/entities/project_model.dart';
import 'package:recapture/domain/entities/project_status.dart';
import 'package:recapture/presentation/screens/catalog/change_product_model_screen.dart';

import 'catalog_entities_test.dart' as golden;

class _FakeProductsRepo implements CatalogProductsRepository {
  _FakeProductsRepo({required this.product, this.onUpdate});

  final CatalogProduct product;
  final Future<CatalogProduct> Function()? onUpdate;

  int updateCalls = 0;
  String? lastUpdateId;
  String? lastSourceModelId;

  @override
  Future<CatalogProduct> get(String id) async => product;

  @override
  Future<CatalogProduct> update(
    String id, {
    String? name,
    String? description,
    Object? price = kCatalogUnchanged,
    Object? categoryId = kCatalogUnchanged,
    List<String>? tags,
    ProductAvailability? availability,
    bool? featured,
    ProductType? type,
    String? sourceModelId,
    String? imageKey,
  }) async {
    updateCalls++;
    lastUpdateId = id;
    lastSourceModelId = sourceModelId;
    if (onUpdate != null) return onUpdate!();
    return product;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName} is not used here');
}

class _StubProjects extends ProjectsNotifier {
  _StubProjects(this._projects);

  final List<Project> _projects;

  @override
  Future<List<Project>> build() async => _projects;
}

class _StubOwnerHistory extends OwnerModelHistoryNotifier {
  _StubOwnerHistory(this._byProject);

  final Map<String, List<ProjectModelView>> _byProject;

  @override
  Future<List<ProjectModelView>> build(String projectId) async =>
      _byProject[projectId] ?? const <ProjectModelView>[];
}

class _StubCatalog extends CatalogNotifier {
  @override
  Future<Catalog?> build() async => Catalog.fromMap(golden.catalogGolden());

  @override
  Future<void> refresh() async {}
}

CatalogProduct _product({
  String? sourceProjectId = 'p1',
  String? sourceModelId = 'm1',
}) =>
    CatalogProduct.fromMap(golden.productGolden()
      ..['id'] = 'prod1'
      ..['name'] = 'Walnut Chair'
      ..['sourceProjectId'] = sourceProjectId
      ..['sourceModelId'] = sourceModelId);

Project _project(String id, String name) => Project(
      id: id,
      name: name,
      status: ProjectStatus.completed,
      updatedAt: DateTime(2026, 1, 1),
      modelCount: 2,
    );

ProjectModelView _model(String id) => ProjectModelView(
      id: id,
      source: ModelSource.meshy,
      status: ModelStatus.succeeded,
      glbUrl: 'https://cdn.example/$id.glb',
    );

Widget _app(
  _FakeProductsRepo repo, {
  Map<String, List<ProjectModelView>> models = const {},
  List<Project> projects = const [],
}) =>
    ProviderScope(
      overrides: [
        catalogProductsRepositoryProvider.overrideWithValue(repo),
        projectsProvider.overrideWith(() => _StubProjects(projects)),
        ownerModelHistoryProvider.overrideWith(() => _StubOwnerHistory(models)),
        catalogProvider.overrideWith(_StubCatalog.new),
      ],
      child: const MaterialApp(
        home: ChangeProductModelScreen(productId: 'prod1'),
      ),
    );

final _save = find.widgetWithText(ElevatedButton, 'Save');

/// Presses Save and lets the write land.
///
/// Deliberately NOT pumpAndSettle: a successful save raises a snackbar, whose
/// auto-dismiss timer keeps the frame loop busy for the whole settle window.
Future<void> _tapSave(WidgetTester tester) async {
  await tester.tap(_save);
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 100));
}

Future<void> _pump(WidgetTester tester, Widget app) async {
  tester.view.physicalSize = const Size(1200, 3200);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(app);
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('opens on the current model, marked Current, with Save disabled',
      (tester) async {
    final repo = _FakeProductsRepo(product: _product());
    await _pump(
      tester,
      _app(
        repo,
        projects: [_project('p1', 'Chair scan')],
        models: {
          'p1': [_model('m2'), _model('m1')],
        },
      ),
    );

    // Preselected on the product's OWN model, not the newest — otherwise
    // opening the screen would already be proposing a change.
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('model_choice_tile_m1')),
        matching: find.byKey(const ValueKey('model_radio_on')),
      ),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('model_current_chip')), findsOneWidget);
    expect(tester.widget<ElevatedButton>(_save).onPressed, isNull);
  });

  testWidgets('picking another model enables Save and sends THAT id',
      (tester) async {
    final repo = _FakeProductsRepo(product: _product());
    await _pump(
      tester,
      _app(
        repo,
        projects: [_project('p1', 'Chair scan')],
        models: {
          'p1': [_model('m2'), _model('m1')],
        },
      ),
    );

    await tester.tap(find.byKey(const ValueKey('model_choice_tile_m2')));
    await tester.pumpAndSettle();
    expect(tester.widget<ElevatedButton>(_save).onPressed, isNotNull);

    await _tapSave(tester);

    expect(repo.updateCalls, 1);
    expect(repo.lastUpdateId, 'prod1');
    expect(repo.lastSourceModelId, 'm2');
    // A model swap is a DRAFT edit like every other write on this surface.
    expect(find.textContaining('after you publish'), findsWidgets);
  });

  testWidgets('a model from a DIFFERENT capture can be chosen', (tester) async {
    final repo = _FakeProductsRepo(product: _product());
    await _pump(
      tester,
      _app(
        repo,
        projects: [
          _project('p1', 'Chair scan'),
          _project('p2', 'Second scan'),
        ],
        models: {
          'p1': [_model('m1')],
          'p2': [_model('n1')],
        },
      ),
    );

    await tester.tap(find.byType(DropdownButtonFormField<String>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Second scan').last);
    await tester.pumpAndSettle();

    // The other capture's newest is preselected, and the Current chip is gone
    // with it — no model here is the product's current one.
    expect(find.byKey(const ValueKey('model_current_chip')), findsNothing);

    await _tapSave(tester);

    expect(repo.lastSourceModelId, 'n1');
  });

  testWidgets('says so plainly when the current model is no longer there',
      (tester) async {
    final repo = _FakeProductsRepo(product: _product());
    await _pump(
      tester,
      _app(
        repo,
        projects: [_project('p1', 'Chair scan')],
        // m1 is gone — a purged record, or a regenerate that replaced it.
        models: {
          'p1': [_model('m9')],
        },
      ),
    );

    expect(find.textContaining('no longer in this capture'), findsOneWidget);
    // Nothing was silently re-picked in its place, so Save stays disabled until
    // the user says which model they want.
    expect(tester.widget<ElevatedButton>(_save).onPressed, isNull);

    await tester.tap(find.byKey(const ValueKey('model_choice_tile_m9')));
    await tester.pumpAndSettle();
    expect(tester.widget<ElevatedButton>(_save).onPressed, isNotNull);
  });

  testWidgets('MODEL_NOT_READY surfaces the mapped copy, not a code',
      (tester) async {
    final repo = _FakeProductsRepo(
      product: _product(),
      onUpdate: () async => throw const CatalogFailure(
        code: 'MODEL_NOT_READY',
        message: 'That 3D model is not finished yet.',
        statusCode: 409,
      ),
    );
    await _pump(
      tester,
      _app(
        repo,
        projects: [_project('p1', 'Chair scan')],
        models: {
          'p1': [_model('m2'), _model('m1')],
        },
      ),
    );

    await tester.tap(find.byKey(const ValueKey('model_choice_tile_m2')));
    await tester.pumpAndSettle();
    await tester.tap(_save);
    await tester.pumpAndSettle();

    // OUR copy for the code, not the server's sentence (F10). The message the
    // fake failure carries is deliberately different from this, so a
    // regression that started passing upstream prose through would fail here.
    expect(find.textContaining('still being built'), findsOneWidget);
    expect(
      find.text('That 3D model is not finished yet.'),
      findsNothing,
      reason: 'that is the SERVER sentence; the client maps the code instead',
    );
    expect(find.textContaining('MODEL_NOT_READY'), findsNothing);
    // Still on the screen, still holding the pick, so Save can be tried again.
    expect(tester.widget<ElevatedButton>(_save).onPressed, isNotNull);
  });

  testWidgets('a stale product id shows the mapped not-found state',
      (tester) async {
    // The backend makes "no such product" and "not yours" identical on purpose.
    final repo = _StaleProductsRepo();
    await _pump(
      tester,
      ProviderScope(
        overrides: [
          catalogProductsRepositoryProvider.overrideWithValue(repo),
          projectsProvider.overrideWith(() => _StubProjects(const [])),
          catalogProvider.overrideWith(_StubCatalog.new),
        ],
        child: const MaterialApp(
          home: ChangeProductModelScreen(productId: 'gone'),
        ),
      ),
    );

    // Mapped from NOT_FOUND, not echoed from the envelope.
    expect(find.textContaining('no longer in your catalog'), findsOneWidget);
    expect(find.text('We could not find that product.'), findsNothing);
    expect(find.text('Retry'), findsOneWidget);
  });
}

class _StaleProductsRepo implements CatalogProductsRepository {
  @override
  Future<CatalogProduct> get(String id) async => throw const CatalogFailure(
        code: 'NOT_FOUND',
        message: 'We could not find that product.',
        statusCode: 404,
      );

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName} is not used here');
}
