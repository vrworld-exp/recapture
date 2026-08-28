// lib/presentation/screens/catalog/delete_catalog_dialog.dart
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/theme/app_colors.dart';
import '../../../app/theme/app_spacing.dart';
import '../../../application/catalog/catalog_notifier.dart';
import '../../../data/repositories/catalog_failure.dart';
import '../../../data/repositories/catalog_repository.dart';
import '../../../domain/entities/catalog.dart';
import '../../widgets/app_button.dart';
import '../../widgets/app_text_field.dart';
import '../../widgets/catalog/catalog_feedback.dart';

/// Asks the user to delete their whole catalog, and does it. Resolves to a
/// [CatalogDeletionSummary] on success, or null if they backed out.
///
/// ⚠ THIS IS NOT UNPUBLISH. Unpublish takes the page offline and keeps the link,
/// so a printed sticker starts working again the moment the user republishes.
/// This gives the link up: the catalog, its products and its public page all go,
/// and the next catalog is issued a NEW URL. Anything already printed stops
/// resolving for good. The copy below says exactly that, because a business that
/// confuses the two loses its stickers.
Future<CatalogDeletionSummary?> showDeleteCatalogDialog(
  BuildContext context,
  Catalog catalog,
) =>
    showDialog<CatalogDeletionSummary>(
      context: context,
      barrierColor: AppColors.scrim,
      // Routed through maybePop, so the PopScope can still veto it mid-request.
      barrierDismissible: true,
      builder: (_) => DeleteCatalogDialog(catalog: catalog),
    );

/// The confirmation form.
///
/// The request is issued from INSIDE the dialog, like [CreateCatalogDialog], so
/// a failure reappears here rather than as a toast on a screen that has already
/// moved on — and the user does not have to find the button again to retry.
class DeleteCatalogDialog extends ConsumerStatefulWidget {
  const DeleteCatalogDialog({super.key, required this.catalog});

  final Catalog catalog;

  @override
  ConsumerState<DeleteCatalogDialog> createState() =>
      _DeleteCatalogDialogState();
}

class _DeleteCatalogDialogState extends ConsumerState<DeleteCatalogDialog> {
  final _confirmController = TextEditingController();

  bool _submitting = false;
  String? _failureMessage;

  @override
  void initState() {
    super.initState();
    // Rebuilds on every keystroke so the destructive button arms the moment the
    // name matches — a Delete that stays grey with the right name typed reads
    // as broken.
    _confirmController.addListener(_onTyped);
  }

  @override
  void dispose() {
    _confirmController
      ..removeListener(_onTyped)
      ..dispose();
    super.dispose();
  }

  void _onTyped() => setState(() => _failureMessage = null);

  /// Case- and whitespace-insensitive: the user is retyping a name they can see,
  /// and this is a speed bump against a misplaced tap — not an auth check. A
  /// stricter match would only punish someone who is already sure.
  bool get _isArmed =>
      _confirmController.text.trim().toLowerCase() ==
      widget.catalog.name.trim().toLowerCase();

  Future<void> _submit() async {
    if (_submitting || !_isArmed) return;

    setState(() {
      _submitting = true;
      _failureMessage = null;
    });

    // Resolved before the await: ref belongs to this State, and the delete must
    // land in the notifier even if the dialog goes away underneath it.
    final notifier = ref.read(catalogProvider.notifier);

    try {
      final summary = await notifier.delete();
      if (!mounted) return;
      Navigator.of(context).pop(summary);
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _submitting = false;
        // From the CODE, never the server's prose — the one catalog table.
        // MIRAGE_UNAVAILABLE is the one worth reading here: it means nothing was
        // deleted, so the retry below is genuinely all that is needed.
        _failureMessage = error is CatalogFailure
            ? CatalogFeedback.failureText(error)
            : CatalogFeedback.textForCode(null);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final catalog = widget.catalog;
    final counts = catalog.counts;

    return PopScope(
      // Only while the request is running. A dialog that vanished mid-delete
      // would leave the user unsure whether their catalog still exists.
      canPop: !_submitting,
      child: AlertDialog(
        backgroundColor: AppColors.surface1,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppRadius.md),
        ),
        scrollable: true,
        title: Row(
          children: [
            const Icon(Icons.warning_amber_rounded, color: AppColors.error),
            const SizedBox(width: AppSpacing.sm),
            Expanded(
              child: Text('Delete this catalog?', style: theme.textTheme.titleLarge),
            ),
          ],
        ),
        content: SizedBox(
          width: 360,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                'This deletes ${catalog.name} and everything in it. '
                'It cannot be undone.',
                style: theme.textTheme.bodyMedium
                    ?.copyWith(color: AppColors.textSecondary, height: 1.5),
              ),
              const SizedBox(height: AppSpacing.lg),
              _WhatGoes(
                lines: [
                  '${counts.products} '
                      '${counts.products == 1 ? 'product' : 'products'}'
                      '${counts.archivedProducts > 0 ? ' (plus ${counts.archivedProducts} archived)' : ''}',
                  '${counts.categories} '
                      '${counts.categories == 1 ? 'category' : 'categories'}',
                  // Only when there IS a live page. Before the first publish
                  // there is no URL and no printed code, and listing one would
                  // be a scare with nothing behind it.
                  if (catalog.isProvisioned)
                    'Your public page and its QR code — printed codes will stop '
                        'working',
                ],
              ),
              if (catalog.isProvisioned) ...[
                const SizedBox(height: AppSpacing.lg),
                Text(
                  'A new catalog gets a NEW link. If you only want to take the '
                  'page offline for a while, use Publish → Take offline instead '
                  '— that keeps your link and your printed codes.',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: AppColors.textMuted,
                    height: 1.5,
                  ),
                ),
              ],
              const SizedBox(height: AppSpacing.xxl),
              AppTextField(
                label: 'Type "${catalog.name}" to confirm',
                hint: catalog.name,
                controller: _confirmController,
                autofocus: true,
                enabled: !_submitting,
                textInputAction: TextInputAction.done,
                // Enter submits only once the name matches; _submit re-checks.
                onFieldSubmitted: (_) => _submit(),
              ),
              if (_failureMessage != null) ...[
                const SizedBox(height: AppSpacing.lg),
                Text(
                  _failureMessage!,
                  style: theme.textTheme.bodySmall
                      ?.copyWith(color: AppColors.error),
                ),
              ],
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: _submitting ? null : () => Navigator.of(context).pop(),
            child: Text(
              'Cancel',
              style: TextStyle(color: AppColors.textSecondary),
            ),
          ),
          // Filled red rather than the outlined secondary: this is the
          // destructive action and it should not look like a peer of Cancel.
          // Disabled until the name matches.
          AppButton(
            label: 'Delete catalog',
            isFullWidth: false,
            isLoading: _submitting,
            onPressed: _isArmed ? _submit : null,
          ),
        ],
      ),
    );
  }
}

/// The itemised "this is what goes" list.
///
/// Spelled out rather than summarised as "and all its data": a user deleting a
/// catalog to start over is usually not certain what they are giving up, and the
/// count of products is the thing that makes them pause if they should.
class _WhatGoes extends StatelessWidget {
  const _WhatGoes({required this.lines});

  final List<String> lines;

  @override
  Widget build(BuildContext context) {
    final style = Theme.of(context)
        .textTheme
        .bodySmall
        ?.copyWith(color: AppColors.error, height: 1.5);

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(AppSpacing.md),
      decoration: BoxDecoration(
        color: AppColors.error.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(AppRadius.xs),
        border: Border.all(color: AppColors.error.withValues(alpha: 0.3)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final line in lines)
            Padding(
              padding: const EdgeInsets.only(bottom: AppSpacing.xs),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('•  ', style: style),
                  Expanded(child: Text(line, style: style)),
                ],
              ),
            ),
        ],
      ),
    );
  }
}
