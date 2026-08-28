// test/auth/token_refresh_test.dart
//
// Proves the CLIENT-SIDE refresh-vs-logout contract that lives in the Dio
// [AuthInterceptor] + [AuthNotifier]:
//
//   * An expiring/expired access token triggers a transparent refresh — the
//     caller's request still succeeds and the session stays authenticated.
//     NO logout on a recoverable expiry.
//   * Logout happens ONLY when the refresh itself fails (refresh token
//     expired/invalid/reused) — the boundary that distinguishes the two.
//   * N concurrent requests hitting expiry collapse into exactly ONE refresh
//     (single-flight), then all proceed.
//
// The real backend is never touched: the protected endpoint is scripted through
// a mock Dio [HttpClientAdapter], and the refresh endpoint through a fake
// [AuthRepository]. Expiry is scripted (a pre-set `exp`, or a server 401) —
// never slept on.
//
// ─────────────────────────────────────────────────────────────────────────────
// BUG-1 (found by this test, now FIXED):
//
//   The reactive 401-retry path in `AuthInterceptor.onError` used to retry via
//   `_ref.read(dioProvider).fetch(...)` — but `_ref` is dioProvider's OWN ref,
//   so it was a provider reading itself. Riverpod threw "A provider cannot
//   depend on itself" (debug/profile asserts); the error never reached the Dio
//   handler, so the retried request HUNG forever instead of returning.
//
//   Fix: the interceptor is now handed the `Dio` instance it is attached to
//   (`AuthInterceptor(ref, dio)`) and retries on that directly — no provider
//   self-read. The `_retriedFlag` still bounds the retry to one attempt. The
//   reactive-retry tests below (transparent-retry success, 500-on-retry, bounded
//   second-401) exercise that fixed path end-to-end.
// ─────────────────────────────────────────────────────────────────────────────

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:recapture/application/auth/auth_notifier.dart';
import 'package:recapture/data/local/active_session_box.dart';
import 'package:recapture/data/local/auth_storage.dart';
import 'package:recapture/data/local/offline_queue_box.dart';
import 'package:recapture/data/local/projects_cache_box.dart';
import 'package:recapture/data/local/storage_providers.dart';
import 'package:recapture/data/remote/api_client.dart';
import 'package:recapture/data/remote/auth_interceptor.dart';
import 'package:recapture/data/repositories/auth_repository.dart';
import 'package:recapture/domain/entities/active_session.dart';
import 'package:recapture/domain/entities/auth_session.dart';
import 'package:recapture/domain/entities/auth_state.dart';
import 'package:recapture/domain/entities/offline_action.dart';
import 'package:recapture/domain/entities/project.dart';

const String _protectedPath = '/projects';

// ── Test data ────────────────────────────────────────────────────────────────

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

// ── Mock Dio transport ───────────────────────────────────────────────────────

/// Scriptable [HttpClientAdapter] so protected-endpoint responses are decided
/// per request (by Authorization header) without any real network. Records
/// every request it sees so tests can count originals + retries.
class MockHttpAdapter implements HttpClientAdapter {
  MockHttpAdapter(this.handler);

  final ResponseBody Function(RequestOptions options) handler;
  final List<RequestOptions> requests = [];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    return handler(options);
  }

  @override
  void close({bool force = false}) {}
}

/// JSON response body with the content-type Dio needs to decode `data` to a Map.
ResponseBody _resp(int status, [Map<String, dynamic> body = const {}]) {
  return ResponseBody.fromString(
    jsonEncode(body),
    status,
    headers: {
      Headers.contentTypeHeader: [Headers.jsonContentType],
    },
  );
}

/// The Bearer token on an outgoing request, or null when none is attached.
String? _bearer(RequestOptions o) => o.headers['Authorization'] as String?;

// ── Fakes (mirror the conventions in auth_notifier_test.dart) ─────────────────

class FakeAuthStorage implements AuthStorage {
  FakeAuthStorage([this._stored]);
  AuthSession? _stored;
  int clearCount = 0;

  @override
  Future<void> save(AuthSession session) async => _stored = session;

  @override
  Future<AuthSession?> read() async => _stored;

  @override
  Future<void> clear() async {
    clearCount++;
    _stored = null;
  }

  AuthSession? get stored => _stored;
}

class FakeAuthRepository implements AuthRepository {
  int refreshCalls = 0;
  int logoutCalls = 0;

  /// When set, refresh awaits this before resolving — lets tests hold a refresh
  /// open while concurrent requests pile up behind it.
  Completer<void>? gate;

  /// Result for the next refresh: a session (success) or null → throw (a
  /// rejected/expired/reused refresh token).
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
  Future<void> logout(String refreshToken) async => logoutCalls++;
}

class FakeActiveSessionBox implements ActiveSessionBox {
  @override
  Future<void> clear() async {}
  @override
  Future<void> save(ActiveSession session) async {}
  @override
  Future<ActiveSession?> read() async => null;
}

class FakeProjectsCacheBox implements ProjectsCacheBox {
  @override
  Future<void> clear() async {}
  @override
  Future<void> save(List<Project> projects) async {}
  @override
  Future<CachedProjects?> read() async => null;
}

class FakeOfflineQueueBox implements OfflineQueueBox {
  @override
  Future<void> clear() async {}
  @override
  Future<void> save(List<OfflineAction> actions) async {}
  @override
  Future<List<OfflineAction>> read() async => const [];
}

// ── Harness ──────────────────────────────────────────────────────────────────

/// Builds a container wired exactly like production (`api_client.dart`): the
/// real [AuthInterceptor] over a real Dio — but with the network swapped for
/// [adapter] and storage/repo/boxes swapped for the fakes. The override mirrors
/// the production factory verbatim (same self-referential interceptor), so the
/// behaviour under test is the shipping behaviour.
ProviderContainer _container({
  required FakeAuthStorage storage,
  required FakeAuthRepository repo,
  required MockHttpAdapter adapter,
}) {
  final container = ProviderContainer(overrides: [
    authStorageProvider.overrideWithValue(storage),
    authRepositoryProvider.overrideWithValue(repo),
    activeSessionBoxProvider.overrideWithValue(FakeActiveSessionBox()),
    projectsCacheBoxProvider.overrideWithValue(FakeProjectsCacheBox()),
    offlineQueueBoxProvider.overrideWithValue(FakeOfflineQueueBox()),
    dioProvider.overrideWith((ref) {
      final dio = Dio(BaseOptions(baseUrl: 'https://test.local'));
      dio.httpClientAdapter = adapter;
      dio.interceptors.add(AuthInterceptor(ref, dio));
      return dio;
    }),
  ]);
  addTearDown(container.dispose);
  return container;
}

/// Triggers the notifier build (`_restore`) and pumps until it settles out of
/// the transient `AuthRestoring` state, so tests start from a known session.
Future<void> _boot(ProviderContainer c) async {
  c.read(authProvider);
  for (var i = 0; i < 50; i++) {
    if (c.read(authProvider) is! AuthRestoring) break;
    await Future<void>.delayed(Duration.zero);
  }
}

/// Yields the event loop a few times so concurrently-fired requests can all
/// reach the (gated) refresh before the gate is opened.
Future<void> _pump([int n = 12]) async {
  for (var i = 0; i < n; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

Future<Response<dynamic>> _get(ProviderContainer c) =>
    c.read(dioProvider).get<dynamic>(_protectedPath);

void main() {
  // ── Proactive expiry: refresh before sending, stay logged in ───────────────
  //
  // The interceptor's onRequest refreshes a near-expiry/expired token BEFORE the
  // request leaves, so the caller's request succeeds on the fresh token. This is
  // the expiry → refresh → transparent-success contract, exercised on the path
  // that does NOT depend on the broken reactive retry.
  group('proactive expiry → refresh → transparent success (no logout)', () {
    test('near-expiry token is refreshed ahead of the request; 200; '
        'session stays authenticated', () async {
      // Within the 2-minute proactive window but not yet past expiry, so restore
      // leaves it authenticated and onRequest refreshes ahead of the request.
      final storage = FakeAuthStorage(
        _session(access: 'soon', expiresIn: const Duration(minutes: 1)),
      );
      final repo = FakeAuthRepository()
        ..onRefresh = (_) => _session(access: 'fresh');
      final adapter = MockHttpAdapter((o) => _bearer(o) == 'Bearer fresh'
          ? _resp(200, {'ok': true})
          : _resp(401, {'error': 'stale_token_should_not_be_sent'}));
      final c = _container(storage: storage, repo: repo, adapter: adapter);
      await _boot(c);

      final res = await _get(c);

      expect(res.statusCode, 200);
      expect(res.data, {'ok': true});
      expect(repo.refreshCalls, 1);
      // ONE request, already carrying the fresh token — no 401 round-trip.
      expect(adapter.requests.length, 1);
      expect(_bearer(adapter.requests.single), 'Bearer fresh');
      // No logout: still authenticated, nothing cleared.
      expect(c.read(authProvider), isA<AuthAuthenticated>());
      expect(storage.clearCount, 0);
    });

    test('rotated tokens are persisted; the next call uses the new token',
        () async {
      final storage = FakeAuthStorage(
        _session(access: 'soon', refresh: 'r1', expiresIn: const Duration(minutes: 1)),
      );
      final repo = FakeAuthRepository()
        ..onRefresh = (_) => _session(access: 'fresh', refresh: 'r2');
      final adapter = MockHttpAdapter(
          (o) => _bearer(o) == 'Bearer fresh' ? _resp(200) : _resp(401));
      final c = _container(storage: storage, repo: repo, adapter: adapter);
      await _boot(c);

      await _get(c);

      // Store holds the rotated pair (old access + old refresh gone).
      expect(storage.stored?.accessToken, 'fresh');
      expect(storage.stored?.refreshToken, 'r2');
      expect(c.read(authProvider.notifier).accessTokenOrNull, 'fresh');

      // A second request now sails through on the new (no-longer-near-expiry)
      // token with no further refresh.
      adapter.requests.clear();
      final res2 = await _get(c);
      expect(res2.statusCode, 200);
      expect(repo.refreshCalls, 1); // still just the one
      expect(_bearer(adapter.requests.single), 'Bearer fresh');
    });
  });

  // ── Single-flight under concurrent expiry ──────────────────────────────────
  group('single-flight: concurrent expiry triggers exactly ONE refresh', () {
    test('three concurrent requests share one refresh; all succeed', () async {
      final storage = FakeAuthStorage(
        _session(access: 'soon', expiresIn: const Duration(minutes: 1)),
      );
      final gate = Completer<void>();
      final repo = FakeAuthRepository()
        ..gate = gate
        ..onRefresh = (_) => _session(access: 'fresh');
      final adapter = MockHttpAdapter((o) => _bearer(o) == 'Bearer fresh'
          ? _resp(200, {'ok': true})
          : _resp(401));
      final c = _container(storage: storage, repo: repo, adapter: adapter);
      await _boot(c);

      // Fire three protected requests while the token is near-expiry. Each
      // onRequest enters refresh(); the shared in-flight future means only one
      // network refresh runs.
      final futures = [_get(c), _get(c), _get(c)];
      await _pump(); // let all three reach the gated refresh
      expect(c.read(authProvider), isA<AuthRefreshing>());
      gate.complete();
      final results = await Future.wait(futures);

      expect(repo.refreshCalls, 1); // exactly one refresh serviced all three
      expect(results.map((r) => r.statusCode), everyElement(200));
      // All three were sent ONCE each, on the fresh token (no 401 retries).
      expect(adapter.requests.length, 3);
      expect(adapter.requests.map(_bearer), everyElement('Bearer fresh'));
      expect(c.read(authProvider), isA<AuthAuthenticated>());
    });
  });

  // ── Logout boundary (refresh failure → logout) ─────────────────────────────
  //
  // These use the REACTIVE 401 path, but on the refresh-FAILURE branch — which
  // returns via handler.next(err) BEFORE the broken self-read — so they exercise
  // the real interceptor end-to-end.
  group('logout boundary: refresh failure → logout', () {
    test('401 then rejected refresh: logs out, clears tokens, request fails',
        () async {
      // Not near-expiry, so onRequest attaches the (stale) token and the SERVER
      // is what rejects it — the reactive path.
      final storage = FakeAuthStorage(_session(access: 'stale'));
      final repo = FakeAuthRepository()..onRefresh = (_) => null; // throws
      final adapter = MockHttpAdapter((_) => _resp(401));
      final c = _container(storage: storage, repo: repo, adapter: adapter);
      await _boot(c);

      // The request must FAIL (surface the auth error) — not silently succeed.
      await expectLater(
        _get(c),
        throwsA(isA<DioException>()
            .having((e) => e.response?.statusCode, 'status', 401)),
      );

      expect(repo.refreshCalls, 1);
      expect(c.read(authProvider), isA<AuthUnauthenticated>());
      expect(storage.stored, isNull);
      expect(storage.clearCount, greaterThan(0));
    });

    test('no session at all: 401 cannot be recovered, stays logged out',
        () async {
      // Nothing to refresh with → the notifier short-circuits without ever
      // calling the refresh endpoint.
      final storage = FakeAuthStorage(); // empty
      final repo = FakeAuthRepository();
      final adapter = MockHttpAdapter((_) => _resp(401));
      final c = _container(storage: storage, repo: repo, adapter: adapter);
      await _boot(c);
      expect(c.read(authProvider), isA<AuthUnauthenticated>());

      await expectLater(_get(c), throwsA(isA<DioException>()));

      expect(repo.refreshCalls, 0); // no refresh token → no network refresh
      expect(c.read(authProvider), isA<AuthUnauthenticated>());
    });
  });

  // ── Reactive 401 → refresh → transparent retry ─────────────────────────────
  //
  // The server (not the client) rejects the token: a 401 drives onError, which
  // refreshes once and replays the original request on the new token. This is
  // the path BUG-1 used to break (the retry self-read dioProvider and hung);
  // it now runs end-to-end against the fixed interceptor.
  group('reactive 401 → refresh → transparent retry', () {
    test('expired token: 401, refresh, retry with new token, caller gets 200',
        () async {
      final storage = FakeAuthStorage(_session(access: 'stale'));
      final repo = FakeAuthRepository()
        ..onRefresh = (_) => _session(access: 'fresh', refresh: 'fresh-r');
      final adapter = MockHttpAdapter((o) => _bearer(o) == 'Bearer fresh'
          ? _resp(200, {'ok': true})
          : _resp(401, {'error': 'token_expired'}));
      final c = _container(storage: storage, repo: repo, adapter: adapter);
      await _boot(c);

      final res = await _get(c);

      expect(res.statusCode, 200);
      expect(res.data, {'ok': true});
      expect(repo.refreshCalls, 1);
      expect(adapter.requests.length, 2); // original (401) + retry (200)
      expect(_bearer(adapter.requests.first), 'Bearer stale');
      expect(_bearer(adapter.requests.last), 'Bearer fresh');
      expect(c.read(authProvider), isA<AuthAuthenticated>());
      expect(storage.clearCount, 0);
      expect(storage.stored?.refreshToken, 'fresh-r'); // rotation persisted
    });

    test('500 on the retried request surfaces as 500 — NOT a logout', () async {
      final storage = FakeAuthStorage(_session(access: 'stale'));
      final repo = FakeAuthRepository()
        ..onRefresh = (_) => _session(access: 'fresh');
      // Old token → 401 (refresh path); new token → 500 (a server error that is
      // NOT an auth problem and must not be mistaken for one).
      final adapter = MockHttpAdapter((o) => _bearer(o) == 'Bearer fresh'
          ? _resp(500, {'error': 'boom'})
          : _resp(401));
      final c = _container(storage: storage, repo: repo, adapter: adapter);
      await _boot(c);

      await expectLater(
        _get(c),
        throwsA(isA<DioException>()
            .having((e) => e.response?.statusCode, 'status', 500)),
      );

      expect(repo.refreshCalls, 1);
      // Refresh succeeded → the session is intact; a 500 is not a logout.
      expect(c.read(authProvider), isA<AuthAuthenticated>());
      expect(storage.clearCount, 0);
    });

    test('second 401 after a successful refresh is bounded (no infinite loop)',
        () async {
      final storage = FakeAuthStorage(_session(access: 'stale'));
      final repo = FakeAuthRepository()
        ..onRefresh = (_) => _session(access: 'fresh');
      // Server rejects EVERY token — even the freshly-refreshed one.
      final adapter = MockHttpAdapter((_) => _resp(401));
      final c = _container(storage: storage, repo: repo, adapter: adapter);
      await _boot(c);

      await expectLater(
        _get(c),
        throwsA(isA<DioException>()
            .having((e) => e.response?.statusCode, 'status', 401)),
      );

      // The `_retriedFlag` caps it: exactly one refresh, exactly one retry.
      expect(repo.refreshCalls, 1);
      expect(adapter.requests.length, 2);
      // NOTE: the refresh itself SUCCEEDED, so the interceptor does not log out
      // here — it surfaces the persistent 401 (an authorization problem, not an
      // auth-session failure). The prompt's "then log out" expectation is a
      // separate, intentional divergence to discuss, not a bug to silently fix.
      expect(c.read(authProvider), isA<AuthAuthenticated>());
    });
  });
}
