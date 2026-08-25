// lib/presentation/widgets/upload_cancel_confirmation.dart
import 'package:flutter/cupertino.dart'
    show
        CupertinoActionSheet,
        CupertinoActionSheetAction,
        showCupertinoModalPopup;
import 'package:flutter/material.dart';

import '../../app/theme/app_colors.dart';
import '../../app/theme/app_spacing.dart';
import '../../platform/haptics.dart';

/// Platform-idiomatic confirmation for cancelling an in-progress (or paused)
/// upload. Mirrors the delete-confirmation pattern (showDeleteConfirmation):
///
///   - Android (and default) → Material [AlertDialog]
///   - iOS / macOS           → [CupertinoActionSheet] with a destructive action
///
/// Branches on `Theme.of(context).platform` (NOT `Platform.isIOS`) so tests can
/// force either side. Returns `true` only on a deliberate confirm; ANY dismissal
/// (system back, tap-outside, iOS Cancel/backdrop) resolves to `false`.
///
/// The wording makes the RETAIN semantics explicit: cancelling aborts the
/// TRANSFER and loses the upload progress, but the captured photos stay on the
/// device and can be uploaded later. This is NOT a delete — there is no "can't be
/// undone" permanence claim about the captured data.
///
/// DECOUPLED: it confirms only — it signals nothing and aborts nothing. The
/// caller awaits and, on `true`, signals the pipeline to cancel.
Future<bool> showUploadCancelConfirmation(BuildContext context) {
  final platform = Theme.of(context).platform;
  final isCupertino =
      platform == TargetPlatform.iOS || platform == TargetPlatform.macOS;

  const title = 'Cancel upload?';
  const message =
      "You'll lose the upload progress, but your captured photos stay on this "
      'device and can be uploaded later.';
  const confirmLabel = 'Cancel upload';
  const keepLabel = 'Keep uploading';

  // Synchronous (no await before the present call) so no BuildContext crosses an
  // async gap — mirrors showDeleteConfirmation's non-async style.
  final Future<bool?> shown = isCupertino
      ? showCupertinoModalPopup<bool>(
          context: context,
          barrierColor: AppColors.scrim,
          builder: (ctx) => CupertinoActionSheet(
            title: const Text(title),
            message: const Text(message),
            actions: [
              CupertinoActionSheetAction(
                isDestructiveAction: true,
                onPressed: () {
                  Haptics.failed();
                  Navigator.of(ctx).pop(true);
                },
                child: const Text(confirmLabel),
              ),
            ],
            cancelButton: CupertinoActionSheetAction(
              isDefaultAction: true, // safe default emphasis: keep uploading
              onPressed: () => Navigator.of(ctx).pop(false),
              child: const Text(keepLabel),
            ),
          ),
        )
      : showDialog<bool>(
          context: context,
          barrierDismissible: true, // tap-outside == keep uploading
          barrierColor: AppColors.scrim,
          builder: (ctx) {
            final theme = Theme.of(ctx);
            return AlertDialog(
              backgroundColor: AppColors.surface1,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(AppRadius.md),
              ),
              title: Text(title, style: theme.textTheme.titleLarge),
              content: Text(
                message,
                style: theme.textTheme.bodyMedium
                    ?.copyWith(color: AppColors.textSecondary),
              ),
              actions: [
                TextButton(
                  // Safe choice — the one a stray dismiss resolves to as well.
                  onPressed: () => Navigator.of(ctx).pop(false),
                  child: Text(
                    keepLabel,
                    style: TextStyle(color: AppColors.textSecondary),
                  ),
                ),
                TextButton(
                  style: TextButton.styleFrom(foregroundColor: AppColors.error),
                  onPressed: () {
                    Haptics.failed();
                    Navigator.of(ctx).pop(true);
                  },
                  child: const Text(confirmLabel),
                ),
              ],
            );
          },
        );

  return shown.then((result) => result ?? false); // any dismissal == kept
}
