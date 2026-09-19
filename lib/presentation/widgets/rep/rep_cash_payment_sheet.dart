// lib/presentation/widgets/rep/rep_cash_payment_sheet.dart
//
// "Record cash payment" — Door 3, the rep's half. A bottom sheet that files a
// cash / transfer / cheque / UPI request for an admin to verify. It is a
// REQUEST: nothing here activates a plan, and the sheet says so.
//
// When a request is already awaiting an admin the sheet shows it read-only
// (§7 rule 3) — a second form would file a second row for the same money.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/theme/app_colors.dart';
import '../../../app/theme/app_spacing.dart';
import '../../../application/connectivity/connectivity_providers.dart';
import '../../../application/rep/rep_manual_payment_notifier.dart';
import '../../../data/repositories/catalog_failure.dart';
import '../../../domain/catalog/subscription_copy.dart';
import '../../../domain/entities/catalog_subscription.dart';
import '../../../domain/entities/subscription_payment.dart';
import '../app_button.dart';
import '../catalog/catalog_feedback.dart';

/// Opens the sheet. Resolves when it closes; the card re-reads its own state.
Future<void> showRepCashPaymentSheet(
  BuildContext context, {
  required String catalogId,
  required String restaurantName,
  required PlanCatalog plans,
  PlanId? currentPlan,
}) =>
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: AppColors.surface1,
      isScrollControlled: true,
      builder: (_) => RepCashPaymentSheet(
        catalogId: catalogId,
        restaurantName: restaurantName,
        plans: plans,
        currentPlan: currentPlan,
      ),
    );

class RepCashPaymentSheet extends ConsumerStatefulWidget {
  const RepCashPaymentSheet({
    super.key,
    required this.catalogId,
    required this.restaurantName,
    required this.plans,
    this.currentPlan,
  });

  final String catalogId;
  final String restaurantName;
  final PlanCatalog plans;
  final PlanId? currentPlan;

  @override
  ConsumerState<RepCashPaymentSheet> createState() =>
      _RepCashPaymentSheetState();
}

class _RepCashPaymentSheetState extends ConsumerState<RepCashPaymentSheet> {
  final _form = GlobalKey<FormState>();
  final _amount = TextEditingController();
  final _reference = TextEditingController();
  final _note = TextEditingController();
  late PlanId _plan;
  BillingInterval _interval = BillingInterval.monthly;
  ManualMethod _method = ManualMethod.cash;
  bool _submitting = false;
  bool _amountTouched = false;

  @override
  void initState() {
    super.initState();
    final current = widget.currentPlan;
    _plan = current != null && widget.plans.byId(current) != null
        ? current
        : (widget.plans.plans.firstOrNull?.planId ?? PlanId.taste);
    _prefillAmount();
  }

  @override
  void dispose() {
    _amount.dispose();
    _reference.dispose();
    _note.dispose();
    super.dispose();
  }

  int get _quotedPaise {
    final plan = widget.plans.byId(_plan);
    if (plan == null) return 0;
    return _interval == BillingInterval.yearly
        ? plan.yearlyPricePaise
        : plan.priceMonthlyPaise;
  }

  /// The plan's price goes into the amount field until the rep edits it —
  /// most cash is the exact price, and a pre-filled field is one less place
  /// to mistype ₹1,199 as ₹1,000 (E12).
  void _prefillAmount() {
    if (_amountTouched) return;
    final paise = _quotedPaise;
    _amount.text =
        paise % 100 == 0 ? '${paise ~/ 100}' : (paise / 100).toStringAsFixed(2);
  }

  String? _validateAmount(String? raw) {
    final paise = parseRupeesToPaise(raw ?? '');
    if (paise == null) {
      return 'Enter an amount in rupees, two decimals at most.';
    }
    return null;
  }

  Future<void> _submit() async {
    if (!(_form.currentState?.validate() ?? false)) return;
    final paise = parseRupeesToPaise(_amount.text);
    if (paise == null) return;
    final messenger = CatalogFeedback.of(context);
    setState(() => _submitting = true);
    try {
      final submission = await ref
          .read(repManualPaymentProvider(widget.catalogId).notifier)
          .submit(ManualPaymentRequest(
            planId: _plan,
            interval: _interval,
            amountPaise: paise,
            method: _method,
            reference: _reference.text.trim(),
            note: _note.text,
          ));
      if (!mounted) return;
      CatalogFeedback.confirm(
        messenger,
        submission.existing
            ? 'A request is already awaiting admin verification.'
            : 'Recorded — awaiting admin verification.',
      );
      Navigator.of(context).pop();
    } on CatalogFailure catch (failure) {
      CatalogFeedback.failure(
        messenger,
        failure,
        subject: 'The payment could not be recorded',
      );
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final pending = ref.watch(repManualPaymentProvider(widget.catalogId));
    final isOnline = ref.watch(isOnlineProvider);
    final textTheme = Theme.of(context).textTheme;
    final existing = pending.valueOrNull;

    return SafeArea(
      child: Padding(
        padding: EdgeInsets.only(
          left: AppSpacing.lg,
          right: AppSpacing.lg,
          top: AppSpacing.lg,
          bottom: MediaQuery.viewInsetsOf(context).bottom + AppSpacing.xxl,
        ),
        child: existing != null && existing.isPending
            ? _PendingSummary(record: existing)
            : SingleChildScrollView(
                child: Form(
                  key: _form,
                  child: Column(
                    key: const ValueKey('rep_cash_form'),
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Text('Record cash payment', style: textTheme.titleMedium),
                      const SizedBox(height: AppSpacing.xs),
                      Text(
                        'For ${widget.restaurantName}. An admin verifies it '
                        'before the plan activates.',
                        style: textTheme.bodySmall
                            ?.copyWith(color: AppColors.textMuted),
                      ),
                      const SizedBox(height: AppSpacing.lg),
                      DropdownButtonFormField<PlanId>(
                        key: const ValueKey('rep_cash_plan'),
                        initialValue: _plan,
                        decoration: const InputDecoration(labelText: 'Plan'),
                        items: [
                          for (final plan in widget.plans.plans)
                            DropdownMenuItem(
                              value: plan.planId,
                              child: Text(plan.displayName),
                            ),
                        ],
                        onChanged: (value) {
                          if (value == null) return;
                          setState(() {
                            _plan = value;
                            _prefillAmount();
                          });
                        },
                      ),
                      const SizedBox(height: AppSpacing.md),
                      SegmentedButton<BillingInterval>(
                        key: const ValueKey('rep_cash_interval'),
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
                        onSelectionChanged: (selection) => setState(() {
                          _interval = selection.first;
                          _prefillAmount();
                        }),
                      ),
                      const SizedBox(height: AppSpacing.md),
                      TextFormField(
                        key: const ValueKey('rep_cash_amount'),
                        controller: _amount,
                        keyboardType: const TextInputType.numberWithOptions(
                            decimal: true),
                        inputFormatters: [
                          FilteringTextInputFormatter.allow(RegExp(r'[\d.,]')),
                        ],
                        decoration: InputDecoration(
                          labelText: 'Amount collected (₹)',
                          helperText: 'Plan price ${formatPaise(_quotedPaise)}',
                        ),
                        validator: _validateAmount,
                        autovalidateMode: AutovalidateMode.onUserInteraction,
                        onChanged: (_) => _amountTouched = true,
                      ),
                      const SizedBox(height: AppSpacing.md),
                      DropdownButtonFormField<ManualMethod>(
                        key: const ValueKey('rep_cash_method'),
                        initialValue: _method,
                        decoration: const InputDecoration(labelText: 'Method'),
                        items: [
                          for (final method in ManualMethod.values)
                            DropdownMenuItem(
                              value: method,
                              child: Text(method.label),
                            ),
                        ],
                        onChanged: (value) {
                          if (value != null) setState(() => _method = value);
                        },
                      ),
                      const SizedBox(height: AppSpacing.md),
                      TextFormField(
                        key: const ValueKey('rep_cash_reference'),
                        controller: _reference,
                        maxLength: 200,
                        decoration: const InputDecoration(
                          labelText: 'Reference',
                          helperText:
                              'Receipt number, UPI txn id or cheque number',
                          counterText: '',
                        ),
                        validator: (raw) => (raw ?? '').trim().isEmpty
                            ? 'A reference is required.'
                            : null,
                      ),
                      const SizedBox(height: AppSpacing.md),
                      TextFormField(
                        key: const ValueKey('rep_cash_note'),
                        controller: _note,
                        maxLength: 1000,
                        maxLines: 2,
                        decoration: const InputDecoration(
                          labelText: 'Note (optional)',
                          counterText: '',
                        ),
                      ),
                      const SizedBox(height: AppSpacing.lg),
                      AppButton(
                        key: const ValueKey('rep_cash_submit'),
                        label: isOnline
                            ? 'Send for verification'
                            : 'Needs a connection',
                        icon: Icons.receipt_long_outlined,
                        isLoading: _submitting,
                        // Offline: disabled with a reason, never queued (E40).
                        onPressed: isOnline ? _submit : null,
                      ),
                      const SizedBox(height: AppSpacing.sm),
                      Text(
                        kPaymentConsentLine,
                        textAlign: TextAlign.center,
                        style: textTheme.bodySmall
                            ?.copyWith(color: AppColors.textMuted),
                      ),
                    ],
                  ),
                ),
              ),
      ),
    );
  }
}

/// The request already on file, read-only.
class _PendingSummary extends StatelessWidget {
  const _PendingSummary({required this.record});

  final ManualPaymentRecord record;

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    return Column(
      key: const ValueKey('rep_cash_pending'),
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Awaiting admin verification', style: textTheme.titleMedium),
        const SizedBox(height: AppSpacing.sm),
        Text(
          '${formatPaise(record.amountPaise)} · ${record.method?.label ?? 'Manual'}'
          ' · ${record.reference}',
          style: textTheme.bodyMedium,
        ),
        const SizedBox(height: AppSpacing.xs),
        Text(
          'Receipt ${record.receiptNo}. The plan activates once an admin '
          'verifies this payment.',
          style: textTheme.bodySmall?.copyWith(color: AppColors.textMuted),
        ),
        const SizedBox(height: AppSpacing.lg),
        AppButton.secondary(
          label: 'Close',
          onPressed: () => Navigator.of(context).pop(),
        ),
      ],
    );
  }
}
