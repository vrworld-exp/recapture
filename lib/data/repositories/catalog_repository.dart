// lib/data/repositories/catalog_repository.dart
import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../domain/entities/business_profile.dart';
import '../../domain/entities/catalog.dart';
import '../../domain/entities/catalog_category.dart';
import '../remote/api_client.dart';
import 'catalog_failure.dart';

/// Data access for the catalog root and its categories.
///
/// Categories live here rather than in their own repository because they are not
/// independently addressable — there is exactly one catalog per account, and a
/// category has no meaning outside it. Products are big enough to justify their
/// own file ([CatalogProductsRepository]); categories are not.
///
/// Every method throws [CatalogFailure] on failure — never a [DioException].
abstract interface class CatalogRepository {
  /// The caller's catalog, or **null when they have none yet**.
  ///
  /// The server answers 404 CATALOG_NOT_FOUND for that state, and this is the
  /// one place it is translated into a value: "you have no catalog" is the
  /// first-run flow, not an error the UI should show.
  Future<Catalog?> fetch();

  /// Creates the caller's catalog. Idempotent server-side — a second call
  /// returns the existing catalog rather than erroring, so a retry after a lost
  /// response is safe.
  Future<Catalog> create({required String name, String? businessName});

  /// Updates catalog metadata. Bumps the draft revision server-side, so the
  /// returned catalog already carries the refreshed `hasUnpublishedChanges`.
  ///
  /// [contact] REPLACES the whole contact block when supplied — pass the full
  /// block, not a delta (that is also what makes clearing one field possible).
  Future<Catalog> update({
    String? name,
    String? businessName,
    BusinessContact? contact,
  });

  /// The catalog's categories plus the uncategorized bucket's size.
  Future<CatalogCategoryList> listCategories();

  Future<CatalogCategory> createCategory(String name);

  Future<CatalogCategory> renameCategory(String id, String name);

  /// Deletes a category and returns how many products moved to Uncategorized —
  /// the confirmation copy needs that number, because deleting a grouping must
  /// never look like it deleted the products inside it.
  Future<int> deleteCategory(String id);

  /// Writes a new category order. Send the FULL ordered id list: the server
  /// rejects a partial set with ID_SET_MISMATCH rather than guessing.
  Future<void> reorderCategories(List<String> orderedIds);
}

/// Concrete [CatalogRepository] over the app Dio (Bearer attach + 401-refresh
/// via `AuthInterceptor`).
class RemoteCatalogRepository implements CatalogRepository {
  const RemoteCatalogRepository(this._dio);

  final Dio _dio;

  @override
  Future<Catalog?> fetch() async {
    try {
      final res = await _dio.get<Map<String, dynamic>>('/catalog');
      return _catalogFrom(res.data);
    } on DioException catch (error) {
      final failure = CatalogFailure.fromDio(error);
      if (failure.isNoCatalog) return null;
      throw failure;
    }
  }

  @override
  Future<Catalog> create({required String name, String? businessName}) =>
      mapCatalogErrors(() async {
        final res = await _dio.post<Map<String, dynamic>>(
          '/catalog',
          data: {
            'name': name,
            // The schema is `.strict()`; a null businessName would be rejected,
            // so an absent value must be an absent KEY.
            if (businessName != null) 'businessName': businessName,
          },
        );
        return _catalogFrom(res.data);
      });

  @override
  Future<Catalog> update({
    String? name,
    String? businessName,
    BusinessContact? contact,
  }) =>
      mapCatalogErrors(() async {
        final res = await _dio.patch<Map<String, dynamic>>(
          '/catalog',
          data: {
            if (name != null) 'name': name,
            if (businessName != null) 'businessName': businessName,
            if (contact != null) 'contact': contact.toMap(),
          },
        );
        return _catalogFrom(res.data);
      });

  @override
  Future<CatalogCategoryList> listCategories() => mapCatalogErrors(() async {
        final res = await _dio.get<Map<String, dynamic>>('/catalog/categories');
        final raw = res.data?['categories'];
        return CatalogCategoryList(
          categories: [
            if (raw is List)
              for (final item in raw)
                if (item is Map<String, dynamic>) CatalogCategory.fromMap(item),
          ],
          uncategorizedCount: switch (res.data?['uncategorizedCount']) {
            final num n when n >= 0 => n.toInt(),
            _ => 0,
          },
        );
      });

  @override
  Future<CatalogCategory> createCategory(String name) => mapCatalogErrors(() async {
        final res = await _dio.post<Map<String, dynamic>>(
          '/catalog/categories',
          data: {'name': name},
        );
        return _categoryFrom(res.data);
      });

  @override
  Future<CatalogCategory> renameCategory(String id, String name) =>
      mapCatalogErrors(() async {
        final res = await _dio.patch<Map<String, dynamic>>(
          '/catalog/categories/$id',
          data: {'name': name},
        );
        return _categoryFrom(res.data);
      });

  @override
  Future<int> deleteCategory(String id) => mapCatalogErrors(() async {
        final res = await _dio.delete<Map<String, dynamic>>('/catalog/categories/$id');
        final moved = res.data?['movedProductCount'];
        return moved is num && moved >= 0 ? moved.toInt() : 0;
      });

  @override
  Future<void> reorderCategories(List<String> orderedIds) => mapCatalogErrors(() async {
        await _dio.post<Map<String, dynamic>>(
          '/catalog/categories/reorder',
          data: {'ids': orderedIds},
        );
      });

  /// Unwraps `{status:"success", catalog:{...}}`. A 2xx without the payload is a
  /// broken contract, not an empty result — fail loudly rather than rendering a
  /// blank catalog the user would try to fix by re-creating one.
  Catalog _catalogFrom(Map<String, dynamic>? body) {
    final catalog = body?['catalog'];
    if (catalog is! Map<String, dynamic>) {
      throw const CatalogFailure(
        code: 'MALFORMED_RESPONSE',
        message: 'Something went wrong. Please try again.',
      );
    }
    return Catalog.fromMap(catalog);
  }

  CatalogCategory _categoryFrom(Map<String, dynamic>? body) {
    final category = body?['category'];
    if (category is! Map<String, dynamic>) {
      throw const CatalogFailure(
        code: 'MALFORMED_RESPONSE',
        message: 'Something went wrong. Please try again.',
      );
    }
    return CatalogCategory.fromMap(category);
  }
}

/// App-wide catalog repository.
final catalogRepositoryProvider = Provider<CatalogRepository>(
  (ref) => RemoteCatalogRepository(ref.watch(dioProvider)),
);
