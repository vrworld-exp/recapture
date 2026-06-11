// lib/presentation/screens/capture/capture_summary_screen.dart
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import '../../../app/routes/app_router.dart';
import '../../../app/theme/app_colors.dart';
import '../../../app/theme/app_spacing.dart';
import '../../widgets/app_button.dart';
import '../../widgets/app_card.dart';

class CaptureSummaryScreen extends StatelessWidget {
  const CaptureSummaryScreen({super.key});

  static const _levels = [
    ('A', 'Eye Ring', 34, 92, 1),
    ('B', 'Top Ring', 32, 87, 1),
    ('C', 'Low Ring', 30, 78, 2),
  ];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.bgPrimary,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        automaticallyImplyLeading: false,
        title: Text('Ready to upload', style: Theme.of(context).textTheme.titleLarge),
      ),
      body: Column(
        children: [
          Expanded(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(AppSpacing.lg),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Review your capture before uploading.',
                    style: Theme.of(context).textTheme.bodyMedium,
                  ),
                  const SizedBox(height: AppSpacing.xxl),
                  ..._levels.map((l) => Padding(
                        padding: const EdgeInsets.only(bottom: AppSpacing.sm),
                        child: _LevelSummaryCard(
                          levelLabel: l.$1,
                          levelName: l.$2,
                          accepted: l.$3,
                          coverage: l.$4,
                          warnings: l.$5,
                        ),
                      )),
                  const SizedBox(height: AppSpacing.xxl),
                  Container(height: 1, color: AppColors.royalGold.withValues(alpha: 0.3)),
                  const SizedBox(height: AppSpacing.lg),
                  AppCard(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            const Icon(Icons.warning_amber, color: AppColors.warning, size: 18),
                            const SizedBox(width: AppSpacing.sm),
                            Text(
                              '3 warnings to review',
                              style: Theme.of(context).textTheme.bodyLarge,
                            ),
                          ],
                        ),
                        const SizedBox(height: AppSpacing.md),
                        Text(
                          '• Shot #18: motion blur detected',
                          style: Theme.of(context)
                              .textTheme
                              .bodySmall
                              ?.copyWith(color: AppColors.textMuted),
                        ),
                        const SizedBox(height: AppSpacing.xs),
                        Text(
                          '• Shot #31: slight over-exposure',
                          style: Theme.of(context)
                              .textTheme
                              .bodySmall
                              ?.copyWith(color: AppColors.textMuted),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
          Container(
            padding: const EdgeInsets.all(AppSpacing.lg),
            color: AppColors.bgPrimary,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                AppButton(
                  label: 'Upload',
                  onPressed: () => context.go(AppRoutes.uploading),
                ),
                const SizedBox(height: AppSpacing.sm),
                AppButton.secondary(
                  label: 'Fix Issues',
                  onPressed: () => context.go(AppRoutes.levelACapture),
                ),
                const SizedBox(height: AppSpacing.sm),
                TextButton(
                  onPressed: () => context.go(AppRoutes.projects),
                  child: const Text('Save for later'),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _LevelSummaryCard extends StatelessWidget {
  const _LevelSummaryCard({
    required this.levelLabel,
    required this.levelName,
    required this.accepted,
    required this.coverage,
    required this.warnings,
  });

  final String levelLabel;
  final String levelName;
  final int accepted;
  final int coverage;
  final int warnings;

  @override
  Widget build(BuildContext context) {
    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 8,
                height: 8,
                decoration: const BoxDecoration(
                  color: AppColors.mirageRed,
                  shape: BoxShape.circle,
                ),
              ),
              const SizedBox(width: AppSpacing.sm),
              Text(
                'Level $levelLabel • $levelName',
                style: Theme.of(context).textTheme.headlineMedium,
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.md),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              _MiniStat(label: 'Accepted', value: '$accepted/36', context: context),
              _MiniStat(label: 'Coverage', value: '$coverage%', context: context),
              _MiniStat(label: 'Warnings', value: '$warnings', context: context),
            ],
          ),
        ],
      ),
    );
  }
}

class _MiniStat extends StatelessWidget {
  const _MiniStat({
    required this.label,
    required this.value,
    required this.context,
  });

  final String label;
  final String value;
  final BuildContext context;

  @override
  Widget build(BuildContext _) {
    return Column(
      children: [
        Text(
          value,
          style: Theme.of(context)
              .textTheme
              .bodyLarge
              ?.copyWith(fontWeight: FontWeight.bold),
        ),
        Text(
          label,
          style: Theme.of(context)
              .textTheme
              .bodySmall
              ?.copyWith(color: AppColors.textMuted),
        ),
      ],
    );
  }
}
