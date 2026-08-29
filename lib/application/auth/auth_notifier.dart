// lib/application/auth/auth_notifier.dart
import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/local/auth_storage.dart';
import '../../data/local/storage_providers.dart';
import '../../data/repositories/auth_repository.dart';
import '../../domain/entities/auth_session.dart';
import '../../domain/entities/auth_state.dart';
import '../../utils/analytics.dart';
import '../../utils/platform_name.dart';

/// Owns the authentication lifecycle and is the single source of truth for
/// "is the user authenticated". Login, logout, refresh, and session restore all
/// flow through here; the router and UI read derived state only.
///
/// Invariants:
///   - Secure storage ([AuthStorage]) is the only token persistence.
///   - Exactly one refresh runs at a time (shared in-flight future).
///   - A logout always wins over an in-flight refresh (epoch guard).
///   - Tokens never appear in logs, analytics, or error messages.
class AuthNotifier extends Notifier<AuthState> {
  /// The single in-flight refresh, shared by all concurrent callers (e.g. a
  /// burst of 401s). Null when no refresh is running.
  Future<bool>? _inFlightRefresh;

  /// Bumped on every login/logout. A refresh captures the epoch at its start
  /// and discards its result if the epoch changed meanwhile — this is how a
  /// logout (or re-login) cancels an in-flight refresh's effect.
  int _epoch = 0;

  @override
  AuthState build() {
    // Kick off restore without blocking build; start locked-out.
    _restore();
    return const AuthRestoring();
  }

  // ── Public API ─────────────────────────────────────────────────────────────

  /// Derived flag used by the router guard. Authenticated AND refreshing both
  /// count as logged in (no mid-refresh bounce).
  bool get isAuthenticated => state.isAuthenticated;

  /// The current access token, or null when unauthenticated. Read by the API
  /// client to attach the Bearer header.
  String? get accessTokenOrNull => state.sessionOrNull?.accessToken;

  /// Persists [session] and flips to authenticated. Called from the OTP verify
  /// success path. Throws if secure storage write fails (safer policy: do not
  /// claim an unpersisted session).
  Future<void> login(AuthSession session) async {
    _epoch++;
    _inFlightRefresh = null; // any prior refresh is now irrelevant
    await ref.read(authStorageProvider).save(session);
    state = AuthAuthenticated(session);
    _log('login');
  }

  /// Clears the session locally (and best-effort server-side) and flips to
  /// unauthenticated. Wins over any in-flight refresh.
  Future<void> logout() async {
    _epoch++;
    _inFlightRefresh = null;
    final refreshToken = state.sessionOrNull?.refreshToken;
    state = const AuthUnauthenticated();
    await _safeClear();
    if (refreshToken != null) {
      // Best-effort server-side revoke; never block local logout on it.
      try {
        await ref.read(authRepositoryProvider).logout(refreshToken);
      } catch (_) {/* already logged out locally */}
    }
    _log('logout');
  }

  /// Refreshes the access token. Concurrent callers share a single in-flight
  /// refresh — the endpoint is hit at most once per burst. Returns true on
  /// success; on unrecoverable failure it clears the session and returns false.
  Future<bool> refresh() {
    return _inFlightRefresh ??=
        _doRefresh().whenComplete(() => _inFlightRefresh = null);
  }

  /// Returns a usable access token, refreshing first if the current one is
  /// expired or about to expire. Used by the API client before each request so
  /// proactive-refresh logic lives in one place, not scattered across the UI.
  Future<String?> ensureFreshToken({
    Duration window = const Duration(minutes: 2),
  }) async {
    final session = state.sessionOrNull;
    if (session == null) return null;
    if (session.isAccessTokenExpired || session.needsRefreshWithin(window)) {
      final ok = await refresh();
      if (ok) return state.sessionOrNull?.accessToken;
      // A TRANSIENT refresh failure retains the session (see _doRefresh). If
      // the token is only inside the proactive window — not hard-expired —
      // it is still valid: use it rather than failing the caller. The
      // server-side 401 (and the caller's forceRefresh recovery) remains the
      // backstop if it expires mid-flight.
      final retained = state.sessionOrNull;
      if (retained != null && !retained.isAccessTokenExpired) {
        return retained.accessToken;
      }
      return null;
    }
    return session.accessToken;
  }

  // ── Internals ──────────────────────────────────────────────────────────────

  Future<void> _restore() async {
    try {
      final session = await ref.read(authStorageProvider).read();
      if (session == null) {
        state = const AuthUnauthenticated();
        _log('session_restore_empty');
        return;
      }
      if (!session.isAccessTokenExpired) {
        state = AuthAuthenticated(session);
        _log('session_restored');
        return;
      }
      // Access token expired but a refresh token is on hand — try to recover.
      state = AuthRefreshing(session);
      await refresh(); // emits Authenticated or Unauthenticated + its own log
    } catch (_) {
      // Storage error (not a corrupt blob — that is handled inside the gateway).
      await _safeClear();
      state = const AuthUnauthenticated();
      _log('session_restore_empty');
    }
  }

  Future<bool> _doRefresh() async {
    final epoch = _epoch;
    final current = state.sessionOrNull;
    if (current == null) {
      state = const AuthUnauthenticated();
      return false;
    }
    if (state is! AuthRefreshing) state = AuthRefreshing(current);

    try {
      final newSession =
          await ref.read(authRepositoryProvider).refresh(current.refreshToken);

      // A logout/login landed while we were awaiting — discard this result.
      if (epoch != _epoch) return false;

      try {
        await ref.read(authStorageProvider).save(newSession);
      } catch (_) {
        // Persisted nothing → force re-login (safer than an in-memory-only
        // session that vanishes on restart).
        await _safeClear();
        if (epoch == _epoch) state = const AuthUnauthenticated();
        _log('refresh_failed');
        return false;
      }

      // Re-check after the async save: logout may have cleared storage; if so,
      // undo our write and stay logged out.
      if (epoch != _epoch) {
        await _safeClear();
        return false;
      }

      state = AuthAuthenticated(newSession);
      _log('refresh_success');
      return true;
    } on DioException catch (e) {
      final code = e.response?.statusCode;
      final rejected = code != null && code >= 400 && code < 500;
      if (!rejected) {
        // TRANSIENT failure (timeout, connection error, 5xx — e.g. a sleeping
        // backend waking up, or a dead spot on mobile data): the refresh
        // token was never judged, so the session is NOT torn down. Restore
        // the authenticated state and report failure; the next caller simply
        // retries the refresh.
        if (epoch == _epoch) state = AuthAuthenticated(current);
        _log('refresh_transient_failure');
        return false;
      }
      // The server REJECTED the token (401/403/…) — the session is gone.
      await _safeClear();
      if (epoch == _epoch) state = const AuthUnauthenticated();
      _log('refresh_failed');
      return false;
    } catch (_) {
      // Non-transport failure (malformed response, storage error) — treat as
      // unrecoverable rather than looping on a broken session.
      await _safeClear();
      if (epoch == _epoch) state = const AuthUnauthenticated();
      _log('refresh_failed');
      return false;
    }
  }

  /// Clears all user-scoped persistence on a session teardown (logout or any
  /// involuntary-logout path). Tokens live in secure storage; the Hive boxes
  /// (active_session, projects_cache, offline_queue) are cleared here too so no
  /// user data survives logout — the offline queue is wiped on disk here so a
  /// previous user's deferred actions are never replayed, even if the queue
  /// notifier was never instantiated this session. Best-effort — a failure to
  /// clear one store never blocks the others or the logout itself.
  Future<void> _safeClear() async {
    try {
      await ref.read(authStorageProvider).clear();
    } catch (_) {/* nothing more we can do */}
    try {
      await ref.read(activeSessionBoxProvider).clear();
    } catch (_) {/* best-effort */}
    try {
      await ref.read(projectsCacheBoxProvider).clear();
    } catch (_) {/* best-effort */}
    try {
      await ref.read(offlineQueueBoxProvider).clear();
    } catch (_) {/* best-effort */}
  }

  void _log(String event) {
    // Analytics carries only the event name + device type — never tokens or ids.
    Analytics.logEvent('auth_session_event', {
      'event': event,
      'device_type': appPlatformName,
    });
  }
}

/// App-wide auth state. The single source of truth for authentication.
final authProvider =
    NotifierProvider<AuthNotifier, AuthState>(AuthNotifier.new);
