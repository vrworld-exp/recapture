// lib/presentation/widgets/app_status_pill.dart
import 'package:flutter/material.dart';
import '../../domain/entities/project_status.dart';
import '../../app/theme/app_spacing.dart';
import '../../app/theme/app_typography.dart';

/// Status badge for ReCapture project cards.
///
/// Displays the human-readable label and semantic color for a ProjectStatus.
/// Color and label are driven entirely by the ProjectStatusDisplay extension —
/// no color values are hardcoded in this widget.
///
/// Usage:
///   AppStatusPill(status: ProjectStatus.completed)
///   AppStatusPill(status: ProjectStatus.failed)
class AppStatusPill extends StatelessWidget {
  const AppStatusPill({
    super.key,
    required this.status,
  });

  final ProjectStatus status;

  @override
  Widget build(BuildContext context) {
    final color = status.color;

    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.sm,
        vertical: AppSpacing.xs,
      ),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(AppRadius.xs),
        border: Border.all(
          color: color.withValues(alpha: 0.35),
          width: 0.5,
        ),
      ),
      child: Text(
        status.label,
        style: TextStyle(
          fontSize: AppTypography.sizeLabel,
          fontWeight: FontWeight.w500,
          color: color,
          height: 1.0,
          letterSpacing: 0.2,
        ),
      ),
    );
  }
}
