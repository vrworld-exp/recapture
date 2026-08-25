// lib/data/repositories/auth_repository.dart
//
// Network access for the auth lifecycle — REAL recapture-api calls:
//   POST /auth/send-otp   { channel, phone|email }        -> { expiresInSeconds, devCode? }
//   POST /auth/verify-otp { channel, phone|email, code }  -> { accessToken, refreshToken,
//                                                             accessTokenExpiresIn, ... }
//   POST /auth/refresh    { refreshToken }                -> same shape (rotates BOTH tokens)
//
// `AuthNotifier` calls these methods and never talks to the network directly.
//
// devCode: when the backend runs NODE_ENV=development, send-otp echoes the OTP
// back in the response (no SMS/email provider is wired yet). [OtpSendResult]
// carries it so the OTP screen can surface a DEV-ONLY autofill chip. Against a
// production backend the field is absent and the chip never renders.
//
// The Dio here is a BARE instance (lazy, own factory): these endpoints are
// unauthenticated, and refresh MUST NOT ride the app client's AuthInterceptor
// (a 401 inside refresh would recursively trigger refresh). Lazy so merely
// constructing the repository in widget tests never touches dotenv/AppConfig.
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../domain/entities/auth_session.dart';
import '../../utils/constants.dart';

/// Result of a successful send-otp dispatch.
class OtpSendResult {
  const OtpSendResult({this.devCode, this.expiresInSeconds});

  /// The OTP echoed by a DEV backend (NODE_ENV=development only). Null against
  /// production — the UI must treat null as "check your phone/email".
  final String? devCode;

  /// Server-reported OTP validity window, when provided.
  final int? expiresInSeconds;
}

/// The backend rate-limited the request (HTTP 429). Surfaced as its own type
/// so screens can show a "try again in Xs" message instead of the generic
/// offline/retry path.
class OtpRateLimitedException implements Exception {
  const OtpRateLimitedException({this.retryAfterSeconds});

  final int? retryAfterSeconds;

  @override
  String toString() =>
      'OtpRateLimitedException(retryAfter: ${retryAfterSeconds ?? '?'}s)';
}

class AuthRepository {
  AuthRepository({Dio Function()? dio}) : _dioFactory = dio;

  /// Lazy bare Dio — built on first network use (see header note).
  final Dio Function()? _dioFactory;
  Dio? _dio;

  Dio get _client => _dio ??= (_dioFactory?.call() ??
      Dio(BaseOptions(
        baseUrl: AppConfig.apiBaseUrl,
        connectTimeout: AppConfig.connectTimeout,
        receiveTimeout: AppConfig.receiveTimeout,
      )));

  /// Dev master OTP — accepted WITHOUT a network call, but never in a release
  /// build. It yields a LOCAL stub session whose tokens the real backend
  /// rejects (401) — fine for offline UI work; use the devCode login when
  /// exercising real backend flows (projects, uploads).
  static const String _masterOtp = '555555';

  /// Requests an OTP for [identifier] over [channel] ('sms' → E.164 phone,
  /// 'email' → address). Returns the dispatch result (carrying devCode against
  /// a dev backend). Throws [OtpRateLimitedException] on 429 and rethrows
  /// transport/server errors so callers surface the offline/retry path.
  Future<OtpSendResult> sendOtp({
    required String channel,
    required String identifier,
  }) async {
    try {
      final res = await _client.post<Map<String, dynamic>>(
        '/auth/send-otp',
        data: _identifierBody(channel, identifier),
      );
      final data = res.data ?? const {};
      final devCode = data['devCode'];
      final expires = data['expiresInSeconds'];
      return OtpSendResult(
        devCode: devCode is String && devCode.isNotEmpty ? devCode : null,
        expiresInSeconds: expires is num ? expires.toInt() : null,
      );
    } on DioException catch (e) {
      _throwIfRateLimited(e);
      rethrow;
    }
  }

  /// Verifies the OTP. Returns a session on success, null for an invalid/
  /// expired code (the backend's enumeration-safe 401), and throws on
  /// rate-limit/transport/server failures.
  Future<AuthSession?> verifyOtp({
    required String channel,
    required String identifier,
    required String code,
  }) async {
    // Offline dev bypass — before any network so it also works with no
    // backend reachable. Compiled out of release builds.
    if (!kReleaseMode && code == _masterOtp) return _stubSession();

    try {
      final res = await _client.post<Map<String, dynamic>>(
        '/auth/verify-otp',
        data: {..._identifierBody(channel, identifier), 'code': code},
      );
      return AuthSession.fromAuthResponse(res.data ?? const {});
    } on DioException catch (e) {
      if (e.response?.statusCode == 401) return null; // invalid/expired code
      _throwIfRateLimited(e);
      rethrow;
    }
  }

  /// Exchanges a refresh token for a fresh session. The backend rotates BOTH
  /// tokens. Throws on an expired/revoked/reused token (the generic 401) and
  /// on transport failure — the caller treats a throw as unrecoverable.
  Future<AuthSession> refresh(String refreshToken) async {
    final res = await _client.post<Map<String, dynamic>>(
      '/auth/refresh',
      data: {'refreshToken': refreshToken},
    );
    return AuthSession.fromAuthResponse(
      res.data ?? const {},
      previousRefreshToken: refreshToken,
    );
  }

  /// Server-side revoke. The backend has NO logout route yet (refresh-token
  /// reuse detection revokes families server-side); logout is the local clear
  /// in [AuthNotifier]. Kept async + best-effort so wiring a real route later
  /// changes only this body.
  Future<void> logout(String refreshToken) async {}

  AuthSession _stubSession() => AuthSession.fromAuthResponse(const {
        'accessToken': 'stub.access.token',
        'refreshToken': 'stub-refresh-token',
        'expiresIn': 900,
        'userId': 'stub-user',
      });

  static Map<String, Object?> _identifierBody(
      String channel, String identifier) {
    return channel == 'email'
        ? {'channel': 'email', 'email': identifier}
        : {'channel': 'sms', 'phone': identifier};
  }

  static void _throwIfRateLimited(DioException e) {
    if (e.response?.statusCode != 429) return;
    final body = e.response?.data;
    final retryAfter = body is Map ? body['retryAfter'] : null;
    throw OtpRateLimitedException(
      retryAfterSeconds: retryAfter is num ? retryAfter.toInt() : null,
    );
  }
}

/// App-wide auth repository.
final authRepositoryProvider =
    Provider<AuthRepository>((ref) => AuthRepository());
