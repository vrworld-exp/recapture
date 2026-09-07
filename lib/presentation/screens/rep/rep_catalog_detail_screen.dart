// lib/presentation/screens/rep/rep_catalog_detail_screen.dart
//
// One delegated restaurant's dishes, while the rep is still at the table.
//
// THE SCREEN'S REASON TO EXIST IS THE BADGE. A rep adds a dish, captures it,
// comes back here, and watches it flip from "3D generating…" to "AR ready"
// without pulling to refresh — that flip is the whole promise of the visit, and
// a rep who cannot see it happen leaves not knowing whether it worked. The poll
// loop behind it is the app's shared cadence (see PendingPollLoop), stops the
// moment nothing is pending, and dies with this screen.
//
// ADD-DISH DEEP-LINKS INTO THE EXISTING CAPTURE FLOW, UNMODIFIED. There is no
// rep-specific capture path and there must not be one: a forked flow is a
// second implementation of the hardest screen in the app, and it is the one
// nobody would keep in step.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/theme/app_colors.dart';
import '../../../app/theme/app_spacing.dart';
import '../../../app/theme/app_typography.dart';
import '../../../application/rep/rep_catalogs_notifier.dart';
import '../../../application/rep/rep_publish_notifier.dart';
import '../../widgets/catalog/catalog_feedback.dart';
import '../../../domain/entities/catalog_product.dart';
import '../../../domain/entities/product_model_status.dart';
import '../../widgets/app_button.dart';
import '../../widgets/app_loading_indicator.dart';

class RepCatalogDetailScreen extends ConsumerWidget {
  const RepCatalogDetailScreen({super.key, required this.catalogId});

  final String catalogId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final products = ref.watch(repCatalogProductsProvider(catalogId));
    final publish = ref.watch(repPublishProvider(catalogId));

    ref.listen<RepPublishState>(repPublishProvider(catalogId), (prev, next) {
      final failure = next.failure;
      final changed = failure?.code != prev?.failure?.code ||
          next.notice != prev?.notice;
      if (!changed) return;

      final messenger = CatalogFeedback.of(context);
      if (next.isBlocked) {
        // The gate list, not a generic sentence: these are the things the rep
        // can still fix while standing in the restaurant.
        CatalogFeedback.confirm(
          messenger,
          next.gates.length == 1
              ? next.gates.first.message
              : '${next.gates.length} things to fix: ${next.gates.first.message}',
        );
      } else if (failure != null) {
        CatalogFeedback.failure(
          messenger,
          failure,
          subject: 'The menu could not be published',
        );
      } else if (next.notice != null) {
        CatalogFeedback.confirm(messenger, next.notice!);
      }
    });

    return Scaffold(
      backgroundColor: AppColors.bgPrimary,
      appBar: AppBar(title: const Text('Dishes')),
      floatingActionButton: FloatingActionButton.extended(
        key: const ValueKey('rep_add_dish_fab'),
        onPressed: () async {
          // The SOURCE PICKER, not the camera. Going straight to capture was
          // the mobile-only assumption stage 10 removed: a rep on a laptop has
          // no capture pipeline at all, and even on a phone "from a finished
          // capture" and "photo" are ordinary ways to add a dish.
          //
          // The refresh is what makes a new "3D generating…" row appear
          // immediately rather than up to one poll interval later.
          await context.push('/rep/catalogs/$catalogId/dishes/new');
          if (!context.mounted) return;
          await ref
              .read(repCatalogProductsProvider(catalogId).notifier)
              .refresh();
        },
        icon: const Icon(Icons.add),
        label: const Text('Add a dish'),
      ),
      // A BOTTOM BAR, NOT A SECOND FAB. "Add a dish" is the repeated action and
      // keeps the FAB; publishing happens once, at the end of the visit. Two
      // floating buttons would also put the rarer, irreversible-feeling one
      // under the thumb that has been tapping the other all visit.
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(AppSpacing.lg),
          child: AppButton(
            key: const ValueKey('rep_publish_button'),
            label: 'Publish the menu',
            isLoading: publish.publishing,
            onPressed: publish.publishing
                ? null
                : () async {
                    await ref
                        .read(repPublishProvider(catalogId).notifier)
                        .publish();
                    // The status the list renders moves on publish, so the
                    // rep sees the change rather than having to pull down.
                    await ref
                        .read(repCatalogProductsProvider(catalogId).notifier)
                        .refresh();
                  },
          ),
        ),
      ),
      body: SafeArea(
        child: RefreshIndicator(
          onRefresh: () =>
              ref.read(repCatalogProductsProvider(catalogId).notifier).refresh(),
          child: products.when(
            loading: () => const Center(child: AppLoadingIndicator()),
            error: (_, __) => _Message(
              title: "Couldn't load the dishes.",
              body: 'Check your connection and pull down to try again.',
              onRetry: () => ref
                  .read(repCatalogProductsProvider(catalogId).notifier)
                  .refresh(),
            ),
            data: (items) => items.isEmpty
                ? const _Message(
                    title: 'No dishes yet.',
                    body: 'Add the first one — capture it and the 3D model '
                        'starts generating on its own.',
                  )
                : ListView.separated(
                    padding: const EdgeInsets.fromLTRB(
                      AppSpacing.lg,
                      AppSpacing.lg,
                      AppSpacing.lg,
                      AppSpacing.huge * 2,
                    ),
                    itemCount: items.length,
                    separatorBuilder: (_, __) =>
                        const SizedBox(height: AppSpacing.sm),
                    itemBuilder: (_, i) => _DishRow(product: items[i]),
                  ),
          ),
        ),
      ),
    );
  }
}

class _DishRow extends StatelessWidget {
  const _DishRow({required this.product});

  final CatalogProduct product;

  @override
  Widget build(BuildContext context) {
    // Same four states, same words as the product card's badge. Two surfaces
    // that disagree about what "3D unavailable" looks like is how a rep learns
    // to distrust both.
    final (label, color) = switch (product.modelStatus) {
      ProductModelStatus.queued ||
      ProductModelStatus.processing =>
        ('3D generating…', AppColors.textSecondary),
      ProductModelStatus.ready => ('AR ready', AppColors.royalGold),
      // NOT an error. The dish is on the menu; only AR is missing. A rep who
      // reads this as a rejection re-shoots the dish and spends generation
      // credits twice on a capture that was never the problem.
      ProductModelStatus.failed => ('3D unavailable', AppColors.textMuted),
      ProductModelStatus.none => ('Photo only', AppColors.textMuted),
    };

    return Container(
      padding: const EdgeInsets.all(AppSpacing.lg),
      decoration: BoxDecoration(
        color: AppColors.surface1,
        borderRadius: BorderRadius.circular(AppRadius.sm),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  product.name,
                  style: const TextStyle(
                    fontSize: AppTypography.sizeHeadline,
                    fontWeight: FontWeight.w600,
                    color: AppColors.textPrimary,
                  ),
                ),
                const SizedBox(height: 2),
                Row(
                  children: [
                    if (product.isModelPending) ...[
                      SizedBox(
                        width: 10,
                        height: 10,
                        child: CircularProgressIndicator(
                          strokeWidth: 1.5,
                          color: color,
                        ),
                      ),
                      const SizedBox(width: AppSpacing.xs),
                    ],
                    Text(
                      label,
                      style: TextStyle(
                        fontSize: AppTypography.sizeLabel,
                        color: color,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
          if (product.isArReady)
            const Icon(Icons.view_in_ar, color: AppColors.royalGold, size: 18),
        ],
      ),
    );
  }
}

class _Message extends StatelessWidget {
  const _Message({required this.title, required this.body, this.onRetry});

  final String title;
  final String body;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) => ListView(
        padding: const EdgeInsets.all(AppSpacing.xxl),
        children: [
          const SizedBox(height: AppSpacing.huge),
          Text(
            title,
            textAlign: TextAlign.center,
            style: const TextStyle(
              fontSize: AppTypography.sizeHeadline,
              fontWeight: FontWeight.w600,
              color: AppColors.textPrimary,
            ),
          ),
          const SizedBox(height: AppSpacing.sm),
          Text(
            body,
            textAlign: TextAlign.center,
            style: const TextStyle(
              fontSize: AppTypography.sizeBody,
              color: AppColors.textSecondary,
            ),
          ),
          if (onRetry != null) ...[
            const SizedBox(height: AppSpacing.lg),
            AppButton.secondary(label: 'Try again', onPressed: onRetry),
          ],
        ],
      );
}
