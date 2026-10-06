// lib/presentation/widgets/pending_capture_card_parts.dart
//
// How a capture waiting on the phone LOOKS on its project card (offline
// capture, Step C1): the short header pill and the action area (a wrapping
// one-line explanation + the buttons). WHICH label applies is decided by the
// pure `pendingLabelFor` (domain/upload/pending_capture_label.dart); this file
// only maps each kind to copy, theme-token colours and buttons — no logic, no
// hex values.
//
// 360 dp: the header pill carries only a SHORT label (it shares a row with the
// thumbnail, name and ⋮). The full sentence lives in the action area, where it
// may wrap but never overflows.
import 'package:flutter/material.dart';

import '../../app/theme/app_colors.dart';
import '../../app/theme/app_spacing.dart';
import '../../domain/upload/pending_capture_label.dart';
import 'app_button.dart';
import 'app_status_pill.dart';

/// Display mapping for [PendingLabelKind] — same style as
/// `ProjectStatusDisplay`.
extension PendingLabelDisplay on PendingLabelKind {
  /// Short header-pill label. [percent] feeds the uploading label.
  String pillLabel({int? percent}) => switch (this) {
        PendingLabelKind.savedOffline => 'Not uploaded',
        PendingLabelKind.waitingWifi => 'Waiting for Wi-Fi',
        PendingLabelKind.queued => 'Waiting to upload',
        PendingLabelKind.waitingConnection => 'Waiting',
        PendingLabelKind.uploading =>
          percent == null ? 'Uploading' : 'Uploading $percent%',
        PendingLabelKind.paused => 'Paused',
        PendingLabelKind.failed ||
        PendingLabelKind.planLimit ||
        PendingLabelKind.projectMissing ||
        PendingLabelKind.filesMissing =>
          'Upload failed',
        PendingLabelKind.needsLogin => 'Log in to upload',
      };

  /// The full sentence under the card header.
  String sentence({int? percent, String? reason}) => switch (this) {
        PendingLabelKind.savedOffline => 'Saved on phone · Not uploaded',
        PendingLabelKind.waitingWifi => 'Waiting for Wi-Fi',
        PendingLabelKind.queued => 'Saved on phone · Uploading soon',
        PendingLabelKind.waitingConnection => 'Waiting for connection',
        PendingLabelKind.uploading =>
          percent == null ? 'Uploading…' : 'Uploading $percent%',
        PendingLabelKind.paused => 'Paused',
        PendingLabelKind.failed =>
          reason == null ? 'Upload failed' : 'Upload failed · $reason',
        PendingLabelKind.planLimit => 'Plan limit reached — upgrade to upload',
        PendingLabelKind.projectMissing => 'This project no longer exists',
        PendingLabelKind.filesMissing =>
          'Capture files are missing on this phone',
        PendingLabelKind.needsLogin => 'Log in again to upload',
      };

  Color get color => switch (this) {
        PendingLabelKind.savedOffline ||
        PendingLabelKind.waitingWifi ||
        PendingLabelKind.queued ||
        PendingLabelKind.waitingConnection =>
          AppColors.warning,
        PendingLabelKind.uploading => AppColors.royalGold,
        PendingLabelKind.paused => AppColors.textSecondary,
        PendingLabelKind.failed ||
        PendingLabelKind.planLimit ||
        PendingLabelKind.projectMissing ||
        PendingLabelKind.filesMissing ||
        PendingLabelKind.needsLogin =>
          AppColors.error,
      };

  IconData get icon => switch (this) {
        PendingLabelKind.savedOffline => Icons.phone_android,
        PendingLabelKind.waitingWifi => Icons.wifi,
        PendingLabelKind.queued => Icons.schedule,
        PendingLabelKind.waitingConnection => Icons.hourglass_empty,
        PendingLabelKind.uploading => Icons.cloud_upload_outlined,
        PendingLabelKind.paused => Icons.pause_circle_outline,
        PendingLabelKind.failed ||
        PendingLabelKind.planLimit ||
        PendingLabelKind.projectMissing ||
        PendingLabelKind.filesMissing =>
          Icons.warning_amber_rounded,
        PendingLabelKind.needsLogin => Icons.lock_outline,
      };
}

extension PendingCardActionDisplay on PendingCardAction {
  String get label => switch (this) {
        PendingCardAction.uploadNow => 'Upload now',
        PendingCardAction.pause => 'Pause',
        PendingCardAction.resume => 'Resume',
        PendingCardAction.retry => 'Retry',
        PendingCardAction.delete => 'Delete',
        PendingCardAction.uploadAsNew => 'Upload as new project',
        PendingCardAction.logIn => 'Log in',
      };

  IconData get icon => switch (this) {
        PendingCardAction.uploadNow => Icons.cloud_upload_outlined,
        PendingCardAction.pause => Icons.pause,
        PendingCardAction.resume => Icons.play_arrow,
        PendingCardAction.retry => Icons.refresh,
        PendingCardAction.delete => Icons.delete_outline,
        PendingCardAction.uploadAsNew => Icons.add_circle_outline,
        PendingCardAction.logIn => Icons.login,
      };
}

/// Short copy for a failure code on the generic "Upload failed · …" line.
String? pendingFailureReason(String? code) => switch (code) {
      null => null,
      'network' => 'No connection',
      'server' => 'Server problem',
      'auth' => 'Signed out',
      'validation' => 'Upload was rejected',
      'quota' => 'Limit reached',
      _ => 'Try again',
    };

/// The header pill for a pending capture.
class PendingCardPill extends StatelessWidget {
  const PendingCardPill({super.key, required this.kind, this.percent});

  final PendingLabelKind kind;
  final int? percent;

  @override
  Widget build(BuildContext context) => PendingCapturePill(
        key: const Key('pending_pill'),
        label: kind.pillLabel(percent: percent),
        color: kind.color,
        icon: kind.icon,
        pulsing: kind == PendingLabelKind.uploading,
      );
}

/// The action area for a pending capture: the full sentence (wraps) and the
/// buttons. [uploadEnabled] false disables "Upload now" (offline) and shows the
/// "Connect to the internet to upload" tooltip.
class PendingCardActions extends StatelessWidget {
  const PendingCardActions({
    super.key,
    required this.kind,
    required this.onAction,
    this.percent,
    this.reason,
    this.uploadEnabled = true,
    this.busy = false,
  });

  final PendingLabelKind kind;
  final ValueChanged<PendingCardAction> onAction;
  final int? percent;
  final String? reason;
  final bool uploadEnabled;
  final bool busy;

  @override
  Widget build(BuildContext context) {
    final actions = pendingActionsFor(kind);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Icon(kind.icon, size: 16, color: kind.color),
            const SizedBox(width: AppSpacing.sm),
            Expanded(
              child: Text(
                kind.sentence(percent: percent, reason: reason),
                key: const Key('pending_sentence'),
                softWrap: true,
                style: Theme.of(context)
                    .textTheme
                    .bodySmall
                    ?.copyWith(color: kind.color),
              ),
            ),
          ],
        ),
        const SizedBox(height: AppSpacing.sm),
        // One action per full-width row: "Delete" beside "Upload as new
        // project" does not fit a 360 dp card (the button's icon + label do
        // not shrink), so a pair stacks instead of overflowing.
        for (var i = 0; i < actions.length; i++) ...[
          if (i > 0) const SizedBox(height: AppSpacing.sm),
          SizedBox(
            width: double.infinity,
            child: _button(actions[i], primary: i == actions.length - 1),
          ),
        ],
      ],
    );
  }

  Widget _button(PendingCardAction a, {required bool primary}) {
    final disabled = a == PendingCardAction.uploadNow && !uploadEnabled;
    final onPressed = disabled ? null : () => onAction(a);
    final key = Key('pending_action_${a.name}');
    final button = primary && a != PendingCardAction.delete
        ? AppButton(
            key: key,
            label: a.label,
            icon: a.icon,
            isFullWidth: false,
            isLoading: busy,
            onPressed: onPressed,
          )
        : AppButton.secondary(
            key: key,
            label: a.label,
            icon: a.icon,
            isFullWidth: false,
            onPressed: busy ? null : onPressed,
          );
    if (!disabled) return button;
    return Tooltip(
      message: 'Connect to the internet to upload',
      triggerMode: TooltipTriggerMode.tap,
      child: button,
    );
  }
}
