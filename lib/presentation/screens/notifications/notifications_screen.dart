// lib/presentation/screens/notifications/notifications_screen.dart
//
// The in-app notification feed: the bell's destination.
//
// A pull surface. It re-fetches on open and on pull-to-refresh, and a
// notification an admin sends between two of those is simply not here yet —
// there is no push channel in v1 (see NotificationsNotifier).
//
// One row per notification: kind icon, bold title while unread, the message,
// a relative time, and up to two buttons — "Details" when there is long-form
// text, and the admin's action when there is one. Tapping the row marks it
// read (optimistically) and opens the detail sheet when there is a detail;
// with no detail the tap just marks it read, and the visible change is the
// row settling from bold to plain.
import 'dart:async';

import 'package:flutter/foundation.dart'
    show defaultTargetPlatform, TargetPlatform;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/routes/flow_back.dart';
import '../../../app/theme/app_colors.dart';
import '../../../app/theme/app_spacing.dart';
import '../../../application/catalog/catalog_link_service.dart';
import '../../../application/notifications/notifications_notifier.dart';
import '../../../domain/entities/app_notification.dart';
import '../../../utils/analytics.dart';
import '../../../utils/extensions.dart';
import '../../widgets/app_button.dart';
import '../../widgets/app_card.dart';

class NotificationsScreen extends ConsumerStatefulWidget {
  const NotificationsScreen({super.key});

  @override
  ConsumerState<NotificationsScreen> createState() =>
      _NotificationsScreenState();
}

class _NotificationsScreenState extends ConsumerState<NotificationsScreen> {
  /// Guards "Mark all read" against a double-tap firing two requests.
  bool _markingAll = false;

  /// Guards against stacking a second detail sheet on a rapid double-tap.
  bool _sheetOpen = false;

  NotificationsNotifier get _notifier =>
      ref.read(notificationsProvider.notifier);

  @override
  void initState() {
    super.initState();
    // Opening the screen is one of the fetch occasions — the bell's count may
    // be minutes old. Silent: a failure keeps whatever is already loaded.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      unawaited(_notifier.refresh());
      Analytics.logEvent(AnalyticsEvents.notificationsScreenOpened, {
        'device_type': _deviceType,
        'unread_count': _notifier.unreadCount,
      });
    });
  }

  String get _deviceType =>
      defaultTargetPlatform == TargetPlatform.iOS ? 'ios' : 'android';

  // ── Actions ─────────────────────────────────────────────────────────────────

  Future<void> _markAllRead() async {
    if (_markingAll) return;
    setState(() => _markingAll = true);
    try {
      await _notifier.markAllRead();
    } catch (_) {
      _toast("Couldn't mark all as read. Try again.");
    } finally {
      if (mounted) setState(() => _markingAll = false);
    }
  }

  /// Row tap: mark read, then open the detail sheet if there is a detail.
  Future<void> _open(AppNotification n) async {
    // Fire-and-forget: the optimistic flip already painted, and the rollback
    // (if any) is the notifier's. The sheet must not wait on the network.
    unawaited(_notifier.markRead(n.id).catchError((_) {}));
    if (n.hasDetail) await _showDetail(n);
  }

  Future<void> _showDetail(AppNotification n) async {
    if (_sheetOpen) return;
    _sheetOpen = true;
    try {
      await showModalBottomSheet<void>(
        context: context,
        isScrollControlled: true,
        backgroundColor: AppColors.surface1,
        shape: const RoundedRectangleBorder(
          borderRadius:
              BorderRadius.vertical(top: Radius.circular(AppRadius.lg)),
        ),
        builder: (_) => _NotificationDetailSheet(
          notification: n,
          onAction: n.hasAction ? () => _runAction(n) : null,
        ),
      );
    } finally {
      _sheetOpen = false;
    }
  }

  /// The admin's CTA. An in-app path goes through the router (push, so BACK
  /// returns here); anything else opens externally through the same seam the
  /// catalog link uses. Also marks the row read — following a link is reading.
  Future<void> _runAction(AppNotification n) async {
    final action = n.action;
    if (action == null) return;
    unawaited(_notifier.markRead(n.id).catchError((_) {}));
    Analytics.logEvent(AnalyticsEvents.notificationActionOpened, {
      'kind': n.kind.name,
      'target': action.isInAppRoute ? 'in_app' : 'external',
    });
    if (action.isInAppRoute) {
      // Close a detail sheet first so the pushed screen lands on top of the
      // list, not on top of the sheet.
      if (_sheetOpen && mounted) Navigator.of(context).pop();
      if (!mounted) return;
      final router = GoRouter.maybeOf(context);
      if (router == null) return; // widget tests pump without a router
      router.push(action.url);
      return;
    }
    try {
      await ref.read(catalogLinkActionsProvider).open(action.url);
    } catch (_) {
      _toast("Couldn't open that link.");
    }
  }

  void _toast(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  // ── Build ───────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final feedAsync = ref.watch(notificationsProvider);
    // The AsyncData CASE, not `.valueOrNull`: a logout reset must hide the
    // action too (see NotificationsNotifier._loaded).
    final hasUnread = switch (feedAsync) {
      AsyncData(:final value) => value.hasUnread,
      _ => false,
    };

    return Scaffold(
      backgroundColor: AppColors.bgPrimary,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        title: Text('Notifications',
            style: Theme.of(context).textTheme.titleLarge),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back, color: AppColors.textSecondary),
          onPressed: () => navigateBack(context),
        ),
        actions: [
          // Only offered while there is something to mark — an always-present
          // "Mark all read" over an all-read list is a button that does nothing.
          if (hasUnread)
            TextButton(
              onPressed: _markingAll ? null : _markAllRead,
              child: const Text('Mark all read'),
            ),
        ],
      ),
      body: SafeArea(
        child: switch (feedAsync) {
          AsyncData(:final value) => _refreshable(
              value.isEmpty
                  ? const _EmptyView()
                  : ListView.separated(
                      physics: const AlwaysScrollableScrollPhysics(),
                      padding: const EdgeInsets.all(AppSpacing.lg),
                      itemCount: value.items.length,
                      separatorBuilder: (_, __) =>
                          const SizedBox(height: AppSpacing.sm),
                      itemBuilder: (context, index) {
                        final n = value.items[index];
                        return NotificationTile(
                          notification: n,
                          onTap: () => _open(n),
                          onDetails: n.hasDetail ? () => _open(n) : null,
                          onAction: n.hasAction ? () => _runAction(n) : null,
                        );
                      },
                    ),
            ),
          AsyncError() => _refreshable(
              _ErrorView(onRetry: () => _notifier.refresh()),
            ),
          _ => const _SkeletonList(),
        },
      ),
    );
  }

  /// Pull-to-refresh, with a scrollable fill so the gesture works on the empty
  /// and error states too.
  Widget _refreshable(Widget child) {
    final body = child is ListView
        ? child
        : LayoutBuilder(
            builder: (context, constraints) => SingleChildScrollView(
              physics: const AlwaysScrollableScrollPhysics(),
              child: ConstrainedBox(
                constraints: BoxConstraints(minHeight: constraints.maxHeight),
                child: child,
              ),
            ),
          );
    return RefreshIndicator(
      color: AppColors.mirageRed,
      backgroundColor: AppColors.surface1,
      onRefresh: _notifier.refresh,
      child: body,
    );
  }
}

// ── Row ──────────────────────────────────────────────────────────────────────

/// One notification row. Public so the widget test can pump it alone.
class NotificationTile extends StatelessWidget {
  const NotificationTile({
    super.key,
    required this.notification,
    required this.onTap,
    this.onDetails,
    this.onAction,
  });

  final AppNotification notification;
  final VoidCallback onTap;

  /// Null hides the Details button.
  final VoidCallback? onDetails;

  /// Null hides the action button.
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final n = notification;
    final unread = !n.isRead;

    return AppCard(
      onTap: onTap,
      border: unread
          ? BorderSide(color: AppColors.mirageRed.withValues(alpha: 0.5))
          : null,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _KindIcon(kind: n.kind, unread: unread),
              const SizedBox(width: AppSpacing.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            n.title,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.titleSmall?.copyWith(
                              color: AppColors.textPrimary,
                              fontWeight:
                                  unread ? FontWeight.w700 : FontWeight.w500,
                            ),
                          ),
                        ),
                        if (unread) ...[
                          const SizedBox(width: AppSpacing.sm),
                          const _UnreadDot(),
                        ],
                      ],
                    ),
                    const SizedBox(height: AppSpacing.xs),
                    Text(
                      n.message,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: unread
                            ? AppColors.textPrimary
                            : AppColors.textSecondary,
                      ),
                    ),
                    const SizedBox(height: AppSpacing.xs),
                    Text(
                      n.createdAt.toLocal().timeAgo,
                      style: theme.textTheme.bodySmall
                          ?.copyWith(color: AppColors.textMuted),
                    ),
                  ],
                ),
              ),
            ],
          ),
          if (onDetails != null || onAction != null) ...[
            const SizedBox(height: AppSpacing.md),
            Row(
              children: [
                if (onDetails != null)
                  AppButton.secondary(
                    label: 'Details',
                    isFullWidth: false,
                    onPressed: onDetails,
                  ),
                if (onDetails != null && onAction != null)
                  const SizedBox(width: AppSpacing.sm),
                if (onAction != null)
                  AppButton(
                    label: n.action!.label,
                    isFullWidth: false,
                    icon: n.action!.isInAppRoute
                        ? Icons.arrow_forward
                        : Icons.open_in_new,
                    onPressed: onAction,
                  ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

/// The unread marker beside the title.
class _UnreadDot extends StatelessWidget {
  const _UnreadDot();

  @override
  Widget build(BuildContext context) => Container(
        width: 8,
        height: 8,
        decoration: const BoxDecoration(
          color: AppColors.mirageRed,
          shape: BoxShape.circle,
        ),
      );
}

class _KindIcon extends StatelessWidget {
  const _KindIcon({required this.kind, required this.unread});

  final NotificationKind kind;
  final bool unread;

  static IconData iconFor(NotificationKind kind) => switch (kind) {
        NotificationKind.welcome => Icons.waving_hand_outlined,
        NotificationKind.paymentDue => Icons.payment_outlined,
        NotificationKind.paymentActivate => Icons.verified_outlined,
        NotificationKind.analytics => Icons.insights_outlined,
        NotificationKind.system => Icons.build_circle_outlined,
        NotificationKind.info => Icons.info_outline,
      };

  @override
  Widget build(BuildContext context) => Container(
        width: 40,
        height: 40,
        decoration: BoxDecoration(
          color: (unread ? AppColors.mirageRed : AppColors.royalGold)
              .withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(AppRadius.xs),
        ),
        child: Icon(
          iconFor(kind),
          size: 22,
          color: unread ? AppColors.mirageRed : AppColors.royalGold,
        ),
      );
}

// ── Detail sheet ─────────────────────────────────────────────────────────────

class _NotificationDetailSheet extends StatelessWidget {
  const _NotificationDetailSheet({required this.notification, this.onAction});

  final AppNotification notification;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final n = notification;
    final maxHeight = MediaQuery.sizeOf(context).height * 0.85;

    return SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: maxHeight),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(
            AppSpacing.xl,
            AppSpacing.lg,
            AppSpacing.xl,
            AppSpacing.xl,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  _KindIcon(kind: n.kind, unread: false),
                  const SizedBox(width: AppSpacing.md),
                  Expanded(
                    child: Text(
                      n.title,
                      style: theme.textTheme.titleMedium
                          ?.copyWith(color: AppColors.textPrimary),
                    ),
                  ),
                  IconButton(
                    tooltip: 'Close',
                    icon:
                        const Icon(Icons.close, color: AppColors.textSecondary),
                    onPressed: () => Navigator.of(context).pop(),
                  ),
                ],
              ),
              const SizedBox(height: AppSpacing.xs),
              Text(
                n.createdAt.toLocal().timeAgo,
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: AppColors.textMuted),
              ),
              const SizedBox(height: AppSpacing.lg),
              Flexible(
                child: SingleChildScrollView(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        n.message,
                        style: theme.textTheme.bodyMedium
                            ?.copyWith(color: AppColors.textPrimary),
                      ),
                      if (n.hasDetail) ...[
                        const SizedBox(height: AppSpacing.md),
                        Text(
                          n.detail!,
                          style: theme.textTheme.bodyMedium
                              ?.copyWith(color: AppColors.textSecondary),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
              if (onAction != null) ...[
                const SizedBox(height: AppSpacing.xl),
                AppButton(
                  label: n.action!.label,
                  icon: n.action!.isInAppRoute
                      ? Icons.arrow_forward
                      : Icons.open_in_new,
                  onPressed: onAction,
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

// ── States ───────────────────────────────────────────────────────────────────

class _EmptyView extends StatelessWidget {
  const _EmptyView();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.all(AppSpacing.xxxl),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Icon(
            Icons.notifications_none_outlined,
            size: 48,
            color: AppColors.textMuted,
          ),
          const SizedBox(height: AppSpacing.lg),
          Text(
            "You're all caught up",
            textAlign: TextAlign.center,
            style: theme.textTheme.titleMedium
                ?.copyWith(color: AppColors.textPrimary),
          ),
          const SizedBox(height: AppSpacing.sm),
          Text(
            'Updates about payments, activation and your catalog will show up here.',
            textAlign: TextAlign.center,
            style: theme.textTheme.bodyMedium
                ?.copyWith(color: AppColors.textSecondary),
          ),
        ],
      ),
    );
  }
}

class _ErrorView extends StatelessWidget {
  const _ErrorView({required this.onRetry});

  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.all(AppSpacing.xxxl),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Icon(
            Icons.notifications_off_outlined,
            size: 40,
            color: AppColors.textMuted,
          ),
          const SizedBox(height: AppSpacing.lg),
          Text(
            "Couldn't load your notifications.",
            textAlign: TextAlign.center,
            style: theme.textTheme.bodyMedium
                ?.copyWith(color: AppColors.textSecondary),
          ),
          const SizedBox(height: AppSpacing.lg),
          AppButton.secondary(
            label: 'Retry',
            isFullWidth: false,
            onPressed: onRetry,
          ),
        ],
      ),
    );
  }
}

/// Three placeholder rows with the list's shape, for the first load.
class _SkeletonList extends StatelessWidget {
  const _SkeletonList();

  @override
  Widget build(BuildContext context) => ListView.separated(
        padding: const EdgeInsets.all(AppSpacing.lg),
        itemCount: 3,
        separatorBuilder: (_, __) => const SizedBox(height: AppSpacing.sm),
        itemBuilder: (_, __) => const AppCard(
          child: SizedBox(height: 64),
        ),
      );
}
