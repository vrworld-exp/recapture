// lib/presentation/widgets/delete_confirmation_modal.dart
import 'package:flutter/cupertino.dart'
    show
        CupertinoActionSheet,
        CupertinoActionSheetAction,
        showCupertinoModalPopup;
import 'package:flutter/material.dart';

import '../../app/theme/app_colors.dart';
import '../../app/theme/app_spacing.dart';
import '../../domain/entities/confirm_kind.dart';
import '../../platform/haptics.dart';

// Re-exported so callers that import this modal keep seeing [ConfirmKind] (it now
// lives in the domain layer so the application layer can share it without
// depending on presentation).
export '../../domain/entities/confirm_kind.dart';

/// Platform-idiomatic destructive-confirmation modal, reusable for Delete and
/// Retake. Returns `true` only on a deliberate confirm; ANY dismissal (system
/// back, tap-outside, iOS Cancel/backdrop) resolves to `false`.
///
///   - Android (and default) → Material [AlertDialog]
///   - iOS / macOS           → [CupertinoActionSheet] with a destructive action
///
/// Branches on `Theme.of(context).platform` (NOT `Platform.isIOS`) so tests can
/// force either side via `Theme`/`debugDefaultTargetPlatformOverride`, mirroring
/// the checklist tip-sheet convention.
///
/// DECOUPLED: it confirms only — it performs no deletion/storage/coverage work.
/// The caller awaits and acts on `true`. The message is counted + pluralized; the
/// reversibility wording matches the actual behavior (delete is final → "can't be
/// undone"; retake re-shoots → "replaced", no false permanence claim). There is
/// no l10n framework in this repo, so plurals are resolved in Dart (the existing
/// convention — see `save_exit_modal.dart`); swap to ARB plurals if l10n lands.
///
/// [count] must be `>= 1` (Delete/Retake are selection-gated). A `count <= 0`
/// call is a no-op that resolves `false` without showing anything.
Future<bool> showDeleteConfirmation(
  BuildContext context, {
  required int count,
  ConfirmKind kind = ConfirmKind.delete,
}) {
  if (count <= 0) return Future<bool>.value(false); // guard: never show

  final platform = Theme.of(context).platform;
  final isCupertino =
      platform == TargetPlatform.iOS || platform == TargetPlatform.macOS;
  final copy = _ConfirmCopy.of(kind, count);

  // Synchronous (no await before the present call) so no BuildContext crosses an
  // async gap — mirrors `checklist_tooltip_sheet.dart`'s non-async style.
  final Future<bool?> shown = isCupertino
      ? showCupertinoModalPopup<bool>(
          context: context,
          barrierColor: AppColors.scrim,
          builder: (ctx) => _CupertinoConfirm(copy: copy),
        )
      : showDialog<bool>(
          context: context,
          barrierDismissible: true, // tap-outside == cancel
          barrierColor: AppColors.scrim,
          builder: (ctx) => _MaterialConfirm(copy: copy),
        );

  return shown.then((result) => result ?? false); // any dismissal == cancelled
}

/// The platform-neutral wording for one confirmation. Plurals + reversibility are
/// resolved here so both platform surfaces render identical text.
class _ConfirmCopy {
  const _ConfirmCopy({
    required this.title,
    required this.message,
    required this.confirmLabel,
  });

  final String title;
  final String message;
  final String confirmLabel;

  factory _ConfirmCopy.of(ConfirmKind kind, int count) {
    final photos = count == 1 ? '1 photo' : '$count photos';
    switch (kind) {
      case ConfirmKind.delete:
        return _ConfirmCopy(
          title: count == 1 ? 'Delete photo?' : 'Delete photos?',
          // Deletion is final in this app (no undo) → permanence is accurate.
          message: "Delete $photos? This can't be undone.",
          confirmLabel: 'Delete',
        );
      case ConfirmKind.retake:
        final shots = count == 1 ? 'shot' : 'shots';
        return _ConfirmCopy(
          title: count == 1 ? 'Retake photo?' : 'Retake photos?',
          // Retake re-shoots: the existing shot is replaced, not "lost forever",
          // so no permanence claim.
          message: 'Retake $photos? Your current $shots will be replaced.',
          confirmLabel: 'Retake',
        );
    }
  }
}

/// Android: a Material [AlertDialog]. Cancel is listed first (safe), Delete is
/// destructive-styled (danger colour). A dismissal (back / tap-outside) returns
/// null → `false`. Each action pops on the first tap, so a rapid double-tap
/// resolves only once.
class _MaterialConfirm extends StatelessWidget {
  const _MaterialConfirm({required this.copy});

  final _ConfirmCopy copy;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return AlertDialog(
      backgroundColor: AppColors.surface1,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppRadius.md),
      ),
      title: Text(copy.title, style: theme.textTheme.titleLarge),
      content: Text(
        copy.message,
        style: theme.textTheme.bodyMedium
            ?.copyWith(color: AppColors.textSecondary),
      ),
      actions: [
        TextButton(
          // Safe choice — the one a stray dismiss resolves to as well.
          onPressed: () => Navigator.of(context).pop(false),
          child: Text(
            'Cancel',
            style: TextStyle(color: AppColors.textSecondary),
          ),
        ),
        TextButton(
          style: TextButton.styleFrom(foregroundColor: AppColors.error),
          onPressed: () {
            Haptics.failed(); // destructive confirm
            Navigator.of(context).pop(true);
          },
          child: Text(copy.confirmLabel),
        ),
      ],
    );
  }
}

/// iOS/macOS: a [CupertinoActionSheet] with a red `isDestructiveAction` confirm
/// and an emphasized `isDefaultAction` Cancel. Backdrop/cancel returns null →
/// `false`.
class _CupertinoConfirm extends StatelessWidget {
  const _CupertinoConfirm({required this.copy});

  final _ConfirmCopy copy;

  @override
  Widget build(BuildContext context) {
    return CupertinoActionSheet(
      title: Text(copy.title),
      message: Text(copy.message),
      actions: [
        CupertinoActionSheetAction(
          isDestructiveAction: true,
          onPressed: () {
            Haptics.failed();
            Navigator.of(context).pop(true);
          },
          child: Text(copy.confirmLabel),
        ),
      ],
      cancelButton: CupertinoActionSheetAction(
        isDefaultAction: true, // safe default emphasis
        onPressed: () => Navigator.of(context).pop(false),
        child: const Text('Cancel'),
      ),
    );
  }
}
