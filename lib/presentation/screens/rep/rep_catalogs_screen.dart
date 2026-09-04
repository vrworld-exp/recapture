// lib/presentation/screens/rep/rep_catalogs_screen.dart
//
// The rep's home: the restaurants they may act on, and the way to add another.
//
// The list is a PICKER, not a dashboard. It carries the name, whether the menu
// is live yet, and nothing else — a rep at a table wants to find the restaurant
// they are standing in and open it, and every extra number on the row is one
// more thing between them and that.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/routes/app_router.dart';
import '../../../app/theme/app_colors.dart';
import '../../../app/theme/app_spacing.dart';
import '../../../app/theme/app_typography.dart';
import '../../../application/rep/rep_catalogs_notifier.dart';
import '../../../domain/entities/catalog_status.dart';
import '../../../domain/entities/rep_activation.dart';
import '../../widgets/app_button.dart';
import '../../widgets/app_loading_indicator.dart';

class RepCatalogsScreen extends ConsumerWidget {
  const RepCatalogsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final catalogs = ref.watch(repCatalogsProvider);

    return Scaffold(
      backgroundColor: AppColors.bgPrimary,
      appBar: AppBar(title: const Text('My restaurants')),
      floatingActionButton: FloatingActionButton.extended(
        key: const ValueKey('rep_activate_fab'),
        onPressed: () => context.push(AppRoutes.repActivate),
        icon: const Icon(Icons.qr_code_scanner),
        label: const Text('Activate a standee'),
      ),
      body: SafeArea(
        child: RefreshIndicator(
          onRefresh: () => ref.read(repCatalogsProvider.notifier).refresh(),
          child: catalogs.when(
            loading: () => const Center(child: AppLoadingIndicator()),
            // No raw error text: a rep gets one sentence and a retry, never the
            // server's or a proxy's prose.
            error: (_, __) => _Message(
              title: "Couldn't load your restaurants.",
              body: 'Check your connection and pull down to try again.',
              onRetry: () => ref.read(repCatalogsProvider.notifier).refresh(),
            ),
            data: (items) => items.isEmpty
                ? const _Message(
                    title: 'No restaurants yet.',
                    body: 'Activate a standee to sign one up.',
                  )
                : ListView.separated(
                    padding: const EdgeInsets.all(AppSpacing.lg),
                    itemCount: items.length,
                    separatorBuilder: (_, __) =>
                        const SizedBox(height: AppSpacing.sm),
                    itemBuilder: (_, i) => _CatalogTile(summary: items[i]),
                  ),
          ),
        ),
      ),
    );
  }
}

class _CatalogTile extends StatelessWidget {
  const _CatalogTile({required this.summary});

  final RepCatalogSummary summary;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: AppColors.surface1,
      borderRadius: BorderRadius.circular(AppRadius.sm),
      child: InkWell(
        borderRadius: BorderRadius.circular(AppRadius.sm),
        onTap: () => context.push('${AppRoutes.repCatalogs}/${summary.id}'),
        child: Padding(
          padding: const EdgeInsets.all(AppSpacing.lg),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      summary.displayName,
                      style: const TextStyle(
                        fontSize: AppTypography.sizeHeadline,
                        fontWeight: FontWeight.w600,
                        color: AppColors.textPrimary,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      // "Menu live" is what a rep actually needs to know, and
                      // it is NOT the same as "activated": a catalog is
                      // activated the moment the standee is claimed and goes
                      // live on its first publish. Saying so plainly stops a
                      // rep leaving before the menu is up.
                      summary.status.isLive
                          ? 'Menu live'
                          : 'Not published yet',
                      style: TextStyle(
                        fontSize: AppTypography.sizeLabel,
                        color: summary.status.isLive
                            ? AppColors.royalGold
                            : AppColors.textMuted,
                      ),
                    ),
                  ],
                ),
              ),
              const Icon(Icons.chevron_right, color: AppColors.textMuted),
            ],
          ),
        ),
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
