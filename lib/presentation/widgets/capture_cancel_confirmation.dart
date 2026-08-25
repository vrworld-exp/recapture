// lib/presentation/widgets/capture_cancel_confirmation.dart
//
// The "Cancel → Keep as Draft" confirmation shown when the user leaves the
// Capture Summary / Uploading step. Mirrors the app's standard leave-flow
// confirmation (SaveExitModal): a Material [AlertDialog] with a full-width Column
// of clearly-ranked actions so it lays out without overflow on small/low-end
// screens. Reassuring by default — the PRIMARY, emphasised choice keeps the work.
//
//   • Keep as Draft (primary, safe)      → [CaptureCancelChoice.keepDraft]
//   • Discard captures (destructive)     → [CaptureCancelChoice.discard]
//   • Keep editing (neutral, dismiss)    → [CaptureCancelChoice.keepEditing]
//
// Presentational + intent only: it returns the choice and touches NO state — the
// caller persists / deletes / navigates and owns the analytics (Keep as Draft
// fires its success event only AFTER the save succeeds). ANY dismissal
// (tap-outside, system back on the dialog) resolves to [keepEditing], so a stray
// dismiss never leaves the flow or loses data.
import 'package:flutter/material.dart';

import '../../app/theme/app_colors.dart';
import '../../app/theme/app_spacing.dart';
import '../../domain/capture/capture_cancel.dart';
import '../../platform/haptics.dart';

/// Shows the cancel confirmation and resolves to the user's [CaptureCancelChoice].
/// Dismissal (barrier tap / system back) resolves to [CaptureCancelChoice.keepEditing].
Future<CaptureCancelChoice> showCaptureCancelConfirmation(
  BuildContext context,
) async {
  final result = await showDialog<CaptureCancelChoice>(
    context: context,
    barrierDismissible: true, // tap-outside == keep editing (safe default)
    barrierColor: AppColors.scrim,
    builder: (_) => const _CaptureCancelDialog(),
  );
  return result ?? CaptureCancelChoice.keepEditing; // any dismissal == keep editing
}

class _CaptureCancelDialog extends StatelessWidget {
  const _CaptureCancelDialog();

  void _resolve(BuildContext context, CaptureCancelChoice choice) {
    if (choice == CaptureCancelChoice.discard) {
      Haptics.failed(); // destructive confirm
    }
    Navigator.of(context).pop(choice);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return AlertDialog(
      key: const Key('capture_cancel_dialog'),
      backgroundColor: AppColors.surface1,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppRadius.md),
      ),
      title: Text('Leave capture?', style: theme.textTheme.titleLarge),
      content: Text(
        "We'll keep your progress as a draft so you can finish it later. "
        'Nothing is lost unless you choose to discard.',
        style: theme.textTheme.bodyMedium
            ?.copyWith(color: AppColors.textSecondary),
      ),
      // A Column keeps the three actions full-width and clearly ranked rather than
      // a cramped row that overflows on small screens.
      actionsPadding: const EdgeInsets.fromLTRB(
        AppSpacing.lg,
        0,
        AppSpacing.lg,
        AppSpacing.lg,
      ),
      actions: [
        Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // PRIMARY, emphasised safe choice.
            SizedBox(
              width: double.infinity,
              child: FilledButton(
                key: const Key('cancel_keep_draft'),
                style: FilledButton.styleFrom(
                  backgroundColor: AppColors.mirageRed,
                  foregroundColor: AppColors.textPrimary,
                ),
                onPressed: () =>
                    _resolve(context, CaptureCancelChoice.keepDraft),
                child: const Text('Keep as Draft'),
              ),
            ),
            const SizedBox(height: AppSpacing.sm),
            // DESTRUCTIVE — the only path that deletes captures.
            SizedBox(
              width: double.infinity,
              child: TextButton(
                key: const Key('cancel_discard'),
                style: TextButton.styleFrom(foregroundColor: AppColors.error),
                onPressed: () =>
                    _resolve(context, CaptureCancelChoice.discard),
                child: const Text('Discard captures'),
              ),
            ),
            // NEUTRAL dismiss — return to the summary unchanged.
            SizedBox(
              width: double.infinity,
              child: TextButton(
                key: const Key('cancel_keep_editing'),
                style:
                    TextButton.styleFrom(foregroundColor: AppColors.textSecondary),
                onPressed: () =>
                    _resolve(context, CaptureCancelChoice.keepEditing),
                child: const Text('Keep editing'),
              ),
            ),
          ],
        ),
      ],
    );
  }
}
