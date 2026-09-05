// lib/domain/catalog/catalog_preview.dart
//
// The composed draft the preview screen renders (feature 5, task T-026).
//
// Built ENTIRELY from ReCapture data — the catalog, its business profile, its
// categories and its products. Never a Mirage read, and not for a technical
// reason: Mirage does not have the draft. The whole point of a pre-publish
// preview is to show what is NOT live yet (feature 57), so reading the live
// page would answer a different question.
//
// Pure Dart, no Flutter import, like every other file under domain/.
import '../entities/business_profile.dart';
import '../entities/catalog.dart';
import '../entities/catalog_category.dart';
import '../entities/catalog_product.dart';
import 'publish_gate.dart';

/// One category's block on the preview page, in the order the sections render.
class CatalogPreviewSection {
  const CatalogPreviewSection({
    required this.id,
    required this.title,
    required this.products,
  });

  /// The category id, or null for the synthetic Uncategorized bucket — which is
  /// a null `categoryId` on the products, never a row the server returns.
  final String? id;

  final String title;
  final List<CatalogProduct> products;

  bool get isUncategorized => id == null;
}

/// Everything the preview screen renders, composed once.
class CatalogPreview {
  CatalogPreview({
    required this.catalog,
    required this.profile,
    required this.sections,
    required this.products,
    required this.gates,
  });

  final Catalog catalog;

  /// Branding for the page header. Null when the profile could not be read —
  /// the header degrades to the catalog's own name rather than failing the
  /// screen, because a missing logo is not a reason to hide the products.
  final BusinessProfile? profile;

  /// Category blocks in their set order, Uncategorized last. Empty categories
  /// are dropped: the public page has no tab for a section with nothing in it.
  final List<CatalogPreviewSection> sections;

  /// Every LIVE product, flat, in catalog order. What the gate evaluation ran
  /// over, and what the counts are derived from.
  final List<CatalogProduct> products;

  /// The client's pre-flight approximation ([evaluateDraftGates]). A strict
  /// subset of what the publish endpoint will decide — see publish_gate.dart.
  final List<PublishGate> gates;

  bool get isEmpty => products.isEmpty;

  /// Warnings for one product, or an empty list. Computed once per preview
  /// rather than per card: the duplicate-name rule is quadratic in the naive
  /// per-card form and the preview scrolls.
  late final Map<String, List<PublishGate>> gatesByProduct =
      gatesByProductId(gates);

  /// Gates about the catalog rather than a product.
  late final List<PublishGate> catalogGates = catalogLevelGates(gates);

  /// How many products carry at least one warning — the headline the banner
  /// leads with, because "3 of 12 products need attention" is the number the
  /// user acts on, not the raw gate count (one product can trip two rules).
  int get productsWithWarnings => gatesByProduct.length;

  bool get hasWarnings => gates.isNotEmpty;

  /// Composes the page from the parts, applying the ordering and grouping rules
  /// in ONE place so the sections, the flat list and the gate set can never
  /// disagree about which products are in the draft.
  ///
  /// Archived products are excluded here and nowhere else: they are hidden from
  /// the public page and dropped from Mirage on the next publish (features
  /// 19-20), so including them would preview a page that will never exist.
  factory CatalogPreview.compose({
    required Catalog catalog,
    required BusinessProfile? profile,
    required List<CatalogCategory> categories,
    required List<CatalogProduct> products,
  }) {
    final live = [
      for (final product in products)
        if (!product.isArchived) product,
    ];

    final ordered = [...categories]
      ..sort((a, b) => a.position.compareTo(b.position));

    final sections = <CatalogPreviewSection>[
      for (final category in ordered)
        if (_inCategory(live, category.id) case final items
            when items.isNotEmpty)
          CatalogPreviewSection(
            id: category.id,
            title: category.name,
            products: items,
          ),
    ];

    // NOTHING MAY FALL OUT OF THE PREVIEW. A product whose `categoryId` names a
    // category this list does not carry — a category deleted on another device,
    // a list read a moment before a rename — is not uncategorized, but it is
    // also not in any section built above, and silently dropping it would make
    // the preview quietly disagree with the catalog about how many products
    // there are. The bucket therefore takes everything the sections did not.
    final placed = {
      for (final section in sections)
        for (final product in section.products) product.id,
    };
    final uncategorized = [
      for (final product in live)
        if (!placed.contains(product.id)) product,
    ];
    if (uncategorized.isNotEmpty) {
      sections.add(CatalogPreviewSection(
        id: null,
        title: 'Uncategorized',
        products: uncategorized,
      ));
    }

    return CatalogPreview(
      catalog: catalog,
      profile: profile,
      sections: sections,
      products: live,
      gates: evaluateDraftGates(
        catalogName: catalog.name,
        products: live,
      ),
    );
  }

  static List<CatalogProduct> _inCategory(
    List<CatalogProduct> products,
    String categoryId,
  ) =>
      [
        for (final product in products)
          if (product.categoryId == categoryId) product,
      ];
}
