// lib/presentation/widgets/catalog/product_actions.dart
//
// Archive, restore and permanent delete (features 19, 20, 21) — the menu that
// offers them and the three functions that run them.
//
// One file, and one implementation each, because these actions are reachable
// from TWO places: the grid card's overflow menu and the product editor. Two
// copies would be two sets of confirmation copy, and the copy is most of the
// feature here — "archived" and "deleted" are a snackbar apart and a universe
// apart, and only one of them can be taken back.
//
// Nothing here takes a `WidgetRef`. Every function grabs the
// [ProviderContainer] instead, because the work OUTLIVES the widget that
// started it: the editor archives and pops, and the undo fires six seconds
// later from a screen that no longer exists. A container survives that; a ref
// does not.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/theme/app_colors.dart';
import '../../../app/theme/app_spacing.dart';
import '../../../application/catalog/catalog_notifier.dart';
import '../../../application/catalog/catalog_products_notifier.dart';
import '../../../application/catalog/product_detail_notifier.dart';
import '../../../data/repositories/catalog_failure.dart';
import '../../../domain/entities/catalog_product.dart';
import '../../../domain/entities/product_sync_status.dart';
import 'catalog_feedback.dart';
import 'typed_confirm_dialog.dart';

/// What the overflow menu offers.
enum ProductAction { archive, restore, delete }

/// Opens one product's overflow menu anchored at [anchor], and runs whatever
/// the user picks.
///
/// [anchor] is the CELL's context — the menu opens over the card it belongs to,
/// which on a five-column grid is the only way to tell which product is about
/// to be archived. `showMenu` gives keyboard traversal and click-to-open on the
/// web build for free, which a hand-rolled popup would not.
Future<void> showProductActionsMenu(
  BuildContext anchor,
  CatalogProduct product,
) async {
  // Both captured while the anchor is certainly mounted: a card can scroll out
  // of the viewport (and be unmounted) while its own menu is open.
  final messenger = CatalogFeedback.of(anchor);
  final container = ProviderScope.containerOf(anchor, listen: false);
  // The Navigator's own context outlives any single card, so it is what the
  // confirmation dialog is shown from.
  final routeContext = Navigator.of(anchor).context;

  final action = await showMenu<ProductAction>(
    context: anchor,
    position: _anchorRect(anchor),
    color: AppColors.surface1,
    shape: RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(AppRadius.xs),
    ),
    items: [
      // Restore is FIRST on an archived product, because it is the only thing
      // the user came to an archived row to do. Archive is first on a live one.
      if (product.isArchived)
        const PopupMenuItem<ProductAction>(
          value: ProductAction.restore,
          child: _MenuRow(
            icon: Icons.unarchive_outlined,
            label: 'Restore',
            color: AppColors.textPrimary,
          ),
        )
      else
        const PopupMenuItem<ProductAction>(
          value: ProductAction.archive,
          child: _MenuRow(
            icon: Icons.inventory_2_outlined,
            label: 'Archive',
            color: AppColors.textPrimary,
          ),
        ),
      const PopupMenuDivider(),
      const PopupMenuItem<ProductAction>(
        value: ProductAction.delete,
        child: _MenuRow(
          icon: Icons.delete_outline,
          label: 'Delete permanently',
          color: AppColors.error,
        ),
      ),
    ],
  );

  switch (action) {
    case null:
      return;
    case ProductAction.archive:
      await archiveProduct(messenger, container, product);
    case ProductAction.restore:
      await restoreProduct(messenger, container, product);
    case ProductAction.delete:
      if (!routeContext.mounted) return;
      await deleteProduct(routeContext, messenger, container, product);
  }
}

/// Archives [product] (feature 19) and offers an undo for
/// [kCatalogUndoWindow].
///
/// Optimistic — the notifier owns the removal and the rollback. What lives here
/// is the CONSEQUENCE, said out loud: a live product leaving the public catalog
/// at the next publish, and an emptied catalog no longer being publishable at
/// all. Both are things the user otherwise finds out later and expensively.
///
/// Returns true only when the server agreed, so a caller sitting ON that product
/// (the editor) can decide what to do next rather than assuming it worked.
Future<bool> archiveProduct(
  ScaffoldMessengerState messenger,
  ProviderContainer container,
  CatalogProduct product,
) async {
  final notifier = container.read(catalogProductsProvider.notifier);
  try {
    final index = await notifier.archive(product.id);
    _adopt(container, product.id);
    CatalogFeedback.undoable(
      messenger,
      _archivedMessage(container, product),
      // The REAL inverse, not a local un-hide: the row is archived on the
      // server, and an undo that only repainted the grid would leave the two
      // disagreeing until the next refresh proved the user wrong.
      onUndo: () => restoreProduct(messenger, container, product, index: index),
    );
    return true;
  } on CatalogFailure catch (failure) {
    // The grid has already rolled back. An offline archive is a clean failure
    // with a retry — never a row that vanishes locally and comes back later.
    CatalogFeedback.failure(
      messenger,
      failure,
      subject: '${product.name} could not be archived',
      onRetry: () => archiveProduct(messenger, container, product),
    );
    return false;
  }
}

/// Restores an archived product (feature 20).
///
/// [index] is where the row was before it was archived, so an undo puts it back
/// where the user is looking rather than on the end of the grid. Restoring from
/// the Archived filter has no index and needs none — the row is already there.
Future<bool> restoreProduct(
  ScaffoldMessengerState messenger,
  ProviderContainer container,
  CatalogProduct product, {
  int? index,
}) async {
  try {
    await container
        .read(catalogProductsProvider.notifier)
        .restore(product.id, index: index);
    _adopt(container, product.id);
    CatalogFeedback.confirm(
      messenger,
      '${product.name} is back in your catalog.',
    );
    return true;
  } on CatalogFailure catch (failure) {
    CatalogFeedback.failure(
      messenger,
      failure,
      subject: '${product.name} could not be restored',
      onRetry: () =>
          restoreProduct(messenger, container, product, index: index),
    );
    return false;
  }
}

/// Permanently deletes [product] (feature 21) behind a typed confirmation.
///
/// Returns true only when the product is gone, so a caller sitting ON that
/// product (the editor) knows to leave.
///
/// The typed gate is not ceremony. This is the one catalog action with no undo
/// anywhere — not a snackbar, not a filter — and for a published product it
/// reaches past ReCapture into what customers see. A misplaced tap must not be
/// able to do that.
Future<bool> deleteProduct(
  BuildContext context,
  ScaffoldMessengerState messenger,
  ProviderContainer container,
  CatalogProduct product,
) async {
  final confirmed = await showTypedConfirmDialog(
    context,
    title: 'Delete ${product.name}?',
    body: 'This removes the product from ReCapture for good, along with its '
        'photo or 3D model. It cannot be undone.',
    warnings: [
      if (product.syncStatus == ProductSyncStatus.synced)
        'This product is live. It will be removed from your public catalog '
            'the next time you publish.',
    ],
    confirmationText: product.name,
  );
  if (!confirmed) return false;

  try {
    await container.read(catalogProductsProvider.notifier).delete(product.id);
    // NOT `_adopt`: re-reading a product that no longer exists would answer the
    // API's deliberately-indistinguishable 404 and paint an error over a screen
    // whose job is now to leave.
    _refreshCatalogHeader(container);
    CatalogFeedback.confirm(messenger, _deletedMessage(container, product));
    return true;
  } on CatalogFailure catch (failure) {
    CatalogFeedback.failure(
      messenger,
      failure,
      subject: '${product.name} could not be deleted',
    );
    return false;
  }
}

// ── Copy ────────────────────────────────────────────────────────────────────

String _archivedMessage(ProviderContainer container, CatalogProduct product) {
  final live = product.syncStatus == ProductSyncStatus.synced
      ? ' It leaves your public catalog at the next publish.'
      : '';
  return '${product.name} archived.$live${_emptyCatalogNote(container)}';
}

String _deletedMessage(ProviderContainer container, CatalogProduct product) {
  final live = product.syncStatus == ProductSyncStatus.synced
      ? ' It will be removed from your public catalog at the next publish.'
      : '';
  return '${product.name} deleted.$live${_emptyCatalogNote(container)}';
}

/// The sentence appended when that was the last product.
///
/// An empty catalog cannot be published — the backend gates it as
/// `CATALOG_EMPTY` — and the user who just archived their only product will not
/// find that out until they press Publish and are refused. Saying it here costs
/// one clause.
///
/// Only claimed for an UNFILTERED grid: an empty filtered view says nothing
/// about how many products the catalog holds.
String _emptyCatalogNote(ProviderContainer container) {
  final state = container.read(catalogProductsProvider);
  if (state.query.isFiltered || state.items.isNotEmpty) return '';
  return ' That was your last product, and publishing needs at least one.';
}

/// Pulls server truth back into every surface showing this product.
///
/// The editor may be OPEN on it — archiving from there must flip its state, and
/// the detail notifier holds its own copy that the grid's in-place update does
/// not reach. Invalidating an auto-disposed provider nobody is watching costs
/// nothing, so this is unconditional rather than a guess about who is on screen.
void _adopt(ProviderContainer container, String productId) {
  container.invalidate(productDetailProvider(productId));
  _refreshCatalogHeader(container);
}

/// The catalog header's counts and its draft badge are both SERVER-derived, and
/// archiving or deleting moves both. Best-effort: the write already succeeded,
/// and a failed refresh must not turn it into an error the user sees.
void _refreshCatalogHeader(ProviderContainer container) {
  container.read(catalogProvider.notifier).refresh().catchError((_) {});
}

/// Where [anchor] sits in the overlay, as `showMenu` wants it.
///
/// The same computation `PopupMenuButton` does internally; it is inlined here
/// because the button lives on a pure-presentation card that holds no menu of
/// its own.
RelativeRect _anchorRect(BuildContext anchor) {
  // `is RenderBox`, never a cast: not every context has a box under it (a
  // sliver's builder context resolves to the SLIVER's render object), and a
  // misplaced menu must not be a crash on tap.
  final render = anchor.findRenderObject();
  final overlayRender = Navigator.of(anchor).overlay?.context.findRenderObject();
  if (render is! RenderBox || overlayRender is! RenderBox) {
    // No geometry to anchor to: centre it rather than throwing. A menu in the
    // middle of the screen is a cosmetic problem; an exception on tap is not.
    return RelativeRect.fill;
  }
  final topLeft = render.localToGlobal(Offset.zero, ancestor: overlayRender);
  final bottomRight = render.localToGlobal(
    render.size.bottomRight(Offset.zero),
    ancestor: overlayRender,
  );
  return RelativeRect.fromLTRB(
    topLeft.dx,
    topLeft.dy,
    overlayRender.size.width - bottomRight.dx,
    overlayRender.size.height - bottomRight.dy,
  );
}

class _MenuRow extends StatelessWidget {
  const _MenuRow({
    required this.icon,
    required this.label,
    required this.color,
  });

  final IconData icon;
  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) => Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 18, color: color),
          const SizedBox(width: AppSpacing.md),
          // Flexible, because a popup menu constrains its items to a width the
          // longest label can exceed — an overflow stripe is not a menu.
          Flexible(
            child: Text(
              label,
              overflow: TextOverflow.ellipsis,
              style:
                  Theme.of(context).textTheme.bodyMedium?.copyWith(color: color),
            ),
          ),
        ],
      );
}
