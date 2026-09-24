// lib/presentation/screens/admin/admin_subscriptions_screen.dart
//
// Everything an admin needs about subscription money, in three tabs:
//
//   • PAYMENTS — the payment journal: every online payment attempt with its
//     pipeline (started → Razorpay → recorded → applied → catalog). "Needs
//     attention" is the default: money Razorpay took that did not become a
//     plan. A row opens the attempt, where "Check with Razorpay" and "Apply
//     to catalog" live.
//   • PLANS — every subscription (All) plus the collections segments, with a
//     name search. A row opens the restaurant's panel.
//   • CASH — the cash requests reps submitted, waiting for a Verify.
//
// Filters are a WRAP of chips (admin_payment_widgets.dart explains why): the
// old single-row SegmentedButton was cut off on a phone.
//
// ADMIN-ONLY, on both sides: the router gate on this subtree mirrors the
// backend's `requireRole('ADMIN')` on every one of these routes (E39).
import 'dart:async';

import 'package:flutter/material.dart';
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
import '../../widgets/app_card.dart';
import '../../widgets/app_loading_indicator.dart';
import '../../widgets/catalog/catalog_feedback.dart';
import '../../widgets/catalog/catalog_message.dart';
import 'admin_payment_widgets.dart';

/// The Plans tab's segments — every collections state, the queue excluded
/// (it is its own tab).
const _planFilters = [
  AdminSubscriptionFilter.all,
  AdminSubscriptionFilter.expiring7d,
  AdminSubscriptionFilter.grace,
  AdminSubscriptionFilter.paused,
  AdminSubscriptionFilter.paused90d,
  AdminSubscriptionFilter.trial,
];

class AdminSubscriptionsScreen extends ConsumerStatefulWidget {
  const AdminSubscriptionsScreen({super.key, this.initialFilter});

  /// Opens on the Plans tab at this segment, or on Cash for `pending`. Null
  /// opens on Payments → Needs attention.
  final AdminSubscriptionFilter? initialFilter;

  @override
  ConsumerState<AdminSubscriptionsScreen> createState() =>
      _AdminSubscriptionsScreenState();
}

class _AdminSubscriptionsScreenState
    extends ConsumerState<AdminSubscriptionsScreen>
    with SingleTickerProviderStateMixin {
  late final TabController _tabs = TabController(
    length: 3,
    vsync: this,
    initialIndex: switch (widget.initialFilter) {
      null => 0,
      AdminSubscriptionFilter.pending => 2,
      _ => 1,
    },
  );

  AdminPaymentFilter _paymentFilter = AdminPaymentFilter.attention;
  late AdminSubscriptionFilter _planFilter =
      _planFilters.contains(widget.initialFilter)
          ? widget.initialFilter!
          : AdminSubscriptionFilter.all;

  final _search = TextEditingController();
  final _lookupField = TextEditingController();
  bool _lookingUp = false;
  Timer? _debounce;
  String _query = '';

  @override
  void dispose() {
    _debounce?.cancel();
    _search.dispose();
    _lookupField.dispose();
    _tabs.dispose();
    super.dispose();
  }

  void _onSearch(String text) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 350), () {
      if (mounted) setState(() => _query = text.trim());
    });
  }

  void _openCatalog(String catalogId) =>
      context.push('${AppRoutes.adminSubscriptions}/$catalogId');

  void _openAttempt(String orderId) => context.push(
      '${AppRoutes.adminPayments}/${Uri.encodeComponent(orderId)}');

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.bgPrimary,
      appBar: AppBar(
        title: const Text('Subscriptions'),
        bottom: TabBar(
          controller: _tabs,
          tabs: const [
            Tab(key: ValueKey('admin_tab_payments'), child: _AttentionTabLabel()),
            Tab(key: ValueKey('admin_tab_plans'), text: 'Plans'),
            Tab(key: ValueKey('admin_tab_cash'), text: 'Cash'),
          ],
        ),
      ),
      body: SafeArea(
        child: TabBarView(
          controller: _tabs,
          children: [
            _paymentsTab(),
            _plansTab(),
            _PendingQueue(onOpen: _openCatalog),
          ],
        ),
      ),
    );
  }

  /// "Find a payment" (edge case #8): any `order_…` / `pay_…` id, from the
  /// Razorpay dashboard or an owner's screenshot, to where it lives.
  Future<void> _lookup() async {
    final id = _lookupField.text.trim();
    if (id.isEmpty) return;
    final messenger = CatalogFeedback.of(context);
    setState(() => _lookingUp = true);
    try {
      final result = await ref.read(paymentsRepositoryProvider).lookupPayment(id);
      if (!mounted) return;
      switch (result) {
        case PaymentLookupOnLedger(:final orderId):
          _openAttempt(orderId);
        case PaymentLookupCashEntry(:final catalogId):
          CatalogFeedback.confirm(
              messenger, 'Recorded as a manual entry — opening the restaurant.');
          _openCatalog(catalogId);
        case final PaymentLookupNotOnLedger found:
          await showDialog<void>(
            context: context,
            builder: (_) => _NotOnLedgerDialog(
              found: found,
              onStartPlan: (catalogId) => context.push(
                '${AppRoutes.adminSubscriptions}/$catalogId'
                '?ref=${Uri.encodeQueryComponent(found.id)}',
              ),
            ),
          );
      }
    } on CatalogFailure catch (failure) {
      CatalogFeedback.failure(messenger, failure,
          subject: 'That payment could not be found');
    } finally {
      if (mounted) setState(() => _lookingUp = false);
    }
  }

  Widget _paymentsTab() => Column(
        children: [
          _FilterBar(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                AdminFilterChips<AdminPaymentFilter>(
                  key: const ValueKey('admin_payments_filter'),
                  values: AdminPaymentFilter.values,
                  selected: _paymentFilter,
                  labelOf: (f) => f.label,
                  keyOf: (f) => f.name,
                  onSelected: (f) => setState(() => _paymentFilter = f),
                ),
                const SizedBox(height: AppSpacing.sm),
                TextField(
                  key: const ValueKey('admin_lookup_field'),
                  controller: _lookupField,
                  textInputAction: TextInputAction.search,
                  onSubmitted: (_) => _lookingUp ? null : _lookup(),
                  decoration: InputDecoration(
                    isDense: true,
                    prefixIcon: const Icon(Icons.manage_search),
                    hintText: 'Find a payment: order_… or pay_…',
                    suffixIcon: IconButton(
                      key: const ValueKey('admin_lookup_go'),
                      tooltip: 'Find',
                      icon: const Icon(Icons.arrow_forward),
                      onPressed: _lookingUp ? null : _lookup,
                    ),
                  ),
                ),
              ],
            ),
          ),
          Expanded(
            child: _AttemptList(filter: _paymentFilter, onOpen: _openAttempt),
          ),
        ],
      );

  Widget _plansTab() => Column(
        children: [
          _FilterBar(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                AdminFilterChips<AdminSubscriptionFilter>(
                  key: const ValueKey('admin_subscriptions_filter'),
                  values: _planFilters,
                  selected: _planFilter,
                  labelOf: (f) => f.label,
                  keyOf: (f) => f.name,
                  onSelected: (f) => setState(() => _planFilter = f),
                ),
                const SizedBox(height: AppSpacing.sm),
                TextField(
                  key: const ValueKey('admin_subscriptions_search'),
                  controller: _search,
                  onChanged: _onSearch,
                  textInputAction: TextInputAction.search,
                  decoration: InputDecoration(
                    isDense: true,
                    prefixIcon: const Icon(Icons.search),
                    // #9: most owners never set a name — phone and email work too.
                    hintText: 'Restaurant, owner, phone (last 4+) or email',
                    suffixIcon: _search.text.isEmpty
                        ? null
                        : IconButton(
                            tooltip: 'Clear',
                            icon: const Icon(Icons.close),
                            onPressed: () {
                              _search.clear();
                              _debounce?.cancel();
                              setState(() => _query = '');
                            },
                          ),
                  ),
                ),
              ],
            ),
          ),
          Expanded(
            child: _StateList(
              listKey: (filter: _planFilter, query: _query),
              onOpen: _openCatalog,
            ),
          ),
        ],
      );
}

/// A Razorpay id our ledger has never seen: what Razorpay says, and — when
/// its notes name one of our catalogs — a way to record it there.
class _NotOnLedgerDialog extends StatelessWidget {
  const _NotOnLedgerDialog({required this.found, required this.onStartPlan});

  final PaymentLookupNotOnLedger found;
  final void Function(String catalogId) onStartPlan;

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    final catalogId = found.catalogId;
    return AlertDialog(
      backgroundColor: AppColors.surface1,
      title: const Text('Not on our ledger'),
      content: Column(
        key: const ValueKey('admin_lookup_not_on_ledger'),
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Razorpay: ${found.id} · ${found.status} · '
            '${formatPaise(found.amountPaise)}',
            style: textTheme.bodyMedium,
          ),
          if (found.orderId != null)
            Text('Order ${found.orderId}', style: textTheme.bodySmall),
          const SizedBox(height: AppSpacing.sm),
          Text(
            catalogId != null
                ? 'Its notes name ${found.catalogName?.isNotEmpty == true ? found.catalogName : 'one of our restaurants'}. '
                    'If the money is real, record it there with Start plan — '
                    'the id is filled in for you.'
                : 'Nothing links it to a restaurant. If you know whose it is, '
                    'open that restaurant and use Start plan with this id.',
            style: textTheme.bodySmall?.copyWith(color: AppColors.textSecondary),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Close'),
        ),
        if (catalogId != null && found.status == 'captured')
          FilledButton(
            key: const ValueKey('admin_lookup_start_plan'),
            onPressed: () {
              Navigator.of(context).pop();
              onStartPlan(catalogId);
            },
            child: const Text('Open restaurant'),
          ),
      ],
    );
  }
}

class _FilterBar extends StatelessWidget {
  const _FilterBar({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(
          AppSpacing.lg,
          AppSpacing.md,
          AppSpacing.lg,
          AppSpacing.sm,
        ),
        child: SizedBox(width: double.infinity, child: child),
      );
}

/// "Payments" with a count of what needs attention, once it has loaded.
class _AttentionTabLabel extends ConsumerWidget {
  const _AttentionTabLabel();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final page = ref
        .watch(adminPaymentAttemptsProvider(AdminPaymentFilter.attention))
        .valueOrNull;
    final count = page?.items.length ?? 0;
    if (count == 0) return const Text('Payments');
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        const Flexible(
          child: Text('Payments', overflow: TextOverflow.ellipsis),
        ),
        const SizedBox(width: AppSpacing.xs),
        Container(
          key: const ValueKey('admin_attention_badge'),
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
          decoration: BoxDecoration(
            color: AppColors.error,
            borderRadius: BorderRadius.circular(10),
          ),
          child: Text(
            page!.hasMore ? '$count+' : '$count',
            style: Theme.of(context)
                .textTheme
                .labelSmall
                ?.copyWith(color: Colors.white),
          ),
        ),
      ],
    );
  }
}

// ── Payments ────────────────────────────────────────────────────────────────

class _AttemptList extends ConsumerWidget {
  const _AttemptList({required this.filter, required this.onOpen});

  final AdminPaymentFilter filter;
  final void Function(String orderId) onOpen;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final provider = adminPaymentAttemptsProvider(filter);
    final list = ref.watch(provider);
    return RefreshIndicator(
      onRefresh: () => ref.read(provider.notifier).refresh(),
      child: list.when(
        loading: () => const Center(child: AppLoadingIndicator()),
        error: (_, __) => CatalogMessage(
          icon: Icons.cloud_off_outlined,
          title: "Couldn't load payments.",
          body: 'Check your connection and try again.',
          actionLabel: 'Try again',
          onAction: () => ref.read(provider.notifier).refresh(),
        ),
        data: (state) => state.items.isEmpty
            ? CatalogMessage(
                icon: filter == AdminPaymentFilter.attention
                    ? Icons.task_alt
                    : Icons.inbox_outlined,
                title: filter == AdminPaymentFilter.attention
                    ? 'Nothing needs attention.'
                    : 'Nothing here.',
                body: filter.emptyBody,
              )
            : ListView.separated(
                padding: const EdgeInsets.all(AppSpacing.lg),
                itemCount: state.items.length + (state.hasMore ? 1 : 0),
                separatorBuilder: (_, __) =>
                    const SizedBox(height: AppSpacing.sm),
                itemBuilder: (_, i) {
                  if (i == state.items.length) {
                    return _LoadMore(
                      loading: state.loadingMore,
                      onPressed: () => ref.read(provider.notifier).loadMore(),
                    );
                  }
                  final attempt = state.items[i];
                  return PaymentAttemptTile(
                    attempt: attempt,
                    onTap: () => onOpen(attempt.orderId),
                  );
                },
              ),
      ),
    );
  }
}

class _LoadMore extends StatelessWidget {
  const _LoadMore({required this.loading, required this.onPressed});

  final bool loading;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) => Center(
        child: TextButton(
          key: const ValueKey('admin_subscriptions_more'),
          onPressed: loading ? null : onPressed,
          child: Text(loading ? 'Loading…' : 'Load more'),
        ),
      );
}

// ── Cash ────────────────────────────────────────────────────────────────────

class _PendingQueue extends ConsumerWidget {
  const _PendingQueue({required this.onOpen});

  final void Function(String catalogId) onOpen;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final queue = ref.watch(adminManualQueueProvider);
    return RefreshIndicator(
      onRefresh: () => ref.refresh(adminManualQueueProvider.future),
      child: queue.when(
        loading: () => const Center(child: AppLoadingIndicator()),
        error: (_, __) => CatalogMessage(
          icon: Icons.cloud_off_outlined,
          title: "Couldn't load the queue.",
          body: 'Check your connection and try again.',
          actionLabel: 'Try again',
          onAction: () => ref.invalidate(adminManualQueueProvider),
        ),
        data: (items) => items.isEmpty
            ? const CatalogMessage(
                icon: Icons.task_alt,
                title: 'Nothing to verify.',
                body: 'Cash requests from reps land here.',
              )
            : ListView.separated(
                padding: const EdgeInsets.all(AppSpacing.lg),
                itemCount: items.length,
                separatorBuilder: (_, __) =>
                    const SizedBox(height: AppSpacing.sm),
                itemBuilder: (_, i) => _QueueTile(
                  record: items[i],
                  onTap: () => onOpen(items[i].catalogId),
                ),
              ),
      ),
    );
  }
}

class _QueueTile extends StatelessWidget {
  const _QueueTile({required this.record, required this.onTap});

  final ManualPaymentRecord record;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    return AppCard(
      key: ValueKey('admin_queue_${record.id}'),
      onTap: onTap,
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  record.catalogName.isEmpty
                      ? 'Restaurant'
                      : record.catalogName,
                  style: textTheme.bodyLarge,
                ),
                const SizedBox(height: AppSpacing.xs),
                Text(
                  '${formatPaise(record.amountPaise)} · '
                  '${record.method?.label ?? 'Manual'} · ${record.reference}',
                  style: textTheme.bodySmall
                      ?.copyWith(color: AppColors.textSecondary),
                ),
                if (!record.amountMatchesQuote) ...[
                  const SizedBox(height: AppSpacing.xs),
                  Text(
                    'Plan price ${formatPaise(record.quotedPaise)} — amount differs',
                    style:
                        textTheme.bodySmall?.copyWith(color: AppColors.warning),
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(width: AppSpacing.sm),
          const AdminStatusChip(label: 'Pending cash', color: AppColors.warning),
          const SizedBox(width: AppSpacing.sm),
          const Icon(Icons.chevron_right, color: AppColors.textMuted),
        ],
      ),
    );
  }
}

// ── Plans ───────────────────────────────────────────────────────────────────

class _StateList extends ConsumerWidget {
  const _StateList({required this.listKey, required this.onOpen});

  final AdminSubscriptionListKey listKey;
  final void Function(String catalogId) onOpen;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final provider = adminSubscriptionListProvider(listKey);
    final list = ref.watch(provider);
    return RefreshIndicator(
      onRefresh: () => ref.read(provider.notifier).refresh(),
      child: list.when(
        loading: () => const Center(child: AppLoadingIndicator()),
        error: (_, __) => CatalogMessage(
          icon: Icons.cloud_off_outlined,
          title: "Couldn't load the list.",
          body: 'Check your connection and try again.',
          actionLabel: 'Try again',
          onAction: () => ref.read(provider.notifier).refresh(),
        ),
        data: (state) => state.items.isEmpty
            ? CatalogMessage(
                icon: Icons.inbox_outlined,
                title: 'Nobody here.',
                body: listKey.query.isNotEmpty
                    ? 'No restaurant or owner matches "${listKey.query}".'
                    : switch (listKey.filter) {
                        AdminSubscriptionFilter.all =>
                          'No restaurant has a subscription yet.',
                        AdminSubscriptionFilter.expiring7d =>
                          'No plan ends in the next seven days.',
                        AdminSubscriptionFilter.grace =>
                          'No restaurant is in its grace period.',
                        AdminSubscriptionFilter.paused =>
                          'No 3D menu is paused.',
                        AdminSubscriptionFilter.paused90d =>
                          'No 3D menu has been paused for 90 days or more.',
                        AdminSubscriptionFilter.trial => 'No trial is running.',
                        AdminSubscriptionFilter.pending => '',
                      },
              )
            : ListView.separated(
                padding: const EdgeInsets.all(AppSpacing.lg),
                itemCount: state.items.length + (state.hasMore ? 1 : 0),
                separatorBuilder: (_, __) =>
                    const SizedBox(height: AppSpacing.sm),
                itemBuilder: (_, i) {
                  if (i == state.items.length) {
                    return _LoadMore(
                      loading: state.loadingMore,
                      onPressed: () => ref.read(provider.notifier).loadMore(),
                    );
                  }
                  final item = state.items[i];
                  return _SubscriptionTile(
                    item: item,
                    onTap: () => onOpen(item.catalogId),
                  );
                },
              ),
      ),
    );
  }
}

class _SubscriptionTile extends StatelessWidget {
  const _SubscriptionTile({required this.item, required this.onTap});

  final AdminSubscriptionListItem item;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    final tone = subscriptionTone(item.status);
    final color = switch (tone) {
      SubscriptionTone.good => AppColors.success,
      SubscriptionTone.warning => AppColors.warning,
      SubscriptionTone.danger => AppColors.error,
      SubscriptionTone.neutral => AppColors.textSecondary,
    };
    final days = item.daysLeft;
    // E46: a paused menu with cards that have nothing to show. Only worth a
    // word when 3D is actually off and some dish has no picture.
    final coverage = item.photoCoverage;
    final placeholders = item.status == SubscriptionStatus.paused &&
        coverage != null &&
        coverage < 100;
    return AppCard(
      key: ValueKey('admin_subscription_${item.catalogId}'),
      onTap: onTap,
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  item.catalogName.isEmpty ? 'Restaurant' : item.catalogName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: textTheme.bodyLarge,
                ),
                const SizedBox(height: AppSpacing.xs),
                Text(
                  [
                    if (item.planId != null) item.planId!.apiValue,
                    if (item.billingInterval != null)
                      item.billingInterval!.apiValue.toLowerCase(),
                    if (days != null) '$days day${days == 1 ? '' : 's'} left',
                    if (item.periodEnd != null)
                      'ends ${formatSubscriptionDate(item.periodEnd!)}',
                  ].join(' · '),
                  style: textTheme.bodySmall
                      ?.copyWith(color: AppColors.textSecondary),
                ),
                if (item.owner != null)
                  Text(
                    'Owner: ${item.owner!.displayLabel}',
                    key: ValueKey('admin_subscription_owner_${item.catalogId}'),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: textTheme.bodySmall
                        ?.copyWith(color: AppColors.textMuted),
                  ),
                if (placeholders) ...[
                  const SizedBox(height: AppSpacing.xs),
                  Text(
                    'Photos $coverage% — some cards are placeholders',
                    key: ValueKey('admin_subscription_photos_${item.catalogId}'),
                    style: textTheme.bodySmall?.copyWith(color: AppColors.error),
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(width: AppSpacing.sm),
          AdminStatusChip(label: item.status.apiValue, color: color),
          const SizedBox(width: AppSpacing.sm),
          const Icon(Icons.chevron_right, color: AppColors.textMuted),
        ],
      ),
    );
  }
}
