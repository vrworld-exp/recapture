// lib/data/local/session_store.dart
import 'package:hive/hive.dart';
import '../../utils/constants.dart';

/// Local persistence for the auth session token, backed by the Hive
/// [AppConfig.boxSession] box (Hive is initialised in main()).
///
/// This is the single source of truth for the token storage key/format.
/// Other layers read and clear the token through this class only.
class SessionStore {
  const SessionStore();

  /// Key under which the JWT auth token is stored in the session box.
  static const String tokenKey = 'authToken';

  Future<Box<dynamic>> _openBox() async {
    if (Hive.isBoxOpen(AppConfig.boxSession)) {
      return Hive.box<dynamic>(AppConfig.boxSession);
    }
    return Hive.openBox<dynamic>(AppConfig.boxSession);
  }

  /// Returns the stored token, or null when none is present.
  Future<String?> readToken() async {
    final box = await _openBox();
    final value = box.get(tokenKey);
    return value is String && value.isNotEmpty ? value : null;
  }

  /// Removes the stored token. Safe to call when no token is present.
  Future<void> clearToken() async {
    final box = await _openBox();
    await box.delete(tokenKey);
  }
}
