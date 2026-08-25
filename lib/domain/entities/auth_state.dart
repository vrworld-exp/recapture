// lib/domain/entities/auth_state.dart
import 'auth_session.dart';

/// The authentication lifecycle as a sealed union. `AuthNotifier` is the single
/// source of truth that emits these; UI and the router read derived state
/// ([isAuthenticated]) and never reconstruct this logic.
sealed class AuthState {
  const AuthState();

  /// The session backing the current state, when one exists (authenticated or
  /// mid-refresh). Null while restoring, unauthenticated, or errored.
  AuthSession? get sessionOrNull => switch (this) {
        AuthAuthenticated(:final session) => session,
        AuthRefreshing(:final previous) => previous,
        _ => null,
      };

  /// True for authenticated AND refreshing — a mid-refresh user is still
  /// considered logged in so the router never bounces them out during a refresh.
  bool get isAuthenticated => this is AuthAuthenticated || this is AuthRefreshing;
}

/// App start: secure storage is being read/validated. The safe, locked-out
/// default until restore resolves.
class AuthRestoring extends AuthState {
  const AuthRestoring();
}

/// No valid session — the router sends the user to the auth flow.
class AuthUnauthenticated extends AuthState {
  const AuthUnauthenticated();
}

/// A valid session is active.
class AuthAuthenticated extends AuthState {
  const AuthAuthenticated(this.session);
  final AuthSession session;
}

/// A refresh is in flight. The [previous] session's tokens stay usable and the
/// user remains authenticated for routing purposes.
class AuthRefreshing extends AuthState {
  const AuthRefreshing(this.previous);
  final AuthSession previous;
}

/// A surfaced, non-fatal auth error (e.g. transient restore failure). Treated
/// as not-authenticated. [message] never contains token values.
class AuthError extends AuthState {
  const AuthError(this.message);
  final String message;
}
