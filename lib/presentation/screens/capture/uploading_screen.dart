// lib/presentation/screens/capture/uploading_screen.dart
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import '../../../app/routes/app_router.dart';
import '../../../app/theme/app_colors.dart';
import '../../../app/theme/app_spacing.dart';
import '../../widgets/app_button.dart';

class UploadingScreen extends StatefulWidget {
  const UploadingScreen({super.key});

  @override
  State<UploadingScreen> createState() => _UploadingScreenState();
}

class _UploadingScreenState extends State<UploadingScreen>
    with SingleTickerProviderStateMixin {
  late final AnimationController _pulseController;
  late final Animation<double> _scaleAnim;
  Timer? _autoNavTimer;

  @override
  void initState() {
    super.initState();
    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 900),
    )..repeat(reverse: true);

    _scaleAnim = Tween<double>(begin: 1.0, end: 1.1).animate(
      CurvedAnimation(parent: _pulseController, curve: Curves.easeInOut),
    );

    _autoNavTimer = Timer(const Duration(seconds: 3), () {
      if (mounted) context.go(AppRoutes.processing);
    });
  }

  @override
  void dispose() {
    _pulseController.dispose();
    _autoNavTimer?.cancel();
    super.dispose();
  }

  void _showCancelDialog() {
    showDialog<void>(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: AppColors.surface1,
        title: Text('Cancel upload?',
            style: Theme.of(context).textTheme.titleLarge),
        content: Text('Keep project as Draft.',
            style: Theme.of(context).textTheme.bodyMedium),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Keep Uploading'),
          ),
          TextButton(
            onPressed: () {
              Navigator.of(context).pop();
              context.go(AppRoutes.projects);
            },
            style: TextButton.styleFrom(foregroundColor: AppColors.error),
            child: const Text('Cancel'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.bgPrimary,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        automaticallyImplyLeading: false,
        title: Text('Uploading', style: Theme.of(context).textTheme.titleLarge),
      ),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(AppSpacing.lg),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const SizedBox(height: AppSpacing.huge),
              ScaleTransition(
                scale: _scaleAnim,
                child: const Icon(
                  Icons.cloud_upload_outlined,
                  size: 64,
                  color: AppColors.mirageRed,
                ),
              ),
              const SizedBox(height: AppSpacing.xxl),
              Text(
                'Uploading your capture',
                style: Theme.of(context).textTheme.titleLarge,
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: AppSpacing.md),
              Text(
                'Wi-Fi recommended for faster upload',
                style: Theme.of(context)
                    .textTheme
                    .bodySmall
                    ?.copyWith(color: AppColors.textMuted),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: AppSpacing.xxl),
              ClipRRect(
                borderRadius: BorderRadius.circular(4),
                child: const LinearProgressIndicator(
                  value: 0.42,
                  color: AppColors.mirageRed,
                  backgroundColor: AppColors.surface2,
                  minHeight: 8,
                ),
              ),
              const SizedBox(height: AppSpacing.sm),
              Text(
                '42 / 120 files • 84 MB / 620 MB',
                style: Theme.of(context)
                    .textTheme
                    .bodySmall
                    ?.copyWith(color: AppColors.textMuted),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: AppSpacing.huge),
              Container(height: 1, color: AppColors.royalGold.withValues(alpha: 0.3)),
              const SizedBox(height: AppSpacing.xxl),
              AppButton.secondary(label: 'Pause', onPressed: () {}),
              const SizedBox(height: AppSpacing.md),
              TextButton(
                onPressed: _showCancelDialog,
                style: TextButton.styleFrom(foregroundColor: AppColors.error),
                child: const Text('Cancel upload'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
