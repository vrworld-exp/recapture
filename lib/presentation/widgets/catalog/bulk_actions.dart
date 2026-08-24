// lib/presentation/widgets/catalog/bulk_actions.dart
//
// Running a bulk action, confirming the destructive ones, and REPORTING what
// happened (feature 30, T-022).
//
// The reporting is the point. `POST /catalog/products/bulk` is all-or-nothing
// per call, and [BulkSelectionNotifier] turns that into per-item outcomes; this
// file is what refuses to flatten them again. A partial run gets a sheet that
// names the products that failed and offers to retry exactly those — never a
// snackbar saying "Done".
//
// Nothing here takes a `WidgetRef`, for the same reason `product_actions.dart`
// does not: a bulk run outlives the bar that started it, and a run over 200
// products outlives it by a while.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/theme/app_colors.dart';
import '../../../app/theme/app_spacing.dart';
import '../../../application/catalog/bulk_selection_notifier.dart';
import '../../../application/catalog/catalog_categories_notifier.dart';
import '../../../application/catalog/catalog_notifier.dart';
import '../../../data/repositories/catalog_products_repository.dart';
import '../../../domain/entities/catalog_category.dart';
import '../app_button.dart';
import 'catalog_feedback.dart';
import 'typed_confirm_dialog.dart';

/// The phrase a bulk permanent delete is gated on.
///
/// Not a product name — there is no single one — but still typed, because this
/// is the same one-way door as the single delete with a multiplier on it.
const String kBulkDeleteConfirmationPhrase = 'DELETE';

/// Runs [action] over the current selection, confirming first where it matters,
/// and reports the outcome per item.
///
/// [context] must be a Navigator's context, not a card's: the confirmation and
/// the report both outlive whatever widget was tapped.
Future<void> runBulkAction(
  BuildContext context,
  ScaffoldMessengerState messenger,
  ProviderContainer container,
  BulkProductAction action, {
  Object? categoryId = kCatalogUnchanged,
}) async {
  final notifier = container.read(bulkSelectionProvider.notifier);
  final count = container.read(bulkSelectionProvider).count;
  if (count == 0) return;

  if (!await _confirm(context, action, count)) return;

  final result = await notifier.run(action: action, categoryId: categoryId);

  // The header's counts and its draft badge are both server-derived and every
  // one of these actions moves them. Best-effort — the writes already happened.
  container.read(catalogProvider.notifier).refresh().catchError((_) {});

  if (result.requested == 0) return;

  if (result.isCompleteSuccess) {
    notifier.exit();
    CatalogFeedback.confirm(messenger, _successMessage(action, result));
    return;
  }

  // Anything less than everything gets the sheet. A partial run reported as a
  // one-line toast is the exact failure this feature was written to avoid.
  if (!context.mounted) return;
  await showBulkResultSheet(context, messenger, container, result);
}

/// The confirmation for the destructive halves. Both name the COUNT, because
/// "Archive products?" over a selection the user cannot see is not a
/// confirmation.
Future<bool> _confirm(
  BuildContext context,
  BulkProductAction action,
  int count,
) async {
  switch (action) {
    case BulkProductAction.restore:
    case BulkProductAction.setCategory:
      return true;

    case BulkProductAction.archive:
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          backgroundColor: AppColors.surface1,
          title: Text('Archive ${_plural(count)}?'),
          content: Text(
            'They stay in ReCapture and can be restored at any time. Any that '
            'are live leave your public catalog at the next publish.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('Cancel'),
            ),
            TextButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text('Archive'),
            ),
          ],
        ),
      );
      return confirmed ?? false;

    case BulkProductAction.delete:
      // Typed, like the single delete. This is the one catalog action with no
      // undo anywhere, and doing it to fifty products at once does not make it
      // less final.
      return showTypedConfirmDialog(
        context,
        title: 'Delete ${_plural(count)}?',
        body: 'This removes them from ReCapture for good, along with their '
            'photos and 3D models. It cannot be undone.',
        warnings: const [
          'Any of these that are live will be removed from your public catalog '
              'the next time you publish.',
        ],
        confirmationText: kBulkDeleteConfirmationPhrase,
        hintText: kBulkDeleteConfirmationPhrase,
      );
  }
}

/// Asks which category the selection should move to, then runs it.
///
/// Uncategorized is offered as a real choice rather than as "none": it is a
/// null `categoryId` on the server and a legitimate destination, and the only
/// way to empty a category without deleting it.
Future<void> promptBulkCategory(
  BuildContext context,
  ScaffoldMessengerState messenger,
  ProviderContainer container,
) async {
  final categories =
      container.read(catalogCategoriesProvider).valueOrNull?.categories ??
          const <CatalogCategory>[];

  final choice = await showDialog<_CategoryChoice>(
    context: context,
    builder: (context) => SimpleDialog(
      backgroundColor: AppColors.surface1,
      title: const Text('Move to category'),
      children: [
        SimpleDialogOption(
          onPressed: () =>
              Navigator.of(context).pop(const _CategoryChoice(null)),
          child: const Text('Uncategorized'),
        ),
        for (final category in categories)
          SimpleDialogOption(
            onPressed: () =>
                Navigator.of(context).pop(_CategoryChoice(category.id)),
            child: Text(category.name),
          ),
      ],
    ),
  );
  if (choice == null || !context.mounted) return;

  await runBulkAction(
    context,
    messenger,
    container,
    BulkProductAction.setCategory,
    // Explicitly null, never the sentinel: SET_CATEGORY needs the KEY present
    // even when the value is null, and null is what means Uncategorized.
    categoryId: choice.id,
  );
}

class _CategoryChoice {
  const _CategoryChoice(this.id);
  final String? id;
}

// ── The report ──────────────────────────────────────────────────────────────

/// Shows what happened, item by item, with a retry for the failed subset.
///
/// A sheet rather than a snackbar because the content is a LIST: which products
/// failed, and why. A toast can hold one sentence, and one sentence is exactly
/// the thing that turns "18 of 20" into "done".
Future<void> showBulkResultSheet(
  BuildContext context,
  ScaffoldMessengerState messenger,
  ProviderContainer container,
  BulkRunResult result,
) =>
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: AppColors.surface1,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(AppRadius.md)),
      ),
      builder: (sheetContext) => _BulkResultSheet(
        result: result,
        messenger: messenger,
        container: container,
      ),
    );

class _BulkResultSheet extends StatelessWidget {
  const _BulkResultSheet({
    required this.result,
    required this.messenger,
    required this.container,
  });

  final BulkRunResult result;
  final ScaffoldMessengerState messenger;
  final ProviderContainer container;

  /// Re-runs the SAME action against the failed ids only.
  ///
  /// Not the whole selection: the succeeded half is already done, and re-sending
  /// it would archive-then-archive or, on a delete, ask the server to delete
  /// rows that are already gone.
  Future<void> _retryFailed(BuildContext context) async {
    final ids = result.failedIds;
    // Captured BEFORE the pop: this sheet's own context is defunct the moment
    // it closes, and the retry's confirmation has to be shown from something
    // that outlives it.
    final navigator = Navigator.of(context, rootNavigator: true).context;
    Navigator.of(context).pop();

    container.read(bulkSelectionProvider.notifier).selectOnly(ids);

    if (!navigator.mounted) return;
    await runBulkAction(
      navigator,
      messenger,
      container,
      result.action,
      // SET_CATEGORY is deliberately NOT retried blind here: the category it
      // moved to is not carried on the result, and guessing it would move
      // products somewhere nobody chose. The user re-picks instead.
      categoryId: kCatalogUnchanged,
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final retryable = result.action != BulkProductAction.setCategory;

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.lg),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(_headline(result), style: theme.textTheme.titleLarge),
            const SizedBox(height: AppSpacing.sm),
            Text(
              result.isCompleteFailure
                  ? 'Nothing was changed.'
                  : '${result.succeeded.length} of ${result.requested} '
                      '${_verb(result.action)}. '
                      '${result.failed.length} failed.',
              style: theme.textTheme.bodyMedium
                  ?.copyWith(color: AppColors.textSecondary),
            ),
            if (result.isolationExhausted) ...[
              const SizedBox(height: AppSpacing.sm),
              Text(
                'Some of these were refused as a group, so a few of them may '
                'have been fine. Retrying will narrow it down.',
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: AppColors.warning, height: 1.4),
              ),
            ],
            const SizedBox(height: AppSpacing.lg),
            Flexible(
              child: ListView.separated(
                shrinkWrap: true,
                itemCount: result.failed.length,
                separatorBuilder: (_, __) =>
                    const Divider(height: 1, color: AppColors.surface2),
                itemBuilder: (_, index) {
                  final item = result.failed[index];
                  return ListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    leading: const Icon(
                      Icons.error_outline,
                      size: 18,
                      color: AppColors.error,
                    ),
                    title: Text(item.name, style: theme.textTheme.bodyMedium),
                    subtitle: Text(
                      // OUR sentence for the code, from the one table.
                      CatalogFeedback.failureText(item.failure),
                      style: theme.textTheme.bodySmall
                          ?.copyWith(color: AppColors.textSecondary),
                    ),
                  );
                },
              ),
            ),
            const SizedBox(height: AppSpacing.lg),
            if (retryable)
              AppButton(
                label: 'Retry ${result.failed.length} failed',
                onPressed: () => _retryFailed(context),
              )
            else
              Text(
                'The products that failed are still selected — pick a category '
                'again to retry them.',
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: AppColors.textSecondary),
              ),
            const SizedBox(height: AppSpacing.sm),
            AppButton.secondary(
              label: 'Close',
              onPressed: () => Navigator.of(context).pop(),
            ),
          ],
        ),
      ),
    );
  }
}

// ── Copy ────────────────────────────────────────────────────────────────────

String _plural(int count) => count == 1 ? '1 product' : '$count products';

String _headline(BulkRunResult result) => result.isCompleteFailure
    ? "That didn't work"
    : '${result.succeeded.length} of ${result.requested} '
        '${_verb(result.action)}';

/// The past tense of each action, for a sentence about what already happened.
String _verb(BulkProductAction action) => switch (action) {
      BulkProductAction.archive => 'archived',
      BulkProductAction.restore => 'restored',
      BulkProductAction.delete => 'deleted',
      BulkProductAction.setCategory => 'moved',
    };

String _successMessage(BulkProductAction action, BulkRunResult result) {
  final subject = _plural(result.succeeded.length);
  return switch (action) {
    BulkProductAction.archive =>
      '$subject archived. Any that were live leave your public catalog at the '
          'next publish.',
    BulkProductAction.restore => '$subject restored.',
    BulkProductAction.delete =>
      '$subject deleted. Any that were live will be removed from your public '
          'catalog at the next publish.',
    BulkProductAction.setCategory => '$subject moved.',
  };
}
