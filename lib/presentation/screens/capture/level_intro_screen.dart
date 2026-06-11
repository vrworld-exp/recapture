// lib/presentation/screens/capture/level_intro_screen.dart
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import '../../../app/theme/app_colors.dart';
import '../../../app/theme/app_spacing.dart';
import '../../widgets/app_button.dart';

class LevelIntroScreen extends StatelessWidget {
  const LevelIntroScreen({
    super.key,
    required this.levelLabel,
    required this.levelName,
    required this.levelColor,
    required this.rules,
    required this.icon,
    required this.nextRoute,
  });

  final String levelLabel;
  final String levelName;
  final Color levelColor;
  final List<String> rules;
  final IconData icon;
  final String nextRoute;

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
        title: Text(
          'Level $levelLabel: $levelName',
          style: Theme.of(context).textTheme.titleLarge,
        ),
      ),
      body: Padding(
        padding: const EdgeInsets.all(AppSpacing.lg),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              width: double.infinity,
              height: 200,
              decoration: BoxDecoration(
                color: AppColors.surface1,
                borderRadius: BorderRadius.circular(AppRadius.md),
                border: Border.all(
                  color: AppColors.royalGold.withValues(alpha: 0.4),
                  width: 1,
                ),
              ),
              child: Icon(icon, size: 80, color: levelColor),
            ),
            const SizedBox(height: AppSpacing.xxl),
            Text(
              'Level $levelLabel: $levelName',
              style: Theme.of(context).textTheme.titleLarge,
            ),
            const SizedBox(height: AppSpacing.lg),
            ...rules.map((rule) => Padding(
                  padding: const EdgeInsets.only(bottom: AppSpacing.md),
                  child: Row(
                    children: [
                      const Icon(
                        Icons.check_circle_outline,
                        color: AppColors.mirageRed,
                        size: 20,
                      ),
                      const SizedBox(width: AppSpacing.sm),
                      Expanded(
                        child: Text(rule, style: Theme.of(context).textTheme.bodyLarge),
                      ),
                    ],
                  ),
                )),
            const Spacer(),
            AppButton(
              label: 'Begin $levelName',
              onPressed: () => context.go(nextRoute),
            ),
          ],
        ),
      ),
    );
  }
}
