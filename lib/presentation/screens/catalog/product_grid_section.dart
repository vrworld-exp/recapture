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
import 'package:flutter/scheduler.dart' show Ticker;
import 'package:flutter/services.dart' show HapticFeedback;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/theme/app_colors.dart';
import '../../../app/theme/app_spacing.dart';
import '../../../application/catalog/bulk_selection_notifier.dart';
import '../../../application/catalog/catalog_categories_notifier.dart';
import '../../../application/catalog/catalog_products_notifier.dart';
import '../../../data/repositories/catalog_failure.dart';
import '../../../domain/entities/catalog_product.dart';
import '../../../domain/entities/product_availability.dart';
import '../../../domain/entities/product_type.dart';
import '../../widgets/catalog/bulk_selection_bar.dart';
import '../../widgets/catalog/catalog_message.dart';
import '../../widgets/catalog/product_card.dart';
import '../../widgets/catalog/catalog_feedback.dart';

/// Opens one product's overflow menu, anchored at the card's own context.
typedef ProductMenuCallback = void Function(
  BuildContext anchor,
  CatalogProduct product,
);

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

/// Whether this width draws the handle at a touch-sized hit target.
///
/// The handle itself is drawn at EVERY width and is always the drag target.
/// Long-press-to-drag used to be the phone path, but on a phone long-press is
/// already how the grid enters bulk selection — the two gestures collided, so
/// on the narrow layout the cards could not be reordered at all and nothing on
/// screen said they were meant to be. One visible affordance, every width;
/// below phone width it is padded out to a finger-sized box.
bool productGridTouchHandle(double width) => width < 600;

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

  /// Opens a product's overflow menu (archive / restore / delete). Null hides
  /// the button rather than rendering one that opens nothing.
  ///
  /// The [BuildContext] is the CELL's, and it is the anchor: the menu opens over
  /// the card it belongs to, which on a five-column grid is the only way to see
  /// which product is about to be archived.
  final ProductMenuCallback? onProductMenu;

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
    if (metrics.pixels >=
        metrics.maxScrollExtent - kProductGridPrefetchExtent) {
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
        // What a select-all covered, and what a filter change just did to the
        // selection. Collapses to nothing when there is neither.
        const SliverToBoxAdapter(child: BulkSelectionNotice()),
        if (state.isLoading && state.items.isEmpty)
          const _SkeletonGrid()
        else if (state.error != null)
          SliverToBoxAdapter(
            child: CatalogMessage(
              icon: Icons.cloud_off_outlined,
              title: "We couldn't load your products",
              body: CatalogFeedback.failureText(state.error!),
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
    final categories = ref.watch(catalogCategoriesProvider).valueOrNull;

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

/// How near the viewport's top or bottom edge the finger has to be before the
/// grid starts scrolling itself during a drag.
const double _kAutoScrollEdge = 96;

/// Top speed of that auto-scroll, in logical pixels per second, reached at the
/// very edge and eased down to nothing at [_kAutoScrollEdge] away from it.
const double _kAutoScrollSpeed = 780;

/// How long a card takes to slide into the slot a drag just freed.
const Duration _kSlotShiftDuration = Duration(milliseconds: 190);

/// How long the picked-up card takes to fade back to the hole it left behind.
const Duration _kLiftDuration = Duration(milliseconds: 120);

class _ProductGrid extends ConsumerStatefulWidget {
  const _ProductGrid({
    required this.state,
    required this.onOpenProduct,
    this.onProductMenu,
  });

  final CatalogProductsState state;
  final ValueChanged<CatalogProduct> onOpenProduct;
  final ProductMenuCallback? onProductMenu;

  @override
  ConsumerState<_ProductGrid> createState() => _ProductGridState();
}

/// Owns the live reorder.
///
/// Flutter ships no reorderable GRID, so this is built from [Draggable] and
/// [DragTarget] directly — the same pair `ReorderableListView` is made of. What
/// this state adds on top of them is everything that made the raw pair unusable
/// in a scrolling grid:
///
///   • a PENDING order ([_from] → [_to]). The cards shuffle under the finger as
///     it moves, so the drop lands where the grid has been showing it would,
///     instead of the user aiming at an invisible slot and hoping.
///   • the DROP IS COMMITTED BY THE SOURCE, on `onDragEnd`, from that pending
///     order — never by a target's `onAccept`. A release over the 16px gutter
///     between two cards, over the header, or past the last row hits no target
///     at all, and every one of those used to be a silent no-op that looked
///     exactly like a broken feature.
///   • AUTO-SCROLL at the viewport edges, because a grid that cannot scroll
///     while dragging cannot move a card further than one screen — which is
///     most of what reordering a catalog is for.
///
/// Everything here is presentation. The order is only ever written through
/// `CatalogProductsNotifier.reorder`, which stays the single place that knows
/// about optimism, rollback and the server's index convention.
class _ProductGridState extends ConsumerState<_ProductGrid>
    with SingleTickerProviderStateMixin {
  /// Index in `widget.state.items` of the card being dragged. Null when idle.
  int? _from;

  /// The slot that card currently occupies on screen, and the slot it lands in
  /// if the finger lifts now.
  int? _to;

  /// Drives the edge auto-scroll. Created lazily and only ever once, which is
  /// what [SingleTickerProviderStateMixin] allows.
  Ticker? _ticker;
  Duration _lastTick = Duration.zero;
  double _scrollVelocity = 0;

  bool get _dragging => _from != null && _to != null;

  @override
  void dispose() {
    _ticker?.dispose();
    super.dispose();
  }

  // ── The order on screen ───────────────────────────────────────────────────

  /// `state.items` with the dragged card moved to the slot it is hovering.
  ///
  /// This is the ONLY list the grid builds from, so "what you see" and "what a
  /// release would write" cannot drift apart.
  List<CatalogProduct> get _visible {
    final items = widget.state.items;
    final from = _from;
    final to = _to;
    if (from == null || to == null || from == to) return items;
    if (from < 0 || from >= items.length || to < 0 || to >= items.length) {
      return items;
    }
    final moved = [...items];
    moved.insert(to, moved.removeAt(from));
    return moved;
  }

  // ── Drag lifecycle ────────────────────────────────────────────────────────

  void _onDragStarted(int index) {
    // A phone gives no cursor and no hover, so the buzz is the only signal that
    // the handle was actually caught. No-op on the web build.
    HapticFeedback.selectionClick();
    setState(() {
      _from = index;
      _to = index;
    });
  }

  /// The finger moved over the cell currently drawn at [slot].
  ///
  /// Stable by construction: after the shuffle the dragged card IS the cell at
  /// [slot], so the next move over the same place reports the same slot and
  /// nothing oscillates.
  void _onHover(int slot) {
    if (!_dragging || _to == slot) return;
    if (slot < 0 || slot >= widget.state.items.length) return;
    HapticFeedback.selectionClick();
    setState(() => _to = slot);
  }

  /// Applies the pending order. Called from the DRAGGABLE, so it runs on every
  /// release — including the ones that land on no target at all.
  void _onDragEnd() {
    final from = _from;
    final to = _to;
    _stopAutoScroll();

    // Written BEFORE the pending order is cleared: `reorder` applies its
    // optimistic list synchronously, so by the time this state drops back to
    // "not dragging" the notifier is already holding the order the grid has
    // been showing. Clearing first would flash one frame of the old order.
    if (from != null && to != null && from != to) {
      _move(context, ref, from: from, to: to);
    }

    setState(() {
      _from = null;
      _to = null;
    });
  }

  // ── Auto-scroll ───────────────────────────────────────────────────────────

  /// Reads the finger's position against the enclosing viewport and sets the
  /// scroll speed from it. Called on every drag update, so it also STOPS the
  /// scroll the moment the finger comes back inside.
  void _onDragUpdate(Offset globalPosition) {
    final scrollable = Scrollable.maybeOf(context);
    final box = scrollable?.context.findRenderObject();
    if (scrollable == null || box is! RenderBox || !box.hasSize) {
      _stopAutoScroll();
      return;
    }

    final top = box.localToGlobal(Offset.zero).dy;
    final bottom = top + box.size.height;

    double velocity = 0;
    if (globalPosition.dy < top + _kAutoScrollEdge) {
      final depth =
          (top + _kAutoScrollEdge - globalPosition.dy) / _kAutoScrollEdge;
      velocity = -_kAutoScrollSpeed * depth.clamp(0.0, 1.0);
    } else if (globalPosition.dy > bottom - _kAutoScrollEdge) {
      final depth =
          (globalPosition.dy - (bottom - _kAutoScrollEdge)) / _kAutoScrollEdge;
      velocity = _kAutoScrollSpeed * depth.clamp(0.0, 1.0);
    }

    _scrollVelocity = velocity;
    if (velocity == 0) {
      _ticker?.stop();
      return;
    }
    _ticker ??= createTicker(_tick);
    if (!_ticker!.isActive) {
      _lastTick = Duration.zero;
      _ticker!.start();
    }
  }

  void _tick(Duration elapsed) {
    final seconds = _lastTick == Duration.zero
        ? 0.0
        : (elapsed - _lastTick).inMicroseconds / Duration.microsecondsPerSecond;
    _lastTick = elapsed;
    if (seconds <= 0) return;

    final position = Scrollable.maybeOf(context)?.position;
    if (position == null ||
        !position.hasPixels ||
        !position.hasContentDimensions) {
      return;
    }

    // jumpTo rather than animateTo: this already runs once a frame at a speed
    // the finger is choosing, and an animation on top of it would fight it.
    // It also emits the scroll notification the shell turns into a next-page
    // fetch, so dragging to the bottom keeps loading rows to drop onto.
    final target = (position.pixels + _scrollVelocity * seconds)
        .clamp(position.minScrollExtent, position.maxScrollExtent);
    if (target != position.pixels) position.jumpTo(target);
  }

  void _stopAutoScroll() {
    _scrollVelocity = 0;
    _ticker?.stop();
  }

  // ── Selection ─────────────────────────────────────────────────────────────

  /// One card's primary activation.
  ///
  /// The whole click grammar of selection mode lives here, in one place, so the
  /// card stays pure presentation and the phone and browser gestures cannot
  /// drift apart:
  ///   • not selecting, plain tap        → open the product
  ///   • not selecting, Ctrl/Cmd+click   → ENTER selection with this product
  ///   • selecting, plain tap or click   → toggle
  ///   • selecting, Shift+click          → extend the range from the anchor
  ///
  /// Long-press (which the card routes to [_onSelectToggle]) enters selection on
  /// a phone, where there is no modifier to hold.
  void _onActivate(CatalogProduct product) {
    final selection = ref.read(bulkSelectionProvider);
    final notifier = ref.read(bulkSelectionProvider.notifier);

    if (!selection.isActive) {
      if (bulkAddModifierHeld()) {
        notifier.enter(product.id);
        return;
      }
      widget.onOpenProduct(product);
      return;
    }
    _onSelectToggle(product);
  }

  void _onSelectToggle(CatalogProduct product) {
    final notifier = ref.read(bulkSelectionProvider.notifier);
    if (bulkRangeModifierHeld()) {
      notifier.selectRangeTo(product.id);
      return;
    }
    notifier.toggle(product.id);
  }

  // ── Build ─────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final selection = ref.watch(bulkSelectionProvider);
    // Reordering is suspended while selecting: a drag that moved a card the
    // user meant to tick is not a reorder anyone asked for.
    final canReorder = widget.state.canReorder && !selection.isActive;
    final items = _visible;

    return SliverLayoutBuilder(
      builder: (context, constraints) {
        // SliverConstraints carries the cross-axis extent, which is the real
        // measured width of this grid — not the window's, not the screen's.
        final width = constraints.crossAxisExtent;
        final columns = productGridColumns(width);
        final cellWidth = (width - AppSpacing.md * (columns - 1)) / columns;
        final cellHeight = cellWidth + _kCardTextExtent;
        final touchHandle = productGridTouchHandle(width);
        // What one step across / down the grid measures, which is what a card
        // has to travel to slide into the slot beside it.
        final stride =
            Size(cellWidth + AppSpacing.md, cellHeight + AppSpacing.md);

        return SliverGrid(
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: columns,
            mainAxisSpacing: AppSpacing.md,
            crossAxisSpacing: AppSpacing.md,
            // Derived from the measured column width so the square image plus
            // its text block always fits — a fixed ratio overflows the moment
            // the text scale or the column count changes.
            childAspectRatio: cellWidth / cellHeight,
          ),
          delegate: SliverChildBuilderDelegate(
            (context, index) {
              final product = items[index];
              final isDragged = _dragging && index == _to;

              // The Builder is what gives the overflow menu something to anchor
              // to. A `SliverChildBuilderDelegate` hands its builder the
              // SLIVER's context, whose render object is the whole grid — a
              // menu positioned from that opens over the wrong product. This
              // context resolves to the cell's own box.
              return KeyedSubtree(
                key: ValueKey<String>(product.id),
                child: _SlotShift(
                  slot: index,
                  columns: columns,
                  stride: stride,
                  child: Builder(
                    builder: (cellContext) => _cell(
                      cellContext,
                      product: product,
                      slot: index,
                      canReorder: canReorder,
                      isDragged: isDragged,
                      selection: selection,
                      cellWidth: cellWidth,
                      touchHandle: touchHandle,
                    ),
                  ),
                ),
              );
            },
            childCount: items.length,
            // Keyed by product id so a shuffle MOVES the widgets it already
            // built rather than repainting a stale card into a new slot — and,
            // during a drag, so the Draggable under the finger keeps its
            // element and stays mounted while its slot changes underneath it.
            findChildIndexCallback: (key) {
              final id = (key as ValueKey<String>).value;
              final index = items.indexWhere((p) => p.id == id);
              return index == -1 ? null : index;
            },
          ),
        );
      },
    );
  }

  Widget _cell(
    BuildContext cellContext, {
    required CatalogProduct product,
    required int slot,
    required bool canReorder,
    required bool isDragged,
    required BulkSelectionState selection,
    required double cellWidth,
    required bool touchHandle,
  }) {
    final card = ProductCard(
      product: product,
      onTap: () => _onActivate(product),
      // Null while selecting: an overflow menu that archived ONE product from
      // inside a twenty-product selection is a second, contradictory answer to
      // the same question.
      onMore: widget.onProductMenu == null || selection.isActive
          ? null
          : () => widget.onProductMenu!(cellContext, product),
      // Null unless selecting, so the checkbox is absent rather than
      // present-and-unchecked on an ordinary grid.
      isSelected: selection.isActive ? selection.contains(product.id) : null,
      // Passed even when NOT selecting: this is what the card's long-press
      // routes to, and long-press is how a phone enters selection mode.
      onSelectedChanged: (_) => _onSelectToggle(product),
      // Drawn at every width: it is the ONLY way to start a reorder, so hiding
      // it on a phone left that layout with no reorder at all.
      dragHandle: canReorder
          ? _DragHandle(
              touch: touchHandle,
              // The card's CURRENT slot is where this drag starts from; the
              // slot moves as the finger does, the start does not.
              onDragStarted: () => _onDragStarted(slot),
              onDragUpdate: _onDragUpdate,
              onDragEnd: _onDragEnd,
              feedback: _DragFeedback(
                product: product,
                width: cellWidth.clamp(140.0, 240.0),
              ),
            )
          : null,
    );

    // The card being dragged reads as the HOLE it left behind: the feedback
    // under the finger is the product now, and two solid copies of the same
    // card is the thing that makes a drag look broken.
    //
    // ⚠ THE SHAPE OF THIS SUBTREE NEVER CHANGES, only its values. The drag
    // SOURCE lives inside `card`, and swapping a card for a placeholder widget
    // changes the element type at this position — which tears the Draggable
    // down mid-gesture and silently orphans the drop. Same reason the
    // decoration is always drawn and merely turns transparent.
    final body = AnimatedContainer(
      duration: _kLiftDuration,
      decoration: BoxDecoration(
        color: isDragged
            ? AppColors.mirageRed.withValues(alpha: 0.06)
            : Colors.transparent,
        borderRadius: BorderRadius.circular(AppRadius.sm),
        border: Border.all(
          color: isDragged
              ? AppColors.mirageRed.withValues(alpha: 0.55)
              : Colors.transparent,
          width: 1.5,
        ),
      ),
      child: AnimatedOpacity(
        duration: _kLiftDuration,
        opacity: isDragged ? 0.22 : 1,
        child: card,
      ),
    );

    // Drawn at every width, reorderable or not, so that entering bulk
    // selection does not nudge every card by the width of a border that only
    // one of the two modes draws.
    if (!canReorder) return body;

    // Every cell is a target, but only so the grid knows where the finger is —
    // the drop itself is committed by the source. `onWillAccept` is therefore
    // unconditionally true: refusing the card's own slot would make the cell
    // under the finger report nothing for the whole time it sits there.
    return DragTarget<int>(
      onWillAcceptWithDetails: (_) => true,
      onMove: (_) => _onHover(slot),
      builder: (_, __, ___) => body,
    );
  }
}

/// Slides a card from the slot it used to hold into the one it holds now.
///
/// The sliver re-lays a reordered child out INSTANTLY; without this the whole
/// grid would teleport on every hover change. Given the grid's own geometry the
/// distance is known exactly, so the card is drawn at its old position and
/// animates the difference away.
///
/// `transformHitTests: false` is deliberate: hit testing keeps using the
/// SETTLED slot, so the hover a drag reads is the grid's real layout rather
/// than a card still halfway through moving. That is what stops a dragged card
/// ping-ponging between two slots.
class _SlotShift extends StatefulWidget {
  const _SlotShift({
    required this.slot,
    required this.columns,
    required this.stride,
    required this.child,
  });

  final int slot;
  final int columns;
  final Size stride;
  final Widget child;

  @override
  State<_SlotShift> createState() => _SlotShiftState();
}

class _SlotShiftState extends State<_SlotShift>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: _kSlotShiftDuration,
  );
  late final Animation<double> _curve = CurvedAnimation(
    parent: _controller,
    curve: Curves.easeOutCubic,
  );

  /// Where this card was, relative to where it is now, at the start of the
  /// current animation. Zero when nothing is moving.
  Offset _offset = Offset.zero;

  Offset _origin(int slot) => Offset(
        (slot % widget.columns) * widget.stride.width,
        (slot ~/ widget.columns) * widget.stride.height,
      );

  @override
  void didUpdateWidget(covariant _SlotShift oldWidget) {
    super.didUpdateWidget(oldWidget);
    // A column-count change is a relayout, not a move: animating across it
    // would fling every card from a geometry that no longer exists.
    if (oldWidget.slot == widget.slot || oldWidget.columns != widget.columns) {
      return;
    }
    // Pick up from wherever the previous animation had got to, so a fast drag
    // across several slots is one continuous slide rather than a series of
    // restarts.
    final current = _offset * (1 - _curve.value);
    _offset = current + (_origin(oldWidget.slot) - _origin(widget.slot));
    _controller.forward(from: 0);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
        animation: _curve,
        child: widget.child,
        // The Transform is ALWAYS in the tree, even at zero. Returning the
        // bare child while idle and a Transform while moving swaps the widget
        // type at this position every time a card starts or stops sliding —
        // which rebuilds the whole card below it from scratch and, mid-drag,
        // throws away the very Draggable that is driving the gesture.
        builder: (context, child) => Transform.translate(
          offset: _offset * (1 - _curve.value),
          transformHitTests: false,
          child: child,
        ),
      );
}

/// Moves a card and reports the outcome.
///
/// The notifier speaks `ReorderableListView`'s index convention (the target
/// counted BEFORE the dragged item is removed), so a "drop into slot [to]"
/// gesture is translated once, here, rather than at every call site.
Future<void> _move(
  BuildContext context,
  WidgetRef ref, {
  required int from,
  required int to,
}) async {
  final messenger = CatalogFeedback.of(context);
  try {
    await ref
        .read(catalogProductsProvider.notifier)
        .reorder(from, to > from ? to + 1 : to);
  } on CatalogFailure catch (failure) {
    // The grid has already snapped back — say why, or the card looks as though
    // it refused the drag for no reason. One subject naming what failed, then
    // the mapped sentence for the code (ID_SET_MISMATCH asks for a refresh).
    CatalogFeedback.failure(
      messenger,
      failure,
      subject: 'Your products are back in their previous order',
    );
  }
}

/// The reorder handle. It is the drag source, not a decoration.
///
/// `Draggable` (immediate drag, no long-press) is deliberate: it is the same
/// recogniser `ReorderableDragStartListener` uses, so it wins the arena against
/// the surrounding scroll view on touch and against a mouse drag on the web —
/// one implementation for both.
///
/// It is drawn as a filled chip rather than a bare glyph because it is the only
/// way into the feature: an 18px icon between a two-line product name and an
/// overflow button reads as punctuation, and on a phone it was too small to
/// catch reliably even once found.
class _DragHandle extends StatelessWidget {
  const _DragHandle({
    required this.touch,
    required this.feedback,
    required this.onDragStarted,
    required this.onDragUpdate,
    required this.onDragEnd,
  });

  /// Narrow layout: pad the icon out to a finger-sized box. An 18px icon is a
  /// fine mouse target and an unhittable touch one.
  final bool touch;

  final _DragFeedback feedback;
  final VoidCallback onDragStarted;
  final ValueChanged<Offset> onDragUpdate;
  final VoidCallback onDragEnd;

  @override
  Widget build(BuildContext context) {
    final size = touch ? 36.0 : 30.0;

    return Draggable<int>(
      data: 0,
      feedback: feedback,
      // The feedback is a card, not the glyph that was grabbed, so it is
      // centred on the finger instead of hanging off wherever inside a 36px
      // box the finger happened to land.
      dragAnchorStrategy: (_, __, ___) => feedback.anchor,
      onDragStarted: onDragStarted,
      onDragUpdate: (details) => onDragUpdate(details.globalPosition),
      // Both endings, one path. `onDragEnd` fires whether or not a target
      // accepted, which is exactly why the drop is committed from here.
      onDragEnd: (_) => onDragEnd(),
      child: MouseRegion(
        cursor: SystemMouseCursors.grab,
        // No Tooltip: on touch the tooltip's trigger IS a long-press, so
        // pressing the handle to start a drag popped "Drag to reorder" over
        // the grid mid-gesture. How to drag is taught outside the widget.
        child: SizedBox(
          width: size,
          height: size,
          child: Center(
            child: Container(
              width: size - 6,
              height: size - 6,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: AppColors.surface2,
                borderRadius: BorderRadius.circular(AppRadius.xs),
                border: Border.all(
                  color: AppColors.royalGold.withValues(alpha: 0.25),
                  width: 0.5,
                ),
              ),
              child: Icon(
                Icons.drag_indicator,
                size: touch ? 18 : 16,
                color: AppColors.textSecondary,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// What follows the finger: the card itself, lifted.
///
/// A 22px glyph told the user a drag was happening but not WHAT was being
/// dragged, which on a five-column grid of similar thumbnails is the only
/// question that matters.
class _DragFeedback extends StatelessWidget {
  const _DragFeedback({required this.product, required this.width});

  final CatalogProduct product;
  final double width;

  /// Where inside this feedback the finger sits — its middle. Read by the
  /// draggable's anchor strategy, so the number comes from the same card
  /// geometry the grid lays out with rather than being guessed.
  Offset get anchor => Offset(width / 2, (width + _kCardTextExtent) / 2);

  @override
  Widget build(BuildContext context) => Material(
        type: MaterialType.transparency,
        child: Opacity(
          opacity: 0.94,
          child: SizedBox(
            width: width,
            child: DecoratedBox(
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(AppRadius.sm),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.45),
                    blurRadius: 24,
                    offset: const Offset(0, 10),
                  ),
                ],
              ),
              // No callbacks: the feedback is a picture of the card, and the
              // card renders itself inert when it has nothing to call.
              child: ProductCard(product: product),
            ),
          ),
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
              CatalogFeedback.failureText(state.appendError!),
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
              onPressed: ref.read(catalogProductsProvider.notifier).retryAppend,
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
