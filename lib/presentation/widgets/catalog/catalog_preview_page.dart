// lib/presentation/widgets/catalog/catalog_preview_page.dart
//
// The imitated public page: everything a preview screen renders below its app
// bar, given an already-composed [CatalogPreview].
//
// LIFTED OUT OF `catalog_preview_screen.dart` UNCHANGED so the rep surface can
// show a restaurant the same page the owner sees of their own. Two renderings of
// "what a customer will get" is the one duplication a preview cannot survive:
// the moment they disagree, at least one of them is lying, and nobody would know
// which. The screens keep what is genuinely theirs — where the data came from,
// what the app bar says, where a warning's Fix button navigates to.
//
// TWO JOBS, AND THIS WIDGET KEEPS THEM APART VISUALLY:
//   • inside the page frame, everything is what a CUSTOMER would see;
//   • outside it — the notice above, the warning strips under each card — is
//     what the AUTHOR needs and no customer ever gets.
// Mixing the two is how a preview starts lying: a sync pill or a featured star
// rendered inside the frame teaches the user that customers see it.
//
// It is an APPROXIMATION and says so. Mirage owns the real page's typography,
// its spacing and — see the notice — its product ORDER, which is by creation
// date and not by the order set here (feature 48). Claiming a pixel-exact
// preview would be the more useful lie.
import 'package:flutter/material.dart';

import '../../../app/theme/app_colors.dart';
import '../../../app/theme/app_spacing.dart';
import '../../../domain/catalog/catalog_preview.dart';
import '../../../domain/catalog/publish_gate.dart';
import '../../../domain/entities/business_profile.dart';
import '../../../domain/entities/catalog_product.dart';
import 'preview_product_card.dart';

/// How wide the imitated page is allowed to get.
///
/// The published catalog is a phone-first web page: a customer meets it by
/// scanning a sticker on a table. Letting the preview stretch to a 1600 px
/// desktop window would preview a layout that does not exist. A narrow window
/// simply gets the full width — the same rule as the product grid, decided from
/// CONSTRAINTS and never from `kIsWeb`.
const double kPreviewPageMaxWidth = 480;

/// What the owner's own preview says it is.
///
/// A constant rather than a default argument because the rep surface passes a
/// different sentence — same page, different reader — and having both spelled
/// out beside each other is how they stay honest about the one thing they must
/// agree on: nothing here is live until someone publishes.
const String kOwnerPreviewNotice =
    'This is an approximation of your public page, built from your draft — '
    'nothing here is live until you publish. The real page arranges products '
    'by when you added them, and shows in-stock and out-of-stock products the '
    'same way.';

/// Card media height for a viewport of [viewportHeight].
///
/// Mirrors mirage-fe's `calc((100dvh - 180px) / 2)` — about two cards per
/// screen, which is the rhythm the public page was designed around. Clamped at
/// both ends so a short desktop window and a tall tablet both stay sane.
double previewCardHeight(double viewportHeight) =>
    ((viewportHeight - 180) / 2).clamp(200.0, 420.0);

/// The scrollable preview body.
///
/// Stateful because two things belong to the RENDERING rather than to the data:
/// which card currently owns the single live 3D viewer, and the section anchors
/// the category strip scrolls to.
class CatalogPreviewPage extends StatefulWidget {
  const CatalogPreviewPage({
    super.key,
    required this.preview,
    required this.noticeBody,
    this.onFix,
  });

  final CatalogPreview preview;

  /// What this preview is, and what it is not. See [kOwnerPreviewNotice].
  final String noticeBody;

  /// Opens the product a warning is about. Null hides the Fix affordance — for
  /// a surface that can show the problem but not take the reader to it.
  final ValueChanged<CatalogProduct>? onFix;

  @override
  State<CatalogPreviewPage> createState() => CatalogPreviewPageState();
}

class CatalogPreviewPageState extends State<CatalogPreviewPage> {
  /// The one product currently rendering a live 3D viewer, if any.
  ///
  /// ONE, not a set: each viewer is a platform WebView, and the preview scrolls.
  /// See the note at the top of preview_product_card.dart.
  String? _activeThreeDId;

  /// Section anchors, so the category strip can scroll to its block.
  final Map<String, GlobalKey> _sectionKeys = {};

  /// Drops the live viewer back to a thumbnail.
  ///
  /// Public because a REFRESH must call it before the reload lands: a refresh
  /// replaces every product object, and a viewer keyed to the old one would be
  /// rebuilt mid-load.
  void releaseThreeD() {
    if (_activeThreeDId == null) return;
    setState(() => _activeThreeDId = null);
  }

  GlobalKey _keyFor(CatalogPreviewSection section) =>
      _sectionKeys.putIfAbsent(section.id ?? '', GlobalKey.new);

  void _scrollTo(CatalogPreviewSection section) {
    final context = _keyFor(section).currentContext;
    if (context == null) return;
    Scrollable.ensureVisible(
      context,
      duration: const Duration(milliseconds: 250),
      curve: Curves.easeOut,
      alignment: 0.05,
    );
  }

  @override
  Widget build(BuildContext context) {
    final preview = widget.preview;

    return LayoutBuilder(
      builder: (context, constraints) => ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.fromLTRB(
          AppSpacing.screenPadding,
          0,
          AppSpacing.screenPadding,
          AppSpacing.xxxl,
        ),
        children: [
          Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: kPreviewPageMaxWidth),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _PreviewNotice(body: widget.noticeBody),
                  if (preview.hasWarnings) ...[
                    const SizedBox(height: AppSpacing.md),
                    _PreflightBanner(preview: preview),
                  ],
                  const SizedBox(height: AppSpacing.xl),
                  _PageFrame(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        _PageHeader(preview: preview),
                        if (preview.isEmpty)
                          const _BrandedEmptyPage()
                        else ...[
                          if (preview.sections.length > 1)
                            _CategoryStrip(
                              sections: preview.sections,
                              onTap: _scrollTo,
                            ),
                          ..._sections(preview, constraints.maxHeight),
                        ],
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  List<Widget> _sections(CatalogPreview preview, double viewportHeight) {
    final cardHeight = previewCardHeight(viewportHeight);
    final onFix = widget.onFix;

    return [
      for (final section in preview.sections) ...[
        Padding(
          key: _keyFor(section),
          padding: const EdgeInsets.fromLTRB(
            AppSpacing.lg,
            AppSpacing.xl,
            AppSpacing.lg,
            AppSpacing.sm,
          ),
          child: Text(
            section.title,
            style: Theme.of(context).textTheme.titleMedium,
          ),
        ),
        for (final product in section.products)
          Padding(
            padding: const EdgeInsets.fromLTRB(
              AppSpacing.md,
              AppSpacing.sm,
              AppSpacing.md,
              AppSpacing.sm,
            ),
            child: PreviewProductCard(
              key: ValueKey('preview_card_${product.id}'),
              product: product,
              height: cardHeight,
              gates: preview.gatesByProduct[product.id] ?? const <PublishGate>[],
              isThreeDActive: _activeThreeDId == product.id,
              onLoadThreeD: () => setState(() => _activeThreeDId = product.id),
              onUnloadThreeD: () => setState(() => _activeThreeDId = null),
              onFix: onFix == null ? null : () => onFix(product),
            ),
          ),
      ],
      // WHY THE EMPTY ONES ARE NAMED RATHER THAN DRAWN. A section with nothing
      // in it gets no heading on the public page, so drawing one here would
      // preview a page that will not exist. Saying nothing at all is worse
      // though: somebody who has just made "Drinks" and cannot find it in the
      // preview reads that as the create having failed. One line answers both.
      if (preview.emptySectionTitles.isNotEmpty)
        Padding(
          key: const ValueKey('preview_empty_sections'),
          padding: const EdgeInsets.fromLTRB(
            AppSpacing.lg,
            AppSpacing.xl,
            AppSpacing.lg,
            AppSpacing.sm,
          ),
          child: Text(
            preview.emptySectionTitles.length == 1
                ? '"${preview.emptySectionTitles.single}" is empty, so it will '
                    'not appear on the page until it has something in it.'
                : '${preview.emptySectionTitles.length} sections are empty '
                    '(${preview.emptySectionTitles.join(', ')}), so they will '
                    'not appear on the page until they have something in them.',
            style: Theme.of(context)
                .textTheme
                .bodySmall
                ?.copyWith(color: AppColors.textMuted, height: 1.4),
          ),
        ),
    ];
  }
}

/// What this screen is and — just as importantly — what it is not.
class _PreviewNotice extends StatelessWidget {
  const _PreviewNotice({required this.body});

  final String body;

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    return Container(
      padding: const EdgeInsets.all(AppSpacing.md),
      decoration: BoxDecoration(
        color: AppColors.surface1,
        borderRadius: BorderRadius.circular(AppRadius.xs),
        border: Border.all(color: AppColors.royalGold.withValues(alpha: 0.2)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(Icons.visibility_outlined,
              size: 16, color: AppColors.royalGold),
          const SizedBox(width: AppSpacing.sm),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Preview of your draft', style: textTheme.bodyMedium),
                const SizedBox(height: AppSpacing.xs),
                Text(
                  body,
                  style: textTheme.bodySmall
                      ?.copyWith(color: AppColors.textSecondary, height: 1.4),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// The pre-flight summary. Counts PRODUCTS, not gates: one product can trip two
/// rules, and "5 problems" over three products reads as worse than it is.
class _PreflightBanner extends StatelessWidget {
  const _PreflightBanner({required this.preview});

  final CatalogPreview preview;

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    final withWarnings = preview.productsWithWarnings;
    final catalogGates = preview.catalogGates;

    final headline = withWarnings > 0
        ? '$withWarnings of ${preview.products.length} '
            '${preview.products.length == 1 ? 'product' : 'products'} '
            "won't publish yet"
        : 'This catalog is not ready to publish yet';

    return Container(
      padding: const EdgeInsets.all(AppSpacing.md),
      decoration: BoxDecoration(
        color: AppColors.warning.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(AppRadius.xs),
        border: Border.all(color: AppColors.warning.withValues(alpha: 0.35)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(Icons.warning_amber_rounded,
              size: 16, color: AppColors.warning),
          const SizedBox(width: AppSpacing.sm),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  headline,
                  style:
                      textTheme.bodyMedium?.copyWith(color: AppColors.warning),
                ),
                for (final gate in catalogGates)
                  Padding(
                    padding: const EdgeInsets.only(top: AppSpacing.xs),
                    child: Text(
                      gate.message,
                      style: textTheme.bodySmall
                          ?.copyWith(color: AppColors.warning),
                    ),
                  ),
                const SizedBox(height: AppSpacing.xs),
                Text(
                  'Each one is flagged on its card below. Publish runs these '
                  'checks again on the server, which can also see things this '
                  'screen cannot.',
                  style: textTheme.bodySmall
                      ?.copyWith(color: AppColors.textSecondary, height: 1.4),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// The border that separates "what a customer sees" from the authoring chrome
/// around it. Everything inside is the imitated page.
class _PageFrame extends StatelessWidget {
  const _PageFrame({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) => Container(
        clipBehavior: Clip.antiAlias,
        decoration: BoxDecoration(
          color: AppColors.bgPrimary,
          borderRadius: BorderRadius.circular(AppRadius.md),
          border: Border.all(color: AppColors.surface2),
        ),
        child: child,
      );
}

/// Cover, logo, catalog name, business name and the contact line customers get.
///
/// Which of those actually reach Mirage is the SERVER's call, carried on
/// `publicFields`; this header renders only fields that are on that list, so a
/// worker that learns to carry another one lights it up here with no client
/// change — and one that never carried a field cannot be previewed into
/// existence.
class _PageHeader extends StatelessWidget {
  const _PageHeader({required this.preview});

  final CatalogPreview preview;

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    final profile = preview.profile;
    final coverUrl = profile?.coverImageUrl;
    final logoUrl = _publicOrNull(profile, 'logoUrl', profile?.logoUrl);
    final phone = _publicOrNull(
        profile, 'contact.phone', preview.catalog.contact?.phone);
    final address = _publicOrNull(
        profile, 'contact.address', preview.catalog.contact?.address);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (coverUrl != null && coverUrl.isNotEmpty)
          SizedBox(
            height: 120,
            child: Image.network(
              coverUrl,
              fit: BoxFit.cover,
              errorBuilder: (_, __, ___) =>
                  const ColoredBox(color: AppColors.surface2),
            ),
          ),
        Padding(
          padding: const EdgeInsets.all(AppSpacing.lg),
          child: Row(
            children: [
              if (logoUrl != null && logoUrl.isNotEmpty) ...[
                ClipRRect(
                  borderRadius: BorderRadius.circular(AppRadius.xs),
                  child: Image.network(
                    logoUrl,
                    width: 48,
                    height: 48,
                    fit: BoxFit.cover,
                    errorBuilder: (_, __, ___) => const SizedBox(
                      width: 48,
                      height: 48,
                      child: ColoredBox(color: AppColors.surface2),
                    ),
                  ),
                ),
                const SizedBox(width: AppSpacing.md),
              ],
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      preview.catalog.displayName,
                      style: textTheme.titleLarge,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                    if (preview.catalog.businessName case final business?
                        when business.isNotEmpty) ...[
                      const SizedBox(height: AppSpacing.xs),
                      Text(
                        business,
                        style: textTheme.bodySmall
                            ?.copyWith(color: AppColors.textSecondary),
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),
        ),
        if (phone != null || address != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(
              AppSpacing.lg,
              0,
              AppSpacing.lg,
              AppSpacing.lg,
            ),
            child: Wrap(
              spacing: AppSpacing.md,
              runSpacing: AppSpacing.xs,
              children: [
                if (phone != null)
                  _ContactChip(icon: Icons.call_outlined, label: phone),
                if (address != null)
                  _ContactChip(icon: Icons.place_outlined, label: address),
              ],
            ),
          ),
      ],
    );
  }

  /// [value] when the server says that field reaches customers, else null.
  ///
  /// A profile the screen could not load marks nothing public, so the header
  /// degrades to the catalog's own name — understating reach rather than
  /// previewing a contact line that may not be on the real page.
  static String? _publicOrNull(
    BusinessProfile? profile,
    String field,
    String? value,
  ) {
    if (profile == null || value == null || value.isEmpty) return null;
    return profile.isPublic(field) ? value : null;
  }
}

class _ContactChip extends StatelessWidget {
  const _ContactChip({required this.icon, required this.label});

  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) => Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 14, color: AppColors.textMuted),
          const SizedBox(width: AppSpacing.xs),
          Text(
            label,
            style: Theme.of(context)
                .textTheme
                .bodySmall
                ?.copyWith(color: AppColors.textSecondary),
          ),
        ],
      );
}

/// The public page's category tabs. Here they only scroll to a block — the real
/// page filters, and a preview that filtered would hide the very products the
/// user came to check.
class _CategoryStrip extends StatelessWidget {
  const _CategoryStrip({required this.sections, required this.onTap});

  final List<CatalogPreviewSection> sections;
  final ValueChanged<CatalogPreviewSection> onTap;

  @override
  Widget build(BuildContext context) => SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg),
        child: Row(
          children: [
            for (final section in sections)
              Padding(
                padding: const EdgeInsets.only(right: AppSpacing.sm),
                child: ActionChip(
                  label: Text(section.title),
                  backgroundColor: AppColors.surface1,
                  side: BorderSide(
                    color: AppColors.royalGold.withValues(alpha: 0.2),
                  ),
                  onPressed: () => onTap(section),
                ),
              ),
          ],
        ),
      );
}

/// A catalog with nothing in it, previewed honestly: the branded page a
/// customer would land on. Not an authoring empty state — this IS the page.
class _BrandedEmptyPage extends StatelessWidget {
  const _BrandedEmptyPage();

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.lg,
          vertical: AppSpacing.huge,
        ),
        child: Column(
          children: [
            const Icon(Icons.restaurant_menu_outlined,
                size: 36, color: AppColors.textMuted),
            const SizedBox(height: AppSpacing.md),
            Text(
              'Nothing on the menu yet',
              style: Theme.of(context).textTheme.titleMedium,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: AppSpacing.xs),
            Text(
              'This is exactly what a customer would see if you published now.',
              textAlign: TextAlign.center,
              style: Theme.of(context)
                  .textTheme
                  .bodySmall
                  ?.copyWith(color: AppColors.textSecondary),
            ),
          ],
        ),
      );
}
