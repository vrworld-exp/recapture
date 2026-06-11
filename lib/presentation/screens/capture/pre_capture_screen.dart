// lib/presentation/screens/capture/pre_capture_screen.dart
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import '../../../app/routes/app_router.dart';
import '../../../app/theme/app_colors.dart';
import '../../../app/theme/app_spacing.dart';
import '../../widgets/app_button.dart';
import '../../widgets/app_card.dart';

class PreCaptureScreen extends StatelessWidget {
  const PreCaptureScreen({super.key});

  static const _items = [
    (Icons.wb_sunny_outlined, 'Use bright, even lighting', 'Avoid shadows and harsh flash'),
    (Icons.crop_square_outlined, 'Use a plain background', 'Recommended for clean edges'),
    (Icons.table_restaurant_outlined, 'Place on a stable surface', 'Object must not move'),
    (Icons.rotate_right, 'Move around the object', "Don't rotate the object itself"),
    (Icons.flash_off, 'Keep flash off', 'Flash creates reflections'),
  ];

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
        title: Text('Before you start', style: Theme.of(context).textTheme.titleLarge),
      ),
      body: Padding(
        padding: const EdgeInsets.all(AppSpacing.lg),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Check these before you begin for best results.',
              style: Theme.of(context).textTheme.bodyMedium,
            ),
            const SizedBox(height: AppSpacing.xxl),
            ..._items.map((item) => Padding(
                  padding: const EdgeInsets.only(bottom: AppSpacing.sm),
                  child: AppCard(
                    child: Row(
                      children: [
                        Container(
                          width: 32,
                          height: 32,
                          decoration: const BoxDecoration(
                            color: AppColors.mirageRed,
                            shape: BoxShape.circle,
                          ),
                          child: Icon(item.$1, color: Colors.white, size: AppSpacing.lg),
                        ),
                        const SizedBox(width: AppSpacing.md),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(item.$2, style: Theme.of(context).textTheme.bodyLarge),
                              Text(
                                item.$3,
                                style: Theme.of(context)
                                    .textTheme
                                    .bodySmall
                                    ?.copyWith(color: AppColors.textMuted),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                )),
            const SizedBox(height: AppSpacing.xxl),
            Container(height: 1, color: AppColors.royalGold.withValues(alpha: 0.3)),
            const SizedBox(height: AppSpacing.xxl),
            AppButton(
              label: 'Start Capture',
              onPressed: () => context.go(AppRoutes.permissions),
            ),
            const SizedBox(height: AppSpacing.md),
            AppButton.secondary(
              label: 'Back',
              onPressed: () {
                if (context.canPop()) context.pop();
              },
            ),
          ],
        ),
      ),
    );
  }
}
