// lib/domain/entities/product_type.dart

/// The two kinds of catalog product (feature 7).
///
/// [threeD] is backed by a finished capture — it carries a GLB (and sometimes a
/// USDZ) and renders in the 3D viewer and AR. [imageOnly] is a photo, a name and
/// a price: no model, no AR.
///
/// This maps to Mirage's `imgOnly` boolean at publish time, but the client never
/// sees that field — the ReCapture DTO is the contract.
///
/// [unknown] is a defensive fallback for an unmapped backend value; a product of
/// unknown type renders as image-only (the strictly less capable of the two), so
/// a client one deploy behind degrades instead of promising AR it cannot show.
enum ProductType { threeD, imageOnly, unknown }

extension ProductTypeX on ProductType {
  String get label => switch (this) {
        ProductType.threeD => '3D product',
        ProductType.imageOnly => 'Image only',
        ProductType.unknown => 'Product',
      };

  /// Whether this product can offer a 3D/AR view. Deliberately false for
  /// [ProductType.unknown] — see the enum doc.
  bool get supportsThreeD => this == ProductType.threeD;

  /// API string value — must match the backend `PRODUCT_TYPES` exactly.
  String get apiValue => switch (this) {
        ProductType.threeD => 'THREE_D',
        ProductType.imageOnly => 'IMAGE_ONLY',
        ProductType.unknown => 'UNKNOWN',
      };

  static ProductType fromApiValue(String value) => switch (value.toUpperCase()) {
        'THREE_D' => ProductType.threeD,
        'IMAGE_ONLY' => ProductType.imageOnly,
        _ => ProductType.unknown,
      };
}
