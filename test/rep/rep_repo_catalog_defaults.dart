// test/rep/rep_repo_catalog_defaults.dart
//
// The delegated-CATALOG half of [RepRepository], stubbed out for the fakes that
// only care about standees, activation, dishes or publishing.
//
// Same reasoning and the same trade as [CatalogRepoDeleteDefaults] over in
// test/catalog: the restaurant-details and dish-editing surfaces landed eight
// methods on the one seam every rep fake implements, so every pre-existing fake
// suddenly owed eight more. One edit here beats forty `throw
// UnimplementedError()` lines spread over five files, and a fake that DOES
// exercise one of them simply overrides it.
//
// They throw rather than answering an empty value. A test that reaches one of
// these is asserting on a call it never meant to make, and a silent empty
// profile would let that pass — while also being the exact shape a real bug
// takes.
import 'package:flutter/foundation.dart' show Uint8List;
import 'package:recapture/data/repositories/catalog_repository.dart'
    show BrandingSlot;
import 'package:recapture/data/repositories/catalog_products_repository.dart'
    show kCatalogUnchanged;
import 'package:recapture/domain/entities/qr_standee.dart';
import 'package:recapture/data/repositories/rep_repository.dart';
import 'package:recapture/domain/entities/business_profile.dart';
import 'package:recapture/domain/entities/catalog.dart';
import 'package:recapture/domain/entities/catalog_category.dart';
import 'package:recapture/domain/entities/catalog_product.dart';
import 'package:recapture/domain/entities/product_availability.dart';

mixin RepRepoCatalogDefaults implements RepRepository {
  /// The published history is empty unless a test says otherwise — most of
  /// these suites are about a single visit, not a career.
  @override
  Future<RepPublishedPage> publishedStandees({int? days}) async =>
      const RepPublishedPage(standees: [], total: 0);

  @override
  Future<Catalog> catalog(String catalogId) =>
      throw UnimplementedError('rep catalog read is not exercised by this test');

  @override
  Future<CatalogCategoryList> categories(String catalogId) =>
      throw UnimplementedError('rep categories are not exercised by this test');

  @override
  Future<CatalogCategory> createCategory(String catalogId, String name) =>
      throw UnimplementedError(
        'rep category create is not exercised by this test',
      );

  @override
  Future<CatalogCategory> renameCategory(
    String catalogId,
    String categoryId,
    String name,
  ) =>
      throw UnimplementedError(
        'rep category rename is not exercised by this test',
      );

  @override
  Future<int> deleteCategory(String catalogId, String categoryId) =>
      throw UnimplementedError(
        'rep category delete is not exercised by this test',
      );

  @override
  Future<void> reorderCategories(String catalogId, List<String> orderedIds) =>
      throw UnimplementedError(
        'rep category reorder is not exercised by this test',
      );

  @override
  Future<BusinessProfile> profile(String catalogId) =>
      throw UnimplementedError('rep profile read is not exercised by this test');

  @override
  Future<BusinessProfile> updateProfile(
    String catalogId, {
    String? name,
    String? businessName,
    BusinessContact? contact,
  }) =>
      throw UnimplementedError(
        'rep profile write is not exercised by this test',
      );

  @override
  Future<String> uploadBrandingBytes(
    String catalogId,
    Uint8List bytes, {
    required BrandingSlot slot,
    required String contentType,
  }) =>
      throw UnimplementedError(
        'rep branding upload is not exercised by this test',
      );

  @override
  Future<BusinessProfile> commitBranding(
    String catalogId, {
    required BrandingSlot slot,
    required String key,
  }) =>
      throw UnimplementedError(
        'rep branding commit is not exercised by this test',
      );

  @override
  Future<CatalogProduct> product(String catalogId, String productId) =>
      throw UnimplementedError('rep dish read is not exercised by this test');

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
  }) =>
      throw UnimplementedError('rep dish edit is not exercised by this test');
}
