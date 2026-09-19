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
//   • Decide that a payment happened. The Pay / Renew / Upgrade button opens
//     Razorpay INSIDE the app and then [CheckoutNotifier] polls the server
//     until it says ACTIVE (§7 rule 1). The SDK's "success" is never shown as
//     "paid"; the server's status is. On web there is no SDK (README C7), so
//     the button gives way to "Pay from the ReCapture app on your phone".
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/routes/flow_back.dart';
import '../../../app/theme/app_colors.dart';
import '../../../app/theme/app_spacing.dart';
import '../../../application/catalog/checkout_adapter.dart';
import '../../../application/catalog/checkout_notifier.dart';
import '../../../application/catalog/payment_history_notifier.dart';
import '../../../application/catalog/subscription_notifier.dart';
import '../../../data/repositories/catalog_failure.dart';
import '../../../domain/catalog/subscription_copy.dart';
import '../../../domain/entities/catalog_subscription.dart';
import '../../../domain/entities/subscription_payment.dart';
import '../../../utils/analytics.dart';
import '../../widgets/app_button.dart';
import '../../widgets/app_card.dart';
import '../../widgets/app_loading_indicator.dart';
import '../../widgets/catalog/catalog_feedback.dart';
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

    // The moment the server says ACTIVE, the ledger has a new row: refresh it
    // here, once, rather than making the history section watch the checkout.
    ref.listen<CheckoutState>(checkoutProvider, (previous, next) {
      if (next.phase == CheckoutPhase.done &&
          previous?.phase != CheckoutPhase.done) {
        ref.invalidate(paymentHistoryProvider);
        CatalogFeedback.confirm(
          CatalogFeedback.of(context),
          'Payment received — your plan is active.',
        );
      }
    });

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
/// test can render every status line with only the payment providers faked.
class SubscriptionBody extends ConsumerStatefulWidget {
  const SubscriptionBody({super.key, required this.subscription});

  final CatalogSubscription subscription;

  @override
  ConsumerState<SubscriptionBody> createState() => _SubscriptionBodyState();
}

class _SubscriptionBodyState extends ConsumerState<SubscriptionBody> {
  BillingInterval _interval = BillingInterval.monthly;

  /// The plan the button pays for. Starts on the plan that is running (a
  /// renewal is the common case) and otherwise on the first tier; tapping a
  /// card moves it.
  PlanId? _selectedPlan;

  PlanId get _effectivePlan {
    final chosen = _selectedPlan;
    if (chosen != null) return chosen;
    final current = widget.subscription.planId;
    if (current != null && current != PlanId.unknown) return current;
    final first = widget.subscription.plans.plans.firstOrNull?.planId;
    return first ?? PlanId.taste;
  }

  @override
  Widget build(BuildContext context) {
    final subscription = widget.subscription;
    final textTheme = Theme.of(context).textTheme;
    final selected = _effectivePlan;

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
            isSelected: plan.planId == selected,
            onTap: () => setState(() => _selectedPlan = plan.planId),
          ),
          const SizedBox(height: AppSpacing.sm),
        ],
        const SizedBox(height: AppSpacing.md),
        CheckoutSection(
          subscription: subscription,
          planId: selected,
          interval: _interval,
        ),
        const SizedBox(height: AppSpacing.xxl),
        const PaymentHistorySection(),
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
    required this.isSelected,
    required this.onTap,
  });

  final PlanDefinition plan;
  final BillingInterval interval;
  final bool isCurrent;

  /// The plan the Pay button is for. A tap moves it here.
  final bool isSelected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    final yearly = interval == BillingInterval.yearly;
    final price = yearly
        ? '${formatRupees(plan.yearlyPricePaise)} / year'
        : '${formatRupees(plan.priceMonthlyPaise)} / month';

    return AppCard(
      key: ValueKey('subscription_plan_${plan.planId.apiValue}'),
      onTap: onTap,
      border: isSelected
          ? const BorderSide(color: AppColors.royalGold, width: 1.5)
          : isCurrent
              ? BorderSide(color: AppColors.royalGold.withValues(alpha: 0.6))
              : null,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                isSelected
                    ? Icons.radio_button_checked
                    : Icons.radio_button_unchecked,
                size: 18,
                color: isSelected ? AppColors.royalGold : AppColors.textMuted,
              ),
              const SizedBox(width: AppSpacing.sm),
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

/// Pay / Renew / Upgrade — ONE button (§9) over the selected plan and
/// interval, the consent line above it (AC-5.2), and the checkout's progress
/// under it. On a target without the SDK it is the "pay from your phone" card.
class CheckoutSection extends ConsumerStatefulWidget {
  const CheckoutSection({
    super.key,
    required this.subscription,
    required this.planId,
    required this.interval,
  });

  final CatalogSubscription subscription;
  final PlanId planId;
  final BillingInterval interval;

  @override
  ConsumerState<CheckoutSection> createState() => _CheckoutSectionState();
}

class _CheckoutSectionState extends ConsumerState<CheckoutSection> {
  @override
  void initState() {
    super.initState();
    if (!ref.read(checkoutAdapterProvider).isSupported) {
      Analytics.logEvent('checkout_result', {'result': 'unsupported'});
    }
  }

  PlanDefinition? get _plan => widget.subscription.plans.byId(widget.planId);

  int get _amountPaise {
    final plan = _plan;
    if (plan == null) return 0;
    return widget.interval == BillingInterval.yearly
        ? plan.yearlyPricePaise
        : plan.priceMonthlyPaise;
  }

  Future<void> _confirmAndPay() async {
    final plan = _plan;
    if (plan == null) return;
    final label = checkoutButtonLabel(widget.subscription, widget.planId);
    final forfeit = paymentForfeitWarning(widget.subscription);
    final agreed = await showModalBottomSheet<bool>(
      context: context,
      backgroundColor: AppColors.surface1,
      isScrollControlled: true,
      builder: (ctx) => _PreCheckoutSheet(
        planName: plan.displayName,
        interval: widget.interval,
        amountPaise: _amountPaise,
        forfeitWarning: forfeit,
        buttonLabel: label,
      ),
    );
    if (agreed != true || !mounted) return;
    await ref.read(checkoutProvider.notifier).pay(
          planId: widget.planId,
          interval: widget.interval,
        );
  }

  @override
  Widget build(BuildContext context) {
    final adapter = ref.watch(checkoutAdapterProvider);
    final textTheme = Theme.of(context).textTheme;

    if (!adapter.isSupported) {
      return AppCard(
        key: const ValueKey('subscription_pay_from_phone'),
        child: Row(
          children: [
            const Icon(Icons.phone_iphone, color: AppColors.textSecondary),
            const SizedBox(width: AppSpacing.md),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Pay from the ReCapture app on your phone.',
                      style: textTheme.bodyMedium),
                  const SizedBox(height: AppSpacing.xs),
                  Text(
                    'In-app payment is available on Android and iOS. '
                    'Your plan and history show here on every device.',
                    style: textTheme.bodySmall
                        ?.copyWith(color: AppColors.textMuted),
                  ),
                ],
              ),
            ),
          ],
        ),
      );
    }

    final checkout = ref.watch(checkoutProvider);
    final subscription = widget.subscription;
    final label = checkoutButtonLabel(subscription, widget.planId);
    final forfeit = paymentForfeitWarning(subscription);
    final plan = _plan;

    return Column(
      key: const ValueKey('subscription_checkout_slot'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (forfeit != null && checkout.phase != CheckoutPhase.done) ...[
          Text(
            forfeit,
            key: const ValueKey('subscription_forfeit_warning'),
            style: textTheme.bodySmall?.copyWith(color: AppColors.warning),
          ),
          const SizedBox(height: AppSpacing.sm),
        ],
        Text(
          kPaymentConsentLine,
          key: const ValueKey('subscription_consent_line'),
          textAlign: TextAlign.center,
          style: textTheme.bodySmall?.copyWith(color: AppColors.textMuted),
        ),
        const SizedBox(height: AppSpacing.sm),
        _CheckoutProgress(checkout: checkout),
        if (checkout.phase != CheckoutPhase.activating)
          AppButton(
            key: const ValueKey('subscription_pay_button'),
            label: plan == null
                ? label
                : '$label · ${formatPaise(_amountPaise)}'
                    '${widget.interval == BillingInterval.yearly ? ' / year' : ' / month'}',
            icon: Icons.lock_outline,
            isLoading: checkout.isBusy,
            onPressed: plan == null || checkout.isBusy ? null : _confirmAndPay,
          ),
      ],
    );
  }
}

/// What the checkout is doing, in one line under (or instead of) the button.
class _CheckoutProgress extends StatelessWidget {
  const _CheckoutProgress({required this.checkout});

  final CheckoutState checkout;

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    final (String? text, Color color, bool spinner) = switch (checkout.phase) {
      CheckoutPhase.idle ||
      CheckoutPhase.quoting ||
      CheckoutPhase.showingSdk =>
        (null, AppColors.textMuted, false),
      CheckoutPhase.activating => (
          'Payment received, activating…',
          AppColors.textSecondary,
          true
        ),
      CheckoutPhase.done => ('Your plan is active.', AppColors.success, false),
      CheckoutPhase.confirming => (
          "Payment is being confirmed. You'll see it here shortly.",
          AppColors.textSecondary,
          false
        ),
      CheckoutPhase.unavailable => (
          "Couldn't reach the payment service, try again in a minute.",
          AppColors.warning,
          false
        ),
      CheckoutPhase.failed => (
          checkout.failureCode == 'UNSUPPORTED'
              ? 'In-app payment is not available on this device.'
              : 'The payment did not go through. Nothing was charged — '
                  'you can try again.',
          AppColors.error,
          false
        ),
    };
    if (text == null) return const SizedBox.shrink();
    return Padding(
      key: ValueKey('subscription_checkout_${checkout.phase.name}'),
      padding: const EdgeInsets.only(bottom: AppSpacing.sm),
      child: Row(
        children: [
          if (spinner) ...[
            const SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
            const SizedBox(width: AppSpacing.sm),
          ],
          Expanded(
            child:
                Text(text, style: textTheme.bodySmall?.copyWith(color: color)),
          ),
        ],
      ),
    );
  }
}

/// The terms sheet in front of the SDK: what is being bought, for how much,
/// the consent sentence again (AC-5.2), and the E9 warning when it applies.
class _PreCheckoutSheet extends StatelessWidget {
  const _PreCheckoutSheet({
    required this.planName,
    required this.interval,
    required this.amountPaise,
    required this.forfeitWarning,
    required this.buttonLabel,
  });

  final String planName;
  final BillingInterval interval;
  final int amountPaise;
  final String? forfeitWarning;
  final String buttonLabel;

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    final yearly = interval == BillingInterval.yearly;
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(
          AppSpacing.lg,
          AppSpacing.lg,
          AppSpacing.lg,
          AppSpacing.xxl,
        ),
        child: Column(
          key: const ValueKey('subscription_precheckout_sheet'),
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('Confirm your plan', style: textTheme.titleMedium),
            const SizedBox(height: AppSpacing.md),
            Text(
              '$planName · ${yearly ? 'yearly' : 'monthly'}',
              style: textTheme.bodyLarge,
            ),
            const SizedBox(height: AppSpacing.xs),
            Text(
              '${formatPaise(amountPaise)} ${yearly ? 'per year' : 'per month'}, '
              'billed now for ${yearly ? '365' : '30'} days.',
              style: textTheme.bodyMedium
                  ?.copyWith(color: AppColors.textSecondary),
            ),
            if (forfeitWarning != null) ...[
              const SizedBox(height: AppSpacing.md),
              Text(
                forfeitWarning!,
                style: textTheme.bodySmall?.copyWith(color: AppColors.warning),
              ),
            ],
            const SizedBox(height: AppSpacing.md),
            Text(
              kPaymentConsentLine,
              style: textTheme.bodySmall?.copyWith(color: AppColors.textMuted),
            ),
            const SizedBox(height: AppSpacing.lg),
            AppButton(
              key: const ValueKey('subscription_precheckout_continue'),
              label: 'Continue to $buttonLabel',
              icon: Icons.lock_outline,
              onPressed: () => Navigator.of(context).pop(true),
            ),
            const SizedBox(height: AppSpacing.sm),
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('Not now'),
            ),
          ],
        ),
      ),
    );
  }
}

/// The owner's ledger: `date · ₹amount · method · receipt no`, newest first.
/// A refund is a row like any other, in a muted style — the history is
/// honest, and there is no refund ACTION here (AC-5.1).
class PaymentHistorySection extends ConsumerWidget {
  const PaymentHistorySection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final history = ref.watch(paymentHistoryProvider);
    final textTheme = Theme.of(context).textTheme;

    return Column(
      key: const ValueKey('subscription_payment_history'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Payment history', style: textTheme.titleMedium),
        const SizedBox(height: AppSpacing.md),
        history.when(
          loading: () => const Padding(
            padding: EdgeInsets.all(AppSpacing.md),
            child: Center(child: AppLoadingIndicator()),
          ),
          error: (_, __) => Row(
            children: [
              Expanded(
                child: Text(
                  "Couldn't load your payments.",
                  style:
                      textTheme.bodySmall?.copyWith(color: AppColors.textMuted),
                ),
              ),
              TextButton(
                onPressed: () =>
                    ref.read(paymentHistoryProvider.notifier).refresh(),
                child: const Text('Retry'),
              ),
            ],
          ),
          data: (rows) => rows.isEmpty
              ? Text(
                  'No payments yet.',
                  key: const ValueKey('subscription_payment_history_empty'),
                  style:
                      textTheme.bodySmall?.copyWith(color: AppColors.textMuted),
                )
              : AppCard(
                  padding: const EdgeInsets.symmetric(
                    horizontal: AppSpacing.lg,
                    vertical: AppSpacing.sm,
                  ),
                  child: Column(
                    children: [
                      for (var i = 0; i < rows.length; i++) ...[
                        if (i > 0)
                          Divider(
                            height: AppSpacing.md,
                            color: AppColors.disabled.withValues(alpha: 0.3),
                          ),
                        PaymentHistoryRow(record: rows[i]),
                      ],
                    ],
                  ),
                ),
        ),
      ],
    );
  }
}

/// One ledger line. Public so the widget test can render the refund style.
class PaymentHistoryRow extends StatelessWidget {
  const PaymentHistoryRow({super.key, required this.record});

  final PaymentRecordSummary record;

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    final refund = record.kind == PaymentKind.refunded;
    final pendingCash = record.kind == PaymentKind.manual &&
        record.verificationStatus == VerificationStatus.pending;
    final muted = refund || record.kind == PaymentKind.checkoutCreated;
    final color = muted ? AppColors.textMuted : AppColors.textPrimary;
    final date = record.createdAt == null
        ? '—'
        : formatSubscriptionDate(record.createdAt!);
    final title = switch (record.kind) {
      PaymentKind.refunded => 'Refund',
      PaymentKind.checkoutCreated => 'Order started',
      PaymentKind.manual when pendingCash => 'Awaiting verification',
      _ => record.kind.label,
    };

    return Padding(
      key: ValueKey('payment_row_${record.id}'),
      padding: const EdgeInsets.symmetric(vertical: AppSpacing.xs),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '$date · ${record.methodLabel}',
                  style: textTheme.bodyMedium?.copyWith(color: color),
                ),
                const SizedBox(height: 2),
                Text(
                  '$title · ${record.receiptNo}',
                  style:
                      textTheme.bodySmall?.copyWith(color: AppColors.textMuted),
                ),
              ],
            ),
          ),
          Text(
            '${refund ? '−' : ''}${formatPaise(record.amountPaise)}',
            style: textTheme.bodyMedium?.copyWith(
              color: color,
              fontWeight: muted ? FontWeight.w400 : FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}
