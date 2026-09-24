// lib/presentation/screens/admin/admin_payment_attempt_screen.dart
//
// ONE online payment, for an admin debugging it: who started it and for which
// restaurant, the five steps it went through (started → Razorpay received it →
// recorded on our ledger → plan applied → catalog updated), each with its time
// and the server's sentence, and the two fixes:
//
//   • "Check with Razorpay" — NO dialog. It asks Razorpay about this order and
//     runs what the webhook would have; it cannot activate anything Razorpay
//     does not confirm, and pressing it twice changes nothing. What Razorpay
//     answered is shown on the page, so the admin sees the provider's truth
//     beside ours.
//   • "Apply to catalog…" — A DIALOG WITH A REASON (20+ characters) and the
//     AC-5.2 notice: it moves entitlement in the owner's favour against what
//     the machine concluded, so it is never a one-tap. Offered only where the
//     server says it is allowed (flagged, or not on the catalog).
//
// Everything on this page is the server's: the stage, each step's state and
// sentence, and whether each fix is allowed. Nothing is decided here.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/routes/app_router.dart';
import '../../../app/theme/app_colors.dart';
import '../../../app/theme/app_spacing.dart';
import '../../../application/admin/admin_subscriptions_notifier.dart';
import '../../../data/repositories/catalog_failure.dart';
import '../../../data/repositories/payments_repository.dart';
import '../../../domain/catalog/subscription_copy.dart';
import '../../../domain/entities/admin_payment_attempt.dart';
import '../../../domain/entities/catalog_subscription.dart';
import '../../../domain/entities/subscription_payment.dart';
import '../../widgets/app_button.dart';
import '../../widgets/app_card.dart';
import '../../widgets/app_loading_indicator.dart';
import '../../widgets/catalog/catalog_feedback.dart';
import '../../widgets/catalog/catalog_message.dart';
import '../projects/project_owner_sheet.dart';
import 'admin_payment_widgets.dart';

class AdminPaymentAttemptScreen extends ConsumerStatefulWidget {
  const AdminPaymentAttemptScreen({super.key, required this.orderId});

  final String orderId;

  @override
  ConsumerState<AdminPaymentAttemptScreen> createState() =>
      _AdminPaymentAttemptScreenState();
}

class _AdminPaymentAttemptScreenState
    extends ConsumerState<AdminPaymentAttemptScreen> {
  bool _acting = false;

  AdminPaymentAttemptNotifier get _notifier =>
      ref.read(adminPaymentAttemptProvider(widget.orderId).notifier);

  Future<void> _sync() async {
    final messenger = CatalogFeedback.of(context);
    setState(() => _acting = true);
    try {
      final result = await _notifier.sync();
      CatalogFeedback.confirm(messenger, result.outcome.sentence);
    } on CatalogFailure catch (failure) {
      CatalogFeedback.failure(
        messenger,
        failure,
        subject: 'Razorpay could not be checked',
      );
    } finally {
      if (mounted) setState(() => _acting = false);
    }
  }

  Future<void> _forceApply(PaymentAttempt attempt) async {
    final note = await showDialog<String>(
      context: context,
      builder: (_) => _ForceApplyDialog(attempt: attempt),
    );
    if (note == null || !mounted) return;
    final messenger = CatalogFeedback.of(context);
    setState(() => _acting = true);
    try {
      await _notifier.forceApply(note);
      CatalogFeedback.confirm(
        messenger,
        'Applied — the plan is active on the catalog.',
      );
    } on CatalogFailure catch (failure) {
      CatalogFeedback.failure(
        messenger,
        failure,
        subject: 'The payment could not be applied',
      );
    } finally {
      if (mounted) setState(() => _acting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final attempt = ref.watch(adminPaymentAttemptProvider(widget.orderId));
    return Scaffold(
      backgroundColor: AppColors.bgPrimary,
      appBar: AppBar(
        title: Text(
          attempt.valueOrNull?.catalogName.isNotEmpty ?? false
              ? attempt.valueOrNull!.catalogName
              : 'Payment',
        ),
      ),
      body: SafeArea(
        child: RefreshIndicator(
          onRefresh: () => _notifier.refresh(),
          child: attempt.when(
            loading: () => const Center(child: AppLoadingIndicator()),
            error: (error, _) => CatalogMessage(
              icon: Icons.cloud_off_outlined,
              title: error is CatalogFailure &&
                      error.code == PaymentErrorCodes.paymentNotFound
                  ? 'That payment was not found.'
                  : "Couldn't load this payment.",
              body: 'Check your connection and try again.',
              actionLabel: 'Try again',
              onAction: () => _notifier.refresh(),
            ),
            data: (data) => _body(context, data),
          ),
        ),
      ),
    );
  }

  Widget _body(BuildContext context, PaymentAttempt attempt) {
    final textTheme = Theme.of(context).textTheme;
    final provider = _notifier.lastProvider;
    return ListView(
      key: const ValueKey('admin_attempt_detail'),
      padding: const EdgeInsets.all(AppSpacing.lg),
      children: [
        _SummaryCard(attempt: attempt),
        const SizedBox(height: AppSpacing.md),
        _WhoCard(attempt: attempt),
        const SizedBox(height: AppSpacing.md),
        if (attempt.canSync || attempt.canForceApply || !attempt.catalogDeleted)
          Wrap(
            spacing: AppSpacing.sm,
            runSpacing: AppSpacing.sm,
            children: [
              if (attempt.canSync)
                AppButton(
                  key: const ValueKey('admin_attempt_sync'),
                  label: 'Check with Razorpay',
                  icon: Icons.sync,
                  isFullWidth: false,
                  onPressed: _acting ? null : _sync,
                ),
              if (attempt.canForceApply)
                AppButton(
                  key: const ValueKey('admin_attempt_apply'),
                  label: 'Apply to catalog…',
                  icon: Icons.playlist_add_check,
                  isFullWidth: false,
                  onPressed: _acting ? null : () => _forceApply(attempt),
                ),
              if (!attempt.catalogDeleted && attempt.catalogId.isNotEmpty)
                AppButton.secondary(
                  key: const ValueKey('admin_attempt_open_catalog'),
                  label: 'Restaurant panel',
                  icon: Icons.storefront_outlined,
                  isFullWidth: false,
                  onPressed: () => context.push(
                      '${AppRoutes.adminSubscriptions}/${attempt.catalogId}'),
                ),
            ],
          ),
        if (attempt.refunded || attempt.stage == PaymentAttemptStage.flagged)
          Padding(
            padding: const EdgeInsets.only(top: AppSpacing.sm),
            child: Text(
              attempt.refunded
                  ? 'Refunds are listed in the restaurant panel\'s ledger.'
                  : 'To refund instead, open the restaurant panel and use '
                      'Refund on this payment in the ledger.',
              style: textTheme.bodySmall?.copyWith(color: AppColors.textMuted),
            ),
          ),
        if (provider != null) ...[
          const SizedBox(height: AppSpacing.md),
          _ProviderCard(snapshot: provider),
        ],
        const SizedBox(height: AppSpacing.xxl),
        Text('What happened', style: textTheme.titleMedium),
        const SizedBox(height: AppSpacing.sm),
        AppCard(
          key: const ValueKey('admin_attempt_steps'),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              for (var i = 0; i < attempt.steps.length; i++)
                _StepRow(
                  step: attempt.steps[i],
                  last: i == attempt.steps.length - 1,
                ),
            ],
          ),
        ),
        const SizedBox(height: AppSpacing.huge),
      ],
    );
  }
}

class _SummaryCard extends StatelessWidget {
  const _SummaryCard({required this.attempt});

  final PaymentAttempt attempt;

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    final plan = planLine(attempt.planName, attempt.planId, attempt.interval);
    final mismatch = attempt.paidPaise != null &&
        attempt.quotedPaise != null &&
        attempt.paidPaise != attempt.quotedPaise;
    return AppCard(
      key: const ValueKey('admin_attempt_summary'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  formatPaise(attempt.displayPaise),
                  style: textTheme.headlineSmall,
                ),
              ),
              Flexible(
                child: AdminStatusChip(
                  label: attempt.stage.label,
                  color: stageColor(attempt.stage),
                ),
              ),
            ],
          ),
          if (plan.isNotEmpty)
            Text(
              plan,
              style:
                  textTheme.bodyMedium?.copyWith(color: AppColors.textSecondary),
            ),
          if (mismatch)
            Text(
              'Order was for ${formatPaise(attempt.quotedPaise!)}',
              style: textTheme.bodySmall?.copyWith(color: AppColors.warning),
            ),
          const SizedBox(height: AppSpacing.sm),
          Text(
            attempt.stage.explanation,
            key: const ValueKey('admin_attempt_explanation'),
            style: textTheme.bodyMedium?.copyWith(
              color: attempt.needsAttention
                  ? AppColors.error
                  : AppColors.textSecondary,
            ),
          ),
          if (attempt.subscriptionStatus != null) ...[
            const SizedBox(height: AppSpacing.xs),
            Text(
              'Catalog now: ${attempt.subscriptionStatus!.apiValue}'
              '${attempt.subscriptionPeriodEnd == null ? '' : ' until ${formatSubscriptionDate(attempt.subscriptionPeriodEnd!)}'}',
              style: textTheme.bodySmall?.copyWith(color: AppColors.textMuted),
            ),
          ],
        ],
      ),
    );
  }
}

/// Restaurant, owner, who pressed Pay, and the two provider ids (copyable —
/// they are what the Razorpay dashboard searches by).
class _WhoCard extends StatelessWidget {
  const _WhoCard({required this.attempt});

  final PaymentAttempt attempt;

  @override
  Widget build(BuildContext context) {
    final owner = attempt.owner;
    return AppCard(
      key: const ValueKey('admin_attempt_who'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _InfoRow(
            label: 'Restaurant',
            value: attempt.catalogName.isEmpty
                ? 'Restaurant'
                : attempt.catalogName +
                    (attempt.catalogDeleted ? ' (deleted)' : ''),
          ),
          _InfoRow(
            label: 'Owner',
            value: owner?.displayLabel ?? 'Account not found',
            trailing: owner == null
                ? null
                : TextButton(
                    key: const ValueKey('admin_attempt_contact'),
                    onPressed: () =>
                        showProjectOwnerSheet(context, owner: owner),
                    child: const Text('Contact'),
                  ),
          ),
          if (attempt.initiatedBy != null)
            _InfoRow(label: 'Started by', value: attempt.initiatedBy!.label),
          if (attempt.startedAt != null)
            _InfoRow(
              label: 'Started',
              value: formatAdminDateTime(attempt.startedAt!),
            ),
          _InfoRow(label: 'Order', value: attempt.orderId, copyable: true),
          if (attempt.providerPaymentId != null)
            _InfoRow(
              label: 'Payment',
              value: attempt.providerPaymentId!,
              copyable: true,
            ),
        ],
      ),
    );
  }
}

class _InfoRow extends StatelessWidget {
  const _InfoRow({
    required this.label,
    required this.value,
    this.copyable = false,
    this.trailing,
  });

  final String label;
  final String value;
  final bool copyable;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: AppSpacing.xs),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          SizedBox(
            width: 92,
            child: Text(
              label,
              style: textTheme.bodySmall?.copyWith(color: AppColors.textMuted),
            ),
          ),
          Expanded(
            child: copyable
                ? SelectableText(value, style: textTheme.bodyMedium)
                : Text(value, style: textTheme.bodyMedium),
          ),
          if (copyable)
            IconButton(
              tooltip: 'Copy',
              visualDensity: VisualDensity.compact,
              icon: const Icon(Icons.copy, size: 18),
              onPressed: () {
                Clipboard.setData(ClipboardData(text: value));
                CatalogFeedback.confirm(
                    CatalogFeedback.of(context), '$label id copied.');
              },
            ),
          if (trailing != null) trailing!,
        ],
      ),
    );
  }
}

class _StepRow extends StatelessWidget {
  const _StepRow({required this.step, required this.last});

  final JournalStep step;
  final bool last;

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    final color = stepColor(step.state);
    return IntrinsicHeight(
      child: Row(
        key: ValueKey('admin_step_${step.key.name}'),
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Column(
            children: [
              Icon(stepIcon(step.state), color: color, size: 22),
              if (!last)
                Expanded(
                  child: Container(
                    width: 2,
                    margin: const EdgeInsets.symmetric(vertical: 2),
                    color: AppColors.disabled.withValues(alpha: 0.4),
                  ),
                ),
            ],
          ),
          const SizedBox(width: AppSpacing.md),
          Expanded(
            child: Padding(
              padding: EdgeInsets.only(bottom: last ? 0 : AppSpacing.md),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    step.title,
                    style: textTheme.bodyLarge?.copyWith(
                      color: step.state == JournalStepState.skipped
                          ? AppColors.textMuted
                          : null,
                    ),
                  ),
                  if (step.at != null)
                    Text(
                      formatAdminDateTime(step.at!),
                      style: textTheme.labelSmall
                          ?.copyWith(color: AppColors.textMuted),
                    ),
                  if (step.detail.isNotEmpty)
                    Text(
                      step.detail,
                      style: textTheme.bodySmall?.copyWith(
                        color: step.state == JournalStepState.failed
                            ? AppColors.error
                            : AppColors.textSecondary,
                      ),
                    ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// What Razorpay answered at the last "Check" — the provider's truth beside ours.
class _ProviderCard extends StatelessWidget {
  const _ProviderCard({required this.snapshot});

  final ProviderSnapshot snapshot;

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    return AppCard(
      key: const ValueKey('admin_attempt_provider'),
      border: const BorderSide(color: AppColors.disabled, width: 1),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Razorpay says', style: textTheme.titleSmall),
          const SizedBox(height: AppSpacing.xs),
          Text(
            'Order ${snapshot.orderStatus} · ${formatPaise(snapshot.orderAmountPaise)}'
            '${snapshot.checkedAt == null ? '' : ' · checked ${formatAdminDateTime(snapshot.checkedAt!)}'}',
            style: textTheme.bodySmall?.copyWith(color: AppColors.textSecondary),
          ),
          if (snapshot.payments.isEmpty)
            Text(
              'No payment attempts on this order.',
              style: textTheme.bodySmall?.copyWith(color: AppColors.textMuted),
            )
          else
            for (final p in snapshot.payments)
              Text(
                '${p.id} · ${p.status} · ${formatPaise(p.amountPaise)}',
                style: textTheme.bodySmall?.copyWith(
                  color: p.status == 'captured'
                      ? AppColors.success
                      : AppColors.textSecondary,
                ),
              ),
        ],
      ),
    );
  }
}

/// "Apply to catalog" — what will happen, why it was held back, and a reason.
class _ForceApplyDialog extends StatefulWidget {
  const _ForceApplyDialog({required this.attempt});

  final PaymentAttempt attempt;

  @override
  State<_ForceApplyDialog> createState() => _ForceApplyDialogState();
}

class _ForceApplyDialogState extends State<_ForceApplyDialog> {
  static const _minChars = 20;
  final _note = TextEditingController();

  @override
  void dispose() {
    _note.dispose();
    super.dispose();
  }

  bool get _canSubmit => _note.text.trim().length >= _minChars;

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    final attempt = widget.attempt;
    final days = attempt.interval == BillingInterval.yearly ? 365 : 30;
    final plan = planLine(attempt.planName, attempt.planId, attempt.interval);
    return AlertDialog(
      backgroundColor: AppColors.surface1,
      title: const Text('Apply this payment to the catalog?'),
      content: SingleChildScrollView(
        child: Column(
          key: const ValueKey('admin_apply_dialog'),
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '${plan.isEmpty ? 'The plan' : plan} starts today and runs $days '
              'days. Unused days on the current period are not carried over.',
              style: textTheme.bodyMedium,
            ),
            if (attempt.outcomeNote != null) ...[
              const SizedBox(height: AppSpacing.sm),
              Text(
                'Held back as ${attempt.outcomeNote}. Applying overrides that '
                'check — make sure the money is really there.',
                style: textTheme.bodySmall?.copyWith(color: AppColors.warning),
              ),
            ],
            const SizedBox(height: AppSpacing.sm),
            TextField(
              key: const ValueKey('admin_apply_note'),
              controller: _note,
              maxLines: 2,
              maxLength: 1000,
              decoration: const InputDecoration(
                labelText: 'Reason',
                helperText: 'At least 20 characters. Kept on the ledger.',
                counterText: '',
              ),
              onChanged: (_) => setState(() {}),
            ),
            const SizedBox(height: AppSpacing.md),
            Text(
              kPaymentConsentLine,
              style: textTheme.bodySmall?.copyWith(color: AppColors.textMuted),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          key: const ValueKey('admin_apply_confirm'),
          onPressed: _canSubmit
              ? () => Navigator.of(context).pop(_note.text.trim())
              : null,
          child: const Text('Apply'),
        ),
      ],
    );
  }
}
