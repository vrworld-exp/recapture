// lib/presentation/screens/capture/permissions_screen.dart
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import '../../../app/routes/app_router.dart';
import '../../../app/theme/app_colors.dart';
import '../../../app/theme/app_spacing.dart';
import '../../../app/theme/app_typography.dart';
import '../../widgets/app_button.dart';
import '../../widgets/app_card.dart';
import '../../widgets/app_scaffold.dart';

class PermissionsScreen extends StatelessWidget {
  const PermissionsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final tt = Theme.of(context).textTheme;
    return Scaffold(
      backgroundColor: AppColors.bgPrimary,
      appBar: rcAppBar(context, title: 'Enable permissions'),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(AppSpacing.screenPadding),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const SizedBox(height: AppSpacing.lg),
              Text('ReCapture needs these to guide your capture.',
                  style: tt.bodyMedium),
              const SizedBox(height: AppSpacing.xxl),
              const _PermCard(
                icon: Icons.camera_alt_outlined,
                title: 'Camera',
                badge: 'Required',
                badgeColor: AppColors.mirageRed,
                desc: 'To capture your object.',
                statusWidget: Icon(Icons.check_circle,
                    color: AppColors.success, size: 22),
              ),
              const SizedBox(height: AppSpacing.sm),
              _PermCard(
                icon: Icons.sensors,
                title: 'Motion',
                badge: 'Recommended',
                badgeColor: AppColors.royalGold,
                desc: 'For tilt and stability guidance.',
                statusWidget: TextButton(
                  style: TextButton.styleFrom(
                      foregroundColor: AppColors.mirageRed),
                  onPressed: () {},
                  child: const Text('Allow'),
                ),
              ),
              const SizedBox(height: AppSpacing.sm),
              _PermCard(
                icon: Icons.photo_library_outlined,
                title: 'Photos',
                badge: 'Optional',
                badgeColor: AppColors.disabled,
                desc: 'To save captures to gallery.',
                statusWidget: TextButton(
                  style: TextButton.styleFrom(
                      foregroundColor: AppColors.textMuted),
                  onPressed: () {},
                  child: const Text('Allow'),
                ),
              ),
              const Spacer(),
              AppButton(
                label: 'Continue',
                onPressed: () => context.go(AppRoutes.levelAIntro),
              ),
              const SizedBox(height: AppSpacing.xxl),
            ],
          ),
        ),
      ),
    );
  }
}

class _PermCard extends StatelessWidget {
  const _PermCard({
    required this.icon,
    required this.title,
    required this.badge,
    required this.badgeColor,
    required this.desc,
    required this.statusWidget,
  });

  final IconData icon;
  final String title;
  final String badge;
  final Color badgeColor;
  final String desc;
  final Widget statusWidget;

  @override
  Widget build(BuildContext context) {
    final tt = Theme.of(context).textTheme;
    return AppCard(
      child: Row(
        children: [
          Icon(icon, size: 22, color: AppColors.textSecondary),
          const SizedBox(width: AppSpacing.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Text(title, style: tt.headlineMedium),
                    const SizedBox(width: AppSpacing.xs),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: AppSpacing.xs,
                        vertical: 2,
                      ),
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(AppRadius.xs),
                        color: badgeColor.withValues(alpha: 0.15),
                      ),
                      child: Text(
                        badge,
                        style: TextStyle(
                          fontSize: AppTypography.sizeLabel,
                          fontWeight: FontWeight.w500,
                          color: badgeColor,
                        ),
                      ),
                    ),
                  ],
                ),
                Text(desc, style: tt.bodySmall),
              ],
            ),
          ),
          statusWidget,
        ],
      ),
    );
  }
}
