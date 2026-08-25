// lib/presentation/widgets/projects_empty_state.dart
import 'package:flutter/material.dart';
import '../../app/theme/app_colors.dart';
import '../../app/theme/app_spacing.dart';
import 'app_button.dart';

/// Shown when the user has zero projects (a fresh login lands here — no demo
/// cards). A layered AR glyph with a soft glow, "Nothing captured yet" copy,
/// and a primary CTA that routes into the pre-capture flow.
class ProjectsEmptyState extends StatelessWidget {
  const ProjectsEmptyState({super.key, required this.onStartCapture});

  final VoidCallback onStartCapture;

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.xxl),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Layered glyph: a faint outer halo ring around the icon disc gives
            // depth without breaking the token rules (gold stays a thin border).
            Container(
              width: 128,
              height: 128,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                border: Border.all(
                  color: AppColors.royalGold.withValues(alpha: 0.12),
                  width: 1,
                ),
              ),
              alignment: Alignment.center,
              child: Container(
                width: 96,
                height: 96,
                decoration: BoxDecoration(
                  color: AppColors.surface1,
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: AppColors.royalGold.withValues(alpha: 0.3),
                    width: 0.5,
                  ),
                  boxShadow: [
                    BoxShadow(
                      color: AppColors.redGlow.withValues(alpha: 0.08),
                      blurRadius: 32,
                      spreadRadius: 4,
                    ),
                  ],
                ),
                child: const Icon(
                  Icons.view_in_ar_outlined,
                  color: AppColors.textMuted,
                  size: 40,
                ),
              ),
            ),
            const SizedBox(height: AppSpacing.xxl),
            Text(
              'Nothing captured yet',
              style: textTheme.titleLarge,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: AppSpacing.sm),
            Text(
              'Objects you capture will live here as 3D models.\n'
              'Point your camera at something — we’ll do the rest.',
              style: textTheme.bodyMedium
                  ?.copyWith(color: AppColors.textSecondary, height: 1.5),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: AppSpacing.xxl),
            AppButton(
              label: 'Start your first capture',
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
