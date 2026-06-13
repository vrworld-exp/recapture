// lib/presentation/widgets/permission_card.dart
import 'package:flutter/material.dart';
import '../../app/theme/app_colors.dart';
import '../../app/theme/app_spacing.dart';
import '../../domain/entities/permission_item.dart';
import '../../platform/permissions_service.dart';
import 'app_card.dart';

/// One permission row on the gate: icon, title + requirement badge, rationale,
/// and a status-dependent trailing action.
///
/// Trailing action by status:
///   - granted           → success check, no button
///   - permanentlyDenied / restricted → "Settings" → [onOpenSettings]
///   - notRequested / denied          → "Allow" → [onAllow]
/// While a request is in flight a spinner replaces the action.
class PermissionCard extends StatelessWidget {
  const PermissionCard({
    super.key,
    required this.item,
    required this.status,
    required this.isInFlight,
    required this.onAllow,
    required this.onOpenSettings,
  });

  final PermissionItem item;
  final AppPermissionStatus status;
  final bool isInFlight;
  final VoidCallback onAllow;
  final VoidCallback onOpenSettings;

  @override
  Widget build(BuildContext context) {
    return AppCard(
      child: Row(
        children: [
          Icon(item.icon, color: AppColors.textSecondary, size: 22),
          const SizedBox(width: AppSpacing.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Text(item.title, style: Theme.of(context).textTheme.bodyLarge),
                    const SizedBox(width: AppSpacing.xs),
                    Text(
                      item.requirement.label,
                      style: Theme.of(context)
                          .textTheme
                          .bodySmall
                          ?.copyWith(color: item.requirement.color),
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
    );
  }

  Widget _trailing(BuildContext context) {
    if (isInFlight) {
      return const SizedBox(
        width: 22,
        height: 22,
        child: CircularProgressIndicator(strokeWidth: 2, color: AppColors.mirageRed),
      );
    }

    if (status.isGranted) {
      return const Icon(Icons.check_circle, color: AppColors.success, size: 22);
    }

    if (status.needsSettings) {
      return _actionButton(
        label: 'Settings',
        color: AppColors.textSecondary,
        onPressed: onOpenSettings,
      );
    }

    // notRequested / denied
    return _actionButton(
      label: 'Allow',
      color: AppColors.mirageRed,
      onPressed: onAllow,
    );
  }

  Widget _actionButton({
    required String label,
    required Color color,
    required VoidCallback onPressed,
  }) {
    return TextButton(
      onPressed: onPressed,
      style: TextButton.styleFrom(
        foregroundColor: color,
        padding: EdgeInsets.zero,
        minimumSize: Size.zero,
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      ),
      child: Text(label),
    );
  }
}
