// lib/presentation/screens/catalog/catalog_screen.dart
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/routes/app_router.dart';
import '../../../app/routes/flow_back.dart';
import '../../../app/theme/app_colors.dart';
import '../../../app/theme/app_spacing.dart';
import '../../../application/catalog/catalog_notifier.dart';
import '../../../data/repositories/catalog_failure.dart';
import '../../../domain/entities/catalog.dart';
import '../../../domain/entities/catalog_status.dart';
import '../../widgets/app_button.dart';
import '../../widgets/app_loading_indicator.dart';
import 'create_catalog_dialog.dart';

/// The catalog shell — the storefront authoring surface's home.
///
/// Three states, and the distinction between the first two is the whole point:
///   • **No catalog yet** (`AsyncData(null)`) → the create prompt. This is a
///     first-run state, not an error; the server's 404 is translated to null by
///     the repository so it never reaches the UI as a failure.
///   • **A catalog with no products** → the add-your-first-product prompt.
///   • **A catalog with products** → the grid (T-017 fills this in).
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

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('${created.name} is ready. Add your first product.')),
    );
  }

  @override
  Widget build(BuildContext context) {
    final catalogAsync = ref.watch(catalogProvider);

    return Scaffold(
      backgroundColor: AppColors.bgPrimary,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          tooltip: 'Back',
          // navigateBack, not Navigator.pop: this screen is reached with go(),
          // so there is usually nothing to pop and a bare pop would do nothing.
          onPressed: () => navigateBack(context),
        ),
        title: Text('Catalog', style: Theme.of(context).textTheme.titleLarge),
      ),
      body: RefreshIndicator(
        color: AppColors.mirageRed,
        backgroundColor: AppColors.surface1,
        onRefresh: () => ref.read(catalogProvider.notifier).refresh(),
        child: catalogAsync.when(
          loading: () => const Center(child: AppLoadingIndicator()),
          error: (error, _) => _CatalogMessage(
            icon: Icons.cloud_off_outlined,
            title: "We couldn't load your catalog",
            body: error is CatalogFailure
                ? error.message
                : 'Something went wrong. Please try again.',
            actionLabel: 'Try again',
            onAction: () => ref.invalidate(catalogProvider),
          ),
          data: (catalog) => catalog == null
              ? _NoCatalogYet(onCreate: _createCatalog)
              : _CatalogBody(catalog: catalog),
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
  Widget build(BuildContext context) => _CatalogMessage(
        icon: Icons.storefront_outlined,
        title: 'No catalog yet',
        body: 'Your catalog is the storefront customers open when they scan '
            'your QR code. Create it once — the link never changes after that.',
        actionLabel: 'Create catalog',
        onAction: onCreate,
      );
}

/// A catalog exists. For now this is the header plus the empty/coming-soon body;
/// the product grid lands with T-017.
class _CatalogBody extends StatelessWidget {
  const _CatalogBody({required this.catalog});

  final Catalog catalog;

  @override
  Widget build(BuildContext context) {
    return ListView(
      // Always scrollable so pull-to-refresh works even when the body is short.
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.all(AppSpacing.screenPadding),
      children: [
        _CatalogHeaderCard(catalog: catalog),
        const SizedBox(height: AppSpacing.xxl),
        if (catalog.counts.products == 0)
          const _CatalogMessage(
            icon: Icons.inventory_2_outlined,
            title: 'No products yet',
            body: 'Add a product from a model you have already captured, '
                'scan something new, or upload a photo.',
            actionLabel: 'Add product',
            onAction: null,
            fillsViewport: false,
          )
        else
          const _CatalogMessage(
            icon: Icons.grid_view_outlined,
            title: 'Products',
            body: 'The product grid arrives with the next release.',
            fillsViewport: false,
          ),
      ],
    );
  }
}

/// The catalog's identity and publish state at a glance (features 4, 37, 38).
class _CatalogHeaderCard extends StatelessWidget {
  const _CatalogHeaderCard({required this.catalog});

  final Catalog catalog;

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
          Text(catalog.name, style: textTheme.titleLarge),
          if (catalog.businessName != null) ...[
            const SizedBox(height: AppSpacing.xs),
            Text(
              catalog.businessName!,
              style: textTheme.bodyMedium?.copyWith(color: AppColors.textSecondary),
            ),
          ],
          const SizedBox(height: AppSpacing.md),
          Wrap(
            spacing: AppSpacing.sm,
            runSpacing: AppSpacing.sm,
            children: [
              _Chip(
                label: catalog.status.label,
                color: catalog.status.isLive ? AppColors.success : AppColors.textMuted,
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
            style: textTheme.bodySmall?.copyWith(color: AppColors.textSecondary),
          ),
        ],
      ),
    );
  }
}

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

/// The one centred icon + title + body + optional CTA block this screen uses for
/// every empty, error and not-yet-built state. One widget rather than four
/// near-identical ones, so they cannot drift apart visually.
class _CatalogMessage extends StatelessWidget {
  const _CatalogMessage({
    required this.icon,
    required this.title,
    required this.body,
    this.actionLabel,
    this.onAction,
    this.fillsViewport = true,
  });

  final IconData icon;
  final String title;
  final String body;
  final String? actionLabel;
  final VoidCallback? onAction;

  /// Whether this block owns the whole screen (the no-catalog / error states) or
  /// sits inside an already-scrolling list.
  final bool fillsViewport;

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;

    final content = Padding(
      padding: const EdgeInsets.all(AppSpacing.xxl),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 96,
            height: 96,
            decoration: BoxDecoration(
              color: AppColors.surface1,
              shape: BoxShape.circle,
              border: Border.all(
                color: AppColors.royalGold.withValues(alpha: 0.3),
                width: 0.5,
              ),
            ),
            child: Icon(icon, color: AppColors.textMuted, size: 40),
          ),
          const SizedBox(height: AppSpacing.xxl),
          Text(title, style: textTheme.titleLarge, textAlign: TextAlign.center),
          const SizedBox(height: AppSpacing.sm),
          Text(
            body,
            style: textTheme.bodyMedium
                ?.copyWith(color: AppColors.textSecondary, height: 1.5),
            textAlign: TextAlign.center,
          ),
          if (actionLabel != null) ...[
            const SizedBox(height: AppSpacing.xxl),
            AppButton(
              label: actionLabel!,
              isFullWidth: false,
              // A null onAction leaves the button disabled through the theme —
              // the step is named, but nothing pretends to work yet.
              onPressed: onAction,
            ),
          ],
        ],
      ),
    );

    if (!fillsViewport) return content;

    // Fill the viewport so pull-to-refresh stays available on a short body.
    return LayoutBuilder(
      builder: (context, constraints) => SingleChildScrollView(
        physics: const AlwaysScrollableScrollPhysics(),
        child: ConstrainedBox(
          constraints: BoxConstraints(minHeight: constraints.maxHeight),
          child: Center(child: content),
        ),
      ),
    );
  }
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
        icon: const Icon(Icons.storefront_outlined, color: AppColors.textSecondary),
        onPressed: () => context.goNamed(AppRouteNames.catalog),
      );
}
