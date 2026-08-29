// lib/presentation/widgets/save_exit_modal.dart
import 'package:flutter/material.dart';

import '../../app/theme/app_colors.dart';
import '../../app/theme/app_spacing.dart';
import '../../domain/entities/save_exit_decision.dart';
import '../../platform/haptics.dart';
import '../../utils/analytics.dart';
import '../../utils/platform_name.dart';

/// Shows the Save & Exit confirmation and resolves to a [SaveExitChoice]. ANY
/// dismissal (tap-outside, system back) resolves to [SaveExitChoice.cancel] —
/// never an accidental exit/discard.
///
/// Presentational + intent only: it returns the choice and emits analytics; the
/// parent performs the save-as-draft / discard / navigation. Emits
/// `save_exit_prompt_shown` when shown and `save_exit_choice` once resolved
/// (including dismissal-as-cancel), so every outcome is logged in one place.
Future<SaveExitChoice> showSaveExitConfirmation(
  BuildContext context, {
  required SaveExitContext ctx,
}) async {
  final deviceType = appPlatformName;

  Analytics.logEvent(AnalyticsEvents.saveExitPromptShown, {
    'captured_count': ctx.capturedCount,
    'device_type': deviceType,
  });

  final result = await showDialog<SaveExitChoice>(
    context: context,
    barrierDismissible: true, // tapping outside == cancel
    barrierColor: AppColors.scrim,
    builder: (_) => SaveExitModal(ctx: ctx),
  );
  final choice = result ?? SaveExitChoice.cancel; // any dismissal == cancel

  Analytics.logEvent(AnalyticsEvents.saveExitChoice, {
    'choice': _choiceKey(choice),
    'captured_count': ctx.capturedCount,
  });
  return choice;
}

String _choiceKey(SaveExitChoice c) {
  switch (c) {
    case SaveExitChoice.saveExit:
      return 'save_exit';
    case SaveExitChoice.discardExit:
      return 'discard_exit';
    case SaveExitChoice.cancel:
      return 'cancel';
  }
}

/// The confirmation dialog: a context line over three clearly-ranked actions —
/// Save & Exit (primary, safe), Discard & Exit (destructive, Mirage Red), and
/// Cancel (neutral). Each pops the dialog with its [SaveExitChoice]; the dialog
/// closes on the first tap so a rapid double-tap resolves only once.
class SaveExitModal extends StatelessWidget {
  const SaveExitModal({super.key, required this.ctx});

  final SaveExitContext ctx;

  void _resolve(BuildContext context, SaveExitChoice choice) {
    if (choice == SaveExitChoice.discardExit) {
      Haptics.failed(); // destructive confirm
    }
    Navigator.of(context).pop(choice);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final count = ctx.capturedCount;
    final photos = count == 1 ? '1 photo' : '$count photos';

    return AlertDialog(
      backgroundColor: AppColors.surface1,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppRadius.md),
      ),
      title: Text('Save your progress?', style: theme.textTheme.titleLarge),
      content: Text(
        "You've captured $photos. Save them as a draft to continue later, "
        'or discard this session.',
        style: theme.textTheme.bodyMedium
            ?.copyWith(color: AppColors.textSecondary),
      ),
      // A Column keeps the three buttons full-width and clearly ranked rather
      // than cramped into a row that overflows on small screens.
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
            SizedBox(
              width: double.infinity,
              child: FilledButton(
                style: FilledButton.styleFrom(
                  backgroundColor: AppColors.mirageRed,
                  foregroundColor: AppColors.textPrimary,
                ),
                onPressed: () => _resolve(context, SaveExitChoice.saveExit),
                child: const Text('Save & Exit'),
              ),
            ),
            const SizedBox(height: AppSpacing.sm),
            SizedBox(
              width: double.infinity,
              child: TextButton(
                style: TextButton.styleFrom(
                  foregroundColor: AppColors.error,
                ),
                onPressed: () => _resolve(context, SaveExitChoice.discardExit),
                child: const Text('Discard & Exit'),
              ),
            ),
            SizedBox(
              width: double.infinity,
              child: TextButton(
                style: TextButton.styleFrom(
                  foregroundColor: AppColors.textSecondary,
                ),
                onPressed: () => _resolve(context, SaveExitChoice.cancel),
                child: const Text('Keep Capturing'),
              ),
            ),
          ],
        ),
      ],
    );
  }
}
