// test/notifications/notifications_notifier_test.dart
//
// The feed notifier's lifecycle: fetch on first watch, a SILENT refresh that
// keeps the last good feed on failure, optimistic mark-read with rollback, the
// server-count reconcile, and — the load-bearing part — a RESET on logout that
// a second user can never see through (a notification can be addressed to
// one person about their own account).
import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:recapture/application/auth/auth_notifier.dart';
import 'package:recapture/application/notifications/notifications_notifier.dart';
import 'package:recapture/data/repositories/notifications_repository.dart';
import 'package:recapture/domain/entities/app_notification.dart';
import 'package:recapture/domain/entities/auth_session.dart';
import 'package:recapture/domain/entities/auth_state.dart';

class _FakeNotificationsRepository implements NotificationsRepository {
  NotificationsFeed feed = NotificationsFeed.empty;
  bool failFetch = false;
  bool failWrite = false;
  int fetchCalls = 0;
  final List<String> readIds = [];
  int readAllCalls = 0;

  /// The count the WRITE endpoints answer with. Null = "whatever the local
  /// optimistic count is" (i.e. agree with the client).
  int? serverUnreadAfterWrite;

  /// When set, fetchFeed waits on it — holds a fetch in flight across an auth
  /// transition.
  Completer<void>? gate;

  @override
  Future<NotificationsFeed> fetchFeed() async {
    fetchCalls++;
    if (gate != null) await gate!.future;
    if (failFetch) throw Exception('offline');
    return feed;
  }

  @override
  Future<int> markRead(String id) async {
    if (failWrite) throw Exception('rejected');
    readIds.add(id);
    return serverUnreadAfterWrite ??
        feed.items.where((n) => !n.isRead && n.id != id).length;
  }

  @override
  Future<int> markAllRead() async {
    readAllCalls++;
    if (failWrite) throw Exception('rejected');
    return serverUnreadAfterWrite ?? 0;
  }
}

class _DrivenAuthNotifier extends AuthNotifier {
  @override
  AuthState build() => const AuthRestoring();

  void emit(AuthState next) => state = next;
}

AppNotification _n(String id, {bool read = false}) => AppNotification(
      id: id,
      kind: NotificationKind.info,
      title: 'T $id',
      message: 'M $id',
      createdAt: DateTime.utc(2026, 9, 1),
      isRead: read,
    );

NotificationsFeed _feed(List<AppNotification> items) =>
    NotificationsFeed.empty.withItems(items);

AuthSession _session() => AuthSession(
      accessToken: 'a',
      refreshToken: 'r',
      accessTokenExpiry: DateTime.now().toUtc().add(const Duration(hours: 1)),
      userId: 'u1',
    );

Future<void> _pump() async {
  for (var i = 0; i < 10; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

void main() {
  late _FakeNotificationsRepository repo;
  late ProviderContainer container;

  ProviderContainer buildContainer() => ProviderContainer(overrides: [
        notificationsRepositoryProvider.overrideWithValue(repo),
        authProvider.overrideWith(_DrivenAuthNotifier.new),
      ]);

  _DrivenAuthNotifier auth() =>
      container.read(authProvider.notifier) as _DrivenAuthNotifier;

  NotificationsNotifier notifier() =>
      container.read(notificationsProvider.notifier);

  setUp(() {
    repo = _FakeNotificationsRepository()
      ..feed = _feed([_n('a'), _n('b'), _n('c', read: true)]);
  });

  tearDown(() => container.dispose());

  test('fetches on first watch and exposes the unread count', () async {
    container = buildContainer();
    expect(container.read(notificationsProvider),
        isA<AsyncLoading<NotificationsFeed>>());
    expect(container.read(unreadNotificationCountProvider), 0);
    await _pump();

    expect(container.read(notificationsProvider).value?.items.length, 3);
    expect(container.read(unreadNotificationCountProvider), 2);
    expect(repo.fetchCalls, 1);
  });

  test('a failed FIRST fetch is an AsyncError (retryable) and the badge is 0',
      () async {
    repo.failFetch = true;
    container = buildContainer();
    container.read(notificationsProvider);
    await _pump();

    expect(container.read(notificationsProvider),
        isA<AsyncError<NotificationsFeed>>());
    expect(container.read(unreadNotificationCountProvider), 0);

    repo.failFetch = false;
    await notifier().refresh();
    expect(container.read(unreadNotificationCountProvider), 2);
  });

  test('a failed REFRESH keeps the last good feed on screen', () async {
    container = buildContainer();
    container.read(notificationsProvider);
    await _pump();

    repo.failFetch = true;
    await notifier().refresh(); // must not throw

    expect(container.read(notificationsProvider),
        isA<AsyncData<NotificationsFeed>>());
    expect(container.read(unreadNotificationCountProvider), 2);
  });

  test('refresh picks up a new server feed without going through loading',
      () async {
    container = buildContainer();
    container.read(notificationsProvider);
    await _pump();

    repo.feed = _feed([_n('new'), _n('a'), _n('b'), _n('c', read: true)]);
    final states = <AsyncValue<NotificationsFeed>>[];
    container.listen(notificationsProvider, (_, next) => states.add(next));
    await notifier().refresh();

    expect(states.whereType<AsyncLoading<NotificationsFeed>>(), isEmpty);
    expect(container.read(unreadNotificationCountProvider), 3);
    expect(container.read(notificationsProvider).value?.items.first.id, 'new');
  });

  test('concurrent refreshes share one request', () async {
    container = buildContainer();
    container.read(notificationsProvider);
    await _pump();
    expect(repo.fetchCalls, 1);

    repo.gate = Completer<void>();
    final r1 = notifier().refresh();
    final r2 = notifier().refresh();
    repo.gate!.complete();
    await Future.wait([r1, r2]);

    expect(repo.fetchCalls, 2); // the first watch + ONE shared refresh
  });

  group('markRead', () {
    test('flips the row and decrements the badge optimistically', () async {
      container = buildContainer();
      container.read(notificationsProvider);
      await _pump();

      final done = notifier().markRead('a');
      // Synchronously painted, before the request resolves.
      expect(container.read(unreadNotificationCountProvider), 1);
      final row = container
          .read(notificationsProvider)
          .value!
          .items
          .firstWhere((n) => n.id == 'a');
      expect(row.isRead, isTrue);
      expect(row.readAt, isNotNull);

      await done;
      expect(repo.readIds, ['a']);
      expect(container.read(unreadNotificationCountProvider), 1);
    });

    test('rolls back when the server refuses, and rethrows', () async {
      container = buildContainer();
      container.read(notificationsProvider);
      await _pump();

      repo.failWrite = true;
      await expectLater(notifier().markRead('a'), throwsException);

      expect(container.read(unreadNotificationCountProvider), 2);
      final row = container
          .read(notificationsProvider)
          .value!
          .items
          .firstWhere((n) => n.id == 'a');
      expect(row.isRead, isFalse);
    });

    test('is a no-op (no request) on an already-read row or an unknown id',
        () async {
      container = buildContainer();
      container.read(notificationsProvider);
      await _pump();

      await notifier().markRead('c');
      await notifier().markRead('nope');
      expect(repo.readIds, isEmpty);
      expect(container.read(unreadNotificationCountProvider), 2);
    });

    test('adopts the SERVER count when it disagrees (a new arrival)', () async {
      container = buildContainer();
      container.read(notificationsProvider);
      await _pump();

      repo.serverUnreadAfterWrite = 5; // something arrived since the fetch
      await notifier().markRead('a');
      expect(container.read(unreadNotificationCountProvider), 5);
    });
  });

  group('markAllRead', () {
    test('flips every row and zeroes the badge', () async {
      container = buildContainer();
      container.read(notificationsProvider);
      await _pump();

      final done = notifier().markAllRead();
      expect(container.read(unreadNotificationCountProvider), 0);
      await done;
      expect(repo.readAllCalls, 1);
      expect(
        container
            .read(notificationsProvider)
            .value!
            .items
            .every((n) => n.isRead),
        isTrue,
      );
    });

    test('rolls back on failure', () async {
      container = buildContainer();
      container.read(notificationsProvider);
      await _pump();

      repo.failWrite = true;
      await expectLater(notifier().markAllRead(), throwsException);
      expect(container.read(unreadNotificationCountProvider), 2);
    });

    test('is a no-op when nothing is unread', () async {
      repo.feed = _feed([_n('c', read: true)]);
      container = buildContainer();
      container.read(notificationsProvider);
      await _pump();

      await notifier().markAllRead();
      expect(repo.readAllCalls, 0);
    });
  });

  group('auth transitions', () {
    test('logout DROPS the feed and the badge; the next login re-fetches',
        () async {
      container = buildContainer();
      container.read(notificationsProvider);
      await _pump();
      expect(container.read(unreadNotificationCountProvider), 2);

      auth().emit(const AuthUnauthenticated());
      expect(container.read(notificationsProvider),
          isA<AsyncLoading<NotificationsFeed>>());
      expect(container.read(unreadNotificationCountProvider), 0);

      repo.feed = _feed([_n('other-user')]);
      auth().emit(AuthAuthenticated(_session()));
      await _pump();
      expect(container.read(notificationsProvider).value?.items.single.id,
          'other-user');
      expect(repo.fetchCalls, 2);
    });

    test('a fetch in flight across a logout can never land', () async {
      repo.gate = Completer<void>();
      container = buildContainer();
      container.read(notificationsProvider); // fetch starts, parked on the gate
      await _pump();

      auth().emit(const AuthUnauthenticated());
      repo.gate!.complete(); // the departing user's feed arrives late
      await _pump();

      expect(container.read(notificationsProvider),
          isA<AsyncLoading<NotificationsFeed>>());
      expect(container.read(unreadNotificationCountProvider), 0);
    });

    test('a routine refresh-rotation does not re-fetch', () async {
      container = buildContainer();
      container.read(notificationsProvider);
      await _pump();

      auth().emit(AuthAuthenticated(_session()));
      auth().emit(AuthRefreshing(_session()));
      auth().emit(AuthAuthenticated(_session()));
      await _pump();

      expect(
          repo.fetchCalls, 2); // first watch + the restore→authenticated edge
    });
  });
}
