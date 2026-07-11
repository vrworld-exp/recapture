// lib/application/upload/upload_auth_session.dart
//
// The BACKEND-SESSION seam for the upload flow. The app's AuthRepository is
// still stubbed (its tokens would 401 against the live backend), so the flow
// obtains a real Bearer session through this small interface instead of the
// app-wide Dio/auth state. Wiring real login is a separate task; when it
// lands, only [uploadAuthSessionProvider] changes — the flow and the adapter
// keep reading through the seam.
//
// DEV IMPLEMENTATION: reuses the dev-probe OTP handshake (the shared
// [DevOtpHandshake] — send-otp devCode echo → verify-otp, in-memory cache).
// It requires a backend running NODE_ENV=development; against production the
// handshake fails and the failure surfaces on Screen 9F as an auth error.
import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/remote/dev_otp_handshake.dart';
import '../../utils/constants.dart';

/// Supplies a valid Bearer access token for upload-flow backend calls.
abstract interface class UploadAuthSession {
  /// The current access token, performing/refreshing auth as needed.
  /// [forceRefresh] discards any cached session first (401 recovery).
  Future<String> accessToken({bool forceRefresh = false});
}

/// DEV [UploadAuthSession] over the shared dev OTP handshake.
class DevOtpUploadAuthSession implements UploadAuthSession {
  const DevOtpUploadAuthSession(this._handshake);

  final DevOtpHandshake _handshake;

  @override
  Future<String> accessToken({bool forceRefresh = false}) async =>
      (await _handshake.session(forceRefresh: forceRefresh)).accessToken;
}

/// The active backend session for uploads. DEV: the probe's OTP handshake on
/// its OWN bare Dio (never the app-wide client — its AuthInterceptor is wired
/// to the stubbed auth state). Swap this provider when real login lands.
final uploadAuthSessionProvider = Provider<UploadAuthSession>((ref) {
  return DevOtpUploadAuthSession(DevOtpHandshake(
    api: Dio(BaseOptions(
      baseUrl: AppConfig.apiBaseUrl,
      connectTimeout: AppConfig.connectTimeout,
      receiveTimeout: AppConfig.receiveTimeout,
    )),
  ));
});

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
        handler.reject(DioException(
          requestOptions: options,
          error: e,
          type: DioExceptionType.unknown,
        ));
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
