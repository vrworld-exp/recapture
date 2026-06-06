import 'package:flutter/material.dart';
import '../../app/theme/app_colors.dart';
import '../../app/theme/app_spacing.dart';
import '../../app/theme/app_typography.dart';

enum ProjectStatus {
  draft,
  capturing,
  uploading,
  processing,
  completed,
  failed,
}

extension ProjectStatusLabel on ProjectStatus {
  String get label => switch (this) {
        ProjectStatus.draft => 'Draft',
        ProjectStatus.capturing => 'Capturing',
        ProjectStatus.uploading => 'Uploading',
        ProjectStatus.processing => 'Processing',
        ProjectStatus.completed => 'Completed',
        ProjectStatus.failed => 'Failed',
      };

  Color get color => switch (this) {
        ProjectStatus.draft => AppColors.disabled,
        ProjectStatus.capturing => AppColors.mirageRed,
        ProjectStatus.uploading => AppColors.royalGold,
        ProjectStatus.processing => AppColors.royalGold,
        ProjectStatus.completed => AppColors.success,
        ProjectStatus.failed => AppColors.error,
      };
}

class AppStatusPill extends StatelessWidget {
  const AppStatusPill({super.key, required this.status});

  final ProjectStatus status;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.sm,
        vertical: AppSpacing.xs,
      ),
      decoration: BoxDecoration(
        color: status.color.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(AppRadius.xs),
        border: Border.all(color: status.color.withValues(alpha: 0.4)),
      ),
      child: Text(
        status.label,
        style: TextStyle(
          fontSize: AppTypography.sizeLabel,
          fontWeight: FontWeight.w500,
          color: status.color,
        ),
      ),
    );
  }
}
