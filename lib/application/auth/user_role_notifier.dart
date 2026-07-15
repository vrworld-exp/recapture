// lib/application/auth/user_role_notifier.dart
import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/local/user_role_store.dart';
import '../../data/repositories/account_repository.dart';
import '../../domain/entities/auth_state.dart';
import '../../domain/entities/user_role.dart';
import 'auth_notifier.dart';

/// Gateway to the persisted user-role flag (active_session box).
final userRoleStoreProvider = Provider<UserRoleStore>((ref) => UserRoleStore());

/// Owns the signed-in user's access role — the client-side mirror of the
/// backend's `User.role`, learned from `GET /auth/me`.
///
/// Lifecycle:
///   - On auth becoming established (session restore at app start, or OTP
///     verify) → fetch the fresh role; until it lands, the persisted role from
///     the last session paints the staff UI without a network wait.
///   - On ANY fetch failure → [UserRole.user] (fail-closed: the staff UI
///     never appears on error; the server still enforces every /admin call).
///   - On logout → reset to [UserRole.user] and clear the persisted flag.
///
/// A role changed via the backend's set-user-role script is picked up on the
/// next app start / auth refresh — accepted v1 lag.
class UserRoleNotifier extends Notifier<UserRole> {
  /// Guards stale async completions: bumped on every auth transition so a
  /// slow fetch/restore from a previous session can never overwrite the
  /// current one (same epoch idiom as AuthNotifier).
  int _epoch = 0;

  /// True once a FRESH /auth/me answer (success or fail-closed) landed for the
  /// current epoch — from then on the persisted disk value must not apply
  /// (it could resurrect a just-revoked staff role).
  bool _freshRoleLanded = false;

  @override
  UserRole build() {
    ref.listen<AuthState>(authProvider, (prev, next) {
      final wasAuthed = prev is AuthAuthenticated || prev is AuthRefreshing;
      if (next is AuthUnauthenticated) {
        _epoch++;
        _freshRoleLanded = false;
        state = UserRole.user;
        unawaited(_clearPersisted());
      } else if (next is AuthAuthenticated && !wasAuthed) {
        // Auth established (restore or OTP verify) — not a routine
        // refresh-rotation, which cycles Authenticated→Refreshing→Authenticated.
        _epoch++;
        _freshRoleLanded = false;
        unawaited(_syncRole(_epoch));
      }
    });

    // Already authenticated when this notifier first builds (e.g. the staff
    // tab is first watched long after login) → sync now; otherwise start from
    // the persisted role so a warm start paints without a network wait.
    // Deferred to a microtask so no storage/network code runs synchronously
    // inside provider mount (this can execute mid-widget-build).
    final epoch = _epoch;
    unawaited(Future<void>.microtask(() async {
      try {
        // An auth transition since build already triggered its own sync via
        // the listener above — never double-fetch.
        if (epoch != _epoch) return;
        if (ref.read(authProvider).isAuthenticated) {
          await _syncRole(epoch);
        }
        await _restorePersisted(epoch);
      } catch (_) {/* disposed mid-flight, or storage failure — stay USER */}
    }));
    return UserRole.user;
  }

  Future<void> _restorePersisted(int epoch) async {
    try {
      final persisted = await ref.read(userRoleStoreProvider).read();
      // The disk value is only a warm-start hint: never apply it once a fresh
      // answer landed (it could resurrect a just-revoked staff role).
      if (persisted != null && epoch == _epoch && !_freshRoleLanded) {
        state = persisted;
      }
    } catch (_) {/* fail-closed: stay USER */}
  }

  Future<void> _syncRole(int epoch) async {
    try {
      final role = await ref.read(accountRepositoryProvider).fetchRole();
      if (epoch != _epoch) return; // auth changed mid-fetch — discard
      _freshRoleLanded = true;
      state = role;
      try {
        await ref.read(userRoleStoreProvider).save(role);
      } catch (_) {/* persistence is a warm-start nicety only */}
    } catch (_) {
      // Fail-closed: any /auth/me failure means no staff UI this session.
      if (epoch == _epoch) {
        _freshRoleLanded = true;
        state = UserRole.user;
      }
    }
  }

  Future<void> _clearPersisted() async {
    try {
      await ref.read(userRoleStoreProvider).clear();
    } catch (_) {/* best-effort */}
  }
}

/// App-wide user role. Defaults to [UserRole.user] until /auth/me answers.
final userRoleProvider =
    NotifierProvider<UserRoleNotifier, UserRole>(UserRoleNotifier.new);

/// True when the signed-in user may see staff-only surfaces (Live projects).
final isStaffProvider = Provider<bool>((ref) => ref.watch(userRoleProvider).isStaff);

/// True only for ADMIN — gates destructive staff actions (photo soft-delete),
/// mirroring the backend's ADMIN-only delete route. Fails closed.
final isAdminProvider = Provider<bool>((ref) => ref.watch(userRoleProvider).isAdmin);
