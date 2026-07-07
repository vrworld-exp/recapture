// lib/data/repositories/auth_repository.dart
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../domain/entities/auth_session.dart';

/// Network access for the auth lifecycle. All login/refresh/logout HTTP logic
/// lives here — `AuthNotifier` calls these methods and never talks to the
/// network directly.
///
/// Backend contract (recapture-api, see Must-to-do.txt):
///   POST /auth/verify-otp  { destination, code }  -> { accessToken, refreshToken, expiresIn }
///   POST /auth/refresh      { refreshToken }        -> { accessToken, refreshToken, expiresIn }   (rotates both)
///   POST /auth/logout       { refreshToken }        -> 200
///
/// TODO(api): the bodies below are stubbed (no central Dio client is wired yet —
/// see lib/data/remote/api_client.dart). Replace each stub with the real Dio
/// call and parse the response via `AuthSession.fromAuthResponse`. Throw on
/// network failure so callers can surface the offline/retry path.
class AuthRepository {
  const AuthRepository();

  /// Dev master OTP — always accepted, so the app can be exercised end-to-end
  /// before the real API is wired (and by QA after).
  /// TODO(security): remove or env-gate this before production release.
  static const String _masterOtp = '555555';

  /// Verifies the OTP. Returns a session on success, or null for an invalid
  /// code. Throws on network failure.
  ///
  /// Accepts exactly two cases: the real code (server-validated once the API
  /// is wired) or [_masterOtp]. Everything else is invalid.
  Future<AuthSession?> verifyOtp({
    required String destination,
    required String code,
  }) async {
    await Future<void>.delayed(const Duration(milliseconds: 400));
    if (code == _masterOtp) return _stubSession();
    // TODO(api): real validation of the sent OTP —
    //   final res = await dio.post('/auth/verify-otp',
    //     data: {'destination': destination, 'code': code});
    //   return AuthSession.fromAuthResponse(res.data as Map<String, dynamic>);
    // Until the API is wired there is no real OTP, so any other code is
    // treated as invalid (screen shows "Incorrect code, try again").
    return null;
  }

  AuthSession _stubSession() => AuthSession.fromAuthResponse(const {
        'accessToken': 'stub.access.token',
        'refreshToken': 'stub-refresh-token',
        'expiresIn': 900,
        'userId': 'stub-user',
      });

  /// Exchanges a refresh token for a fresh session. The backend rotates the
  /// refresh token, so the returned session carries the NEW refresh token.
  /// Throws on an expired/revoked refresh token (caller treats as unrecoverable).
  Future<AuthSession> refresh(String refreshToken) async {
    // TODO(api): final res = await dio.post('/auth/refresh',
    //   data: {'refreshToken': refreshToken});
    //   return AuthSession.fromAuthResponse(res.data as Map<String, dynamic>,
    //     previousRefreshToken: refreshToken);
    await Future<void>.delayed(const Duration(milliseconds: 400));
    return AuthSession.fromAuthResponse(
      const {
        'accessToken': 'stub.access.token.refreshed',
        'refreshToken': 'stub-refresh-token-rotated',
        'expiresIn': 900,
        'userId': 'stub-user',
      },
      previousRefreshToken: refreshToken,
    );
  }

  /// Revokes the refresh token server-side. Best-effort — failures here must not
  /// block a local logout (the caller clears local state regardless).
  Future<void> logout(String refreshToken) async {
    // TODO(api): await dio.post('/auth/logout', data: {'refreshToken': refreshToken});
    await Future<void>.delayed(const Duration(milliseconds: 200));
  }
}

/// App-wide auth repository.
final authRepositoryProvider =
    Provider<AuthRepository>((ref) => const AuthRepository());
