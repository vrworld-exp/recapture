// lib/domain/entities/catalog_product.dart
import 'catalog_json.dart';
import 'product_availability.dart';
import 'product_sync_status.dart';
import 'product_type.dart';

/// Bounds mirrored from the backend Zod schema so the editor rejects an
/// over-long value locally instead of after a 400.
const int kMaxProductNameLength = 120;
const int kMaxProductDescriptionLength = 2000;
const int kMaxProductTags = 20;
const int kMaxProductTagLength = 40;

/// One item in the business's catalog (features 6-21).
///
/// Either a 3D product backed by a finished capture, or an image-only product
/// that is a photo, a name and a price ([type]).
///
/// Several fields are ReCapture-only and never reach a customer: [tags],
/// [availability], [featured] and [position] all have no home in Mirage's item
/// schema. The editor must say so where it offers them, rather than implying
/// they change the public page.
class CatalogProduct {
  const CatalogProduct({
    required this.id,
    required this.type,
    required this.name,
    required this.currency,
    required this.position,
    this.description,
    this.price,
    this.categoryId,
    this.tags = const <String>[],
    this.availability = ProductAvailability.inStock,
    this.featured = false,
    this.glbUrl,
    this.usdzUrl,
    this.thumbnailUrl,
    this.syncStatus = ProductSyncStatus.never,
    this.syncError,
    this.isArchived = false,
    this.updatedAt,
    this.createdAt,
  });

  final String id;
  final ProductType type;
  final String name;
  final String? description;

  /// Null means no price set — deliberately not 0, which would read as "free".
  final double? price;

  /// ISO currency code; the backend defaults it to INR. Mirage stores no
  /// currency at all, so this is a ReCapture-side display concern.
  final String currency;

  /// Null = Uncategorized (feature 26).
  final String? categoryId;

  /// ⚠ ReCapture-only — Mirage has no tags field on its item schema.
  final List<String> tags;

  /// ⚠ ReCapture-only — out-of-stock cannot be shown to customers.
  final ProductAvailability availability;

  /// ⚠ ReCapture-only — affects ordering inside the app, nothing public.
  final bool featured;

  /// Sort key within the catalog. ⚠ ReCapture-only: Mirage sorts the public page
  /// by creation date and stores no position (feature 48).
  final int position;

  /// OUR CloudFront URLs, frozen at create time from the source capture. Null on
  /// an image-only product. The publish worker streams the bytes to Mirage; the
  /// client uses these directly for preview and AR.
  final String? glbUrl;
  final String? usdzUrl;

  /// The card image: the model's generated preview for a 3D product, the
  /// uploaded photo for an image-only one.
  final String? thumbnailUrl;

  final ProductSyncStatus syncStatus;

  /// OUR message for the last sync failure — the backend never passes Mirage's
  /// prose through, so this is safe to show as-is.
  final String? syncError;

  /// Archived products are hidden from the grid and removed from the public
  /// catalog on the next publish, but are restorable (features 19-20).
  final bool isArchived;

  final DateTime? updatedAt;
  final DateTime? createdAt;

  /// Whether this product can be opened in the 3D viewer / AR right now.
  bool get canViewInThreeD => type.supportsThreeD && (glbUrl?.isNotEmpty ?? false);

  /// Uncategorized (feature 26).
  bool get isUncategorized => categoryId == null;

  /// The last publish left this product broken and it needs the user (feature 68).
  bool get hasSyncFailure => syncStatus.needsAttention;

  /// Defensive parsing — every field falls back to a safe value so one malformed
  /// row never crashes the product grid.
  factory CatalogProduct.fromMap(Map<String, dynamic> map) => CatalogProduct(
        id: (map['id'] ?? '').toString(),
        type: ProductTypeX.fromApiValue((map['type'] ?? '').toString()),
        name: catalogText(map['name']) ?? 'Untitled product',
        description: catalogText(map['description']),
        price: catalogPrice(map['price']),
        currency: catalogText(map['currency']) ?? 'INR',
        categoryId: catalogText(map['categoryId']),
        tags: catalogStringList(map['tags']),
        availability: ProductAvailabilityX.fromApiValue(
          (map['availability'] ?? '').toString(),
        ),
        featured: map['featured'] == true,
        position: catalogCount(map['position']),
        glbUrl: catalogText(map['glbUrl']),
        usdzUrl: catalogText(map['usdzUrl']),
        thumbnailUrl: catalogText(map['thumbnailUrl']),
        syncStatus:
            ProductSyncStatusX.fromApiValue((map['syncStatus'] ?? '').toString()),
        syncError: catalogText(map['syncError']),
        isArchived: map['isArchived'] == true,
        updatedAt: catalogDate(map['updatedAt']),
        createdAt: catalogDate(map['createdAt']),
      );

  /// Serialises to the same shape [CatalogProduct.fromMap] reads, for warm-start
  /// caching. Server-truth still wins on screen open.
  Map<String, dynamic> toMap() => {
        'id': id,
        'type': type.apiValue,
        'name': name,
        'description': description,
        'price': price,
        'currency': currency,
        'categoryId': categoryId,
        'tags': tags,
        'availability': availability.apiValue,
        'featured': featured,
        'position': position,
        'glbUrl': glbUrl,
        'usdzUrl': usdzUrl,
        'thumbnailUrl': thumbnailUrl,
        'syncStatus': syncStatus.apiValue,
        'syncError': syncError,
        'isArchived': isArchived,
        'updatedAt': updatedAt?.toIso8601String(),
        'createdAt': createdAt?.toIso8601String(),
      };

  /// Returns a copy with the given fields replaced, for in-place list updates
  /// (a featured toggle, an archive) so the grid never has to refetch.
  ///
  /// `categoryId` is a [Object?] sentinel rather than a plain `String?` because
  /// null is a MEANINGFUL value here (Uncategorized) and must be distinguishable
  /// from "not changing it".
  CatalogProduct copyWith({
    String? name,
    String? description,
    double? price,
    Object? categoryId = _unset,
    List<String>? tags,
    ProductAvailability? availability,
    bool? featured,
    int? position,
    ProductSyncStatus? syncStatus,
    String? syncError,
    bool? isArchived,
    DateTime? updatedAt,
  }) =>
      CatalogProduct(
        id: id,
        type: type,
        name: name ?? this.name,
        description: description ?? this.description,
        price: price ?? this.price,
        currency: currency,
        categoryId: identical(categoryId, _unset)
            ? this.categoryId
            : categoryId as String?,
        tags: tags ?? this.tags,
        availability: availability ?? this.availability,
        featured: featured ?? this.featured,
        position: position ?? this.position,
        glbUrl: glbUrl,
        usdzUrl: usdzUrl,
        thumbnailUrl: thumbnailUrl,
        syncStatus: syncStatus ?? this.syncStatus,
        syncError: syncError ?? this.syncError,
        isArchived: isArchived ?? this.isArchived,
        updatedAt: updatedAt ?? this.updatedAt,
        createdAt: createdAt,
      );
}

/// Sentinel for "argument not supplied" where null is itself a valid value.
const Object _unset = Object();
