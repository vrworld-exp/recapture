// test/rep/rep_add_dish_source_test.dart
//
// Stage 10: the add-dish source list is 3 on mobile and 2 on web, and BOTH
// mixes can actually create a dish.
//
// The second half is the one that matters. Asserting the count alone would pass
// for a web build that shows two sources and cannot author anything — which is
// precisely the "same page" claim this stage has to make good on. So each mix
// is driven all the way to a create call and the request is inspected.
//
// The missing source is CAPTURE, and it is a platform limit rather than a
// decision: a browser has no capture pipeline — no exposure, stability, IMU or
// permission channels — so there is nothing to gate behind a flag. Every other
// source works identically on both targets.
//
// Hermetic: the repository and the image picker are both fakes.
import 'dart:convert';

import 'package:flutter/foundation.dart' show Uint8List;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:recapture/application/projects/owner_model_history_notifier.dart';
import 'package:recapture/application/projects/projects_notifier.dart';
import 'package:recapture/application/rep/rep_capabilities.dart';
import 'package:recapture/data/datasources/product_image_picker.dart';
import 'package:recapture/data/repositories/catalog_products_repository.dart'
    show ProductImageSlot;
import 'package:recapture/data/repositories/rep_repository.dart';
import 'package:recapture/domain/entities/catalog_product.dart';
import 'package:recapture/domain/entities/product_type.dart';
import 'package:recapture/domain/entities/project.dart';
import 'package:recapture/domain/entities/project_model.dart';
import 'package:recapture/domain/entities/qr_code_preflight.dart';
import 'package:recapture/domain/entities/rep_activation.dart';
import 'package:recapture/presentation/screens/rep/rep_add_dish_screen.dart';

/// One recorded create, so a test can assert WHAT was authored, not just that
/// something was.
typedef _CreatedDish = ({ProductType type, String name, String? modelId, String? imageKey});

class _FakeRepRepository implements RepRepository {
  final List<_CreatedDish> created = [];
  final List<Uint8List> uploaded = [];

  @override
  Future<CatalogProduct> createProduct(
    String catalogId, {
    required ProductType type,
    required String name,
    String? description,
    double? price,
    String? sourceModelId,
    String? imageKey,
  }) async {
    created.add((
      type: type,
      name: name,
      modelId: sourceModelId,
      imageKey: imageKey,
    ));
    return CatalogProduct.fromMap({
      'id': 'p1',
      'name': name,
      'type': type == ProductType.threeD ? 'THREE_D' : 'IMAGE_ONLY',
    });
  }

  @override
  Future<String> uploadImageBytes(
    String catalogId,
    Uint8List bytes, {
    required String contentType,
  }) async {
    uploaded.add(bytes);
    return 'catalogs/cat-1/products/uploaded.jpg';
  }

  @override
  Future<ProductImageSlot> createImageSlot(
    String catalogId, {
    required String contentType,
  }) async =>
      throw UnimplementedError();

  @override
  Future<QrCodePreflight> preflight(String code) async =>
      throw UnimplementedError();

  @override
  Future<RepActivation> activate(RepActivationRequest request) async =>
      throw UnimplementedError();

  @override
  Future<List<RepCatalogSummary>> catalogs() async => const [];

  @override
  Future<List<CatalogProduct>> products(String catalogId) async => const [];

  @override
  Future<void> attachCode(String catalogId, String code) async {}

  @override
  Future<void> retireCode(String code) async {}
}

/// The rep's own finished captures, held still.
///
/// The model picker reads the SAME provider an owner's add-product screen does
/// — the rep shoots on their own account, so these are the rep's projects. The
/// real notifier reaches for a Hive cache, which does not exist in a widget
/// test.
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

/// A REAL 1x1 PNG, not a few magic bytes.
///
/// The screen renders the picked image with `Image.memory`, so a stub that only
/// looks like a header decodes to "Invalid image data" and fails the test for a
/// reason that has nothing to do with what is being asserted.
final _onePixelPng = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAE'
  'hQGAhKmMIQAAAABJRU5ErkJggg==',
);

/// Always returns the same image, so the photo path can run without a platform
/// channel or a file.
class _FakeImagePicker implements ProductImagePicker {
  @override
  Future<PickedProductImage?> pickProductImage() async => PickedProductImage(
        bytes: _onePixelPng,
        contentType: 'image/png',
      );
}

Widget _app(
  _FakeRepRepository repo, {
  required RepCapabilities caps,
  List<Project> projects = const [],
  Map<String, List<ProjectModelView>> models = const {},
}) =>
    ProviderScope(
      overrides: [
        repRepositoryProvider.overrideWithValue(repo),
        repCapabilitiesProvider.overrideWithValue(caps),
        productImagePickerProvider.overrideWithValue(_FakeImagePicker()),
        projectsProvider.overrideWith(() => _StubProjects(projects)),
        ownerModelHistoryProvider.overrideWith(() => _StubOwnerHistory(models)),
      ],
      child: const MaterialApp(
        home: RepAddDishScreen(catalogId: 'cat-1'),
      ),
    );

// BOTH REAL TARGETS CAPTURE NOW. The browser runs a different ENGINE for it —
// six manual shots rather than the guided IMU ring — but this screen only ever
// asked whether the source can be offered, and on both targets it now can.
const _mobile = RepCapabilities(canScan: false, canCaptureDish: true);
const _web = RepCapabilities(canScan: false, canCaptureDish: true);

/// The stub target: no `dart:io`, no `dart:js_interop`, so no capture of either
/// kind. Kept because HIDDEN-NOT-DISABLED is a rule about this renderer, and it
/// needs a false capability to be asserted against at all.
const _fallback = RepCapabilities(canScan: false, canCaptureDish: false);

Finder _source(RepDishSource source) =>
    find.byKey(ValueKey('rep_dish_source_${source.name}'));

void main() {
  group('the source list', () {
    for (final (name, caps) in [('mobile', _mobile), ('web', _web)]) {
      testWidgets('$name offers three, capture included', (tester) async {
        await tester.pumpWidget(_app(_FakeRepRepository(), caps: caps));

        expect(_source(RepDishSource.captureNow), findsOneWidget);
        expect(_source(RepDishSource.fromCapture), findsOneWidget);
        expect(_source(RepDishSource.photo), findsOneWidget);
      });
    }

    testWidgets('a build that cannot capture omits the source ENTIRELY',
        (tester) async {
      await tester.pumpWidget(_app(_FakeRepRepository(), caps: _fallback));

      // findsNothing, not a disabled tile. An offered-but-dead source would be
      // a promise the target cannot keep.
      expect(_source(RepDishSource.captureNow), findsNothing);
      expect(_source(RepDishSource.fromCapture), findsOneWidget);
      expect(_source(RepDishSource.photo), findsOneWidget);
    });
  });

  group('both mixes can create a dish', () {
    /// THE PARITY CLAIM. Two sources that render but cannot author would pass a
    /// count assertion and fail the rep standing in a restaurant.
    for (final (name, caps) in [('mobile', _mobile), ('web', _web)]) {
      testWidgets('$name creates an image-only dish', (tester) async {
        final repo = _FakeRepRepository();
        await tester.pumpWidget(_app(repo, caps: caps));

        await tester.tap(_source(RepDishSource.photo));
        await tester.pumpAndSettle();

        await tester.tap(find.byKey(const ValueKey('rep_dish_pick_photo')));
        await tester.pumpAndSettle();

        await tester.enterText(
          find.byKey(const ValueKey('rep_dish_name_field')),
          'Paneer Tikka',
        );
        await tester.tap(find.byKey(const ValueKey('rep_dish_submit')));
        await tester.pumpAndSettle();

        // The upload comes FIRST — an image-only dish is created WITH its key,
        // so there is no product to scope the upload to yet.
        expect(repo.uploaded, hasLength(1));
        expect(repo.created, hasLength(1));
        expect(repo.created.single.type, ProductType.imageOnly);
        expect(repo.created.single.name, 'Paneer Tikka');
        expect(repo.created.single.imageKey, isNotNull);
        expect(repo.created.single.modelId, isNull);
      });
    }
  });

  group('what the server would certainly refuse is caught here', () {
    testWidgets('a photo dish with no photo does not become a request',
        (tester) async {
      final repo = _FakeRepRepository();
      await tester.pumpWidget(_app(repo, caps: _web));

      await tester.tap(_source(RepDishSource.photo));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('rep_dish_name_field')),
        'Paneer Tikka',
      );
      await tester.tap(find.byKey(const ValueKey('rep_dish_submit')));
      await tester.pumpAndSettle();

      expect(repo.created, isEmpty);
      expect(repo.uploaded, isEmpty);
      expect(find.byKey(const ValueKey('rep_dish_failure')), findsOneWidget);
    });

    testWidgets('a 3D dish with no capture does not become a request',
        (tester) async {
      final repo = _FakeRepRepository();
      await tester.pumpWidget(_app(repo, caps: _web));

      await tester.enterText(
        find.byKey(const ValueKey('rep_dish_name_field')),
        'Paneer Tikka',
      );
      await tester.tap(find.byKey(const ValueKey('rep_dish_submit')));
      await tester.pumpAndSettle();

      expect(repo.created, isEmpty);
      expect(find.byKey(const ValueKey('rep_dish_failure')), findsOneWidget);
    });

    testWidgets('a nameless dish does not become a request', (tester) async {
      final repo = _FakeRepRepository();
      await tester.pumpWidget(_app(repo, caps: _web));

      await tester.tap(_source(RepDishSource.photo));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('rep_dish_pick_photo')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('rep_dish_submit')));
      await tester.pumpAndSettle();

      expect(repo.created, isEmpty);
    });
  });
}
