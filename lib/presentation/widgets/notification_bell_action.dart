// lib/presentation/widgets/notification_bell_action.dart
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/routes/app_router.dart';
import '../../app/theme/app_colors.dart';
import '../../application/notifications/notifications_notifier.dart';

/// The app-bar entry point to /notifications: a bell, with an unread-count
/// badge when there is anything unread.
///
/// The badge reads [unreadNotificationCountProvider], which is 0 while the
/// feed loads and after a failed fetch — so the bell itself is ALWAYS there
/// and always tappable, and only the number depends on the network. A bell
/// that vanished while offline would take away the one way to see what was
/// already fetched.
///
/// The count is capped at "9+": a two-digit badge is a badge that has stopped
/// being a nudge and started being a number, and the screen has the real one.
class NotificationBellAction extends ConsumerWidget {
  const NotificationBellAction({super.key});

  /// Above this the badge reads [overflowLabel].
  static const int maxBadgeCount = 9;
  static const String overflowLabel = '9+';

  /// The badge text for [count], or null for "no badge".
  static String? badgeLabelFor(int count) {
    if (count <= 0) return null;
    return count > maxBadgeCount ? overflowLabel : '$count';
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final unread = ref.watch(unreadNotificationCountProvider);
    final label = badgeLabelFor(unread);

    return IconButton(
      tooltip: 'Notifications',
      icon: Badge(
        isLabelVisible: label != null,
        label: label == null ? null : Text(label),
        backgroundColor: AppColors.mirageRed,
        textColor: Colors.white,
        child: Icon(
          // Filled when something is waiting, outlined when not — the same
          // read/unread emphasis the list rows use.
          label == null ? Icons.notifications_outlined : Icons.notifications,
          color:
              label == null ? AppColors.textSecondary : AppColors.textPrimary,
        ),
      ),
      // go(), not push: /notifications is a standalone top-level destination
      // like /profile, so the address bar reads what a deep link would. BACK
      // is mapped /notifications → /projects by FlowBackScope.
      onPressed: () => context.goNamed(AppRouteNames.notifications),
    );
  }
}
