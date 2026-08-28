// lib/domain/entities/catalog_category.dart
import 'catalog_json.dart';
import 'product_sync_status.dart';

/// Maximum category name length — mirrors the backend Zod bound.
const int kMaxCategoryNameLength = 80;

/// A grouping of products within the catalog (features 22-26).
///
/// "Uncategorized" is NOT one of these: a product with no category has a null
/// `categoryId`, and the uncategorized bucket is a synthetic row the UI renders
/// from `uncategorizedCount` on the list response. Modelling it as a real
/// category here would mean the client could rename or delete it.
class CatalogCategory {
  const CatalogCategory({
    required this.id,
    required this.name,
    required this.position,
    this.productCount = 0,
    this.syncStatus = ProductSyncStatus.never,
    this.syncError,
    this.updatedAt,
    this.createdAt,
  });

  final String id;
  final String name;

  /// Sort key within the catalog. Sparse and server-assigned; the client sends a
  /// full ordered id list to reorder rather than computing positions itself.
  final int position;

  /// Products currently in this category. Drives the "3 products will move to
  /// Uncategorized" confirmation on delete — deleting a grouping must never look
  /// like it deletes the things inside it.
  final int productCount;

  final ProductSyncStatus syncStatus;

  /// OUR message for the last sync failure. The backend never passes Mirage's
  /// own prose through, so this is safe to show as-is.
  final String? syncError;

  final DateTime? updatedAt;
  final DateTime? createdAt;

  bool get isEmpty => productCount == 0;

  factory CatalogCategory.fromMap(Map<String, dynamic> map) => CatalogCategory(
        id: (map['id'] ?? '').toString(),
        name: catalogText(map['name']) ?? 'Untitled category',
        position: catalogCount(map['position']),
        productCount: catalogCount(map['productCount']),
        syncStatus:
            ProductSyncStatusX.fromApiValue((map['syncStatus'] ?? '').toString()),
        syncError: catalogText(map['syncError']),
        updatedAt: catalogDate(map['updatedAt']),
        createdAt: catalogDate(map['createdAt']),
      );

  Map<String, dynamic> toMap() => {
        'id': id,
        'name': name,
        'position': position,
        'productCount': productCount,
        'syncStatus': syncStatus.apiValue,
        'syncError': syncError,
        'updatedAt': updatedAt?.toIso8601String(),
        'createdAt': createdAt?.toIso8601String(),
      };

  CatalogCategory copyWith({
    String? name,
    int? position,
    int? productCount,
  }) =>
      CatalogCategory(
        id: id,
        name: name ?? this.name,
        position: position ?? this.position,
        productCount: productCount ?? this.productCount,
        syncStatus: syncStatus,
        syncError: syncError,
        updatedAt: updatedAt,
        createdAt: createdAt,
      );
}

/// One page of the category list, plus the uncategorized bucket's size.
///
/// The two travel together because the category manager always renders the
/// bucket alongside the real categories — fetching them separately would make
/// the bucket's count lag its own list by one request.
class CatalogCategoryList {
  const CatalogCategoryList({
    required this.categories,
    required this.uncategorizedCount,
  });

  final List<CatalogCategory> categories;

  /// Products with no category (feature 26). Always rendered, even at 0, so the
  /// bucket does not appear and disappear as products move.
  final int uncategorizedCount;

  static const empty = CatalogCategoryList(
    categories: <CatalogCategory>[],
    uncategorizedCount: 0,
  );
}
