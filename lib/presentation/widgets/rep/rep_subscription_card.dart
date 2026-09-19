// lib/presentation/widgets/rep/rep_subscription_card.dart
//
// The Subscription card on a delegated restaurant's detail screen, and the
// three actions a rep has on it: Start free trial (Door 1), Notify owner to
// pay (Door 2's nudge — an SMS and a bell notification asking the owner to
// open THEIR app and pay; never a payment itself, AC-7.3) and Record cash
// payment (Door 3 — a REQUEST an admin verifies; the card says "Awaiting admin
// verification" while it is pending). There is no Pay, no refund and no
// "mark paid" here, and there must never be (AC-5.1, AC-6.5).
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
import '../../../application/rep/rep_manual_payment_notifier.dart';
import '../../../application/rep/rep_subscription_notifier.dart';
import '../../../data/repositories/catalog_failure.dart';
import '../../../domain/catalog/subscription_copy.dart';
import '../../../domain/entities/catalog_subscription.dart';
import '../../../domain/entities/subscription_nudge.dart';
import '../../../utils/analytics.dart';
import '../app_button.dart';
import '../catalog/catalog_feedback.dart';
import 'rep_cash_payment_sheet.dart';

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
  bool _nudging = false;

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

  Future<void> _notifyOwner() async {
    Analytics.logEvent('rep_nudge_tapped', {'catalog_id': widget.catalogId});
    final messenger = CatalogFeedback.of(context);
    setState(() => _nudging = true);
    try {
      final result = await ref
          .read(repSubscriptionProvider(widget.catalogId).notifier)
          .notifyOwner();
      CatalogFeedback.confirm(messenger, nudgeResultSentence(result));
    } on CatalogFailure catch (failure) {
      CatalogFeedback.failure(
        messenger,
        failure,
        subject: 'The owner could not be notified',
      );
    } finally {
      if (mounted) setState(() => _nudging = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final subscription = ref.watch(repSubscriptionProvider(widget.catalogId));
    final pendingCash =
        ref.watch(repManualPaymentProvider(widget.catalogId)).valueOrNull;
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
        data: (data) => _body(
          context,
          data,
          isOnline: isOnline,
          pendingCash: pendingCash != null && pendingCash.isPending,
        ),
      ),
    );
  }

  Widget _body(
    BuildContext context,
    CatalogSubscription subscription, {
    required bool isOnline,
    required bool pendingCash,
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
        // Stage 5: a worried owner's first question is "is my menu down?".
        // It is not, and the rep should be able to read the answer off the
        // card without looking anything up.
        if (subscription.status == SubscriptionStatus.paused) ...[
          const SizedBox(height: AppSpacing.xs),
          Text(
            kPausedPhotoMenuLine,
            key: const ValueKey('rep_paused_photo_menu_line'),
            style:
                textTheme.bodySmall?.copyWith(color: AppColors.textSecondary),
          ),
        ],
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
        if (standeeDeliveryLine(subscription) case final standees?) ...[
          const SizedBox(height: AppSpacing.xs),
          Text(
            standees,
            key: const ValueKey('rep_standee_line'),
            style:
                textTheme.bodySmall?.copyWith(color: AppColors.textSecondary),
          ),
        ],
        const SizedBox(height: AppSpacing.sm),
        if (subscription.trialAvailable) ...[
          AppButton.secondary(
            key: const ValueKey('rep_start_trial'),
            label: isOnline ? 'Start free trial' : 'Needs a connection',
            icon: Icons.timer_outlined,
            isFullWidth: false,
            isLoading: _starting,
            // Offline: disabled with a reason, never queued (E40).
            onPressed: isOnline ? () => _startTrial(subscription) : null,
          ),
          const SizedBox(height: AppSpacing.sm),
        ],
        // Door 2's nudge. HIDDEN, not disabled, for a paid-up owner (the
        // server would answer 409 anyway); DISABLED with the wait while the
        // restaurant's window is spent — the cooldown comes from the server
        // (per restaurant, shared by every rep) and is adopted in place after
        // a tap, so it shows without a refresh.
        if (nudgeOffered(subscription)) ...[
          Builder(builder: (context) {
            final cooldown = nudgeCooldownLabel(subscription, DateTime.now());
            return AppButton.secondary(
              key: const ValueKey('rep_notify_owner'),
              label: cooldown ??
                  (isOnline ? 'Notify owner to pay' : 'Needs a connection'),
              icon: Icons.notifications_active_outlined,
              isFullWidth: false,
              isLoading: _nudging,
              onPressed:
                  cooldown == null && isOnline && !_nudging ? _notifyOwner : null,
            );
          }),
          const SizedBox(height: AppSpacing.sm),
        ],
        if (pendingCash)
          Row(
            key: const ValueKey('rep_cash_pending_line'),
            children: [
              const Icon(Icons.hourglass_top,
                  size: 16, color: AppColors.warning),
              const SizedBox(width: AppSpacing.sm),
              Expanded(
                child: Text(
                  'Cash payment recorded — awaiting admin verification.',
                  style:
                      textTheme.bodySmall?.copyWith(color: AppColors.warning),
                ),
              ),
              TextButton(
                onPressed: () => _openCashSheet(subscription),
                child: const Text('View'),
              ),
            ],
          )
        else
          AppButton.secondary(
            key: const ValueKey('rep_record_cash'),
            label: 'Record cash payment',
            icon: Icons.receipt_long_outlined,
            isFullWidth: false,
            onPressed: () => _openCashSheet(subscription),
          ),
        const SizedBox(height: AppSpacing.xs),
        Text(
          'The owner pays online in their app. Cash needs an admin to verify.',
          key: const ValueKey('rep_payment_hint'),
          style: textTheme.bodySmall?.copyWith(color: AppColors.textMuted),
        ),
      ],
    );
  }

  Future<void> _openCashSheet(CatalogSubscription subscription) async {
    await showRepCashPaymentSheet(
      context,
      catalogId: widget.catalogId,
      restaurantName: widget.restaurantName,
      plans: subscription.plans,
      currentPlan: subscription.planId,
    );
    if (!mounted) return;
    // The sheet may have filed a request; the line under the button reads
    // the same provider it wrote, so nothing more is needed here.
  }
}

// ── The nudge's copy and rules, pure so the tests can pin them ──────────────

/// Whether the card offers "Notify owner to pay" at all. Mirrors the server's
/// NOT_NEEDED rule: ACTIVE with more than a week left, or a comp, has
/// nothing to pay — offering the button would only earn a 409.
bool nudgeOffered(CatalogSubscription subscription) {
  switch (subscription.status) {
    case SubscriptionStatus.comped:
      return false;
    case SubscriptionStatus.active:
      final days = subscription.daysLeft;
      return days != null && days <= 7;
    case SubscriptionStatus.none:
    case SubscriptionStatus.trial:
    case SubscriptionStatus.grace:
    case SubscriptionStatus.paused:
    case SubscriptionStatus.cancelled:
    case SubscriptionStatus.unknown:
      return true;
  }
}

/// The disabled button's label while the restaurant's window is spent —
/// "Sent · again in 23h" — or null when a nudge is allowed at [now].
String? nudgeCooldownLabel(CatalogSubscription subscription, DateTime now) {
  if (!subscription.nudgeOnCooldownAt(now)) return null;
  return 'Sent · again in ${nudgeWaitText(subscription.nudgeNextAllowedAt!, now)}';
}

/// "23h" for anything an hour or more away, "45m" under that, never "0h".
/// Rounded UP on both scales: a button that says "again in 1m" for 61
/// seconds is honest; one that says "0m" for 59 seconds is a bug report.
String nudgeWaitText(DateTime nextAllowedAt, DateTime now) {
  final remaining = nextAllowedAt.difference(now);
  final minutes = (remaining.inSeconds / 60).ceil();
  if (minutes >= 60) return '${(minutes / 60).ceil()}h';
  return '${minutes < 1 ? 1 : minutes}m';
}

/// The toast for each answer — OUR sentence for the server's code, never its
/// prose (F10), and the same wording the stage doc fixes for a legacy owner.
String nudgeResultSentence(NudgeResult result, {DateTime? now}) {
  switch (result) {
    case NudgeSent(:final bySms, :final inApp):
      if (bySms && inApp) return 'Sent to the owner by SMS and in-app.';
      if (inApp) return 'Sent to the owner in-app — the SMS could not be sent.';
      return 'Sent to the owner by SMS.';
    case NudgeCooldown(:final nextAllowedAt):
      return 'Already sent — the owner can be reminded again in '
          '${nudgeWaitText(nextAllowedAt, now ?? DateTime.now())}.';
    case NudgeRefused(reason: NudgeRefusal.ownerUnreachable):
      return 'This owner has no phone number on file — ask an admin.';
    case NudgeRefused(reason: NudgeRefusal.notNeeded):
      return 'This restaurant is paid up — no reminder needed.';
  }
}
