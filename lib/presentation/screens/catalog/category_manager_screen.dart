// lib/presentation/screens/catalog/category_manager_screen.dart
//
// The category manager (features 22-26): create, rename, delete with
// reassignment, drag-reorder, and moving products between categories.
//
// Categories are NOT optional here, which is why this screen exists at all:
// Mirage's create-item requires a real category id, so every publishable
// product needs one, and the Uncategorized bucket is materialised server-side at
// publish. What the user arranges here is what customers see, in this order.
//
// Two shapes from one widget tree, decided from the CONSTRAINTS: master/detail
// side by side when there is room, and a list that pushes to its sublist when
// there is not. Never `kIsWeb` — a narrow browser window is the phone shape.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/routes/flow_back.dart';
import '../../../app/theme/app_colors.dart';
import '../../../app/theme/app_spacing.dart';
import '../../../application/catalog/catalog_categories_notifier.dart';
import '../../../application/catalog/category_candidates_notifier.dart';
import '../../../application/catalog/category_products_notifier.dart';
import '../../../data/repositories/catalog_failure.dart';
import '../../../domain/entities/catalog_category.dart';
import '../../../domain/entities/catalog_product.dart';
import '../../../domain/entities/product_type.dart';
import '../../widgets/app_button.dart';
import '../../widgets/app_loading_indicator.dart';
import '../../widgets/app_text_field.dart';
import '../../widgets/catalog/catalog_feedback.dart';
import '../../widgets/catalog/catalog_message.dart';

/// Width at or above which the manager splits into master and detail.
///
/// Below it the same content is two screens instead of two panes. Measured, not
/// platform-sniffed.
const double kCategoryMasterDetailWidth = 900;

/// Which bucket the detail pane is showing.
///
/// A nullable `String` cannot express this: null would have to mean both "the
/// Uncategorized bucket" and "nothing selected", and those are different screens.
@immutable
class CategorySelection {
  const CategorySelection.category(String this.id);
  const CategorySelection.uncategorized() : id = null;

  /// The category's id, or null for the Uncategorized bucket.
  final String? id;

  bool get isUncategorized => id == null;

  @override
  bool operator ==(Object other) =>
      other is CategorySelection && other.id == id;

  @override
  int get hashCode => id.hashCode;
}

/// The category manager screen.
class CategoryManagerScreen extends ConsumerStatefulWidget {
  const CategoryManagerScreen({super.key});

  @override
  ConsumerState<CategoryManagerScreen> createState() =>
      _CategoryManagerScreenState();
}

class _CategoryManagerScreenState extends ConsumerState<CategoryManagerScreen> {
  /// The detail pane's subject on wide layouts. Null until the user picks one.
  CategorySelection? _selected;

  /// The category whose row is currently an editable field. One at a time —
  /// two half-renamed rows is a state with no correct outcome.
  String? _editingId;

  void _openSelection(CategorySelection selection, {required bool wide}) {
    if (wide) {
      setState(() => _selected = selection);
      return;
    }
    // Narrow: the sublist is a page, not a pane. A local push rather than a
    // route, because it is a view OF this screen's state — it has no meaning
    // deep-linked, and reloading a browser on it should land back here.
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => _CategoryProductsPage(selection: selection),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final async = ref.watch(catalogCategoriesProvider);

    return Scaffold(
      backgroundColor: AppColors.bgPrimary,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          tooltip: 'Back',
          onPressed: () => navigateBack(context),
        ),
        title:
            Text('Categories', style: Theme.of(context).textTheme.titleLarge),
      ),
      body: SafeArea(
        child: async.when(
          loading: () => const Center(child: AppLoadingIndicator()),
          error: (error, _) => CatalogMessage(
            icon: Icons.cloud_off_outlined,
            title: "We couldn't load your categories",
            body: error is CatalogFailure
                ? CatalogFeedback.failureText(error)
                : CatalogFeedback.textForCode(null),
            actionLabel: 'Try again',
            onAction: () =>
                ref.read(catalogCategoriesProvider.notifier).refresh(),
          ),
          data: (list) => LayoutBuilder(
            builder: (context, constraints) {
              final wide = constraints.maxWidth >= kCategoryMasterDetailWidth;

              final master = _CategoryList(
                list: list,
                selected: wide ? _selected : null,
                editingId: _editingId,
                onEdit: (id) => setState(() => _editingId = id),
                onOpen: (selection) =>
                    _openSelection(selection, wide: wide),
              );

              if (!wide) return master;

              return Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  SizedBox(width: 380, child: master),
                  const VerticalDivider(width: 1, color: AppColors.surface2),
                  Expanded(
                    child: _selected == null
                        ? const _NoSelection()
                        : _CategoryProductsPane(
                            key: ValueKey(_selected!.id ?? '__uncategorized__'),
                            selection: _selected!,
                          ),
                  ),
                ],
              );
            },
          ),
        ),
      ),
    );
  }
}

// ── Master: the category list ───────────────────────────────────────────────

class _CategoryList extends ConsumerWidget {
  const _CategoryList({
    required this.list,
    required this.selected,
    required this.editingId,
    required this.onEdit,
    required this.onOpen,
  });

  final CatalogCategoryList list;
  final CategorySelection? selected;
  final String? editingId;
  final ValueChanged<String?> onEdit;
  final ValueChanged<CategorySelection> onOpen;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final categories = list.categories;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Padding(
          padding: EdgeInsets.all(AppSpacing.screenPadding),
          child: _CreateCategoryField(),
        ),
        Expanded(
          child: categories.isEmpty
              ? const _NoCategoriesYet()
              : ReorderableListView.builder(
                  padding: const EdgeInsets.symmetric(
                    horizontal: AppSpacing.screenPadding,
                  ),
                  // Handles are drawn by the rows themselves, so ONE affordance
                  // serves touch drag, mouse drag and the keyboard hint.
                  buildDefaultDragHandles: false,
                  itemCount: categories.length,
                  onReorder: (oldIndex, newIndex) =>
                      _reorder(context, ref, oldIndex, newIndex),
                  itemBuilder: (context, index) {
                    final category = categories[index];
                    return _CategoryRow(
                      key: ValueKey(category.id),
                      category: category,
                      index: index,
                      count: categories.length,
                      isSelected: selected?.id == category.id,
                      isEditing: editingId == category.id,
                      onEdit: onEdit,
                      onOpen: () =>
                          onOpen(CategorySelection.category(category.id)),
                    );
                  },
                ),
        ),
        // Always present, always last, never draggable, never renameable.
        // Uncategorized is the ABSENCE of a category — a null `categoryId` — and
        // giving it a row that behaved like the others would be inviting the
        // user to rename something that does not exist.
        Padding(
          padding: const EdgeInsets.fromLTRB(
            AppSpacing.screenPadding,
            AppSpacing.sm,
            AppSpacing.screenPadding,
            0,
          ),
          child: _UncategorizedRow(
            count: list.uncategorizedCount,
            isSelected: selected?.isUncategorized ?? false,
            onOpen: () => onOpen(const CategorySelection.uncategorized()),
          ),
        ),
        Padding(
          padding: const EdgeInsets.all(AppSpacing.screenPadding),
          child: Text(
            'Your public catalog shows categories in this order.',
            style: Theme.of(context)
                .textTheme
                .bodySmall
                ?.copyWith(color: AppColors.textMuted),
          ),
        ),
      ],
    );
  }

  static Future<void> _reorder(
    BuildContext context,
    WidgetRef ref,
    int oldIndex,
    int newIndex,
  ) async {
    // Captured while the context is certainly mounted. An undo fires seconds
    // later and this screen is a pushed route the user can leave in that time —
    // a container survives it, a ref does not.
    final messenger = CatalogFeedback.of(context);
    final container = ProviderScope.containerOf(context, listen: false);
    final name = container
        .read(catalogCategoriesProvider)
        .valueOrNull
        ?.categories
        .elementAtOrNull(oldIndex)
        ?.name;
    await _writeOrder(messenger, container, oldIndex, newIndex, name: name);
  }

  /// One drag, written to the server, confirmed, and offered back.
  ///
  /// [undoable] is false for the undo's OWN write, so pressing undo twice does
  /// not become a way to walk the list back and forth forever.
  static Future<void> _writeOrder(
    ScaffoldMessengerState messenger,
    ProviderContainer container,
    int oldIndex,
    int newIndex, {
    String? name,
    bool undoable = true,
  }) async {
    try {
      final landed = await container
          .read(catalogCategoriesProvider.notifier)
          .reorder(oldIndex, newIndex);
      // Nothing moved — a drag that ended where it started. Confirming it would
      // be a message about an event that did not happen.
      if (landed == null) return;

      final subject = name == null ? 'Category order saved.' : '$name moved.';
      if (!undoable) {
        CatalogFeedback.confirm(messenger, subject);
        return;
      }
      CatalogFeedback.undoable(
        messenger,
        '$subject Customers see the new order after you publish.',
        // The REAL inverse: the row is dragged back from where it LANDED to
        // where it came from, and that write goes to the server like any other.
        // `oldIndex + 1` when moving down is the ReorderableListView
        // convention — the target is counted before the row is lifted out.
        onUndo: () => _writeOrder(
          messenger,
          container,
          landed,
          oldIndex > landed ? oldIndex + 1 : oldIndex,
          name: name,
          undoable: false,
        ),
      );
    } on CatalogFailure catch (failure) {
      // The list has already snapped back and re-read itself. Say why, or the
      // row looks as though it refused the drag for no reason.
      CatalogFeedback.failure(
        messenger,
        failure,
        subject: 'That order could not be saved',
      );
    }
  }
}

/// The inline create field (feature 22).
class _CreateCategoryField extends ConsumerStatefulWidget {
  const _CreateCategoryField();

  @override
  ConsumerState<_CreateCategoryField> createState() =>
      _CreateCategoryFieldState();
}

class _CreateCategoryFieldState extends ConsumerState<_CreateCategoryField> {
  final TextEditingController _controller = TextEditingController();
  String? _error;
  bool _busy = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final name = _controller.text.trim();
    if (name.isEmpty) {
      setState(() => _error = 'Give the category a name.');
      return;
    }
    if (name.length > kMaxCategoryNameLength) {
      setState(() => _error =
          'Category names can be at most $kMaxCategoryNameLength characters.');
      return;
    }

    setState(() {
      _busy = true;
      _error = null;
    });
    final messenger = CatalogFeedback.of(context);
    try {
      final created =
          await ref.read(catalogCategoriesProvider.notifier).create(name);
      if (!mounted) return;
      _controller.clear();
      CatalogFeedback.confirm(messenger, '${created.name} added.');
    } on CatalogFailure catch (failure) {
      // A duplicate name is the SERVER's verdict — it owns uniqueness within the
      // catalog — so the sentence for its code lands beside the field the user
      // typed in rather than in a toast they have to remember.
      if (!mounted) return;
      setState(() => _error = CatalogFeedback.failureText(failure));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: AppTextField(
              label: 'New category',
              hint: 'Starters, Chairs, Desserts…',
              controller: _controller,
              enabled: !_busy,
              errorText: _error,
              maxLength: kMaxCategoryNameLength,
              textInputAction: TextInputAction.done,
              onFieldSubmitted: (_) => _submit(),
              onChanged: (_) {
                if (_error != null) setState(() => _error = null);
              },
            ),
          ),
          const SizedBox(width: AppSpacing.md),
          // Top-aligned, NOT offset. The field's input box and the button are
          // both 48 high, so `start` lands them on the same line — and when an
          // error message appears the field grows DOWNWARD, which is the only
          // alignment that keeps the button on the row the user is typing in.
          AppButton(
            label: 'Add',
            isFullWidth: false,
            isLoading: _busy,
            onPressed: _submit,
          ),
        ],
      );
}

/// One category row: drag handle, name (or the inline rename field), count,
/// and the overflow menu.
class _CategoryRow extends ConsumerWidget {
  const _CategoryRow({
    super.key,
    required this.category,
    required this.index,
    required this.count,
    required this.isSelected,
    required this.isEditing,
    required this.onEdit,
    required this.onOpen,
  });

  final CatalogCategory category;
  final int index;
  final int count;
  final bool isSelected;
  final bool isEditing;
  final ValueChanged<String?> onEdit;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);

    if (isEditing) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: AppSpacing.xs),
        child: _RenameField(
          category: category,
          onDone: () => onEdit(null),
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: AppSpacing.xs),
      child: CallbackShortcuts(
        // Keyboard reorder (Alt + arrows). Drag-only is inaccessible on a
        // desktop, and this is the same call the drag makes — one code path,
        // one set of rollbacks.
        bindings: {
          const SingleActivator(LogicalKeyboardKey.arrowUp, alt: true): () {
            if (index > 0) _keyboardMove(context, ref, index, index - 1);
          },
          const SingleActivator(LogicalKeyboardKey.arrowDown, alt: true): () {
            if (index < count - 1) _keyboardMove(context, ref, index, index + 2);
          },
        },
        child: Material(
          type: MaterialType.transparency,
          child: InkWell(
            borderRadius: BorderRadius.circular(AppRadius.xs),
            hoverColor: AppColors.surface2,
            focusColor: AppColors.surface2,
            onTap: onOpen,
            child: Container(
              padding: const EdgeInsets.symmetric(
                horizontal: AppSpacing.md,
                vertical: AppSpacing.md,
              ),
              decoration: BoxDecoration(
                color: isSelected ? AppColors.surface2 : AppColors.surface1,
                borderRadius: BorderRadius.circular(AppRadius.xs),
                border: Border.all(
                  color: isSelected
                      ? AppColors.mirageRed.withValues(alpha: 0.6)
                      : AppColors.textMuted.withValues(alpha: 0.2),
                  width: 0.5,
                ),
              ),
              child: Row(
                children: [
                  // ReorderableDragStartListener works for touch AND mouse, so
                  // the web build's drag needs no second implementation.
                  ReorderableDragStartListener(
                    index: index,
                    child: const MouseRegion(
                      cursor: SystemMouseCursors.grab,
                      child: Tooltip(
                        message: 'Drag to reorder (or Alt + ↑ / ↓)',
                        child: Icon(
                          Icons.drag_indicator,
                          size: 18,
                          color: AppColors.textMuted,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: AppSpacing.md),
                  Expanded(
                    child: Text(
                      category.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodyLarge,
                    ),
                  ),
                  Text(
                    _countLabel(category.productCount),
                    style: theme.textTheme.bodySmall
                        ?.copyWith(color: AppColors.textMuted),
                  ),
                  _CategoryRowMenu(
                    category: category,
                    onRename: () => onEdit(category.id),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  static Future<void> _keyboardMove(
    BuildContext context,
    WidgetRef ref,
    int from,
    int to,
  ) =>
      _CategoryList._reorder(context, ref, from, to);
}

/// Rename in place (feature 23).
class _RenameField extends ConsumerStatefulWidget {
  const _RenameField({required this.category, required this.onDone});

  final CatalogCategory category;
  final VoidCallback onDone;

  @override
  ConsumerState<_RenameField> createState() => _RenameFieldState();
}

class _RenameFieldState extends ConsumerState<_RenameField> {
  late final TextEditingController _controller =
      TextEditingController(text: widget.category.name);
  String? _error;
  bool _busy = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final name = _controller.text.trim();
    if (name == widget.category.name) {
      widget.onDone();
      return;
    }
    if (name.isEmpty) {
      setState(() => _error = 'Give the category a name.');
      return;
    }
    if (name.length > kMaxCategoryNameLength) {
      setState(() => _error =
          'Category names can be at most $kMaxCategoryNameLength characters.');
      return;
    }

    setState(() {
      _busy = true;
      _error = null;
    });
    final messenger = CatalogFeedback.of(context);
    try {
      await ref
          .read(catalogCategoriesProvider.notifier)
          .rename(widget.category.id, name);
      if (!mounted) return;
      // Renaming a category that is already live on Mirage is allowed; the
      // change goes out with the next publish like every other draft edit.
      CatalogFeedback.confirm(
        messenger,
        'Renamed to $name. Customers see it after you publish.',
      );
      widget.onDone();
    } on CatalogFailure catch (failure) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = CatalogFeedback.failureText(failure);
      });
    }
  }

  @override
  Widget build(BuildContext context) => CallbackShortcuts(
        bindings: {
          const SingleActivator(LogicalKeyboardKey.escape): widget.onDone,
        },
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: AppTextField(
                label: 'Category name',
                controller: _controller,
                autofocus: true,
                enabled: !_busy,
                errorText: _error,
                maxLength: kMaxCategoryNameLength,
                textInputAction: TextInputAction.done,
                onFieldSubmitted: (_) => _submit(),
              ),
            ),
            const SizedBox(width: AppSpacing.sm),
            // Aligned with the field's input box, for the reason spelled out on
            // the create row above.
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextButton(
                  onPressed: _busy ? null : widget.onDone,
                  child: const Text('Cancel'),
                ),
                AppButton(
                  label: 'Save',
                  isFullWidth: false,
                  isLoading: _busy,
                  onPressed: _submit,
                ),
              ],
            ),
          ],
        ),
      );
}

class _CategoryRowMenu extends ConsumerWidget {
  const _CategoryRowMenu({required this.category, required this.onRename});

  final CatalogCategory category;
  final VoidCallback onRename;

  @override
  Widget build(BuildContext context, WidgetRef ref) => PopupMenuButton<String>(
        tooltip: 'Category options',
        color: AppColors.surface1,
        icon: const Icon(
          Icons.more_vert,
          size: 18,
          color: AppColors.textSecondary,
        ),
        itemBuilder: (_) => [
          const PopupMenuItem(value: 'rename', child: Text('Rename')),
          PopupMenuItem(
            value: 'delete',
            child: Text(
              'Delete',
              style: TextStyle(color: AppColors.error),
            ),
          ),
        ],
        onSelected: (value) {
          if (value == 'rename') {
            onRename();
          } else {
            showDeleteCategoryDialog(context, category);
          }
        },
      );
}

/// The Uncategorized bucket (feature 26).
class _UncategorizedRow extends StatelessWidget {
  const _UncategorizedRow({
    required this.count,
    required this.isSelected,
    required this.onOpen,
  });

  final int count;
  final bool isSelected;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Material(
      type: MaterialType.transparency,
      child: InkWell(
        borderRadius: BorderRadius.circular(AppRadius.xs),
        hoverColor: AppColors.surface2,
        focusColor: AppColors.surface2,
        onTap: onOpen,
        child: Container(
          padding: const EdgeInsets.symmetric(
            horizontal: AppSpacing.md,
            vertical: AppSpacing.md,
          ),
          decoration: BoxDecoration(
            color: isSelected ? AppColors.surface2 : Colors.transparent,
            borderRadius: BorderRadius.circular(AppRadius.xs),
            border: Border.all(
              color: AppColors.textMuted.withValues(alpha: 0.2),
              width: 0.5,
            ),
          ),
          child: Row(
            children: [
              const SizedBox(width: 18 + AppSpacing.md), // aligns with handles
              Expanded(
                child: Text(
                  'Uncategorized',
                  style: theme.textTheme.bodyLarge
                      ?.copyWith(color: AppColors.textSecondary),
                ),
              ),
              Text(
                _countLabel(count),
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: AppColors.textMuted),
              ),
              const SizedBox(width: AppSpacing.sm),
              const Tooltip(
                message: 'Always last, and cannot be renamed or deleted',
                child: Icon(Icons.lock_outline,
                    size: 14, color: AppColors.textMuted),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _NoCategoriesYet extends StatelessWidget {
  const _NoCategoriesYet();

  // `fillsViewport` stays true (the default): this block sits in an `Expanded`,
  // which hands it a TIGHT height, and the block is a 96px circle plus four
  // stacked text runs. On a short viewport — or any viewport at a large text
  // scale — its natural height is bigger than the slot, and an unscrollable
  // Column in a tight slot is an overflow, not a smaller layout. Filling the
  // viewport wraps it in the scroll view that makes the overflow impossible,
  // and still centres it whenever there is room.
  @override
  Widget build(BuildContext context) => const CatalogMessage(
        icon: Icons.category_outlined,
        title: 'No categories yet',
        body: 'Group your products so customers can find them. Every product '
            'needs a category before it can go live.',
      );
}

class _NoSelection extends StatelessWidget {
  const _NoSelection();

  @override
  Widget build(BuildContext context) => const CatalogMessage(
        icon: Icons.touch_app_outlined,
        title: 'Pick a category',
        body: 'Choose one on the left to see what is in it and move products '
            'between groups.',
      );
}

String _countLabel(int count) => count == 1 ? '1 product' : '$count products';

// ── Delete with reassignment (feature 24) ───────────────────────────────────

/// Confirms and performs a category delete.
///
/// A non-empty category ALWAYS tells the user where its products go before it
/// happens, and lets them choose: Uncategorized (what the server does on its
/// own) or another category (a bulk move first, then the delete). Deleting a
/// grouping must never look like it deleted the things inside it.
Future<void> showDeleteCategoryDialog(
  BuildContext context,
  CatalogCategory category,
) async {
  final messenger = CatalogFeedback.of(context);
  final container = ProviderScope.containerOf(context, listen: false);
  final others = [
    for (final other
        in container.read(catalogCategoriesProvider).valueOrNull?.categories ??
            const <CatalogCategory>[])
      if (other.id != category.id) other,
  ];

  final destination = await showDialog<_DeleteChoice>(
    context: context,
    barrierColor: AppColors.scrim,
    builder: (_) => _DeleteCategoryDialog(category: category, others: others),
  );
  if (destination == null) return;

  try {
    var moved = 0;
    if (destination.categoryId != null) {
      // Reassignment is a client-side move THEN the delete: the endpoint has
      // exactly one behaviour (everything to Uncategorized), so a destination
      // has to be honoured before the category stops existing.
      moved = await _moveEveryProduct(
        container,
        from: category.id,
        to: destination.categoryId,
      );
      await container.read(catalogCategoriesProvider.notifier)
          .delete(category.id);
    } else {
      moved = await container
          .read(catalogCategoriesProvider.notifier)
          .delete(category.id);
    }

    CatalogFeedback.confirm(
      messenger,
      moved == 0
          ? '${category.name} deleted.'
          : '${category.name} deleted. '
              '${_countLabel(moved)} moved to ${destination.label}.',
    );
  } on CatalogFailure catch (failure) {
    CatalogFeedback.failure(
      messenger,
      failure,
      subject: '${category.name} could not be deleted',
    );
  }
}

/// Moves every product out of [from] and into [to].
///
/// Archived products included — they are still in the category, and leaving
/// them behind would put them in Uncategorized instead of where the user said.
///
/// The drain lives in the notifier rather than here because it must not be
/// bounded by what a pane can display: selecting the loaded products and moving
/// the selection would strand everything past [kCategoryProductsMax] for the
/// delete to sweep into Uncategorized.
///
/// The provider is pinned for the duration. It is `autoDispose`, and this runs
/// from the row menu on a narrow layout where no pane is watching it — a
/// `read` alone leaves the notifier collectable part-way through its own drain.
Future<int> _moveEveryProduct(
  ProviderContainer container, {
  required String from,
  required String? to,
}) async {
  final provider = categoryProductsProvider(from);
  final pin = container.listen<CategoryProductsState>(provider, (_, __) {});
  try {
    return await container.read(provider.notifier).moveAllTo(to);
  } finally {
    pin.close();
  }
}

/// Where a deleted category's products land.
@immutable
class _DeleteChoice {
  const _DeleteChoice({required this.categoryId, required this.label});

  /// Null = the Uncategorized bucket, which is what the server does unaided.
  final String? categoryId;
  final String label;
}

class _DeleteCategoryDialog extends StatefulWidget {
  const _DeleteCategoryDialog({required this.category, required this.others});

  final CatalogCategory category;
  final List<CatalogCategory> others;

  @override
  State<_DeleteCategoryDialog> createState() => _DeleteCategoryDialogState();
}

class _DeleteCategoryDialogState extends State<_DeleteCategoryDialog> {
  /// Null = Uncategorized, and it is the default because it is the outcome that
  /// needs no extra work and loses nothing.
  String? _destinationId;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final count = widget.category.productCount;
    final empty = count == 0;

    return AlertDialog(
      backgroundColor: AppColors.surface1,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppRadius.md),
      ),
      title: Text('Delete ${widget.category.name}?',
          style: theme.textTheme.titleLarge),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              empty
                  ? 'This category is empty. Deleting it changes nothing else.'
                  : 'The ${_countLabel(count)} in this category will move — '
                      'nothing is deleted with it. Choose where they go.',
              style: theme.textTheme.bodyMedium
                  ?.copyWith(color: AppColors.textSecondary, height: 1.4),
            ),
            if (!empty) ...[
              const SizedBox(height: AppSpacing.lg),
              _DestinationTile(
                label: 'Uncategorized',
                selected: _destinationId == null,
                onTap: () => setState(() => _destinationId = null),
              ),
              for (final other in widget.others)
                _DestinationTile(
                  label: other.name,
                  selected: _destinationId == other.id,
                  onTap: () => setState(() => _destinationId = other.id),
                ),
              const SizedBox(height: AppSpacing.md),
              Text(
                'Archived products in this category move too.',
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: AppColors.textMuted),
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text(
            'Cancel',
            style: TextStyle(color: AppColors.textSecondary),
          ),
        ),
        TextButton(
          style: TextButton.styleFrom(foregroundColor: AppColors.error),
          onPressed: () => Navigator.of(context).pop(
            _DeleteChoice(
              categoryId: _destinationId,
              label: _destinationId == null
                  ? 'Uncategorized'
                  : widget.others
                      .firstWhere((c) => c.id == _destinationId)
                      .name,
            ),
          ),
          child: Text(empty ? 'Delete' : 'Move and delete'),
        ),
      ],
    );
  }
}

class _DestinationTile extends StatelessWidget {
  const _DestinationTile({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  // Hand-built rather than a `RadioListTile`: Material's radio now wants a
  // `RadioGroup` ancestor, and a two-option picker inside a dialog does not
  // need one. The affordance is the icon; the whole row is the target.
  @override
  Widget build(BuildContext context) => Material(
        type: MaterialType.transparency,
        child: InkWell(
          borderRadius: BorderRadius.circular(AppRadius.xs),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: AppSpacing.sm),
            child: Row(
              children: [
                Icon(
                  selected
                      ? Icons.radio_button_checked
                      : Icons.radio_button_unchecked,
                  size: 18,
                  color:
                      selected ? AppColors.mirageRed : AppColors.textMuted,
                ),
                const SizedBox(width: AppSpacing.md),
                Expanded(
                  child: Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.bodyMedium,
                  ),
                ),
              ],
            ),
          ),
        ),
      );
}

// ── Detail: one category's products ─────────────────────────────────────────

/// The narrow-layout page wrapper around [_CategoryProductsPane].
class _CategoryProductsPage extends ConsumerWidget {
  const _CategoryProductsPage({required this.selection});

  final CategorySelection selection;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final name = selection.isUncategorized
        ? 'Uncategorized'
        : ref.watch(categoryNameProvider(selection.id)) ?? 'Category';

    return Scaffold(
      backgroundColor: AppColors.bgPrimary,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        title: Text(name, style: Theme.of(context).textTheme.titleLarge),
      ),
      body: SafeArea(child: _CategoryProductsPane(selection: selection)),
    );
  }
}

/// The products in one category, with multi-select and "Move to…".
class _CategoryProductsPane extends ConsumerWidget {
  const _CategoryProductsPane({super.key, required this.selection});

  final CategorySelection selection;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final provider = categoryProductsProvider(selection.id);
    final state = ref.watch(provider);
    final notifier = ref.read(provider.notifier);

    if (state.isLoading && state.items.isEmpty) {
      return const Center(child: AppLoadingIndicator());
    }
    if (state.error != null && state.items.isEmpty) {
      return CatalogMessage(
        icon: Icons.cloud_off_outlined,
        title: "We couldn't load these products",
        body: CatalogFeedback.failureText(state.error!),
        actionLabel: 'Try again',
        onAction: notifier.load,
      );
    }
    if (state.isEmpty) {
      // Fills the viewport for the same reason [_NoCategoriesYet] does: this is
      // the whole pane, not a block inside something that already scrolls.
      //
      // A category the user has just created lands HERE, empty, so this is
      // where the way to fill it belongs. An empty pane whose only advice is
      // "do it from somewhere else" is a dead end at exactly the moment the
      // user has decided what the category is for.
      final destination = selection.id;
      return CatalogMessage(
        icon: Icons.inventory_2_outlined,
        title: 'Nothing in here yet',
        body: selection.isUncategorized
            // No CTA on the bucket, and no promise of one: "adding" a product
            // to Uncategorized is REMOVING its category, which is Move to… on
            // the category the product is actually in.
            ? 'Every product has a category. That is what you want before you '
                'publish.'
            : 'Add products from your catalog, or set this category on the '
                'product itself.',
        actionLabel: destination == null ? null : 'Add products',
        onAction: destination == null
            ? null
            : () => _addProducts(context, destination),
      );
    }

    return Column(
      children: [
        _SelectionBar(selection: selection, state: state, notifier: notifier),
        if (state.truncated)
          Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: AppSpacing.screenPadding,
            ),
            child: Text(
              'Showing the first $kCategoryProductsMax products in this '
              'category.',
              style: Theme.of(context)
                  .textTheme
                  .bodySmall
                  ?.copyWith(color: AppColors.warning),
            ),
          ),
        Expanded(
          child: ListView.builder(
            padding: const EdgeInsets.all(AppSpacing.screenPadding),
            itemCount: state.items.length,
            itemBuilder: (context, index) {
              final product = state.items[index];
              return _ProductRow(
                product: product,
                selected: state.isSelected(product.id),
                onChanged: state.isMoving
                    ? null
                    : (_) => notifier.toggle(product.id),
              );
            },
          ),
        ),
      ],
    );
  }
}

class _SelectionBar extends StatelessWidget {
  const _SelectionBar({
    required this.selection,
    required this.state,
    required this.notifier,
  });

  final CategorySelection selection;
  final CategoryProductsState state;
  final CategoryProductsNotifier notifier;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final destination = selection.id;

    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.screenPadding,
        AppSpacing.md,
        AppSpacing.screenPadding,
        0,
      ),
      // A Wrap, not a Row: the count and two actions do not fit 320dp at a
      // large text scale, and a bar that overflows is how the action the user
      // came for ends up half off the screen.
      child: Wrap(
        alignment: WrapAlignment.spaceBetween,
        crossAxisAlignment: WrapCrossAlignment.center,
        spacing: AppSpacing.sm,
        runSpacing: AppSpacing.xs,
        children: [
          Text(
            state.hasSelection
                ? '${state.selectedIds.length} selected'
                : _countLabel(state.items.length),
            style: theme.textTheme.bodyMedium
                ?.copyWith(color: AppColors.textSecondary),
          ),
          Row(
            mainAxisSize: MainAxisSize.min,
            children: state.hasSelection
                ? [
                    TextButton(
                      onPressed:
                          state.isMoving ? null : notifier.clearSelection,
                      child: const Text('Clear'),
                    ),
                    const SizedBox(width: AppSpacing.sm),
                    AppButton(
                      label: 'Move to…',
                      isFullWidth: false,
                      isLoading: state.isMoving,
                      onPressed: () => _move(context),
                    ),
                  ]
                : [
                    TextButton(
                      onPressed: state.isMoving ? null : notifier.selectAll,
                      child: const Text('Select all'),
                    ),
                    if (destination != null) ...[
                      const SizedBox(width: AppSpacing.sm),
                      AppButton(
                        label: 'Add products',
                        isFullWidth: false,
                        // Not `isLoading`: the move already owns the spinner in
                        // this bar, and two spinners say two things are running.
                        onPressed: state.isMoving
                            ? null
                            : () => _addProducts(context, destination),
                      ),
                    ],
                  ],
          ),
        ],
      ),
    );
  }

  Future<void> _move(BuildContext context) async {
    final messenger = CatalogFeedback.of(context);
    final container = ProviderScope.containerOf(context, listen: false);
    final categories =
        container.read(catalogCategoriesProvider).valueOrNull?.categories ??
            const <CatalogCategory>[];

    final choice = await showModalBottomSheet<_DeleteChoice>(
      context: context,
      backgroundColor: AppColors.surface1,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(AppRadius.lg)),
      ),
      builder: (sheetContext) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            Padding(
              padding: const EdgeInsets.all(AppSpacing.lg),
              child: Text(
                'Move ${state.selectedIds.length} to…',
                style: Theme.of(sheetContext).textTheme.titleMedium,
              ),
            ),
            for (final category in categories)
              if (category.id != selection.id)
                ListTile(
                  title: Text(category.name),
                  onTap: () => Navigator.of(sheetContext).pop(
                    _DeleteChoice(
                      categoryId: category.id,
                      label: category.name,
                    ),
                  ),
                ),
            if (!selection.isUncategorized)
              ListTile(
                title: const Text('Uncategorized'),
                onTap: () => Navigator.of(sheetContext).pop(
                  const _DeleteChoice(
                    categoryId: null,
                    label: 'Uncategorized',
                  ),
                ),
              ),
          ],
        ),
      ),
    );
    if (choice == null) return;

    try {
      final moved = await notifier.moveSelectedTo(choice.categoryId);
      CatalogFeedback.confirm(
        messenger,
        '${_countLabel(moved)} moved to ${choice.label}.',
      );
    } on CatalogFailure catch (failure) {
      CatalogFeedback.failure(
        messenger,
        failure,
        subject: 'Those products could not be moved',
      );
    }
  }
}

// ── Adding existing products to a category ───────────────────────

/// Opens the picker for [categoryId] and writes back whatever it returns.
///
/// The WRITE is the destination pane's, not the picker's: the picker is a list
/// of what could be added and dies with the sheet, while the counts an add
/// moves — this category's, the one the product came from, the catalog header's
/// — belong to the notifier the user is standing in front of.
Future<void> _addProducts(BuildContext context, String categoryId) async {
  // Captured while the context is certainly mounted. The sheet is a route the
  // user can spend a while in, and on a narrow layout the pane underneath is a
  // page they can leave from it.
  final messenger = CatalogFeedback.of(context);
  final container = ProviderScope.containerOf(context, listen: false);
  final name =
      container.read(categoryNameProvider(categoryId)) ?? 'this category';

  final ids = await showModalBottomSheet<List<String>>(
    context: context,
    isScrollControlled: true,
    backgroundColor: AppColors.surface1,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(AppRadius.lg)),
    ),
    builder: (_) =>
        _AddProductsSheet(categoryId: categoryId, categoryName: name),
  );
  // Dismissed, or dismissed with nothing ticked. Neither is a write.
  if (ids == null || ids.isEmpty) return;

  try {
    final added = await container
        .read(categoryProductsProvider(categoryId).notifier)
        .addProducts(ids);
    if (added == 0) {
      // The server moved nothing, so every product picked had been deleted or
      // moved by someone else since the picker read them. Confirming an add
      // that did not happen is worse than saying it did not.
      CatalogFeedback.confirm(
        messenger,
        'Nothing was added — those products had already moved.',
      );
      return;
    }
    CatalogFeedback.confirm(
      messenger,
      '${_countLabel(added)} added to $name. Customers see it after you '
      'publish.',
    );
  } on CatalogFailure catch (failure) {
    // A part-written run still landed its earlier chunks, and the pane has
    // already re-read itself — so this says what went wrong over a list that is
    // already telling the truth about what arrived.
    CatalogFeedback.failure(
      messenger,
      failure,
      subject: 'Those products could not be added',
    );
  }
}

/// The picker: everything in the catalog that is NOT already in this category,
/// ticked, and handed back as a list of ids.
///
/// Returns through `Navigator.pop` rather than writing anything itself, so
/// success and failure are reported in one place — [_addProducts] — whether the
/// user got here from the empty state or from the selection bar.
class _AddProductsSheet extends ConsumerStatefulWidget {
  const _AddProductsSheet({
    required this.categoryId,
    required this.categoryName,
  });

  final String categoryId;
  final String categoryName;

  @override
  ConsumerState<_AddProductsSheet> createState() => _AddProductsSheetState();
}

class _AddProductsSheetState extends ConsumerState<_AddProductsSheet> {
  final TextEditingController _search = TextEditingController();

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final provider = categoryCandidatesProvider(widget.categoryId);
    final state = ref.watch(provider);
    final notifier = ref.read(provider.notifier);
    final visible = state.visible;

    // Where each product is coming FROM, resolved once for the whole list: a
    // thousand rows walking the same handful of categories is a thousand walks
    // for one map.
    final names = <String, String>{
      for (final category
          in ref.watch(catalogCategoriesProvider).valueOrNull?.categories ??
              const <CatalogCategory>[])
        category.id: category.name,
    };

    return Padding(
      // The search field raises the keyboard; the sheet rides up with it rather
      // than leaving the list behind it.
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: FractionallySizedBox(
        heightFactor: 0.85,
        child: SafeArea(
          top: false,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(
                  AppSpacing.lg,
                  AppSpacing.lg,
                  AppSpacing.sm,
                  0,
                ),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        'Add to ${widget.categoryName}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.titleLarge,
                      ),
                    ),
                    IconButton(
                      icon: const Icon(Icons.close),
                      tooltip: 'Close',
                      onPressed: () => Navigator.of(context).pop(),
                    ),
                  ],
                ),
              ),
              Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: AppSpacing.lg),
                child: Text(
                  // Said once, up front. A product sits in exactly one
                  // category, so this is a MOVE — and a user who reads it as a
                  // copy will wonder why the category they took it from got
                  // smaller.
                  'A product sits in one category, so adding it here takes it '
                  'out of the one it is in now.',
                  style: theme.textTheme.bodySmall
                      ?.copyWith(color: AppColors.textMuted),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(
                  AppSpacing.lg,
                  AppSpacing.md,
                  AppSpacing.lg,
                  0,
                ),
                child: AppTextField(
                  label: 'Search products',
                  controller: _search,
                  enabled: !state.isLoading,
                  prefixIcon: const Icon(Icons.search),
                  suffixIcon: state.isSearching
                      ? IconButton(
                          icon: const Icon(Icons.clear),
                          tooltip: 'Clear search',
                          onPressed: () {
                            _search.clear();
                            notifier.setQuery('');
                          },
                        )
                      : null,
                  textInputAction: TextInputAction.search,
                  // Filters what is already loaded rather than re-fetching, so
                  // there is nothing to debounce.
                  onChanged: notifier.setQuery,
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(
                  AppSpacing.lg,
                  AppSpacing.sm,
                  AppSpacing.lg,
                  0,
                ),
                child: Wrap(
                  alignment: WrapAlignment.spaceBetween,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  spacing: AppSpacing.sm,
                  children: [
                    Text(
                      state.hasSelection
                          ? '${state.selectedIds.length} selected'
                          : '${visible.length} to choose from',
                      style: theme.textTheme.bodyMedium
                          ?.copyWith(color: AppColors.textSecondary),
                    ),
                    TextButton(
                      onPressed:
                          visible.isEmpty ? null : notifier.selectAllVisible,
                      // While a search is on, "all" means these — and it ADDS
                      // to the selection rather than replacing it, so the rows
                      // the filter is hiding stay ticked.
                      child: Text(
                        state.isSearching ? 'Select these' : 'Select all',
                      ),
                    ),
                  ],
                ),
              ),
              if (state.truncated)
                Padding(
                  padding:
                      const EdgeInsets.symmetric(horizontal: AppSpacing.lg),
                  child: Text(
                    'Searched the first $kCategoryCandidatesMax products in '
                    'your catalog.',
                    style: theme.textTheme.bodySmall
                        ?.copyWith(color: AppColors.warning),
                  ),
                ),
              Expanded(
                child: _list(context, state, notifier, visible, names),
              ),
              const Divider(height: 1),
              Padding(
                padding: const EdgeInsets.all(AppSpacing.lg),
                child: Wrap(
                  alignment: WrapAlignment.spaceBetween,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  spacing: AppSpacing.sm,
                  runSpacing: AppSpacing.sm,
                  children: [
                    TextButton(
                      onPressed:
                          state.hasSelection ? notifier.clearSelection : null,
                      child: const Text('Clear'),
                    ),
                    AppButton(
                      label: state.hasSelection
                          ? 'Add ${state.selectedIds.length}'
                          : 'Add',
                      isFullWidth: false,
                      // Nothing ticked is not a write: the button stays down
                      // rather than closing the sheet on an empty list.
                      onPressed: state.hasSelection
                          ? () => Navigator.of(context)
                              .pop(state.selectedIds.toList())
                          : null,
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// The four ways this list can be empty each get their own sentence. "You
  /// have no products yet", "they are all already in here", "your search found
  /// nothing" and "we could not load them" are four different situations, and
  /// one shared "Nothing to add" would leave the user guessing which.
  Widget _list(
    BuildContext context,
    CategoryCandidatesState state,
    CategoryCandidatesNotifier notifier,
    List<CatalogProduct> visible,
    Map<String, String> names,
  ) {
    if (state.isLoading && state.items.isEmpty) {
      return const Center(child: AppLoadingIndicator());
    }
    if (state.error != null && state.items.isEmpty) {
      return CatalogMessage(
        icon: Icons.cloud_off_outlined,
        title: "We couldn't load your products",
        body: CatalogFeedback.failureText(state.error!),
        actionLabel: 'Try again',
        onAction: notifier.load,
      );
    }
    if (state.catalogIsEmpty) {
      return const CatalogMessage(
        icon: Icons.inventory_2_outlined,
        title: 'No products yet',
        body: 'Add a product to your catalog first, then come back and group '
            'it here.',
      );
    }
    if (state.allAlreadyHere) {
      return CatalogMessage(
        icon: Icons.check_circle_outline,
        title: 'Everything is already here',
        body: 'Every product in your catalog is in ${widget.categoryName}.',
      );
    }
    if (visible.isEmpty) {
      return const CatalogMessage(
        icon: Icons.search_off,
        title: 'No match',
        body: 'Nothing outside this category is named like that.',
      );
    }

    return ListView.builder(
      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg),
      itemCount: visible.length,
      itemBuilder: (context, index) {
        final product = visible[index];
        final from = product.categoryId == null
            ? 'Uncategorized'
            // A category the list has not fetched is named honestly rather
            // than silently reported as Uncategorized, which is a real and
            // different place for a product to be.
            : names[product.categoryId] ?? 'another category';
        return _ProductRow(
          product: product,
          selected: state.isSelected(product.id),
          onChanged: (_) => notifier.toggle(product.id),
          note: 'in $from',
        );
      },
    );
  }
}

class _ProductRow extends StatelessWidget {
  const _ProductRow({
    required this.product,
    required this.selected,
    required this.onChanged,
    this.note,
  });

  final CatalogProduct product;
  final bool selected;
  final ValueChanged<bool?>? onChanged;

  /// Appended to the subtitle. The picker uses it to say where a product is
  /// coming FROM, because a product has one category and adding it here takes
  /// it out of the one it is in now.
  final String? note;

  @override
  Widget build(BuildContext context) => CheckboxListTile(
        contentPadding: EdgeInsets.zero,
        dense: true,
        value: selected,
        activeColor: AppColors.mirageRed,
        controlAffinity: ListTileControlAffinity.leading,
        onChanged: onChanged,
        title: Text(
          product.name,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: Theme.of(context).textTheme.bodyMedium,
        ),
        subtitle: Text(
          [
            product.type.label,
            if (product.isArchived) 'Archived',
            if (note != null) note!,
          ].join(' · '),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: Theme.of(context)
              .textTheme
              .bodySmall
              ?.copyWith(color: AppColors.textMuted),
        ),
      );
}
