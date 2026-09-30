// lib/data/repositories/menu_translations_repository.dart
import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../domain/catalog/menu_languages.dart';
import '../../domain/entities/business_profile.dart';
import '../../domain/entities/catalog_category.dart';
import '../../domain/entities/catalog_product.dart';
import '../remote/api_client.dart';
import 'catalog_failure.dart';

/// Everything the Translations screen reads, in one load.
class MenuTranslationsData {
  const MenuTranslationsData({
    required this.profile,
    required this.products,
    required this.categories,
  });

  final BusinessProfile profile;

  /// Every live, unarchived dish, in catalog order.
  final List<CatalogProduct> products;
  final List<CatalogCategory> categories;
}

/// Data access for multi-language menus (more-customization Stage 6).
///
/// A repository of its own rather than new methods on the profile / product
/// repositories, whose interfaces every screen test fakes — the translation
/// writes are only ever made from the two Stage 6 surfaces.
///
/// Every translation write MERGES per language on the server: saving the Hindi
/// text of a dish never touches its Tamil. Like every authoring write it bumps
/// the draft revision, so the change reaches the menu at the next Publish.
///
/// Every method throws [CatalogFailure] on failure — never a [DioException].
abstract interface class MenuTranslationsRepository {
  /// Profile + every dish + every category. Null when there is no catalog.
  Future<MenuTranslationsData?> load();

  /// Replaces which languages the menu is offered in.
  Future<BusinessProfile> updateLanguages(MenuLanguages languages);

  /// The announcement and badge labels in [lang]; an empty [text] removes them.
  Future<BusinessProfile> updateCatalogText(MenuLanguage lang, CatalogLanguageText text);

  /// One dish in [lang]; an empty [translation] removes that language.
  Future<CatalogProduct> updateDish(String productId, MenuLanguage lang, DishTranslation translation);

  /// One section name in [lang]; a blank [name] removes that language.
  Future<CatalogCategory> updateCategory(String categoryId, MenuLanguage lang, String name);
}

class RemoteMenuTranslationsRepository implements MenuTranslationsRepository {
  const RemoteMenuTranslationsRepository(this._dio);

  final Dio _dio;

  /// The product list is paged at 100 (the API's ceiling). A menu is tens of
  /// dishes; the page cap only stops a runaway loop on a malformed cursor.
  static const int _pageSize = 100;
  static const int _maxPages = 20;

  @override
  Future<MenuTranslationsData?> load() async {
    try {
      final profileRes = await _dio.get<Map<String, dynamic>>('/catalog/profile');
      final profile = _profileFrom(profileRes.data);

      final products = <CatalogProduct>[];
      String? cursor;
      for (var page = 0; page < _maxPages; page++) {
        final res = await _dio.get<Map<String, dynamic>>(
          '/catalog/products',
          queryParameters: {'limit': _pageSize, if (cursor != null) 'cursor': cursor},
        );
        final items = res.data?['items'];
        if (items is List) {
          for (final item in items) {
            if (item is Map<String, dynamic>) products.add(CatalogProduct.fromMap(item));
          }
        }
        final next = res.data?['nextCursor'];
        if (next is! String || next.isEmpty) break;
        cursor = next;
      }

      final catRes = await _dio.get<Map<String, dynamic>>('/catalog/categories');
      final rawCats = catRes.data?['categories'];
      return MenuTranslationsData(
        profile: profile,
        products: products,
        categories: [
          if (rawCats is List)
            for (final item in rawCats)
              if (item is Map<String, dynamic>) CatalogCategory.fromMap(item),
        ],
      );
    } on DioException catch (error) {
      final failure = CatalogFailure.fromDio(error);
      if (failure.isNoCatalog) return null;
      throw failure;
    }
  }

  @override
  Future<BusinessProfile> updateLanguages(MenuLanguages languages) => mapCatalogErrors(() async {
        final res = await _dio.patch<Map<String, dynamic>>(
          '/catalog/profile',
          data: {'languages': languages.toMap()},
        );
        return _profileFrom(res.data);
      });

  @override
  Future<BusinessProfile> updateCatalogText(MenuLanguage lang, CatalogLanguageText text) =>
      mapCatalogErrors(() async {
        final res = await _dio.patch<Map<String, dynamic>>(
          '/catalog/profile',
          // An explicit null removes the language; the server does the same
          // for an entry left with nothing in it.
          data: {
            'i18n': {lang.code: text.isEmpty ? null : text.toMap()},
          },
        );
        return _profileFrom(res.data);
      });

  @override
  Future<CatalogProduct> updateDish(
    String productId,
    MenuLanguage lang,
    DishTranslation translation,
  ) =>
      mapCatalogErrors(() async {
        final res = await _dio.patch<Map<String, dynamic>>(
          '/catalog/products/$productId',
          data: {
            'i18n': {lang.code: translation.isEmpty ? null : translation.toMap()},
          },
        );
        final product = res.data?['product'];
        if (product is! Map<String, dynamic>) throw _malformed;
        return CatalogProduct.fromMap(product);
      });

  @override
  Future<CatalogCategory> updateCategory(String categoryId, MenuLanguage lang, String name) =>
      mapCatalogErrors(() async {
        final res = await _dio.patch<Map<String, dynamic>>(
          '/catalog/categories/$categoryId',
          data: {
            'i18n': {
              lang.code: name.trim().isEmpty ? null : {'name': name.trim()},
            },
          },
        );
        final category = res.data?['category'];
        if (category is! Map<String, dynamic>) throw _malformed;
        return CatalogCategory.fromMap(category);
      });

  static const _malformed = CatalogFailure(
    code: 'MALFORMED_RESPONSE',
    message: 'Something went wrong. Please try again.',
  );

  BusinessProfile _profileFrom(Map<String, dynamic>? body) {
    final profile = body?['profile'];
    if (profile is! Map<String, dynamic>) throw _malformed;
    return BusinessProfile.fromMap(profile);
  }
}

final menuTranslationsRepositoryProvider = Provider<MenuTranslationsRepository>(
  (ref) => RemoteMenuTranslationsRepository(ref.watch(dioProvider)),
);
