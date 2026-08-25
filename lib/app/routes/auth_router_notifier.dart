// lib/app/routes/auth_router_notifier.dart
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../application/auth/auth_notifier.dart';
import '../../domain/entities/auth_state.dart';

/// Thin [Listenable] bridge that drives GoRouter's `refreshListenable` from the
/// auth source of truth ([authProvider]). The router's `redirect` runs
/// synchronously, so this caches a synchronous [isAuthenticated] flag and
/// notifies the router to re-evaluate guards whenever auth state changes.
///
/// This owns no auth logic — [AuthNotifier] does. The router contract is
/// unchanged from before: a synchronous [isAuthenticated] plus change
/// notifications; only the data source moved to [AuthNotifier].
class AuthRouterNotifier extends ChangeNotifier {
  AuthRouterNotifier({required bool initialAuthenticated})
      : _isAuthenticated = initialAuthenticated;

  bool _isAuthenticated;

  /// Synchronous auth flag read by the router's `redirect`. Mirrors
  /// [AuthState.isAuthenticated] (authenticated + refreshing both count).
  bool get isAuthenticated => _isAuthenticated;

  /// Updates the cached flag and notifies the router only on an actual change.
  void setAuthenticated(bool value) {
    if (_isAuthenticated == value) return;
    _isAuthenticated = value;
    notifyListeners();
  }
}

/// App-wide router notifier, bridged to [authProvider]. Constructed once; it
/// listens to auth state and refreshes the router's guards on every change.
final authRouterNotifierProvider = Provider<AuthRouterNotifier>((ref) {
  final notifier = AuthRouterNotifier(
    initialAuthenticated: ref.read(authProvider).isAuthenticated,
  );
  ref.listen<AuthState>(authProvider, (_, next) {
    notifier.setAuthenticated(next.isAuthenticated);
  });
  ref.onDispose(notifier.dispose);
  return notifier;
});
