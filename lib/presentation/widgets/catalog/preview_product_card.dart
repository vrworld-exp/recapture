// lib/presentation/widgets/catalog/preview_product_card.dart
//
// One product as a CUSTOMER would meet it: a full-bleed image or 3D viewer, a
// dark gradient, the name and price over it, a 3D/photo badge, and an AR chip
// where AR can actually run. Modelled on mirage-fe's `MenuItemCard`, which is
// what the published page really renders.
//
// Deliberately NOT `ProductCard`. That card is an AUTHORING row — sync pill,
// featured star, out-of-stock marker, overflow menu — and every one of those is
// ReCapture-only. Reusing it would make the preview show a page no customer
// will ever see, which is the one thing a preview must not do.
//
// THE 3D MODEL IS OPT-IN, PER CARD, AND ONLY ONE AT A TIME. The public page can
// mount a viewer per visible card because a browser IntersectionObserver
// unmounts the off-screen ones and the whole page is one JS runtime. Here each
// viewer is a platform WebView, and ten of them scrolling on a phone is an
// out-of-memory crash, not a slow page. So the card shows the real thumbnail
// (which is what a customer sees first anyway, while the GLB streams) and loads
// the model when asked — which doubles as the answer to "very large GLB on a
// low-end device": nothing downloads until the user says so, and the hint on
// the button says why.
import 'package:flutter/material.dart';

import '../../../app/theme/app_colors.dart';
import '../../../app/theme/app_spacing.dart';
import '../../../app/theme/app_typography.dart';
import '../../../domain/catalog/publish_gate.dart';
import '../../../domain/entities/catalog_product.dart';
import '../../../domain/entities/product_type.dart';
import '../../../utils/price_format.dart';
import '../../screens/projects/model_render_view.dart';

class PreviewProductCard extends StatelessWidget {
  const PreviewProductCard({
    super.key,
    required this.product,
    required this.height,
    this.gates = const <PublishGate>[],
    this.isThreeDActive = false,
    this.onLoadThreeD,
    this.onUnloadThreeD,
    this.onFix,
  });

  final CatalogProduct product;

  /// The card's media height, derived by the caller from the viewport so the
  /// preview keeps the public page's "about two cards per screen" rhythm.
  final double height;

  /// Publish gates this product trips. Rendered as a warning strip UNDER the
  /// card rather than over it: the card is the customer's view and must stay
  /// clean, while the warning is the author's and must be impossible to miss.
  final List<PublishGate> gates;

  /// Whether this is the one card currently rendering a live viewer.
  final bool isThreeDActive;

  /// Mounts the viewer on this card (and unmounts whichever had it).
  final VoidCallback? onLoadThreeD;

  /// Drops back to the thumbnail, freeing the WebView.
  final VoidCallback? onUnloadThreeD;

  /// Opens the product editor at the thing the gate is about.
  final VoidCallback? onFix;

  bool get _canShowThreeD => product.canViewInThreeD;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(AppRadius.md),
          child: SizedBox(
            height: height,
            child: Stack(
              fit: StackFit.expand,
              children: [
                _media(),
                // The public page's cinematic scrim. Also what makes white text
                // legible over an arbitrary customer photo.
                const DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.bottomCenter,
                      end: Alignment.topCenter,
                      colors: [
                        Color(0xE60B0B0E),
                        Color(0x330B0B0E),
                        Color(0x000B0B0E),
                      ],
                      stops: [0.0, 0.45, 1.0],
                    ),
                  ),
                ),
                Positioned(
                  top: AppSpacing.md,
                  right: AppSpacing.md,
                  child: _TypeBadge(product: product),
                ),
                Positioned(
                  left: AppSpacing.lg,
                  right: AppSpacing.lg,
                  bottom: AppSpacing.lg,
                  child: _Caption(
                    product: product,
                    canShowThreeD: _canShowThreeD,
                    isThreeDActive: isThreeDActive,
                    onLoadThreeD: onLoadThreeD,
                    onUnloadThreeD: onUnloadThreeD,
                  ),
                ),
              ],
            ),
          ),
        ),
        if (gates.isNotEmpty) ...[
          const SizedBox(height: AppSpacing.sm),
          _WarningStrip(gates: gates, onFix: onFix),
        ],
      ],
    );
  }

  /// The media layer this card would build right now.
  ///
  /// Exposed for `test/projects/meshopt_decoder_test.dart`, which has to prove
  /// the preview's 3D path goes through [ModelRenderView] — the widget that
  /// carries the meshopt decoder configuration. A raw `ModelViewer` dropped in
  /// here would render every UNOPTIMIZED model perfectly and fail on every
  /// optimized one, on both platforms, with nothing in the build to notice it.
  /// It cannot be checked by pumping the card: the real viewer drives a WebView
  /// with no platform implementation in a widget test.
  @visibleForTesting
  Widget debugMedia() => _media();

  Widget _media() {
    if (isThreeDActive && _canShowThreeD) {
      // The viewer owns its own loading skin and its own inline failure body
      // with a retry, so a GLB that will not load leaves this ONE card showing
      // an error instead of blanking the preview.
      return ModelRenderView.forUrls(
        key: ValueKey('preview_viewer_${product.id}'),
        glbUrl: product.glbUrl,
        usdzUrl: product.usdzUrl,
        // No permanently-muted AR chip on a desktop browser — see the flag's
        // doc on ModelRenderView. Mobile web still gets the real one.
        showArCtaWhenUnavailable: false,
      );
    }
    return _PreviewThumbnail(product: product);
  }
}

/// The card image. A 3D product's is its generated preview, an image-only
/// product's is the uploaded photo — both arrive as `thumbnailUrl`, and its
/// absence is itself a publish gate, so the placeholder here says so plainly
/// rather than pretending an image is on its way.
class _PreviewThumbnail extends StatelessWidget {
  const _PreviewThumbnail({required this.product});

  final CatalogProduct product;

  @override
  Widget build(BuildContext context) {
    final url = product.thumbnailUrl;
    if (url == null || url.isEmpty) return const _MissingImage();

    return Image.network(
      url,
      fit: BoxFit.cover,
      errorBuilder: (_, __, ___) => const _MissingImage(),
    );
  }
}

class _MissingImage extends StatelessWidget {
  const _MissingImage();

  @override
  Widget build(BuildContext context) => ColoredBox(
        color: AppColors.surface2,
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.image_not_supported_outlined,
                  color: AppColors.textMuted, size: 32),
              const SizedBox(height: AppSpacing.sm),
              Text(
                'No image yet',
                style: Theme.of(context)
                    .textTheme
                    .bodySmall
                    ?.copyWith(color: AppColors.textMuted),
              ),
            ],
          ),
        ),
      );
}

/// The public page's top-right pill: 3D or photo.
class _TypeBadge extends StatelessWidget {
  const _TypeBadge({required this.product});

  final CatalogProduct product;

  @override
  Widget build(BuildContext context) {
    final threeD = product.type.supportsThreeD;
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.sm,
        vertical: AppSpacing.xs,
      ),
      decoration: BoxDecoration(
        color: AppColors.bgPrimary.withValues(alpha: 0.6),
        borderRadius: BorderRadius.circular(AppRadius.xs),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            threeD ? Icons.view_in_ar_outlined : Icons.photo_outlined,
            size: 12,
            color: AppColors.mirageRed,
          ),
          const SizedBox(width: AppSpacing.xs),
          Text(
            threeD ? '3D' : 'PHOTO',
            style: const TextStyle(
              fontSize: AppTypography.sizeLabel,
              fontWeight: FontWeight.w700,
              letterSpacing: 1.2,
              color: AppColors.textPrimary,
            ),
          ),
        ],
      ),
    );
  }
}

/// Name, price and the 3D affordance, over the scrim — the public page's
/// bottom overlay.
class _Caption extends StatelessWidget {
  const _Caption({
    required this.product,
    required this.canShowThreeD,
    required this.isThreeDActive,
    required this.onLoadThreeD,
    required this.onUnloadThreeD,
  });

  final CatalogProduct product;
  final bool canShowThreeD;
  final bool isThreeDActive;
  final VoidCallback? onLoadThreeD;
  final VoidCallback? onUnloadThreeD;

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    final price = formatPrice(product.price, product.currency);

    return Row(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                product.name,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: textTheme.titleMedium?.copyWith(
                  color: AppColors.textPrimary,
                  fontWeight: FontWeight.w700,
                ),
              ),
              // No price is NOT rendered as a zero: the public card simply has
              // no price line, and so does this one (mirage-fe hides it below
              // 1). Showing "₹0" here would preview a claim the customer will
              // never see.
              if (price != null) ...[
                const SizedBox(height: AppSpacing.xs),
                Text(
                  price,
                  style: textTheme.bodyMedium?.copyWith(
                    color: AppColors.textPrimary,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ],
          ),
        ),
        if (canShowThreeD) ...[
          const SizedBox(width: AppSpacing.sm),
          _ThreeDButton(
            active: isThreeDActive,
            onPressed: isThreeDActive ? onUnloadThreeD : onLoadThreeD,
          ),
        ],
      ],
    );
  }
}

class _ThreeDButton extends StatelessWidget {
  const _ThreeDButton({required this.active, required this.onPressed});

  final bool active;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) => Tooltip(
        message: active
            ? 'Show the card image again'
            : 'Loads the 3D model — these can be several megabytes, so it may '
                'take a moment on a slow connection or an older phone.',
        child: Material(
          key: ValueKey(active ? 'preview_3d_hide' : 'preview_3d_show'),
          color: active
              ? AppColors.surface2.withValues(alpha: 0.92)
              : AppColors.mirageRed,
          borderRadius: BorderRadius.circular(AppRadius.lg),
          child: InkWell(
            onTap: onPressed,
            borderRadius: BorderRadius.circular(AppRadius.lg),
            child: Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: AppSpacing.lg,
                vertical: AppSpacing.sm,
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    active ? Icons.close : Icons.threed_rotation,
                    size: 16,
                    color: AppColors.textPrimary,
                  ),
                  const SizedBox(width: AppSpacing.xs),
                  Text(
                    active ? 'Hide 3D' : 'View in 3D',
                    style: const TextStyle(
                      fontSize: AppTypography.sizeLabel,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 0.8,
                      color: AppColors.textPrimary,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
}

/// The pre-flight half of the preview: what would stop this product publishing.
///
/// Under the card, in the author's colours, never inside the customer view. A
/// gate that clears itself (a preview image still generating) gets the quieter
/// treatment and no Fix button — sending someone to an editor where nothing
/// they can do will help is worse than saying "wait".
class _WarningStrip extends StatelessWidget {
  const _WarningStrip({required this.gates, required this.onFix});

  final List<PublishGate> gates;
  final VoidCallback? onFix;

  @override
  Widget build(BuildContext context) {
    final actionable = [
      for (final gate in gates)
        if (!gate.code.resolvesItself) gate,
    ];
    final color =
        actionable.isEmpty ? AppColors.textMuted : AppColors.warning;
    final fixLabel = actionable.isEmpty
        ? null
        : actionable.first.code.fixLabel;

    return Container(
      padding: const EdgeInsets.all(AppSpacing.md),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(AppRadius.xs),
        border: Border.all(color: color.withValues(alpha: 0.35), width: 0.5),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            actionable.isEmpty
                ? Icons.hourglass_empty
                : Icons.warning_amber_rounded,
            size: 16,
            color: color,
          ),
          const SizedBox(width: AppSpacing.sm),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (final gate in gates)
                  Padding(
                    padding: const EdgeInsets.only(bottom: AppSpacing.xs),
                    // The gate's own sentence, whether it came from the server
                    // or from evaluateDraftGates. Both are ReCapture copy.
                    child: Text(
                      gate.message,
                      style: Theme.of(context)
                          .textTheme
                          .bodySmall
                          ?.copyWith(color: color),
                    ),
                  ),
              ],
            ),
          ),
          if (fixLabel != null && onFix != null) ...[
            const SizedBox(width: AppSpacing.sm),
            TextButton(
              key: const ValueKey('preview_gate_fix'),
              onPressed: onFix,
              child: Text(fixLabel),
            ),
          ],
        ],
      ),
    );
  }
}
