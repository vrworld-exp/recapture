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
    required this.photosAccepted,
    required this.coveragePercent,
    required this.warningsCount,
    required this.nextRoute,
    required this.nextLabel,
    required this.reviewRoute,
  });

  final String levelLabel;
  final String levelName;
  final int photosAccepted;
  final int coveragePercent;
  final int warningsCount;
  final String nextRoute;
  final String nextLabel;
  final String reviewRoute;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.bgPrimary,
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(AppSpacing.lg),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Container(
                width: 80,
                height: 80,
                decoration: BoxDecoration(
                  color: AppColors.success.withValues(alpha: 0.15),
                  shape: BoxShape.circle,
                ),
                child: const Icon(
                  Icons.check_circle,
                  size: 48,
                  color: AppColors.success,
                ),
              ),
              const SizedBox(height: AppSpacing.lg),
              Text(
                'Level $levelLabel complete',
                style: Theme.of(context).textTheme.titleLarge,
              ),
              const SizedBox(height: AppSpacing.xxl),
              AppCard(
                child: Column(
                  children: [
                    _StatRow(
                      label: 'Photos accepted',
                      value: '$photosAccepted / 36',
                      valueColor: AppColors.textPrimary,
                    ),
                    const _GoldDivider(),
                    _StatRow(
                      label: 'Coverage',
                      value: '$coveragePercent%',
                      valueColor: coveragePercent > 80
                          ? AppColors.success
                          : AppColors.warning,
                    ),
                    const _GoldDivider(),
                    _StatRow(
                      label: 'Warnings',
                      value: '$warningsCount',
                      valueColor: warningsCount > 0
                          ? AppColors.warning
                          : AppColors.success,
                    ),
                  ],
                ),
              ),
              const SizedBox(height: AppSpacing.xxl),
              AppButton(
                label: nextLabel,
                onPressed: () => context.go(nextRoute),
              ),
              const SizedBox(height: AppSpacing.md),
              AppButton.secondary(
                label: 'Review $levelName',
                onPressed: () => context.push(reviewRoute),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _StatRow extends StatelessWidget {
  const _StatRow({
    required this.label,
    required this.value,
    required this.valueColor,
  });

  final String label;
  final String value;
  final Color valueColor;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: AppSpacing.sm),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(
            label,
            style: Theme.of(context)
                .textTheme
                .bodySmall
                ?.copyWith(color: AppColors.textSecondary),
          ),
          Text(
            value,
            style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                  fontWeight: FontWeight.bold,
                  color: valueColor,
                ),
          ),
        ],
      ),
    );
  }
}

class _GoldDivider extends StatelessWidget {
  const _GoldDivider();

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 1,
      color: AppColors.royalGold.withValues(alpha: 0.3),
    );
  }
}
