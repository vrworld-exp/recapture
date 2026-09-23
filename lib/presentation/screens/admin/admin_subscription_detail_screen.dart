// lib/presentation/screens/admin/admin_subscription_detail_screen.dart
//
// One restaurant's subscription, for an admin: the status card, the cash
// requests waiting for a decision, the actions, and the ledger.
//
// EVERY ACTION IS A DIALOG WITH A NOTE, and the two that move money or
// entitlement in the owner's favour say the AC-5.2 sentence again — an admin
// verifying cash is the last person who sees the terms before they bind.
// Verify checks the amount against the quote and asks for an explicit
// override when they differ (E12); Refund asks for one when the row is not a
// flagged duplicate (E5's escape hatch). Nothing here is a one-tap.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/theme/app_colors.dart';
import '../../../app/theme/app_spacing.dart';
import '../../../application/admin/admin_subscriptions_notifier.dart';
import '../../../data/repositories/catalog_failure.dart';
import '../../../data/repositories/payments_repository.dart';
import '../../../domain/catalog/subscription_copy.dart';
import '../../../domain/entities/catalog_subscription.dart';
import '../../../domain/entities/subscription_payment.dart';
import '../../widgets/app_button.dart';
import '../../widgets/app_card.dart';
import '../../widgets/app_loading_indicator.dart';
import '../../widgets/catalog/catalog_feedback.dart';
import '../../widgets/catalog/catalog_message.dart';
import '../catalog/subscription_screen.dart' show PaymentHistoryRow;

class AdminSubscriptionDetailScreen extends ConsumerStatefulWidget {
  const AdminSubscriptionDetailScreen({super.key, required this.catalogId});

  final String catalogId;

  @override
  ConsumerState<AdminSubscriptionDetailScreen> createState() =>
      _AdminSubscriptionDetailScreenState();
}

class _AdminSubscriptionDetailScreenState
    extends ConsumerState<AdminSubscriptionDetailScreen> {
  bool _acting = false;

  AdminSubscriptionDetailNotifier get _notifier =>
      ref.read(adminSubscriptionDetailProvider(widget.catalogId).notifier);

  /// Runs one action with the busy flag and the feedback toast. A 409 is a
  /// sentence, not a crash — and the notifier has already re-read.
  Future<void> _run(
    Future<void> Function() action, {
    required String done,
    required String subject,
  }) async {
    final messenger = CatalogFeedback.of(context);
    setState(() => _acting = true);
    try {
      await action();
      CatalogFeedback.confirm(messenger, done);
    } on CatalogFailure catch (failure) {
      CatalogFeedback.failure(messenger, failure, subject: subject);
    } finally {
      if (mounted) setState(() => _acting = false);
    }
  }

  Future<void> _decide(ManualPaymentRecord record) async {
    final result = await showDialog<_DecisionInput>(
      context: context,
      builder: (_) => _DecideDialog(record: record),
    );
    if (result == null || !mounted) return;
    await _run(
      () => _notifier.decide(
        paymentRecordId: record.id,
        decision: result.decision,
        note: result.note,
        override: result.override,
      ),
      done: result.decision == ManualPaymentDecision.verify
          ? 'Verified — the plan is active.'
          : 'Request rejected.',
      subject: 'The request could not be decided',
    );
  }

  Future<void> _comp() async {
    final result = await showDialog<_CompInput>(
      context: context,
      builder: (_) => const _CompDialog(),
    );
    if (result == null || !mounted) return;
    await _run(
      () => _notifier.comp(until: result.until, note: result.note),
      done: 'Complimentary until ${formatSubscriptionDate(result.until)}.',
      subject: 'The comp could not be applied',
    );
  }

  Future<void> _extendGrace() async {
    final result = await showDialog<_GraceInput>(
      context: context,
      builder: (_) => const _ExtendGraceDialog(),
    );
    if (result == null || !mounted) return;
    await _run(
      () => _notifier.extendGrace(days: result.days, note: result.note),
      done:
          'Grace extended by ${result.days} day${result.days == 1 ? '' : 's'}.',
      subject: 'Grace could not be extended',
    );
  }

  /// Re-tells Mirage the current 3D entitlement (E18). No dialog: it is a
  /// re-send of what is already true, and the worst a second press does is
  /// queue a second harmless job.
  Future<void> _resyncAr() => _run(
        () => _notifier.resyncArEntitlement(),
        done: '3D sync queued — the stamp below updates when it lands.',
        subject: 'The 3D sync could not be queued',
      );

  /// Re-tells Mirage the current page state. Same contract as [_resyncAr]: no
  /// dialog, because it can only re-assert what the row already says — the
  /// server computes the desired state from the row, so this cannot take a paid
  /// restaurant's page down however many times it is pressed.
  Future<void> _resyncPage() => _run(
        () => _notifier.resyncPageState(),
        done: 'Page sync queued — the stamp below updates when it lands.',
        subject: 'The page sync could not be queued',
      );

  Future<void> _setStandees(CatalogSubscription subscription) async {
    final result = await showDialog<_StandeesInput>(
      context: context,
      builder: (_) => _StandeesDialog(
        included: subscription.standeeIncluded ?? 0,
        issued: subscription.standeeIssued ?? 0,
      ),
    );
    if (result == null || !mounted) return;
    await _run(
      () => _notifier.setStandeesIssued(
        issued: result.issued,
        note: result.note,
      ),
      done: 'Standees delivered: ${result.issued}.',
      subject: 'The standee count could not be saved',
    );
  }

  Future<void> _refund(PaymentRecordSummary row) async {
    final result = await showDialog<_RefundInput>(
      context: context,
      builder: (_) => _RefundDialog(row: row),
    );
    if (result == null || !mounted) return;
    await _run(
      () => _notifier.refund(
        refundsPaymentId: row.id,
        note: result.note,
        override: result.override,
      ),
      done: 'Refund of ${formatPaise(row.amountPaise)} issued.',
      subject: 'The refund could not be issued',
    );
  }

  @override
  Widget build(BuildContext context) {
    final detail = ref.watch(adminSubscriptionDetailProvider(widget.catalogId));
    return Scaffold(
      backgroundColor: AppColors.bgPrimary,
      appBar: AppBar(
        title: Text(detail.valueOrNull?.catalogName.isNotEmpty ?? false
            ? detail.valueOrNull!.catalogName
            : 'Subscription'),
      ),
      body: SafeArea(
        child: RefreshIndicator(
          onRefresh: () => _notifier.refresh(),
          child: detail.when(
            loading: () => const Center(child: AppLoadingIndicator()),
            error: (error, _) => CatalogMessage(
              icon: Icons.cloud_off_outlined,
              title: error is CatalogFailure && error.isNoCatalog
                  ? 'That catalog was not found.'
                  : "Couldn't load this subscription.",
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

  Widget _body(BuildContext context, AdminSubscriptionDetail detail) {
    final textTheme = Theme.of(context).textTheme;
    final subscription = detail.subscription;
    final pending = detail.payments
        .where((row) =>
            row.kind == PaymentKind.manual &&
            row.verificationStatus == VerificationStatus.pending)
        .toList();
    final queue = ref.watch(adminManualQueueProvider).valueOrNull ?? const [];
    final pendingRecords = {
      for (final record in queue)
        if (record.catalogId == detail.catalogId) record.id: record,
    };

    return ListView(
      key: const ValueKey('admin_subscription_detail'),
      padding: const EdgeInsets.all(AppSpacing.lg),
      children: [
        _StatusCard(detail: detail),
        if (pending.isNotEmpty) ...[
          const SizedBox(height: AppSpacing.md),
          Text('Awaiting verification', style: textTheme.titleSmall),
          const SizedBox(height: AppSpacing.sm),
          for (final row in pending)
            _PendingCard(
              row: row,
              record: pendingRecords[row.id],
              busy: _acting,
              onDecide: () {
                final record = pendingRecords[row.id];
                if (record != null) _decide(record);
              },
            ),
        ],
        const SizedBox(height: AppSpacing.md),
        if (!detail.catalogDeleted)
          Wrap(
            spacing: AppSpacing.sm,
            runSpacing: AppSpacing.sm,
            children: [
              AppButton.secondary(
                key: const ValueKey('admin_comp'),
                label: 'Comp until…',
                icon: Icons.card_giftcard_outlined,
                isFullWidth: false,
                onPressed: _acting ? null : _comp,
              ),
              if (subscription?.status == SubscriptionStatus.grace)
                AppButton.secondary(
                  key: const ValueKey('admin_extend_grace'),
                  label: 'Extend grace',
                  icon: Icons.more_time,
                  isFullWidth: false,
                  onPressed: _acting ? null : _extendGrace,
                ),
              // Stage 5: the button the ENTITLEMENT_FAILED alert points at.
              // Only with a row — without one there is no desired state.
              if (subscription != null && subscription.hasRow)
                AppButton.secondary(
                  key: const ValueKey('admin_resync_ar'),
                  label: 'Resync 3D',
                  icon: Icons.sync,
                  isFullWidth: false,
                  onPressed: _acting ? null : _resyncAr,
                ),
              // The button the "a paid restaurant's page is still switched off"
              // alert points at — the most damaging state this product has, and
              // the only one an operator has to fix by hand.
              if (subscription != null && subscription.hasRow)
                AppButton.secondary(
                  key: const ValueKey('admin_resync_page'),
                  label: 'Resync page',
                  icon: Icons.link,
                  isFullWidth: false,
                  onPressed: _acting ? null : _resyncPage,
                ),
              // Only a plan that includes standees has a count to keep.
              if (subscription != null &&
                  (subscription.standeeIncluded ?? 0) > 0)
                AppButton.secondary(
                  key: const ValueKey('admin_set_standees'),
                  label: 'Standees delivered…',
                  icon: Icons.qr_code_2_outlined,
                  isFullWidth: false,
                  onPressed: _acting ? null : () => _setStandees(subscription),
                ),
            ],
          ),
        const SizedBox(height: AppSpacing.xxl),
        Text('Ledger', style: textTheme.titleMedium),
        const SizedBox(height: AppSpacing.sm),
        if (detail.payments.isEmpty)
          Text(
            'No payments yet.',
            style: textTheme.bodySmall?.copyWith(color: AppColors.textMuted),
          )
        else
          AppCard(
            padding: const EdgeInsets.symmetric(
              horizontal: AppSpacing.lg,
              vertical: AppSpacing.sm,
            ),
            child: Column(
              children: [
                for (var i = 0; i < detail.payments.length; i++) ...[
                  if (i > 0)
                    Divider(
                      height: AppSpacing.md,
                      color: AppColors.disabled.withValues(alpha: 0.3),
                    ),
                  _LedgerRow(
                    row: detail.payments[i],
                    busy: _acting,
                    onRefund: () => _refund(detail.payments[i]),
                  ),
                ],
              ],
            ),
          ),
        const SizedBox(height: AppSpacing.huge),
      ],
    );
  }
}

class _StatusCard extends StatelessWidget {
  const _StatusCard({required this.detail});

  final AdminSubscriptionDetail detail;

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    final subscription = detail.subscription;
    if (subscription == null) {
      return AppCard(
        key: const ValueKey('admin_subscription_status'),
        child: Text(
          detail.catalogDeleted
              ? 'This catalog has been deleted. Its ledger is kept below.'
              : 'No subscription.',
          style: textTheme.bodyMedium?.copyWith(color: AppColors.textSecondary),
        ),
      );
    }
    final tone = subscriptionTone(subscription.status);
    final color = switch (tone) {
      SubscriptionTone.good => AppColors.success,
      SubscriptionTone.warning => AppColors.warning,
      SubscriptionTone.danger => AppColors.error,
      SubscriptionTone.neutral => AppColors.textSecondary,
    };
    return AppCard(
      key: const ValueKey('admin_subscription_status'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            ownerStatusLine(
              subscription,
              trialThreeDCap: subscription.plans.trialThreeDCap,
            ),
            style: textTheme.bodyLarge
                ?.copyWith(color: color, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: AppSpacing.xs),
          Text(
            subscription.hasRow
                ? '3D/AR dishes ${threeDUsageLine(subscription)}'
                : '${subscription.threeDDishCount} 3D/AR dishes on the menu',
            style:
                textTheme.bodySmall?.copyWith(color: AppColors.textSecondary),
          ),
          if (standeeDeliveryLine(subscription) case final standees?) ...[
            const SizedBox(height: AppSpacing.xs),
            Text(
              standees,
              key: const ValueKey('admin_standee_line'),
              style: textTheme.bodySmall
                  ?.copyWith(color: AppColors.textSecondary),
            ),
          ],
          if (subscription.graceEndsAt != null) ...[
            const SizedBox(height: AppSpacing.xs),
            Text(
              'Grace ends ${formatSubscriptionDate(subscription.graceEndsAt!)}',
              style: textTheme.bodySmall?.copyWith(color: AppColors.textMuted),
            ),
          ],
          // Stage 5 (E18): when Mirage last heard about this row's 3D
          // entitlement, next to the status it should match. A PAUSED row
          // with an old stamp — or none — is the thing this line exists to
          // make visible; "Resync 3D" below is the fix.
          const SizedBox(height: AppSpacing.xs),
          Text(
            arEntitlementSyncLine(
              subscription.status,
              detail.arEntitlementSyncedAt,
            ),
            key: const ValueKey('admin_ar_sync_line'),
            style: textTheme.bodySmall?.copyWith(
              color: arEntitlementSyncStale(
                subscription.status,
                detail.arEntitlementSyncedAt,
              )
                  ? AppColors.warning
                  : AppColors.textMuted,
            ),
          ),
        ],
      ),
    );
  }
}

/// "3D on Mirage: synced 18 Oct 2026 14:02" / "never synced (Mirage default:
/// 3D on)". The stamp is the server's; nothing here computes a state.
String arEntitlementSyncLine(SubscriptionStatus status, DateTime? syncedAt) {
  if (syncedAt == null) {
    return status == SubscriptionStatus.paused ||
            status == SubscriptionStatus.cancelled
        ? '3D on Mirage: never synced — Mirage still shows 3D'
        : '3D on Mirage: never synced (Mirage default: 3D on)';
  }
  final local = syncedAt.toLocal();
  final hh = local.hour.toString().padLeft(2, '0');
  final mm = local.minute.toString().padLeft(2, '0');
  return '3D on Mirage: synced ${formatSubscriptionDate(syncedAt)} $hh:$mm';
}

/// A row that is NOT entitled and has never been synced is the one case
/// where the customer page may disagree with the plan — draw it in warning.
bool arEntitlementSyncStale(SubscriptionStatus status, DateTime? syncedAt) =>
    syncedAt == null &&
    (status == SubscriptionStatus.paused ||
        status == SubscriptionStatus.cancelled);

class _PendingCard extends StatelessWidget {
  const _PendingCard({
    required this.row,
    required this.record,
    required this.busy,
    required this.onDecide,
  });

  final PaymentRecordSummary row;

  /// The queue's fuller record (quote, reference); null until the queue loads.
  final ManualPaymentRecord? record;
  final bool busy;
  final VoidCallback onDecide;

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    final mismatch = record != null && !record!.amountMatchesQuote;
    return AppCard(
      key: ValueKey('admin_pending_${row.id}'),
      margin: const EdgeInsets.only(bottom: AppSpacing.sm),
      border: const BorderSide(color: AppColors.warning, width: 1),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '${formatPaise(row.amountPaise)} · ${row.methodLabel}'
            '${record == null ? '' : ' · ${record!.reference}'}',
            style: textTheme.bodyLarge,
          ),
          const SizedBox(height: AppSpacing.xs),
          Text(
            'Receipt ${row.receiptNo}'
            '${record == null ? '' : ' · ${record!.planId.apiValue} ${record!.interval.apiValue.toLowerCase()}'}'
            '${record?.note == null ? '' : '\n${record!.note}'}',
            style:
                textTheme.bodySmall?.copyWith(color: AppColors.textSecondary),
          ),
          if (mismatch) ...[
            const SizedBox(height: AppSpacing.xs),
            Text(
              'Plan price is ${formatPaise(record!.quotedPaise)} — the amount '
              'differs. Verifying needs an override and a reason.',
              style: textTheme.bodySmall?.copyWith(color: AppColors.warning),
            ),
          ],
          const SizedBox(height: AppSpacing.sm),
          AppButton.secondary(
            key: ValueKey('admin_decide_${row.id}'),
            label: 'Verify or reject',
            icon: Icons.fact_check_outlined,
            isFullWidth: false,
            onPressed: busy || record == null ? null : onDecide,
          ),
        ],
      ),
    );
  }
}

class _LedgerRow extends StatelessWidget {
  const _LedgerRow({
    required this.row,
    required this.busy,
    required this.onRefund,
  });

  final PaymentRecordSummary row;
  final bool busy;
  final VoidCallback onRefund;

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        PaymentHistoryRow(record: row),
        if (row.note != null || row.isRefundable)
          Padding(
            padding: const EdgeInsets.only(bottom: AppSpacing.xs),
            child: Row(
              children: [
                if (row.note != null)
                  Expanded(
                    child: Text(
                      row.note!,
                      key: ValueKey('admin_ledger_note_${row.id}'),
                      style: textTheme.labelSmall?.copyWith(
                        color: row.isSuspectedDuplicate
                            ? AppColors.warning
                            : AppColors.textMuted,
                      ),
                    ),
                  )
                else
                  const Spacer(),
                if (row.isRefundable)
                  TextButton(
                    key: ValueKey('admin_refund_${row.id}'),
                    onPressed: busy ? null : onRefund,
                    child: Text(
                      row.isSuspectedDuplicate ? 'Refund duplicate' : 'Refund…',
                    ),
                  ),
              ],
            ),
          ),
      ],
    );
  }
}

// ── Dialogs ─────────────────────────────────────────────────────────────────

class _DecisionInput {
  const _DecisionInput(this.decision, this.note, this.override);
  final ManualPaymentDecision decision;
  final String? note;
  final bool override;
}

/// Verify / Reject. The AC-5.2 notice is on it; Reject needs a note; a
/// mismatched amount needs the override and a 20-character reason (E12).
class _DecideDialog extends StatefulWidget {
  const _DecideDialog({required this.record});

  final ManualPaymentRecord record;

  @override
  State<_DecideDialog> createState() => _DecideDialogState();
}

class _DecideDialogState extends State<_DecideDialog> {
  final _note = TextEditingController();
  bool _override = false;

  @override
  void dispose() {
    _note.dispose();
    super.dispose();
  }

  bool get _mismatch => !widget.record.amountMatchesQuote;

  bool get _canVerify =>
      !_mismatch || (_override && _note.text.trim().length >= 20);

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    final record = widget.record;
    return AlertDialog(
      backgroundColor: AppColors.surface1,
      title: const Text('Verify this payment?'),
      content: SingleChildScrollView(
        child: Column(
          key: const ValueKey('admin_decide_dialog'),
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '${formatPaise(record.amountPaise)} by '
              '${record.method?.label ?? 'manual'} · ${record.reference}',
              style: textTheme.bodyMedium,
            ),
            Text(
              '${record.planId.apiValue} · ${record.interval.apiValue.toLowerCase()}'
              ' · plan price ${formatPaise(record.quotedPaise)}',
              style:
                  textTheme.bodySmall?.copyWith(color: AppColors.textSecondary),
            ),
            if (_mismatch) ...[
              const SizedBox(height: AppSpacing.sm),
              Text(
                'The amount does not match the plan price.',
                style: textTheme.bodySmall?.copyWith(color: AppColors.warning),
              ),
              CheckboxListTile(
                key: const ValueKey('admin_decide_override'),
                contentPadding: EdgeInsets.zero,
                controlAffinity: ListTileControlAffinity.leading,
                value: _override,
                onChanged: (v) => setState(() => _override = v ?? false),
                title: Text('Verify anyway', style: textTheme.bodyMedium),
                subtitle: Text(
                  'Explain why below (at least 20 characters).',
                  style: textTheme.bodySmall,
                ),
              ),
            ],
            const SizedBox(height: AppSpacing.sm),
            TextField(
              key: const ValueKey('admin_decide_note'),
              controller: _note,
              maxLines: 2,
              maxLength: 1000,
              decoration: const InputDecoration(
                labelText: 'Note',
                helperText: 'Required to reject.',
                counterText: '',
              ),
              onChanged: (_) => setState(() {}),
            ),
            const SizedBox(height: AppSpacing.md),
            Text(
              kPaymentConsentLine,
              key: const ValueKey('admin_decide_consent'),
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
        TextButton(
          key: const ValueKey('admin_decide_reject'),
          onPressed: _note.text.trim().isEmpty
              ? null
              : () => Navigator.of(context).pop(_DecisionInput(
                    ManualPaymentDecision.reject,
                    _note.text.trim(),
                    false,
                  )),
          child: const Text('Reject'),
        ),
        FilledButton(
          key: const ValueKey('admin_decide_verify'),
          onPressed: _canVerify
              ? () => Navigator.of(context).pop(_DecisionInput(
                    ManualPaymentDecision.verify,
                    _note.text.trim().isEmpty ? null : _note.text.trim(),
                    _override,
                  ))
              : null,
          child: const Text('Verify'),
        ),
      ],
    );
  }
}

class _CompInput {
  const _CompInput(this.until, this.note);
  final DateTime until;
  final String note;
}

class _CompDialog extends StatefulWidget {
  const _CompDialog();

  @override
  State<_CompDialog> createState() => _CompDialogState();
}

class _CompDialogState extends State<_CompDialog> {
  final _note = TextEditingController();
  DateTime _until = DateTime.now().add(const Duration(days: 30));

  @override
  void dispose() {
    _note.dispose();
    super.dispose();
  }

  Future<void> _pick() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _until,
      firstDate: DateTime.now().add(const Duration(days: 1)),
      lastDate: DateTime.now().add(const Duration(days: 365 * 3)),
    );
    if (picked != null) setState(() => _until = picked);
  }

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    return AlertDialog(
      backgroundColor: AppColors.surface1,
      title: const Text('Comp this restaurant'),
      content: Column(
        key: const ValueKey('admin_comp_dialog'),
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Complimentary and uncapped until the date below. Ends any '
            'running period.',
            style:
                textTheme.bodySmall?.copyWith(color: AppColors.textSecondary),
          ),
          const SizedBox(height: AppSpacing.sm),
          OutlinedButton.icon(
            key: const ValueKey('admin_comp_until'),
            onPressed: _pick,
            icon: const Icon(Icons.event),
            label: Text('Until ${formatSubscriptionDate(_until)}'),
          ),
          const SizedBox(height: AppSpacing.sm),
          TextField(
            key: const ValueKey('admin_comp_note'),
            controller: _note,
            maxLength: 1000,
            decoration: const InputDecoration(
              labelText: 'Reason',
              counterText: '',
            ),
            onChanged: (_) => setState(() {}),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          key: const ValueKey('admin_comp_confirm'),
          onPressed: _note.text.trim().isEmpty
              ? null
              : () => Navigator.of(context).pop(_CompInput(
                    DateTime(_until.year, _until.month, _until.day, 23, 59),
                    _note.text.trim(),
                  )),
          child: const Text('Comp'),
        ),
      ],
    );
  }
}

class _GraceInput {
  const _GraceInput(this.days, this.note);
  final int days;
  final String note;
}

class _ExtendGraceDialog extends StatefulWidget {
  const _ExtendGraceDialog();

  @override
  State<_ExtendGraceDialog> createState() => _ExtendGraceDialogState();
}

class _ExtendGraceDialogState extends State<_ExtendGraceDialog> {
  final _note = TextEditingController();
  int _days = 7;

  @override
  void dispose() {
    _note.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    return AlertDialog(
      backgroundColor: AppColors.surface1,
      title: const Text('Extend grace'),
      content: Column(
        key: const ValueKey('admin_grace_dialog'),
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('$_days day${_days == 1 ? '' : 's'}',
              style: textTheme.bodyLarge),
          Slider(
            key: const ValueKey('admin_grace_days'),
            value: _days.toDouble(),
            min: 1,
            max: 30,
            divisions: 29,
            label: '$_days',
            onChanged: (v) => setState(() => _days = v.round()),
          ),
          TextField(
            key: const ValueKey('admin_grace_note'),
            controller: _note,
            maxLength: 1000,
            decoration: const InputDecoration(
              labelText: 'Reason',
              counterText: '',
            ),
            onChanged: (_) => setState(() {}),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          key: const ValueKey('admin_grace_confirm'),
          onPressed: _note.text.trim().isEmpty
              ? null
              : () => Navigator.of(context)
                  .pop(_GraceInput(_days, _note.text.trim())),
          child: const Text('Extend'),
        ),
      ],
    );
  }
}

class _StandeesInput {
  const _StandeesInput(this.issued, this.note);
  final int issued;
  final String? note;
}

/// "How many have gone out" — a number the admin types, bounded by what the
/// plan includes. An absolute count, not "+1": the truth is what is on the
/// restaurant's tables, and that is what gets typed in.
class _StandeesDialog extends StatefulWidget {
  const _StandeesDialog({required this.included, required this.issued});

  final int included;
  final int issued;

  @override
  State<_StandeesDialog> createState() => _StandeesDialogState();
}

class _StandeesDialogState extends State<_StandeesDialog> {
  late final TextEditingController _count =
      TextEditingController(text: '${widget.issued}');
  final _note = TextEditingController();

  @override
  void dispose() {
    _count.dispose();
    _note.dispose();
    super.dispose();
  }

  int? get _parsed {
    final value = int.tryParse(_count.text.trim());
    if (value == null || value < 0 || value > widget.included) return null;
    return value;
  }

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    final parsed = _parsed;
    return AlertDialog(
      backgroundColor: AppColors.surface1,
      title: const Text('Standees delivered'),
      content: Column(
        key: const ValueKey('admin_standees_dialog'),
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'The plan includes ${widget.included}. Enter how many have been '
            'handed over in total.',
            style:
                textTheme.bodySmall?.copyWith(color: AppColors.textSecondary),
          ),
          const SizedBox(height: AppSpacing.sm),
          TextField(
            key: const ValueKey('admin_standees_count'),
            controller: _count,
            keyboardType: TextInputType.number,
            autofocus: true,
            decoration: InputDecoration(
              labelText: 'Delivered so far',
              suffixText: 'of ${widget.included}',
              errorText: _count.text.trim().isNotEmpty && parsed == null
                  ? 'Between 0 and ${widget.included}'
                  : null,
            ),
            onChanged: (_) => setState(() {}),
          ),
          TextField(
            key: const ValueKey('admin_standees_note'),
            controller: _note,
            maxLength: 1000,
            decoration: const InputDecoration(
              labelText: 'Note (optional)',
              counterText: '',
            ),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          key: const ValueKey('admin_standees_confirm'),
          onPressed: parsed == null
              ? null
              : () => Navigator.of(context).pop(_StandeesInput(
                    parsed,
                    _note.text.trim().isEmpty ? null : _note.text.trim(),
                  )),
          child: const Text('Save'),
        ),
      ],
    );
  }
}

class _RefundInput {
  const _RefundInput(this.note, this.override);
  final String note;
  final bool override;
}

/// Refund ONE online payment in full. Shows the original; needs a note of at
/// least 10 characters, and — unless the row is a flagged duplicate — the
/// override with 30 (the E5 orphan-payment case).
class _RefundDialog extends StatefulWidget {
  const _RefundDialog({required this.row});

  final PaymentRecordSummary row;

  @override
  State<_RefundDialog> createState() => _RefundDialogState();
}

class _RefundDialogState extends State<_RefundDialog> {
  final _note = TextEditingController();
  bool _override = false;

  @override
  void dispose() {
    _note.dispose();
    super.dispose();
  }

  bool get _needsOverride => !widget.row.isSuspectedDuplicate;

  bool get _canSubmit {
    final length = _note.text.trim().length;
    if (_needsOverride) return _override && length >= 30;
    return length >= 10;
  }

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    final row = widget.row;
    return AlertDialog(
      backgroundColor: AppColors.surface1,
      title: const Text('Refund this payment?'),
      content: SingleChildScrollView(
        child: Column(
          key: const ValueKey('admin_refund_dialog'),
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '${formatPaise(row.amountPaise)} · ${row.methodLabel} · '
              '${row.receiptNo}',
              style: textTheme.bodyMedium,
            ),
            Text(
              row.createdAt == null
                  ? ''
                  : 'Paid ${formatSubscriptionDate(row.createdAt!)}. '
                      'Refunded in full; the subscription period is not changed.',
              style:
                  textTheme.bodySmall?.copyWith(color: AppColors.textSecondary),
            ),
            if (_needsOverride) ...[
              const SizedBox(height: AppSpacing.sm),
              Text(
                'This payment is not flagged as a duplicate.',
                style: textTheme.bodySmall?.copyWith(color: AppColors.warning),
              ),
              CheckboxListTile(
                key: const ValueKey('admin_refund_override'),
                contentPadding: EdgeInsets.zero,
                controlAffinity: ListTileControlAffinity.leading,
                value: _override,
                onChanged: (v) => setState(() => _override = v ?? false),
                title: Text('Refund anyway', style: textTheme.bodyMedium),
                subtitle: Text(
                  'Explain why below (at least 30 characters).',
                  style: textTheme.bodySmall,
                ),
              ),
            ],
            const SizedBox(height: AppSpacing.sm),
            TextField(
              key: const ValueKey('admin_refund_note'),
              controller: _note,
              maxLines: 2,
              maxLength: 1000,
              decoration: InputDecoration(
                labelText: 'Reason',
                helperText: _needsOverride
                    ? 'At least 30 characters.'
                    : 'At least 10 characters.',
                counterText: '',
              ),
              onChanged: (_) => setState(() {}),
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
          key: const ValueKey('admin_refund_confirm'),
          onPressed: _canSubmit
              ? () => Navigator.of(context)
                  .pop(_RefundInput(_note.text.trim(), _override))
              : null,
          child: const Text('Refund'),
        ),
      ],
    );
  }
}
