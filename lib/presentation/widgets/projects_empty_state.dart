// lib/presentation/widgets/projects_empty_state.dart
import 'package:flutter/material.dart';
import '../../app/theme/app_colors.dart';
import '../../app/theme/app_spacing.dart';
import 'app_button.dart';

/// Shown when the user has zero projects. Illustration + message + a primary
/// CTA that routes into the pre-capture flow.
class ProjectsEmptyState extends StatelessWidget {
  const ProjectsEmptyState({super.key, required this.onStartCapture});

  final VoidCallback onStartCapture;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.xxl),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 96,
              height: 96,
              decoration: BoxDecoration(
                color: AppColors.surface1,
                shape: BoxShape.circle,
                border: Border.all(
                  color: AppColors.royalGold.withValues(alpha: 0.3),
                  width: 0.5,
                ),
              ),
              child: const Icon(
                Icons.view_in_ar_outlined,
                color: AppColors.textMuted,
                size: 40,
              ),
            ),
            const SizedBox(height: AppSpacing.xxl),
            Text(
              'No projects yet',
              style: Theme.of(context).textTheme.titleLarge,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: AppSpacing.sm),
            Text(
              'Start your first capture to turn a real object into a 3D model.',
              style: Theme.of(context)
                  .textTheme
                  .bodyMedium
                  ?.copyWith(color: AppColors.textSecondary),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: AppSpacing.xxl),
            AppButton(
              label: 'Start new capture',
              icon: Icons.add,
              isFullWidth: false,
              onPressed: onStartCapture,
            ),
          ],
        ),
      ),
    );
  }
}
