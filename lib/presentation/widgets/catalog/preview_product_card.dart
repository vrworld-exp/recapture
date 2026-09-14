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
//
// ── WHAT THE VISUAL TREATMENT IS DOING ──────────────────────────────────────
// A menu is chosen from, not read, so the card is built to be SCANNED: the
// photo carries the appetite, and everything drawn over it is ranked — name
// first, price second as a gold pill, the 3D affordance as the one saturated
// object on the card. The lift (shadow + hairline) is what makes a column of
// these read as a stack of menu cards rather than as a list of rows.
//
// NOTHING AUTHORING-ONLY MAY ENTER THE FRAME. Every decoration here is
// something the published card also has (photo, name, price, media kind, the
// veg marker); the warning strip stays OUTSIDE, under the card, in the
// author's colours. A prettier card that leaks a sync pill is a broken preview.
import 'package:flutter/foundation.dart' show Uint8List;
import 'package:flutter/material.dart';

import '../../../app/theme/app_colors.dart';
import '../../../app/theme/app_spacing.dart';
import '../../../app/theme/app_typography.dart';
import '../../../domain/catalog/publish_gate.dart';
import '../../../domain/entities/catalog_product.dart';
import '../../../domain/entities/product_type.dart';
import '../../../utils/price_format.dart';
import '../../screens/projects/model_render_view.dart';
import 'food_type_field.dart';

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
    this.overrideImageBytes,
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

  /// A picked-but-not-yet-saved photo, rendered INSTEAD of `thumbnailUrl`.
  ///
  /// The whole reason the rep's dish editor can promise a live preview. Without
  /// it, a rep who picks a new photo sees the card still showing the one they
  /// are replacing — which is the single most misleading thing a screen called
  /// "what a customer will see" could do. Null everywhere else, and the card
  /// falls back to the stored image exactly as before.
  final Uint8List? overrideImageBytes;

  bool get _canShowThreeD => product.canViewInThreeD;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          height: height,
          clipBehavior: Clip.antiAlias,
          decoration: BoxDecoration(
            // An opaque base so the drop shadow has something to sit under
            // while a photo is still streaming in.
            color: AppColors.surface2,
            borderRadius: BorderRadius.circular(AppRadius.lg),
            boxShadow: const [
              BoxShadow(
                color: Color(0x73000000),
                blurRadius: 24,
                offset: Offset(0, 10),
              ),
            ],
          ),
          // Painted OVER the media and under no hit test — a hairline that
          // keeps a dark photo from bleeding into the dark page behind it.
          foregroundDecoration: BoxDecoration(
            borderRadius: BorderRadius.circular(AppRadius.lg),
            border: Border.all(color: const Color(0x14FFFFFF)),
          ),
          child: Stack(
            fit: StackFit.expand,
            children: [
              _media(),
              const _CardScrim(),
              Positioned(
                top: AppSpacing.md,
                right: AppSpacing.md,
                child: _TypeBadge(product: product),
              ),
              // Top-left, exactly where mirage-fe's MenuItemCard puts it.
              // Draws nothing for "no label" — the value decides, not the
              // caller.
              Positioned(
                top: AppSpacing.md,
                left: AppSpacing.md,
                child: FoodTypeMarker(type: product.foodType, size: 16),
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
    return _PreviewThumbnail(
      product: product,
      overrideImageBytes: overrideImageBytes,
    );
  }
}

/// The public page's cinematic scrim, and what makes white text legible over an
/// arbitrary customer photo.
///
/// Four stops rather than three: the extra one near the bottom keeps the name
/// and price on solid ground over a BRIGHT photo — a plated dish shot on a
/// white tablecloth is the common case, and it is exactly where a two-stop
/// gradient gives up.
class _CardScrim extends StatelessWidget {
  const _CardScrim();

  @override
  Widget build(BuildContext context) => const DecoratedBox(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.bottomCenter,
            end: Alignment.topCenter,
            colors: [
              Color(0xF20B0B0E),
              Color(0x9E0B0B0E),
              Color(0x330B0B0E),
              Color(0x000B0B0E),
            ],
            stops: [0.0, 0.34, 0.62, 1.0],
          ),
        ),
      );
}

/// The card image. A 3D product's is its generated preview, an image-only
/// product's is the uploaded photo — both arrive as `thumbnailUrl`, and its
/// absence is itself a publish gate, so the placeholder here says so plainly
/// rather than pretending an image is on its way.
class _PreviewThumbnail extends StatelessWidget {
  const _PreviewThumbnail({required this.product, this.overrideImageBytes});

  final CatalogProduct product;
  final Uint8List? overrideImageBytes;

  @override
  Widget build(BuildContext context) {
    // An unsaved pick WINS over the stored url — it is the newer truth, and it
    // is the one the person looking at this card just chose.
    final bytes = overrideImageBytes;
    if (bytes != null) {
      return Image.memory(
        bytes,
        fit: BoxFit.cover,
        errorBuilder: (_, __, ___) => const _MissingImage(),
      );
    }

    final url = product.thumbnailUrl;
    if (url == null || url.isEmpty) return const _MissingImage();

    return Image.network(
      url,
      fit: BoxFit.cover,
      // A photo that fades in reads as the page loading; one that snaps in
      // reads as the page jumping.
      frameBuilder: (_, child, frame, wasSynchronous) => wasSynchronous
          ? child
          : AnimatedOpacity(
              opacity: frame == null ? 0 : 1,
              duration: const Duration(milliseconds: 260),
              curve: Curves.easeOut,
              child: child,
            ),
      errorBuilder: (_, __, ___) => const _MissingImage(),
    );
  }
}

class _MissingImage extends StatelessWidget {
  const _MissingImage();

  @override
  Widget build(BuildContext context) => DecoratedBox(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [AppColors.surface1, AppColors.surface2],
          ),
        ),
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                padding: const EdgeInsets.all(AppSpacing.md),
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: AppColors.bgPrimary.withValues(alpha: 0.5),
                  border: Border.all(color: const Color(0x14FFFFFF)),
                ),
                child: const Icon(Icons.image_not_supported_outlined,
                    color: AppColors.textMuted, size: 26),
              ),
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
///
/// The two are coloured apart on purpose. "3D" is the thing this product has
/// that most menu items do not, so it carries the gold; a photo is the baseline
/// and stays quiet. A customer scanning a column of cards can find the ones
/// worth turning around without reading a word.
class _TypeBadge extends StatelessWidget {
  const _TypeBadge({required this.product});

  final CatalogProduct product;

  @override
  Widget build(BuildContext context) {
    final threeD = product.type.supportsThreeD;
    final accent = threeD ? AppColors.royalGold : AppColors.textSecondary;
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.sm,
        vertical: AppSpacing.xs,
      ),
      decoration: BoxDecoration(
        color: AppColors.bgPrimary.withValues(alpha: 0.62),
        borderRadius: BorderRadius.circular(AppRadius.xs),
        border: Border.all(color: accent.withValues(alpha: 0.45)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            threeD ? Icons.view_in_ar_outlined : Icons.photo_outlined,
            size: 12,
            color: accent,
          ),
          const SizedBox(width: AppSpacing.xs),
          Text(
            threeD ? '3D' : 'PHOTO',
            style: TextStyle(
              fontSize: AppTypography.sizeLabel,
              fontWeight: FontWeight.w700,
              letterSpacing: 1.2,
              color: accent,
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

  /// Cast under the name and price so they hold up over a blown-out highlight
  /// the scrim alone cannot tame.
  static const List<Shadow> _legibility = [
    Shadow(color: Color(0xCC000000), blurRadius: 12, offset: Offset(0, 2)),
  ];

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
                product.displayName,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: textTheme.titleMedium?.copyWith(
                  color: AppColors.textPrimary,
                  fontWeight: FontWeight.w700,
                  height: 1.18,
                  letterSpacing: -0.2,
                  shadows: _legibility,
                ),
              ),
              // No price is NOT rendered as a zero: the public card simply has
              // no price line, and so does this one (mirage-fe hides it below
              // 1). Showing "₹0" here would preview a claim the customer will
              // never see.
              if (price != null) ...[
                const SizedBox(height: AppSpacing.sm),
                // A pill rather than a line of text: price is the second thing
                // anyone looks for and the first thing they compare between
                // cards, so it gets an edge to be found by.
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: AppSpacing.sm,
                    vertical: AppSpacing.xs,
                  ),
                  decoration: BoxDecoration(
                    color: AppColors.bgPrimary.withValues(alpha: 0.55),
                    borderRadius: BorderRadius.circular(AppRadius.xs),
                    border: Border.all(
                      color: AppColors.royalGold.withValues(alpha: 0.5),
                    ),
                  ),
                  child: Text(
                    price,
                    style: textTheme.bodyMedium?.copyWith(
                      color: AppColors.goldGlow,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 0.2,
                    ),
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
  Widget build(BuildContext context) {
    final radius = BorderRadius.circular(AppRadius.lg);
    return Tooltip(
      message: active
          ? 'Show the card image again'
          : 'Loads the 3D model — these can be several megabytes, so it may '
              'take a moment on a slow connection or an older phone.',
      child: DecoratedBox(
        decoration: BoxDecoration(
          borderRadius: radius,
          // Inactive is the invitation and carries the brand gradient and its
          // glow; active is a dismiss and recedes to glass.
          gradient: active ? null : AppColors.primaryGradient,
          color: active ? AppColors.bgPrimary.withValues(alpha: 0.72) : null,
          border: active
              ? Border.all(color: const Color(0x2EFFFFFF))
              : null,
          boxShadow: active
              ? null
              : const [
                  BoxShadow(
                    color: Color(0x59E10600),
                    blurRadius: 18,
                    offset: Offset(0, 6),
                  ),
                ],
        ),
        child: Material(
          key: ValueKey(active ? 'preview_3d_hide' : 'preview_3d_show'),
          color: Colors.transparent,
          borderRadius: radius,
          child: InkWell(
            onTap: onPressed,
            borderRadius: radius,
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
      ),
    );
  }
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
        borderRadius: BorderRadius.circular(AppRadius.sm),
        border: Border.all(color: color.withValues(alpha: 0.35), width: 0.5),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // The icon sits in a tinted disc so the strip has one clear entry
          // point at a glance, the same shape the notices above the page use.
          Container(
            padding: const EdgeInsets.all(AppSpacing.xs),
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: color.withValues(alpha: 0.16),
            ),
            child: Icon(
              actionable.isEmpty
                  ? Icons.hourglass_empty
                  : Icons.warning_amber_rounded,
              size: 14,
              color: color,
            ),
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
                          ?.copyWith(color: color, height: 1.35),
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
