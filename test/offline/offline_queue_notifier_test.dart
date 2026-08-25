// test/offline/offline_queue_notifier_test.dart
import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:recapture/application/auth/auth_notifier.dart';
import 'package:recapture/application/connectivity/connectivity_providers.dart';
import 'package:recapture/application/offline/offline_queue_notifier.dart';
import 'package:recapture/data/local/offline_queue_box.dart';
import 'package:recapture/data/local/storage_providers.dart';
import 'package:recapture/domain/entities/auth_state.dart';
import 'package:recapture/domain/entities/offline_action.dart';
import 'package:recapture/platform/connectivity_watcher.dart';

OfflineAction _action(OfflineActionType type, {String? id, int attempts = 0}) =>
    OfflineAction(
      id: id ?? OfflineAction.newId(),
      type: type,
      payload: const {},
      createdAt: DateTime.utc(2026),
      attempts: attempts,
    );

/// In-memory queue box (no Hive). Subclasses so it satisfies the provider type.
class FakeOfflineQueueBox extends OfflineQueueBox {
  FakeOfflineQueueBox([List<OfflineAction> seeded = const []])
      : stored = List.of(seeded);

  List<OfflineAction> stored;

  @override
  Future<List<OfflineAction>> read() async => List.of(stored);

  @override
  Future<void> save(List<OfflineAction> actions) async =>
      stored = List.of(actions);

  @override
  Future<void> clear() async => stored = [];
}

/// Controllable auth notifier so tests can flip to unauthenticated without
/// touching secure storage / the network.
class FakeAuthNotifier extends AuthNotifier {
  @override
  AuthState build() => const AuthRestoring();

  void emit(AuthState next) => state = next;
}

typedef _Harness = ({
  ProviderContainer container,
  FakeOfflineQueueBox box,
  StreamController<AppConnectivityStatus> conn,
  FakeAuthNotifier auth,
});

_Harness _harness({List<OfflineAction> seeded = const []}) {
  final box = FakeOfflineQueueBox(seeded);
  final conn = StreamController<AppConnectivityStatus>.broadcast();
  final auth = FakeAuthNotifier();
  final container = ProviderContainer(overrides: [
    offlineQueueBoxProvider.overrideWithValue(box),
    connectivityStatusProvider.overrideWith((ref) => conn.stream),
    authProvider.overrideWith(() => auth),
  ]);
  addTearDown(container.dispose);
  addTearDown(conn.close);
  return (container: container, box: box, conn: conn, auth: auth);
}

Future<void> _settle() async {
  for (var i = 0; i < 20; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

void main() {
  test('enqueue persists and updates pendingCount', () async {
    final h = _harness();
    final n = h.container.read(offlineQueueProvider.notifier);
    await n.enqueue(_action(OfflineActionType.renameProject));
    expect(h.container.read(offlineQueueProvider).pendingCount, 1);
    expect(h.box.stored.length, 1);
  });

  test('drain retains failing actions and increments attempts', () async {
    final h = _harness();
    final n = h.container.read(offlineQueueProvider.notifier);
    await n.enqueue(_action(OfflineActionType.renameProject)); // _process → false
    await n.processQueue();
    final state = h.container.read(offlineQueueProvider);
    expect(state.pendingCount, 1);
    expect(state.pending.single.attempts, 1);
    expect(h.box.stored.single.attempts, 1); // persisted too
  });

  test('drain removes successfully-processed actions (unknown dropped)', () async {
    final h = _harness();
    final n = h.container.read(offlineQueueProvider.notifier);
    await n.enqueue(_action(OfflineActionType.unknown)); // _process → true
    await n.processQueue();
    expect(h.container.read(offlineQueueProvider).pendingCount, 0);
    expect(h.box.stored, isEmpty);
  });

  test('action exceeding the attempt cap is dropped', () async {
    final h = _harness();
    final n = h.container.read(offlineQueueProvider.notifier);
    await n.enqueue(
      _action(OfflineActionType.renameProject, attempts: kMaxOfflineAttempts - 1),
    );
    await n.processQueue(); // bumps to the cap → dropped
    expect(h.container.read(offlineQueueProvider).pendingCount, 0);
    expect(h.box.stored, isEmpty);
  });

  test('a second drain while one is in flight is a no-op', () async {
    final h = _harness();
    final n = h.container.read(offlineQueueProvider.notifier);
    await n.enqueue(_action(OfflineActionType.renameProject));
    final f1 = n.processQueue();
    final f2 = n.processQueue(); // guarded by `processing`
    await Future.wait([f1, f2]);
    // Single drain → attempts incremented exactly once.
    expect(h.container.read(offlineQueueProvider).pending.single.attempts, 1);
  });

  test('an action enqueued during a drain is preserved', () async {
    final h = _harness();
    final n = h.container.read(offlineQueueProvider.notifier);
    await n.enqueue(_action(OfflineActionType.renameProject, id: 'a'));
    final draining = n.processQueue(); // captures batch [a]
    await n.enqueue(_action(OfflineActionType.renameProject, id: 'b')); // newcomer
    await draining;
    final ids =
        h.container.read(offlineQueueProvider).pending.map((e) => e.id).toSet();
    expect(ids, {'a', 'b'}); // 'a' retained (failed), 'b' carried over
  });

  test('restores a persisted queue on build', () async {
    final h = _harness(seeded: [_action(OfflineActionType.renameProject)]);
    h.container.read(offlineQueueProvider); // build → _restore
    await _settle();
    expect(h.container.read(offlineQueueProvider).pendingCount, 1);
  });

  test('drains automatically when connectivity returns', () async {
    final h = _harness();
    final n = h.container.read(offlineQueueProvider.notifier);
    await n.enqueue(_action(OfflineActionType.unknown)); // removed on drain
    h.conn.add(AppConnectivityStatus.online);
    await _settle();
    expect(h.container.read(offlineQueueProvider).pendingCount, 0);
  });

  test('flapping connectivity does not duplicate or corrupt the queue', () async {
    final h = _harness();
    final n = h.container.read(offlineQueueProvider.notifier);
    await n.enqueue(_action(OfflineActionType.renameProject)); // retained
    h.conn
      ..add(AppConnectivityStatus.online)
      ..add(AppConnectivityStatus.offline)
      ..add(AppConnectivityStatus.online);
    await _settle();
    final state = h.container.read(offlineQueueProvider);
    expect(state.pendingCount, 1); // exactly one, never duplicated
    expect(state.processing, isFalse);
  });

  test('logout clears the queue in memory and on disk', () async {
    final h = _harness();
    final n = h.container.read(offlineQueueProvider.notifier);
    await n.enqueue(_action(OfflineActionType.renameProject));
    h.auth.emit(const AuthUnauthenticated());
    await _settle();
    expect(h.container.read(offlineQueueProvider).pendingCount, 0);
    expect(h.box.stored, isEmpty);
  });

  test('empty queue drain is a cheap no-op', () async {
    final h = _harness();
    final n = h.container.read(offlineQueueProvider.notifier);
    await n.processQueue();
    expect(h.container.read(offlineQueueProvider).pendingCount, 0);
  });
}
