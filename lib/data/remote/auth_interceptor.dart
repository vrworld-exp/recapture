// lib/data/remote/auth_interceptor.dart
import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../application/auth/auth_notifier.dart';

/// Dio interceptor that bridges the API client to [AuthNotifier]:
///   - attaches `Authorization: Bearer <access token>` on every request,
///     refreshing proactively first if the token is expired/near-expiry,
///   - on a 401, triggers a single shared refresh and retries the request once.
///
/// Refresh-storm safety lives in [AuthNotifier.refresh] (one in-flight future
/// shared across callers), so N concurrent 401s cause exactly one refresh.
class AuthInterceptor extends Interceptor {
  AuthInterceptor(this._ref, this._dio);

  final Ref _ref;

  /// The Dio instance this interceptor is attached to, used to replay a request
  /// after a refresh. Passed in (not read from a provider) so the retry never
  /// re-reads the provider that owns this interceptor — a provider reading
  /// itself trips Riverpod's self-dependency assertion and the retry would hang.
  final Dio _dio;

  /// Marks a request that has already been retried after a refresh, so a second
  /// 401 falls through instead of looping.
  static const String _retriedFlag = 'auth_retried';

  AuthNotifier get _auth => _ref.read(authProvider.notifier);

  @override
  void onRequest(
    RequestOptions options,
    RequestInterceptorHandler handler,
  ) async {
    final token = await _auth.ensureFreshToken();
    if (token != null) {
      options.headers['Authorization'] = 'Bearer $token';
    }
    handler.next(options);
  }

  @override
  void onError(DioException err, ErrorInterceptorHandler handler) async {
    final isUnauthorized = err.response?.statusCode == 401;
    final alreadyRetried = err.requestOptions.extra[_retriedFlag] == true;

    if (!isUnauthorized || alreadyRetried) {
      handler.next(err);
      return;
    }

    final refreshed = await _auth.refresh();
    if (!refreshed) {
      // Session was cleared by the notifier; user is already logged out.
      handler.next(err);
      return;
    }

    final token = _auth.accessTokenOrNull;
    // Build the retry from a COPY rather than mutating `err.requestOptions` in
    // place: that object is the original, still-referenced request, and
    // rewriting its headers here would retroactively change what the original
    // attempt looks like. The copy carries fresh maps so the two attempts stay
    // independent (original = old token, retry = new token).
    final retryOptions = err.requestOptions.copyWith(
      extra: {...err.requestOptions.extra, _retriedFlag: true},
      headers: {
        ...err.requestOptions.headers,
        'Authorization': token != null ? 'Bearer $token' : null,
      },
    );

    try {
      final response = await _dio.fetch<dynamic>(retryOptions);
      handler.resolve(response);
    } on DioException catch (retryError) {
      handler.next(retryError);
    }
  }
}
