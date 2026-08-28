// lib/data/remote/dev_otp_handshake.dart
//
// The DEV-ONLY backend auth handshake, shared by the Dev Tools probe and the
// upload flow's dev [UploadAuthSession]: `POST /auth/send-otp` echoes a
// `devCode` (only when the backend runs NODE_ENV=development), which is
// immediately verified via `POST /auth/verify-otp` for a real Bearer session.
//
// The session is cached IN MEMORY ONLY (static — one session per app run,
// shared across consumers, surviving widget rebuilds), never secure storage
// and never the app's stubbed auth state. Wiring the production login flow is
// a separate task; nothing here touches the auth repositories.
import 'package:dio/dio.dart';

/// Fixed dev identity for the handshake.
const String kDevOtpPhone = '+911111111111';

/// An in-memory dev backend session.
class DevOtpSession {
  const DevOtpSession({required this.accessToken, required this.refreshToken});

  final String accessToken;

  // Kept for completeness; consumers re-handshake rather than refreshing.
  final String refreshToken;
}

/// Raised when the handshake cannot produce a session. [detail] is a
/// display-ready explanation (dev tooling surfaces it verbatim).
class DevOtpHandshakeException implements Exception {
  DevOtpHandshakeException(this.detail);

  final String detail;

  @override
  String toString() => 'DevOtpHandshakeException: $detail';
}

/// Performs (and caches) the dev OTP handshake against a Dio bound to the API
/// base URL. The Dio must be a bare/own instance — never the app-wide client,
/// whose AuthInterceptor is wired to the stubbed auth state.
class DevOtpHandshake {
  DevOtpHandshake({required this.api, this.phone = kDevOtpPhone});

  final Dio api;
  final String phone;

  /// One cached session per app run, shared by every consumer (avoids the
  /// send-otp rate window). Memory only, by design.
  static DevOtpSession? _cached;

  /// Drops the shared cached session (test isolation / dev-tools reset).
  static void resetCachedSession() => _cached = null;

  bool get hasCachedSession => _cached != null;

  /// Drops the cached session (e.g. after a 401 on an authed call) so the next
  /// [session] re-handshakes.
  void invalidate() => _cached = null;

  /// Returns the cached session, or performs the handshake. Throws
  /// [DevOtpHandshakeException] when the backend carries no devCode (i.e. it
  /// is not running in development mode); Dio transport errors propagate.
  Future<DevOtpSession> session({bool forceRefresh = false}) async {
    if (forceRefresh) _cached = null;
    final cached = _cached;
    if (cached != null) return cached;

    final send = await api.post<Object?>(
      '/auth/send-otp',
      data: {'channel': 'sms', 'phone': phone},
    );
    final sendBody = _asJsonMap(send.data);
    final devCode = sendBody['devCode'];
    if (devCode is! String || devCode.isEmpty) {
      throw DevOtpHandshakeException(
          'send-otp succeeded but carried no devCode — the backend is '
          'running with NODE_ENV=production (the dev echo is gated off). '
          'Point the probe at a dev backend.');
    }

    final verify = await api.post<Object?>(
      '/auth/verify-otp',
      data: {'channel': 'sms', 'phone': phone, 'code': devCode},
    );
    final verifyBody = _asJsonMap(verify.data);
    final fresh = DevOtpSession(
      accessToken: verifyBody['accessToken'] as String,
      refreshToken: verifyBody['refreshToken'] as String,
    );
    _cached = fresh;
    return fresh;
  }

  static Map<String, dynamic> _asJsonMap(Object? data) {
    if (data is Map<String, dynamic>) return data;
    if (data is Map) return Map<String, dynamic>.from(data);
    throw DevOtpHandshakeException('Expected a JSON object, got: $data');
  }
}
