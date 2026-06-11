// lib/presentation/screens/capture/review_screen.dart
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import '../../../app/theme/app_colors.dart';
import '../../../app/theme/app_spacing.dart';
import '../../../app/theme/app_typography.dart';
import '../../widgets/app_button.dart';
import '../../widgets/app_scaffold.dart';
import '../../widgets/placeholder_box.dart';

class ReviewScreen extends StatelessWidget {
  const ReviewScreen({
    super.key,
    required this.levelLabel,
    required this.levelName,
    required this.nextRoute,
  });

  final String levelLabel;
  final String levelName;
  final String nextRoute;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.bgPrimary,
      appBar: rcAppBar(context, title: 'Review: $levelName'),
      body: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: AppSpacing.screenPadding,
                vertical: AppSpacing.md,
              ),
              child: Row(
                children: [
                  _filterChip('All (36)', active: true),
                  const SizedBox(width: AppSpacing.sm),
                  _filterChip('Warned (3)', active: false),
                  const SizedBox(width: AppSpacing.sm),
                  _filterChip('Rejected (1)', active: false),
                ],
              ),
            ),
            const Expanded(
              child: PlaceholderBox(
                label:
                    'Photo Grid\n36 captures — 9 accepted, 3 warned, 1 rejected',
                height: double.infinity,
                icon: Icons.grid_view_rounded,
              ),
            ),
            Container(
              color: AppColors.surface1,
              padding: const EdgeInsets.all(AppSpacing.lg),
              child: Column(
                children: [
                  AppButton(
                    label: 'Proceed to Complete',
                    onPressed: () => context.go(nextRoute),
                  ),
                  const SizedBox(height: AppSpacing.sm),
                  AppButton.secondary(
                    label: 'Back to Capture',
                    onPressed: () => context.pop(),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

Widget _filterChip(String label, {required bool active}) {
  return Container(
    padding: const EdgeInsets.symmetric(
      horizontal: AppSpacing.lg,
      vertical: AppSpacing.sm,
    ),
    decoration: BoxDecoration(
      borderRadius: BorderRadius.circular(AppRadius.xs),
      color: active ? AppColors.mirageRed : AppColors.surface2,
      border: active
          ? null
          : Border.all(color: AppColors.disabled, width: 0.5),
    ),
    child: Text(
      label,
      style: TextStyle(
        fontSize: AppTypography.sizeLabel,
        fontWeight: FontWeight.w500,
        color: active ? Colors.white : AppColors.textSecondary,
      ),
    ),
  );
}
