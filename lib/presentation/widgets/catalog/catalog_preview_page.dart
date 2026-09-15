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
//   • outside it — the summary strip and notice above, the warning strips under
//     each card — is what the AUTHOR needs and no customer ever gets.
// Mixing the two is how a preview starts lying: a sync pill or a featured star
// rendered inside the frame teaches the user that customers see it. The frame
// now says so out loud (see [_FrameLabel]) rather than leaving the boundary to
// be inferred from a hairline.
//
// It is an APPROXIMATION and says so. Mirage owns the real page's typography,
// its spacing and — see the notice — its product ORDER, which is by creation
// date and not by the order set here (feature 48). Claiming a pixel-exact
// preview would be the more useful lie.
//
// ── WHY THE CHROME IS SHAPED THE WAY IT IS ──────────────────────────────────
// The author arrives with two questions, in this order: "is my menu right?" and
// "will it publish?". So the chrome answers the second one in a glance — a row
// of counts, then the notice, then the pre-flight banner if there is anything
// to say — and then gets out of the way, because the rest of the screen is the
// answer to the first and it is the part worth scrolling.
//
// ── SORTING AND FILTERING, AND THE ONE RULE THEY BEND ────────────────────────
// A menu of forty dishes is not reviewable in page order alone: "what did I just
// add", "which ones still have no 3D", "which ones will block Publish" are all
// questions about the SET, and answering them by scrolling is how a preview
// stops being opened. So the chrome carries a sort and a filter.
//
// They are AUTHOR CONTROLS AND THEY SIT OUTSIDE THE FRAME, like everything else
// that is not the customer's. But unlike the rest of the chrome they change what
// is drawn INSIDE it, which is the one thing this widget otherwise never does —
// so the frame stops claiming to be the customer's page the moment either is
// touched ([_FrameLabel] renames itself, and [_ViewNotice] says what changed and
// offers the way back). Menu order with no filter is the default and is the only
// state that claims to be what a customer gets.
//
// The alternative — sorting the page and saying nothing — is the exact failure
// this file's header warns about: it would teach an author that customers see
// their dishes newest-first, which Mirage does not do (see the notice copy).
import 'package:flutter/material.dart';

import '../../../app/theme/app_colors.dart';
import '../../../app/theme/app_spacing.dart';
import '../../../app/theme/app_typography.dart';
import '../../../domain/catalog/catalog_preview.dart';
import '../../../domain/catalog/publish_gate.dart';
import '../../../domain/entities/business_profile.dart';
import '../../../domain/entities/catalog_product.dart';
import '../../../domain/entities/product_food_type.dart';
import 'preview_product_card.dart';
import 'product_view_controls.dart';

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

/// What the preview leaves out.
///
/// Every one of these answers a question an author actually asks before
/// publishing, which is the bar for being here: "what is broken"
/// ([needsAttention]), "what still has no model" ([photo]), "what did the 3D
/// work produce" ([threeD]), and the two the food-type labels exist for.
enum PreviewFilter {
  all('All', null),
  needsAttention('Needs attention', Icons.warning_amber_rounded),
  threeD('3D', Icons.view_in_ar_outlined),
  photo('Photo only', Icons.photo_outlined),
  veg('Veg', null),
  nonVeg('Non-veg', null);

  const PreviewFilter(this.label, this.icon);

  final String label;
  final IconData? icon;

  bool get isDefault => this == PreviewFilter.all;
}

/// The scrollable preview body.
///
/// Stateful because three things belong to the RENDERING rather than to the
/// data: which card currently owns the single live 3D viewer, the category the
/// strip has narrowed the page to, and the sort/filter the author is looking
/// through.
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

  /// The category the strip has narrowed the page to, by [_idOf]. Null is the
  /// first chip — All — which is the whole page.
  ///
  /// NOT a lens in the [_isLensed] sense: the public page's tabs narrow it the
  /// same way, so a single category on screen is still what a customer can see.
  String? _selectedSectionId;

  /// The author's lens on the draft. Both default to "show me the page", which
  /// is the only state that claims to be what a customer gets.
  ProductSort _sort = ProductSort.menuOrder;
  PreviewFilter _filter = PreviewFilter.all;

  /// Whether anything is being shown other than the page itself.
  bool get _isLensed => !_sort.isDefault || !_filter.isDefault;

  void _setSort(ProductSort sort) {
    if (sort == _sort) return;
    setState(() => _sort = sort);
  }

  void _setFilter(PreviewFilter filter) {
    if (filter == _filter) return;
    setState(() => _filter = filter);
  }

  void _selectSection(String? id) {
    if (id == _selectedSectionId) return;
    setState(() => _selectedSectionId = id);
  }

  /// Back to the whole page: no lens, and every category.
  void _resetView() {
    if (!_isLensed && _selectedSectionId == null) return;
    setState(() {
      _sort = ProductSort.menuOrder;
      _filter = PreviewFilter.all;
      _selectedSectionId = null;
    });
  }

  /// Whether [product] survives the current filter.
  bool _matches(CatalogPreview preview, CatalogProduct product) =>
      switch (_filter) {
        PreviewFilter.all => true,
        PreviewFilter.needsAttention =>
          (preview.gatesByProduct[product.id] ?? const <PublishGate>[])
              .isNotEmpty,
        // The card's own question, asked the card's way: "can this be turned
        // around", not "was it typed in as a 3D product".
        PreviewFilter.threeD => product.canViewInThreeD,
        PreviewFilter.photo => !product.canViewInThreeD,
        PreviewFilter.veg => product.foodType == ProductFoodType.veg,
        PreviewFilter.nonVeg => product.foodType == ProductFoodType.nonVeg,
      };

  /// [preview]'s sections through the current lens, with emptied ones dropped.
  ///
  /// Sections are kept rather than flattened even when sorting: the page's
  /// shape is half of what an author is checking, and a flat list of forty
  /// dishes answers "what did I add" while hiding "is it filed correctly".
  List<CatalogPreviewSection> _lensed(CatalogPreview preview) {
    if (!_isLensed) return preview.sections;

    final out = <CatalogPreviewSection>[];
    for (final section in preview.sections) {
      final kept = [
        for (final product in section.products)
          if (_matches(preview, product)) product,
      ];
      if (kept.isEmpty) continue;
      out.add(CatalogPreviewSection(
        id: section.id,
        title: section.title,
        products: sortProducts(kept, _sort),
      ));
    }
    return out;
  }

  /// Drops the live viewer back to a thumbnail.
  ///
  /// Public because a REFRESH must call it before the reload lands: a refresh
  /// replaces every product object, and a viewer keyed to the old one would be
  /// rebuilt mid-load.
  void releaseThreeD() {
    if (_activeThreeDId == null) return;
    setState(() => _activeThreeDId = null);
  }

  @override
  void didUpdateWidget(covariant CatalogPreviewPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    // A refresh composes a new preview with new sections; a selection left
    // over from the old one may name a category that no longer exists (deleted
    // on another device, or emptied), and the page would show nothing for it.
    if (!identical(oldWidget.preview, widget.preview)) {
      final id = _selectedSectionId;
      if (id != null && !widget.preview.sections.any((s) => _idOf(s) == id)) {
        _selectedSectionId = null;
      }
    }
  }

  /// The strip identity of a section. The Uncategorized bucket has a null id
  /// by design, so '' stands in for it — it is a real section to the reader.
  static String _idOf(CatalogPreviewSection section) => section.id ?? '';

  @override
  Widget build(BuildContext context) {
    final preview = widget.preview;
    // Computed ONCE per build and handed to everything below it, so the strip,
    // the sections and the hidden-count line cannot disagree about what is on
    // screen.
    final sections = _lensed(preview);
    final shown = [
      for (final section in sections) ...section.products,
    ].length;
    // About the FILTER only — a category tab hides nothing a customer cannot
    // reach with the same tab.
    final hidden = preview.products.length - shown;

    // A selected category the filter has just emptied falls back to All rather
    // than to a blank page: the strip has no chip for it to be highlighted on.
    final selectedId = _selectedSectionId;
    final narrowed = selectedId != null &&
        sections.length > 1 &&
        sections.any((s) => _idOf(s) == selectedId);
    final visible = narrowed
        ? [
            for (final s in sections)
              if (_idOf(s) == selectedId) s
          ]
        : sections;

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
                  if (!preview.isEmpty) ...[
                    const SizedBox(height: AppSpacing.sm),
                    _PreviewSummaryBar(preview: preview),
                  ],
                  const SizedBox(height: AppSpacing.md),
                  _PreviewNotice(body: widget.noticeBody),
                  if (preview.hasWarnings) ...[
                    const SizedBox(height: AppSpacing.md),
                    _PreflightBanner(preview: preview),
                  ],
                  // Nothing to sort or filter in an empty draft, and a row of
                  // dead controls over a branded empty page is noise.
                  if (!preview.isEmpty) ...[
                    const SizedBox(height: AppSpacing.md),
                    _ViewControls(
                      sort: _sort,
                      filter: _filter,
                      onSort: _setSort,
                      onFilter: _setFilter,
                    ),
                  ],
                  const SizedBox(height: AppSpacing.xxl),
                  _FrameLabel(lensed: _isLensed),
                  if (_isLensed) ...[
                    const SizedBox(height: AppSpacing.sm),
                    _ViewNotice(
                      sort: _sort,
                      filter: _filter,
                      hidden: hidden,
                      onReset: _resetView,
                    ),
                  ],
                  const SizedBox(height: AppSpacing.md),
                  _PageFrame(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        _PageHeader(preview: preview),
                        if (preview.isEmpty)
                          const _BrandedEmptyPage()
                        else if (sections.isEmpty)
                          // NOT the branded empty page: that one says "this is
                          // what a customer would see", which would be a lie
                          // about a draft the author has merely filtered.
                          _NoMatchesView(
                            filter: _filter,
                            onReset: _resetView,
                          )
                        else ...[
                          if (sections.length > 1)
                            _CategoryStrip(
                              sections: sections,
                              selectedId: narrowed ? selectedId : null,
                              onSelect: _selectSection,
                            ),
                          ..._sections(
                            preview,
                            visible,
                            constraints.maxHeight,
                            narrowed: narrowed,
                          ),
                          const SizedBox(height: AppSpacing.xl),
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

  List<Widget> _sections(
    CatalogPreview preview,
    List<CatalogPreviewSection> sections,
    double viewportHeight, {
    required bool narrowed,
  }) {
    final cardHeight = previewCardHeight(viewportHeight);
    final onFix = widget.onFix;

    return [
      for (final section in sections) ...[
        Padding(
          key: ValueKey('preview_section_${_idOf(section)}'),
          padding: const EdgeInsets.fromLTRB(
            AppSpacing.lg,
            AppSpacing.xl,
            AppSpacing.lg,
            AppSpacing.md,
          ),
          child: _SectionHeading(section: section),
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
              gates:
                  preview.gatesByProduct[product.id] ?? const <PublishGate>[],
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
      //
      // Suppressed under a filter or a category tab: the sentence is about the
      // DRAFT, and beside a narrowed page it reads as a claim about what the
      // narrowing did.
      if (!_isLensed && !narrowed && preview.emptySectionTitles.isNotEmpty)
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

/// The shape of the draft in four numbers, before any of it is read.
///
/// AUTHOR-ONLY, hence outside the frame: "5 in 3D" is a fact about the work,
/// not about the menu, and a customer counting 3D dishes is not a thing that
/// happens. It leads because it answers "did everything I added actually make
/// it in?" without scrolling — the question that otherwise sends someone
/// through the whole page to count cards.
class _PreviewSummaryBar extends StatelessWidget {
  const _PreviewSummaryBar({required this.preview});

  final CatalogPreview preview;

  @override
  Widget build(BuildContext context) {
    final total = preview.products.length;
    final sections = preview.sections.length;
    final threeD = [
      for (final product in preview.products)
        if (product.canViewInThreeD) product,
    ].length;
    final warned = preview.productsWithWarnings;

    return Wrap(
      spacing: AppSpacing.sm,
      runSpacing: AppSpacing.sm,
      children: [
        _StatPill(
          icon: Icons.restaurant_menu,
          label: total == 1 ? '1 product' : '$total products',
        ),
        if (sections > 0)
          _StatPill(
            icon: Icons.category_outlined,
            label: sections == 1 ? '1 section' : '$sections sections',
          ),
        if (threeD > 0)
          _StatPill(
            icon: Icons.view_in_ar_outlined,
            label: '$threeD in 3D',
            accent: AppColors.royalGold,
          ),
        // The count that decides whether Publish will do anything, in the one
        // colour on this screen that means "not yet".
        if (warned > 0)
          _StatPill(
            icon: Icons.warning_amber_rounded,
            label: warned == 1 ? '1 needs attention' : '$warned need attention',
            accent: AppColors.warning,
          ),
      ],
    );
  }
}

class _StatPill extends StatelessWidget {
  const _StatPill({required this.icon, required this.label, this.accent});

  final IconData icon;
  final String label;

  /// Null keeps the pill quiet — the neutral counts are context, not findings.
  final Color? accent;

  @override
  Widget build(BuildContext context) {
    final color = accent ?? AppColors.textSecondary;
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.md,
        vertical: AppSpacing.xs,
      ),
      decoration: BoxDecoration(
        color: AppColors.surface1,
        borderRadius: BorderRadius.circular(AppRadius.lg),
        border: Border.all(color: color.withValues(alpha: 0.28)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 13, color: color),
          const SizedBox(width: AppSpacing.xs),
          Text(
            label,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: color,
                  fontWeight: FontWeight.w600,
                ),
          ),
        ],
      ),
    );
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
        borderRadius: BorderRadius.circular(AppRadius.sm),
        border: Border.all(color: AppColors.royalGold.withValues(alpha: 0.22)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _IconDisc(
            icon: Icons.visibility_outlined,
            color: AppColors.royalGold,
          ),
          const SizedBox(width: AppSpacing.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Preview of your draft',
                  style: textTheme.bodyMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: AppSpacing.xs),
                Text(
                  body,
                  style: textTheme.bodySmall
                      ?.copyWith(color: AppColors.textSecondary, height: 1.45),
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
        borderRadius: BorderRadius.circular(AppRadius.sm),
        border: Border.all(color: AppColors.warning.withValues(alpha: 0.35)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _IconDisc(
            icon: Icons.warning_amber_rounded,
            color: AppColors.warning,
          ),
          const SizedBox(width: AppSpacing.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  headline,
                  style: textTheme.bodyMedium?.copyWith(
                    color: AppColors.warning,
                    fontWeight: FontWeight.w700,
                  ),
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
                      ?.copyWith(color: AppColors.textSecondary, height: 1.45),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// The tinted disc every notice leads with, so the chrome above the page reads
/// as one family rather than as three unrelated boxes.
class _IconDisc extends StatelessWidget {
  const _IconDisc({required this.icon, required this.color});

  final IconData icon;
  final Color color;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.all(AppSpacing.sm),
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: color.withValues(alpha: 0.14),
        ),
        child: Icon(icon, size: 16, color: color),
      );
}

/// Names the boundary the frame below draws.
///
/// The rule this widget exists to make visible is the one the whole file is
/// built around: inside is the customer's page, outside is the author's. A
/// hairline alone leaves that to be guessed at, and the guess that goes wrong —
/// "customers must see these warnings too" — is the expensive one.
class _FrameLabel extends StatelessWidget {
  const _FrameLabel({required this.lensed});

  /// Whether a sort or filter is on. The label is the ONE place the page stops
  /// claiming to be the customer's, so it has to change the instant either is.
  final bool lensed;

  @override
  Widget build(BuildContext context) => Row(
        children: [
          const Expanded(child: _Hairline()),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md),
            child: Text(
              lensed ? 'YOUR VIEW OF THE DRAFT' : 'WHAT A CUSTOMER SEES',
              key: const ValueKey('preview_frame_label'),
              style: TextStyle(
                fontSize: AppTypography.sizeLabel,
                fontWeight: FontWeight.w700,
                letterSpacing: 1.6,
                color: lensed ? AppColors.royalGold : AppColors.textMuted,
              ),
            ),
          ),
          const Expanded(child: _Hairline()),
        ],
      );
}

/// The sort and filter controls.
///
/// The same two rows the catalog page has under its search box — see
/// [ControlRow] for why rows and not a menu.
class _ViewControls extends StatelessWidget {
  const _ViewControls({
    required this.sort,
    required this.filter,
    required this.onSort,
    required this.onFilter,
  });

  final ProductSort sort;
  final PreviewFilter filter;
  final ValueChanged<ProductSort> onSort;
  final ValueChanged<PreviewFilter> onFilter;

  @override
  Widget build(BuildContext context) {
    return ViewControlsPanel(
      children: [
        ControlRow(
          label: 'Sort',
          children: [
            for (final option in ProductSort.values)
              _ViewChip(
                key: ValueKey('preview_sort_${option.name}'),
                label: option.label,
                selected: option == sort,
                onTap: () => onSort(option),
              ),
          ],
        ),
        const SizedBox(height: AppSpacing.sm),
        ControlRow(
          label: 'Show',
          children: [
            for (final option in PreviewFilter.values)
              _ViewChip(
                key: ValueKey('preview_filter_${option.name}'),
                label: option.label,
                icon: option.icon,
                selected: option == filter,
                onTap: () => onFilter(option),
              ),
          ],
        ),
      ],
    );
  }
}

class _ViewChip extends StatelessWidget {
  const _ViewChip({
    super.key,
    required this.label,
    required this.selected,
    required this.onTap,
    this.icon,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    final radius = BorderRadius.circular(AppRadius.lg);
    final color = selected ? AppColors.goldGlow : AppColors.textSecondary;
    return Material(
      color: selected
          ? AppColors.royalGold.withValues(alpha: 0.16)
          : AppColors.bgPrimary,
      borderRadius: radius,
      child: InkWell(
        onTap: onTap,
        borderRadius: radius,
        child: Container(
          padding: const EdgeInsets.symmetric(
            horizontal: AppSpacing.md,
            vertical: AppSpacing.sm,
          ),
          decoration: BoxDecoration(
            borderRadius: radius,
            border: Border.all(
              color: selected
                  ? AppColors.royalGold.withValues(alpha: 0.7)
                  : AppColors.surface2,
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (icon != null) ...[
                Icon(icon, size: 13, color: color),
                const SizedBox(width: AppSpacing.xs),
              ],
              Text(
                label,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: color,
                      fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                    ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Says what the lens is doing, and offers the way back to the real page.
///
/// The RESET is the important half. A filter left on is the failure mode here:
/// an author who forgets they narrowed to "Needs attention" is looking at a
/// page that is missing most of their menu, and "my dishes disappeared" is how
/// that gets reported.
class _ViewNotice extends StatelessWidget {
  const _ViewNotice({
    required this.sort,
    required this.filter,
    required this.hidden,
    required this.onReset,
  });

  final ProductSort sort;
  final PreviewFilter filter;
  final int hidden;
  final VoidCallback onReset;

  @override
  Widget build(BuildContext context) {
    final parts = <String>[
      if (!sort.isDefault) 'sorted by ${sort.label.toLowerCase()}',
      if (!filter.isDefault)
        hidden == 1 ? '1 product hidden' : '$hidden products hidden',
    ];

    return Container(
      padding: const EdgeInsets.all(AppSpacing.md),
      decoration: BoxDecoration(
        color: AppColors.royalGold.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(AppRadius.sm),
        border: Border.all(color: AppColors.royalGold.withValues(alpha: 0.28)),
      ),
      child: Row(
        children: [
          const Icon(Icons.tune, size: 14, color: AppColors.royalGold),
          const SizedBox(width: AppSpacing.sm),
          Expanded(
            child: Text(
              // Names the ONE thing that is now untrue of the page below.
              'Your view — ${parts.join(', ')}. Customers get the menu order.',
              key: const ValueKey('preview_view_notice'),
              style: Theme.of(context)
                  .textTheme
                  .bodySmall
                  ?.copyWith(color: AppColors.textSecondary, height: 1.35),
            ),
          ),
          const SizedBox(width: AppSpacing.sm),
          TextButton(
            key: const ValueKey('preview_view_reset'),
            onPressed: onReset,
            child: const Text('Reset'),
          ),
        ],
      ),
    );
  }
}

/// A filter that matched nothing.
///
/// Deliberately NOT [_BrandedEmptyPage]: that one tells the author this is
/// exactly what a customer would see, which would be false of a draft they have
/// merely narrowed.
class _NoMatchesView extends StatelessWidget {
  const _NoMatchesView({required this.filter, required this.onReset});

  final PreviewFilter filter;
  final VoidCallback onReset;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.lg,
          vertical: AppSpacing.xxxl,
        ),
        child: Column(
          key: const ValueKey('preview_no_matches'),
          children: [
            const Icon(Icons.filter_alt_off_outlined,
                size: 32, color: AppColors.textMuted),
            const SizedBox(height: AppSpacing.md),
            Text(
              'Nothing matches "${filter.label}".',
              textAlign: TextAlign.center,
              style: Theme.of(context)
                  .textTheme
                  .bodyMedium
                  ?.copyWith(fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: AppSpacing.xs),
            Text(
              'Your menu is still there — this is a filter, not the page.',
              textAlign: TextAlign.center,
              style: Theme.of(context)
                  .textTheme
                  .bodySmall
                  ?.copyWith(color: AppColors.textSecondary, height: 1.45),
            ),
            const SizedBox(height: AppSpacing.lg),
            TextButton(
              key: const ValueKey('preview_no_matches_reset'),
              onPressed: onReset,
              child: const Text('Show everything'),
            ),
          ],
        ),
      );
}

class _Hairline extends StatelessWidget {
  const _Hairline();

  @override
  Widget build(BuildContext context) =>
      const SizedBox(height: 1, child: ColoredBox(color: AppColors.surface2));
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
          borderRadius: BorderRadius.circular(AppRadius.lg),
          border: Border.all(color: AppColors.surface2),
          // The page is a thing sitting ON this screen, not a region of it.
          boxShadow: const [
            BoxShadow(
              color: Color(0x8C000000),
              blurRadius: 32,
              offset: Offset(0, 14),
            ),
          ],
        ),
        child: child,
      );
}

/// Cover, logo, catalog name, business name and the contact line customers get.
///
/// Built as a HERO — the branding over the cover rather than beside it — because
/// that is the first screen of a page a customer meets by scanning a sticker,
/// and a restaurant's own photo is the strongest thing on it. A catalog with no
/// cover gets a neutral branded backdrop ([_HeaderBackdrop]) rather than a
/// stand-in photo: an invented image is exactly the kind of thing a preview
/// must not put on the page.
///
/// Which fields actually reach Mirage is the SERVER's call, carried on
/// `publicFields`; this header renders only fields that are on that list, so a
/// worker that learns to carry another one lights it up here with no client
/// change — and one that never carried a field cannot be previewed into
/// existence.
class _PageHeader extends StatelessWidget {
  const _PageHeader({required this.preview});

  final CatalogPreview preview;

  /// Tall enough for a photo to be a photo; short enough that the first card is
  /// still on screen under it on a small phone.
  static const double _heroWithCover = 180;
  static const double _heroWithoutCover = 136;

  /// Keeps the name and the business line readable over whatever the
  /// restaurant uploaded.
  static const List<Shadow> _legibility = [
    Shadow(color: Color(0xCC000000), blurRadius: 14, offset: Offset(0, 2)),
  ];

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    final profile = preview.profile;
    final coverUrl = profile?.coverImageUrl;
    final logoUrl = _publicOrNull(profile, 'logoUrl', profile?.logoUrl);
    final phone =
        _publicOrNull(profile, 'contact.phone', preview.catalog.contact?.phone);
    final address = _publicOrNull(
        profile, 'contact.address', preview.catalog.contact?.address);
    final hasCover = coverUrl != null && coverUrl.isNotEmpty;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SizedBox(
          height: hasCover ? _heroWithCover : _heroWithoutCover,
          child: Stack(
            fit: StackFit.expand,
            children: [
              // Tested inline rather than through `hasCover` so the null
              // check promotes the url for Image.network.
              if (coverUrl != null && coverUrl.isNotEmpty)
                Image.network(
                  coverUrl,
                  fit: BoxFit.cover,
                  errorBuilder: (_, __, ___) => const _HeaderBackdrop(),
                )
              else
                const _HeaderBackdrop(),
              // Same scrim job as a card: the branding sits on the photo, so
              // the photo has to give way underneath it.
              const DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.bottomCenter,
                    end: Alignment.topCenter,
                    colors: [
                      Color(0xF20B0B0E),
                      Color(0x8C0B0B0E),
                      Color(0x1A0B0B0E),
                    ],
                    stops: [0.0, 0.55, 1.0],
                  ),
                ),
              ),
              Positioned(
                left: AppSpacing.lg,
                right: AppSpacing.lg,
                bottom: AppSpacing.lg,
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    if (logoUrl != null && logoUrl.isNotEmpty) ...[
                      _Logo(url: logoUrl),
                      const SizedBox(width: AppSpacing.md),
                    ],
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            preview.catalog.displayName,
                            style: textTheme.titleLarge?.copyWith(
                              fontWeight: FontWeight.w700,
                              letterSpacing: -0.3,
                              height: 1.15,
                              shadows: _legibility,
                            ),
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                          if (preview.catalog.businessName case final business?
                              when business.isNotEmpty) ...[
                            const SizedBox(height: AppSpacing.xs),
                            Text(
                              business,
                              style: textTheme.bodySmall?.copyWith(
                                color: AppColors.textSecondary,
                                shadows: _legibility,
                              ),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ],
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
        // The one gold rule this screen is allowed — it marks the seam between
        // the branding and the menu, which is the only seam that matters here.
        const SizedBox(
          height: 2,
          child: DecoratedBox(
            decoration: BoxDecoration(gradient: AppColors.goldGradient),
          ),
        ),
        if (phone != null || address != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(
              AppSpacing.lg,
              AppSpacing.md,
              AppSpacing.lg,
              0,
            ),
            child: Wrap(
              spacing: AppSpacing.sm,
              runSpacing: AppSpacing.sm,
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

/// The backdrop behind the branding when there is no cover photo — and behind a
/// cover that fails to load. Neutral on purpose: page chrome, never something
/// that could be mistaken for an image the restaurant uploaded.
class _HeaderBackdrop extends StatelessWidget {
  const _HeaderBackdrop();

  @override
  Widget build(BuildContext context) => const DecoratedBox(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [AppColors.surface1, AppColors.bgPrimary],
          ),
        ),
        child: DecoratedBox(
          decoration: BoxDecoration(
            gradient: RadialGradient(
              center: Alignment(0.85, -0.9),
              radius: 1.1,
              colors: [Color(0x26E10600), Color(0x00E10600)],
            ),
          ),
        ),
      );
}

class _Logo extends StatelessWidget {
  const _Logo({required this.url});

  final String url;

  static const double _size = 56;

  @override
  Widget build(BuildContext context) => Container(
        width: _size,
        height: _size,
        clipBehavior: Clip.antiAlias,
        decoration: BoxDecoration(
          color: AppColors.surface2,
          borderRadius: BorderRadius.circular(AppRadius.sm),
          border: Border.all(color: const Color(0x2EFFFFFF)),
          boxShadow: const [
            BoxShadow(
              color: Color(0x99000000),
              blurRadius: 16,
              offset: Offset(0, 6),
            ),
          ],
        ),
        child: Image.network(
          url,
          fit: BoxFit.cover,
          errorBuilder: (_, __, ___) => const ColoredBox(
            color: AppColors.surface2,
            child: Icon(Icons.storefront_outlined,
                size: 22, color: AppColors.textMuted),
          ),
        ),
      );
}

class _ContactChip extends StatelessWidget {
  const _ContactChip({required this.icon, required this.label});

  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.md,
          vertical: AppSpacing.xs,
        ),
        decoration: BoxDecoration(
          color: AppColors.surface1,
          borderRadius: BorderRadius.circular(AppRadius.lg),
          border: Border.all(color: AppColors.surface2),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 13, color: AppColors.textMuted),
            const SizedBox(width: AppSpacing.xs),
            Flexible(
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context)
                    .textTheme
                    .bodySmall
                    ?.copyWith(color: AppColors.textSecondary),
              ),
            ),
          ],
        ),
      );
}

/// The public page's category tabs, doing what the real ones do: "All" first,
/// which is the whole page, then one chip per category that NARROWS the page
/// to that block. A tab is not a lens — a customer has the same tab.
class _CategoryStrip extends StatelessWidget {
  const _CategoryStrip({
    required this.sections,
    required this.selectedId,
    required this.onSelect,
  });

  final List<CatalogPreviewSection> sections;

  /// `section.id ?? ''` of the block being shown; null for All.
  final String? selectedId;

  /// Called with the same identity, or null for All.
  final ValueChanged<String?> onSelect;

  @override
  Widget build(BuildContext context) {
    final total = [for (final s in sections) ...s.products].length;
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.lg,
        AppSpacing.md,
        AppSpacing.lg,
        AppSpacing.xs,
      ),
      child: Row(
        children: [
          Padding(
            padding: const EdgeInsets.only(right: AppSpacing.sm),
            child: _CategoryChip(
              key: const ValueKey('preview_category_all'),
              label: 'All',
              count: total,
              active: selectedId == null,
              onTap: () => onSelect(null),
            ),
          ),
          for (final section in sections)
            Padding(
              padding: const EdgeInsets.only(right: AppSpacing.sm),
              child: _CategoryChip(
                key: ValueKey('preview_category_${section.id ?? ''}'),
                label: section.title,
                count: section.products.length,
                active: (section.id ?? '') == selectedId,
                onTap: () => onSelect(section.id ?? ''),
              ),
            ),
        ],
      ),
    );
  }
}

class _CategoryChip extends StatelessWidget {
  const _CategoryChip({
    super.key,
    required this.label,
    required this.count,
    required this.active,
    required this.onTap,
  });

  final String label;
  final int count;
  final bool active;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    final radius = BorderRadius.circular(AppRadius.lg);
    return Material(
      color: active
          ? AppColors.royalGold.withValues(alpha: 0.16)
          : AppColors.surface1,
      borderRadius: radius,
      child: InkWell(
        onTap: onTap,
        borderRadius: radius,
        child: Container(
          padding: const EdgeInsets.symmetric(
            horizontal: AppSpacing.md,
            vertical: AppSpacing.sm,
          ),
          decoration: BoxDecoration(
            borderRadius: radius,
            border: Border.all(
              color: active
                  ? AppColors.royalGold.withValues(alpha: 0.7)
                  : AppColors.surface2,
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              // Its own Text, not interpolated with the count: the category's
              // name is a value that other code (and tests) look for exactly.
              Text(
                label,
                style: textTheme.bodySmall?.copyWith(
                  color: active ? AppColors.goldGlow : AppColors.textSecondary,
                  fontWeight: active ? FontWeight.w700 : FontWeight.w500,
                ),
              ),
              const SizedBox(width: AppSpacing.xs),
              Text(
                '$count',
                style: textTheme.bodySmall?.copyWith(
                  color: active
                      ? AppColors.royalGold.withValues(alpha: 0.8)
                      : AppColors.textMuted,
                  fontSize: AppTypography.sizeLabel,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// One category's heading on the imitated page.
///
/// A menu is read in blocks, so the heading has to be findable while scrolling
/// past at speed: an accent mark, the name, how many are in it, and a rule that
/// carries the eye across to the next card.
class _SectionHeading extends StatelessWidget {
  const _SectionHeading({required this.section});

  final CatalogPreviewSection section;

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    return Row(
      children: [
        const SizedBox(
          width: 3,
          height: 18,
          child: DecoratedBox(
            decoration: BoxDecoration(gradient: AppColors.goldGradient),
          ),
        ),
        const SizedBox(width: AppSpacing.sm),
        Flexible(
          child: Text(
            section.title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.w700,
              letterSpacing: 0.4,
            ),
          ),
        ),
        const SizedBox(width: AppSpacing.sm),
        Text(
          '${section.products.length}',
          style: textTheme.bodySmall?.copyWith(
            color: AppColors.textMuted,
            fontWeight: FontWeight.w700,
          ),
        ),
        const SizedBox(width: AppSpacing.md),
        const Expanded(child: _Hairline()),
      ],
    );
  }
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
            Container(
              padding: const EdgeInsets.all(AppSpacing.lg),
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: AppColors.surface1,
                border: Border.all(color: AppColors.surface2),
              ),
              child: const Icon(Icons.restaurant_menu_outlined,
                  size: 32, color: AppColors.textMuted),
            ),
            const SizedBox(height: AppSpacing.lg),
            Text(
              'Nothing on the menu yet',
              style: Theme.of(context)
                  .textTheme
                  .titleMedium
                  ?.copyWith(fontWeight: FontWeight.w700),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: AppSpacing.xs),
            Text(
              'This is exactly what a customer would see if you published now.',
              textAlign: TextAlign.center,
              style: Theme.of(context)
                  .textTheme
                  .bodySmall
                  ?.copyWith(color: AppColors.textSecondary, height: 1.45),
            ),
          ],
        ),
      );
}
