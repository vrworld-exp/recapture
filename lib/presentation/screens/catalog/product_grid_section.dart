// lib/presentation/screens/catalog/product_grid_section.dart
//
// The product browsing surface: search, filters, the responsive grid, its four
// states, and reordering.
//
// Delivered as SLIVERS rather than as a screen, so it composes into the catalog
// shell's existing scroll view underneath the header card. One scrollable, not a
// list inside a list: nesting them is what makes a grid scroll independently of
// the header it belongs to, and breaks pull-to-refresh on the way.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/theme/app_colors.dart';
import '../../../app/theme/app_spacing.dart';
import '../../../application/catalog/catalog_categories_notifier.dart';
import '../../../application/catalog/catalog_products_notifier.dart';
import '../../../data/repositories/catalog_failure.dart';
import '../../../domain/entities/catalog_product.dart';
import '../../../domain/entities/product_availability.dart';
import '../../../domain/entities/product_type.dart';
import '../../widgets/catalog/catalog_message.dart';
import '../../widgets/catalog/product_card.dart';

/// How many columns the grid uses at [width].
///
/// Decided from the CONSTRAINTS the grid is handed, never from `kIsWeb`: a
/// narrow browser window is a phone layout and a tablet APK is not a phone. Same
/// rule as `model_picker_field.dart` — the platform decides CAPABILITIES, the
/// available width decides layout.
int productGridColumns(double width) {
  if (width < 600) return 2;
  if (width < 900) return 3;
  if (width < 1200) return 4;
  return 5;
}

/// Whether this width gets an explicit drag handle instead of long-press-drag.
///
/// Long-press to drag is the phone idiom and it does work with a mouse, but on a
/// desktop-width layout it is undiscoverable — nothing on screen says the cards
/// can move. Above phone width the handle is drawn and IS the drag target.
bool productGridUsesDragHandle(double width) => width >= 600;

/// Roughly the height of a card's text block (name up to two lines, then the
/// price row) on top of its square image. Used to derive the grid's aspect
/// ratio from the measured column width, so a cell is never a fixed pixel size.
const double _kCardTextExtent = 100;

/// Distance from the bottom at which the next page starts loading. About one
/// screen of cards on a phone: far enough that the spinner is rarely seen,
/// close enough that a slow connection is not asked for pages nobody scrolls to.
const double kProductGridPrefetchExtent = 600;

/// The product grid, as slivers.
///
/// Callers own the scroll view. [handleScrollNotification] is the other half of
/// this contract: the shell wires it into a `NotificationListener` around the
/// scroll view so the grid can ask for its next page.
class ProductGridSection extends ConsumerWidget {
  const ProductGridSection({
    super.key,
    required this.onOpenProduct,
    this.onAddProduct,
    this.onProductMenu,
  });

  /// Opens one product's editor.
  final ValueChanged<CatalogProduct> onOpenProduct;

  /// The first-run empty state's CTA. Null hides it.
  final VoidCallback? onAddProduct;

  /// Opens a product's overflow menu (archive / duplicate / delete). Null hides
  /// the button rather than rendering one that opens nothing.
  final ValueChanged<CatalogProduct>? onProductMenu;

  /// Fires the next-page load when a scroll approaches the end.
  ///
  /// Returns false so the notification keeps bubbling — this is an observer, not
  /// a consumer, and swallowing it would break anything else listening.
  static bool handleScrollNotification(
    WidgetRef ref,
    ScrollNotification notification,
  ) {
    if (notification is! ScrollUpdateNotification &&
        notification is! ScrollEndNotification) {
      return false;
    }
    final metrics = notification.metrics;
    if (!metrics.hasContentDimensions) return false;
    if (metrics.pixels >= metrics.maxScrollExtent - kProductGridPrefetchExtent) {
      // The notifier owns every guard against a double fetch (in-flight, no
      // cursor, a failed append awaiting retry), which is why this can be
      // called on every scroll frame without a local latch of its own.
      ref.read(catalogProductsProvider.notifier).loadMore();
    }
    return false;
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(catalogProductsProvider);
    final notifier = ref.read(catalogProductsProvider.notifier);

    return SliverMainAxisGroup(
      slivers: [
        const SliverToBoxAdapter(child: _ProductSearchField()),
        const SliverToBoxAdapter(child: SizedBox(height: AppSpacing.md)),
        const SliverToBoxAdapter(child: _ProductFilterBar()),
        const SliverToBoxAdapter(child: SizedBox(height: AppSpacing.lg)),
        if (state.isLoading && state.items.isEmpty)
          const _SkeletonGrid()
        else if (state.error != null)
          SliverToBoxAdapter(
            child: CatalogMessage(
              icon: Icons.cloud_off_outlined,
              title: "We couldn't load your products",
              body: state.error!.message,
              actionLabel: 'Try again',
              onAction: notifier.retry,
              fillsViewport: false,
            ),
          )
        else if (state.isFirstRunEmpty)
          SliverToBoxAdapter(
            child: CatalogMessage(
              icon: Icons.inventory_2_outlined,
              title: 'No products yet',
              body: 'Add a product from a model you have already captured, '
                  'or upload a photo.',
              actionLabel: onAddProduct == null ? null : 'Add product',
              onAction: onAddProduct,
              fillsViewport: false,
            ),
          )
        else if (state.isFilteredEmpty)
          SliverToBoxAdapter(
            child: CatalogMessage(
              icon: Icons.search_off_outlined,
              title: 'No products match',
              // The query is echoed so the user can see WHAT did not match —
              // "no results" on its own leaves them guessing whether the search
              // or the filters did it.
              body: _filteredEmptyBody(state.query),
              actionLabel: 'Clear filters',
              onAction: notifier.clearFilters,
              fillsViewport: false,
            ),
          )
        else
          _ProductGrid(
            state: state,
            onOpenProduct: onOpenProduct,
            onProductMenu: onProductMenu,
          ),
        SliverToBoxAdapter(child: _GridFooter(state: state)),
      ],
    );
  }

  static String _filteredEmptyBody(CatalogProductQuery query) {
    final term = query.searchTerm;
    if (term != null && query.activeFilterCount > 0) {
      return 'Nothing matches "$term" with these filters.';
    }
    if (term != null) return 'Nothing matches "$term".';
    return 'No products match these filters.';
  }
}

// ── Search ──────────────────────────────────────────────────────────────────

/// The search box.
///
/// Server-side and debounced by the notifier. What lives here is only the text
/// field's own state, plus the sync back FROM the notifier so that "Clear
/// filters" empties the box the user is looking at.
class _ProductSearchField extends ConsumerStatefulWidget {
  const _ProductSearchField();

  @override
  ConsumerState<_ProductSearchField> createState() =>
      _ProductSearchFieldState();
}

class _ProductSearchFieldState extends ConsumerState<_ProductSearchField> {
  final TextEditingController _controller = TextEditingController();
  final FocusNode _focusNode = FocusNode();

  @override
  void dispose() {
    _controller.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // One-way sync: the notifier is the source of truth for the query, so a
    // clear-from-elsewhere empties the field. Guarded on inequality, or every
    // keystroke would reset the cursor to the end of the text.
    ref.listen<String>(
      catalogProductsProvider.select((s) => s.query.search),
      (_, next) {
        if (_controller.text != next) _controller.text = next;
      },
    );

    // Read from the notifier, not the controller: the controller does not
    // notify this build, so a clear button driven by `_controller.text` would
    // only appear on the NEXT unrelated rebuild.
    final hasText = ref
        .watch(catalogProductsProvider.select((s) => s.query.search))
        .isNotEmpty;

    return TextField(
      controller: _controller,
      focusNode: _focusNode,
      textInputAction: TextInputAction.search,
      // No Shortcuts/Actions wrapper anywhere near this field. Flutter's default
      // text bindings leave Ctrl/Cmd+F alone, so it stays the BROWSER's find —
      // taking it would break a shortcut the user did not know they were
      // spending on our search box.
      onChanged: ref.read(catalogProductsProvider.notifier).search,
      style: Theme.of(context).textTheme.bodyLarge,
      decoration: InputDecoration(
        hintText: 'Search products',
        prefixIcon: const Icon(Icons.search, color: AppColors.textMuted),
        suffixIcon: hasText
            ? IconButton(
                icon: const Icon(Icons.close, color: AppColors.textMuted),
                tooltip: 'Clear search',
                onPressed: () {
                  _controller.clear();
                  ref.read(catalogProductsProvider.notifier).search('');
                },
              )
            : null,
      ),
      onTapOutside: (_) => _focusNode.unfocus(),
      onSubmitted: (_) => _focusNode.unfocus(),
    );
  }
}

// ── Filters ─────────────────────────────────────────────────────────────────

/// The filter chip row: category, type, availability, archived.
///
/// Every chip is a REQUEST parameter. Nothing here filters the loaded page.
class _ProductFilterBar extends ConsumerWidget {
  const _ProductFilterBar();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final query = ref.watch(catalogProductsProvider.select((s) => s.query));
    final notifier = ref.read(catalogProductsProvider.notifier);
    final categories =
        ref.watch(catalogCategoriesProvider).valueOrNull;

    return Wrap(
      spacing: AppSpacing.sm,
      runSpacing: AppSpacing.sm,
      children: [
        _CatalogFilterChip(
          label: 'All',
          selected: !query.isFiltered,
          onSelected: (_) => notifier.clearFilters(),
        ),
        _CatalogFilterChip(
          label: '3D',
          icon: Icons.view_in_ar_outlined,
          selected: query.type == ProductType.threeD,
          onSelected: (selected) =>
              notifier.setType(selected ? ProductType.threeD : null),
        ),
        _CatalogFilterChip(
          label: 'Image only',
          icon: Icons.image_outlined,
          selected: query.type == ProductType.imageOnly,
          onSelected: (selected) =>
              notifier.setType(selected ? ProductType.imageOnly : null),
        ),
        _CatalogFilterChip(
          label: 'Out of stock',
          selected: query.availability == ProductAvailability.outOfStock,
          onSelected: (selected) => notifier.setAvailability(
            selected ? ProductAvailability.outOfStock : null,
          ),
        ),
        _CatalogFilterChip(
          label: 'Archived',
          icon: Icons.inventory_2_outlined,
          selected: query.includeArchived,
          onSelected: notifier.setIncludeArchived,
        ),
        if (categories != null) ...[
          for (final category in categories.categories)
            _CatalogFilterChip(
              label: category.name,
              selected: query.categoryId == category.id,
              onSelected: (selected) =>
                  notifier.setCategory(selected ? category.id : null),
            ),
          // Always offered, even at zero, so the bucket does not appear and
          // disappear as products move in and out of it.
          _CatalogFilterChip(
            label: 'Uncategorized',
            selected: query.categoryId == kUncategorizedFilterId,
            onSelected: (selected) =>
                notifier.setCategory(selected ? kUncategorizedFilterId : null),
          ),
        ],
      ],
    );
  }
}

/// A filter chip in the app's own palette.
///
/// Hand-built rather than a Material `FilterChip` because the M3 chip's selected
/// state paints from the colour scheme's secondary container, which this theme
/// deliberately does not use — the result reads as a different app. Everything
/// else about it (focus, hover, keyboard activation) comes from [InkWell].
class _CatalogFilterChip extends StatelessWidget {
  const _CatalogFilterChip({
    required this.label,
    required this.selected,
    required this.onSelected,
    this.icon,
  });

  final String label;
  final bool selected;
  final ValueChanged<bool> onSelected;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    final color = selected ? AppColors.mirageRed : AppColors.textSecondary;

    return Semantics(
      selected: selected,
      button: true,
      child: Material(
        type: MaterialType.transparency,
        child: InkWell(
          borderRadius: BorderRadius.circular(AppRadius.xs),
          hoverColor: AppColors.surface2,
          focusColor: AppColors.surface2,
          onTap: () => onSelected(!selected),
          child: Container(
            padding: const EdgeInsets.symmetric(
              horizontal: AppSpacing.md,
              vertical: AppSpacing.sm,
            ),
            decoration: BoxDecoration(
              color: selected
                  ? AppColors.mirageRed.withValues(alpha: 0.12)
                  : AppColors.surface1,
              borderRadius: BorderRadius.circular(AppRadius.xs),
              border: Border.all(
                color: selected
                    ? AppColors.mirageRed.withValues(alpha: 0.6)
                    : AppColors.textMuted.withValues(alpha: 0.3),
                width: selected ? 1 : 0.5,
              ),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (icon != null) ...[
                  Icon(icon, size: 14, color: color),
                  const SizedBox(width: AppSpacing.xs),
                ],
                Text(
                  label,
                  style: Theme.of(context)
                      .textTheme
                      .bodySmall
                      ?.copyWith(color: color),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// ── The grid ────────────────────────────────────────────────────────────────

class _ProductGrid extends ConsumerWidget {
  const _ProductGrid({
    required this.state,
    required this.onOpenProduct,
    this.onProductMenu,
  });

  final CatalogProductsState state;
  final ValueChanged<CatalogProduct> onOpenProduct;
  final ValueChanged<CatalogProduct>? onProductMenu;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return SliverLayoutBuilder(
      builder: (context, constraints) {
        // SliverConstraints carries the cross-axis extent, which is the real
        // measured width of this grid — not the window's, not the screen's.
        final width = constraints.crossAxisExtent;
        final columns = productGridColumns(width);
        final cellWidth =
            (width - AppSpacing.md * (columns - 1)) / columns;
        final handles = productGridUsesDragHandle(width);

        return SliverGrid(
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: columns,
            mainAxisSpacing: AppSpacing.md,
            crossAxisSpacing: AppSpacing.md,
            // Derived from the measured column width so the square image plus
            // its text block always fits — a fixed ratio overflows the moment
            // the text scale or the column count changes.
            childAspectRatio:
                cellWidth / (cellWidth + _kCardTextExtent),
          ),
          delegate: SliverChildBuilderDelegate(
            (context, index) {
              final product = state.items[index];
              final card = ProductCard(
                product: product,
                onTap: () => onOpenProduct(product),
                onMore: onProductMenu == null
                    ? null
                    : () => onProductMenu!(product),
                dragHandle: state.canReorder && handles
                    ? _DragHandle(index: index)
                    : null,
              );

              return KeyedSubtree(
                key: ValueKey<String>(product.id),
                child: state.canReorder
                    ? _ReorderableCell(
                        index: index,
                        // On a phone the whole card is the drag target
                        // (long-press); on a wide layout only the handle is, so
                        // a mouse drag across a card stays a scroll/select
                        // gesture rather than an accidental reorder.
                        draggableWhole: !handles,
                        child: card,
                      )
                    : card,
              );
            },
            childCount: state.items.length,
            // Keyed by product id so an optimistic reorder moves the widgets it
            // built rather than repainting a stale card into a new slot.
            findChildIndexCallback: (key) {
              final id = (key as ValueKey<String>).value;
              final index = state.items.indexWhere((p) => p.id == id);
              return index == -1 ? null : index;
            },
          ),
        );
      },
    );
  }
}

/// One draggable / droppable grid cell.
///
/// Flutter ships no reorderable GRID, and `ReorderableListView` is a list — so
/// the pair of primitives underneath it ([Draggable] and [DragTarget]) is used
/// directly. Both touch drag and mouse drag come from the same widget, which is
/// what makes the web build's reorder work without a second code path.
class _ReorderableCell extends ConsumerWidget {
  const _ReorderableCell({
    required this.index,
    required this.draggableWhole,
    required this.child,
  });

  final int index;
  final bool draggableWhole;
  final Widget child;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return DragTarget<int>(
      onWillAcceptWithDetails: (details) => details.data != index,
      onAcceptWithDetails: (details) =>
          _move(context, ref, from: details.data, to: index),
      builder: (context, candidate, __) {
        final highlighted = candidate.isNotEmpty;
        final cell = AnimatedContainer(
          duration: const Duration(milliseconds: 120),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(AppRadius.sm),
            border: Border.all(
              color: highlighted
                  ? AppColors.mirageRed
                  : Colors.transparent,
              width: 2,
            ),
          ),
          child: child,
        );

        if (!draggableWhole) return cell;

        return LongPressDraggable<int>(
          data: index,
          feedback: _DragFeedback(child: child),
          childWhenDragging: Opacity(opacity: 0.3, child: cell),
          child: cell,
        );
      },
    );
  }
}

/// Moves a card and reports the outcome.
///
/// The notifier speaks `ReorderableListView`'s index convention (the target
/// counted BEFORE the dragged item is removed), so a "drop onto slot [to]"
/// gesture has to be translated once, here, rather than in both call sites.
Future<void> _move(
  BuildContext context,
  WidgetRef ref, {
  required int from,
  required int to,
}) async {
  final messenger = ScaffoldMessenger.of(context);
  try {
    await ref
        .read(catalogProductsProvider.notifier)
        .reorder(from, to > from ? to + 1 : to);
  } on CatalogFailure catch (failure) {
    // The grid has already snapped back — say why, or the card looks as though
    // it refused the drag for no reason. The server's own owner-safe sentence
    // (ID_SET_MISMATCH asks for a reload) plus what we did about it.
    messenger.showSnackBar(
      SnackBar(
        content: Text(
          '${failure.message} Your products are back in their previous order.',
        ),
      ),
    );
  }
}

/// The handle shown on wide layouts. It is the drag target, not a decoration.
class _DragHandle extends StatelessWidget {
  const _DragHandle({required this.index});

  final int index;

  @override
  Widget build(BuildContext context) {
    return Draggable<int>(
      data: index,
      feedback: const _DragHandleFeedback(),
      child: const MouseRegion(
        cursor: SystemMouseCursors.grab,
        child: Tooltip(
          message: 'Drag to reorder',
          child: Padding(
            padding: EdgeInsets.symmetric(horizontal: AppSpacing.xs),
            child: Icon(
              Icons.drag_indicator,
              size: 18,
              color: AppColors.textMuted,
            ),
          ),
        ),
      ),
    );
  }
}

class _DragHandleFeedback extends StatelessWidget {
  const _DragHandleFeedback();

  @override
  Widget build(BuildContext context) => const Material(
        color: Colors.transparent,
        child: Icon(Icons.drag_indicator, size: 22, color: AppColors.mirageRed),
      );
}

/// The card under the finger/cursor mid-drag. Bounded, because a feedback widget
/// is laid out UNCONSTRAINED — an unbounded card here is an immediate assertion.
class _DragFeedback extends StatelessWidget {
  const _DragFeedback({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) => Material(
        color: Colors.transparent,
        child: Opacity(
          opacity: 0.9,
          child: SizedBox(width: 160, height: 220, child: child),
        ),
      );
}

// ── Skeletons and footer ────────────────────────────────────────────────────

/// The first-load state: the grid's real shape, empty.
///
/// Cards rather than a single spinner, because the shape is the information —
/// the user sees where their products will be before they arrive, and the
/// screen does not jump when they do.
class _SkeletonGrid extends StatelessWidget {
  const _SkeletonGrid();

  @override
  Widget build(BuildContext context) {
    return SliverLayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.crossAxisExtent;
        final columns = productGridColumns(width);
        final cellWidth = (width - AppSpacing.md * (columns - 1)) / columns;

        return SliverGrid(
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: columns,
            mainAxisSpacing: AppSpacing.md,
            crossAxisSpacing: AppSpacing.md,
            childAspectRatio: cellWidth / (cellWidth + _kCardTextExtent),
          ),
          delegate: SliverChildBuilderDelegate(
            (context, index) => const _SkeletonCard(),
            childCount: columns * 2,
          ),
        );
      },
    );
  }
}

class _SkeletonCard extends StatelessWidget {
  const _SkeletonCard();

  @override
  Widget build(BuildContext context) => Container(
        decoration: BoxDecoration(
          color: AppColors.surface1,
          borderRadius: BorderRadius.circular(AppRadius.sm),
          border: Border.all(
            color: AppColors.textMuted.withValues(alpha: 0.12),
            width: 0.5,
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Container(
                decoration: BoxDecoration(
                  color: AppColors.surface2,
                  borderRadius: const BorderRadius.vertical(
                    top: Radius.circular(AppRadius.sm),
                  ),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.all(AppSpacing.md),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(height: 10, width: 90, color: AppColors.surface2),
                  const SizedBox(height: AppSpacing.sm),
                  Container(height: 10, width: 50, color: AppColors.surface2),
                ],
              ),
            ),
          ],
        ),
      );
}

/// What sits under the last card: the append spinner, the append failure with a
/// retry, or nothing.
///
/// The failure case is the one that matters. It keeps every loaded page on
/// screen and offers to fetch the page that failed again — an append error that
/// replaced the grid would throw away work the user already waited for.
class _GridFooter extends ConsumerWidget {
  const _GridFooter({required this.state});

  final CatalogProductsState state;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (state.appendError != null) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: AppSpacing.xl),
        child: Column(
          children: [
            Text(
              state.appendError!.message,
              textAlign: TextAlign.center,
              style: Theme.of(context)
                  .textTheme
                  .bodySmall
                  ?.copyWith(color: AppColors.textSecondary),
            ),
            const SizedBox(height: AppSpacing.sm),
            TextButton.icon(
              icon: const Icon(Icons.refresh, size: 16),
              label: const Text('Load more'),
              onPressed:
                  ref.read(catalogProductsProvider.notifier).retryAppend,
            ),
          ],
        ),
      );
    }

    if (state.isAppending) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: AppSpacing.xl),
        child: Center(
          child: SizedBox(
            width: 22,
            height: 22,
            child: CircularProgressIndicator(
              strokeWidth: 2,
              color: AppColors.textMuted,
            ),
          ),
        ),
      );
    }

    // Trailing room so the last row is not flush against the bottom edge, and
    // so a short second page still leaves something to scroll into.
    return const SizedBox(height: AppSpacing.xxxl);
  }
}
