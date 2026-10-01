// lib/presentation/screens/admin/admin_catalogs_screen.dart
//
// `/admin/catalogs` — the ADMIN's "All catalogs": every live catalog as a
// two-up grid of logo + name, with a search.
//
// A BROWSER. A card says which restaurant it is and nothing that would cost a
// request per card. Tapping one opens that restaurant's page
// ([AdminCatalogPageScreen]); editing starts from that page's banner.
//
// TWO PER ROW AT EVERY WIDTH, by request — so on a wide web window the grid is
// capped and centred instead of stretching two cards across 1600 px.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/routes/app_router.dart';
import '../../../app/theme/app_colors.dart';
import '../../../app/theme/app_spacing.dart';
import '../../../app/theme/app_typography.dart';
import '../../../application/admin/admin_catalogs_notifier.dart';
import '../../../data/repositories/admin_catalogs_repository.dart';
import '../../../domain/entities/admin_catalog_card.dart';
import '../../widgets/app_button.dart';
import '../../widgets/app_loading_indicator.dart';
import '../../widgets/catalog/catalog_message.dart';

/// The widest the grid gets. Two cards of ~350 px read as cards; two of 800 px
/// read as banners.
const double kAdminCatalogGridMaxWidth = 760;

class AdminCatalogsScreen extends ConsumerStatefulWidget {
  const AdminCatalogsScreen({super.key});

  @override
  ConsumerState<AdminCatalogsScreen> createState() =>
      _AdminCatalogsScreenState();
}

class _AdminCatalogsScreenState extends ConsumerState<AdminCatalogsScreen> {
  final _search = TextEditingController();
  Timer? _debounce;
  String _query = '';

  @override
  void dispose() {
    _debounce?.cancel();
    _search.dispose();
    super.dispose();
  }

  void _onSearch(String text) {
    // Rebuilds now so the clear button appears with the first character; the
    // QUERY waits, so typing "blue cafe" is one request rather than nine.
    setState(() {});
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 350), () {
      if (mounted) setState(() => _query = text.trim());
    });
  }

  void _clearSearch() {
    _search.clear();
    _debounce?.cancel();
    setState(() => _query = '');
  }

  Future<void> _open(AdminCatalogCard card) async {
    await context.push(
      '${AppRoutes.adminCatalogs}/${card.id}',
      extra: card.displayName,
    );
    if (!mounted) return;
    // The admin may have renamed, re-branded or published it — re-read
    // quietly so the card under their thumb is not stale.
    unawaited(ref.read(adminCatalogsProvider(_query).notifier).refresh());
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.bgPrimary,
      appBar: AppBar(title: const Text('All catalogs')),
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints:
                const BoxConstraints(maxWidth: kAdminCatalogGridMaxWidth),
            child: Column(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(
                      AppSpacing.lg, AppSpacing.md, AppSpacing.lg, 0),
                  child: TextField(
                    key: const ValueKey('admin_catalogs_search'),
                    controller: _search,
                    onChanged: _onSearch,
                    maxLength: kAdminCatalogQueryMaxLength,
                    textInputAction: TextInputAction.search,
                    decoration: InputDecoration(
                      isDense: true,
                      counterText: '',
                      prefixIcon: const Icon(Icons.search),
                      hintText: 'Search by restaurant or business name',
                      suffixIcon: _search.text.isEmpty
                          ? null
                          : IconButton(
                              tooltip: 'Clear',
                              icon: const Icon(Icons.close),
                              onPressed: _clearSearch,
                            ),
                    ),
                  ),
                ),
                Expanded(
                  child: _CatalogGrid(
                    query: _query,
                    onOpen: _open,
                    onClearSearch: _clearSearch,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _CatalogGrid extends ConsumerWidget {
  const _CatalogGrid({
    required this.query,
    required this.onOpen,
    required this.onClearSearch,
  });

  final String query;
  final ValueChanged<AdminCatalogCard> onOpen;
  final VoidCallback onClearSearch;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final provider = adminCatalogsProvider(query);
    final grid = ref.watch(provider);

    return RefreshIndicator(
      onRefresh: () => ref.read(provider.notifier).refresh(),
      child: grid.when(
        loading: () => const Center(child: AppLoadingIndicator()),
        // No raw error text: one sentence and a retry.
        error: (_, __) => CatalogMessage(
          icon: Icons.cloud_off_outlined,
          title: "Couldn't load catalogs.",
          body: 'Check your connection and try again.',
          actionLabel: 'Try again',
          onAction: () => ref.invalidate(provider),
        ),
        data: (state) {
          if (state.items.isEmpty) {
            return query.isEmpty
                ? const CatalogMessage(
                    icon: Icons.storefront_outlined,
                    title: 'No live catalogs yet.',
                    body: 'A catalog shows up here once it has been '
                        'published — live or taken offline.',
                  )
                : CatalogMessage(
                    icon: Icons.search_off,
                    title: 'No catalog matches "$query".',
                    body: 'Catalogs never published are not listed. Try '
                        'part of the name.',
                    actionLabel: 'Clear search',
                    onAction: onClearSearch,
                  );
          }
          return NotificationListener<ScrollNotification>(
            // Infinite scroll: the next page is asked for a screen before the
            // end. The explicit button below stays as the fallback — a short
            // page on a tall window never scrolls, so it never notifies.
            onNotification: (n) {
              if (state.hasMore &&
                  !state.loadingMore &&
                  n.metrics.extentAfter < 600) {
                ref.read(provider.notifier).loadMore();
              }
              return false;
            },
            child: CustomScrollView(
              physics: const AlwaysScrollableScrollPhysics(),
              slivers: [
                SliverPadding(
                  padding: const EdgeInsets.all(AppSpacing.lg),
                  sliver: SliverGrid(
                    gridDelegate:
                        const SliverGridDelegateWithFixedCrossAxisCount(
                      crossAxisCount: 2,
                      mainAxisSpacing: AppSpacing.md,
                      crossAxisSpacing: AppSpacing.md,
                      // Square logo + two lines of name + a chip row.
                      childAspectRatio: 0.74,
                    ),
                    delegate: SliverChildBuilderDelegate(
                      (_, i) => _CatalogCardTile(
                        card: state.items[i],
                        onTap: () => onOpen(state.items[i]),
                      ),
                      childCount: state.items.length,
                    ),
                  ),
                ),
                if (state.hasMore)
                  SliverToBoxAdapter(
                    child: Padding(
                      padding: const EdgeInsets.only(
                          bottom: AppSpacing.xxl,
                          left: AppSpacing.lg,
                          right: AppSpacing.lg),
                      child: state.loadingMore
                          ? const Center(child: AppLoadingIndicator())
                          : AppButton.secondary(
                              label: 'Load more',
                              onPressed: () =>
                                  ref.read(provider.notifier).loadMore(),
                            ),
                    ),
                  ),
              ],
            ),
          );
        },
      ),
    );
  }
}

class _CatalogCardTile extends StatelessWidget {
  const _CatalogCardTile({required this.card, required this.onTap});

  final AdminCatalogCard card;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final name = card.displayName.isEmpty ? 'Untitled' : card.displayName;
    return Material(
      key: ValueKey('admin_catalog_card_${card.id}'),
      color: AppColors.surface1,
      borderRadius: BorderRadius.circular(AppRadius.sm),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(AppSpacing.md),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(child: _CatalogIcon(url: card.logoUrl, name: name)),
              const SizedBox(height: AppSpacing.sm),
              Text(
                name,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontSize: AppTypography.sizeBody,
                  fontWeight: FontWeight.w600,
                  color: AppColors.textPrimary,
                  height: AppTypography.lineHeightTight,
                ),
              ),
              if (card.businessName case final business?) ...[
                const SizedBox(height: 2),
                Text(
                  business,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: AppTypography.sizeLabel,
                    color: AppColors.textMuted,
                  ),
                ),
              ],
              const SizedBox(height: AppSpacing.xs),
              Wrap(
                spacing: AppSpacing.xs,
                runSpacing: AppSpacing.xs,
                children: [
                  _StatusChip(card: card),
                  if (card.isBranch)
                    const _Chip(label: 'Branch', color: AppColors.textMuted),
                  // Someone saved edits and never published them — worth
                  // knowing before an admin publishes over them.
                  if (card.hasDraftChanges)
                    const _Chip(
                        label: 'Unpublished edits', color: AppColors.warning),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Live / Offline / Updating… — always shown, first chip on the card.
class _StatusChip extends StatelessWidget {
  const _StatusChip({required this.card});

  final AdminCatalogCard card;

  @override
  Widget build(BuildContext context) {
    final (label, color) = card.isPublishing
        ? ('Updating…', AppColors.warning)
        : card.isLive
            ? ('Live', AppColors.success)
            : ('Offline', AppColors.error);
    return KeyedSubtree(
      key: ValueKey('admin_catalog_status_${card.id}'),
      child: _Chip(label: label, color: color),
    );
  }
}

/// The catalog's logo, or its initial on a tile when it has none (or the image
/// fails to load — a broken CDN object must not leave a blank card).
class _CatalogIcon extends StatelessWidget {
  const _CatalogIcon({required this.url, required this.name});

  final String? url;
  final String name;

  @override
  Widget build(BuildContext context) {
    final fallback = ColoredBox(
      color: AppColors.surface2,
      child: Center(
        child: Text(
          name.characters.first.toUpperCase(),
          style: const TextStyle(
            fontSize: AppTypography.sizeDisplay,
            fontWeight: FontWeight.w700,
            color: AppColors.textMuted,
          ),
        ),
      ),
    );
    final url = this.url;
    return ClipRRect(
      borderRadius: BorderRadius.circular(AppRadius.xs),
      child: SizedBox.expand(
        child: url == null
            ? fallback
            : Image.network(
                url,
                fit: BoxFit.cover,
                errorBuilder: (_, __, ___) => fallback,
                loadingBuilder: (_, child, progress) =>
                    progress == null ? child : fallback,
              ),
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
        padding:
            const EdgeInsets.symmetric(horizontal: AppSpacing.sm, vertical: 1),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(AppRadius.xs),
          border: Border.all(color: color.withValues(alpha: 0.4)),
        ),
        child: Text(
          label,
          style: TextStyle(fontSize: AppTypography.sizeLabel, color: color),
        ),
      );
}
