// lib/presentation/screens/admin/admin_subscriptions_screen.dart
//
// Collections: who needs chasing, and the cash requests waiting for a Verify.
//
// Five segments over two server routes — Pending is the manual-payment queue,
// the other four are `GET /admin/subscriptions?state=`. One screen because an
// admin working payments does both in one sitting: verify the cash that came
// in, then look at who is about to lapse. Every row opens the same per-catalog
// panel (`/admin/subscriptions/:catalogId`), where every action lives.
//
// ADMIN-ONLY, on both sides: the router gate on this subtree mirrors the
// backend's `requireRole('ADMIN')` on every one of these routes (E39).
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/routes/app_router.dart';
import '../../../app/theme/app_colors.dart';
import '../../../app/theme/app_spacing.dart';
import '../../../application/admin/admin_subscriptions_notifier.dart';
import '../../../domain/catalog/subscription_copy.dart';
import '../../../domain/entities/catalog_subscription.dart';
import '../../../domain/entities/subscription_payment.dart';
import '../../widgets/app_card.dart';
import '../../widgets/app_loading_indicator.dart';
import '../../widgets/catalog/catalog_message.dart';

class AdminSubscriptionsScreen extends ConsumerStatefulWidget {
  const AdminSubscriptionsScreen({super.key, this.initialFilter});

  final AdminSubscriptionFilter? initialFilter;

  @override
  ConsumerState<AdminSubscriptionsScreen> createState() =>
      _AdminSubscriptionsScreenState();
}

class _AdminSubscriptionsScreenState
    extends ConsumerState<AdminSubscriptionsScreen> {
  late AdminSubscriptionFilter _filter =
      widget.initialFilter ?? AdminSubscriptionFilter.pending;

  void _open(String catalogId) =>
      context.push('${AppRoutes.adminSubscriptions}/$catalogId');

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.bgPrimary,
      appBar: AppBar(title: const Text('Subscriptions')),
      body: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(
                AppSpacing.lg,
                AppSpacing.md,
                AppSpacing.lg,
                AppSpacing.sm,
              ),
              child: SizedBox(
                width: double.infinity,
                child: SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: SegmentedButton<AdminSubscriptionFilter>(
                    key: const ValueKey('admin_subscriptions_filter'),
                    showSelectedIcon: false,
                    segments: [
                      for (final filter in AdminSubscriptionFilter.values)
                        ButtonSegment(
                          value: filter,
                          label: Text(filter.label),
                        ),
                    ],
                    selected: {_filter},
                    onSelectionChanged: (selection) =>
                        setState(() => _filter = selection.first),
                  ),
                ),
              ),
            ),
            Expanded(
              child: _filter == AdminSubscriptionFilter.pending
                  ? _PendingQueue(onOpen: _open)
                  : _StateList(filter: _filter, onOpen: _open),
            ),
          ],
        ),
      ),
    );
  }
}

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
          const _Chip(label: 'Pending cash', color: AppColors.warning),
          const SizedBox(width: AppSpacing.sm),
          const Icon(Icons.chevron_right, color: AppColors.textMuted),
        ],
      ),
    );
  }
}

class _StateList extends ConsumerWidget {
  const _StateList({required this.filter, required this.onOpen});

  final AdminSubscriptionFilter filter;
  final void Function(String catalogId) onOpen;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final list = ref.watch(adminSubscriptionListProvider(filter));
    return RefreshIndicator(
      onRefresh: () =>
          ref.read(adminSubscriptionListProvider(filter).notifier).refresh(),
      child: list.when(
        loading: () => const Center(child: AppLoadingIndicator()),
        error: (_, __) => CatalogMessage(
          icon: Icons.cloud_off_outlined,
          title: "Couldn't load the list.",
          body: 'Check your connection and try again.',
          actionLabel: 'Try again',
          onAction: () => ref
              .read(adminSubscriptionListProvider(filter).notifier)
              .refresh(),
        ),
        data: (state) => state.items.isEmpty
            ? CatalogMessage(
                icon: Icons.inbox_outlined,
                title: 'Nobody here.',
                body: switch (filter) {
                  AdminSubscriptionFilter.expiring7d =>
                    'No plan ends in the next seven days.',
                  AdminSubscriptionFilter.grace =>
                    'No restaurant is in its grace period.',
                  AdminSubscriptionFilter.paused => 'No 3D menu is paused.',
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
                    return Center(
                      child: TextButton(
                        key: const ValueKey('admin_subscriptions_more'),
                        onPressed: state.loadingMore
                            ? null
                            : () => ref
                                .read(adminSubscriptionListProvider(filter)
                                    .notifier)
                                .loadMore(),
                        child:
                            Text(state.loadingMore ? 'Loading…' : 'Load more'),
                      ),
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
                  style: textTheme.bodyLarge,
                ),
                const SizedBox(height: AppSpacing.xs),
                Text(
                  [
                    if (item.planId != null) item.planId!.apiValue,
                    if (days != null) '$days day${days == 1 ? '' : 's'} left',
                    if (item.periodEnd != null)
                      'ends ${formatSubscriptionDate(item.periodEnd!)}',
                  ].join(' · '),
                  style: textTheme.bodySmall
                      ?.copyWith(color: AppColors.textSecondary),
                ),
              ],
            ),
          ),
          _Chip(label: item.status.apiValue, color: color),
          const SizedBox(width: AppSpacing.sm),
          const Icon(Icons.chevron_right, color: AppColors.textMuted),
        ],
      ),
    );
  }
}

class _Chip extends StatelessWidget {
  const _Chip({required this.label, required this.color});

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
          style: Theme.of(context).textTheme.labelSmall?.copyWith(color: color),
        ),
      );
}
