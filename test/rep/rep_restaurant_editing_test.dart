// test/rep/rep_restaurant_editing_test.dart
//
// The rep's editing surface: a dish they can fix, a restaurant they can fill
// in, and a preview of what publishing would actually produce.
//
// What this file exists to catch, in order of how badly the alternative goes:
//
//   • THE PREVIEW LYING. The card on the dish editor claims to be "what a
//     customer will see". If it rendered the SAVED dish instead of the one the
//     form currently holds, a rep would check their work against the thing they
//     were trying to change. The test types a new name and asserts the card
//     moved.
//   • A SAVE SENDING FIELDS NOBODY TOUCHED. Every write bumps the draft
//     revision, so a patch that resends the whole form lights up "not live yet"
//     for an edit nobody made — and the sentinel that separates "clear the
//     price" from "I did not touch the price" is exactly the thing a naive
//     implementation gets wrong.
//   • THE DELEGATED PROFILE WRITING TO THE WRONG CATALOG. The details screen is
//     the OWNER's screen given a scope. If the scope did not reach the
//     repository call, a rep's edit would land on the rep's own catalog — which
//     usually does not exist, so it would fail loudly, or worse, would not.
//
// Hermetic: the rep repository and the image picker are fakes. No Dio, no Hive,
// no platform channels.
import 'package:flutter/foundation.dart' show Uint8List;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:recapture/application/auth/auth_notifier.dart';
import 'package:recapture/application/catalog/qr_download_file.dart';
import 'package:recapture/data/datasources/product_image_picker.dart';
import 'package:recapture/data/repositories/admin_standee_repository.dart'
    show StandeeQrFormat;
import 'package:recapture/data/repositories/catalog_failure.dart';
import 'package:recapture/data/repositories/catalog_products_repository.dart'
    show ProductImageSlot, kCatalogUnchanged;
import 'package:recapture/data/repositories/catalog_repository.dart'
    show BrandingSlot;
import 'package:recapture/data/repositories/rep_repository.dart';
import 'package:recapture/domain/entities/auth_state.dart';
import 'package:recapture/domain/entities/business_profile.dart';
import 'package:recapture/domain/entities/catalog.dart';
import 'package:recapture/domain/entities/catalog_category.dart';
import 'package:recapture/domain/entities/catalog_product.dart';
import 'package:recapture/domain/entities/product_availability.dart';
import 'package:recapture/domain/entities/product_type.dart';
import 'package:recapture/domain/entities/qr_code_preflight.dart';
import 'package:recapture/domain/entities/qr_standee.dart';
import 'package:recapture/domain/entities/rep_activation.dart';
import 'package:recapture/presentation/screens/catalog/business_profile_screen.dart';
import 'package:recapture/presentation/screens/rep/rep_catalog_detail_screen.dart';
import 'package:recapture/presentation/screens/rep/rep_dish_editor_screen.dart';
import 'package:recapture/presentation/screens/rep/rep_menu_preview_screen.dart';
import 'package:recapture/presentation/widgets/catalog/preview_product_card.dart';

import '../catalog/catalog_entities_test.dart' as golden;

const String kCatalogId = '6a83dd464aea89d1d2d28d50';
const String kDishId = '6a83dd464aea89d1d2d28d60';

/// One recorded dish PATCH, with the sentinels intact.
///
/// Held as `Object?` rather than `double?`/`String?` deliberately: the whole
/// point of the assertions below is to tell [kCatalogUnchanged] apart from an
/// explicit null, and a typed field would erase the difference before the test
/// could see it.
class DishPatch {
  DishPatch({
    required this.name,
    required this.description,
    required this.price,
    required this.categoryId,
    required this.availability,
    required this.imageKey,
  });

  final String? name;
  final String? description;
  final Object? price;
  final Object? categoryId;
  final ProductAvailability? availability;
  final String? imageKey;

  bool get priceUntouched => identical(price, kCatalogUnchanged);
  bool get categoryUntouched => identical(categoryId, kCatalogUnchanged);
}

/// One recorded profile PATCH.
class ProfilePatch {
  ProfilePatch(this.catalogId, this.name, this.businessName, this.contact);

  final String catalogId;
  final String? name;
  final String? businessName;
  final BusinessContact? contact;
}

class FakeRepRepository implements RepRepository {
  FakeRepRepository({CatalogProduct? dish, BusinessProfile? profile})
      : dish = dish ?? imageDish(),
        storedProfile =
            profile ?? BusinessProfile.fromMap(golden.profileGolden());

  CatalogProduct dish;

  // `storedProfile` / `storedCategories` rather than `profile` / `categories`:
  // those names are METHODS on the interface, and a field cannot share a name
  // with the member it is meant to serve.
  BusinessProfile storedProfile;
  List<CatalogCategory> storedCategories = [
    CatalogCategory.fromMap(golden.categoryGolden()),
  ];

  final List<DishPatch> dishPatches = [];
  final List<ProfilePatch> profilePatches = [];
  final List<String> uploadedFor = [];

  /// Set to fail the next dish write.
  CatalogFailure? dishFailure;

  static CatalogProduct imageDish() => CatalogProduct.fromMap({
        ...golden.productGolden(),
        'id': kDishId,
        'type': 'IMAGE_ONLY',
        'name': 'masala_dosa',
        'price': 120.0,
        'glbUrl': null,
        'usdzUrl': null,
        'sourceModelId': null,
        'modelStatus': 'NONE',
      });

  // ── The delegated catalog ─────────────────────────────────────────────────

  @override
  Future<Catalog> catalog(String catalogId) async =>
      Catalog.fromMap({...golden.catalogGolden(), 'id': catalogId});

  @override
  Future<CatalogCategoryList> categories(String catalogId) async =>
      CatalogCategoryList(
        categories: storedCategories,
        uncategorizedCount: 0,
      );

  @override
  Future<BusinessProfile> profile(String catalogId) async => storedProfile;

  @override
  Future<BusinessProfile> updateProfile(
    String catalogId, {
    String? name,
    String? businessName,
    BusinessContact? contact,
  }) async {
    profilePatches.add(ProfilePatch(catalogId, name, businessName, contact));
    storedProfile = storedProfile.copyWith(
      name: name,
      businessName: businessName,
      contact: contact,
    );
    return storedProfile;
  }

  @override
  Future<String> uploadBrandingBytes(
    String catalogId,
    Uint8List bytes, {
    required BrandingSlot slot,
    required String contentType,
  }) async =>
      'branding-key';

  @override
  Future<BusinessProfile> commitBranding(
    String catalogId, {
    required BrandingSlot slot,
    required String key,
  }) async =>
      storedProfile;

  // ── One dish ──────────────────────────────────────────────────────────────

  @override
  Future<CatalogProduct> product(String catalogId, String productId) async =>
      dish;

  @override
  Future<CatalogProduct> updateProduct(
    String catalogId,
    String productId, {
    String? name,
    String? description,
    Object? price = kCatalogUnchanged,
    Object? categoryId = kCatalogUnchanged,
    ProductAvailability? availability,
    String? imageKey,
  }) async {
    dishPatches.add(DishPatch(
      name: name,
      description: description,
      price: price,
      categoryId: categoryId,
      availability: availability,
      imageKey: imageKey,
    ));
    if (dishFailure != null) throw dishFailure!;

    dish = dish.copyWith(
      name: name,
      description: description,
      price: identical(price, kCatalogUnchanged) ? kCatalogUnchanged : price,
      categoryId: identical(categoryId, kCatalogUnchanged)
          ? kCatalogUnchanged
          : categoryId,
      availability: availability,
    );
    return dish;
  }

  // ── The rest of the seam, unexercised here ────────────────────────────────

  @override
  Future<QrCodePreflight> preflight(String code) async =>
      throw UnimplementedError();

  @override
  Future<RepActivation> activate(RepActivationRequest request) async =>
      throw UnimplementedError();

  @override
  Future<List<RepCatalogSummary>> catalogs() async => const [];

  @override
  Future<List<CatalogProduct>> products(String catalogId) async => [dish];

  @override
  Future<CatalogProduct> createProduct(
    String catalogId, {
    required ProductType type,
    required String name,
    String? description,
    double? price,
    String? sourceModelId,
    String? imageKey,
  }) async =>
      throw UnimplementedError();

  @override
  Future<String> uploadImageBytes(
    String catalogId,
    Uint8List bytes, {
    required String contentType,
    String? productId,
  }) async {
    uploadedFor.add(productId ?? '<none>');
    return 'uploaded-image-key';
  }

  @override
  Future<ProductImageSlot> createImageSlot(
    String catalogId, {
    required String contentType,
  }) async =>
      throw UnimplementedError();

  @override
  Future<RepPublishResult> publish(String catalogId) async =>
      const RepPublishResult(outcome: RepPublishOutcome.queued);

  @override
  Future<void> attachCode(String catalogId, String code) async {}

  @override
  Future<void> retireCode(String code) async {}

  @override
  Future<List<RepStandee>> standees() async => const [];

  @override
  Future<QrDownloadFile> standeeFile(
    String code, {
    StandeeQrFormat format = StandeeQrFormat.pdf,
    int? size,
  }) async =>
      throw UnimplementedError();
}

class FakePicker implements ProductImagePicker {
  FakePicker(this.picked);

  final PickedProductImage? picked;
  int calls = 0;

  @override
  Future<PickedProductImage?> pickProductImage() async {
    calls++;
    return picked;
  }
}

/// Auth held still — the profile notifier listens to it and the real one
/// reaches for secure storage.
class _StubAuth extends AuthNotifier {
  @override
  AuthState build() => const AuthRestoring();
}

Widget harness(
  FakeRepRepository repo,
  Widget child, {
  double width = 500,
  double height = 900,
  ProductImagePicker? picker,
}) =>
    ProviderScope(
      overrides: [
        authProvider.overrideWith(_StubAuth.new),
        repRepositoryProvider.overrideWithValue(repo),
        if (picker != null) productImagePickerProvider.overrideWithValue(picker),
      ],
      child: MaterialApp(
        home: Center(
          child: SizedBox(width: width, height: height, child: child),
        ),
      ),
    );

/// Scrolls [finder] into view, then taps it.
///
/// Both editors are long scrolling forms and their primary button sits at the
/// bottom, so a bare `tap` acts on a point outside the viewport — which fails by
/// doing NOTHING, and reads as "the save did not fire" rather than as a test
/// that never pressed the button.
Future<void> tapButton(WidgetTester tester, Finder finder) async {
  await tester.ensureVisible(finder);
  await tester.pumpAndSettle();
  await tester.tap(finder);
  await tester.pumpAndSettle();
}

void main() {
  group('the dish list is a door, not a status board', () {
    testWidgets('offers Preview and Restaurant details, and opens a dish',
        (tester) async {
      final repo = FakeRepRepository();
      await tester.pumpWidget(
        harness(repo, const RepCatalogDetailScreen(catalogId: kCatalogId)),
      );
      await tester.pumpAndSettle();

      // The two entry points that did not exist before, and the per-dish one.
      expect(find.byKey(const ValueKey('rep_preview_menu')), findsOneWidget);
      expect(
        find.byKey(const ValueKey('rep_restaurant_details')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('rep_dish_row_$kDishId')),
        findsOneWidget,
      );

      // A row that renders but does not respond is the failure this catches:
      // it looks finished and leaves the rep with no way in.
      final row = tester.widget<InkWell>(
        find.byKey(const ValueKey('rep_dish_row_$kDishId')),
      );
      expect(row.onTap, isNotNull);
    });
  });

  group('the dish editor previews what it is about to publish', () {
    testWidgets('renders the customer-eye card for the dish', (tester) async {
      final repo = FakeRepRepository();
      await tester.pumpWidget(harness(
        repo,
        const RepDishEditorScreen(catalogId: kCatalogId, productId: kDishId),
      ));
      await tester.pumpAndSettle();

      expect(find.byType(PreviewProductCard), findsOneWidget);
      expect(find.text('What a customer will see'), findsOneWidget);
    });

    testWidgets('the card follows the FORM, not the last saved dish',
        (tester) async {
      final repo = FakeRepRepository();
      await tester.pumpWidget(harness(
        repo,
        const RepDishEditorScreen(catalogId: kCatalogId, productId: kDishId),
      ));
      await tester.pumpAndSettle();

      await tester.enterText(
        find.byKey(const ValueKey('rep_dish_name')),
        'mysore_masala_dosa',
      );
      await tester.pump();

      final card = tester.widget<PreviewProductCard>(
        find.byType(PreviewProductCard),
      );
      // THE ASSERTION THIS FILE EXISTS FOR. A card fed the saved dish would
      // still say 'masala_dosa' here, and the rep would be checking their work
      // against the thing they are trying to change.
      expect(card.product.name, 'mysore_masala_dosa');
      // …and nothing has been written. A live preview must not be a live save.
      expect(repo.dishPatches, isEmpty);
    });

    testWidgets('Save is dead until something actually changes',
        (tester) async {
      final repo = FakeRepRepository();
      await tester.pumpWidget(harness(
        repo,
        const RepDishEditorScreen(catalogId: kCatalogId, productId: kDishId),
      ));
      await tester.pumpAndSettle();

      Widget saveButton() =>
          tester.widget(find.byKey(const ValueKey('rep_dish_save')));

      expect((saveButton() as dynamic).onPressed, isNull);

      await tester.enterText(
        find.byKey(const ValueKey('rep_dish_name')),
        'mysore_masala_dosa',
      );
      await tester.pump();

      expect((saveButton() as dynamic).onPressed, isNotNull);
    });

    testWidgets('sends ONLY the field that changed', (tester) async {
      final repo = FakeRepRepository();
      await tester.pumpWidget(harness(
        repo,
        const RepDishEditorScreen(catalogId: kCatalogId, productId: kDishId),
      ));
      await tester.pumpAndSettle();

      await tester.enterText(
        find.byKey(const ValueKey('rep_dish_name')),
        'mysore_masala_dosa',
      );
      await tester.pump();
      await tapButton(tester, find.byKey(const ValueKey('rep_dish_save')));

      expect(repo.dishPatches, hasLength(1));
      final patch = repo.dishPatches.single;
      expect(patch.name, 'mysore_masala_dosa');
      expect(patch.description, isNull);
      expect(patch.availability, isNull);
      expect(patch.imageKey, isNull);
      // The sentinels, untouched. A patch carrying `price: null` here would
      // silently clear a price the rep never went near.
      expect(patch.priceUntouched, isTrue);
      expect(patch.categoryUntouched, isTrue);
    });

    testWidgets('an emptied price is an explicit null, not an absence',
        (tester) async {
      final repo = FakeRepRepository();
      await tester.pumpWidget(harness(
        repo,
        const RepDishEditorScreen(catalogId: kCatalogId, productId: kDishId),
      ));
      await tester.pumpAndSettle();

      await tester.enterText(find.byKey(const ValueKey('rep_dish_price')), '');
      await tester.pump();
      await tapButton(tester, find.byKey(const ValueKey('rep_dish_save')));

      final patch = repo.dishPatches.single;
      // "No price set" and "costs nothing" are different claims, and clearing
      // one has to be expressible.
      expect(patch.priceUntouched, isFalse);
      expect(patch.price, isNull);
    });

    testWidgets('a picked photo is uploaded once and bound by the SAVE',
        (tester) async {
      final repo = FakeRepRepository();
      final picker = FakePicker(PickedProductImage(
        bytes: Uint8List.fromList(List<int>.filled(8, 7)),
        contentType: 'image/jpeg',
      ));
      await tester.pumpWidget(harness(
        repo,
        const RepDishEditorScreen(catalogId: kCatalogId, productId: kDishId),
        picker: picker,
      ));
      await tester.pumpAndSettle();

      await tapButton(
        tester,
        find.byKey(const ValueKey('rep_dish_replace_photo')),
      );

      // Uploaded, SCOPED TO THE DISH, and not yet bound: a rep who changes the
      // photo and the name together sends one write, not two.
      expect(repo.uploadedFor, [kDishId]);
      expect(repo.dishPatches, isEmpty);

      // And the card shows the new bytes rather than the photo being replaced.
      final card = tester.widget<PreviewProductCard>(
        find.byType(PreviewProductCard),
      );
      expect(card.overrideImageBytes, isNotNull);

      await tapButton(tester, find.byKey(const ValueKey('rep_dish_save')));

      expect(repo.dishPatches.single.imageKey, 'uploaded-image-key');
      // One upload, not two — the save did not re-send the bytes.
      expect(repo.uploadedFor, hasLength(1));
    });

    testWidgets('a failed save keeps the form and says what went wrong',
        (tester) async {
      final repo = FakeRepRepository()
        ..dishFailure = const CatalogFailure(
          code: 'DUPLICATE_NAME',
          message: 'ignored — we use our own sentence',
        );
      await tester.pumpWidget(harness(
        repo,
        const RepDishEditorScreen(catalogId: kCatalogId, productId: kDishId),
      ));
      await tester.pumpAndSettle();

      await tester.enterText(
        find.byKey(const ValueKey('rep_dish_name')),
        'mysore_masala_dosa',
      );
      await tester.pump();
      await tapButton(tester, find.byKey(const ValueKey('rep_dish_save')));

      // The typed value survives — blanking the form over a failed write is how
      // a rep loses the edit twice.
      final field = tester.widget<EditableText>(
        find.descendant(
          of: find.byKey(const ValueKey('rep_dish_name')),
          matching: find.byType(EditableText),
        ),
      );
      expect(field.controller.text, 'mysore_masala_dosa');
      // And the server's own prose is never what is shown.
      expect(find.textContaining('ignored'), findsNothing);
    });
  });

  group('the restaurant details screen is the owner screen, scoped', () {
    testWidgets('loads and saves through the DELEGATED repository',
        (tester) async {
      final repo = FakeRepRepository();
      await tester.pumpWidget(harness(
        repo,
        const BusinessProfileScreen.delegated(catalogId: kCatalogId),
        width: 500,
      ));
      await tester.pumpAndSettle();

      // Named for whose it is, so a rep working three restaurants in a day can
      // tell which form is in front of them.
      expect(find.text('Restaurant details'), findsOneWidget);

      await tester.enterText(find.byType(TextFormField).first, 'Blue Cafe');
      await tester.pump();
      await tapButton(tester, find.text('Save profile'));

      // THE ASSERTION THAT MATTERS: the write went through the rep seam, at
      // this catalog. A scope that failed to reach the repository would have
      // written to the rep's own (nonexistent) catalog instead.
      expect(repo.profilePatches, hasLength(1));
      expect(repo.profilePatches.single.catalogId, kCatalogId);
      expect(repo.profilePatches.single.name, 'Blue Cafe');
    });

    testWidgets('sends the WHOLE contact block, never a delta', (tester) async {
      final repo = FakeRepRepository();
      await tester.pumpWidget(harness(
        repo,
        const BusinessProfileScreen.delegated(catalogId: kCatalogId),
      ));
      await tester.pumpAndSettle();

      await tester.enterText(find.byType(TextFormField).first, 'Blue Cafe');
      await tester.pump();
      await tapButton(tester, find.text('Save profile'));

      // The server REPLACES the block, so a delta silently wipes every field it
      // omits — the address a rep typed on a previous visit included.
      final contact = repo.profilePatches.single.contact!;
      expect(contact.phone, isNotNull);
      expect(contact.address, isNotNull);
      expect(contact.email, isNotNull);
    });
  });

  group('the menu preview', () {
    testWidgets('composes the page from the delegated reads', (tester) async {
      final repo = FakeRepRepository();
      await tester.pumpWidget(harness(
        repo,
        const RepMenuPreviewScreen(catalogId: kCatalogId),
        height: 1200,
      ));
      await tester.pumpAndSettle();

      expect(find.text('Menu preview'), findsOneWidget);
      // Its own possessive — "your public page" is wrong when the reader is
      // standing in someone else's restaurant.
      expect(
        find.textContaining("the restaurant's public page"),
        findsOneWidget,
      );
      expect(find.byType(PreviewProductCard), findsOneWidget);
    });
  });
}
