// test/catalog/product_editor_test.dart
//
// The product editor: field bounds, dirty tracking, the exit guard, the
// upload-then-commit retry, and duplicate.
//
// Two things here are worth more than the rest. The first is the PATCH BODY: a
// patch that resends untouched fields bumps the catalog's draft revision and
// lights the "unpublished changes" badge for an edit nobody made, and a patch
// that sends `null` for a field the user did not touch silently clears it. The
// second is the commit retry: the bytes are already in the bucket, and asking a
// café owner to send 5 MiB again because OUR second call failed is charging them
// for our problem.
//
// Hermetic: repositories and the image picker are faked, no HTTP, no Hive.
import 'package:flutter/foundation.dart' show Uint8List;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:recapture/application/auth/auth_notifier.dart';
import 'package:recapture/data/datasources/product_image_picker.dart';
import 'package:recapture/data/repositories/catalog_failure.dart';
import 'package:recapture/data/repositories/catalog_products_repository.dart';
import 'package:recapture/data/repositories/catalog_repository.dart';
import 'package:recapture/domain/entities/auth_state.dart';
import 'package:recapture/domain/entities/catalog_category.dart';
import 'package:recapture/domain/entities/catalog_product.dart';
import 'package:recapture/domain/entities/product_availability.dart';
import 'package:recapture/domain/entities/product_sync_status.dart';
import 'package:recapture/domain/entities/product_type.dart';
import 'package:go_router/go_router.dart';
import 'package:recapture/app/routes/app_router.dart';
import 'package:recapture/presentation/screens/catalog/product_editor_screen.dart';

import 'catalog_entities_test.dart' as golden;
import 'product_grid_test.dart' show FakeCatalogRepository, product;

/// One recorded PATCH. Every field is a nullable `Object?` so the test can tell
/// "absent" from "explicitly null" — the distinction the whole sentinel dance
/// exists for.
class UpdateCall {
  UpdateCall(this.fields);

  final Map<String, Object?> fields;

  bool has(String key) => fields.containsKey(key);
  Object? operator [](String key) => fields[key];
}

/// A products repository for one product.
class EditorRepository implements CatalogProductsRepository {
  EditorRepository(this._product);

  CatalogProduct _product;

  final List<UpdateCall> updates = [];
  final List<String> uploads = [];
  final List<String> commits = [];
  int duplicates = 0;

  /// Set to fail the next call of the matching kind.
  CatalogFailure? updateFailure;
  CatalogFailure? uploadFailure;
  CatalogFailure? commitFailure;

  final Map<String, CatalogProduct> _byId = {};

  @override
  Future<CatalogProduct> get(String id) async => _byId[id] ?? _product;

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
    updates.add(UpdateCall({
      if (name != null) 'name': name,
      if (description != null) 'description': description,
      if (!identical(price, kCatalogUnchanged)) 'price': price,
      if (!identical(categoryId, kCatalogUnchanged)) 'categoryId': categoryId,
      if (tags != null) 'tags': tags,
      if (availability != null) 'availability': availability,
      if (featured != null) 'featured': featured,
      if (type != null) 'type': type,
      if (sourceModelId != null) 'sourceModelId': sourceModelId,
      if (imageKey != null) 'imageKey': imageKey,
    }));
    if (updateFailure != null) throw updateFailure!;

    _product = _product.copyWith(
      name: name,
      description: description,
      price: identical(price, kCatalogUnchanged) ? null : price as double?,
      categoryId: categoryId,
      tags: tags,
      availability: availability,
      featured: featured,
    );
    return _product;
  }

  @override
  Future<String> uploadImageBytes(
    Uint8List bytes, {
    required String contentType,
    String? productId,
  }) async {
    uploads.add(contentType);
    if (uploadFailure != null) throw uploadFailure!;
    return 'catalog/img/${uploads.length}.jpg';
  }

  @override
  Future<CatalogProduct> commitImage(String productId, String key) async {
    commits.add(key);
    if (commitFailure != null) throw commitFailure!;
    return _product;
  }

  @override
  Future<CatalogProduct> duplicate(String id, {String? name}) async {
    duplicates++;
    final copy = CatalogProduct.fromMap(
      golden.productGolden()
        ..['id'] = 'copy-1'
        ..['name'] = '${_product.name} (copy)',
    );
    // Served by `get` afterwards, because the editor navigates STRAIGHT to the
    // copy and the destination re-fetches by id. A fake that kept returning the
    // original would make the screen show the wrong product and the test would
    // pass only because both share a prefix.
    _byId[copy.id] = copy;
    return copy;
  }

  @override
  Future<CatalogProductPage> list({
    int limit = 20,
    String? cursor,
    String? categoryId,
    ProductType? type,
    ProductAvailability? availability,
    String? query,
    bool includeArchived = false,
  }) async =>
      CatalogProductPage(items: [_product]);

  // ── Not used here ─────────────────────────────────────────────────────────

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
  }) =>
      throw UnimplementedError();

  @override
  Future<ProductImageSlot> createImageSlot({
    required ProductImageContentType contentType,
    String? productId,
  }) =>
      throw UnimplementedError();

  @override
  Future<CatalogProduct> archive(String id) => throw UnimplementedError();

  @override
  Future<CatalogProduct> restore(String id) => throw UnimplementedError();

  @override
  Future<void> delete(String id) => throw UnimplementedError();

  @override
  Future<void> reorder(List<String> orderedIds) async {}

  @override
  Future<int> bulk({
    required BulkProductAction action,
    required List<String> ids,
    Object? categoryId = kCatalogUnchanged,
  }) =>
      throw UnimplementedError();
}

/// A picker that hands back fixed bytes without a platform channel.
class FakePicker implements ProductImagePicker {
  FakePicker({this.image});

  final PickedProductImage? image;
  int calls = 0;

  @override
  Future<PickedProductImage?> pickProductImage() async {
    calls++;
    return image;
  }
}

class _StubAuth extends AuthNotifier {
  @override
  AuthState build() => const AuthRestoring();
}

/// The editor inside a REAL GoRouter, for the one flow that navigates by name.
///
/// `_duplicate` finishes with `context.pushReplacementNamed(productDetail)`,
/// which throws "No GoRouter found in context" under a plain MaterialApp. The
/// rest of the file does not need a router (`navigateBack` degrades to
/// Navigator), so only this flow pays for one.
///
/// The destination is the SAME screen at a different id, which is what the real
/// route does — that is how the copy's name gets on screen and how a
/// duplicate-then-duplicate-again would be caught.
Widget routedHarness(EditorRepository repo) {
  final router = GoRouter(
    initialLocation: '/catalog/products/p1',
    routes: [
      GoRoute(
        path: '/catalog',
        builder: (_, __) => const Scaffold(body: Center(child: Text('grid'))),
      ),
      GoRoute(
        path: AppRoutes.productDetail,
        name: AppRouteNames.productDetail,
        builder: (_, state) => Center(
          child: SizedBox(
            width: 500,
            height: 900,
            child: ProductEditorScreen(
              productId: state.pathParameters['productId']!,
            ),
          ),
        ),
      ),
    ],
  );

  return ProviderScope(
    overrides: [
      authProvider.overrideWith(_StubAuth.new),
      catalogProductsRepositoryProvider.overrideWithValue(repo),
      catalogRepositoryProvider.overrideWithValue(FakeCatalogRepository()),
    ],
    child: MaterialApp.router(routerConfig: router),
  );
}

/// Scrolls [finder] into view, then taps it.
///
/// The editor is a TALL SCROLLING FORM and its actions sit at the bottom of it.
/// On a test surface they start off-screen, and `tap` on an off-screen widget
/// does not fail — it prints a warning and MISSES. The assertion that follows
/// then fails claiming the patch body was wrong, when in truth the button was
/// never pressed. Scrolling first is what makes those assertions about the
/// thing they name.
Future<void> tapAfterScroll(WidgetTester tester, Finder finder) async {
  await tester.ensureVisible(finder);
  await tester.pumpAndSettle();
  await tester.tap(finder);
}

Widget harness(
  EditorRepository repo, {
  double width = 500,
  List<CatalogCategory> categories = const [],
  FakePicker? picker,
}) =>
    ProviderScope(
      overrides: [
        authProvider.overrideWith(_StubAuth.new),
        catalogProductsRepositoryProvider.overrideWithValue(repo),
        catalogRepositoryProvider
            .overrideWithValue(FakeCatalogRepository(categories: categories)),
        if (picker != null)
          productImagePickerProvider.overrideWithValue(picker),
      ],
      child: MaterialApp(
        // PUSHED, not `home`. The exit guard's whole job is to pop this screen,
        // and popping the only route leaves an empty navigator that never
        // settles — `pumpAndSettle` then spins until the suite's timeout and
        // every later test in the file reports "did not complete". Giving the
        // editor a route to go back to is also what the real app does: it is
        // always pushed from the grid, never the root.
        //
        // `initialRoute` with a path builds the stack ['/', '/editor'], so the
        // screen is already pushed on the first pump and no call site has to
        // drive the navigation itself.
        initialRoute: '/editor',
        routes: {
          '/': (_) => const Scaffold(body: Center(child: Text('grid'))),
          '/editor': (_) => Center(
                child: SizedBox(
                  width: width,
                  height: 900,
                  child: const ProductEditorScreen(productId: 'p1'),
                ),
              ),
        },
      ),
    );

/// Pumps an editor harness on a surface big enough to HIT the thing being
/// tapped.
///
/// The default test view is 800x600 and the editor's own box is 900 tall, so
/// "Save changes" lands around y=948 — off-screen. `tap()` warns and misses
/// rather than failing, which is worse than an error: the assertion that
/// follows then fails for a reason that has nothing to do with what it is
/// testing.
Future<void> pumpEditor(WidgetTester tester, Widget widget) async {
  tester.view.physicalSize = const Size(1000, 1800);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(widget);
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('loads the product and seeds every field', (tester) async {
    final repo = EditorRepository(
      product('p1', name: 'Walnut Chair', price: 4999.5),
    );
    await pumpEditor(tester, harness(repo));

    expect(find.text('Walnut Chair'), findsOneWidget);
    expect(find.text('4999.5'), findsOneWidget);
    // The tags on the golden product.
    expect(find.text('chair'), findsOneWidget);
    expect(find.text('wood'), findsOneWidget);
  });

  group('the patch body', () {
    testWidgets('carries only what changed', (tester) async {
      final repo = EditorRepository(product('p1', name: 'Walnut Chair'));
      await pumpEditor(tester, harness(repo));

      await tester.enterText(
        find.widgetWithText(TextFormField, 'Walnut Chair'),
        'Oak Chair',
      );
      await tester.pumpAndSettle();
      await tapAfterScroll(tester, find.text('Save changes'));
      await tester.pumpAndSettle();

      final call = repo.updates.single;
      expect(call['name'], 'Oak Chair');
      // Everything untouched must be ABSENT. A resent field is a draft-revision
      // bump — and an "unpublished changes" badge — for an edit nobody made.
      expect(call.has('price'), isFalse);
      expect(call.has('categoryId'), isFalse);
      expect(call.has('tags'), isFalse);
      expect(call.has('featured'), isFalse);
      expect(call.has('availability'), isFalse);
    });

    testWidgets('an emptied price is sent as an explicit null', (tester) async {
      final repo = EditorRepository(product('p1', price: 250));
      await pumpEditor(tester, harness(repo));

      await tester.enterText(find.widgetWithText(TextFormField, '250'), '');
      await tester.pumpAndSettle();
      await tapAfterScroll(tester, find.text('Save changes'));
      await tester.pumpAndSettle();

      // Absent would mean "unchanged" and the price would survive; null is what
      // clears it. The two are different requests and only one is right.
      final call = repo.updates.single;
      expect(call.has('price'), isTrue);
      expect(call['price'], isNull);
    });

    testWidgets('the price field explains that empty is not free',
        (tester) async {
      final repo = EditorRepository(product('p1', price: null));
      await pumpEditor(tester, harness(repo));

      expect(find.textContaining('No price set'), findsOneWidget);
      expect(find.textContaining('rather than "Free"'), findsOneWidget);
    });
  });

  group('validation happens before the round trip', () {
    testWidgets('an emptied name is rejected locally', (tester) async {
      final repo = EditorRepository(product('p1', name: 'Walnut Chair'));
      await pumpEditor(tester, harness(repo));

      await tester.enterText(
        find.widgetWithText(TextFormField, 'Walnut Chair'),
        '',
      );
      await tester.pumpAndSettle();
      await tapAfterScroll(tester, find.text('Save changes'));
      await tester.pumpAndSettle();

      expect(find.text('Give this product a name.'), findsOneWidget);
      expect(repo.updates, isEmpty);
    });

    testWidgets('the tag ceiling is enforced before submit', (tester) async {
      final many = [for (var i = 0; i < kMaxProductTags; i++) 'tag$i'];
      final base = product('p1');
      final repo = EditorRepository(base.copyWith(tags: many));
      await pumpEditor(tester, harness(repo));

      expect(find.textContaining('$kMaxProductTags of $kMaxProductTags used'),
          findsOneWidget);
      // The input is closed rather than accepting a 21st tag and letting the
      // server say no.
      final field = tester.widget<TextFormField>(
        find.widgetWithText(TextFormField, 'Add a tag'),
      );
      expect(field.enabled, isFalse);
    });

    testWidgets('a tag is lower-cased and de-duplicated as the server would',
        (tester) async {
      final repo = EditorRepository(product('p1'));
      await pumpEditor(tester, harness(repo));

      await tester.enterText(
        find.widgetWithText(TextFormField, 'Add a tag'),
        'BESTSELLER',
      );
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();

      expect(find.text('bestseller'), findsOneWidget);

      await tapAfterScroll(tester, find.text('Save changes'));
      await tester.pumpAndSettle();

      expect(repo.updates.single['tags'], ['chair', 'wood', 'bestseller']);
    });
  });

  group('the exit guard', () {
    testWidgets('asks before discarding typed work', (tester) async {
      final repo = EditorRepository(product('p1', name: 'Walnut Chair'));
      await pumpEditor(tester, harness(repo));

      await tester.enterText(
        find.widgetWithText(TextFormField, 'Walnut Chair'),
        'Oak Chair',
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('Back'));
      await tester.pumpAndSettle();

      expect(find.text('Discard your changes?'), findsOneWidget);

      await tester.tap(find.text('Keep editing'));
      await tester.pumpAndSettle();
      expect(find.text('Discard your changes?'), findsNothing);
    });

    testWidgets('leaves without asking when nothing changed', (tester) async {
      final repo = EditorRepository(product('p1'));
      await pumpEditor(tester, harness(repo));

      await tester.tap(find.byTooltip('Back'));
      await tester.pumpAndSettle();

      expect(find.text('Discard your changes?'), findsNothing);
    });

    testWidgets('publishes the dirty flag the router reads', (tester) async {
      // go_router's onExit — the BROWSER back button — has no access to the
      // screen's State, so the flag has to live somewhere the router can read.
      final repo = EditorRepository(product('p1', name: 'Walnut Chair'));
      await pumpEditor(tester, harness(repo));

      final container = ProviderScope.containerOf(
        tester.element(find.byType(ProductEditorScreen)),
      );
      expect(container.read(productEditorDirtyProvider), isFalse);

      await tester.enterText(
        find.widgetWithText(TextFormField, 'Walnut Chair'),
        'Oak Chair',
      );
      await tester.pumpAndSettle();

      expect(container.read(productEditorDirtyProvider), isTrue);
    });
  });

  group('image replacement', () {
    final bytes = Uint8List.fromList([1, 2, 3, 4]);

    testWidgets('uploads then commits', (tester) async {
      final repo = EditorRepository(
        product('p1', type: ProductType.imageOnly),
      );
      final picker = FakePicker(
        image: PickedProductImage(bytes: bytes, contentType: 'image/jpeg'),
      );
      await pumpEditor(tester, harness(repo, picker: picker));

      await tapAfterScroll(tester, find.text('Replace photo'));
      await tester.pumpAndSettle();

      expect(repo.uploads, ['image/jpeg']);
      expect(repo.commits.single, 'catalog/img/1.jpg');
    });

    testWidgets('a failed commit retries the COMMIT, not the upload',
        (tester) async {
      final repo = EditorRepository(
        product('p1', type: ProductType.imageOnly),
      )..commitFailure = const CatalogFailure(
          code: 'UNKNOWN',
          message: 'Something went wrong. Please try again.',
        );
      final picker = FakePicker(
        image: PickedProductImage(bytes: bytes, contentType: 'image/jpeg'),
      );
      await pumpEditor(tester, harness(repo, picker: picker));

      await tapAfterScroll(tester, find.text('Replace photo'));
      await tester.pumpAndSettle();

      expect(repo.uploads.length, 1);
      expect(repo.commits.length, 1);
      expect(find.textContaining('Nothing needs re-uploading'), findsOneWidget);

      repo.commitFailure = null;
      await tapAfterScroll(tester, find.text('Finish attaching photo'));
      await tester.pumpAndSettle();

      // The bytes went over the wire ONCE.
      expect(repo.uploads.length, 1);
      expect(repo.commits, ['catalog/img/1.jpg', 'catalog/img/1.jpg']);
      expect(find.textContaining('Nothing needs re-uploading'), findsNothing);
    });

    testWidgets('a 3D product is offered a model swap, not a photo',
        (tester) async {
      final repo = EditorRepository(product('p1'));
      await pumpEditor(tester, harness(repo));

      expect(find.text('Change 3D model'), findsOneWidget);
      expect(find.text('Replace photo'), findsNothing);
    });

    testWidgets('an image-only product warns before converting to 3D',
        (tester) async {
      final repo = EditorRepository(
        product('p1', type: ProductType.imageOnly),
      );
      await pumpEditor(tester, harness(repo));

      expect(find.text('Use a 3D model instead'), findsOneWidget);
      // Feature 17: the conversion changes what a customer sees, and it says so
      // before the user commits to it.
      expect(
        find.textContaining('replaces this photo everywhere'),
        findsOneWidget,
      );
    });
  });

  group('the live-state banner', () {
    testWidgets('a synced product says it is live and edits wait for publish',
        (tester) async {
      final repo = EditorRepository(
        product('p1', sync: ProductSyncStatus.synced),
      );
      await pumpEditor(tester, harness(repo));

      expect(find.textContaining('This product is live'), findsOneWidget);
      expect(find.textContaining('next publish'), findsWidgets);
    });

    testWidgets('an unpublished product never claims to be live',
        (tester) async {
      final repo = EditorRepository(
        product('p1', sync: ProductSyncStatus.never),
      );
      await pumpEditor(tester, harness(repo));

      expect(find.textContaining('never been published'), findsOneWidget);
      expect(find.textContaining('This product is live'), findsNothing);
    });

    testWidgets('a publish in flight says the edit is not part of it',
        (tester) async {
      final repo = EditorRepository(
        product('p1', sync: ProductSyncStatus.pending),
      );
      // Sized like pumpEditor, but pumped by hand: a pending product's pill
      // carries the pulsing dot, which repeats forever, so this one uses
      // `pump` and must NOT call pumpAndSettle.
      tester.view.physicalSize = const Size(1000, 1800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(harness(repo));
      await tester.pump();
      await tester.pump();

      expect(find.textContaining('A publish is running'), findsOneWidget);
    });
  });

  testWidgets('duplicate is server-side and one press', (tester) async {
    final repo = EditorRepository(product('p1', name: 'Walnut Chair'));
    await pumpEditor(tester, routedHarness(repo));

    await tapAfterScroll(tester, find.text('Duplicate product'));
    await tester.pumpAndSettle();

    expect(repo.duplicates, 1);
    expect(find.textContaining('Walnut Chair (copy)'), findsWidgets);
  });

  // Was "shows the server sentence" when this file was written. F10 changed the
  // answer: the editor now renders OUR mapped copy for the code and the
  // server's own prose never reaches the screen. The assertion below is
  // therefore inverted from the original on purpose — the raw sentence being
  // absent is the guarantee, and a test still demanding it would be pinning the
  // exact hole F10 closed.
  testWidgets('a failed save keeps the form and maps the code to our copy',
      (tester) async {
    final repo = EditorRepository(product('p1', name: 'Walnut Chair'))
      ..updateFailure = const CatalogFailure(
        code: 'DUPLICATE_NAME',
        message: 'You already have a product with that name.',
      );
    await pumpEditor(tester, harness(repo));

    await tester.enterText(
      find.widgetWithText(TextFormField, 'Walnut Chair'),
      'Oak Chair',
    );
    await tester.pumpAndSettle();
    await tapAfterScroll(tester, find.text('Save changes'));
    await tester.pumpAndSettle();

    // Our sentence for DUPLICATE_NAME, naming the next action.
    expect(
      find.textContaining('already uses this name'),
      findsOneWidget,
    );
    // And the server's own prose is nowhere on screen.
    expect(
      find.textContaining('You already have a product with that name.'),
      findsNothing,
      reason: 'the backend message is owner-safe but it is still the SERVER\'s '
          'sentence — F10 maps the code instead so no upstream text can reach '
          'the UI',
    );
    // What the user typed is still there — a failed save must never blank it.
    expect(find.text('Oak Chair'), findsOneWidget);
  });

  testWidgets('two columns above the breakpoint, one below', (tester) async {
    tester.view.physicalSize = const Size(1400, 1200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final repo = EditorRepository(product('p1'));
    await pumpEditor(tester, harness(repo, width: 1200));
    expect(find.byType(Row), findsWidgets);

    // The layout decision is the CONSTRAINTS' — the same widget tree at a
    // narrow width must be a single column, with no platform check anywhere.
    await pumpEditor(tester, harness(repo, width: 500));
    expect(tester.takeException(), isNull);
  });
}
