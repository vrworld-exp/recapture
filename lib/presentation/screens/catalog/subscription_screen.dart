// lib/presentation/screens/catalog/subscription_screen.dart
//
// The owner's Subscription screen (RECAPTURE_SUBSCRIPTION_PLAN.md §9): what
// the restaurant is on, how long is left, how many 3D dishes the plan covers
// against how many the menu carries, and the three plans side by side.
//
// THREE THINGS THIS SCREEN DOES NOT DO:
//   • Count days. `daysLeft` is the server's (D6) and is printed verbatim.
//   • Count dishes. `threeDDishCount` is the server's, over the same list the
//     publish gate counts (C1), so the usage row and the gate agree.
//   • Take money. There is no Pay / Renew / Upgrade button in this stage —
//     [_CheckoutSlot] is the named place Stage 3 fills, and until then the
//     line says who to talk to.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/routes/flow_back.dart';
import '../../../app/theme/app_colors.dart';
import '../../../app/theme/app_spacing.dart';
import '../../../application/catalog/subscription_notifier.dart';
import '../../../data/repositories/catalog_failure.dart';
import '../../../domain/catalog/subscription_copy.dart';
import '../../../domain/entities/catalog_subscription.dart';
import '../../../utils/analytics.dart';
import '../../widgets/app_card.dart';
import '../../widgets/app_loading_indicator.dart';
import '../../widgets/catalog/catalog_message.dart';

class SubscriptionScreen extends ConsumerStatefulWidget {
  const SubscriptionScreen({super.key});

  @override
  ConsumerState<SubscriptionScreen> createState() => _SubscriptionScreenState();
}

class _SubscriptionScreenState extends ConsumerState<SubscriptionScreen> {
  @override
  void initState() {
    super.initState();
    Analytics.logEvent('subscription_screen_viewed', {'surface': 'owner'});
  }

  @override
  Widget build(BuildContext context) {
    final subscription = ref.watch(subscriptionProvider);

    return Scaffold(
      backgroundColor: AppColors.bgPrimary,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          tooltip: 'Back',
          onPressed: () => navigateBack(context),
        ),
        title:
            Text('Subscription', style: Theme.of(context).textTheme.titleLarge),
      ),
      body: SafeArea(
        child: RefreshIndicator(
          onRefresh: () => ref.read(subscriptionProvider.notifier).refresh(),
          child: subscription.when(
            loading: () => const Center(child: AppLoadingIndicator()),
            error: (error, _) => _errorState(error),
            data: (data) => SubscriptionBody(subscription: data),
          ),
        ),
      ),
    );
  }

  Widget _errorState(Object error) {
    final failure = error is CatalogFailure ? error : null;
    if (failure?.isNoCatalog ?? false) {
      return const CatalogMessage(
        icon: Icons.storefront_outlined,
        title: 'No catalog yet',
        body: 'Create your catalog first — the subscription belongs to it.',
      );
    }
    return CatalogMessage(
      icon: Icons.cloud_off_outlined,
      title: "Couldn't load your subscription.",
      body: failure?.isOffline ?? false
          ? "You're offline. Reconnect and try again."
          : 'Check your connection and try again.',
      actionLabel: 'Try again',
      onAction: () => ref.read(subscriptionProvider.notifier).refresh(),
    );
  }
}

/// The screen's content, over a loaded subscription. Public so the widget
/// test can render every status line without a provider.
class SubscriptionBody extends StatefulWidget {
  const SubscriptionBody({super.key, required this.subscription});

  final CatalogSubscription subscription;

  @override
  State<SubscriptionBody> createState() => _SubscriptionBodyState();
}

class _SubscriptionBodyState extends State<SubscriptionBody> {
  BillingInterval _interval = BillingInterval.monthly;

  @override
  Widget build(BuildContext context) {
    final subscription = widget.subscription;
    final textTheme = Theme.of(context).textTheme;

    return ListView(
      key: const ValueKey('subscription_body'),
      padding: const EdgeInsets.all(AppSpacing.lg),
      children: [
        _StatusCard(subscription: subscription),
        const SizedBox(height: AppSpacing.md),
        _UsageCard(subscription: subscription),
        const SizedBox(height: AppSpacing.xxl),
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text('Plans', style: textTheme.titleMedium),
            SegmentedButton<BillingInterval>(
              key: const ValueKey('subscription_interval_toggle'),
              showSelectedIcon: false,
              segments: const [
                ButtonSegment(
                  value: BillingInterval.monthly,
                  label: Text('Monthly'),
                ),
                ButtonSegment(
                  value: BillingInterval.yearly,
                  label: Text('Yearly'),
                ),
              ],
              selected: {_interval},
              onSelectionChanged: (selection) =>
                  setState(() => _interval = selection.first),
            ),
          ],
        ),
        const SizedBox(height: AppSpacing.md),
        for (final plan in subscription.plans.plans) ...[
          _PlanCard(
            plan: plan,
            interval: _interval,
            isCurrent: subscription.planId == plan.planId &&
                subscription.status.isEntitled,
          ),
          const SizedBox(height: AppSpacing.sm),
        ],
        const SizedBox(height: AppSpacing.md),
        const _CheckoutSlot(),
        const SizedBox(height: AppSpacing.huge),
      ],
    );
  }
}

/// The status line and its date, coloured by how urgent it is.
class _StatusCard extends StatelessWidget {
  const _StatusCard({required this.subscription});

  final CatalogSubscription subscription;

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    final tone = subscriptionTone(subscription.status);
    final color = switch (tone) {
      SubscriptionTone.good => AppColors.success,
      SubscriptionTone.warning => AppColors.warning,
      SubscriptionTone.danger => AppColors.error,
      SubscriptionTone.neutral => AppColors.textSecondary,
    };
    final line = ownerStatusLine(
      subscription,
      trialThreeDCap: subscription.plans.trialThreeDCap,
    );

    return AppCard(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            switch (tone) {
              SubscriptionTone.good => Icons.verified_outlined,
              SubscriptionTone.warning => Icons.timer_outlined,
              SubscriptionTone.danger => Icons.error_outline,
              SubscriptionTone.neutral => Icons.info_outline,
            },
            size: 20,
            color: color,
          ),
          const SizedBox(width: AppSpacing.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  line,
                  key: const ValueKey('subscription_status_line'),
                  style: textTheme.bodyLarge
                      ?.copyWith(color: color, fontWeight: FontWeight.w600),
                ),
                if (subscription.status == SubscriptionStatus.grace &&
                    subscription.graceEndsAt != null) ...[
                  const SizedBox(height: AppSpacing.xs),
                  Text(
                    'Pay before '
                    '${formatSubscriptionDate(subscription.graceEndsAt!)} '
                    'to keep your 3D dishes live.',
                    style: textTheme.bodySmall
                        ?.copyWith(color: AppColors.textSecondary),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// "3D/AR dishes 12 / 15 (Signature plan)" and "Image dishes: unlimited".
class _UsageCard extends StatelessWidget {
  const _UsageCard({required this.subscription});

  final CatalogSubscription subscription;

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    final over = subscription.isOverCap;

    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Usage', style: textTheme.titleSmall),
          const SizedBox(height: AppSpacing.sm),
          _UsageRow(
            key: const ValueKey('subscription_usage_3d'),
            label: '3D/AR dishes',
            value: subscription.hasRow
                ? threeDUsageLine(subscription)
                : '${subscription.threeDDishCount}',
            color: over ? AppColors.error : AppColors.textPrimary,
          ),
          const SizedBox(height: AppSpacing.xs),
          _UsageRow(
            label: 'Image dishes',
            value: '${subscription.imageDishCount} · Unlimited',
            color: AppColors.textPrimary,
          ),
          if (over) ...[
            const SizedBox(height: AppSpacing.sm),
            Text(
              'More 3D dishes than your plan covers — publishing will ask '
              'you to upgrade or archive some.',
              style: textTheme.bodySmall?.copyWith(color: AppColors.error),
            ),
          ],
        ],
      ),
    );
  }
}

class _UsageRow extends StatelessWidget {
  const _UsageRow({
    super.key,
    required this.label,
    required this.value,
    required this.color,
  });

  final String label;
  final String value;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(label,
            style:
                textTheme.bodyMedium?.copyWith(color: AppColors.textSecondary)),
        Text(value,
            style: textTheme.bodyMedium
                ?.copyWith(color: color, fontWeight: FontWeight.w600)),
      ],
    );
  }
}

/// One plan, priced for the chosen interval. The yearly figure is the
/// server's formula rounded to whole rupees FOR DISPLAY (`formatRupees`);
/// the paise stay the truth.
class _PlanCard extends StatelessWidget {
  const _PlanCard({
    required this.plan,
    required this.interval,
    required this.isCurrent,
  });

  final PlanDefinition plan;
  final BillingInterval interval;
  final bool isCurrent;

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    final yearly = interval == BillingInterval.yearly;
    final price = yearly
        ? '${formatRupees(plan.yearlyPricePaise)} / year'
        : '${formatRupees(plan.priceMonthlyPaise)} / month';

    return AppCard(
      key: ValueKey('subscription_plan_${plan.planId.apiValue}'),
      border: isCurrent
          ? BorderSide(color: AppColors.royalGold.withValues(alpha: 0.6))
          : null,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(plan.displayName, style: textTheme.titleMedium),
              ),
              if (isCurrent)
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: AppSpacing.sm,
                    vertical: 2,
                  ),
                  decoration: BoxDecoration(
                    color: AppColors.royalGold.withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(AppRadius.xs),
                  ),
                  child: Text(
                    'Current plan',
                    style: textTheme.labelSmall
                        ?.copyWith(color: AppColors.royalGold),
                  ),
                ),
            ],
          ),
          const SizedBox(height: AppSpacing.xs),
          Row(
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: [
              Text(
                price,
                style: textTheme.titleLarge
                    ?.copyWith(color: AppColors.textPrimary),
              ),
              if (yearly) ...[
                const SizedBox(width: AppSpacing.sm),
                Text(
                  'save ${plan.yearlyDiscountPct}%',
                  style:
                      textTheme.labelMedium?.copyWith(color: AppColors.success),
                ),
              ],
            ],
          ),
          const SizedBox(height: AppSpacing.sm),
          _Feature('Up to ${plan.threeDDishCap} 3D/AR dishes'),
          const _Feature('Unlimited image dishes'),
          _Feature('${plan.includedStandeeCount} QR-code standees included'),
          for (final feature in plan.features) _Feature(_featureLabel(feature)),
        ],
      ),
    );
  }

  static String _featureLabel(String feature) => switch (feature) {
        'whatsapp_instagram_buttons' => 'WhatsApp & Instagram buttons',
        'website_embed' => 'AR menu on your own website',
        'per_dish_analytics' => 'Per-dish view analytics',
        'priority_support' => 'Priority call support',
        _ => feature.replaceAll('_', ' '),
      };
}

class _Feature extends StatelessWidget {
  const _Feature(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(top: AppSpacing.xs),
        child: Row(
          children: [
            const Icon(Icons.check, size: 16, color: AppColors.success),
            const SizedBox(width: AppSpacing.sm),
            Expanded(
              child: Text(
                text,
                style: Theme.of(context)
                    .textTheme
                    .bodySmall
                    ?.copyWith(color: AppColors.textSecondary),
              ),
            ),
          ],
        ),
      );
}

/// Where the Pay / Renew / Upgrade control lands in Stage 3. Until then a
/// sentence, deliberately: a button that opens nothing is worse than none.
class _CheckoutSlot extends StatelessWidget {
  const _CheckoutSlot();

  @override
  Widget build(BuildContext context) => Padding(
        key: const ValueKey('subscription_checkout_slot'),
        padding: const EdgeInsets.symmetric(horizontal: AppSpacing.sm),
        child: Text(
          'Talk to your sales rep to activate or change a plan. '
          'In-app payment is coming soon.',
          textAlign: TextAlign.center,
          style: Theme.of(context)
              .textTheme
              .bodySmall
              ?.copyWith(color: AppColors.textMuted),
        ),
      );
}
