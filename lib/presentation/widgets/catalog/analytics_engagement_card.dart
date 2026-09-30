// lib/presentation/widgets/catalog/analytics_engagement_card.dart
//
// "Customer buttons" on the analytics screen (more-customization Stage 7.3):
// taps on Rate us / Order on WhatsApp / Call waiter, and what diners said
// through the feedback form — the average, the 1–5 spread and the newest
// comments. Renders nothing when none of it happened in the range.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/theme/app_colors.dart';
import '../../../app/theme/app_spacing.dart';
import '../../../data/repositories/menu_extras_repository.dart';
import '../../../domain/catalog/menu_extras.dart';
import '../../../domain/entities/catalog_analytics.dart';

class AnalyticsEngagementCard extends ConsumerWidget {
  const AnalyticsEngagementCard({super.key, required this.kpis, this.from, this.to});

  final AnalyticsKpis kpis;
  final String? from;
  final String? to;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Feedback is a best-effort extra: an older Mirage without the report
    // simply shows the counts.
    final feedback = ref.watch(catalogFeedbackProvider((from, to))).valueOrNull ?? FeedbackReport.empty;
    if (!kpis.hasEngagement && feedback.count == 0) return const SizedBox.shrink();

    final text = Theme.of(context).textTheme;
    final muted = text.bodySmall?.copyWith(color: AppColors.textMuted);

    return Padding(
      padding: const EdgeInsets.only(top: AppSpacing.lg),
      child: Container(
        key: const Key('analytics-engagement'),
        padding: const EdgeInsets.all(AppSpacing.lg),
        decoration: BoxDecoration(
          color: AppColors.surface1,
          borderRadius: BorderRadius.circular(16),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('Customer buttons', style: text.titleMedium),
            const SizedBox(height: AppSpacing.md),
            Wrap(
              spacing: AppSpacing.xl,
              runSpacing: AppSpacing.md,
              children: [
                _Count(label: 'Rate us taps', value: kpis.reviewClicks),
                _Count(label: 'WhatsApp orders', value: kpis.whatsappOrders),
                _Count(label: 'Waiter calls', value: kpis.waiterCalls),
                _Count(label: 'Feedback sent', value: feedback.count > 0 ? feedback.count : kpis.feedbackCount),
              ],
            ),
            if (feedback.count > 0) ...[
              const Divider(height: AppSpacing.xxl),
              Row(
                children: [
                  const Icon(Icons.star_rounded, color: AppColors.royalGold),
                  const SizedBox(width: AppSpacing.xs),
                  Text(
                    feedback.average?.toStringAsFixed(1) ?? '–',
                    style: text.headlineSmall,
                  ),
                  const SizedBox(width: AppSpacing.sm),
                  Text('from ${feedback.count} ${feedback.count == 1 ? 'rating' : 'ratings'}', style: muted),
                ],
              ),
              const SizedBox(height: AppSpacing.sm),
              for (var stars = 5; stars >= 1; stars--)
                _Bar(
                  stars: stars,
                  count: feedback.distribution[stars - 1],
                  total: feedback.count,
                ),
              if (feedback.recent.any((f) => f.comment.trim().isNotEmpty)) ...[
                const SizedBox(height: AppSpacing.md),
                Text('Latest comments', style: text.titleSmall),
                const SizedBox(height: AppSpacing.xs),
                for (final entry in feedback.recent.where((f) => f.comment.trim().isNotEmpty).take(8))
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: AppSpacing.xs),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('${'★' * entry.rating.clamp(0, 5)} ',
                            style: text.bodySmall?.copyWith(color: AppColors.royalGold)),
                        Expanded(child: Text(entry.comment, style: text.bodySmall)),
                      ],
                    ),
                  ),
              ],
            ],
          ],
        ),
      ),
    );
  }
}

class _Count extends StatelessWidget {
  const _Count({required this.label, required this.value});

  final String label;
  final int value;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('$value', style: text.titleLarge),
        Text(label, style: text.bodySmall?.copyWith(color: AppColors.textMuted)),
      ],
    );
  }
}

class _Bar extends StatelessWidget {
  const _Bar({required this.stars, required this.count, required this.total});

  final int stars;
  final int count;
  final int total;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: Row(
          children: [
            SizedBox(width: 22, child: Text('$stars★', style: Theme.of(context).textTheme.bodySmall)),
            Expanded(
              child: LinearProgressIndicator(
                value: total == 0 ? 0 : count / total,
                minHeight: 6,
                backgroundColor: AppColors.surface2,
                color: AppColors.royalGold,
              ),
            ),
            SizedBox(
              width: 32,
              child: Text('$count', textAlign: TextAlign.end, style: Theme.of(context).textTheme.bodySmall),
            ),
          ],
        ),
      );
}
