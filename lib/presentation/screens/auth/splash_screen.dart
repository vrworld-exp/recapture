// lib/presentation/screens/auth/splash_screen.dart
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import '../../../app/routes/app_router.dart';
import '../../../app/theme/app_colors.dart';
import '../../../app/theme/app_spacing.dart';
import '../../widgets/app_button.dart';
import '../../widgets/app_loading_indicator.dart';

class SplashScreen extends StatelessWidget {
  const SplashScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final tt = Theme.of(context).textTheme;
    return Scaffold(
      backgroundColor: AppColors.bgPrimary,
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: AppSpacing.screenPadding),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Container(
                width: 80,
                height: 80,
                decoration: BoxDecoration(
                  color: AppColors.mirageRed,
                  borderRadius: BorderRadius.circular(AppRadius.md),
                ),
                child: const Icon(Icons.videocam_rounded,
                    size: 40, color: Colors.white),
              ),
              const SizedBox(height: AppSpacing.xxl),
              Text('ReCapture', style: tt.displayLarge),
              const SizedBox(height: AppSpacing.sm),
              Text('Guided 3D Capture', style: tt.bodyMedium),
              const SizedBox(height: AppSpacing.huge * 2),
              const AppLoadingIndicator(size: 20),
              const SizedBox(height: AppSpacing.md),
              Text('Preparing capture tools…',
                  style: tt.bodySmall?.copyWith(color: AppColors.textMuted)),
              const SizedBox(height: AppSpacing.xxxl),
              AppButton(
                label: 'Get Started',
                onPressed: () => context.go(AppRoutes.auth),
              ),
              const SizedBox(height: AppSpacing.lg),
            ],
          ),
        ),
      ),
    );
  }
}
