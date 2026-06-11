// lib/presentation/screens/capture/uploading_screen.dart
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import '../../../app/routes/app_router.dart';
import '../../../app/theme/app_colors.dart';
import '../../../app/theme/app_spacing.dart';
import '../../widgets/app_button.dart';
import '../../widgets/app_scaffold.dart';

class UploadingScreen extends StatelessWidget {
  const UploadingScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final tt = Theme.of(context).textTheme;
    return Scaffold(
      backgroundColor: AppColors.bgPrimary,
      appBar: rcAppBar(context, title: 'Uploading', showBack: false),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(AppSpacing.screenPadding),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(Icons.cloud_upload_outlined,
                  size: 64, color: AppColors.mirageRed),
              const SizedBox(height: AppSpacing.xxl),
              Text(
                'Uploading your capture',
                style: tt.titleLarge,
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: AppSpacing.sm),
              Text(
                'Wi-Fi recommended for faster upload',
                style: tt.bodySmall?.copyWith(color: AppColors.textMuted),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: AppSpacing.xxxl),
              ClipRRect(
                borderRadius: BorderRadius.circular(AppRadius.xs),
                child: const LinearProgressIndicator(
                  value: 0.42,
                  backgroundColor: AppColors.surface2,
                  color: AppColors.mirageRed,
                  minHeight: 8,
                ),
              ),
              const SizedBox(height: AppSpacing.sm),
              Text(
                '42 / 120 files  •  84 MB / 620 MB',
                style: tt.bodySmall,
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: AppSpacing.xxxl),
              Container(height: 1,
                  color: AppColors.royalGold.withValues(alpha: 0.3)),
              const SizedBox(height: AppSpacing.xxl),
              AppButton.secondary(
                label: 'Pause',
                onPressed: () {},
              ),
              const SizedBox(height: AppSpacing.md),
              TextButton(
                onPressed: () => context.go(AppRoutes.projects),
                child: Text(
                  'Cancel upload',
                  style: tt.bodyMedium?.copyWith(color: AppColors.error),
                ),
              ),
              const SizedBox(height: AppSpacing.xxl),
              Container(
                  height: 1,
                  color: AppColors.disabled.withValues(alpha: 0.3)),
              const SizedBox(height: AppSpacing.lg),
              TextButton(
                onPressed: () => context.go(AppRoutes.processing),
                child: Text(
                  '→ Skip to Processing (skeleton nav)',
                  style: tt.bodySmall?.copyWith(color: AppColors.textMuted),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
