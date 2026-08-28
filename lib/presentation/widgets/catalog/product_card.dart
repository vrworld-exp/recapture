// lib/presentation/widgets/catalog/product_card.dart
//
// One product in the catalog grid. Pure presentation — every action is an
// injected callback, matching `project_card.dart`, so the card holds no
// business logic and can be laid out in a test at any width.
import 'package:flutter/material.dart';

import '../../../app/theme/app_colors.dart';
import '../../../app/theme/app_spacing.dart';
import '../../../app/theme/app_typography.dart';
import '../../../domain/entities/catalog_product.dart';
import '../../../domain/entities/product_availability.dart';
import '../../../domain/entities/product_type.dart';
import '../../../utils/price_format.dart';
import '../app_status_pill.dart';

/// A single product card.
///
/// What it shows, and why each one earns its place on a card the user scans
/// rather than reads:
///   • the thumbnail — the generated preview for a 3D product, the uploaded
///     photo for an image-only one; both arrive as [CatalogProduct.thumbnailUrl]
///   • the type badge — 3D and image-only behave differently everywhere else in
///     the app, so the difference is visible before the card is opened
///   • the sync pill — a product whose last publish FAILED must be findable by
///     scrolling the grid, not by opening every product in turn (feature 68)
///   • out of stock and featured — ReCapture-only flags, marked plainly, never
///     dressed up as something the customer sees
class ProductCard extends StatelessWidget {
  const ProductCard({
    super.key,
    required this.product,
    this.onTap,
    this.onMore,
    this.dragHandle,
    this.isSelected,
    this.onSelectedChanged,
  });

  final CatalogProduct product;

  /// Opens the product. Null renders the card inert (used by the preview, which
  /// shows the same card with nothing behind it).
  final VoidCallback? onTap;

  /// Opens the overflow menu. Null hides the button — archive/restore/delete
  /// land with their own task, and a menu button that opens nothing is worse
  /// than no menu button.
  final VoidCallback? onMore;

  /// The reorder affordance, and the drag source itself. Rendered at every
  /// width — on a phone long-press already means "select", so the handle is the
  /// only gesture left. Null whenever reordering is not meaningful (any
  /// filtered view, or while bulk selection is active).
  final Widget? dragHandle;

  /// Selection mode (bulk actions). Null means selection is not active — the
  /// checkbox is not rendered at all rather than rendered disabled.
  final bool? isSelected;
  final ValueChanged<bool>? onSelectedChanged;

  bool get _selectable => isSelected != null;

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    final price = formatPrice(product.price, product.currency);

    final card = Container(
      decoration: BoxDecoration(
        color: AppColors.surface1,
        borderRadius: BorderRadius.circular(AppRadius.sm),
        border: Border.all(
          color: isSelected == true
              ? AppColors.mirageRed.withValues(alpha: 0.8)
              : AppColors.royalGold.withValues(alpha: 0.15),
          width: isSelected == true ? 1.5 : 0.5,
        ),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          AspectRatio(
            aspectRatio: 1,
            child: Stack(
              fit: StackFit.expand,
              children: [
                _Thumbnail(url: product.thumbnailUrl, type: product.type),
                Positioned(
                  top: AppSpacing.sm,
                  left: AppSpacing.sm,
                  child: _TypeBadge(type: product.type),
                ),
                if (product.featured)
                  const Positioned(
                    top: AppSpacing.sm,
                    right: AppSpacing.sm,
                    child: _FeaturedMarker(),
                  ),
                // The pill sits ON the image so it survives a narrow column,
                // where the text block below is already fighting for two lines.
                Positioned(
                  bottom: AppSpacing.sm,
                  left: AppSpacing.sm,
                  right: AppSpacing.sm,
                  // spaceBetween rather than a Spacer: a Spacer is a TIGHT
                  // flex child, so it claims half the free width and squeezes
                  // the pill beside it below the width of its own icon in a
                  // two-column phone grid. Alignment pushes the two apart
                  // without either of them competing for space.
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Flexible(
                        child: SyncStatusPill(status: product.syncStatus),
                      ),
                      if (product.isArchived) ...[
                        const SizedBox(width: AppSpacing.xs),
                        const Flexible(child: _ArchivedBadge()),
                      ],
                    ],
                  ),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(AppSpacing.md),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: Text(
                        product.name,
                        // Two lines then an ellipsis: a 120-character product
                        // name is legal server-side, and unbounded text in a
                        // grid cell is an overflow, not a long name.
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: textTheme.bodyLarge,
                      ),
                    ),
                    if (dragHandle != null) dragHandle!,
                    if (onMore != null)
                      SizedBox(
                        width: 32,
                        height: 32,
                        child: IconButton(
                          padding: EdgeInsets.zero,
                          iconSize: 18,
                          visualDensity: VisualDensity.compact,
                          tooltip: 'Product options',
                          icon: const Icon(
                            Icons.more_vert,
                            color: AppColors.textSecondary,
                          ),
                          onPressed: onMore,
                        ),
                      ),
                  ],
                ),
                const SizedBox(height: AppSpacing.xs),
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        // No price is its own sentence. Rendering 0 here would
                        // quietly turn "not priced yet" into "free".
                        price ?? 'No price set',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: textTheme.bodyMedium?.copyWith(
                          color: price == null
                              ? AppColors.textMuted
                              : AppColors.textPrimary,
                        ),
                      ),
                    ),
                    if (product.availability ==
                        ProductAvailability.outOfStock) ...[
                      const SizedBox(width: AppSpacing.xs),
                      const _OutOfStockBadge(),
                    ],
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );

    // Archived products stay legible but visibly inactive — they are not gone,
    // and Restore is the action that matters on them.
    final body = product.isArchived
        ? Opacity(opacity: 0.55, child: card)
        : card;

    return Semantics(
      button: onTap != null,
      selected: isSelected,
      label: _semanticLabel(price),
      child: Material(
        type: MaterialType.transparency,
        child: InkWell(
          // InkWell, not GestureDetector: it brings the web hover highlight and
          // keyboard focus traversal with it, both of which this grid needs on
          // the browser build and neither of which is worth hand-rolling.
          borderRadius: BorderRadius.circular(AppRadius.sm),
          hoverColor: AppColors.surface2,
          focusColor: AppColors.surface2,
          onTap: _selectable
              ? () => onSelectedChanged?.call(!(isSelected ?? false))
              : onTap,
          onLongPress: onSelectedChanged == null
              ? null
              : () => onSelectedChanged!.call(!(isSelected ?? false)),
          child: Stack(
            children: [
              body,
              if (_selectable)
                Positioned(
                  top: AppSpacing.xs,
                  right: AppSpacing.xs,
                  child: _SelectionCheck(selected: isSelected ?? false),
                ),
            ],
          ),
        ),
      ),
    );
  }

  /// One sentence a screen reader can say instead of five separate labels.
  String _semanticLabel(String? price) {
    final parts = <String>[
      product.name,
      product.type.label,
      if (price != null) price,
      if (product.availability == ProductAvailability.outOfStock) 'Out of stock',
      if (product.featured) 'Featured',
      if (product.isArchived) 'Archived',
      if (product.hasSyncFailure) 'Last publish failed',
    ];
    return parts.join(', ');
  }
}

/// The card image, with a placeholder for a null URL and for one that 404s.
///
/// A thumbnail URL can go stale — the object is behind CloudFront and the
/// product row outlives any single asset — so the error path is not an edge
/// case. It renders the same placeholder as a missing URL: a broken-image glyph
/// tells the user nothing they can act on.
class _Thumbnail extends StatelessWidget {
  const _Thumbnail({required this.url, required this.type});

  final String? url;
  final ProductType type;

  @override
  Widget build(BuildContext context) {
    if (url == null || url!.isEmpty) return _ThumbnailPlaceholder(type: type);
    return Image.network(
      url!,
      fit: BoxFit.cover,
      errorBuilder: (_, __, ___) => _ThumbnailPlaceholder(type: type),
      loadingBuilder: (context, child, progress) => progress == null
          ? child
          : Container(
              color: AppColors.surface2,
              alignment: Alignment.center,
              child: const SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: AppColors.textMuted,
                ),
              ),
            ),
    );
  }
}

class _ThumbnailPlaceholder extends StatelessWidget {
  const _ThumbnailPlaceholder({required this.type});

  final ProductType type;

  @override
  Widget build(BuildContext context) => Container(
        color: AppColors.surface2,
        alignment: Alignment.center,
        child: Icon(
          type.supportsThreeD
              ? Icons.view_in_ar_outlined
              : Icons.image_outlined,
          color: AppColors.textMuted,
          size: 28,
        ),
      );
}

/// 3D vs image-only, on the image where the eye already is.
class _TypeBadge extends StatelessWidget {
  const _TypeBadge({required this.type});

  final ProductType type;

  @override
  Widget build(BuildContext context) {
    final threeD = type.supportsThreeD;
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.sm,
        vertical: 2,
      ),
      decoration: BoxDecoration(
        color: AppColors.bgPrimary.withValues(alpha: 0.75),
        borderRadius: BorderRadius.circular(AppRadius.xs),
        border: Border.all(
          color: (threeD ? AppColors.royalGold : AppColors.textMuted)
              .withValues(alpha: 0.4),
          width: 0.5,
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            threeD ? Icons.view_in_ar : Icons.image_outlined,
            size: 11,
            color: threeD ? AppColors.royalGold : AppColors.textSecondary,
          ),
          const SizedBox(width: AppSpacing.xs),
          Text(
            threeD ? '3D' : 'Image',
            style: TextStyle(
              fontSize: AppTypography.sizeLabel,
              fontWeight: FontWeight.w500,
              height: 1.0,
              color: threeD ? AppColors.royalGold : AppColors.textSecondary,
            ),
          ),
        ],
      ),
    );
  }
}

class _FeaturedMarker extends StatelessWidget {
  const _FeaturedMarker();

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.all(AppSpacing.xs),
        decoration: BoxDecoration(
          color: AppColors.bgPrimary.withValues(alpha: 0.75),
          shape: BoxShape.circle,
        ),
        // Tooltip, not a label: the word "Featured" would not fit next to a
        // 120-character name, and this flag changes nothing a customer sees.
        child: const Tooltip(
          message: 'Featured in your app only',
          child: Icon(Icons.star, size: 13, color: AppColors.royalGold),
        ),
      );
}

class _OutOfStockBadge extends StatelessWidget {
  const _OutOfStockBadge();

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.sm,
          vertical: 2,
        ),
        decoration: BoxDecoration(
          color: AppColors.warning.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(AppRadius.xs),
          border: Border.all(
            color: AppColors.warning.withValues(alpha: 0.35),
            width: 0.5,
          ),
        ),
        child: const Text(
          'Out of stock',
          style: TextStyle(
            fontSize: AppTypography.sizeLabel,
            fontWeight: FontWeight.w500,
            height: 1.0,
            color: AppColors.warning,
          ),
        ),
      );
}

class _ArchivedBadge extends StatelessWidget {
  const _ArchivedBadge();

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.sm,
          vertical: 2,
        ),
        decoration: BoxDecoration(
          color: AppColors.bgPrimary.withValues(alpha: 0.8),
          borderRadius: BorderRadius.circular(AppRadius.xs),
          border: Border.all(
            color: AppColors.textMuted.withValues(alpha: 0.5),
            width: 0.5,
          ),
        ),
        child: const Text(
          'Archived',
          maxLines: 1,
          softWrap: false,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            fontSize: AppTypography.sizeLabel,
            fontWeight: FontWeight.w500,
            height: 1.0,
            color: AppColors.textSecondary,
          ),
        ),
      );
}

class _SelectionCheck extends StatelessWidget {
  const _SelectionCheck({required this.selected});

  final bool selected;

  @override
  Widget build(BuildContext context) => Container(
        width: 24,
        height: 24,
        decoration: BoxDecoration(
          color: selected ? AppColors.mirageRed : AppColors.bgPrimary,
          shape: BoxShape.circle,
          border: Border.all(
            color: selected ? AppColors.mirageRed : AppColors.textMuted,
            width: 1.5,
          ),
        ),
        child: selected
            ? const Icon(Icons.check, size: 15, color: AppColors.textPrimary)
            : null,
      );
}
