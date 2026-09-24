// lib/presentation/screens/admin/admin_payment_widgets.dart
//
// The pieces the admin's payment surfaces share: the status chip, the filter
// chips, a payment-attempt tile with its five-step progress bar, and the
// date-and-time line. One file so the journal list, the per-catalog panel and
// the attempt screen draw a payment the same way on web and on the apk.
//
// FILTERS ARE A WRAP OF CHIPS, NOT A SEGMENTED BUTTON. Six segments in one
// horizontal SegmentedButton were cut off on a phone — and on web a mouse
// cannot drag a horizontal scroller, so the hidden ones were unreachable. A
// Wrap flows onto a second line instead: every filter is visible and tappable
// at any width.
import 'package:flutter/material.dart';

import '../../../app/theme/app_colors.dart';
import '../../../app/theme/app_spacing.dart';
import '../../../domain/catalog/subscription_copy.dart';
import '../../../domain/entities/admin_payment_attempt.dart';
import '../../../domain/entities/catalog_subscription.dart';
import '../../../domain/entities/subscription_payment.dart';
import '../../widgets/app_card.dart';

/// "24 Sep 2026, 14:02" in the device's time zone.
String formatAdminDateTime(DateTime utc) {
  final local = utc.toLocal();
  final hh = local.hour.toString().padLeft(2, '0');
  final mm = local.minute.toString().padLeft(2, '0');
  return '${formatSubscriptionDate(utc)}, $hh:$mm';
}

/// "Taste plan · monthly" — whatever of the two is known.
String planLine(String? planName, PlanId? planId, BillingInterval? interval) =>
    [
      if (planName != null && planName.isNotEmpty)
        planName
      else if (planId != null)
        planId.apiValue,
      if (interval != null) interval.apiValue.toLowerCase(),
    ].join(' · ');

Color stageColor(PaymentAttemptStage stage) => switch (stage) {
      PaymentAttemptStage.completed || PaymentAttemptStage.resolved =>
        AppColors.success,
      PaymentAttemptStage.paidNotApplied ||
      PaymentAttemptStage.flagged ||
      PaymentAttemptStage.notReflected =>
        AppColors.error,
      PaymentAttemptStage.inProgress => AppColors.warning,
      PaymentAttemptStage.notCompleted ||
      PaymentAttemptStage.refunded ||
      PaymentAttemptStage.unknown =>
        AppColors.textSecondary,
    };

Color stepColor(JournalStepState state) => switch (state) {
      JournalStepState.done => AppColors.success,
      JournalStepState.waiting => AppColors.warning,
      JournalStepState.failed => AppColors.error,
      JournalStepState.unknown => AppColors.textMuted,
      JournalStepState.skipped => AppColors.disabled,
    };

IconData stepIcon(JournalStepState state) => switch (state) {
      JournalStepState.done => Icons.check_circle,
      JournalStepState.waiting => Icons.schedule,
      JournalStepState.failed => Icons.error,
      JournalStepState.unknown => Icons.help_outline,
      JournalStepState.skipped => Icons.remove_circle_outline,
    };

/// A small tinted label.
class AdminStatusChip extends StatelessWidget {
  const AdminStatusChip({super.key, required this.label, required this.color});

  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.sm,
          vertical: 2,
        ),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.15),
          borderRadius: BorderRadius.circular(AppRadius.xs),
        ),
        child: Text(
          label,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: Theme.of(context).textTheme.labelSmall?.copyWith(color: color),
        ),
      );
}

/// Filter chips that WRAP — see the file header.
class AdminFilterChips<T> extends StatelessWidget {
  const AdminFilterChips({
    super.key,
    required this.values,
    required this.selected,
    required this.labelOf,
    required this.keyOf,
    required this.onSelected,
  });

  final List<T> values;
  final T selected;
  final String Function(T) labelOf;
  final String Function(T) keyOf;
  final ValueChanged<T> onSelected;

  @override
  Widget build(BuildContext context) => Wrap(
        spacing: AppSpacing.sm,
        runSpacing: AppSpacing.sm,
        children: [
          for (final value in values)
            ChoiceChip(
              key: ValueKey('admin_filter_${keyOf(value)}'),
              label: Text(labelOf(value)),
              selected: value == selected,
              showCheckmark: false,
              onSelected: (_) => onSelected(value),
            ),
        ],
      );
}

/// Five short bars, one per step, coloured by state — the whole pipeline at
/// a glance on a list row.
class PaymentStepBar extends StatelessWidget {
  const PaymentStepBar({super.key, required this.steps});

  final List<JournalStep> steps;

  @override
  Widget build(BuildContext context) => Row(
        children: [
          for (var i = 0; i < steps.length; i++) ...[
            if (i > 0) const SizedBox(width: 3),
            Expanded(
              child: Tooltip(
                message: steps[i].title,
                child: Container(
                  height: 4,
                  decoration: BoxDecoration(
                    color: stepColor(steps[i].state),
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
            ),
          ],
        ],
      );
}

/// One payment attempt on a list: restaurant, stage, amount, owner, when.
class PaymentAttemptTile extends StatelessWidget {
  const PaymentAttemptTile({
    super.key,
    required this.attempt,
    required this.onTap,
    this.showCatalog = true,
  });

  final PaymentAttempt attempt;
  final VoidCallback onTap;

  /// False inside one restaurant's panel, where the name is the page title.
  final bool showCatalog;

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    final plan = planLine(attempt.planName, attempt.planId, attempt.interval);
    final title = showCatalog
        ? (attempt.catalogName.isEmpty ? 'Restaurant' : attempt.catalogName)
        : '${formatPaise(attempt.displayPaise)}${plan.isEmpty ? '' : ' · $plan'}';
    final who = attempt.owner?.displayLabel ?? attempt.initiatedBy?.label;
    return AppCard(
      key: ValueKey('admin_attempt_${attempt.orderId}'),
      onTap: onTap,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: textTheme.bodyLarge,
                ),
              ),
              const SizedBox(width: AppSpacing.sm),
              Flexible(
                child: AdminStatusChip(
                  label: attempt.stage.label,
                  color: stageColor(attempt.stage),
                ),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.xs),
          if (showCatalog)
            Text(
              '${formatPaise(attempt.displayPaise)}${plan.isEmpty ? '' : ' · $plan'}',
              style: textTheme.bodySmall?.copyWith(color: AppColors.textSecondary),
            ),
          Text(
            [
              if (showCatalog && who != null) 'Owner: $who',
              if (attempt.startedAt != null)
                formatAdminDateTime(attempt.startedAt!),
            ].join(' · '),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: textTheme.bodySmall?.copyWith(color: AppColors.textMuted),
          ),
          if (attempt.steps.isNotEmpty) ...[
            const SizedBox(height: AppSpacing.sm),
            PaymentStepBar(steps: attempt.steps),
          ],
        ],
      ),
    );
  }
}
