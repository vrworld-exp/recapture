// lib/presentation/screens/capture/permissions_screen.dart
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import '../../../app/routes/app_router.dart';
import '../../../app/theme/app_colors.dart';
import '../../../app/theme/app_spacing.dart';
import '../../widgets/app_button.dart';
import '../../widgets/app_card.dart';

class PermissionsScreen extends StatelessWidget {
  const PermissionsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.bgPrimary,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_ios_new, color: AppColors.textPrimary),
          onPressed: () {
            if (context.canPop()) context.pop();
          },
        ),
        title: Text('Enable permissions', style: Theme.of(context).textTheme.titleLarge),
      ),
      body: Padding(
        padding: const EdgeInsets.all(AppSpacing.lg),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'ReCapture needs these to guide your capture.',
              style: Theme.of(context).textTheme.bodyMedium,
            ),
            const SizedBox(height: AppSpacing.xxl),
            const _PermissionCard(
              icon: Icons.camera_alt_outlined,
              title: 'Camera',
              badge: '(required)',
              badgeColor: AppColors.mirageRed,
              description: 'To capture your object.',
              statusWidget: Icon(Icons.check_circle, color: AppColors.success, size: 22),
            ),
            const SizedBox(height: AppSpacing.sm),
            _PermissionCard(
              icon: Icons.sensors,
              title: 'Motion',
              badge: '(recommended)',
              badgeColor: AppColors.textSecondary,
              description: 'For tilt and stability guidance.',
              statusWidget: TextButton(
                onPressed: () {},
                style: TextButton.styleFrom(
                  foregroundColor: AppColors.mirageRed,
                  padding: EdgeInsets.zero,
                  minimumSize: Size.zero,
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
                child: const Text('Allow'),
              ),
            ),
            const SizedBox(height: AppSpacing.sm),
            _PermissionCard(
              icon: Icons.photo_library_outlined,
              title: 'Photos',
              badge: '(optional)',
              badgeColor: AppColors.textMuted,
              description: 'To save to gallery.',
              statusWidget: TextButton(
                onPressed: () {},
                style: TextButton.styleFrom(
                  foregroundColor: AppColors.textMuted,
                  padding: EdgeInsets.zero,
                  minimumSize: Size.zero,
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
                child: const Text('Allow'),
              ),
            ),
            const SizedBox(height: AppSpacing.huge),
            AppButton(
              label: 'Continue',
              onPressed: () => context.go(AppRoutes.levelAIntro),
            ),
          ],
        ),
      ),
    );
  }
}

class _PermissionCard extends StatelessWidget {
  const _PermissionCard({
    required this.icon,
    required this.title,
    required this.badge,
    required this.badgeColor,
    required this.description,
    required this.statusWidget,
  });

  final IconData icon;
  final String title;
  final String badge;
  final Color badgeColor;
  final String description;
  final Widget statusWidget;

  @override
  Widget build(BuildContext context) {
    return AppCard(
      child: Row(
        children: [
          Icon(icon, color: AppColors.textSecondary, size: 22),
          const SizedBox(width: AppSpacing.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Text(title, style: Theme.of(context).textTheme.bodyLarge),
                    const SizedBox(width: AppSpacing.xs),
                    Text(
                      badge,
                      style: Theme.of(context)
                          .textTheme
                          .bodySmall
                          ?.copyWith(color: badgeColor),
                    ),
                  ],
                ),
                Text(description, style: Theme.of(context).textTheme.bodySmall),
              ],
            ),
          ),
          statusWidget,
        ],
      ),
    );
  }
}
