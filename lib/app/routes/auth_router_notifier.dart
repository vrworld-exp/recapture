// lib/app/routes/auth_router_notifier.dart
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../data/local/session_store.dart';

/// Thin [Listenable] over the existing auth source ([SessionStore]) used to
/// drive GoRouter's `refreshListenable`. It caches a synchronous
/// [isAuthenticated] flag (the router's `redirect` runs synchronously and Hive
/// reads are async) and notifies the router to re-evaluate guards whenever the
/// session changes.
///
/// This does NOT own auth/session logic — the token lives in [SessionStore] and
/// the launch decision (including clearing expired tokens) is made by
/// `AppBootstrapService` on the splash. This class only mirrors that state for
/// the router.
class AuthRouterNotifier extends ChangeNotifier {
  AuthRouterNotifier({SessionStore store = const SessionStore()})
      : _store = store {
    _load();
  }

  final SessionStore _store;

  bool _isAuthenticated = false;

  /// Synchronous auth flag read by the router's `redirect`. Defaults to false
  /// (the safe, locked-out default) until the initial token read resolves or
  /// the splash sets the bootstrap-accurate value via [setAuthenticated].
  bool get isAuthenticated => _isAuthenticated;

  /// Best-effort initial read of token presence. The splash's bootstrap is the
  /// authority on the launch state (it also clears expired tokens) and calls
  /// [setAuthenticated] explicitly, which overrides this.
  Future<void> _load() async {
    try {
      final token = await _store.readToken();
      setAuthenticated(token != null);
    } catch (_) {
      setAuthenticated(false);
    }
  }

  /// Sets the cached auth state and, when it changes, notifies the router to
  /// re-run its guards. Idempotent — a no-op when the value is unchanged.
  void setAuthenticated(bool value) {
    if (_isAuthenticated == value) return;
    _isAuthenticated = value;
    notifyListeners();
  }

  /// Marks the session authenticated after a successful login / OTP verify.
  ///
  /// TODO(auth): when the real auth service lands, persist the returned token
  /// via [SessionStore] first, then call this.
  void signIn() => setAuthenticated(true);

  /// Clears the stored session and flips state so the guard redirects to login.
  Future<void> signOut() async {
    await _store.clearToken();
    setAuthenticated(false);
  }
}

/// App-wide singleton notifier. Constructed once and disposed with the scope.
final authRouterNotifierProvider = Provider<AuthRouterNotifier>((ref) {
  final notifier = AuthRouterNotifier();
  ref.onDispose(notifier.dispose);
  return notifier;
});
