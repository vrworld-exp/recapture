// lib/presentation/screens/capture/pre_capture_screen.dart
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import '../../../app/routes/app_router.dart';
import '../../../app/theme/app_colors.dart';
import '../../../app/theme/app_spacing.dart';
import '../../widgets/app_button.dart';
import '../../widgets/app_card.dart';
import '../../widgets/app_scaffold.dart';

class PreCaptureScreen extends StatelessWidget {
  const PreCaptureScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final tt = Theme.of(context).textTheme;
    return Scaffold(
      backgroundColor: AppColors.bgPrimary,
      appBar: rcAppBar(context, title: 'Before you start'),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(horizontal: AppSpacing.screenPadding),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const SizedBox(height: AppSpacing.lg),
              Text('Complete these checks for best results.',
                  style: tt.bodyMedium),
              const SizedBox(height: AppSpacing.xxl),
              const _CheckItem(
                icon: Icons.wb_sunny_outlined,
                title: 'Use bright, even lighting',
                subtitle: 'Avoid shadows and direct flash',
              ),
              const _CheckItem(
                icon: Icons.crop_square_outlined,
                title: 'Use a plain background',
                subtitle: 'Recommended for clean geometry',
              ),
              const _CheckItem(
                icon: Icons.table_restaurant_outlined,
                title: 'Place on a stable surface',
                subtitle: 'Object must not move during capture',
              ),
              const _CheckItem(
                icon: Icons.rotate_right,
                title: 'Move around the object',
                subtitle: 'Do not rotate the object itself',
              ),
              const _CheckItem(
                icon: Icons.flash_off,
                title: 'Keep flash off',
                subtitle:
                    'Flash creates reflections that confuse reconstruction',
              ),
              const SizedBox(height: AppSpacing.xxl),
              Container(
                height: 1,
                color: AppColors.royalGold.withValues(alpha: 0.3),
              ),
              const SizedBox(height: AppSpacing.xxl),
              AppButton(
                label: 'Start Capture',
                onPressed: () => context.go(AppRoutes.permissions),
              ),
              const SizedBox(height: AppSpacing.md),
              AppButton.secondary(
                label: 'Back',
                onPressed: () => context.pop(),
              ),
              const SizedBox(height: AppSpacing.xxl),
            ],
          ),
        ),
      ),
    );
  }
}

class _CheckItem extends StatelessWidget {
  const _CheckItem({
    required this.icon,
    required this.title,
    required this.subtitle,
  });

  final IconData icon;
  final String title;
  final String subtitle;

  @override
  Widget build(BuildContext context) {
    final tt = Theme.of(context).textTheme;
    return AppCard(
      margin: const EdgeInsets.only(bottom: AppSpacing.sm),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 36,
            height: 36,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: AppColors.mirageRed.withValues(alpha: 0.15),
              border: Border.all(
                color: AppColors.mirageRed.withValues(alpha: 0.3),
                width: 0.5,
              ),
            ),
            child: Icon(icon, size: 18, color: AppColors.mirageRed),
          ),
          const SizedBox(width: AppSpacing.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: tt.bodyLarge),
                const SizedBox(height: AppSpacing.xs),
                Text(subtitle, style: tt.bodySmall),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
