// lib/presentation/widgets/rep/admin_publish_bar.dart
//
// The ADMIN's two buttons at the foot of the publish screen:
//
//   • "Publish by admin" — publishes whatever the restaurant's plan says. The
//     server lifts the SUBSCRIPTION gate for an admin and nothing else, so it
//     is enabled exactly when no CONTENT gate stands (an empty menu, a dish
//     with no picture, a model still generating) — those Mirage cannot take,
//     whoever presses.
//   • "Unpublish by admin" — takes a LIVE menu offline, behind a dialog that
//     requires a reason. The reason is shown to the owner.
//
// Both drive the same [PublishFlow] as the screen's own Publish button, so the
// progress, the failures and the "it is live" toast are the ones above.
//
// Rendered only for an ADMIN; the screen decides that, and the server refuses
// anyone else with 403 regardless.
import 'package:flutter/material.dart';

import '../../../app/theme/app_colors.dart';
import '../../../app/theme/app_spacing.dart';
import '../../../app/theme/app_typography.dart';
import '../../../application/catalog/publish_flow.dart';
import '../../../domain/catalog/publish_status.dart';
import '../app_button.dart';

/// The reason's bounds — the server's (`adminUnpublishSchema`).
const int kAdminUnpublishReasonMin = 5;
const int kAdminUnpublishReasonMax = 500;

class AdminPublishBar extends StatelessWidget {
  const AdminPublishBar({
    super.key,
    required this.state,
    required this.status,
    required this.isOnline,
    required this.onPublish,
    required this.onUnpublish,
  });

  final PublishScreenState state;
  final PublishStatus status;
  final bool isOnline;
  final VoidCallback onPublish;
  final VoidCallback onUnpublish;

  /// Why the publish button is off, in one line — or null when it is on.
  String? get _publishBlockedBecause {
    if (!isOnline) return 'You are offline.';
    if (status.isPublishing) {
      return 'A publish is running — wait for it to finish.';
    }
    if (!status.canAdminPublish) {
      return 'Fix the items above first. An admin publish skips only the plan '
          'check.';
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final busy = state.isRequesting;
    final publishBlocked = _publishBlockedBecause;
    final canPublish = publishBlocked == null && !busy;
    final canUnpublish = isOnline && status.canAdminUnpublish && !busy;

    return Material(
      key: const ValueKey('admin_publish_bar'),
      color: AppColors.surface1,
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(
            AppSpacing.lg,
            AppSpacing.md,
            AppSpacing.lg,
            AppSpacing.md,
          ),
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 560),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const Row(
                    children: [
                      Icon(Icons.admin_panel_settings_outlined,
                          size: 14, color: AppColors.textMuted),
                      SizedBox(width: AppSpacing.xs),
                      Text(
                        'Admin actions',
                        style: TextStyle(
                          fontSize: AppTypography.sizeLabel,
                          color: AppColors.textMuted,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: AppSpacing.sm),
                  // Side by side when there is room, stacked on a narrow
                  // phone — two full labels never fit 320 px together.
                  LayoutBuilder(builder: (context, constraints) {
                    final publish = AppButton(
                      key: const ValueKey('admin_publish_button'),
                      label: 'Publish by admin',
                      onPressed: canPublish ? onPublish : null,
                    );
                    final unpublish = AppButton.secondary(
                      key: const ValueKey('admin_unpublish_button'),
                      label: 'Unpublish by admin',
                      onPressed: canUnpublish ? onUnpublish : null,
                    );
                    if (constraints.maxWidth < 420) {
                      return Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          publish,
                          const SizedBox(height: AppSpacing.sm),
                          unpublish,
                        ],
                      );
                    }
                    return Row(
                      children: [
                        Expanded(child: publish),
                        const SizedBox(width: AppSpacing.sm),
                        Expanded(child: unpublish),
                      ],
                    );
                  }),
                  if (publishBlocked != null && !busy) ...[
                    const SizedBox(height: AppSpacing.xs),
                    Text(
                      publishBlocked,
                      key: const ValueKey('admin_publish_hint'),
                      style: const TextStyle(
                        fontSize: AppTypography.sizeLabel,
                        color: AppColors.textMuted,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Asks for the reason and takes the menu offline.
///
/// [onSubmit] performs the request and answers null on success (the dialog
/// closes) or the sentence to show (the dialog stays open, the reason kept, so
/// a dropped connection does not cost the admin what they typed). Returns
/// whether the menu was taken offline.
Future<bool> showAdminUnpublishDialog(
  BuildContext context, {
  required String restaurantName,
  required Future<String?> Function(String reason) onSubmit,
}) async {
  final done = await showDialog<bool>(
    context: context,
    // Not dismissible by a stray tap: the admin is typing a sentence the owner
    // will read, and losing it to a mis-tap outside the box is maddening.
    barrierDismissible: false,
    builder: (_) => _AdminUnpublishDialog(
      restaurantName: restaurantName,
      onSubmit: onSubmit,
    ),
  );
  return done ?? false;
}

class _AdminUnpublishDialog extends StatefulWidget {
  const _AdminUnpublishDialog({
    required this.restaurantName,
    required this.onSubmit,
  });

  final String restaurantName;
  final Future<String?> Function(String reason) onSubmit;

  @override
  State<_AdminUnpublishDialog> createState() => _AdminUnpublishDialogState();
}

class _AdminUnpublishDialogState extends State<_AdminUnpublishDialog> {
  final _reason = TextEditingController();
  bool _submitting = false;
  String? _error;

  @override
  void dispose() {
    _reason.dispose();
    super.dispose();
  }

  bool get _valid => _reason.text.trim().length >= kAdminUnpublishReasonMin;

  Future<void> _submit() async {
    if (!_valid || _submitting) return;
    setState(() {
      _submitting = true;
      _error = null;
    });
    final error = await widget.onSubmit(_reason.text.trim());
    if (!mounted) return;
    if (error == null) {
      Navigator.of(context).pop(true);
      return;
    }
    setState(() {
      _submitting = false;
      _error = error;
    });
  }

  @override
  Widget build(BuildContext context) {
    final trimmed = _reason.text.trim().length;
    return PopScope(
      // No back-button escape mid-request either: the answer is on its way and
      // the screen behind needs it.
      canPop: !_submitting,
      child: AlertDialog(
        key: const ValueKey('admin_unpublish_dialog'),
        backgroundColor: AppColors.surface1,
        title: const Text('Unpublish this menu?'),
        content: SizedBox(
          width: 420,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '${widget.restaurantName} will go offline for customers. '
                  'The link and every printed QR keep working once it is '
                  'published again. The owner will see your reason.',
                  style: const TextStyle(
                    fontSize: AppTypography.sizeBody,
                    color: AppColors.textSecondary,
                  ),
                ),
                const SizedBox(height: AppSpacing.md),
                TextField(
                  key: const ValueKey('admin_unpublish_reason'),
                  controller: _reason,
                  enabled: !_submitting,
                  autofocus: true,
                  minLines: 3,
                  maxLines: 6,
                  maxLength: kAdminUnpublishReasonMax,
                  textCapitalization: TextCapitalization.sentences,
                  onChanged: (_) => setState(() => _error = null),
                  decoration: InputDecoration(
                    labelText: 'Reason',
                    hintText: 'e.g. Prices on the menu are out of date',
                    alignLabelWithHint: true,
                    helperText:
                        trimmed > 0 && trimmed < kAdminUnpublishReasonMin
                            ? 'At least $kAdminUnpublishReasonMin characters.'
                            : null,
                    errorText: _error,
                    errorMaxLines: 4,
                  ),
                ),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            key: const ValueKey('admin_unpublish_cancel'),
            onPressed:
                _submitting ? null : () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            key: const ValueKey('admin_unpublish_confirm'),
            style: FilledButton.styleFrom(backgroundColor: AppColors.error),
            onPressed: _valid && !_submitting ? _submit : null,
            child: _submitting
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Text('Unpublish'),
          ),
        ],
      ),
    );
  }
}
