// lib/presentation/screens/capture/capture_summary_screen.dart
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import '../../../app/routes/app_router.dart';
import '../../../app/theme/app_colors.dart';
import '../../../app/theme/app_spacing.dart';
import '../../../app/theme/app_typography.dart';
import '../../widgets/app_button.dart';
import '../../widgets/app_card.dart';
import '../../widgets/app_scaffold.dart';

class CaptureSummaryScreen extends StatelessWidget {
  const CaptureSummaryScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final tt = Theme.of(context).textTheme;
    return Scaffold(
      backgroundColor: AppColors.bgPrimary,
      appBar: rcAppBar(context, title: 'Ready to upload', showBack: false),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(horizontal: AppSpacing.screenPadding),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const SizedBox(height: AppSpacing.lg),
              Text('Review your capture before uploading.',
                  style: tt.bodyMedium),
              const SizedBox(height: AppSpacing.xxl),
              const _LevelSummaryCard(
                levelLabel: 'A',
                levelName: 'Eye Ring',
                photos: 36,
                coverage: 92,
                warnings: 2,
                indicatorColor: AppColors.success,
              ),
              const SizedBox(height: AppSpacing.sm),
              const _LevelSummaryCard(
                levelLabel: 'B',
                levelName: 'Top Ring',
                photos: 30,
                coverage: 88,
                warnings: 1,
                indicatorColor: AppColors.success,
              ),
              const SizedBox(height: AppSpacing.sm),
              const _LevelSummaryCard(
                levelLabel: 'C',
                levelName: 'Low Ring',
                photos: 24,
                coverage: 76,
                warnings: 3,
                indicatorColor: AppColors.warning,
              ),
              const SizedBox(height: AppSpacing.xxl),
              Container(height: 1,
                  color: AppColors.royalGold.withValues(alpha: 0.3)),
              const SizedBox(height: AppSpacing.lg),
              Row(
                children: [
                  const Icon(Icons.warning_amber_rounded,
                      size: 18, color: AppColors.warning),
                  const SizedBox(width: AppSpacing.sm),
                  Text('6 warnings across all levels',
                      style: tt.bodyMedium
                          ?.copyWith(color: AppColors.warning)),
                ],
              ),
              const SizedBox(height: AppSpacing.xxxl),
              AppButton(
                label: 'Upload',
                onPressed: () => context.go(AppRoutes.uploading),
              ),
              const SizedBox(height: AppSpacing.sm),
              AppButton.secondary(
                label: 'Fix Issues',
                onPressed: () => context.go(AppRoutes.levelCCapture),
              ),
              const SizedBox(height: AppSpacing.sm),
              TextButton(
                onPressed: () => context.go(AppRoutes.projects),
                child: Text(
                  'Save for later',
                  style: tt.bodyMedium
                      ?.copyWith(color: AppColors.textMuted),
                ),
              ),
              const SizedBox(height: AppSpacing.xxl),
            ],
          ),
        ),
      ),
    );
  }
}

class _LevelSummaryCard extends StatelessWidget {
  const _LevelSummaryCard({
    required this.levelLabel,
    required this.levelName,
    required this.photos,
    required this.coverage,
    required this.warnings,
    required this.indicatorColor,
  });

  final String levelLabel;
  final String levelName;
  final int photos;
  final int coverage;
  final int warnings;
  final Color indicatorColor;

  @override
  Widget build(BuildContext context) {
    final tt = Theme.of(context).textTheme;
    return AppCard(
      child: Column(
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Row(
                children: [
                  Container(
                    width: 8,
                    height: 8,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: indicatorColor,
                    ),
                  ),
                  const SizedBox(width: AppSpacing.sm),
                  Text('Level $levelLabel • $levelName',
                      style: tt.headlineMedium),
                ],
              ),
              Text('$photos photos', style: tt.bodySmall),
            ],
          ),
          const SizedBox(height: AppSpacing.sm),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                'Coverage: $coverage%',
                style: TextStyle(
                  fontSize: AppTypography.sizeCaption,
                  color: indicatorColor,
                ),
              ),
              Text(
                'Warnings: $warnings',
                style: TextStyle(
                  fontSize: AppTypography.sizeCaption,
                  color: warnings > 0 ? AppColors.warning : AppColors.success,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
