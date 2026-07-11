// test/auth/auth_notifier_test.dart
import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:recapture/application/auth/auth_notifier.dart';
import 'package:recapture/data/local/active_session_box.dart';
import 'package:recapture/data/local/auth_storage.dart';
import 'package:recapture/data/local/offline_queue_box.dart';
import 'package:recapture/data/local/projects_cache_box.dart';
import 'package:recapture/data/local/storage_providers.dart';
import 'package:recapture/domain/entities/offline_action.dart';
import 'package:recapture/data/repositories/auth_repository.dart';
import 'package:recapture/domain/entities/active_session.dart';
import 'package:recapture/domain/entities/auth_session.dart';
import 'package:recapture/domain/entities/auth_state.dart';
import 'package:recapture/domain/entities/project.dart';

AuthSession _session({
  String access = 'access',
  String refresh = 'refresh',
  Duration expiresIn = const Duration(minutes: 15),
}) {
  return AuthSession(
    accessToken: access,
    refreshToken: refresh,
    accessTokenExpiry: DateTime.now().toUtc().add(expiresIn),
    userId: 'u',
  );
}

/// In-memory secure-storage double.
class FakeAuthStorage implements AuthStorage {
  FakeAuthStorage([this._stored]);
  AuthSession? _stored;
  bool failWrites = false;
  int clearCount = 0;

  @override
  Future<void> save(AuthSession session) async {
    if (failWrites) throw Exception('write failed');
    _stored = session;
  }

  @override
  Future<AuthSession?> read() async => _stored;

  @override
  Future<void> clear() async {
    clearCount++;
    _stored = null;
  }

  AuthSession? get stored => _stored;
}

/// Controllable auth repository double.
class FakeAuthRepository implements AuthRepository {
  int refreshCalls = 0;
  int logoutCalls = 0;

  /// When set, refresh awaits this before resolving — lets tests interleave.
  Completer<void>? gate;

  /// Result for the next refresh: a session (success) or null → throw.
  AuthSession? Function(String refreshToken)? onRefresh;

  @override
  Future<OtpSendResult> sendOtp({
    required String channel,
    required String identifier,
  }) async =>
      const OtpSendResult();

  @override
  Future<AuthSession?> verifyOtp({
    required String channel,
    required String identifier,
    required String code,
  }) async =>
      _session();

  @override
  Future<AuthSession> refresh(String refreshToken) async {
    refreshCalls++;
    if (gate != null) await gate!.future;
    final result = onRefresh?.call(refreshToken);
    if (result == null) throw Exception('refresh rejected');
    return result;
  }

  @override
  Future<void> logout(String refreshToken) async {
    logoutCalls++;
  }
}

/// No-op Hive box doubles so the notifier's teardown can clear them without
/// touching real Hive.
class FakeActiveSessionBox implements ActiveSessionBox {
  int clearCount = 0;
  @override
  Future<void> clear() async => clearCount++;
  @override
  Future<void> save(ActiveSession session) async {}
  @override
  Future<ActiveSession?> read() async => null;
}

class FakeProjectsCacheBox implements ProjectsCacheBox {
  int clearCount = 0;
  @override
  Future<void> clear() async => clearCount++;
  @override
  Future<void> save(List<Project> projects) async {}
  @override
  Future<CachedProjects?> read() async => null;
}

class FakeOfflineQueueBox implements OfflineQueueBox {
  int clearCount = 0;
  @override
  Future<void> clear() async => clearCount++;
  @override
  Future<void> save(List<OfflineAction> actions) async {}
  @override
  Future<List<OfflineAction>> read() async => const [];
}

ProviderContainer _makeContainer(
  FakeAuthStorage storage,
  FakeAuthRepository repo, {
  FakeActiveSessionBox? sessionBox,
  FakeProjectsCacheBox? cacheBox,
}) {
  final container = ProviderContainer(overrides: [
    authStorageProvider.overrideWithValue(storage),
    authRepositoryProvider.overrideWithValue(repo),
    activeSessionBoxProvider.overrideWithValue(sessionBox ?? FakeActiveSessionBox()),
    projectsCacheBoxProvider.overrideWithValue(cacheBox ?? FakeProjectsCacheBox()),
    offlineQueueBoxProvider.overrideWithValue(FakeOfflineQueueBox()),
  ]);
  addTearDown(container.dispose);
  return container;
}

/// Builds the notifier and waits until restore settles out of AuthRestoring.
Future<ProviderContainer> _booted(
  FakeAuthStorage storage,
  FakeAuthRepository repo,
) async {
  final container = _makeContainer(storage, repo);
  container.read(authProvider); // trigger build → _restore
  for (var i = 0; i < 50; i++) {
    if (container.read(authProvider) is! AuthRestoring) break;
    await Future<void>.delayed(Duration.zero);
  }
  return container;
}

void main() {
  group('restore', () {
    test('no stored session → unauthenticated', () async {
      final c = await _booted(FakeAuthStorage(), FakeAuthRepository());
      expect(c.read(authProvider), isA<AuthUnauthenticated>());
    });

    test('valid stored session → authenticated', () async {
      final c = await _booted(FakeAuthStorage(_session()), FakeAuthRepository());
      expect(c.read(authProvider), isA<AuthAuthenticated>());
    });

    test('expired access + valid refresh → refreshes to authenticated', () async {
      final storage =
          FakeAuthStorage(_session(expiresIn: const Duration(seconds: -1)));
      final repo = FakeAuthRepository()
        ..onRefresh = (_) => _session(access: 'new');
      final c = await _booted(storage, repo);
      expect(repo.refreshCalls, 1);
      final state = c.read(authProvider);
      expect(state, isA<AuthAuthenticated>());
      expect((state as AuthAuthenticated).session.accessToken, 'new');
    });

    test('expired access + rejected refresh → unauthenticated, cleared', () async {
      final storage =
          FakeAuthStorage(_session(expiresIn: const Duration(seconds: -1)));
      final repo = FakeAuthRepository()..onRefresh = (_) => null; // throws
      final c = await _booted(storage, repo);
      expect(c.read(authProvider), isA<AuthUnauthenticated>());
      expect(storage.stored, isNull);
    });
  });

  group('login / logout', () {
    test('login persists session and flips to authenticated', () async {
      final storage = FakeAuthStorage();
      final c = await _booted(storage, FakeAuthRepository());
      final session = _session(access: 'fresh');
      await c.read(authProvider.notifier).login(session);
      expect(c.read(authProvider), isA<AuthAuthenticated>());
      expect(storage.stored?.accessToken, 'fresh');
    });

    test('logout clears storage and flips to unauthenticated', () async {
      final storage = FakeAuthStorage(_session());
      final repo = FakeAuthRepository();
      final c = await _booted(storage, repo);
      await c.read(authProvider.notifier).logout();
      expect(c.read(authProvider), isA<AuthUnauthenticated>());
      expect(storage.stored, isNull);
      expect(repo.logoutCalls, 1);
    });

    test('logout clears the active_session and projects_cache boxes', () async {
      final sessionBox = FakeActiveSessionBox();
      final cacheBox = FakeProjectsCacheBox();
      final c = _makeContainer(
        FakeAuthStorage(_session()),
        FakeAuthRepository(),
        sessionBox: sessionBox,
        cacheBox: cacheBox,
      );
      c.read(authProvider); // build
      for (var i = 0; i < 50; i++) {
        if (c.read(authProvider) is! AuthRestoring) break;
        await Future<void>.delayed(Duration.zero);
      }
      await c.read(authProvider.notifier).logout();
      expect(sessionBox.clearCount, greaterThan(0));
      expect(cacheBox.clearCount, greaterThan(0));
    });
  });

  group('refresh', () {
    test('success rotates session and persists it', () async {
      final storage = FakeAuthStorage(_session());
      final repo = FakeAuthRepository()
        ..onRefresh = (_) => _session(access: 'rotated', refresh: 'r2');
      final c = await _booted(storage, repo);

      final ok = await c.read(authProvider.notifier).refresh();
      expect(ok, isTrue);
      expect((c.read(authProvider) as AuthAuthenticated).session.accessToken,
          'rotated');
      expect(storage.stored?.refreshToken, 'r2');
    });

    test('failure clears session and forces unauthenticated', () async {
      final storage = FakeAuthStorage(_session());
      final repo = FakeAuthRepository()..onRefresh = (_) => null; // throws
      final c = await _booted(storage, repo);

      final ok = await c.read(authProvider.notifier).refresh();
      expect(ok, isFalse);
      expect(c.read(authProvider), isA<AuthUnauthenticated>());
      expect(storage.stored, isNull);
    });

    test('storage write failure forces re-login (safer policy)', () async {
      final storage = FakeAuthStorage(_session())..failWrites = true;
      final repo = FakeAuthRepository()..onRefresh = (_) => _session();
      final c = await _booted(storage, repo);

      final ok = await c.read(authProvider.notifier).refresh();
      expect(ok, isFalse);
      expect(c.read(authProvider), isA<AuthUnauthenticated>());
    });

    test('concurrent callers share a single in-flight refresh (no storm)',
        () async {
      final storage = FakeAuthStorage(_session());
      final gate = Completer<void>();
      final repo = FakeAuthRepository()
        ..gate = gate
        ..onRefresh = (_) => _session(access: 'rotated');
      final c = await _booted(storage, repo);
      final notifier = c.read(authProvider.notifier);

      final futures = [notifier.refresh(), notifier.refresh(), notifier.refresh()];
      expect(c.read(authProvider), isA<AuthRefreshing>());
      gate.complete();
      final results = await Future.wait(futures);

      expect(results, everyElement(isTrue));
      expect(repo.refreshCalls, 1); // exactly one network refresh
    });

    test('logout during an in-flight refresh wins (no re-auth)', () async {
      final storage = FakeAuthStorage(_session());
      final gate = Completer<void>();
      final repo = FakeAuthRepository()
        ..gate = gate
        ..onRefresh = (_) => _session(access: 'rotated');
      final c = await _booted(storage, repo);
      final notifier = c.read(authProvider.notifier);

      final refreshFuture = notifier.refresh();
      await notifier.logout(); // happens mid-refresh
      gate.complete();
      final ok = await refreshFuture;

      expect(ok, isFalse);
      expect(c.read(authProvider), isA<AuthUnauthenticated>());
      expect(storage.stored, isNull); // rotated session must not be persisted
    });
  });

  group('derived accessors', () {
    test('AuthRefreshing counts as authenticated', () {
      const restoring = AuthRestoring();
      expect(restoring.isAuthenticated, isFalse);
      expect(AuthRefreshing(_session()).isAuthenticated, isTrue);
      expect(AuthAuthenticated(_session()).isAuthenticated, isTrue);
      expect(const AuthUnauthenticated().isAuthenticated, isFalse);
    });
  });
}
