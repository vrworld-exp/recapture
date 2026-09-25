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
//     "paid"; the server's status is. The sheet is the native SDK on
//     Android/iOS and Razorpay's Checkout.js overlay in a browser (README
//     C7); only desktop has neither, and there the button gives way to
//     "Pay from the ReCapture app on your phone".
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/routes/app_router.dart' show AppRoutes;
import '../../../app/routes/flow_back.dart';
import '../../../app/theme/app_colors.dart';
import '../../../app/theme/app_spacing.dart';
import '../../../application/catalog/catalog_qr_service.dart';
import '../../../application/catalog/checkout_adapter.dart';
import '../../../application/catalog/checkout_notifier.dart';
import '../../../application/catalog/payment_history_notifier.dart';
import '../../../application/catalog/subscription_notifier.dart';
import '../../../data/repositories/catalog_failure.dart';
import '../../../data/repositories/payments_repository.dart';
import '../../../domain/catalog/subscription_copy.dart';
import '../../../domain/entities/catalog_subscription.dart';
import '../../../domain/entities/subscription_payment.dart';
import '../../../utils/analytics.dart';
import '../../widgets/app_button.dart';
import '../../widgets/app_card.dart';
import '../../widgets/app_loading_indicator.dart';
import '../../widgets/catalog/catalog_feedback.dart';
import '../../widgets/catalog/catalog_message.dart';

/// The query flag the PUBLISH screen adds when it sends the owner here:
/// `?fromPublish=1`.
///
/// The owner did not come to read about plans — they pressed Publish, were
/// handed a paywall, and this screen is a detour. So once the server says the
/// plan is active, the screen offers the way back to the thing they were doing,
/// which resumes the publish by itself (see `PublishScreen._maybeAutoStart`).
/// Without the flag, paying here ends here, which is right for the header chip
/// and the Profile door.
const String kSubscriptionFromPublishQuery = 'fromPublish';

class SubscriptionScreen extends ConsumerStatefulWidget {
  const SubscriptionScreen({super.key, this.fromPublish = false});

  /// Opened from the publish screen's paywall — see
  /// [kSubscriptionFromPublishQuery].
  final bool fromPublish;

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
          next.isDeferredAutopay
              ? 'Autopay is on — your plan will renew by itself.'
              : 'Payment received — your plan is active.',
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
            data: (data) => SubscriptionBody(
              subscription: data,
              fromPublish: widget.fromPublish,
            ),
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
  const SubscriptionBody({
    super.key,
    required this.subscription,
    this.fromPublish = false,
  });

  final CatalogSubscription subscription;

  /// See [kSubscriptionFromPublishQuery]. Adds the "back to publishing" card
  /// once the plan is active, and nothing else.
  final bool fromPublish;

  @override
  ConsumerState<SubscriptionBody> createState() => _SubscriptionBodyState();
}

class _SubscriptionBodyState extends ConsumerState<SubscriptionBody> {
  BillingInterval _interval = BillingInterval.monthly;

  /// Where an offer in the overview scrolls to: the plan cards and the
  /// button, with the offer's plan and interval already selected.
  final GlobalKey _plansKey = GlobalKey();

  /// An offer was tapped: select what it offers and bring the plans and the
  /// button into view. Nothing is bought here — the button still asks.
  void _takeOffer({PlanId? planId, BillingInterval? interval}) {
    setState(() {
      if (planId != null) _selectedPlan = planId;
      if (interval != null) _interval = interval;
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final target = _plansKey.currentContext;
      if (target == null || !mounted) return;
      Scrollable.ensureVisible(
        target,
        duration: const Duration(milliseconds: 350),
        curve: Curves.easeOutCubic,
      );
    });
  }

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
    final priceNotice = lockedPriceNotice(subscription);

    return ListView(
      key: const ValueKey('subscription_body'),
      padding: const EdgeInsets.all(AppSpacing.lg),
      children: [
        // FIRST, and only after the SERVER says the plan is live — the phase is
        // CheckoutNotifier's, which reaches `done` by polling the subscription
        // until the status actually flips, never on the SDK's own "success".
        if (widget.fromPublish &&
            ref.watch(checkoutProvider).phase == CheckoutPhase.done) ...[
          const _BackToPublishingCard(),
          const SizedBox(height: AppSpacing.md),
        ],
        // An owner ON a plan gets the plan itself first — about 70% of the
        // screen: what they have, how long it runs, what it includes, what
        // they could switch to. Everything else (other plans, the button,
        // history) follows below, as before.
        if (_PlanOverview.showsFor(subscription)) ...[
          ConstrainedBox(
            constraints: BoxConstraints(
              // 70% of the screen on a phone; capped so a tablet or a wide
              // browser does not get a mostly empty block.
              minHeight: (MediaQuery.sizeOf(context).height * 0.7)
                  .clamp(0.0, 720.0),
            ),
            child: _PlanOverview(
              subscription: subscription,
              onSwitchToYearly: () => _takeOffer(
                planId: subscription.planId,
                interval: BillingInterval.yearly,
              ),
              onSeePlan: (planId) => _takeOffer(planId: planId),
            ),
          ),
        ] else ...[
          _StatusCard(subscription: subscription),
          if (_AutopayCard.showsFor(subscription)) ...[
            const SizedBox(height: AppSpacing.md),
            _AutopayCard(subscription: subscription),
          ],
          const SizedBox(height: AppSpacing.md),
          _UsageCard(subscription: subscription),
        ],
        const SizedBox(height: AppSpacing.xxl),
        Row(
          key: _plansKey,
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
        // REQUIREMENT 1. Prices are being served at testing rates, so say so
        // ABOVE the cards rather than next to one of them: the badge is about
        // every number below it, and a restaurant that agrees to ₹3 on the
        // strength of an unlabelled card is owed ₹3 forever.
        if (subscription.plans.testingPrices) ...[
          const SizedBox(height: AppSpacing.md),
          const _TestingPricesBadge(),
        ],
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
          // B6: the price moved since this period was bought. Said once,
          // under the plan it is about, and only on the day it is true.
          if (priceNotice != null && subscription.planId == plan.planId)
            Padding(
              padding: const EdgeInsets.only(
                left: AppSpacing.sm,
                right: AppSpacing.sm,
                top: AppSpacing.xs,
              ),
              child: Text(
                priceNotice,
                key: const ValueKey('subscription_price_change_notice'),
                style:
                    textTheme.bodySmall?.copyWith(color: AppColors.warning),
              ),
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

/// "Your plan is active — back to publishing", for an owner who only came here
/// because Publish sent them.
///
/// A BUTTON, NOT AN AUTOMATIC POP. The screen could take itself off the stack
/// the moment the plan flips, and that is one tap fewer — but it would also
/// snatch away the receipt, the new period's dates and the confirmation of a
/// payment that just left the owner's bank, which is the last moment to be
/// clever with. So the way out is offered, prominently and first, and pressing
/// it lands back on the publish screen where the run the owner originally asked
/// for starts on its own.
class _BackToPublishingCard extends StatelessWidget {
  const _BackToPublishingCard();

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    return AppCard(
      key: const ValueKey('subscription_back_to_publish'),
      border: const BorderSide(color: AppColors.success, width: 1.5),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              const Icon(Icons.check_circle_outline,
                  size: 20, color: AppColors.success),
              const SizedBox(width: AppSpacing.sm),
              Expanded(
                child: Text(
                  'Your plan is active',
                  style: textTheme.titleMedium?.copyWith(
                    color: AppColors.success,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.xs),
          Text(
            'Nothing is blocking your menu now — go back and it publishes.',
            style: textTheme.bodyMedium?.copyWith(
              color: AppColors.textSecondary,
              height: 1.4,
            ),
          ),
          const SizedBox(height: AppSpacing.md),
          AppButton(
            key: const ValueKey('subscription_back_to_publish_cta'),
            label: 'Back to publishing',
            icon: Icons.cloud_upload_outlined,
            onPressed: () => navigateBack(context),
          ),
        ],
      ),
    );
  }
}

/// The owner's plan, in full — the top of the screen for anyone ON one (a paid
/// plan, in or out of grace, a trial, a comp). One card, read top to bottom:
///
///   YOUR PLAN · status chip
///   Plan name, price
///   days-left ring  |  renews / ends on …, grace, autopay
///   the status sentence (the same one every surface uses)
///   autopay card
///   usage tiles: 3D dishes, image dishes, QR standees, billing
///   what's included
///   offers: yearly saving, the next tier up
///   See catalog
///
/// Every number is the SERVER's (daysLeft D6, the counts C1); the ring's
/// fraction is only that number over the period's nominal length.
class _PlanOverview extends StatelessWidget {
  const _PlanOverview({
    required this.subscription,
    required this.onSwitchToYearly,
    required this.onSeePlan,
  });

  final CatalogSubscription subscription;
  final VoidCallback onSwitchToYearly;
  final ValueChanged<PlanId> onSeePlan;

  static bool showsFor(CatalogSubscription subscription) =>
      switch (subscription.status) {
        SubscriptionStatus.active ||
        SubscriptionStatus.grace ||
        SubscriptionStatus.trial ||
        SubscriptionStatus.comped =>
          true,
        _ => false,
      };

  PlanDefinition? get _plan {
    final snapshot = subscription.planSnapshot;
    if (snapshot != null) return snapshot;
    final id = subscription.planId;
    return id == null ? null : subscription.plans.byId(id);
  }

  bool get _yearly => subscription.billingInterval == BillingInterval.yearly;

  String get _title {
    final name = subscription.planName ?? _plan?.displayName;
    return switch (subscription.status) {
      SubscriptionStatus.trial => 'Free trial',
      SubscriptionStatus.comped => 'Complimentary plan',
      _ => name ?? 'Your plan',
    };
  }

  String? get _priceLine {
    final plan = _plan;
    switch (subscription.status) {
      case SubscriptionStatus.trial:
        return 'Free for ${subscription.plans.trialDays} days';
      case SubscriptionStatus.comped:
        return 'No charge — on us';
      default:
        if (plan == null) return null;
        return _yearly
            ? '${formatRupees(plan.yearlyPricePaise)} / year'
            : '${formatRupees(plan.priceMonthlyPaise)} / month';
    }
  }

  (String, Color) get _chip => switch (subscription.status) {
        SubscriptionStatus.active => ('Active', AppColors.success),
        SubscriptionStatus.grace => ('Grace period', AppColors.warning),
        SubscriptionStatus.trial => ('Trial', AppColors.royalGold),
        SubscriptionStatus.comped => ('Complimentary', AppColors.success),
        _ => ('', AppColors.textSecondary),
      };

  /// The period's nominal length in days, for the ring. Null = no ring
  /// fraction worth drawing (a comp runs to whatever date an admin chose).
  int? get _periodDays => switch (subscription.status) {
        SubscriptionStatus.trial => subscription.plans.trialDays,
        SubscriptionStatus.grace => subscription.plans.graceDays,
        SubscriptionStatus.active => _yearly ? 365 : 30,
        _ => null,
      };

  /// "Renews by autopay on …" / "Renews on …" / "Ends on …", or in grace
  /// "Grace ends on …". Null when there is no date.
  (String, DateTime)? get _keyDate {
    final autopay = subscription.autopay;
    if (subscription.status == SubscriptionStatus.grace) {
      final end = subscription.graceEndsAt;
      return end == null ? null : ('Grace ends on', end);
    }
    final end = subscription.periodEnd;
    if (end == null) return null;
    if (subscription.status == SubscriptionStatus.active &&
        autopay != null &&
        autopay.isHealthy) {
      return ('Renews by autopay on', autopay.nextChargeAt ?? end);
    }
    return ('Ends on', end);
  }

  /// The next tier up from the running plan, when there is one.
  PlanDefinition? get _nextTier {
    final plans = subscription.plans.plans;
    final current = subscription.planId;
    if (current == null ||
        subscription.status == SubscriptionStatus.trial ||
        subscription.status == SubscriptionStatus.comped) {
      return null;
    }
    final index = plans.indexWhere((p) => p.planId == current);
    if (index < 0 || index + 1 >= plans.length) return null;
    return plans[index + 1];
  }

  static String _featureLabel(String feature) => _PlanCard._featureLabel(feature);

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    final (chipLabel, chipColor) = _chip;
    final plan = _plan;
    final priceLine = _priceLine;
    final keyDate = _keyDate;
    final standees = standeeDeliveryLine(subscription);
    final over = subscription.isOverCap;
    final days = subscription.daysLeft;
    final total = _periodDays;
    final fraction = days == null || total == null || total <= 0
        ? null
        : (days / total).clamp(0.0, 1.0);
    final ringColor = switch (subscription.status) {
      SubscriptionStatus.grace => AppColors.warning,
      _ when days != null && days <= 3 => AppColors.warning,
      _ => AppColors.royalGold,
    };
    final nextTier = _nextTier;

    return Container(
      key: const ValueKey('subscription_plan_overview'),
      padding: const EdgeInsets.all(AppSpacing.lg),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(AppRadius.md),
        border: Border.all(color: AppColors.royalGold.withValues(alpha: 0.45)),
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            AppColors.royalGold.withValues(alpha: 0.16),
            AppColors.surface1,
            AppColors.surface1,
          ],
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // ── Header ──────────────────────────────────────────────────────
          Row(
            children: [
              Text(
                'YOUR PLAN',
                style: textTheme.labelSmall?.copyWith(
                  color: AppColors.royalGold,
                  letterSpacing: 1.4,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const Spacer(),
              Container(
                key: const ValueKey('subscription_overview_chip'),
                padding: const EdgeInsets.symmetric(
                  horizontal: AppSpacing.sm,
                  vertical: 2,
                ),
                decoration: BoxDecoration(
                  color: chipColor.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(AppRadius.xs),
                ),
                child: Text(
                  chipLabel,
                  style: textTheme.labelSmall?.copyWith(
                    color: chipColor,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.sm),
          Text(
            _title,
            key: const ValueKey('subscription_overview_title'),
            style: textTheme.headlineSmall?.copyWith(
              color: AppColors.textPrimary,
              fontWeight: FontWeight.w700,
            ),
          ),
          if (priceLine != null) ...[
            const SizedBox(height: AppSpacing.xs),
            Text(
              priceLine,
              key: const ValueKey('subscription_overview_price'),
              style: textTheme.titleMedium?.copyWith(color: AppColors.goldGlow),
            ),
          ],
          const SizedBox(height: AppSpacing.xl),

          // ── Days left + the date that matters ───────────────────────────
          Row(
            children: [
              SizedBox(
                width: 112,
                height: 112,
                child: Stack(
                  alignment: Alignment.center,
                  children: [
                    SizedBox.expand(
                      child: CircularProgressIndicator(
                        value: fraction ?? 1,
                        strokeWidth: 8,
                        backgroundColor:
                            AppColors.disabled.withValues(alpha: 0.35),
                        valueColor: AlwaysStoppedAnimation(ringColor),
                      ),
                    ),
                    Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          days == null ? '—' : '$days',
                          key: const ValueKey('subscription_overview_days'),
                          style: textTheme.headlineMedium?.copyWith(
                            color: AppColors.textPrimary,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        Text(
                          days == 1 ? 'day left' : 'days left',
                          style: textTheme.labelSmall
                              ?.copyWith(color: AppColors.textSecondary),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              const SizedBox(width: AppSpacing.lg),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (keyDate != null) ...[
                      Text(
                        keyDate.$1,
                        style: textTheme.bodySmall
                            ?.copyWith(color: AppColors.textMuted),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        formatSubscriptionDate(keyDate.$2),
                        key: const ValueKey('subscription_overview_date'),
                        style: textTheme.titleMedium?.copyWith(
                          color: AppColors.textPrimary,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: AppSpacing.sm),
                    ],
                    // The same sentence every surface uses for this status.
                    Text(
                      ownerStatusLine(
                        subscription,
                        trialThreeDCap: subscription.plans.trialThreeDCap,
                      ),
                      key: const ValueKey('subscription_status_line'),
                      style: textTheme.bodySmall?.copyWith(
                        color: subscription.status == SubscriptionStatus.grace
                            ? AppColors.warning
                            : AppColors.textSecondary,
                        height: 1.4,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),

          if (_AutopayCard.showsFor(subscription)) ...[
            const SizedBox(height: AppSpacing.lg),
            _AutopayCard(subscription: subscription),
          ],

          // ── Usage ───────────────────────────────────────────────────────
          const SizedBox(height: AppSpacing.lg),
          LayoutBuilder(
            builder: (context, constraints) {
              final tileWidth = (constraints.maxWidth - AppSpacing.sm) / 2;
              return Wrap(
                spacing: AppSpacing.sm,
                runSpacing: AppSpacing.sm,
                children: [
                  _OverviewTile(
                    key: const ValueKey('subscription_usage_3d'),
                    width: tileWidth,
                    icon: Icons.view_in_ar_outlined,
                    label: '3D/AR dishes',
                    // The same line every surface uses: "12 / 15 (Signature
                    // plan)", "12 (unlimited)" for a comp.
                    value: threeDUsageLine(subscription),
                    color: over ? AppColors.error : AppColors.textPrimary,
                  ),
                  _OverviewTile(
                    width: tileWidth,
                    icon: Icons.image_outlined,
                    label: 'Image dishes',
                    value: '${subscription.imageDishCount} · unlimited',
                  ),
                  if (standees != null)
                    _OverviewTile(
                      key: const ValueKey('subscription_standee_line'),
                      width: tileWidth,
                      icon: Icons.qr_code_2,
                      label: 'QR standees',
                      value: standees.replaceFirst('QR standees: ', ''),
                    ),
                  if (subscription.billingInterval != null &&
                      subscription.status != SubscriptionStatus.trial &&
                      subscription.status != SubscriptionStatus.comped)
                    _OverviewTile(
                      width: tileWidth,
                      icon: Icons.event_repeat,
                      label: 'Billing',
                      value: _yearly ? 'Yearly' : 'Monthly',
                    ),
                ],
              );
            },
          ),
          if (over) ...[
            const SizedBox(height: AppSpacing.sm),
            Text(
              'More 3D dishes than your plan covers — publishing will ask you '
              'to upgrade or archive some.',
              style: textTheme.bodySmall?.copyWith(color: AppColors.error),
            ),
          ],

          // ── What's included ─────────────────────────────────────────────
          if (plan != null &&
              subscription.status != SubscriptionStatus.trial &&
              subscription.status != SubscriptionStatus.comped) ...[
            const SizedBox(height: AppSpacing.lg),
            Text("What's included", style: textTheme.titleSmall),
            _Feature('Up to ${plan.threeDDishCap} 3D/AR dishes'),
            const _Feature('Unlimited image dishes'),
            _Feature('${plan.includedStandeeCount} QR-code standees included'),
            for (final feature in plan.features)
              _Feature(_featureLabel(feature)),
          ],

          // ── Offers ──────────────────────────────────────────────────────
          ..._offers(context, plan, nextTier),

          // ── The catalog itself ──────────────────────────────────────────
          const SizedBox(height: AppSpacing.xl),
          AppButton.secondary(
            key: const ValueKey('subscription_see_catalog'),
            label: 'See catalog',
            icon: Icons.storefront_outlined,
            onPressed: () => context.go(AppRoutes.catalog),
          ),
        ],
      ),
    );
  }

  List<Widget> _offers(
    BuildContext context,
    PlanDefinition? plan,
    PlanDefinition? nextTier,
  ) {
    final offers = <Widget>[];
    final status = subscription.status;
    final paid =
        status == SubscriptionStatus.active || status == SubscriptionStatus.grace;

    if (paid && plan != null && !_yearly && plan.yearlyDiscountPct > 0) {
      final twelve = plan.priceMonthlyPaise * 12;
      offers.add(_OfferCard(
        key: const ValueKey('subscription_offer_yearly'),
        icon: Icons.savings_outlined,
        title: 'Save ${plan.yearlyDiscountPct}% with yearly billing',
        body: '${formatRupees(plan.yearlyPricePaise)} a year instead of '
            '${formatRupees(twelve)} — the same plan, paid once a year.',
        actionLabel: 'Switch to yearly',
        onAction: onSwitchToYearly,
      ));
    } else if (paid && plan != null && _yearly && plan.yearlyDiscountPct > 0) {
      offers.add(_OfferCard(
        key: const ValueKey('subscription_offer_yearly'),
        icon: Icons.savings_outlined,
        title: "You're saving ${plan.yearlyDiscountPct}%",
        body: 'Yearly billing costs ${formatRupees(plan.yearlyPricePaise)} '
            'instead of ${formatRupees(plan.priceMonthlyPaise * 12)}.',
      ));
    }

    if (nextTier != null) {
      final extra = nextTier.features
          .where((f) => plan == null || !plan.features.contains(f))
          .map(_featureLabel)
          .toList();
      offers.add(_OfferCard(
        key: const ValueKey('subscription_offer_upgrade'),
        icon: Icons.upgrade,
        title: 'Upgrade to ${nextTier.displayName}',
        body: 'Up to ${nextTier.threeDDishCap} 3D/AR dishes'
            '${extra.isEmpty ? '' : ', plus ${extra.join(', ').toLowerCase()}'}'
            '. From ${formatRupees(nextTier.priceMonthlyPaise)} / month.',
        actionLabel: 'See ${nextTier.displayName}',
        onAction: () => onSeePlan(nextTier.planId),
      ));
    }

    if (status == SubscriptionStatus.trial ||
        status == SubscriptionStatus.comped) {
      final plans = subscription.plans.plans;
      final cheapest = plans.isEmpty
          ? null
          : plans.reduce(
              (a, b) => a.priceMonthlyPaise <= b.priceMonthlyPaise ? a : b);
      if (cheapest != null) {
        offers.add(_OfferCard(
          key: const ValueKey('subscription_offer_pick_plan'),
          icon: Icons.local_offer_outlined,
          title: 'Keep your 3D menu after this ends',
          body: 'Plans from ${formatRupees(cheapest.priceMonthlyPaise)} / '
              'month, ${cheapest.yearlyDiscountPct}% off when you pay '
              'yearly. Autopay renews it for you.',
          actionLabel: 'See plans',
          onAction: () => onSeePlan(cheapest.planId),
        ));
      }
    }

    if (offers.isEmpty) return const [];
    return [
      const SizedBox(height: AppSpacing.lg),
      Text('Offers', style: Theme.of(context).textTheme.titleSmall),
      const SizedBox(height: AppSpacing.sm),
      for (var i = 0; i < offers.length; i++) ...[
        if (i > 0) const SizedBox(height: AppSpacing.sm),
        offers[i],
      ],
    ];
  }
}

/// One usage number in the overview grid.
class _OverviewTile extends StatelessWidget {
  const _OverviewTile({
    super.key,
    required this.width,
    required this.icon,
    required this.label,
    required this.value,
    this.color = AppColors.textPrimary,
  });

  final double width;
  final IconData icon;
  final String label;
  final String value;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    return Container(
      width: width,
      padding: const EdgeInsets.all(AppSpacing.md),
      decoration: BoxDecoration(
        color: AppColors.surface2,
        borderRadius: BorderRadius.circular(AppRadius.sm),
        border: Border.all(color: AppColors.disabled.withValues(alpha: 0.3)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, size: 16, color: AppColors.textMuted),
              const SizedBox(width: AppSpacing.xs),
              Expanded(
                child: Text(
                  label,
                  overflow: TextOverflow.ellipsis,
                  style:
                      textTheme.labelSmall?.copyWith(color: AppColors.textMuted),
                ),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.xs),
          Text(
            value,
            style: textTheme.titleSmall
                ?.copyWith(color: color, fontWeight: FontWeight.w600),
          ),
        ],
      ),
    );
  }
}

/// One offer: what it is, why, and (when it has one) the button that selects
/// it below — never a purchase by itself.
class _OfferCard extends StatelessWidget {
  const _OfferCard({
    super.key,
    required this.icon,
    required this.title,
    required this.body,
    this.actionLabel,
    this.onAction,
  });

  final IconData icon;
  final String title;
  final String body;
  final String? actionLabel;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    return Container(
      padding: const EdgeInsets.all(AppSpacing.md),
      decoration: BoxDecoration(
        color: AppColors.royalGold.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(AppRadius.sm),
        border: Border.all(color: AppColors.royalGold.withValues(alpha: 0.3)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 20, color: AppColors.royalGold),
          const SizedBox(width: AppSpacing.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: textTheme.bodyMedium?.copyWith(
                    color: AppColors.textPrimary,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  body,
                  style: textTheme.bodySmall
                      ?.copyWith(color: AppColors.textSecondary, height: 1.4),
                ),
                if (actionLabel != null && onAction != null)
                  Align(
                    alignment: Alignment.centerLeft,
                    child: TextButton(
                      onPressed: onAction,
                      style: TextButton.styleFrom(
                        padding: EdgeInsets.zero,
                        foregroundColor: AppColors.royalGold,
                      ),
                      child: Text(actionLabel!),
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
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

/// The owner's autopay: on (with the next charge and a way to turn it off),
/// failing, stopped — or, over a running paid plan, OFF with a nudge that
/// the plan will not renew by itself. Hidden when there is nothing to say
/// (no plan and no autopay: the plan cards below are the whole story).
class _AutopayCard extends ConsumerStatefulWidget {
  const _AutopayCard({required this.subscription});

  final CatalogSubscription subscription;

  static bool showsFor(CatalogSubscription subscription) =>
      subscription.autopay != null ||
      subscription.status == SubscriptionStatus.active;

  @override
  ConsumerState<_AutopayCard> createState() => _AutopayCardState();
}

class _AutopayCardState extends ConsumerState<_AutopayCard> {
  bool _turningOff = false;

  Future<void> _confirmTurnOff() async {
    final subscription = widget.subscription;
    final until = subscription.status == SubscriptionStatus.active
        ? subscription.periodEnd
        : null;
    final agreed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        key: const ValueKey('subscription_autopay_off_dialog'),
        title: const Text('Turn off autopay?'),
        content: Text(
          until == null
              ? "You won't be charged again. You can turn autopay back on any "
                  'time.'
              : "You won't be charged again. Your plan stays active until "
                  '${formatSubscriptionDate(until)}; after that your 3D menu '
                  'pauses unless you pay or turn autopay back on.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Keep autopay'),
          ),
          TextButton(
            key: const ValueKey('subscription_autopay_off_confirm'),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Turn off'),
          ),
        ],
      ),
    );
    if (agreed != true || !mounted) return;

    final messenger = CatalogFeedback.of(context);
    setState(() => _turningOff = true);
    try {
      await ref.read(paymentsRepositoryProvider).cancelAutopay();
      Analytics.logEvent('autopay_turned_off', {'surface': 'owner'});
      await ref.read(subscriptionProvider.notifier).refresh();
      CatalogFeedback.confirm(messenger, "Autopay turned off. You won't be charged again.");
    } on CatalogFailure catch (failure) {
      if (failure.code == PaymentErrorCodes.autopayNotOn) {
        // Already off (another device, or Razorpay ended it) — just catch up.
        await ref.read(subscriptionProvider.notifier).refresh();
      } else {
        CatalogFeedback.failure(
          messenger,
          failure,
          subject: "Couldn't turn off autopay",
        );
      }
    } finally {
      if (mounted) setState(() => _turningOff = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    final autopay = widget.subscription.autopay;
    final line = autopayStatusLine(autopay) ??
        "Autopay is off — your plan won't renew by itself. Turn it on below "
            'to keep your 3D menu live without a break.';
    final (IconData icon, Color color) = switch (autopay?.status) {
      null => (Icons.autorenew, AppColors.textSecondary),
      AutopayStatus.pending => (Icons.sync_problem, AppColors.warning),
      AutopayStatus.halted => (Icons.error_outline, AppColors.error),
      _ => (Icons.autorenew, AppColors.success),
    };

    return AppCard(
      key: const ValueKey('subscription_autopay_card'),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 20, color: color),
          const SizedBox(width: AppSpacing.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  line,
                  key: const ValueKey('subscription_autopay_line'),
                  style: textTheme.bodyMedium?.copyWith(
                    color: autopay == null ? AppColors.textSecondary : color,
                    fontWeight:
                        autopay == null ? FontWeight.w400 : FontWeight.w600,
                    height: 1.4,
                  ),
                ),
                // Offered while Razorpay could still charge — on, or failing
                // and retrying. A halted mandate charges nothing more.
                if (autopay != null && autopay.status.willCharge) ...[
                  const SizedBox(height: AppSpacing.xs),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: TextButton(
                      key: const ValueKey('subscription_autopay_off'),
                      onPressed: _turningOff ? null : _confirmTurnOff,
                      child: Text(_turningOff ? 'Turning off…' : 'Turn off autopay'),
                    ),
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
          if (standeeDeliveryLine(subscription) case final standees?) ...[
            const SizedBox(height: AppSpacing.xs),
            _UsageRow(
              key: const ValueKey('subscription_standee_line'),
              label: 'QR standees',
              value: standees.replaceFirst('QR standees: ', ''),
              color: AppColors.textPrimary,
            ),
          ],
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
        const SizedBox(width: AppSpacing.md),
        // "12 / 15 (Signature plan)" can outgrow a narrow phone: it wraps
        // under its own right edge instead of overflowing.
        Flexible(
          child: Text(value,
              textAlign: TextAlign.end,
              style: textTheme.bodyMedium
                  ?.copyWith(color: color, fontWeight: FontWeight.w600)),
        ),
      ],
    );
  }
}

/// One plan, priced for the chosen interval. The yearly figure is the
/// Requirement 1's badge: every price on this screen is a TESTING price.
///
/// Deliberately loud and deliberately unmissable. The failure this exists to
/// prevent is not a technical one — it is a rep showing a real restaurant a ₹3
/// card during a test window and that restaurant reasonably expecting ₹3.
class _TestingPricesBadge extends StatelessWidget {
  const _TestingPricesBadge();

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    return Container(
      key: const ValueKey('subscription_testing_prices_badge'),
      padding: const EdgeInsets.all(AppSpacing.md),
      decoration: BoxDecoration(
        color: AppColors.warning.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(AppRadius.xs),
        border: Border.all(color: AppColors.warning.withValues(alpha: 0.5)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(Icons.science_outlined, size: 16, color: AppColors.warning),
          const SizedBox(width: AppSpacing.sm),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'TEST PRICING — not the real prices',
                  style: textTheme.bodyMedium?.copyWith(
                    color: AppColors.warning,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: AppSpacing.xs),
                Text(
                  'The amounts below are test amounts and a payment made now is '
                  'a real charge at the test amount. Do not quote these to a '
                  'restaurant as its price.',
                  style: textTheme.bodySmall?.copyWith(
                    color: AppColors.textSecondary,
                    height: 1.4,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

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
          // A Wrap, not a Row: "₹20,992 / year  save 30%" is wider than a
          // small phone, and the saving drops under the price instead.
          Wrap(
            spacing: AppSpacing.sm,
            crossAxisAlignment: WrapCrossAlignment.end,
            children: [
              Text(
                price,
                style: textTheme.titleLarge
                    ?.copyWith(color: AppColors.textPrimary),
              ),
              if (yearly)
                Padding(
                  padding: const EdgeInsets.only(bottom: 3),
                  child: Text(
                    'save ${plan.yearlyDiscountPct}%',
                    style: textTheme.labelMedium
                        ?.copyWith(color: AppColors.success),
                  ),
                ),
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

  /// When autopay for this plan would first charge, when that is not now.
  DateTime? get _deferredUntil => autopayDeferredUntil(
        widget.subscription,
        widget.planId,
        widget.interval,
      );

  int get _amountPaise {
    final plan = _plan;
    if (plan == null) return 0;
    return widget.interval == BillingInterval.yearly
        ? plan.yearlyPricePaise
        : plan.priceMonthlyPaise;
  }

  /// The E9 line: the ORDER's `daysForfeited` once the server has quoted
  /// one (it stays in the checkout state through a cancelled SDK sheet), and
  /// the status DTO's figure before that. Both are the server's; neither is
  /// a clock. An older server that sends no `daysForfeited` reads as 0 and
  /// shows nothing — Pay still works.
  String? _forfeitLine() {
    // Autopay over a paid period of this same plan charges nothing today, so
    // nothing is forfeited — the first charge waits for the period to end.
    if (_deferredUntil != null) return null;
    final quoted = ref.read(checkoutProvider).daysForfeited;
    if (quoted != null) {
      return earlyRenewalLine(
        daysForfeited: quoted,
        interval: widget.interval,
      );
    }
    return paymentForfeitWarning(
      widget.subscription,
      interval: widget.interval,
    );
  }

  Future<void> _confirmAndPay() async {
    final plan = _plan;
    if (plan == null) return;
    final label = autopayButtonLabel(
      widget.subscription,
      widget.planId,
      widget.interval,
    );
    final forfeit = _forfeitLine();
    final agreed = await showModalBottomSheet<bool>(
      context: context,
      backgroundColor: AppColors.surface1,
      isScrollControlled: true,
      builder: (ctx) => _PreCheckoutSheet(
        planName: plan.displayName,
        interval: widget.interval,
        amountPaise: _amountPaise,
        deferredUntil: _deferredUntil,
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
                    'In-app payment is available on Android, iOS and in '
                    'the browser. Your plan and history show here on every '
                    'device.',
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
    final label =
        autopayButtonLabel(subscription, widget.planId, widget.interval);
    final forfeit = _forfeitLine();
    final plan = _plan;

    // Autopay already charges exactly this plan and interval: there is
    // nothing for the button to do, and a second mandate would be refused.
    if (autopayCovers(subscription, widget.planId, widget.interval) &&
        checkout.phase != CheckoutPhase.activating) {
      return Column(
        key: const ValueKey('subscription_checkout_slot'),
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _CheckoutProgress(
            checkout: checkout,
            onCheckAgain: () =>
                ref.read(checkoutProvider.notifier).checkAgain(),
          ),
          Text(
            'Autopay is on for this plan — it renews by itself. Pick another '
            'plan above to switch.',
            key: const ValueKey('subscription_autopay_covers'),
            textAlign: TextAlign.center,
            style: textTheme.bodySmall?.copyWith(color: AppColors.textMuted),
          ),
        ],
      );
    }

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
          kAutopayConsentLine,
          key: const ValueKey('subscription_consent_line'),
          textAlign: TextAlign.center,
          style: textTheme.bodySmall?.copyWith(color: AppColors.textMuted),
        ),
        const SizedBox(height: AppSpacing.sm),
        _CheckoutProgress(
          checkout: checkout,
          onCheckAgain: () =>
              ref.read(checkoutProvider.notifier).checkAgain(),
        ),
        if (checkout.phase != CheckoutPhase.activating)
          AppButton(
            key: const ValueKey('subscription_pay_button'),
            // "Turn on autopay" charges nothing today, so it carries no
            // price (the confirm sheet says what and when) — and stays short
            // enough for a narrow phone.
            label: plan == null || _deferredUntil != null
                ? label
                : '$label · ${formatPaise(_amountPaise)}'
                    '${widget.interval == BillingInterval.yearly ? ' / year' : ' / month'}',
            icon: Icons.autorenew,
            isLoading: checkout.isBusy,
            onPressed: plan == null || checkout.isBusy ? null : _confirmAndPay,
          ),
      ],
    );
  }
}

/// What the checkout is doing, in one line under (or instead of) the button.
class _CheckoutProgress extends StatelessWidget {
  const _CheckoutProgress({required this.checkout, required this.onCheckAgain});

  final CheckoutState checkout;

  /// Only offered while the payment is being confirmed: one more read, which
  /// is what makes the server settle a paid order it has not heard about.
  final VoidCallback onCheckAgain;

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    final (String? text, Color color, bool spinner) = switch (checkout.phase) {
      CheckoutPhase.idle ||
      CheckoutPhase.quoting ||
      CheckoutPhase.showingSdk =>
        (null, AppColors.textMuted, false),
      CheckoutPhase.activating => (
          checkout.isDeferredAutopay
              ? 'Autopay approved, switching it on…'
              : 'Payment received, activating…',
          AppColors.textSecondary,
          true
        ),
      CheckoutPhase.done => (
          checkout.isDeferredAutopay
              ? 'Autopay is on.'
              : 'Your plan is active.',
          AppColors.success,
          false
        ),
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
          switch (checkout.failureCode) {
            'UNSUPPORTED' => 'In-app payment is not available on this device.',
            // The web half could not fetch checkout.js — a blocker or a
            // locked-down network. Nothing was even attempted.
            'SDK_UNAVAILABLE' =>
              "Couldn't load the payment window. Check your connection or "
                  'ad blocker and try again.',
            PaymentErrorCodes.autopayAlreadyOn =>
              'Autopay is already on for this plan.',
            _ => 'The payment did not go through. Nothing was charged — '
                'you can try again.',
          },
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
          if (checkout.phase == CheckoutPhase.confirming)
            TextButton(
              key: const ValueKey('subscription_checkout_check_again'),
              onPressed: onCheckAgain,
              child: const Text('Check again'),
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
    required this.deferredUntil,
    required this.forfeitWarning,
    required this.buttonLabel,
  });

  final String planName;
  final BillingInterval interval;
  final int amountPaise;

  /// Autopay's first charge, when it is not today (see autopayDeferredUntil).
  final DateTime? deferredUntil;
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
              '$planName · ${yearly ? 'yearly' : 'monthly'} · autopay',
              style: textTheme.bodyLarge,
            ),
            const SizedBox(height: AppSpacing.xs),
            // AUTOPAY: a real calendar month / year now — Razorpay charges on
            // the same date each cycle, and the period follows its calendar.
            Text(
              autopayChargeLine(
                amountPaise: amountPaise,
                interval: interval,
                deferredUntil: deferredUntil,
              ),
              key: const ValueKey('subscription_precheckout_period'),
              style: textTheme.bodyMedium
                  ?.copyWith(color: AppColors.textSecondary),
            ),
            const SizedBox(height: AppSpacing.sm),
            Text(
              'You approve the autopay once with UPI, card or net banking. '
              'Turn it off any time from this screen.',
              key: const ValueKey('subscription_precheckout_autopay'),
              style: textTheme.bodySmall
                  ?.copyWith(color: AppColors.textMuted, height: 1.4),
            ),
            if (forfeitWarning != null) ...[
              const SizedBox(height: AppSpacing.md),
              Text(
                forfeitWarning!,
                key: const ValueKey('subscription_precheckout_forfeit'),
                style: textTheme.bodySmall?.copyWith(color: AppColors.warning),
              ),
            ],
            const SizedBox(height: AppSpacing.md),
            Text(
              kAutopayConsentLine,
              style: textTheme.bodySmall?.copyWith(color: AppColors.textMuted),
            ),
            const SizedBox(height: AppSpacing.lg),
            AppButton(
              key: const ValueKey('subscription_precheckout_continue'),
              label: 'Continue to $buttonLabel',
              icon: Icons.autorenew,
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
class PaymentHistorySection extends ConsumerStatefulWidget {
  const PaymentHistorySection({super.key});

  @override
  ConsumerState<PaymentHistorySection> createState() =>
      _PaymentHistorySectionState();
}

class _PaymentHistorySectionState extends ConsumerState<PaymentHistorySection> {
  /// The row whose receipt is being fetched, so its icon spins and a second
  /// tap on it does nothing.
  String? _downloading;

  /// Fetches the PDF and hands it to the same seam the QR download uses —
  /// a share sheet on mobile, a blob download in the browser. No new
  /// file-saving path; the receipt is one more file through the one door.
  Future<void> _downloadReceipt(PaymentRecordSummary record) async {
    if (_downloading != null) return;
    final messenger = CatalogFeedback.of(context);
    setState(() => _downloading = record.id);
    try {
      final file =
          await ref.read(paymentsRepositoryProvider).receipt(record.id);
      await ref.read(qrDelivererProvider).deliver(file);
      Analytics.logEvent('receipt_downloaded', {'kind': record.kind.name});
    } on CatalogFailure catch (failure) {
      CatalogFeedback.failure(
        messenger,
        failure,
        subject: "Couldn't download the receipt",
      );
    } finally {
      if (mounted) setState(() => _downloading = null);
    }
  }

  @override
  Widget build(BuildContext context) {
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
                        PaymentHistoryRow(
                          record: rows[i],
                          onDownloadReceipt: rows[i].hasReceipt
                              ? () => _downloadReceipt(rows[i])
                              : null,
                          isDownloading: _downloading == rows[i].id,
                        ),
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
  const PaymentHistoryRow({
    super.key,
    required this.record,
    this.onDownloadReceipt,
    this.isDownloading = false,
  });

  final PaymentRecordSummary record;

  /// Shows the receipt icon when set. The OWNER's section passes it for the
  /// rows that have one; the admin's ledger passes nothing — the receipt is
  /// the owner's document, fetched under the owner's token.
  final VoidCallback? onDownloadReceipt;
  final bool isDownloading;

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
          if (onDownloadReceipt != null) ...[
            const SizedBox(width: AppSpacing.xs),
            isDownloading
                ? const Padding(
                    padding: EdgeInsets.all(AppSpacing.sm),
                    child: SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                  )
                : IconButton(
                    key: ValueKey('payment_receipt_${record.id}'),
                    tooltip: 'Download receipt',
                    visualDensity: VisualDensity.compact,
                    icon: const Icon(Icons.download_outlined, size: 20),
                    color: AppColors.textSecondary,
                    onPressed: onDownloadReceipt,
                  ),
          ],
        ],
      ),
    );
  }
}
