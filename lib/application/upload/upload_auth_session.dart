// lib/application/upload/upload_auth_session.dart
//
// The BACKEND-SESSION seam for the upload flow: a small interface supplying a
// valid Bearer token, so the flow/adapter never depend on where the session
// comes from.
//
// PRODUCTION IMPLEMENTATION ([AppAuthUploadSession]): the app's REAL logged-in
// session via [AuthNotifier] — proactive refresh through ensureFreshToken, and
// a forced rotate on 401 recovery. Requires a real login (the devCode/OTP
// flow); a master-OTP stub session's tokens are rejected by the backend and
// surface on Screen 9F as an auth failure.
//
// [DevOtpUploadAuthSession] (the probe's send-otp devCode → verify-otp
// handshake) is kept for dev tooling/tests that must not touch app auth state.
import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../auth/auth_notifier.dart';
import '../../data/remote/dev_otp_handshake.dart';
import '../../domain/upload/upload_failure.dart';
import '../../utils/constants.dart';

/// Supplies a valid Bearer access token for upload-flow backend calls.
abstract interface class UploadAuthSession {
  /// The current access token, performing/refreshing auth as needed.
  /// [forceRefresh] discards any cached session first (401 recovery).
  Future<String> accessToken({bool forceRefresh = false});
}

/// A token-acquisition failure carrying its ALREADY-MAPPED 9F category (an
/// [UploadFailureSignal], so `classifyUploadFailure` never falls back to
/// UNK-01 for it):
///   • `auth`    — the session is genuinely gone (rejected/absent): Retry is
///                 pointless; 9F says "sign in again".
///   • `network` — the session survived but a TRANSIENT refresh failure left
///                 no usable token right now (sleeping backend, dead spot):
///                 retryable, 9F says "check your connection and try again".
/// [detail] is diagnostics-only — never rendered.
class UploadAuthException implements Exception, UploadFailureSignal {
  const UploadAuthException(this.uploadErrorCategory, {this.detail});

  @override
  final UploadErrorCategory uploadErrorCategory;

  final String? detail;

  @override
  String toString() => 'UploadAuthException(${uploadErrorCategory.wireName}'
      '${detail == null ? '' : ': $detail'})';
}

/// DEV [UploadAuthSession] over the shared dev OTP handshake.
class DevOtpUploadAuthSession implements UploadAuthSession {
  const DevOtpUploadAuthSession(this._handshake);

  final DevOtpHandshake _handshake;

  @override
  Future<String> accessToken({bool forceRefresh = false}) async =>
      (await _handshake.session(forceRefresh: forceRefresh)).accessToken;
}

/// PRODUCTION [UploadAuthSession]: the app's real logged-in session.
class AppAuthUploadSession implements UploadAuthSession {
  const AppAuthUploadSession(this._ref);

  final Ref _ref;

  @override
  Future<String> accessToken({bool forceRefresh = false}) async {
    final auth = _ref.read(authProvider.notifier);
    if (forceRefresh) {
      // 401 recovery: rotate now (single-flight inside the notifier). A failed
      // rotate surfaces as a MAPPED failure (Screen 9F), never a silent hang.
      final ok = await auth.refresh();
      final token = ok ? auth.accessTokenOrNull : null;
      if (token == null) throw _noToken(auth, 'refresh after 401 failed');
      return token;
    }
    final token = await auth.ensureFreshToken();
    if (token == null) throw _noToken(auth, 'no fresh token');
    return token;
  }

  /// Maps "no usable token" to its true category: session retained after a
  /// TRANSIENT refresh failure → network (retryable); session absent/cleared
  /// (rejected refresh, never logged in, stub session torn down) → auth.
  UploadAuthException _noToken(AuthNotifier auth, String why) =>
      auth.isAuthenticated
          ? UploadAuthException(UploadErrorCategory.network,
              detail: '$why; session retained (transient)')
          : UploadAuthException(UploadErrorCategory.auth,
              detail: '$why; session gone — sign in again');
}

/// The active backend session for uploads: the app's real login session.
/// (A master-OTP stub session cannot upload — its tokens 401 server-side and
/// the flow reports an auth failure. Use the devCode login when testing.)
final uploadAuthSessionProvider = Provider<UploadAuthSession>(
  (ref) => AppAuthUploadSession(ref),
);

/// Builds the AUTHED Dio the upload flow's backend calls go through: attaches
/// the seam's Bearer token per request and, on a 401, refreshes the session
/// once and replays the request. Distinct from [DioS3PartClient]'s bare Dio —
/// presigned S3 PUTs must NOT carry an Authorization header.
Dio buildUploadApiDio(UploadAuthSession session, {String? baseUrl}) {
  final dio = Dio(BaseOptions(
    baseUrl: baseUrl ?? AppConfig.apiBaseUrl,
    connectTimeout: AppConfig.connectTimeout,
    receiveTimeout: AppConfig.receiveTimeout,
  ));
  dio.interceptors.add(InterceptorsWrapper(
    onRequest: (options, handler) async {
      try {
        final token = await session.accessToken();
        options.headers['Authorization'] = 'Bearer $token';
        handler.next(options);
      } catch (e) {
        // Dio requires a DioException here; _AuthRejectDioException keeps the
        // inner error's mapped category visible to classifyUploadFailure so a
        // token failure never degrades to UNK-01.
        handler.reject(_AuthRejectDioException(requestOptions: options, cause: e));
      }
    },
    onError: (e, handler) async {
      final alreadyRetried = e.requestOptions.extra['authRetried'] == true;
      if (e.response?.statusCode == 401 && !alreadyRetried) {
        try {
          final token = await session.accessToken(forceRefresh: true);
          final retried = e.requestOptions
            ..extra['authRetried'] = true
            ..headers['Authorization'] = 'Bearer $token';
          handler.resolve(await dio.fetch(retried));
          return;
        } catch (_) {
          // Fall through with the ORIGINAL 401 — never mask it with the
          // refresh attempt's error.
        }
      }
      handler.next(e);
    },
  ));
  return dio;
}

/// The authed upload-flow Dio. keepAlive so the interceptor's session context
/// (and Dio connection pool) survives across screens within one flow.
final uploadApiDioProvider = Provider<Dio>(
  (ref) => buildUploadApiDio(ref.watch(uploadAuthSessionProvider)),
);

/// The DioException the auth interceptor rejects with when token acquisition
/// fails BEFORE the request goes out. Implements [UploadFailureSignal] with
/// the inner error's own category (or its classified category as a fallback)
/// so 9F reports AUTH-01/NET-01 — never the generic UNK-01.
class _AuthRejectDioException extends DioException
    implements UploadFailureSignal {
  _AuthRejectDioException({
    required super.requestOptions,
    required Object cause,
  })  : uploadErrorCategory = cause is UploadFailureSignal
            ? cause.uploadErrorCategory
            : classifyUploadFailure(cause),
        super(error: cause, type: DioExceptionType.unknown);

  @override
  final UploadErrorCategory uploadErrorCategory;
}
