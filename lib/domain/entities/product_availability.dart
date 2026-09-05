// lib/domain/entities/product_availability.dart

/// Whether a product is in stock (feature 8c).
///
/// ⚠ ReCapture-ONLY. Mirage's item schema has no availability field, so this
/// never reaches the public catalog — an out-of-stock product still shows to
/// customers exactly like an in-stock one. The product editor must say so
/// rather than implying customers see it (see 02-feature-to-side-mapping.md,
/// feature 8c).
enum ProductAvailability { inStock, outOfStock, unknown }

extension ProductAvailabilityX on ProductAvailability {
  String get label => switch (this) {
        ProductAvailability.inStock => 'In stock',
        ProductAvailability.outOfStock => 'Out of stock',
        ProductAvailability.unknown => 'Unknown',
      };

  /// API string value — must match the backend `PRODUCT_AVAILABILITIES` exactly.
  String get apiValue => switch (this) {
        ProductAvailability.inStock => 'IN_STOCK',
        ProductAvailability.outOfStock => 'OUT_OF_STOCK',
        ProductAvailability.unknown => 'UNKNOWN',
      };

  static ProductAvailability fromApiValue(String value) => switch (value.toUpperCase()) {
        'IN_STOCK' => ProductAvailability.inStock,
        'OUT_OF_STOCK' => ProductAvailability.outOfStock,
        _ => ProductAvailability.unknown,
      };
}
