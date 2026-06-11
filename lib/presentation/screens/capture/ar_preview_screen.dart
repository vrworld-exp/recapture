// lib/presentation/screens/capture/ar_preview_screen.dart
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import '../../../app/theme/app_colors.dart';
import '../../../app/theme/app_spacing.dart';
import '../../widgets/app_button.dart';

class ArPreviewScreen extends StatelessWidget {
  const ArPreviewScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Stack(
        fit: StackFit.expand,
        children: [
          // camera mock — not a brand color
          Container(color: const Color(0xFF0D0D0D)),
          Center(
            child: Container(
              width: 150,
              height: 150,
              decoration: BoxDecoration(
                color: AppColors.surface1.withValues(alpha: 0.3),
                borderRadius: BorderRadius.circular(AppRadius.sm),
                border: Border.all(color: AppColors.royalGold, width: 1),
              ),
              child: const Icon(
                Icons.view_in_ar,
                size: 60,
                color: AppColors.mirageRed,
              ),
            ),
          ),
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: SafeArea(
              child: Padding(
                padding: const EdgeInsets.all(AppSpacing.sm),
                child: Row(
                  children: [
                    IconButton(
                      icon: const Icon(Icons.close, color: Colors.white),
                      onPressed: () {
                        if (context.canPop()) context.pop();
                      },
                    ),
                    const Spacer(),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: AppSpacing.md,
                        vertical: AppSpacing.xs,
                      ),
                      decoration: BoxDecoration(
                        color: AppColors.surface1.withValues(alpha: 0.85),
                        borderRadius: BorderRadius.circular(AppRadius.lg),
                      ),
                      child: Text(
                        'Move your phone to find a surface',
                        style: Theme.of(context)
                            .textTheme
                            .labelSmall
                            ?.copyWith(color: AppColors.textPrimary),
                      ),
                    ),
                    const Spacer(),
                    const SizedBox(width: 48),
                  ],
                ),
              ),
            ),
          ),
          Positioned(
            bottom: 0,
            left: 0,
            right: 0,
            child: SafeArea(
              child: Padding(
                padding: const EdgeInsets.all(AppSpacing.lg),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    SizedBox(
                      width: 120,
                      child: AppButton(label: 'Place', onPressed: () {}),
                    ),
                    const SizedBox(width: AppSpacing.md),
                    SizedBox(
                      width: 120,
                      child: AppButton.secondary(label: 'Reset', onPressed: () {}),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
