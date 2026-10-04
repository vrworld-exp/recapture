// lib/presentation/widgets/catalog/plan_comparison_sheet.dart
//
// "Compare all benefits" on the Subscription screen (2026-10-04): every
// benefit the app gives, one row each, a ✓ / ✗ (or a count) per plan. A
// bottom sheet rather than a section, so the plan cards stay short and the Pay
// button stays in reach. Scrolls inside the sheet on a phone; capped at 640
// wide on web.
import 'package:flutter/material.dart';

import '../../../app/theme/app_colors.dart';
import '../../../app/theme/app_spacing.dart';
import '../../../domain/catalog/plan_benefits.dart';
import '../../../domain/entities/catalog_subscription.dart';

const _icons = <String, IconData>{
  'threeD': Icons.view_in_ar_outlined,
  'images': Icons.photo_library_outlined,
  'standees': Icons.qr_code_2,
  'hours': Icons.schedule,
  'diet': Icons.eco_outlined,
  'themes': Icons.palette_outlined,
  'badges': Icons.sell_outlined,
  'languages': Icons.translate,
  'spotlight': Icons.auto_awesome_outlined,
  'arBranding': Icons.view_in_ar,
  'brandedQr': Icons.qr_code_scanner,
  'offers': Icons.local_offer_outlined,
  'plate': Icons.restaurant_menu,
  'address': Icons.link,
  'whatsapp_instagram_buttons': Icons.chat_outlined,
  'website_embed': Icons.language,
  'per_dish_analytics': Icons.insights_outlined,
  'priority_support': Icons.support_agent,
};

/// The row's icon; a feature key this build does not know gets a star.
IconData benefitIcon(String id) => _icons[id] ?? Icons.star_outline;

/// The ✓ / ✗ mark, shared with the plan cards so both read the same.
class BenefitMark extends StatelessWidget {
  const BenefitMark({super.key, required this.included, this.value});

  final bool included;

  /// A count shown instead of the tick ("10 3D dishes").
  final String? value;

  @override
  Widget build(BuildContext context) {
    if (included && value != null) {
      return Text(
        value!,
        style: Theme.of(context).textTheme.labelLarge?.copyWith(
              color: AppColors.success,
              fontWeight: FontWeight.w700,
            ),
      );
    }
    return Icon(
      included ? Icons.check_circle_rounded : Icons.cancel_rounded,
      size: 18,
      color: included ? AppColors.success : AppColors.error.withValues(alpha: 0.75),
    );
  }
}

Future<void> showPlanComparison(
  BuildContext context, {
  required List<PlanDefinition> plans,
  required PlanId? currentPlanId,
}) =>
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: AppColors.surface1,
      constraints: const BoxConstraints(maxWidth: 640),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (_) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.85,
        minChildSize: 0.5,
        maxChildSize: 0.95,
        builder: (context, controller) => PlanComparison(
          plans: plans,
          currentPlanId: currentPlanId,
          controller: controller,
        ),
      ),
    );

class PlanComparison extends StatelessWidget {
  const PlanComparison({
    super.key,
    required this.plans,
    required this.currentPlanId,
    this.controller,
  });

  final List<PlanDefinition> plans;
  final PlanId? currentPlanId;
  final ScrollController? controller;

  static const _columnWidth = 64.0;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    // id → benefit, per plan. Rows are the union in first-seen order, so a
    // feature key only one plan carries still gets a row (✗ on the others).
    final perPlan = [
      for (final p in plans) {for (final b in planBenefits(p)) b.id: b},
    ];
    final rows = <PlanBenefit>[];
    final seen = <String>{};
    for (final m in perPlan) {
      for (final b in m.values) {
        if (seen.add(b.id)) rows.add(b);
      }
    }

    String shortName(PlanDefinition p) => p.displayName.replaceAll(RegExp(r'\s*plan$', caseSensitive: false), '');

    return Column(
      children: [
        const SizedBox(height: AppSpacing.sm),
        Container(
          width: 40,
          height: 4,
          decoration: BoxDecoration(
            color: AppColors.textMuted.withValues(alpha: 0.4),
            borderRadius: BorderRadius.circular(2),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(AppSpacing.lg, AppSpacing.md, AppSpacing.sm, AppSpacing.sm),
          child: Row(
            children: [
              Expanded(child: Text('Compare plans', style: text.titleLarge)),
              IconButton(
                tooltip: 'Close',
                icon: const Icon(Icons.close),
                onPressed: () => Navigator.of(context).maybePop(),
              ),
            ],
          ),
        ),
        // The plan names stay pinned while the rows scroll under them.
        Container(
          padding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg, vertical: AppSpacing.sm),
          decoration: BoxDecoration(
            border: Border(bottom: BorderSide(color: AppColors.royalGold.withValues(alpha: 0.25))),
          ),
          child: Row(
            children: [
              const Expanded(child: SizedBox.shrink()),
              for (final p in plans)
                SizedBox(
                  width: _columnWidth,
                  child: Column(
                    children: [
                      Text(
                        shortName(p),
                        textAlign: TextAlign.center,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: text.labelLarge?.copyWith(
                          color: p.planId == currentPlanId ? AppColors.royalGold : AppColors.textPrimary,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      if (p.planId == currentPlanId)
                        Text('Current', style: text.labelSmall?.copyWith(color: AppColors.royalGold)),
                    ],
                  ),
                ),
            ],
          ),
        ),
        Expanded(
          child: ListView(
            key: const ValueKey('plan_comparison_list'),
            controller: controller,
            padding: const EdgeInsets.fromLTRB(AppSpacing.lg, 0, AppSpacing.lg, AppSpacing.xxl),
            children: [
              for (final group in BenefitGroup.values) ...[
                Padding(
                  padding: const EdgeInsets.only(top: AppSpacing.lg, bottom: AppSpacing.xs),
                  child: Text(
                    group.title.toUpperCase(),
                    style: text.labelSmall?.copyWith(
                      color: AppColors.royalGold,
                      letterSpacing: 1.1,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                for (final row in rows.where((r) => r.group == group))
                  Container(
                    key: ValueKey('plan_comparison_row_${row.id}'),
                    padding: const EdgeInsets.symmetric(vertical: AppSpacing.sm),
                    decoration: BoxDecoration(
                      border: Border(
                        bottom: BorderSide(color: AppColors.textMuted.withValues(alpha: 0.12)),
                      ),
                    ),
                    child: Row(
                      children: [
                        Icon(benefitIcon(row.id), size: 18, color: AppColors.royalGold),
                        const SizedBox(width: AppSpacing.sm),
                        Expanded(
                          child: Text(
                            row.compareLabel,
                            style: text.bodySmall?.copyWith(color: AppColors.textPrimary),
                          ),
                        ),
                        for (final m in perPlan)
                          SizedBox(
                            width: _columnWidth,
                            child: Center(
                              child: BenefitMark(
                                included: m[row.id]?.included ?? false,
                                value: m[row.id]?.value,
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
              ],
            ],
          ),
        ),
      ],
    );
  }
}
