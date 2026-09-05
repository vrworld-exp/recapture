// lib/domain/catalog/publish_gate.dart
//
// The reasons a catalog cannot publish, as the client renders them.
//
// TWO producers, ONE type, and the distinction matters:
//   • the SERVER's set, parsed by [PublishGate.fromMap] out of
//     `POST /catalog/publish` (422) and `GET /catalog/publish/status`. That set
//     is AUTHORITATIVE — it is what the publish endpoint itself evaluated, and
//     it can see things the client cannot (whether the source ProjectModel
//     finished, whether Mirage is configured on this deployment at all).
//   • the CLIENT's approximation, [evaluateDraftGates], which the catalog
//     PREVIEW runs over the draft it already holds so a per-product warning can
//     appear without a publish round trip (and while B4/B5 are still in flight).
//
// The client set is a strict SUBSET of the server's, never a second opinion: it
// only asserts the rules that are decidable from a product DTO. A gate it
// cannot evaluate is simply absent — preview under-reports rather than
// promising a publish will succeed. The publish screen renders the server's set
// and nothing else.
//
// Both sets are ReCapture's own sentences. Nothing here is ever built from
// Mirage prose — the backend maps upstream failures onto UPPER_SNAKE codes
// before they leave it, and this file only ever handles those codes.
import '../entities/catalog_json.dart';
import '../entities/catalog_product.dart';
import '../entities/product_type.dart';

/// Every reason a catalog cannot publish. Mirrors the backend's
/// `PublishGateCode` exactly — hand-synced, because there is no shared package
/// (AGENTS.md §0.1).
///
/// [unknown] is the defensive fallback for a code this build does not know: a
/// client one deploy behind must still render the checklist row (with the
/// server's own sentence) rather than dropping a blocker on the floor.
enum PublishGateCode {
  catalogEmpty,
  catalogNameMissing,
  productAssetMissing,
  productThumbnailMissing,
  productModelNotReady,
  productNameDuplicate,
  publishingUnavailable,
  unknown,
}

extension PublishGateCodeX on PublishGateCode {
  /// Must match the backend `PublishGateCode` exactly.
  String get apiValue => switch (this) {
        PublishGateCode.catalogEmpty => 'CATALOG_EMPTY',
        PublishGateCode.catalogNameMissing => 'CATALOG_NAME_MISSING',
        PublishGateCode.productAssetMissing => 'PRODUCT_ASSET_MISSING',
        PublishGateCode.productThumbnailMissing => 'PRODUCT_THUMBNAIL_MISSING',
        PublishGateCode.productModelNotReady => 'PRODUCT_MODEL_NOT_READY',
        PublishGateCode.productNameDuplicate => 'PRODUCT_NAME_DUPLICATE',
        PublishGateCode.publishingUnavailable => 'PUBLISHING_UNAVAILABLE',
        PublishGateCode.unknown => 'UNKNOWN',
      };

  static PublishGateCode fromApiValue(String value) =>
      switch (value.toUpperCase()) {
        'CATALOG_EMPTY' => PublishGateCode.catalogEmpty,
        'CATALOG_NAME_MISSING' => PublishGateCode.catalogNameMissing,
        'PRODUCT_ASSET_MISSING' => PublishGateCode.productAssetMissing,
        'PRODUCT_THUMBNAIL_MISSING' => PublishGateCode.productThumbnailMissing,
        'PRODUCT_MODEL_NOT_READY' => PublishGateCode.productModelNotReady,
        'PRODUCT_NAME_DUPLICATE' => PublishGateCode.productNameDuplicate,
        'PUBLISHING_UNAVAILABLE' => PublishGateCode.publishingUnavailable,
        _ => PublishGateCode.unknown,
      };

  /// The label on the affordance that takes the user to the fix, or null when
  /// there is nothing to navigate to (waiting for a preview to finish
  /// generating, or an operator-side outage).
  ///
  /// Null is a real answer here, not a gap: offering "Fix" for a gate whose
  /// only resolution is to wait sends the user to a screen where nothing they
  /// can do will help.
  String? get fixLabel => switch (this) {
        PublishGateCode.catalogEmpty => 'Add a product',
        PublishGateCode.catalogNameMissing => 'Name your catalog',
        PublishGateCode.productAssetMissing => 'Open product',
        PublishGateCode.productNameDuplicate => 'Rename',
        PublishGateCode.productThumbnailMissing => null,
        PublishGateCode.productModelNotReady => null,
        PublishGateCode.publishingUnavailable => null,
        PublishGateCode.unknown => null,
      };

  /// Whether time alone clears this. Drives the "waiting" treatment: a gate the
  /// user cannot act on must not be dressed as a task they are ignoring.
  bool get resolvesItself =>
      this == PublishGateCode.productThumbnailMissing ||
      this == PublishGateCode.productModelNotReady;
}

/// One failing gate — a checklist row on the publish screen, and a per-product
/// warning in the preview.
class PublishGate {
  const PublishGate({
    required this.code,
    required this.message,
    this.productId,
    this.productName,
  });

  final PublishGateCode code;

  /// OUR sentence. From the server it is the backend's own owner-safe copy;
  /// from [evaluateDraftGates] it is this file's mirror of that copy. Never
  /// upstream prose either way, so it is safe to render as-is.
  final String message;

  /// The product this gate is about, when it is about one. Null for the
  /// catalog-level gates (empty catalog, missing name, publishing unavailable).
  final String? productId;
  final String? productName;

  bool get isAboutProduct => productId != null;

  /// Defensive parsing — an unknown code keeps the server's sentence and
  /// renders as a blocker, which is the safe direction to be wrong in.
  factory PublishGate.fromMap(Map<String, dynamic> map) => PublishGate(
        code: PublishGateCodeX.fromApiValue((map['code'] ?? '').toString()),
        message: catalogText(map['message']) ??
            'This catalog is not ready to publish yet.',
        productId: catalogText(map['productId']),
        productName: catalogText(map['productName']),
      );

  /// Parses the `gates` array carried by a 422 PUBLISH_BLOCKED body and by the
  /// status payload. A malformed row is skipped, never rendered blank.
  static List<PublishGate> listFrom(Object? raw) => [
        if (raw is List)
          for (final item in raw)
            if (item is Map<String, dynamic>) PublishGate.fromMap(item),
      ];
}

/// Groups [gates] by the product they are about. Catalog-level gates (no
/// `productId`) are not in the result — read those with [catalogLevelGates].
Map<String, List<PublishGate>> gatesByProductId(List<PublishGate> gates) {
  final byProduct = <String, List<PublishGate>>{};
  for (final gate in gates) {
    final id = gate.productId;
    if (id == null) continue;
    (byProduct[id] ??= <PublishGate>[]).add(gate);
  }
  return byProduct;
}

/// The gates that are about the catalog rather than one product.
List<PublishGate> catalogLevelGates(List<PublishGate> gates) => [
      for (final gate in gates)
        if (!gate.isAboutProduct) gate,
    ];

/// The client's approximation of the server's gate set, over the draft the
/// preview already holds.
///
/// [products] must be the LIVE products — the caller filters archived ones out,
/// exactly as the backend's `publishableProducts` does, because an archived
/// product is not published and must not be reported as blocking.
///
/// Deliberately NOT evaluated here, and the omissions are the point:
///   • `PRODUCT_MODEL_NOT_READY` needs the source ProjectModel's status and its
///     project's ownership — neither is on the product DTO.
///   • `PUBLISHING_UNAVAILABLE` is a property of the deployment.
/// The preview says so in its own copy: it is a pre-flight check, not the
/// verdict. The verdict is the publish screen's, and it comes from the server.
List<PublishGate> evaluateDraftGates({
  required String catalogName,
  required List<CatalogProduct> products,
}) {
  final gates = <PublishGate>[];

  if (products.isEmpty) {
    gates.add(const PublishGate(
      code: PublishGateCode.catalogEmpty,
      message: 'Add at least one product before publishing.',
    ));
  }

  if (catalogName.trim().isEmpty) {
    gates.add(const PublishGate(
      code: PublishGateCode.catalogNameMissing,
      message: 'Give your catalog a name before publishing.',
    ));
  }

  for (final product in products) {
    gates.addAll(_gateProduct(product));
  }
  gates.addAll(_gateDuplicateNames(products));

  return gates;
}

/// Per-product asset rules, mirroring the backend's `gateProduct`.
///
/// The asymmetry is deliberate and copied verbatim from the server: a 3D
/// product needs BOTH its model and its generated preview image, because
/// Mirage's card shows the image while the GLB streams — published without one
/// it is a blank tile on a customer's phone for as long as the model takes.
///
/// A product of `ProductType.unknown` is treated as image-only, matching
/// `ProductTypeX.supportsThreeD`: the strictly less capable reading, so a
/// client one deploy behind under-claims instead of inventing a 3D blocker.
List<PublishGate> _gateProduct(CatalogProduct product) {
  final id = product.id;
  final name = product.name;
  final hasThumbnail = product.thumbnailUrl?.isNotEmpty ?? false;

  if (product.type.supportsThreeD) {
    return [
      if (!(product.glbUrl?.isNotEmpty ?? false))
        PublishGate(
          code: PublishGateCode.productAssetMissing,
          message: '"$name" has no 3D model yet.',
          productId: id,
          productName: name,
        ),
      if (!hasThumbnail)
        PublishGate(
          code: PublishGateCode.productThumbnailMissing,
          message: '"$name" is still generating its preview image. '
              'Try again shortly.',
          productId: id,
          productName: name,
        ),
    ];
  }

  return [
    if (!hasThumbnail)
      PublishGate(
        code: PublishGateCode.productAssetMissing,
        message: '"$name" has no photo yet.',
        productId: id,
        productName: name,
      ),
  ];
}

/// Mirage keys items by name within a restaurant and there is no repair at
/// publish time — a run cannot know which of two identically-named products the
/// user meant. So the collision is reported against EVERY row involved, not
/// just the second one, exactly as the backend does.
List<PublishGate> _gateDuplicateNames(List<CatalogProduct> products) {
  final byName = <String, List<CatalogProduct>>{};
  for (final product in products) {
    (byName[product.name.trim().toLowerCase()] ??= <CatalogProduct>[])
        .add(product);
  }

  return [
    for (final group in byName.values)
      if (group.length > 1)
        for (final product in group)
          PublishGate(
            code: PublishGateCode.productNameDuplicate,
            message: 'More than one product is called "${product.name}". '
                'Rename one of them.',
            productId: product.id,
            productName: product.name,
          ),
  ];
}
