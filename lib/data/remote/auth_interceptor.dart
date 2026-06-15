// lib/data/remote/auth_interceptor.dart
import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../application/auth/auth_notifier.dart';
import 'api_client.dart';

/// Dio interceptor that bridges the API client to [AuthNotifier]:
///   - attaches `Authorization: Bearer <access token>` on every request,
///     refreshing proactively first if the token is expired/near-expiry,
///   - on a 401, triggers a single shared refresh and retries the request once.
///
/// Refresh-storm safety lives in [AuthNotifier.refresh] (one in-flight future
/// shared across callers), so N concurrent 401s cause exactly one refresh.
class AuthInterceptor extends Interceptor {
  AuthInterceptor(this._ref);

  final Ref _ref;

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
    final retryOptions = err.requestOptions
      ..extra[_retriedFlag] = true
      ..headers['Authorization'] = token != null ? 'Bearer $token' : null;

    try {
      final response = await _ref.read(dioProvider).fetch<dynamic>(retryOptions);
      handler.resolve(response);
    } on DioException catch (retryError) {
      handler.next(retryError);
    }
  }
}
