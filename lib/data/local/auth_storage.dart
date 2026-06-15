// lib/data/local/auth_storage.dart
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../../domain/entities/auth_session.dart';

/// The only gateway to persisted auth tokens. Wraps [FlutterSecureStorage]
/// (OS Keychain / Keystore) so the notifier never touches the package directly.
///
/// Tokens are credentials: they live here and nowhere else. A corrupt or
/// undecodable blob is treated as "no session" — it is cleared and `null` is
/// returned, never thrown, so a bad blob can never crash app startup.
class AuthStorage {
  AuthStorage([FlutterSecureStorage? storage])
      : _storage = storage ??
            const FlutterSecureStorage(
              aOptions: AndroidOptions(encryptedSharedPreferences: true),
            );

  final FlutterSecureStorage _storage;

  static const String _key = 'recapture_auth_session';

  Future<void> save(AuthSession session) {
    return _storage.write(key: _key, value: jsonEncode(session.toJson()));
  }

  /// Reads and decodes the session. Returns null when absent; on corrupt data
  /// it clears the bad blob and returns null.
  Future<AuthSession?> read() async {
    final raw = await _storage.read(key: _key);
    if (raw == null || raw.isEmpty) return null;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map<String, dynamic>) {
        throw const FormatException('Stored session is not a JSON object');
      }
      return AuthSession.fromJson(decoded);
    } on FormatException {
      await clear();
      return null;
    }
  }

  Future<void> clear() => _storage.delete(key: _key);
}

/// App-wide secure auth storage.
final authStorageProvider = Provider<AuthStorage>((ref) => AuthStorage());
