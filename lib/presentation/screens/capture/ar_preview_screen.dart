// lib/presentation/screens/capture/ar_preview_screen.dart
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import '../../../app/theme/app_colors.dart';
import '../../../app/theme/app_spacing.dart';
import '../../widgets/app_button.dart';
import '../../widgets/placeholder_box.dart';

class ArPreviewScreen extends StatelessWidget {
  const ArPreviewScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      // Dark camera mock — not a brand color
      backgroundColor: const Color(0xFF0D0D0D),
      body: Stack(
        children: [
          // Camera background
          const Positioned.fill(
            child: PlaceholderBox(
              label: 'AR Camera View\nPoint phone at a flat surface',
              height: double.infinity,
              icon: Icons.camera,
            ),
          ),
          // Surface hint banner (top center)
          Positioned(
            top: AppSpacing.huge,
            left: 0,
            right: 0,
            child: Center(
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: AppSpacing.lg,
                  vertical: AppSpacing.sm,
                ),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(AppRadius.lg),
                  color: AppColors.surface1.withValues(alpha: 0.85),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.radar,
                        size: 16, color: AppColors.mirageRed),
                    const SizedBox(width: AppSpacing.sm),
                    Text(
                      'Move your phone to find a surface',
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                            color: AppColors.textPrimary,
                          ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          // Close button (top left)
          Positioned(
            top: AppSpacing.huge,
            left: AppSpacing.lg,
            child: SafeArea(
              child: Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: AppColors.surface1.withValues(alpha: 0.7),
                ),
                child: IconButton(
                  padding: EdgeInsets.zero,
                  icon: const Icon(Icons.close, color: Colors.white, size: 20),
                  onPressed: () => context.pop(),
                ),
              ),
            ),
          ),
          // Bottom controls
          Positioned(
            bottom: 0,
            left: 0,
            right: 0,
            child: SafeArea(
              child: Container(
                color: AppColors.surface1.withValues(alpha: 0.85),
                padding: const EdgeInsets.all(AppSpacing.lg),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                  children: [
                    Expanded(
                      child: AppButton(
                        label: 'Place',
                        onPressed: () {},
                      ),
                    ),
                    const SizedBox(width: AppSpacing.md),
                    Expanded(
                      child: AppButton.secondary(
                        label: 'Reset',
                        onPressed: () {},
                      ),
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
