// lib/domain/entities/auth_session.dart
import 'dart:convert';

/// Immutable auth session: the access + refresh token pair, the access token's
/// absolute expiry (always UTC), and the opaque user id.
///
/// This is the only token-bearing model in the app. It is persisted via
/// `AuthStorage` (secure storage) and owned by `AuthNotifier`. Never log or
/// serialise an instance to anywhere but secure storage — it holds credentials.
class AuthSession {
  const AuthSession({
    required this.accessToken,
    required this.refreshToken,
    required this.accessTokenExpiry,
    required this.userId,
  });

  final String accessToken;
  final String refreshToken;

  /// Absolute access-token expiry, in UTC. Stored/compared in UTC throughout to
  /// avoid timezone bugs (device clocks are local, JWT `exp` is UTC seconds).
  final DateTime accessTokenExpiry;

  /// Opaque user id. May be empty when the backend does not surface one and the
  /// access token is not a decodable JWT — never relied on for auth decisions.
  final String userId;

  /// True once the access token's expiry has passed (UTC comparison).
  bool get isAccessTokenExpired =>
      DateTime.now().toUtc().isAfter(accessTokenExpiry);

  /// True when the access token expires within [window] from now — used by the
  /// interceptor to refresh proactively and to tolerate small device clock skew
  /// rather than waiting for an exact-expiry 401.
  bool needsRefreshWithin(Duration window) =>
      DateTime.now().toUtc().add(window).isAfter(accessTokenExpiry);

  AuthSession copyWith({
    String? accessToken,
    String? refreshToken,
    DateTime? accessTokenExpiry,
    String? userId,
  }) {
    return AuthSession(
      accessToken: accessToken ?? this.accessToken,
      refreshToken: refreshToken ?? this.refreshToken,
      accessTokenExpiry: accessTokenExpiry ?? this.accessTokenExpiry,
      userId: userId ?? this.userId,
    );
  }

  Map<String, dynamic> toJson() => {
        'accessToken': accessToken,
        'refreshToken': refreshToken,
        // ISO-8601 UTC string — unambiguous across timezones.
        'accessTokenExpiry': accessTokenExpiry.toUtc().toIso8601String(),
        'userId': userId,
      };

  /// Defensive deserialisation from secure storage. Throws [FormatException] on
  /// any missing/ill-typed field so the storage gateway can treat the blob as
  /// corrupt (clear it, return null) rather than crashing on startup.
  factory AuthSession.fromJson(Map<String, dynamic> json) {
    final accessToken = json['accessToken'];
    final refreshToken = json['refreshToken'];
    final expiryRaw = json['accessTokenExpiry'];
    if (accessToken is! String ||
        accessToken.isEmpty ||
        refreshToken is! String ||
        refreshToken.isEmpty ||
        expiryRaw is! String) {
      throw const FormatException('Malformed AuthSession');
    }
    final expiry = DateTime.tryParse(expiryRaw)?.toUtc();
    if (expiry == null) {
      throw const FormatException('Malformed accessTokenExpiry');
    }
    final userId = json['userId'];
    return AuthSession(
      accessToken: accessToken,
      refreshToken: refreshToken,
      accessTokenExpiry: expiry,
      userId: userId is String ? userId : '',
    );
  }

  /// Builds a session from the backend auth response
  /// (`/auth/verify-otp` and `/auth/refresh`):
  ///   `{ "accessToken": ..., "refreshToken": ..., "expiresIn": 900 }`
  /// where `expiresIn` is the access-token lifetime in **seconds**.
  ///
  /// [previousRefreshToken] is used as a fallback if the response omits a
  /// rotated refresh token (some refresh endpoints rotate only the access
  /// token). The recapture-api refresh endpoint rotates both, so the response's
  /// `refreshToken` normally wins.
  factory AuthSession.fromAuthResponse(
    Map<String, dynamic> json, {
    String? previousRefreshToken,
  }) {
    final accessToken = json['accessToken'];
    if (accessToken is! String || accessToken.isEmpty) {
      throw const FormatException('Auth response missing accessToken');
    }

    final responseRefresh = json['refreshToken'];
    final refreshToken = responseRefresh is String && responseRefresh.isNotEmpty
        ? responseRefresh
        : previousRefreshToken;
    if (refreshToken == null || refreshToken.isEmpty) {
      throw const FormatException('Auth response missing refreshToken');
    }

    // Prefer an explicit absolute expiry; otherwise derive from expiresIn
    // seconds (recapture-api names it accessTokenExpiresIn); finally fall
    // back to the JWT `exp` claim if present.
    final DateTime expiry;
    final explicit = json['accessTokenExpiry'];
    final expiresIn = json['expiresIn'] ?? json['accessTokenExpiresIn'];
    if (explicit is String && DateTime.tryParse(explicit) != null) {
      expiry = DateTime.parse(explicit).toUtc();
    } else if (expiresIn is num) {
      expiry = DateTime.now().toUtc().add(Duration(seconds: expiresIn.toInt()));
    } else {
      expiry = _expiryFromJwt(accessToken) ??
          DateTime.now().toUtc().add(const Duration(minutes: 15));
    }

    final userId = json['userId'];
    return AuthSession(
      accessToken: accessToken,
      refreshToken: refreshToken,
      accessTokenExpiry: expiry,
      userId: userId is String && userId.isNotEmpty
          ? userId
          : (_userIdFromJwt(accessToken) ?? ''),
    );
  }

  // ── JWT helpers (best-effort, never throw) ─────────────────────────────────

  static Map<String, dynamic>? _jwtPayload(String token) {
    try {
      final parts = token.split('.');
      if (parts.length != 3) return null;
      final payload = json.decode(
        utf8.decode(base64Url.decode(base64Url.normalize(parts[1]))),
      );
      return payload is Map<String, dynamic> ? payload : null;
    } catch (_) {
      return null;
    }
  }

  static DateTime? _expiryFromJwt(String token) {
    final exp = _jwtPayload(token)?['exp'];
    if (exp is! int) return null;
    return DateTime.fromMillisecondsSinceEpoch(exp * 1000, isUtc: true);
  }

  static String? _userIdFromJwt(String token) {
    final payload = _jwtPayload(token);
    final id = payload?['userId'] ?? payload?['authUid'] ?? payload?['sub'];
    return id is String ? id : null;
  }
}
