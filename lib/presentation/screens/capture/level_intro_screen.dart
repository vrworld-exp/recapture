// lib/presentation/screens/capture/level_intro_screen.dart
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import '../../../app/theme/app_colors.dart';
import '../../../app/theme/app_spacing.dart';
import '../../../app/theme/app_typography.dart';
import '../../widgets/app_button.dart';
import '../../widgets/app_scaffold.dart';
import '../../widgets/placeholder_box.dart';

class LevelIntroScreen extends StatelessWidget {
  const LevelIntroScreen({
    super.key,
    required this.levelLabel,
    required this.levelName,
    required this.icon,
    required this.rules,
    required this.angleHint,
    required this.nextRoute,
  });

  final String levelLabel;
  final String levelName;
  final IconData icon;
  final List<String> rules;
  final String angleHint;
  final String nextRoute;

  @override
  Widget build(BuildContext context) {
    final tt = Theme.of(context).textTheme;
    return Scaffold(
      backgroundColor: AppColors.bgPrimary,
      appBar: rcAppBar(context, title: 'Level $levelLabel: $levelName'),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(AppSpacing.screenPadding),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const SizedBox(height: AppSpacing.xxl),
              PlaceholderBox(
                label: 'Level $levelLabel — $angleHint',
                height: 180,
                icon: icon,
              ),
              const SizedBox(height: AppSpacing.xxl),
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: AppSpacing.lg,
                  vertical: AppSpacing.sm,
                ),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(AppRadius.xs),
                  color: AppColors.mirageRed.withValues(alpha: 0.12),
                  border: Border.all(
                    color: AppColors.mirageRed.withValues(alpha: 0.3),
                    width: 0.5,
                  ),
                ),
                child: Text(
                  'Level $levelLabel — $levelName',
                  style: const TextStyle(
                    fontSize: AppTypography.sizeLabel,
                    fontWeight: FontWeight.w500,
                    color: AppColors.mirageRed,
                  ),
                ),
              ),
              const SizedBox(height: AppSpacing.xxl),
              ...rules.map(
                (rule) => Padding(
                  padding: const EdgeInsets.only(bottom: AppSpacing.md),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Icon(Icons.check_circle_outline,
                          size: 18, color: AppColors.mirageRed),
                      const SizedBox(width: AppSpacing.sm),
                      Expanded(child: Text(rule, style: tt.bodyLarge)),
                    ],
                  ),
                ),
              ),
              const Spacer(),
              AppButton(
                label: 'Begin $levelName',
                onPressed: () => context.go(nextRoute),
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
