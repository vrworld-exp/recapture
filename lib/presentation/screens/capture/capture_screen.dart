// lib/presentation/screens/capture/capture_screen.dart
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import '../../../app/routes/app_router.dart';
import '../../../app/theme/app_colors.dart';
import '../../../app/theme/app_spacing.dart';
import '../../widgets/app_button.dart';
import '../../widgets/placeholder_box.dart';

// Shutter button dimensions (not spacing — specific design spec)
const double _shutterOuter = 70.0;
const double _shutterInner = 58.0;

class CaptureScreen extends StatelessWidget {
  const CaptureScreen({
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
    final tt = Theme.of(context).textTheme;
    return Scaffold(
      backgroundColor: AppColors.bgPrimary,
      appBar: AppBar(
        backgroundColor: AppColors.bgPrimary,
        elevation: 0,
        scrolledUnderElevation: 0,
        title: Text('$levelLabel • $levelName', style: tt.bodyLarge),
        leading: IconButton(
          icon: const Icon(Icons.close, color: AppColors.textPrimary),
          onPressed: () => context.go(AppRoutes.projects),
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.help_outline, color: AppColors.textSecondary),
            onPressed: () {},
          ),
          IconButton(
            icon: const Icon(Icons.settings_outlined,
                color: AppColors.textSecondary),
            onPressed: () {},
          ),
        ],
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(AppSpacing.screenPadding),
          child: Column(
            children: [
              const SizedBox(height: AppSpacing.md),
              PlaceholderBox(
                label: 'Camera Preview\n$levelLabel • $levelName',
                height: 340,
                icon: Icons.camera_alt_outlined,
              ),
              const SizedBox(height: AppSpacing.lg),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(AppSpacing.md),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(AppRadius.xs),
                  color: AppColors.surface1,
                  border: Border.all(color: AppColors.disabled, width: 0.5),
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    const Icon(Icons.rotate_right,
                        size: 16, color: AppColors.mirageRed),
                    const SizedBox(width: AppSpacing.sm),
                    Text('Move clockwise',
                        style: tt.bodyLarge
                            ?.copyWith(color: AppColors.textPrimary)),
                  ],
                ),
              ),
              const SizedBox(height: AppSpacing.lg),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('Accepted', style: tt.labelSmall),
                      Text('12 / 36', style: tt.headlineMedium),
                    ],
                  ),
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
                      Text('Coverage', style: tt.labelSmall),
                      Text('68%',
                          style: tt.headlineMedium
                              ?.copyWith(color: AppColors.warning)),
                    ],
                  ),
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      Text('Auto', style: tt.labelSmall),
                      Text('ON',
                          style: tt.headlineMedium
                              ?.copyWith(color: AppColors.success)),
                    ],
                  ),
                ],
              ),
              const SizedBox(height: AppSpacing.xxl),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  AppButton.secondary(
                    label: 'Review',
                    isFullWidth: false,
                    onPressed: () => context.go(nextRoute),
                  ),
                  const SizedBox(width: AppSpacing.lg),
                  Container(
                    width: _shutterOuter,
                    height: _shutterOuter,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      border: Border.all(
                          color: AppColors.textPrimary, width: 3),
                    ),
                    child: Center(
                      child: Container(
                        width: _shutterInner,
                        height: _shutterInner,
                        decoration: const BoxDecoration(
                          shape: BoxShape.circle,
                          color: AppColors.mirageRed,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: AppSpacing.lg),
                  AppButton.secondary(
                    label: 'Done',
                    isFullWidth: false,
                    onPressed: () => context.go(nextRoute),
                  ),
                ],
              ),
              const SizedBox(height: AppSpacing.lg),
            ],
          ),
        ),
      ),
    );
  }
}
