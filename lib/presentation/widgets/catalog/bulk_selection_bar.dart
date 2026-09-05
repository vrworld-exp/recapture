// lib/presentation/widgets/catalog/bulk_selection_bar.dart
//
// The chrome of selection mode: the app bar that replaces the catalog's own
// while a selection is live, the action row underneath the grid, and the
// keyboard scope that makes the whole thing usable with a mouse and a keyboard
// (feature 30, T-022).
//
// Two bars rather than one crowded one, and the split is a layout decision that
// holds at every width: the COUNT and the way out belong at the top where the
// title was, and the four actions belong at the bottom where a thumb reaches
// and where they cannot be mistaken for navigation.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/theme/app_colors.dart';
import '../../../app/theme/app_spacing.dart';
import '../../../application/catalog/bulk_selection_notifier.dart';
import '../../../application/catalog/catalog_products_notifier.dart';
import '../../../data/repositories/catalog_products_repository.dart';
import 'bulk_actions.dart';
import 'catalog_feedback.dart';

/// Whether a modifier that means "add to the selection" is held right now.
///
/// Read from [HardwareKeyboard] at the moment of the click rather than tracked
/// in state: a modifier pressed and released between two frames would otherwise
/// be missed, and a stale one would turn an ordinary click into a range select.
///
/// Both Control and Meta, unconditionally — the platform decides which one users
/// reach for, and accepting both costs nothing while getting it wrong makes the
/// gesture simply not work on one OS.
bool bulkAddModifierHeld() {
  final keys = HardwareKeyboard.instance.logicalKeysPressed;
  return keys.contains(LogicalKeyboardKey.controlLeft) ||
      keys.contains(LogicalKeyboardKey.controlRight) ||
      keys.contains(LogicalKeyboardKey.metaLeft) ||
      keys.contains(LogicalKeyboardKey.metaRight);
}

/// Whether Shift — the "extend the range" modifier — is held right now.
bool bulkRangeModifierHeld() {
  final keys = HardwareKeyboard.instance.logicalKeysPressed;
  return keys.contains(LogicalKeyboardKey.shiftLeft) ||
      keys.contains(LogicalKeyboardKey.shiftRight);
}

/// The keyboard half of selection mode: `Ctrl/Cmd+A` selects every loaded
/// product, `Escape` leaves.
///
/// Wrapped around the catalog's scroll view rather than around a card, because a
/// shortcut only fires while the focus is INSIDE the widget that declares it —
/// and the focus, after a click on a card, is on the card. The invisible
/// autofocus node is what makes the shortcuts work before anything has been
/// clicked at all; it holds no visual focus of its own and gives the ring up the
/// moment a real control asks for it.
///
/// `Ctrl+A` inside the search field stays the field's own select-all: the field
/// takes focus when it is being typed in, and Flutter's text bindings handle the
/// combination before it ever reaches this scope.
class BulkSelectionShortcuts extends ConsumerWidget {
  const BulkSelectionShortcuts({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final notifier = ref.read(bulkSelectionProvider.notifier);

    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.keyA, control: true):
            notifier.selectAllLoaded,
        const SingleActivator(LogicalKeyboardKey.keyA, meta: true):
            notifier.selectAllLoaded,
        const SingleActivator(LogicalKeyboardKey.escape): notifier.exit,
      },
      child: Focus(autofocus: true, child: child),
    );
  }
}

/// The app bar shown INSTEAD of the catalog's own while selection is active.
class BulkSelectionAppBar extends ConsumerWidget
    implements PreferredSizeWidget {
  const BulkSelectionAppBar({super.key});

  @override
  Size get preferredSize => const Size.fromHeight(kToolbarHeight);

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final selection = ref.watch(bulkSelectionProvider);
    final notifier = ref.read(bulkSelectionProvider.notifier);
    final loaded = ref.watch(catalogProductsProvider).items.length;

    return AppBar(
      backgroundColor: AppColors.surface1,
      elevation: 0,
      leading: IconButton(
        icon: const Icon(Icons.close),
        tooltip: 'Leave selection mode',
        onPressed: notifier.exit,
      ),
      title: Text(
        selection.count == 0
            ? 'Select products'
            : '${selection.count} selected',
        style: Theme.of(context).textTheme.titleLarge,
      ),
      actions: [
        TextButton(
          // Selects what is LOADED. Naming it so is the honest half of the
          // affordance; the note below says how much that was.
          onPressed: loaded == 0 || selection.isRunning
              ? null
              : notifier.selectAllLoaded,
          child: const Text('Select all'),
        ),
        TextButton(
          onPressed:
              selection.isEmpty || selection.isRunning ? null : notifier.clear,
          child: const Text('Clear'),
        ),
        const SizedBox(width: AppSpacing.sm),
      ],
    );
  }
}

/// The note strip under the app bar: what a select-all actually covered, and
/// what a filter change just did to the selection.
///
/// Rendered as a sliver so it composes into the catalog's one scroll view.
class BulkSelectionNotice extends ConsumerWidget {
  const BulkSelectionNotice({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final selection = ref.watch(bulkSelectionProvider);
    if (!selection.isActive) return const SizedBox.shrink();

    final String? message;
    if (selection.clearedByFilterChange) {
      // Said out loud, always. A selection that empties itself when the filters
      // move is correct behaviour and invisible behaviour — and invisible is how
      // a user presses Archive believing twenty rows are still chosen.
      message = 'The filters changed, so your selection was cleared.';
    } else if (selection.scopedToLoaded) {
      message = 'Selected the ${selection.count} products loaded so far. '
          'Scroll to load more, then select again.';
    } else {
      message = null;
    }
    if (message == null) return const SizedBox.shrink();

    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpacing.md),
      child: Container(
        padding: const EdgeInsets.all(AppSpacing.md),
        decoration: BoxDecoration(
          color: AppColors.warning.withValues(alpha: 0.1),
          borderRadius: BorderRadius.circular(AppRadius.xs),
          border: Border.all(color: AppColors.warning.withValues(alpha: 0.35)),
        ),
        child: Row(
          children: [
            const Icon(Icons.info_outline, size: 16, color: AppColors.warning),
            const SizedBox(width: AppSpacing.sm),
            Expanded(
              child: Text(
                message,
                style: Theme.of(context)
                    .textTheme
                    .bodySmall
                    ?.copyWith(color: AppColors.warning, height: 1.4),
              ),
            ),
            IconButton(
              icon: const Icon(Icons.close, size: 16),
              tooltip: 'Dismiss',
              onPressed:
                  ref.read(bulkSelectionProvider.notifier).acknowledgeNotes,
            ),
          ],
        ),
      ),
    );
  }
}

/// The action row: archive, restore, move, delete.
///
/// Shown as the scaffold's bottom bar while selection is active. Every button is
/// disabled with an empty selection rather than hidden, so the user can see what
/// selecting is FOR before they have selected anything.
class BulkActionBar extends ConsumerWidget {
  const BulkActionBar({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final selection = ref.watch(bulkSelectionProvider);
    final enabled = !selection.isEmpty && !selection.isRunning;

    // Both captured while this widget is certainly mounted: a bulk run over 200
    // products outlives the bar that started it.
    final messenger = CatalogFeedback.of(context);
    final container = ProviderScope.containerOf(context, listen: false);
    final routeContext = Navigator.of(context).context;

    Future<void> run(BulkProductAction action) async {
      if (!routeContext.mounted) return;
      await runBulkAction(routeContext, messenger, container, action);
    }

    return Material(
      color: AppColors.surface1,
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: AppSpacing.sm,
            vertical: AppSpacing.xs,
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: [
              _BarAction(
                icon: Icons.inventory_2_outlined,
                label: 'Archive',
                onPressed:
                    enabled ? () => run(BulkProductAction.archive) : null,
              ),
              _BarAction(
                icon: Icons.unarchive_outlined,
                label: 'Restore',
                onPressed:
                    enabled ? () => run(BulkProductAction.restore) : null,
              ),
              _BarAction(
                icon: Icons.category_outlined,
                label: 'Category',
                onPressed: enabled
                    ? () async {
                        if (!routeContext.mounted) return;
                        await promptBulkCategory(
                          routeContext,
                          messenger,
                          container,
                        );
                      }
                    : null,
              ),
              _BarAction(
                icon: Icons.delete_outline,
                label: 'Delete',
                color: AppColors.error,
                onPressed: enabled ? () => run(BulkProductAction.delete) : null,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _BarAction extends StatelessWidget {
  const _BarAction({
    required this.icon,
    required this.label,
    required this.onPressed,
    this.color,
  });

  final IconData icon;
  final String label;
  final VoidCallback? onPressed;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final tint = onPressed == null
        ? AppColors.disabled
        : (color ?? AppColors.textPrimary);

    return Expanded(
      child: TextButton(
        onPressed: onPressed,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 20, color: tint),
            const SizedBox(height: AppSpacing.xs),
            Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style:
                  Theme.of(context).textTheme.bodySmall?.copyWith(color: tint),
            ),
          ],
        ),
      ),
    );
  }
}
