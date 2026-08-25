// lib/presentation/widgets/permission_card.dart
import 'package:flutter/material.dart';
import '../../app/theme/app_colors.dart';
import '../../app/theme/app_spacing.dart';
import '../../domain/entities/permission_item.dart';
import '../../platform/permissions_service.dart';
import 'app_card.dart';

/// One permission row on the gate: icon, title + criticality label, rationale,
/// and a status-driven trailing indicator/action. Purely presentational — it
/// emits callbacks and holds no permission state of its own.
///
/// Status is conveyed by icon + TEXT + colour together (never colour alone), so
/// it stays legible in greyscale and to screen readers:
///   - granted           → check icon + "Granted" (success)
///   - permanentlyDenied / restricted → alert icon + "Settings" button → [onOpenSettings]
///   - notRequested / denied          → "Allow" button → [onAllow]
/// While a request is in flight a spinner replaces the trailing widget.
///
/// Criticality ([PermissionRequirement]) changes only the label/emphasis — it
/// never changes which action a given status shows. A combined semantics label
/// (`title, criticality, status`) is exposed so the state is announced without
/// relying on colour/icon.
class PermissionCard extends StatelessWidget {
  const PermissionCard({
    super.key,
    required this.item,
    required this.status,
    required this.isInFlight,
    this.onAllow,
    this.onOpenSettings,
  });

  final PermissionItem item;
  final AppPermissionStatus status;
  final bool isInFlight;

  /// Tapped "Allow" (triggers the OS request). When null the request action is
  /// not offered (the card degrades to a status-only chip).
  final VoidCallback? onAllow;

  /// Tapped "Settings" (deep-links to app settings). When null the settings
  /// action is not offered.
  final VoidCallback? onOpenSettings;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      container: true,
      label: _semanticLabel,
      child: AppCard(
        child: Row(
          children: [
            // Decorative — the combined label above already conveys the meaning.
            ExcludeSemantics(
              child: Icon(item.icon, color: AppColors.textSecondary, size: 22),
            ),
            const SizedBox(width: AppSpacing.md),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Wrap (not Row) so the criticality label flows to the next
                  // line under large text scaling instead of overflowing.
                  Wrap(
                    crossAxisAlignment: WrapCrossAlignment.center,
                    spacing: AppSpacing.xs,
                    children: [
                      Text(item.title, style: Theme.of(context).textTheme.bodyLarge),
                      Text(
                        item.requirement.label,
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                              color: item.requirement.color,
                              fontWeight: item.requirement == PermissionRequirement.required
                                  ? FontWeight.w600
                                  : FontWeight.w400,
                            ),
                      ),
                    ],
                  ),
                  Text(item.rationale, style: Theme.of(context).textTheme.bodySmall),
                ],
              ),
            ),
            const SizedBox(width: AppSpacing.sm),
            _trailing(context),
          ],
        ),
      ),
    );
  }

  /// Screen-reader summary: e.g. "Camera, required, granted". Lets the state be
  /// understood without seeing the colour or icon.
  String get _semanticLabel =>
      '${item.title}, ${item.requirement.analyticsValue}, $_statusWord';

  String get _statusWord {
    if (status.isGranted) return 'granted';
    if (status.needsSettings) return 'blocked';
    return 'not granted';
  }

  Widget _trailing(BuildContext context) {
    if (isInFlight) {
      return const SizedBox(
        width: 22,
        height: 22,
        child: CircularProgressIndicator(strokeWidth: 2, color: AppColors.mirageRed),
      );
    }

    // Granted (and limited, which the service folds into granted): icon + text.
    if (status.isGranted) {
      return _statusChip(
        context,
        icon: Icons.check_circle,
        label: 'Granted',
        color: AppColors.success,
      );
    }

    // Permanently denied / restricted: the OS won't re-prompt → route to Settings.
    if (status.needsSettings) {
      return onOpenSettings == null
          ? _statusChip(context,
              icon: Icons.error_outline, label: 'Blocked', color: AppColors.error)
          : _actionButton(
              label: 'Settings',
              color: AppColors.error,
              icon: Icons.error_outline,
              onPressed: onOpenSettings!,
            );
    }

    // notRequested / denied: re-promptable in-app.
    return onAllow == null
        ? _statusChip(context,
            icon: Icons.radio_button_unchecked,
            label: 'Not granted',
            color: AppColors.textMuted)
        : _actionButton(label: 'Allow', color: AppColors.mirageRed, onPressed: onAllow!);
  }

  /// Non-interactive status indicator: icon + text + colour (no dangling button).
  Widget _statusChip(
    BuildContext context, {
    required IconData icon,
    required String label,
    required Color color,
  }) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, color: color, size: 18),
        const SizedBox(width: AppSpacing.xs),
        Text(
          label,
          style: Theme.of(context).textTheme.bodySmall?.copyWith(color: color),
        ),
      ],
    );
  }

  Widget _actionButton({
    required String label,
    required Color color,
    required VoidCallback onPressed,
    IconData? icon,
  }) {
    final style = TextButton.styleFrom(
      foregroundColor: color,
      padding: EdgeInsets.zero,
      minimumSize: Size.zero,
      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
    );
    if (icon == null) {
      return TextButton(onPressed: onPressed, style: style, child: Text(label));
    }
    return TextButton.icon(
      onPressed: onPressed,
      style: style,
      icon: Icon(icon, size: 18),
      label: Text(label),
    );
  }
}
