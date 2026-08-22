// lib/presentation/widgets/catalog/typed_confirm_dialog.dart
//
// The confirmation for a destructive catalog action that CANNOT be undone.
//
// Why this is not `delete_confirmation_modal.dart`: that modal is the
// selection-gated photo idiom — it counts photos, it pluralises its own copy
// from a closed [ConfirmKind] enum, and it presents as a Cupertino action sheet
// on iOS. None of that survives contact with a typed gate: an action sheet has
// no text field, and "type the product's name" is the whole point here. So this
// is the same visual language (AppColors, AppRadius, the safe-choice-first
// button order, any dismissal resolving to false) with the one thing added that
// the photo modal cannot express.
//
// The typed gate exists because a permanent product delete has no undo and, for
// a published product, reaches past ReCapture into the live catalog. A single
// misplaced tap must not be able to do that.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../app/theme/app_colors.dart';
import '../../../app/theme/app_spacing.dart';
import '../../../platform/haptics.dart';

/// Shows a destructive confirmation gated on the user typing [confirmationText].
///
/// Resolves `true` only when the user typed the phrase AND pressed the confirm
/// button (or Enter, which is the same action). Every dismissal — Escape,
/// system back, tap-outside, Cancel — resolves `false`.
///
/// Matching is trimmed and case-insensitive. The gate is there to make the act
/// deliberate, not to test typing accuracy: rejecting "chair 02" for "Chair 02"
/// would only teach the user to paste.
///
/// [warnings] are the consequences, one per line, shown above the field. Pass
/// the live-catalog sentence here when the product is published — the user has
/// to read it before the field, not after.
Future<bool> showTypedConfirmDialog(
  BuildContext context, {
  required String title,
  required String body,
  required String confirmationText,
  List<String> warnings = const <String>[],
  String confirmLabel = 'Delete',
  String hintText = 'Product name',
}) async {
  final result = await showDialog<bool>(
    context: context,
    barrierDismissible: true, // tap-outside == cancel
    barrierColor: AppColors.scrim,
    builder: (_) => _TypedConfirmDialog(
      title: title,
      body: body,
      confirmationText: confirmationText,
      warnings: warnings,
      confirmLabel: confirmLabel,
      hintText: hintText,
    ),
  );
  return result ?? false;
}

class _TypedConfirmDialog extends StatefulWidget {
  const _TypedConfirmDialog({
    required this.title,
    required this.body,
    required this.confirmationText,
    required this.warnings,
    required this.confirmLabel,
    required this.hintText,
  });

  final String title;
  final String body;
  final String confirmationText;
  final List<String> warnings;
  final String confirmLabel;

  /// What the field is asking for. A bulk delete has no single product name to
  /// type, so the phrase — and therefore the hint — is not always a name.
  final String hintText;

  @override
  State<_TypedConfirmDialog> createState() => _TypedConfirmDialogState();
}

class _TypedConfirmDialogState extends State<_TypedConfirmDialog> {
  final TextEditingController _controller = TextEditingController();
  bool _matches = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _onChanged(String value) {
    final matches = value.trim().toLowerCase() ==
        widget.confirmationText.trim().toLowerCase();
    if (matches != _matches) setState(() => _matches = matches);
  }

  void _confirm() {
    if (!_matches) return;
    Haptics.failed(); // destructive confirm
    Navigator.of(context).pop(true);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return CallbackShortcuts(
      // Escape cancels. On web this is the only keyboard exit a modal gets for
      // free that matches what a browser user expects; on mobile the system
      // back gesture already resolves to the same false.
      bindings: {
        const SingleActivator(LogicalKeyboardKey.escape): () =>
            Navigator.of(context).pop(false),
      },
      child: AlertDialog(
        backgroundColor: AppColors.surface1,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppRadius.md),
        ),
        title: Text(widget.title, style: theme.textTheme.titleLarge),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              widget.body,
              style: theme.textTheme.bodyMedium
                  ?.copyWith(color: AppColors.textSecondary, height: 1.4),
            ),
            for (final warning in widget.warnings) ...[
              const SizedBox(height: AppSpacing.md),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Icon(
                    Icons.warning_amber_rounded,
                    size: 16,
                    color: AppColors.warning,
                  ),
                  const SizedBox(width: AppSpacing.sm),
                  Expanded(
                    child: Text(
                      warning,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: AppColors.warning,
                        height: 1.4,
                      ),
                    ),
                  ),
                ],
              ),
            ],
            const SizedBox(height: AppSpacing.lg),
            Text(
              'Type ${widget.confirmationText} to confirm',
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: AppColors.textMuted),
            ),
            const SizedBox(height: AppSpacing.sm),
            TextField(
              controller: _controller,
              autofocus: true,
              autocorrect: false,
              enableSuggestions: false,
              textInputAction: TextInputAction.done,
              onChanged: _onChanged,
              // Enter is the same action as the button, and only when the gate
              // is open — a submit on a half-typed name must do nothing.
              onSubmitted: (_) => _confirm(),
              style: theme.textTheme.bodyLarge,
              decoration: InputDecoration(hintText: widget.hintText),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text(
              'Cancel',
              style: TextStyle(color: AppColors.textSecondary),
            ),
          ),
          TextButton(
            style: TextButton.styleFrom(
              foregroundColor: AppColors.error,
              disabledForegroundColor: AppColors.disabled,
            ),
            // Disabled, not hidden: the user can see the action they are working
            // towards, and why it is not available yet.
            onPressed: _matches ? _confirm : null,
            child: Text(widget.confirmLabel),
          ),
        ],
      ),
    );
  }
}
