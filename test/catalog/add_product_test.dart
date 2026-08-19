// test/catalog/add_product_test.dart
//
// The add-product form (T-018).
//
// The thing these tests exist to pin is the ORDER and the SHAPE of what goes
// out. The backend refuses a product that has no asset — a 3D one without a
// model id, an image-only one without an already-uploaded key — so the form
// has to upload FIRST and create with the resulting key, and it has to refuse
// a submit with no asset before spending a round trip on it. Both are easy to
// regress into "create, then attach", which the server rejects and which would
// leave the user looking at a failure they cannot act on.
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:recapture/application/catalog/catalog_notifier.dart';
import 'package:recapture/application/projects/owner_model_state_notifier.dart';
import 'package:recapture/application/projects/projects_notifier.dart';
import 'package:recapture/data/datasources/product_image_picker.dart';
import 'package:recapture/data/repositories/catalog_failure.dart';
import 'package:recapture/data/repositories/catalog_products_repository.dart';
import 'package:recapture/data/repositories/projects_repository.dart';
import 'package:recapture/domain/entities/catalog.dart';
import 'package:recapture/domain/entities/catalog_product.dart';
import 'package:recapture/domain/entities/product_availability.dart';
import 'package:recapture/domain/entities/product_type.dart';
import 'package:recapture/domain/entities/project.dart';
import 'package:recapture/domain/entities/project_model.dart';
import 'package:recapture/domain/entities/project_status.dart';
import 'package:recapture/presentation/screens/catalog/add_product_screen.dart';

import 'catalog_entities_test.dart' as golden;

/// One JPEG's worth of magic bytes. The picker sniffs the type from these, so a
/// test image has to start with them or it is rejected before anything else.
final _jpegBytes = Uint8List.fromList([0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10]);

/// Records what the form asked for, so the tests can assert on the REQUEST
/// rather than on the widget tree's account of it.
class _FakeProductsRepo implements CatalogProductsRepository {
  _FakeProductsRepo({this.onUpload});

  final Future<String> Function()? onUpload;

  int uploadCalls = 0;
  Uint8List? lastUploadBytes;
  String? lastUploadContentType;
  String? lastUploadProductId;

  int createCalls = 0;
  ProductType? lastType;
  String? lastName;
  String? lastDescription;
  double? lastPrice;
  String? lastSourceModelId;
  String? lastImageKey;
  ProductAvailability? lastAvailability;

  /// The order the two calls actually ran in — the invariant this file is here
  /// to protect.
  final List<String> calls = [];

  @override
  Future<String> uploadImageBytes(
    Uint8List bytes, {
    required String contentType,
    String? productId,
  }) async {
    calls.add('upload');
    uploadCalls++;
    lastUploadBytes = bytes;
    lastUploadContentType = contentType;
    lastUploadProductId = productId;
    return onUpload != null ? onUpload!() : 'prod/catalog/c1/products/s1/i1.jpg';
  }

  @override
  Future<CatalogProduct> create({
    required ProductType type,
    required String name,
    String? description,
    double? price,
    String? categoryId,
    List<String>? tags,
    ProductAvailability? availability,
    bool? featured,
    String? sourceModelId,
    String? imageKey,
  }) async {
    calls.add('create');
    createCalls++;
    lastType = type;
    lastName = name;
    lastDescription = description;
    lastPrice = price;
    lastSourceModelId = sourceModelId;
    lastImageKey = imageKey;
    lastAvailability = availability;
    return CatalogProduct.fromMap(golden.productGolden()..['name'] = name);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName} is not used here');
}

class _FakePicker implements ProductImagePicker {
  _FakePicker(this._result);

  /// A thrown [ProductImagePickException] models an unusable file; null models
  /// a cancel.
  final Object? _result;

  @override
  Future<PickedProductImage?> pickProductImage() async {
    if (_result is ProductImagePickException) throw _result;
    return _result as PickedProductImage?;
  }
}

/// The projects list held still — the form only reads it.
class _StubProjects extends ProjectsNotifier {
  _StubProjects(this._projects);

  final List<Project> _projects;

  @override
  Future<List<Project>> build() async => _projects;
}

class _StubOwnerModelState extends OwnerModelStateNotifier {
  _StubOwnerModelState(this._state);

  final OwnerModelState _state;

  @override
  Future<OwnerModelState> build(String projectId) async => _state;
}

/// The catalog notifier held still: the form refreshes it after a successful
/// create, and the real one would reach for the network to do it.
class _StubCatalog extends CatalogNotifier {
  int refreshes = 0;

  @override
  Future<Catalog?> build() async => Catalog.fromMap(golden.catalogGolden());

  @override
  Future<void> refresh() async => refreshes++;
}

Project _project(String id, String name, {int modelCount = 1}) => Project(
      id: id,
      name: name,
      status: ProjectStatus.completed,
      updatedAt: DateTime(2026, 1, 1),
      modelCount: modelCount,
    );

OwnerModelState _readyModel(String id) => OwnerModelState(
      model: ProjectModelView(
        id: id,
        source: ModelSource.meshy,
        status: ModelStatus.succeeded,
        glbUrl: 'https://cdn.example/$id.glb',
      ),
    );

Widget _app({
  required _FakeProductsRepo repo,
  ProductImagePicker? picker,
  List<Project> projects = const [],
  OwnerModelState? modelState,
  _StubCatalog? catalog,
}) =>
    ProviderScope(
      overrides: [
        catalogProductsRepositoryProvider.overrideWithValue(repo),
        if (picker != null) productImagePickerProvider.overrideWithValue(picker),
        projectsProvider.overrideWith(() => _StubProjects(projects)),
        ownerModelStateProvider.overrideWith(
          () => _StubOwnerModelState(modelState ?? const OwnerModelState()),
        ),
        catalogProvider.overrideWith(() => catalog ?? _StubCatalog()),
      ],
      child: const MaterialApp(home: AddProductScreen()),
    );

/// The form's submit button — the empty states carry the same words, so it is
/// matched on the ElevatedButton AppButton renders.
final _submit = find.widgetWithText(ElevatedButton, 'Add product');

/// Pumps the form on a surface tall enough to hold all of it.
///
/// The form is a ListView, which builds only what is on screen: at the default
/// 800x600 test surface the submit button is genuinely not in the tree, and
/// every tap on it fails for a reason that has nothing to do with the form.
/// Scrolling to it in each test would work too, but it would make the tests
/// about scrolling.
Future<void> _pump(WidgetTester tester, Widget app) async {
  tester.view.physicalSize = const Size(1200, 3200);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(app);
  await tester.pumpAndSettle();
}

Future<void> _fillName(WidgetTester tester, String name) =>
    tester.enterText(find.widgetWithText(TextFormField, 'Product name'), name);

void main() {
  group('image-only', () {
    Future<_FakeProductsRepo> pickAndSubmit(
      WidgetTester tester, {
      _FakeProductsRepo? repo,
      Object? pick,
    }) async {
      final products = repo ?? _FakeProductsRepo();
      await _pump(tester, _app(
        repo: products,
        picker: _FakePicker(
          pick ??
              PickedProductImage(bytes: _jpegBytes, contentType: 'image/jpeg'),
        ),
      ));

      await tester.tap(find.text('Photo'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Choose a photo'));
      await tester.pumpAndSettle();

      await _fillName(tester, 'Paneer Tikka');
      await tester.tap(_submit);
      await tester.pumpAndSettle();
      return products;
    }

    testWidgets('uploads the photo BEFORE creating, and creates with its key',
        (tester) async {
      final repo = await pickAndSubmit(tester);

      // The order is the contract: an image-only product cannot be created
      // without a key, so create must not run first.
      expect(repo.calls, ['upload', 'create']);
      expect(repo.lastUploadContentType, 'image/jpeg');
      // No product id — the product does not exist yet, so the object is staged.
      expect(repo.lastUploadProductId, isNull);
      expect(repo.lastType, ProductType.imageOnly);
      expect(repo.lastImageKey, 'prod/catalog/c1/products/s1/i1.jpg');
      expect(repo.lastSourceModelId, isNull);
      expect(repo.lastName, 'Paneer Tikka');
    });

    testWidgets('refuses to submit with no photo, without a round trip',
        (tester) async {
      final repo = _FakeProductsRepo();
      await _pump(tester, _app(repo: repo, picker: _FakePicker(null)));

      await tester.tap(find.text('Photo'));
      await tester.pumpAndSettle();
      await _fillName(tester, 'Paneer Tikka');
      await tester.tap(_submit);
      await tester.pumpAndSettle();

      expect(find.text('Add a photo for this product.'), findsOneWidget);
      expect(repo.calls, isEmpty);
    });

    testWidgets('an unusable file is reported without uploading anything',
        (tester) async {
      final repo = _FakeProductsRepo();
      await _pump(tester, _app(
        repo: repo,
        picker: _FakePicker(
          const ProductImagePickException(ProductImagePickFailure.tooLarge),
        ),
      ));

      await tester.tap(find.text('Photo'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Choose a photo'));
      await tester.pumpAndSettle();

      expect(find.textContaining('too large'), findsOneWidget);
      expect(repo.uploadCalls, 0);
    });

    testWidgets('a failed upload keeps the form open with what was typed',
        (tester) async {
      final repo = _FakeProductsRepo(
        onUpload: () async => throw const CatalogFailure(
          code: 'OFFLINE',
          message: "You're offline — check your connection and try again.",
          isOffline: true,
        ),
      );
      await pickAndSubmit(tester, repo: repo);

      // The server's own owner-safe sentence, and the typed name still there to
      // retry with.
      expect(find.textContaining("You're offline"), findsOneWidget);
      expect(find.text('Paneer Tikka'), findsOneWidget);
      expect(repo.createCalls, 0);
    });
  });

  group('3D', () {
    testWidgets('sends the chosen capture\'s model id, and no image key',
        (tester) async {
      final repo = _FakeProductsRepo();
      await _pump(tester, _app(
        repo: repo,
        projects: [_project('p1', 'Wooden statue')],
        modelState: _readyModel('m1'),
      ));

      await tester.tap(find.byType(DropdownButtonFormField<String>));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Wooden statue').last);
      await tester.pumpAndSettle();

      await _fillName(tester, 'Statue');
      await tester.tap(_submit);
      await tester.pumpAndSettle();

      expect(repo.lastType, ProductType.threeD);
      expect(repo.lastSourceModelId, 'm1');
      expect(repo.lastImageKey, isNull);
      // Nothing was uploaded — a 3D product's card image is the model's own
      // generated preview.
      expect(repo.uploadCalls, 0);
    });

    testWidgets('offers only captures that have a finished model',
        (tester) async {
      await _pump(tester, _app(
        repo: _FakeProductsRepo(),
        projects: [
          _project('p1', 'Wooden statue'),
          _project('p2', 'Still building', modelCount: 0),
        ],
      ));

      await tester.tap(find.byType(DropdownButtonFormField<String>));
      await tester.pumpAndSettle();

      expect(find.text('Wooden statue'), findsWidgets);
      // modelCount 0 means "nothing to view" — offering it would produce a
      // product the server then refuses.
      expect(find.text('Still building'), findsNothing);
    });

    testWidgets('says so when there is nothing to build a 3D product from',
        (tester) async {
      await _pump(tester, _app(repo: _FakeProductsRepo()));

      expect(find.textContaining('no finished 3D models yet'), findsOneWidget);
    });

    testWidgets('refuses to submit with no model chosen, without a round trip',
        (tester) async {
      final repo = _FakeProductsRepo();
      await _pump(tester, _app(
        repo: repo,
        projects: [_project('p1', 'Wooden statue')],
        modelState: _readyModel('m1'),
      ));

      await _fillName(tester, 'Statue');
      await tester.tap(_submit);
      await tester.pumpAndSettle();

      expect(find.textContaining('Choose a finished 3D model'), findsOneWidget);
      expect(repo.calls, isEmpty);
    });
  });

  group('fields', () {
    testWidgets('an empty name is rejected without a round trip', (tester) async {
      final repo = _FakeProductsRepo();
      await _pump(tester, _app(
        repo: repo,
        projects: [_project('p1', 'Wooden statue')],
        modelState: _readyModel('m1'),
      ));

      await tester.tap(_submit);
      await tester.pumpAndSettle();

      expect(find.text('Give this product a name.'), findsOneWidget);
      expect(repo.calls, isEmpty);
    });

    testWidgets('a blank optional field goes out ABSENT, not empty',
        (tester) async {
      final repo = _FakeProductsRepo();
      await _pump(tester, _app(
        repo: repo,
        projects: [_project('p1', 'Wooden statue')],
        modelState: _readyModel('m1'),
      ));

      await tester.tap(find.byType(DropdownButtonFormField<String>));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Wooden statue').last);
      await tester.pumpAndSettle();
      await _fillName(tester, 'Statue');
      await tester.tap(_submit);
      await tester.pumpAndSettle();

      // The server schema is strict and rejects a blank description; an empty
      // price is a real "no price", not 0.
      expect(repo.lastDescription, isNull);
      expect(repo.lastPrice, isNull);
    });

    testWidgets('a non-numeric price is rejected without a round trip',
        (tester) async {
      final repo = _FakeProductsRepo();
      await _pump(tester, _app(
        repo: repo,
        projects: [_project('p1', 'Wooden statue')],
        modelState: _readyModel('m1'),
      ));

      await _fillName(tester, 'Statue');
      // The formatter strips everything but digits and dots, so an invalid
      // value has to be built out of those.
      await tester.enterText(
        find.widgetWithText(TextFormField, 'Price (optional)'),
        '1.2.3',
      );
      await tester.tap(_submit);
      await tester.pumpAndSettle();

      expect(find.textContaining('Enter a number'), findsOneWidget);
      expect(repo.calls, isEmpty);
    });

    testWidgets('a successful create refreshes the catalog header',
        (tester) async {
      final repo = _FakeProductsRepo();
      final catalog = _StubCatalog();
      await _pump(tester, _app(
        repo: repo,
        projects: [_project('p1', 'Wooden statue')],
        modelState: _readyModel('m1'),
        catalog: catalog,
      ));

      await tester.tap(find.byType(DropdownButtonFormField<String>));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Wooden statue').last);
      await tester.pumpAndSettle();
      await _fillName(tester, 'Statue');
      await tester.tap(_submit);
      await tester.pumpAndSettle();

      // The counts and the "Draft changes not yet live" badge are server-derived
      // and this write moved both.
      expect(repo.createCalls, 1);
      expect(catalog.refreshes, 1);
    });
  });
}
