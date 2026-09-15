// lib/presentation/widgets/catalog/product_view_controls.dart
//
// The Sort lens and the labelled chip row it is drawn with — shared by the
// catalog page and its preview, so "Newest" means the same thing on both and a
// sort added to one cannot quietly go missing from the other.
//
// The sort is a LENS, never a request. The server lists products in one order
// only (`position`, the one the author sets by dragging), and the public page
// has its own; everything here reorders what is already on screen. On the
// catalog page that is the loaded pages — a sort over page 1 is a sort over
// page 1, which is why the grid keeps loading pages under it instead of
// pretending the lens is a query.
import 'package:flutter/material.dart';

import '../../../app/theme/app_colors.dart';
import '../../../app/theme/app_spacing.dart';
import '../../../app/theme/app_typography.dart';
import '../../../domain/entities/catalog_product.dart';

/// How a product surface orders what it shows.
///
/// [menuOrder] is the catalog's own order — the one the author set and the
/// only one that is a claim about the page. The rest are lenses on the draft.
enum ProductSort {
  menuOrder('Menu order'),
  newest('Newest'),
  oldest('Oldest'),
  priceHigh('Price: high first'),
  priceLow('Price: low first'),
  nameAz('Name A–Z');

  const ProductSort(this.label);

  final String label;

  bool get isDefault => this == ProductSort.menuOrder;
}

/// [products] in [sort] order. Never sorts the caller's list.
List<CatalogProduct> sortProducts(
  List<CatalogProduct> products,
  ProductSort sort,
) {
  if (sort.isDefault) return products;
  final out = [...products];
  switch (sort) {
    case ProductSort.menuOrder:
      break;
    // A product with no date sorts LAST in both directions rather than
    // pretending to be the oldest thing in the menu.
    case ProductSort.newest:
      out.sort((a, b) => _compareDates(b.createdAt, a.createdAt));
    case ProductSort.oldest:
      out.sort((a, b) => _compareDates(a.createdAt, b.createdAt));
    // Priceless products sort last too — the public card has no price line
    // for them, so they are not "free", they are unanswered.
    case ProductSort.priceHigh:
      out.sort((a, b) => _comparePrices(b.price, a.price));
    case ProductSort.priceLow:
      out.sort((a, b) => _comparePrices(a.price, b.price));
    case ProductSort.nameAz:
      out.sort((a, b) =>
          a.displayName.toLowerCase().compareTo(b.displayName.toLowerCase()));
  }
  return out;
}

/// Null sorts last whichever way the comparison is running.
int _compareDates(DateTime? a, DateTime? b) {
  if (a == null && b == null) return 0;
  if (a == null) return 1;
  if (b == null) return -1;
  return a.compareTo(b);
}

int _comparePrices(double? a, double? b) {
  if (a == null && b == null) return 0;
  if (a == null) return 1;
  if (b == null) return -1;
  return a.compareTo(b);
}

/// One labelled, horizontally scrolling row of chips — "SORT", then the
/// options; "SHOW", then the filters.
///
/// A scrolling row rather than a menu: the options are few, naming them all is
/// cheaper to read than opening something, and the row doubles as the display
/// of what is currently on — which a closed menu cannot do.
class ControlRow extends StatelessWidget {
  const ControlRow({super.key, required this.label, required this.children});

  final String label;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md),
          child: Text(
            label.toUpperCase(),
            style: const TextStyle(
              fontSize: AppTypography.sizeLabel,
              fontWeight: FontWeight.w700,
              letterSpacing: 1.2,
              color: AppColors.textMuted,
            ),
          ),
        ),
        const SizedBox(height: AppSpacing.sm),
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md),
          child: Row(
            children: [
              for (final child in children)
                Padding(
                  padding: const EdgeInsets.only(right: AppSpacing.sm),
                  child: child,
                ),
            ],
          ),
        ),
      ],
    );
  }
}

/// The bordered panel both rows sit in.
class ViewControlsPanel extends StatelessWidget {
  const ViewControlsPanel({super.key, required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(vertical: AppSpacing.md),
        decoration: BoxDecoration(
          color: AppColors.surface1,
          borderRadius: BorderRadius.circular(AppRadius.sm),
          border: Border.all(color: AppColors.surface2),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: children,
        ),
      );
}
