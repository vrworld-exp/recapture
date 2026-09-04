// test/catalog/catalog_entities_test.dart
//
// Golden-JSON parsing for the catalog entities.
//
// These DTOs are HAND-SYNCED with the backend's TypeScript DTOs — no shared
// package, no code generation — so nothing but a test catches drift. Each golden
// map below is the exact shape the corresponding `toXDto()` in
// `recapture-api/src/services/catalog*Service.ts` emits; if one of those grows a
// field, this file is where the client notices.
//
// The other half of the job is defensive parsing: a response that is malformed,
// truncated, or newer than this build must RENDER, not crash. Every entity
// therefore parses field by field with a safe fallback, and the "tolerates"
// tests pin those fallbacks — several of them are deliberate product decisions,
// not arbitrary defaults.
import 'package:flutter_test/flutter_test.dart';
import 'package:recapture/domain/entities/business_profile.dart';
import 'package:recapture/domain/entities/catalog.dart';
import 'package:recapture/domain/entities/catalog_category.dart';
import 'package:recapture/domain/entities/catalog_product.dart';
import 'package:recapture/domain/entities/catalog_status.dart';
import 'package:recapture/domain/entities/product_availability.dart';
import 'package:recapture/domain/entities/product_sync_status.dart';
import 'package:recapture/domain/entities/product_model_status.dart';
import 'package:recapture/domain/entities/product_type.dart';

/// Exactly what `toCatalogDto()` emits.
Map<String, dynamic> catalogGolden() => {
      'id': '6a83dd464aea89d1d2d28d50',
      'name': 'Cafe Mocha',
      'businessName': 'Mocha Foods Pvt Ltd',
      'contact': {
        'phone': '+91 90000 00000',
        'email': 'hello@shop.example',
        'address': '12 Market Road, Pune',
        'website': 'https://shop.example',
        'socials': {'instagram': 'mocha', 'whatsapp': '+919000000000'},
      },
      'status': 'PUBLISHED',
      'publicUrl': 'https://menu.example.com/6a83dd464aea89d1d2d28d51',
      'isProvisioned': true,
      'hasUnpublishedChanges': false,
      'lastPublishedAt': '2026-08-17T10:30:00.000Z',
      'isPublishing': false,
      'counts': {'products': 12, 'archivedProducts': 3, 'categories': 4},
      'updatedAt': '2026-08-18T09:00:00.000Z',
      'createdAt': '2026-08-01T09:00:00.000Z',
    };

/// Exactly what `toProductDto()` emits.
Map<String, dynamic> productGolden() => {
      'id': '6a83dd464aea89d1d2d28d60',
      'type': 'THREE_D',
      'name': 'Walnut Chair',
      'description': 'Solid walnut, oil finish.',
      'price': 4999.5,
      'currency': 'INR',
      'categoryId': '6a83dd464aea89d1d2d28d70',
      'tags': ['chair', 'wood'],
      'availability': 'IN_STOCK',
      'featured': true,
      'position': 3,
      'glbUrl': 'https://cdn.example.com/model.glb',
      'usdzUrl': 'https://cdn.example.com/model.usdz',
      'thumbnailUrl': 'https://cdn.example.com/preview.jpg',
      'sourceProjectId': '6a83dd464aea89d1d2d28d80',
      'sourceModelId': '6a83dd464aea89d1d2d28d90',
      'modelStatus': 'READY',
      'syncStatus': 'SYNCED',
      'syncError': null,
      'isArchived': false,
      'updatedAt': '2026-08-18T09:00:00.000Z',
      'createdAt': '2026-08-01T09:00:00.000Z',
    };

/// Exactly what `toCategoryDto()` emits.
Map<String, dynamic> categoryGolden() => {
      'id': '6a83dd464aea89d1d2d28d70',
      'name': 'Chairs',
      'position': 2,
      'productCount': 7,
      'syncStatus': 'FAILED',
      'syncError': 'We could not create this category. Try publishing again.',
      'updatedAt': '2026-08-18T09:00:00.000Z',
      'createdAt': '2026-08-01T09:00:00.000Z',
    };

/// Exactly what `toBusinessProfileDto()` emits.
Map<String, dynamic> profileGolden() => {
      'id': '6a83dd464aea89d1d2d28d50',
      'name': 'Cafe Mocha',
      'businessName': 'Mocha Foods Pvt Ltd',
      'contact': {
        'phone': '+91 90000 00000',
        'email': 'hello@shop.example',
        'address': '12 Market Road, Pune',
        'website': 'https://shop.example',
        'socials': {'instagram': 'mocha'},
      },
      'logoUrl': 'https://cdn.example.com/logo.jpg',
      'coverImageUrl': null,
      'publicFields': ['name', 'contact.phone', 'contact.address', 'logoUrl'],
      'updatedAt': '2026-08-18T09:00:00.000Z',
    };

void main() {
  group('Catalog', () {
    test('parses the golden DTO field by field', () {
      final catalog = Catalog.fromMap(catalogGolden());

      expect(catalog.id, '6a83dd464aea89d1d2d28d50');
      expect(catalog.name, 'Cafe Mocha');
      expect(catalog.businessName, 'Mocha Foods Pvt Ltd');
      expect(catalog.status, CatalogStatus.published);
      expect(catalog.status.isLive, isTrue);
      expect(catalog.publicUrl,
          'https://menu.example.com/6a83dd464aea89d1d2d28d51');
      expect(catalog.isProvisioned, isTrue);
      expect(catalog.hasUnpublishedChanges, isFalse);
      expect(catalog.isPublishing, isFalse);
      expect(
          catalog.lastPublishedAt, DateTime.parse('2026-08-17T10:30:00.000Z'));
      expect(catalog.counts.products, 12);
      expect(catalog.counts.archivedProducts, 3);
      expect(catalog.counts.categories, 4);
      expect(catalog.contact?.phone, '+91 90000 00000');
      expect(catalog.contact?.socials?.instagram, 'mocha');
      // Not sent by the server → stays null rather than becoming ''.
      expect(catalog.contact?.socials?.facebook, isNull);
    });

    test('round-trips through toMap for the warm-start cache', () {
      final original = Catalog.fromMap(catalogGolden());
      final restored = Catalog.fromMap(original.toMap());

      expect(restored.id, original.id);
      expect(restored.name, original.name);
      expect(restored.status, original.status);
      expect(restored.publicUrl, original.publicUrl);
      expect(restored.isProvisioned, original.isProvisioned);
      expect(restored.hasUnpublishedChanges, original.hasUnpublishedChanges);
      expect(restored.lastPublishedAt, original.lastPublishedAt);
      expect(restored.counts.products, original.counts.products);
      expect(restored.contact?.website, original.contact?.website);
    });

    test('tolerates a truncated response without crashing', () {
      final catalog = Catalog.fromMap({'id': 'abc'});

      expect(catalog.id, 'abc');
      expect(catalog.name, 'Untitled catalog');
      expect(catalog.status, CatalogStatus.unknown);
      expect(catalog.publicUrl, isNull);
      expect(catalog.isProvisioned, isFalse);
      expect(catalog.counts.products, 0);
      // No timestamp is null — NOT DateTime.now(), which would read on the
      // publish screen as "published just now".
      expect(catalog.lastPublishedAt, isNull);
      expect(catalog.isNeverPublished, isTrue);
    });

    test('assumes there ARE unpublished changes when the flag is missing', () {
      // Wrongly hiding the badge tells the user their edits are live when they
      // are not; wrongly showing it costs one redundant publish. So absent → true.
      expect(Catalog.fromMap({'id': 'a'}).hasUnpublishedChanges, isTrue);
      expect(
        Catalog.fromMap({'id': 'a', 'hasUnpublishedChanges': false})
            .hasUnpublishedChanges,
        isFalse,
      );
    });

    test('ignores unknown fields from a newer server', () {
      final map = catalogGolden()..['somethingNewWeDoNotKnow'] = {'a': 1};
      expect(Catalog.fromMap(map).name, 'Cafe Mocha');
    });

    test('an unmapped status degrades to unknown, not a crash', () {
      final map = catalogGolden()..['status'] = 'ARCHIVED_SOMEDAY';
      final catalog = Catalog.fromMap(map);
      expect(catalog.status, CatalogStatus.unknown);
      expect(catalog.status.isLive, isFalse);
    });

    test(
        'canPublish is false while a run is in flight or there is nothing to send',
        () {
      final ready = Catalog.fromMap(catalogGolden());
      expect(ready.canPublish, isTrue);

      final publishing =
          Catalog.fromMap(catalogGolden()..['isPublishing'] = true);
      expect(publishing.canPublish, isFalse);

      final empty = Catalog.fromMap(catalogGolden()
        ..['counts'] = {'products': 0, 'archivedProducts': 0, 'categories': 0});
      expect(empty.canPublish, isFalse);
    });

    test('copyWith cannot move the public URL — a printed QR depends on it',
        () {
      final catalog = Catalog.fromMap(catalogGolden());
      final renamed = catalog.copyWith(name: 'Renamed Cafe');

      expect(renamed.name, 'Renamed Cafe');
      // Feature 32: the URL is minted once, server-side, and frozen.
      expect(renamed.publicUrl, catalog.publicUrl);
      expect(renamed.isProvisioned, catalog.isProvisioned);
    });
  });

  group('CatalogProduct', () {
    test('parses the golden DTO field by field', () {
      final product = CatalogProduct.fromMap(productGolden());

      expect(product.id, '6a83dd464aea89d1d2d28d60');
      expect(product.type, ProductType.threeD);
      expect(product.name, 'Walnut Chair');
      expect(product.description, 'Solid walnut, oil finish.');
      expect(product.price, 4999.5);
      expect(product.currency, 'INR');
      expect(product.categoryId, '6a83dd464aea89d1d2d28d70');
      expect(product.tags, ['chair', 'wood']);
      expect(product.availability, ProductAvailability.inStock);
      expect(product.featured, isTrue);
      expect(product.position, 3);
      expect(product.glbUrl, 'https://cdn.example.com/model.glb');
      expect(product.usdzUrl, 'https://cdn.example.com/model.usdz');
      expect(product.thumbnailUrl, 'https://cdn.example.com/preview.jpg');
      // WHICH capture and WHICH of its models — what the model picker opens on.
      expect(product.sourceProjectId, '6a83dd464aea89d1d2d28d80');
      expect(product.sourceModelId, '6a83dd464aea89d1d2d28d90');
      expect(product.syncStatus, ProductSyncStatus.synced);
      expect(product.syncError, isNull);
      expect(product.isArchived, isFalse);
      expect(product.canViewInThreeD, isTrue);
      expect(product.isUncategorized, isFalse);
    });

    test('round-trips through toMap', () {
      final original = CatalogProduct.fromMap(productGolden());
      final restored = CatalogProduct.fromMap(original.toMap());

      expect(restored.type, original.type);
      expect(restored.price, original.price);
      expect(restored.tags, original.tags);
      expect(restored.availability, original.availability);
      expect(restored.featured, original.featured);
      expect(restored.position, original.position);
      expect(restored.glbUrl, original.glbUrl);
      expect(restored.sourceProjectId, original.sourceProjectId);
      expect(restored.sourceModelId, original.sourceModelId);
      expect(restored.syncStatus, original.syncStatus);
    });

    test('the model pointers tolerate a backend that does not send them', () {
      // Additive fields: a client one deploy ahead of the API must render the
      // product, not crash the grid — and an image-only product legitimately
      // has neither.
      final map = productGolden()
        ..remove('sourceProjectId')
        ..remove('sourceModelId');
      final product = CatalogProduct.fromMap(map);

      expect(product.sourceProjectId, isNull);
      expect(product.sourceModelId, isNull);
      expect(product.name, 'Walnut Chair');
    });

    test('an image-only product carries no model URLs and cannot offer 3D', () {
      final product = CatalogProduct.fromMap(productGolden()
        ..['type'] = 'IMAGE_ONLY'
        ..['glbUrl'] = null
        ..['usdzUrl'] = null);

      expect(product.type, ProductType.imageOnly);
      expect(product.canViewInThreeD, isFalse);
      expect(product.thumbnailUrl, isNotNull);
    });

    test('an unknown type never promises 3D or AR', () {
      // A build one deploy behind must degrade to the LESS capable rendering,
      // not offer an AR button that cannot work.
      final product =
          CatalogProduct.fromMap(productGolden()..['type'] = 'HOLOGRAM');
      expect(product.type, ProductType.unknown);
      expect(product.canViewInThreeD, isFalse);
    });

    test('a missing price stays null — "no price" is not "free"', () {
      final product = CatalogProduct.fromMap(productGolden()..['price'] = null);
      expect(product.price, isNull);
      expect(CatalogProduct.fromMap(productGolden()..['price'] = 0).price, 0);
    });

    test('a null categoryId means Uncategorized', () {
      final product =
          CatalogProduct.fromMap(productGolden()..['categoryId'] = null);
      expect(product.categoryId, isNull);
      expect(product.isUncategorized, isTrue);
    });

    test('surfaces a sync failure with our own message', () {
      final product = CatalogProduct.fromMap(productGolden()
        ..['syncStatus'] = 'FAILED'
        ..['syncError'] =
            'A product with this name already exists. Rename it.');

      expect(product.syncStatus, ProductSyncStatus.failed);
      expect(product.hasSyncFailure, isTrue);
      expect(product.syncError, contains('Rename it.'));
    });

    test('tolerates a truncated row', () {
      final product = CatalogProduct.fromMap({'id': 'x'});

      expect(product.name, 'Untitled product');
      expect(product.type, ProductType.unknown);
      expect(product.currency, 'INR');
      expect(product.tags, isEmpty);
      expect(product.availability, ProductAvailability.unknown);
      expect(product.featured, isFalse);
      expect(product.syncStatus, ProductSyncStatus.unknown);
      expect(product.position, 0);
    });

    // ── modelStatus (stage 5/6: a dish on the menu before its model) ────────

    test('parses modelStatus, and AR is gated on it rather than on type', () {
      final ready = CatalogProduct.fromMap(productGolden());
      expect(ready.modelStatus, ProductModelStatus.ready);
      expect(ready.isArReady, isTrue);
      expect(ready.isModelPending, isFalse);

      // A THREE_D dish whose model is still generating: a real, publishable
      // menu item with NO AR button. Gating on `type` would show one.
      final pending = CatalogProduct.fromMap(
        productGolden()
          ..['modelStatus'] = 'PROCESSING'
          ..['glbUrl'] = null,
      );
      expect(pending.type, ProductType.threeD);
      expect(pending.isArReady, isFalse);
      expect(pending.isModelPending, isTrue);

      // FAILED is not pending and not ready — the dish stays on the menu in 2D.
      final failed =
          CatalogProduct.fromMap(productGolden()..['modelStatus'] = 'FAILED');
      expect(failed.isModelPending, isFalse);
      expect(failed.isArReady, isFalse);
    });

    test('an ABSENT modelStatus parses as none rather than throwing', () {
      // THE TEST THAT LETS THE CLIENT ROLL OUT BEFORE OR AFTER THE BACKEND. A
      // server that predates the field sends no `modelStatus`, and the grid has
      // to render anyway — with no AR button, which is the fail-closed answer.
      final map = productGolden()..remove('modelStatus');
      final product = CatalogProduct.fromMap(map);

      expect(product.modelStatus, ProductModelStatus.none);
      expect(product.isArReady, isFalse);
      expect(product.isModelPending, isFalse);
      // And the rest of the row is untouched — one missing field must not cost
      // the dish its name or its price.
      expect(product.name, 'Walnut Chair');
      expect(product.glbUrl, 'https://cdn.example.com/model.glb');
    });

    test('an unrecognised modelStatus fails closed', () {
      final product = CatalogProduct.fromMap(
        productGolden()..['modelStatus'] = 'RENDERING_IN_THE_CLOUD',
      );
      // A client one deploy behind ignores a status it does not know rather
      // than crashing the grid — and promises no AR it cannot show.
      expect(product.modelStatus, ProductModelStatus.none);
      expect(product.isArReady, isFalse);
    });

    test('copyWith carries modelStatus, so a promotion lands in place', () {
      final pending = CatalogProduct.fromMap(
        productGolden()..['modelStatus'] = 'PROCESSING',
      );
      final promoted =
          pending.copyWith(modelStatus: ProductModelStatus.ready);

      expect(promoted.modelStatus, ProductModelStatus.ready);
      // Omitted → unchanged, like every other field on this copyWith.
      expect(pending.copyWith(featured: true).modelStatus,
          ProductModelStatus.processing);
    });

    test('copyWith distinguishes "move to Uncategorized" from "leave it alone"',
        () {
      final product = CatalogProduct.fromMap(productGolden());

      // Omitted → unchanged.
      expect(product.copyWith(featured: false).categoryId, product.categoryId);
      // Explicit null → Uncategorized. A plain `String?` parameter could not
      // express this, which is why the sentinel exists.
      expect(product.copyWith(categoryId: null).categoryId, isNull);
      expect(product.copyWith(categoryId: 'other').categoryId, 'other');
    });
  });

  group('CatalogCategory', () {
    test('parses the golden DTO field by field', () {
      final category = CatalogCategory.fromMap(categoryGolden());

      expect(category.id, '6a83dd464aea89d1d2d28d70');
      expect(category.name, 'Chairs');
      expect(category.position, 2);
      expect(category.productCount, 7);
      expect(category.isEmpty, isFalse);
      expect(category.syncStatus, ProductSyncStatus.failed);
      expect(category.syncStatus.needsAttention, isTrue);
      expect(category.syncError, contains('Try publishing again'));
    });

    test('round-trips through toMap', () {
      final original = CatalogCategory.fromMap(categoryGolden());
      final restored = CatalogCategory.fromMap(original.toMap());

      expect(restored.name, original.name);
      expect(restored.position, original.position);
      expect(restored.productCount, original.productCount);
      expect(restored.syncStatus, original.syncStatus);
      expect(restored.syncError, original.syncError);
    });

    test('tolerates a truncated row', () {
      final category = CatalogCategory.fromMap({'id': 'x'});
      expect(category.name, 'Untitled category');
      expect(category.position, 0);
      expect(category.productCount, 0);
      expect(category.isEmpty, isTrue);
    });
  });

  group('BusinessProfile', () {
    test('parses the golden DTO field by field', () {
      final profile = BusinessProfile.fromMap(profileGolden());

      expect(profile.id, '6a83dd464aea89d1d2d28d50');
      expect(profile.name, 'Cafe Mocha');
      expect(profile.businessName, 'Mocha Foods Pvt Ltd');
      expect(profile.contact?.address, '12 Market Road, Pune');
      expect(profile.contact?.socials?.instagram, 'mocha');
      expect(profile.logoUrl, 'https://cdn.example.com/logo.jpg');
      expect(profile.coverImageUrl, isNull);
      expect(profile.updatedAt, DateTime.parse('2026-08-18T09:00:00.000Z'));
    });

    test('publicFields decides what the UI marks as ReCapture-only', () {
      final profile = BusinessProfile.fromMap(profileGolden());

      // Mirage's update-restaurant carries these.
      expect(profile.isPublic('name'), isTrue);
      expect(profile.isPublic('contact.phone'), isTrue);
      expect(profile.isPublic('contact.address'), isTrue);
      expect(profile.isPublic('logoUrl'), isTrue);
      // These have no home on the public catalog.
      expect(profile.isPublic('businessName'), isFalse);
      expect(profile.isPublic('contact.email'), isFalse);
      expect(profile.isPublic('contact.website'), isFalse);
      expect(profile.isPublic('coverImageUrl'), isFalse);
    });

    test('an absent publicFields marks everything ReCapture-only', () {
      // Understating what reaches customers is the safe direction: the user is
      // never told a field is public when it is not.
      final profile =
          BusinessProfile.fromMap(profileGolden()..remove('publicFields'));
      expect(profile.publicFields, isEmpty);
      expect(profile.isPublic('name'), isFalse);
    });

    test('contact.toMap omits absent fields so a strict PATCH is accepted', () {
      const contact = BusinessContact(phone: '+91 90000 00000');
      final map = contact.toMap();

      expect(map, {'phone': '+91 90000 00000'});
      // The backend schema is `.strict()`; a null email would be a 400, so an
      // absent value must be an absent KEY.
      expect(map.containsKey('email'), isFalse);
      expect(map.containsKey('socials'), isFalse);
    });

    test('an empty socials block is not sent at all', () {
      const contact = BusinessContact(phone: '1', socials: BusinessSocials());
      expect(contact.toMap().containsKey('socials'), isFalse);
    });

    test('blank strings collapse to null so the UI has one "nothing here" case',
        () {
      final profile = BusinessProfile.fromMap(profileGolden()
        ..['businessName'] = '   '
        ..['logoUrl'] = '');

      expect(profile.businessName, isNull);
      expect(profile.logoUrl, isNull);
    });

    test('tolerates a truncated response', () {
      final profile = BusinessProfile.fromMap({'id': 'x'});
      expect(profile.name, '');
      expect(profile.contact, isNull);
      expect(profile.publicFields, isEmpty);
      expect(profile.updatedAt, isNull);
    });
  });

  group('enum API values match the backend constants exactly', () {
    // A drifted string here is a silent 400 at runtime, so pin them literally
    // rather than round-tripping through the parser (which would pass either way).
    test('CatalogStatus', () {
      expect(CatalogStatus.draft.apiValue, 'DRAFT');
      expect(CatalogStatus.published.apiValue, 'PUBLISHED');
      expect(CatalogStatus.unpublished.apiValue, 'UNPUBLISHED');
    });

    test('ProductType', () {
      expect(ProductType.threeD.apiValue, 'THREE_D');
      expect(ProductType.imageOnly.apiValue, 'IMAGE_ONLY');
    });

    test('ProductAvailability', () {
      expect(ProductAvailability.inStock.apiValue, 'IN_STOCK');
      expect(ProductAvailability.outOfStock.apiValue, 'OUT_OF_STOCK');
    });

    test('ProductSyncStatus', () {
      expect(ProductSyncStatus.never.apiValue, 'NEVER');
      expect(ProductSyncStatus.pending.apiValue, 'PENDING');
      expect(ProductSyncStatus.synced.apiValue, 'SYNCED');
      expect(ProductSyncStatus.failed.apiValue, 'FAILED');
    });

    test('parsing is case-insensitive and total', () {
      expect(CatalogStatusX.fromApiValue('published'), CatalogStatus.published);
      expect(ProductTypeX.fromApiValue(''), ProductType.unknown);
      expect(ProductSyncStatusX.fromApiValue('nonsense'),
          ProductSyncStatus.unknown);
      expect(
        ProductAvailabilityX.fromApiValue('out_of_stock'),
        ProductAvailability.outOfStock,
      );
    });
  });
}
