// lib/presentation/widgets/catalog/analytics_plate_card.dart
//
// "My plate" on the analytics screen (more-customization Stage 11): how many
// diners built a plate to show the waiter, what it was worth on average, and
// the dishes they added most. Renders nothing when nobody built one.
import 'package:flutter/material.dart';

import '../../../app/theme/app_colors.dart';
import '../../../app/theme/app_spacing.dart';
import '../../../domain/catalog/catalog_names.dart';
import '../../../domain/entities/catalog_analytics.dart';

class AnalyticsPlateCard extends StatelessWidget {
  const AnalyticsPlateCard({super.key, required this.stats});

  final PlateStats stats;

  @override
  Widget build(BuildContext context) {
    if (stats.plates == 0) return const SizedBox.shrink();
    final text = Theme.of(context).textTheme;
    final muted = text.bodySmall?.copyWith(color: AppColors.textMuted);

    Widget count(String label, String value) => Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(value, style: text.titleLarge?.copyWith(fontWeight: FontWeight.w700)),
            Text(label, style: muted),
          ],
        );

    return Padding(
      padding: const EdgeInsets.only(top: AppSpacing.lg),
      child: Container(
        key: const Key('analytics-plate'),
        padding: const EdgeInsets.all(AppSpacing.lg),
        decoration: BoxDecoration(color: AppColors.surface1, borderRadius: BorderRadius.circular(16)),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('My plate', style: text.titleMedium),
            const SizedBox(height: AppSpacing.md),
            Wrap(
              spacing: AppSpacing.xl,
              runSpacing: AppSpacing.md,
              children: [
                count('Plates built', '${stats.plates}'),
                if (stats.avgValue > 0) count('Avg plate value', '₹${stats.avgValue}'),
                count('Shown to waiter', '${stats.shownToWaiter}'),
                if (stats.sentWhatsapp > 0) count('Sent on WhatsApp', '${stats.sentWhatsapp}'),
              ],
            ),
            if (stats.topDishes.isNotEmpty) ...[
              const Divider(height: AppSpacing.xxl),
              Text('Most added', style: muted),
              const SizedBox(height: AppSpacing.xs),
              for (final d in stats.topDishes)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 2),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(catalogDisplayName(d.name),
                            overflow: TextOverflow.ellipsis, style: text.bodyMedium),
                      ),
                      Text('${d.adds}', style: text.bodyMedium?.copyWith(color: AppColors.textSecondary)),
                    ],
                  ),
                ),
            ],
          ],
        ),
      ),
    );
  }
}
