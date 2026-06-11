// lib/presentation/screens/capture/review_screen.dart
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import '../../../app/theme/app_colors.dart';
import '../../../app/theme/app_spacing.dart';
import '../../../app/theme/app_typography.dart';
import '../../widgets/app_button.dart';

class ReviewScreen extends StatefulWidget {
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
  State<ReviewScreen> createState() => _ReviewScreenState();
}

class _ReviewScreenState extends State<ReviewScreen> {
  bool _showAll = true;

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
          'Review: ${widget.levelName}',
          style: Theme.of(context).textTheme.titleLarge,
        ),
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: AppSpacing.lg,
              vertical: AppSpacing.md,
            ),
            child: Row(
              children: [
                _FilterChip(
                  label: 'All (36)',
                  active: _showAll,
                  onTap: () => setState(() => _showAll = true),
                ),
                const SizedBox(width: AppSpacing.sm),
                _FilterChip(
                  label: 'Warned (3)',
                  active: !_showAll,
                  onTap: () => setState(() => _showAll = false),
                ),
              ],
            ),
          ),
          Expanded(
            child: GridView.count(
              crossAxisCount: 3,
              padding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg),
              mainAxisSpacing: AppSpacing.sm,
              crossAxisSpacing: AppSpacing.sm,
              children: List.generate(12, (i) {
                Color dotColor;
                String? badge;
                if (i == 5 || i == 9) {
                  dotColor = AppColors.warning;
                  badge = null;
                } else if (i == 11) {
                  dotColor = AppColors.error;
                  badge = '!';
                } else {
                  dotColor = AppColors.success;
                  badge = null;
                }
                return Stack(
                  children: [
                    Container(
                      decoration: BoxDecoration(
                        color: AppColors.surface2,
                        borderRadius: BorderRadius.circular(AppRadius.xs),
                      ),
                      child: Center(
                        child: Text(
                          '#${i + 1}',
                          style: Theme.of(context).textTheme.labelSmall,
                        ),
                      ),
                    ),
                    Positioned(
                      top: AppSpacing.xs,
                      right: AppSpacing.xs,
                      child: badge != null
                          ? Container(
                              width: 16,
                              height: 16,
                              decoration: BoxDecoration(
                                color: dotColor,
                                shape: BoxShape.circle,
                              ),
                              child: Center(
                                child: Text(
                                  badge,
                                  style: const TextStyle(
                                    fontSize: AppTypography.sizeLabel,
                                    color: Colors.white,
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                              ),
                            )
                          : Container(
                              width: 8,
                              height: 8,
                              decoration: BoxDecoration(
                                color: dotColor,
                                shape: BoxShape.circle,
                              ),
                            ),
                    ),
                  ],
                );
              }),
            ),
          ),
          Container(
            color: AppColors.surface1,
            padding: const EdgeInsets.all(AppSpacing.lg),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                AppButton.secondary(
                  label: 'Back to Capture',
                  onPressed: () {
                    if (context.canPop()) context.pop();
                  },
                ),
                const SizedBox(height: AppSpacing.sm),
                AppButton(
                  label: 'Proceed',
                  onPressed: () => context.go(widget.nextRoute),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _FilterChip extends StatelessWidget {
  const _FilterChip({required this.label, required this.active, required this.onTap});
  final String label;
  final bool active;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.md,
          vertical: AppSpacing.xs,
        ),
        decoration: BoxDecoration(
          color: active ? AppColors.mirageRed : AppColors.surface2,
          borderRadius: BorderRadius.circular(AppRadius.xs),
        ),
        child: Text(
          label,
          style: Theme.of(context).textTheme.labelSmall?.copyWith(
                color: active ? Colors.white : AppColors.textSecondary,
              ),
        ),
      ),
    );
  }
}
