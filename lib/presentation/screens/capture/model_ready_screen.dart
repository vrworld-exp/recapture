// lib/presentation/screens/capture/model_ready_screen.dart
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import '../../../app/routes/app_router.dart';
import '../../../app/theme/app_colors.dart';
import '../../../app/theme/app_spacing.dart';
import '../../../app/theme/app_typography.dart';
import '../../widgets/app_button.dart';
import '../../widgets/app_card.dart';
import '../../widgets/placeholder_box.dart';

class ModelReadyScreen extends StatelessWidget {
  const ModelReadyScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final tt = Theme.of(context).textTheme;
    return Scaffold(
      backgroundColor: AppColors.bgPrimary,
      appBar: AppBar(
        backgroundColor: AppColors.bgPrimary,
        elevation: 0,
        scrolledUnderElevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_ios_new,
              color: AppColors.textPrimary, size: 18),
          onPressed: () => context.go(AppRoutes.projects),
        ),
        title: Row(
          children: [
            Container(
              width: 8,
              height: 8,
              decoration: const BoxDecoration(
                shape: BoxShape.circle,
                color: AppColors.success,
              ),
            ),
            const SizedBox(width: AppSpacing.sm),
            Text('Model Ready', style: tt.headlineMedium),
          ],
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.more_vert, color: AppColors.textSecondary),
            onPressed: () {},
          ),
        ],
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const PlaceholderBox(
                label: '3D Model Viewer\nGLB preview — tap to interact',
                height: 280,
                icon: Icons.view_in_ar_rounded,
              ),
              Container(height: 1,
                  color: AppColors.royalGold.withValues(alpha: 0.4)),
              const Padding(
                padding: EdgeInsets.symmetric(
                  horizontal: AppSpacing.screenPadding,
                  vertical: AppSpacing.md,
                ),
                child: Row(
                  children: [
                    _MetaChip('v1'),
                    SizedBox(width: AppSpacing.sm),
                    _MetaChip('18 MB'),
                    SizedBox(width: AppSpacing.sm),
                    _MetaChip('Updated today'),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(
                    horizontal: AppSpacing.screenPadding),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    AppButton(
                      label: 'AR Preview',
                      icon: Icons.view_in_ar,
                      onPressed: () => context.push(AppRoutes.arPreview),
                    ),
                    const SizedBox(height: AppSpacing.sm),
                    AppButton.secondary(
                      label: 'Share Link',
                      icon: Icons.share_outlined,
                      onPressed: () {},
                    ),
                    const SizedBox(height: AppSpacing.sm),
                    AppButton.secondary(
                      label: 'Re-capture',
                      icon: Icons.refresh,
                      onPressed: () => context.go(AppRoutes.preCapture),
                    ),
                    const SizedBox(height: AppSpacing.xxl),
                    AppCard(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text('Version History', style: tt.headlineMedium),
                          const SizedBox(height: AppSpacing.lg),
                          const _VersionRow(
                            version: 'v1',
                            date: 'Today',
                            size: '18 MB',
                            statusColor: AppColors.success,
                          ),
                          Divider(
                            color: AppColors.disabled.withValues(alpha: 0.5),
                            thickness: 0.5,
                          ),
                          const _VersionRow(
                            version: 'v0',
                            date: 'Yesterday',
                            size: '22 MB',
                            statusColor: AppColors.error,
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: AppSpacing.xxl),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _MetaChip extends StatelessWidget {
  const _MetaChip(this.label);
  final String label;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.sm,
        vertical: AppSpacing.xs,
      ),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(AppRadius.xs),
        color: AppColors.surface2,
      ),
      child: Text(
        label,
        style: const TextStyle(
          fontSize: AppTypography.sizeLabel,
          fontWeight: FontWeight.w500,
          color: AppColors.textSecondary,
        ),
      ),
    );
  }
}

class _VersionRow extends StatelessWidget {
  const _VersionRow({
    required this.version,
    required this.date,
    required this.size,
    required this.statusColor,
  });

  final String version;
  final String date;
  final String size;
  final Color statusColor;

  @override
  Widget build(BuildContext context) {
    final tt = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: AppSpacing.md),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Row(
            children: [
              Container(
                width: 8,
                height: 8,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: statusColor,
                ),
              ),
              const SizedBox(width: AppSpacing.sm),
              Text(version, style: tt.bodyLarge),
            ],
          ),
          Text('$date  •  $size', style: tt.bodySmall),
        ],
      ),
    );
  }
}
