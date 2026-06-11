// lib/presentation/screens/capture/level_complete_screen.dart
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import '../../../app/theme/app_colors.dart';
import '../../../app/theme/app_spacing.dart';
import '../../widgets/app_button.dart';
import '../../widgets/app_card.dart';

class LevelCompleteScreen extends StatelessWidget {
  const LevelCompleteScreen({
    super.key,
    required this.levelLabel,
    required this.levelName,
    required this.nextLabel,
    required this.nextRoute,
    required this.reviewRoute,
  });

  final String levelLabel;
  final String levelName;
  final String nextLabel;
  final String nextRoute;
  final String reviewRoute;

  @override
  Widget build(BuildContext context) {
    final tt = Theme.of(context).textTheme;
    return Scaffold(
      backgroundColor: AppColors.bgPrimary,
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(AppSpacing.screenPadding),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Container(
                width: 80,
                height: 80,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: AppColors.success.withValues(alpha: 0.12),
                  border: Border.all(
                    color: AppColors.success.withValues(alpha: 0.3),
                    width: 0.5,
                  ),
                ),
                child: const Icon(Icons.check_circle_rounded,
                    size: 48, color: AppColors.success),
              ),
              const SizedBox(height: AppSpacing.xxl),
              Text(
                'Level $levelLabel complete',
                style: tt.titleLarge,
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: AppSpacing.xxl),
              AppCard(
                child: Column(
                  children: [
                    const _StatRow('Photos accepted', '36 / 36', AppColors.success),
                    Container(
                      height: 0.5,
                      color: AppColors.disabled.withValues(alpha: 0.5),
                    ),
                    const _StatRow('Coverage', '92%', AppColors.success),
                    Container(
                      height: 0.5,
                      color: AppColors.disabled.withValues(alpha: 0.5),
                    ),
                    const _StatRow('Warnings', '2', AppColors.warning),
                  ],
                ),
              ),
              const SizedBox(height: AppSpacing.xxxl),
              AppButton(
                label: nextLabel,
                onPressed: () => context.go(nextRoute),
              ),
              const SizedBox(height: AppSpacing.md),
              AppButton.secondary(
                label: 'Review $levelName',
                onPressed: () => context.push(reviewRoute),
              ),
              const SizedBox(height: AppSpacing.xxl),
            ],
          ),
        ),
      ),
    );
  }
}

class _StatRow extends StatelessWidget {
  const _StatRow(this.label, this.value, this.valueColor);

  final String label;
  final String value;
  final Color valueColor;

  @override
  Widget build(BuildContext context) {
    final tt = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: AppSpacing.md),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label, style: tt.bodyMedium),
          Text(
            value,
            style: tt.bodyLarge?.copyWith(
              color: valueColor,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}
