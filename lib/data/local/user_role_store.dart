// lib/data/local/user_role_store.dart
import 'package:hive/hive.dart';

import '../../domain/entities/user_role.dart';
import 'box_names.dart';
import 'hive_init.dart';

/// Persists the signed-in user's access role in the (unencrypted)
/// `active_session` box, under its own key. The role is NOT a secret — it is
/// server-enforced on every /admin request — so it deliberately lives in Hive,
/// not secure storage; persisting it only lets the staff UI appear without
/// waiting for the /auth/me round-trip on a warm start. Cleared with the rest
/// of the box on logout (AuthNotifier._safeClear → activeSessionBox.clear
/// clears the session key; this store's key is cleared by [clear], wired into
/// the role notifier's unauthenticated reset).
class UserRoleStore {
  UserRoleStore();

  static const String _key = 'user_role';

  Box<String>? _box;
  Future<Box<String>>? _opening;

  Future<Box<String>> _open() {
    final existing = _box;
    if (existing != null && existing.isOpen) return Future.value(existing);
    return _opening ??= openStringBoxSafely(BoxNames.activeSession).then((box) {
      _box = box;
      _opening = null;
      return box;
    });
  }

  /// Best-effort: a storage failure is swallowed — persistence is only a
  /// warm-start nicety and must never break the role flow (or a test host
  /// without Hive initialized).
  Future<void> save(UserRole role) async {
    try {
      await (await _open()).put(_key, role.apiValue);
    } catch (_) {/* best-effort */}
  }

  /// The persisted role, or null when absent/unreadable. Unrecognized values
  /// read as [UserRole.user] (fail-closed). Never throws.
  Future<UserRole?> read() async {
    try {
      final raw = (await _open()).get(_key);
      if (raw == null || raw.isEmpty) return null;
      return UserRole.fromApiValue(raw);
    } catch (_) {
      return null;
    }
  }

  Future<void> clear() async {
    try {
      await (await _open()).delete(_key);
    } catch (_) {/* best-effort */}
  }
}
