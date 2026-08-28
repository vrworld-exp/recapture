// lib/presentation/screens/catalog/catalog_screen.dart
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/routes/app_router.dart';
import '../../../app/routes/flow_back.dart';
import '../../../app/theme/app_colors.dart';
import '../../../app/theme/app_spacing.dart';
import '../../../application/catalog/bulk_selection_notifier.dart';
import '../../../application/catalog/catalog_categories_notifier.dart';
import '../../../application/catalog/catalog_notifier.dart';
import '../../../application/catalog/catalog_products_notifier.dart';
import '../../../data/repositories/catalog_failure.dart';
import '../../../domain/entities/catalog.dart';
import '../../../domain/entities/catalog_product.dart';
import '../../../domain/entities/catalog_status.dart';
import '../../widgets/app_button.dart';
import '../../widgets/app_loading_indicator.dart';
import '../../widgets/catalog/catalog_feedback.dart';
import '../../widgets/catalog/bulk_selection_bar.dart';
import '../../widgets/catalog/catalog_message.dart';
import '../../widgets/catalog/product_actions.dart';
import 'create_catalog_dialog.dart';
import 'delete_catalog_dialog.dart';
import 'product_grid_section.dart';

/// The catalog shell — the storefront authoring surface's home.
///
/// Three states, and the distinction between the first two is the whole point:
///   • **No catalog yet** (`AsyncData(null)`) → the create prompt. This is a
///     first-run state, not an error; the server's 404 is translated to null by
///     the repository so it never reaches the UI as a failure.
///   • **A catalog** → the header card, then the product surface, which owns its
///     own empty / filtered-empty / loading / error states
///     ([ProductGridSection]) because only it knows which of them applies.
///   • **A failed load** → the error state with a retry.
///
/// Nothing here reaches customers. Every write on this surface is a draft edit;
/// the live catalog only moves when the user presses Publish (feature 57).
class CatalogScreen extends ConsumerStatefulWidget {
  const CatalogScreen({super.key});

  @override
  ConsumerState<CatalogScreen> createState() => _CatalogScreenState();
}

class _CatalogScreenState extends ConsumerState<CatalogScreen> {
  /// Opens the create form and acknowledges the result.
  ///
  /// Nothing is refreshed on success: [CatalogNotifier.create] has already put
  /// the created catalog into state, so this screen has rebuilt into
  /// [_CatalogBody] by the time the dialog finishes popping. Failures never
  /// reach here — the dialog keeps them next to the fields the user typed in.
  Future<void> _createCatalog() async {
    final created = await showCreateCatalogDialog(context);
    if (created == null || !mounted) return; // cancelled

    CatalogFeedback.confirm(
      CatalogFeedback.of(context),
      '${created.name} is ready. Add your first product.',
    );
  }

  /// Deletes the whole catalog, after the typed-name confirmation.
  ///
  /// Nothing is refreshed and nothing is navigated afterwards: the notifier puts
  /// state back to `AsyncData(null)` — the same value as "never had one" — so
  /// this screen rebuilds into [_NoCatalogYet] on its own, and the user is left
  /// exactly one tap from creating the replacement. That is the whole point of
  /// the feature, so sending them back to Projects would be the wrong ending.
  ///
  /// Failures never reach here: the dialog keeps them where the user can retry.
  Future<void> _deleteCatalog(Catalog catalog) async {
    // Captured BEFORE the await — a catalog action outlives the widget that
    // started it, and this dialog is on screen for as long as a Mirage teardown
    // takes. See CatalogFeedback.of.
    final messenger = CatalogFeedback.of(context);

    final summary = await showDeleteCatalogDialog(context, catalog);
    if (summary == null) return; // cancelled

    CatalogFeedback.confirm(
      messenger,
      summary.wasPublished
          ? '${catalog.name} and its public page were deleted. '
              'Create a new catalog to start over.'
          : '${catalog.name} was deleted. Create a new catalog to start over.',
    );
  }

  /// Opens the add-product form.
  ///
  /// push, not go: /catalog is a top-level destination reached with go(), and
  /// pushing the form on top of it is what lets back pop straight back to the
  /// catalog. The grid is refreshed on return because a product created while
  /// this screen was covered is not in the page it already holds.
  Future<void> _addProduct() async {
    await context.pushNamed(AppRouteNames.productNew);
    if (!mounted) return;
    await ref.read(catalogProductsProvider.notifier).refresh();
  }

  /// Opens one product's editor, then re-reads it: the editor returns after an
  /// arbitrary number of saves, and the card behind it is a snapshot from
  /// whenever its page was fetched.
  Future<void> _openProduct(CatalogProduct product) async {
    await context.pushNamed(
      AppRouteNames.productDetail,
      pathParameters: {'productId': product.id},
    );
    if (!mounted) return;
    await ref.read(catalogProductsProvider.notifier).refresh();
    await ref.read(catalogProvider.notifier).refresh();
  }

  /// Opens the business profile — name, logo, cover, contact and socials.
  ///
  /// push, not go: /catalog/settings is a sub-screen of the shell, so back pops
  /// straight back to it. The profile and the header card read the same catalog
  /// notifier, which the profile refreshes on every write, so nothing needs
  /// refreshing on return.
  void _openBusinessProfile() =>
      context.pushNamed(AppRouteNames.catalogSettings);

  /// Opens the preview — the draft in the public page's shape (feature 5).
  ///
  /// push, not go: it is a sub-screen of the shell, so back pops straight back.
  /// Nothing is refreshed on return: the preview reads its own copy of the
  /// draft, and a fix made from inside it re-reads that copy itself. What CAN
  /// change underneath is a product the user edited from a preview warning, so
  /// the grid is re-pulled for the same reason opening a product editor does.
  Future<void> _openPreview() async {
    await context.pushNamed(AppRouteNames.catalogPreview);
    if (!mounted) return;
    await ref.read(catalogProductsProvider.notifier).refresh();
  }

  /// Opens the publish screen — the pre-flight checklist, the live run, and
  /// whatever the last one left behind (features 36-39).
  ///
  /// The catalog notifier is re-read on return because the header's own chips
  /// (Published / Draft changes / Publishing) are server-derived and a run that
  /// finished while the user was on that screen has moved all three. The
  /// publish notifier refreshes it as it polls, so this is only the belt to
  /// that braces — and it costs one request on a screen the user just left.
  Future<void> _openPublish() async {
    await context.pushNamed(AppRouteNames.catalogPublish);
    if (!mounted) return;
    await ref.read(catalogProvider.notifier).refresh();
  }

  /// Opens the QR screen. Offered whenever the catalog has been provisioned —
  /// including while it is UNPUBLISHED, because taking a catalog offline keeps
  /// the link and the code alive and a business may still need to reprint one.
  void _openQr() => context.pushNamed(AppRouteNames.catalogQr);

  /// Opens the analytics dashboard (feature 66).
  ///
  /// Offered UNCONDITIONALLY, unlike the QR above. The two differ in what is
  /// behind them before the first publish: there is no code to show, but there
  /// IS an analytics destination, and its empty state is the instruction
  /// "publish first, then the numbers appear here". A business hunting for its
  /// visitor numbers should land on that sentence rather than on a button that
  /// is not there.
  void _openAnalytics() => context.pushNamed(AppRouteNames.catalogAnalytics);

  /// Opens the category manager. Categories are not decoration: Mirage's
  /// create-item requires a real category id, so this is where a catalog becomes
  /// publishable. The grid's chips and the editor's picker read the same list,
  /// so nothing needs refreshing on return.
  void _openCategories() => context.pushNamed(AppRouteNames.catalogCategories);

  /// Pull-to-refresh pulls everything the screen shows: the catalog's own header
  /// counts, the product pages, and the category chips. Refreshing one of the
  /// three is how a header claiming 12 products ends up over a grid of 11.
  Future<void> _refreshAll() => Future.wait([
        ref.read(catalogProvider.notifier).refresh(),
        ref.read(catalogProductsProvider.notifier).refresh(),
        ref.read(catalogCategoriesProvider.notifier).refresh(),
      ]);

  @override
  Widget build(BuildContext context) {
    final catalogAsync = ref.watch(catalogProvider);
    final selecting = ref.watch(
      bulkSelectionProvider.select((selection) => selection.isActive),
    );

    return Scaffold(
      backgroundColor: AppColors.bgPrimary,
      // Selection REPLACES the screen's chrome rather than adding to it. The
      // count belongs where the title was, and the way out has to be as
      // prominent as the actions it guards.
      appBar: selecting
          ? const BulkSelectionAppBar()
          : AppBar(
              backgroundColor: Colors.transparent,
              elevation: 0,
              leading: IconButton(
                icon: const Icon(Icons.arrow_back),
                tooltip: 'Back',
                // navigateBack, not Navigator.pop: this screen is reached with
                // go(), so there is usually nothing to pop and a bare pop would
                // do nothing.
                onPressed: () => navigateBack(context),
              ),
              title: Text(
                'Catalog',
                style: Theme.of(context).textTheme.titleLarge,
              ),
            ),
      bottomNavigationBar: selecting ? const BulkActionBar() : null,
      body: RefreshIndicator(
        color: AppColors.mirageRed,
        backgroundColor: AppColors.surface1,
        onRefresh: _refreshAll,
        child: catalogAsync.when(
          loading: () => const Center(child: AppLoadingIndicator()),
          error: (error, _) => CatalogMessage(
            icon: Icons.cloud_off_outlined,
            title: "We couldn't load your catalog",
            body: error is CatalogFailure
                ? CatalogFeedback.failureText(error)
                : CatalogFeedback.textForCode(null),
            actionLabel: 'Try again',
            onAction: () => ref.invalidate(catalogProvider),
          ),
          data: (catalog) => catalog == null
              ? _NoCatalogYet(onCreate: _createCatalog)
              : _CatalogBody(
                  catalog: catalog,
                  onAddProduct: _addProduct,
                  onDeleteCatalog: () => _deleteCatalog(catalog),
                  onOpenProduct: _openProduct,
                  onOpenCategories: _openCategories,
                  onOpenBusinessProfile: _openBusinessProfile,
                  onOpenPreview: _openPreview,
                  onOpenPublish: _openPublish,
                  onOpenQr: _openQr,
                  onOpenAnalytics: _openAnalytics,
                  onSelect: () =>
                      ref.read(bulkSelectionProvider.notifier).enter(),
                ),
        ),
      ),
    );
  }
}

/// First run: the account has no catalog at all.
class _NoCatalogYet extends StatelessWidget {
  const _NoCatalogYet({required this.onCreate});

  final VoidCallback onCreate;

  @override
  Widget build(BuildContext context) => CatalogMessage(
        icon: Icons.storefront_outlined,
        title: 'No catalog yet',
        body: 'Your catalog is the storefront customers open when they scan '
            'your QR code. Create it once — the link never changes after that.',
        actionLabel: 'Create catalog',
        onAction: onCreate,
      );
}

/// A catalog exists: the header card, then the product surface.
///
/// ONE scroll view for both. The grid is composed in as slivers rather than
/// nested as its own scrollable, so the header scrolls away with the products,
/// pull-to-refresh covers the whole screen, and infinite scroll has a single set
/// of metrics to watch.
class _CatalogBody extends ConsumerWidget {
  const _CatalogBody({
    required this.catalog,
    required this.onAddProduct,
    required this.onDeleteCatalog,
    required this.onOpenProduct,
    required this.onOpenCategories,
    required this.onOpenBusinessProfile,
    required this.onOpenPreview,
    required this.onOpenPublish,
    required this.onOpenQr,
    required this.onOpenAnalytics,
    required this.onSelect,
  });

  final Catalog catalog;
  final VoidCallback onAddProduct;
  final VoidCallback onDeleteCatalog;
  final ValueChanged<CatalogProduct> onOpenProduct;
  final VoidCallback onOpenCategories;
  final VoidCallback onOpenBusinessProfile;
  final VoidCallback onOpenPreview;
  final VoidCallback onOpenPublish;
  final VoidCallback onOpenQr;
  final VoidCallback onOpenAnalytics;

  /// Enters selection mode. Always offered, not only on web: a button is the
  /// discoverable half of a feature whose other entry point is a long-press
  /// that nothing on screen advertises.
  final VoidCallback onSelect;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final selecting = ref.watch(
      bulkSelectionProvider.select((selection) => selection.isActive),
    );

    // The keyboard half of selection: Ctrl/Cmd+A over the grid, Escape to
    // leave. Wrapped around the scroll view because a shortcut only fires while
    // the focus is inside the widget declaring it, and after a click on a card
    // the focus is on that card.
    return BulkSelectionShortcuts(
      child: NotificationListener<ScrollNotification>(
        onNotification: (notification) =>
            ProductGridSection.handleScrollNotification(ref, notification),
        child: CustomScrollView(
          // Always scrollable so pull-to-refresh works even when the body is
          // shorter than the viewport (an empty or filtered-empty catalog).
          physics: const AlwaysScrollableScrollPhysics(),
          slivers: [
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(
                AppSpacing.screenPadding,
                AppSpacing.screenPadding,
                AppSpacing.screenPadding,
                0,
              ),
              sliver: SliverMainAxisGroup(
                slivers: [
                  SliverToBoxAdapter(
                    child: _CatalogHeaderCard(
                      catalog: catalog,
                      onDeleteCatalog: onDeleteCatalog,
                      onOpenBusinessProfile: onOpenBusinessProfile,
                      onOpenPreview: onOpenPreview,
                      onOpenPublish: onOpenPublish,
                      onOpenQr: onOpenQr,
                      onOpenAnalytics: onOpenAnalytics,
                    ),
                  ),
                  const SliverToBoxAdapter(
                    child: SizedBox(height: AppSpacing.xxl),
                  ),
                  SliverToBoxAdapter(
                    // Wrap, not Row: a heading plus three buttons does not fit a
                    // phone width, and an overflow stripe is not a header.
                    child: Wrap(
                      crossAxisAlignment: WrapCrossAlignment.center,
                      alignment: WrapAlignment.spaceBetween,
                      children: [
                        Text(
                          'Products',
                          style: Theme.of(context).textTheme.headlineMedium,
                        ),
                        // Hidden while selecting: the selection bars own the
                        // screen's actions then, and these would compete with
                        // them for the same tap.
                        if (!selecting)
                          Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              TextButton.icon(
                                icon: const Icon(Icons.checklist, size: 18),
                                label: const Text('Select'),
                                onPressed: onSelect,
                              ),
                              TextButton.icon(
                                icon: const Icon(
                                  Icons.category_outlined,
                                  size: 18,
                                ),
                                label: const Text('Categories'),
                                onPressed: onOpenCategories,
                              ),
                              TextButton.icon(
                                icon: const Icon(Icons.add, size: 18),
                                label: const Text('Add product'),
                                onPressed: onAddProduct,
                              ),
                            ],
                          ),
                      ],
                    ),
                  ),
                  const SliverToBoxAdapter(
                    child: SizedBox(height: AppSpacing.md),
                  ),
                  ProductGridSection(
                    onOpenProduct: onOpenProduct,
                    onAddProduct: onAddProduct,
                    // The menu owns its own confirmations, undo and feedback,
                    // so the shell hands it the anchor and stays out of the way.
                    onProductMenu: showProductActionsMenu,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// The catalog's identity and publish state at a glance (features 4, 37, 38).
class _CatalogHeaderCard extends StatelessWidget {
  const _CatalogHeaderCard({
    required this.catalog,
    required this.onDeleteCatalog,
    required this.onOpenBusinessProfile,
    required this.onOpenPreview,
    required this.onOpenPublish,
    required this.onOpenQr,
    required this.onOpenAnalytics,
  });

  final Catalog catalog;
  final VoidCallback onDeleteCatalog;
  final VoidCallback onOpenBusinessProfile;
  final VoidCallback onOpenPreview;
  final VoidCallback onOpenPublish;
  final VoidCallback onOpenQr;
  final VoidCallback onOpenAnalytics;

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;

    return Container(
      padding: const EdgeInsets.all(AppSpacing.lg),
      decoration: BoxDecoration(
        color: AppColors.surface1,
        borderRadius: BorderRadius.circular(AppRadius.sm),
        border: Border.all(color: AppColors.royalGold.withValues(alpha: 0.2)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(catalog.name, style: textTheme.titleLarge),
              ),
              IconButton(
                tooltip: 'Business profile',
                icon: const Icon(
                  Icons.badge_outlined,
                  size: 20,
                  color: AppColors.textSecondary,
                ),
                onPressed: onOpenBusinessProfile,
              ),
              // Behind a menu, not out on the header next to Publish and
              // Preview. Deleting the catalog is the one action on this screen
              // that cannot be undone and that gives up the public URL — it
              // needs to be FINDABLE, which is why it is here on the catalog
              // itself rather than buried in app settings, but a red button
              // sitting a thumb's width from Preview is how it gets pressed by
              // accident. The typed-name confirmation is the second gate.
              PopupMenuButton<_CatalogMenuAction>(
                tooltip: 'More',
                color: AppColors.surface1,
                icon: const Icon(
                  Icons.more_vert,
                  size: 20,
                  color: AppColors.textSecondary,
                ),
                onSelected: (action) => switch (action) {
                  _CatalogMenuAction.delete => onDeleteCatalog(),
                },
                itemBuilder: (context) => [
                  PopupMenuItem(
                    value: _CatalogMenuAction.delete,
                    child: Row(
                      children: [
                        const Icon(
                          Icons.delete_outline,
                          size: 18,
                          color: AppColors.error,
                        ),
                        const SizedBox(width: AppSpacing.sm),
                        Text(
                          'Delete catalog',
                          style: Theme.of(context)
                              .textTheme
                              .bodyMedium
                              ?.copyWith(color: AppColors.error),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ],
          ),
          if (catalog.businessName != null) ...[
            const SizedBox(height: AppSpacing.xs),
            Text(
              catalog.businessName!,
              style: textTheme.bodyMedium
                  ?.copyWith(color: AppColors.textSecondary),
            ),
          ],
          const SizedBox(height: AppSpacing.md),
          Wrap(
            spacing: AppSpacing.sm,
            runSpacing: AppSpacing.sm,
            children: [
              _Chip(
                label: catalog.status.label,
                color: catalog.status.isLive
                    ? AppColors.success
                    : AppColors.textMuted,
              ),
              // Feature 38. Server-derived — never recomputed here.
              if (catalog.hasUnpublishedChanges)
                const _Chip(
                  label: 'Draft changes not yet live',
                  color: AppColors.warning,
                ),
              if (catalog.isPublishing)
                const _Chip(label: 'Publishing…', color: AppColors.royalGold),
            ],
          ),
          const SizedBox(height: AppSpacing.md),
          Text(
            '${catalog.counts.products} products · '
            '${catalog.counts.categories} categories',
            style:
                textTheme.bodySmall?.copyWith(color: AppColors.textSecondary),
          ),
          const SizedBox(height: AppSpacing.md),
          // Wrap, not Row: this grows as the publish surfaces land, and a
          // header that overflows on a phone is not a header.
          Wrap(
            spacing: AppSpacing.sm,
            runSpacing: AppSpacing.sm,
            children: [
              AppButton(
                key: const ValueKey('catalog_publish_cta'),
                // "Publish changes" once something is live: the first press
                // creates a public page, every one after that updates one, and
                // those are different promises.
                label: catalog.isNeverPublished
                    ? 'Publish'
                    : 'Publish changes',
                icon: Icons.cloud_upload_outlined,
                isFullWidth: false,
                onPressed: onOpenPublish,
              ),
              AppButton.secondary(
                key: const ValueKey('catalog_preview_cta'),
                label: 'Preview',
                icon: Icons.visibility_outlined,
                isFullWidth: false,
                onPressed: onOpenPreview,
              ),
              // Only once a URL exists. Before the first publish there is no
              // code to show, and an entry point to an explanation of why the
              // thing is missing is worse than no entry point.
              if (catalog.isProvisioned)
                AppButton.secondary(
                  key: const ValueKey('catalog_qr_cta'),
                  label: 'QR code',
                  icon: Icons.qr_code_2,
                  isFullWidth: false,
                  onPressed: onOpenQr,
                ),
              // Unconditional, unlike the QR above: before the first publish
              // there is no code to show, but there IS an analytics
              // destination whose empty state says "publish first". See
              // `_CatalogShellState._openAnalytics`.
              AppButton.secondary(
                key: const ValueKey('catalog_analytics_cta'),
                label: 'Analytics',
                icon: Icons.insights_outlined,
                isFullWidth: false,
                onPressed: onOpenAnalytics,
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// The header's overflow menu. An enum with one entry rather than a bare
/// callback because this menu is where the next catalog-level action lands, and
/// a `switch` over it is a compile error the day one is added without a branch.
enum _CatalogMenuAction { delete }

class _Chip extends StatelessWidget {
  const _Chip({required this.label, required this.color});

  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.md,
          vertical: AppSpacing.xs,
        ),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(AppRadius.xs),
          border: Border.all(color: color.withValues(alpha: 0.4)),
        ),
        child: Text(
          label,
          style: Theme.of(context).textTheme.bodySmall?.copyWith(color: color),
        ),
      );
}

/// The Projects app-bar entry point to the catalog.
///
/// go(), not push: /catalog is a standalone top-level destination like /profile,
/// so the location REPLACES /projects and a cold deep-link behaves identically.
/// Back is not lost — FlowBackScope maps /catalog → /projects.
class CatalogEntryAction extends StatelessWidget {
  const CatalogEntryAction({super.key});

  @override
  Widget build(BuildContext context) => IconButton(
        tooltip: 'Catalog',
        icon: const Icon(Icons.storefront_outlined,
            color: AppColors.textSecondary),
        onPressed: () => context.goNamed(AppRouteNames.catalog),
      );
}
