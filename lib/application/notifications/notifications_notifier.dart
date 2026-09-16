// lib/application/notifications/notifications_notifier.dart
import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/repositories/notifications_repository.dart';
import '../../domain/entities/app_notification.dart';
import '../../domain/entities/auth_state.dart';
import '../../utils/analytics.dart';
import '../auth/auth_notifier.dart';

/// Owns the signed-in user's notification feed — fetched from
/// `GET /notifications` on first watch, re-pulled by [refresh], and mutated
/// through the two read endpoints.
///
/// PULL, NOT PUSH. There is no real-time channel in v1. The feed is re-fetched
/// on the same occasions the app re-fetches projects and the profile: app
/// start (first watch — the bell on the Projects hub watches this), the hub's
/// focus/pull refresh, opening the Profile screen, and opening or pulling the
/// Notifications screen itself. A notification an admin sends is therefore
/// seen the next time the user does any of those, which is the accepted lag.
///
/// Lifecycle (the `ref.listen` + epoch-guard idiom of [ProfileNotifier]):
///   - First watch → fetch.
///   - On logout → the state is DROPPED and the epoch bumped, so a second user
///     never sees the first user's feed (a message can be addressed to one
///     person about their own account), and an in-flight fetch can't land.
///   - On auth established again → re-fetch for the NEW user.
///
/// NOT persisted to Hive: it is per-user, cheap to re-fetch, and a stale
/// badge painted at startup for the wrong account would be worse than none.
///
/// [refresh] is SILENT: it never drops loaded data into AsyncLoading, and a
/// failed refresh keeps the last good feed on screen. Only the very first
/// fetch (nothing to keep) can surface an AsyncError, which the screen turns
/// into a retry.
class NotificationsNotifier extends AsyncNotifier<NotificationsFeed> {
  /// Bumped on every auth transition and every explicit refresh; a request
  /// captures it at its start and discards its result if it changed meanwhile.
  int _epoch = 0;

  /// One in-flight fetch at a time. A focus refresh racing a pull refresh
  /// shares the same future rather than issuing two requests.
  Future<void>? _inFlight;

  @override
  Future<NotificationsFeed> build() async {
    ref.listen<AuthState>(authProvider, (prev, next) {
      final wasAuthed = prev is AuthAuthenticated || prev is AuthRefreshing;
      if (next is AuthUnauthenticated) {
        _epoch++;
        _inFlight = null;
        // Back to loading, not to a stale value — see ProfileNotifier for why
        // consumers must switch on the AsyncValue CASE rather than `.value`.
        state = const AsyncLoading<NotificationsFeed>();
      } else if (next is AuthAuthenticated && !wasAuthed) {
        _epoch++;
        _inFlight = null;
        state = const AsyncLoading<NotificationsFeed>();
        unawaited(_load(_epoch));
      }
    });

    final epoch = _epoch;
    return _fetch().then(
      (feed) => epoch == _epoch ? feed : _superseded(),
      onError: (Object error, StackTrace stack) => epoch == _epoch
          ? Future<NotificationsFeed>.error(error, stack)
          : _superseded(),
    );
  }

  /// A future that never completes — for a build fetch superseded by an auth
  /// transition. The listener has already installed the right state.
  Future<NotificationsFeed> _superseded() =>
      Completer<NotificationsFeed>().future;

  /// The repository read, wrapped so a provider that fails to CONSTRUCT (a
  /// misconfigured client) surfaces as an ordinary fetch failure rather than
  /// escaping the async build.
  Future<NotificationsFeed> _fetch() =>
      ref.read(notificationsRepositoryProvider).fetchFeed();

  /// The LOADED feed, or null while loading / after a failure / after the
  /// logout reset. Matched on the AsyncData CASE, never `.valueOrNull`:
  /// Riverpod carries the previous data along a loading transition, so
  /// `.valueOrNull` would still hand back the DEPARTING user's feed after a
  /// logout — exactly what the reset exists to prevent.
  NotificationsFeed? get _loaded => switch (state) {
        AsyncData(:final value) => value,
        _ => null,
      };

  /// The unread count the bell shows, or 0 while loading / after a failure —
  /// a badge that cannot be trusted is worse than none.
  int get unreadCount => _loaded?.unreadCount ?? 0;

  /// Re-pulls the feed WITHOUT blanking what is on screen. Never throws: a
  /// failed refresh keeps the last good feed (or, with nothing loaded yet,
  /// becomes the AsyncError the screen shows a retry for). Concurrent callers
  /// share one request.
  Future<void> refresh() {
    final pending = _inFlight;
    if (pending != null) return pending;
    _epoch++;
    final epoch = _epoch;
    late final Future<void> run;
    run = _load(epoch).whenComplete(() {
      if (identical(_inFlight, run)) _inFlight = null;
    });
    _inFlight = run;
    return run;
  }

  /// Marks one notification read, OPTIMISTICALLY: the row flips and the badge
  /// decrements at once; the previous feed is restored if the server refuses.
  /// A row that is already read is a no-op (no request).
  ///
  /// Rethrows so a screen can say "couldn't mark as read" — but the caller may
  /// equally ignore it: the rollback already happened.
  Future<void> markRead(String id) async {
    final previous = _loaded;
    if (previous == null) return;
    final index = previous.items.indexWhere((n) => n.id == id);
    if (index < 0 || previous.items[index].isRead) return;

    final epoch = _epoch;
    final next = [...previous.items];
    next[index] = next[index].markedRead();
    state = AsyncData(previous.withItems(next));

    try {
      final unread =
          await ref.read(notificationsRepositoryProvider).markRead(id);
      if (epoch != _epoch) return; // auth changed / a refresh superseded us
      _reconcileCount(unread);
      Analytics.logEvent(AnalyticsEvents.notificationRead, {
        'scope': 'one',
        'kind': previous.items[index].kind.name,
      });
    } catch (_) {
      if (epoch == _epoch) state = AsyncData(previous); // rollback
      rethrow;
    }
  }

  /// Marks everything read, optimistically, with the same rollback contract.
  /// No-op when nothing is unread.
  Future<void> markAllRead() async {
    final previous = _loaded;
    if (previous == null || !previous.hasUnread) return;

    final epoch = _epoch;
    state = AsyncData(
      previous.withItems([for (final n in previous.items) n.markedRead()]),
    );

    try {
      final unread =
          await ref.read(notificationsRepositoryProvider).markAllRead();
      if (epoch != _epoch) return;
      _reconcileCount(unread);
      Analytics.logEvent(AnalyticsEvents.notificationRead, {'scope': 'all'});
    } catch (_) {
      if (epoch == _epoch) state = AsyncData(previous);
      rethrow;
    }
  }

  /// After a write, adopt the SERVER's unread count if it disagrees with the
  /// optimistic one — a notification that arrived between the last fetch and
  /// this write is exactly what that disagreement means, and the badge should
  /// say so before the next refresh brings the row itself.
  void _reconcileCount(int serverUnread) {
    final current = _loaded;
    if (current == null || current.unreadCount == serverUnread) return;
    state = AsyncData(
      NotificationsFeed(items: current.items, unreadCount: serverUnread),
    );
  }

  Future<void> _load(int epoch) async {
    try {
      final feed = await _fetch();
      if (epoch != _epoch) return; // superseded (logout, or a newer refresh)
      state = AsyncData(feed);
    } catch (error, stack) {
      if (epoch != _epoch) return;
      // Keep the last good feed; only a first load with nothing to keep
      // becomes an error the screen can retry.
      if (_loaded == null) {
        state = AsyncError<NotificationsFeed>(error, stack);
      }
    }
  }
}

/// The signed-in user's notification feed. Resets on logout — never persisted.
final notificationsProvider =
    AsyncNotifierProvider<NotificationsNotifier, NotificationsFeed>(
  NotificationsNotifier.new,
);

/// The number on the bell's badge: the loaded feed's unread count, or 0 while
/// loading and after a failure. Derived, so the badge repaints on every feed
/// change with no second fetch.
///
/// Matched on the AsyncData CASE (see [NotificationsNotifier._loaded]) so the
/// logout reset really does zero the badge.
final unreadNotificationCountProvider = Provider<int>(
  (ref) => switch (ref.watch(notificationsProvider)) {
    AsyncData(:final value) => value.unreadCount,
    _ => 0,
  },
);
