// lib/data/repositories/notifications_repository.dart
import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../domain/entities/app_notification.dart';
import '../remote/api_client.dart';

/// The in-app notification feed over `/notifications` (authed — rides the app
/// Dio with the Bearer/refresh interceptor).
///
/// Pull-only. There is no push channel: the notifier calls [fetchFeed] on the
/// same occasions the app re-fetches projects and the profile. Every method
/// throws on transport/auth/parse failure; the notifier decides what the
/// screen sees (it keeps the last good feed on a failed refresh).
abstract interface class NotificationsRepository {
  /// The feed, newest first, with the server's unread count.
  Future<NotificationsFeed> fetchFeed();

  /// Marks one read. Returns the server's unread count AFTER the write.
  /// Idempotent server-side — the first readAt wins.
  Future<int> markRead(String id);

  /// Marks everything currently visible read. Returns the unread count after
  /// (always 0 on success, but read from the body rather than assumed).
  Future<int> markAllRead();
}

class RemoteNotificationsRepository implements NotificationsRepository {
  RemoteNotificationsRepository(this._dio);

  final Dio _dio;

  @override
  Future<NotificationsFeed> fetchFeed() async {
    final res = await _dio.get<Map<String, dynamic>>('/notifications');
    final body = res.data;
    if (body == null) {
      throw const FormatException('notifications response has no body');
    }
    return NotificationsFeed.fromJson(body);
  }

  @override
  Future<int> markRead(String id) async {
    final res =
        await _dio.post<Map<String, dynamic>>('/notifications/$id/read');
    return _unreadCountFrom(res.data);
  }

  @override
  Future<int> markAllRead() async {
    final res =
        await _dio.post<Map<String, dynamic>>('/notifications/read-all');
    return _unreadCountFrom(res.data);
  }

  /// The `unreadCount` out of a write response. Absent/ill-typed is a hard
  /// failure — the notifier uses it to reconcile its optimistic count, and a
  /// guess here would be a badge lying with confidence.
  static int _unreadCountFrom(Map<String, dynamic>? body) {
    final count = body?['unreadCount'];
    if (count is int && count >= 0) return count;
    throw const FormatException('notifications response has no unreadCount');
  }
}

/// App-wide notifications repository.
final notificationsRepositoryProvider = Provider<NotificationsRepository>(
  (ref) => RemoteNotificationsRepository(ref.watch(dioProvider)),
);
