// lib/presentation/widgets/rep/rep_subscription_card.dart
//
// The Subscription card on a delegated restaurant's detail screen, and the
// one action a rep has on it: Start free trial (Door 1).
//
// WHAT THE CARD SAYS is the owner's status line, word for word — a rep on the
// phone with an owner must be reading the same sentence. WHAT THE BUTTON DOES
// is the only rep-side subscription write there is, and it is:
//   • confirmed first ("one trial per restaurant" is worth a second look),
//   • refused offline with a reason (E40 — never queued for replay), and
//   • answered with OUR sentence for the server's code, never the server's
//     prose (the F10 rule every catalog surface follows).
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/theme/app_colors.dart';
import '../../../app/theme/app_spacing.dart';
import '../../../application/connectivity/connectivity_providers.dart';
import '../../../application/rep/rep_subscription_notifier.dart';
import '../../../data/repositories/catalog_failure.dart';
import '../../../domain/catalog/subscription_copy.dart';
import '../../../domain/entities/catalog_subscription.dart';
import '../../../utils/analytics.dart';
import '../app_button.dart';
import '../catalog/catalog_feedback.dart';

class RepSubscriptionCard extends ConsumerStatefulWidget {
  const RepSubscriptionCard({
    super.key,
    required this.catalogId,
    required this.restaurantName,
  });

  final String catalogId;

  /// For the confirmation: "Start a 30-day free trial for `name`?".
  final String restaurantName;

  @override
  ConsumerState<RepSubscriptionCard> createState() =>
      _RepSubscriptionCardState();
}

class _RepSubscriptionCardState extends ConsumerState<RepSubscriptionCard> {
  bool _starting = false;

  @override
  void initState() {
    super.initState();
    Analytics.logEvent('subscription_screen_viewed', {'surface': 'rep'});
  }

  Future<void> _startTrial(CatalogSubscription subscription) async {
    Analytics.logEvent(
      'subscription_trial_tapped',
      {'catalog_id': widget.catalogId},
    );
    final plans = subscription.plans;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.surface1,
        title: const Text('Start a free trial?'),
        content: Text(
          'Start a ${plans.trialDays}-day free trial for '
          '${widget.restaurantName}? Up to ${plans.trialThreeDCap} 3D dishes. '
          'One trial per restaurant.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Not now'),
          ),
          TextButton(
            key: const ValueKey('rep_trial_confirm'),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Start trial'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    final messenger = CatalogFeedback.of(context);
    setState(() => _starting = true);
    try {
      await ref
          .read(repSubscriptionProvider(widget.catalogId).notifier)
          .startTrial();
      CatalogFeedback.confirm(
        messenger,
        'Free trial started — ${plans.trialDays} days, up to '
        '${plans.trialThreeDCap} 3D dishes.',
      );
    } on CatalogFailure catch (failure) {
      CatalogFeedback.failure(
        messenger,
        failure,
        subject: 'The trial could not be started',
      );
    } finally {
      if (mounted) setState(() => _starting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final subscription = ref.watch(repSubscriptionProvider(widget.catalogId));
    final isOnline = ref.watch(isOnlineProvider);
    final textTheme = Theme.of(context).textTheme;

    return Container(
      key: const ValueKey('rep_subscription_card'),
      padding: const EdgeInsets.all(AppSpacing.md),
      decoration: BoxDecoration(
        color: AppColors.surface1,
        borderRadius: BorderRadius.circular(AppRadius.xs),
        border: Border.all(color: AppColors.disabled.withValues(alpha: 0.4)),
      ),
      child: subscription.when(
        loading: () => Text(
          'Checking the subscription…',
          style: textTheme.bodySmall?.copyWith(color: AppColors.textMuted),
        ),
        error: (_, __) => Row(
          children: [
            Expanded(
              child: Text(
                "Couldn't load the subscription.",
                style:
                    textTheme.bodySmall?.copyWith(color: AppColors.textMuted),
              ),
            ),
            TextButton(
              onPressed: () => ref
                  .read(repSubscriptionProvider(widget.catalogId).notifier)
                  .refresh(),
              child: const Text('Retry'),
            ),
          ],
        ),
        data: (data) => _body(context, data, isOnline: isOnline),
      ),
    );
  }

  Widget _body(
    BuildContext context,
    CatalogSubscription subscription, {
    required bool isOnline,
  }) {
    final textTheme = Theme.of(context).textTheme;
    final tone = subscriptionTone(subscription.status);
    final color = switch (tone) {
      SubscriptionTone.good => AppColors.success,
      SubscriptionTone.warning => AppColors.warning,
      SubscriptionTone.danger => AppColors.error,
      SubscriptionTone.neutral => AppColors.textSecondary,
    };

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Subscription', style: textTheme.titleSmall),
        const SizedBox(height: AppSpacing.xs),
        Text(
          ownerStatusLine(
            subscription,
            trialThreeDCap: subscription.plans.trialThreeDCap,
          ),
          key: const ValueKey('rep_subscription_status_line'),
          style: textTheme.bodyMedium
              ?.copyWith(color: color, fontWeight: FontWeight.w600),
        ),
        const SizedBox(height: AppSpacing.xs),
        Text(
          subscription.hasRow
              ? '3D/AR dishes ${threeDUsageLine(subscription)} · '
                  'image dishes unlimited'
              : '${subscription.threeDDishCount} 3D/AR dishes on the menu · '
                  'image dishes unlimited',
          style: textTheme.bodySmall?.copyWith(
            color: subscription.isOverCap
                ? AppColors.error
                : AppColors.textSecondary,
          ),
        ),
        const SizedBox(height: AppSpacing.sm),
        if (subscription.trialAvailable)
          AppButton.secondary(
            key: const ValueKey('rep_start_trial'),
            label: isOnline ? 'Start free trial' : 'Needs a connection',
            icon: Icons.timer_outlined,
            isFullWidth: false,
            isLoading: _starting,
            // Offline: disabled with a reason, never queued (E40).
            onPressed: isOnline ? () => _startTrial(subscription) : null,
          )
        else
          Text(
            'Owner pays in the app (coming soon)',
            key: const ValueKey('rep_trial_unavailable'),
            style: textTheme.bodySmall?.copyWith(color: AppColors.textMuted),
          ),
      ],
    );
  }
}
