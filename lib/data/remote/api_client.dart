// lib/data/remote/api_client.dart
import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../utils/constants.dart';
import 'auth_interceptor.dart';

/// The app's configured Dio client: base URL + timeouts from [AppConfig] with
/// the [AuthInterceptor] wired in for token attach and 401-refresh.
///
/// TODO(api): no repository consumes this yet — `ProjectsRepository` and
/// `AuthRepository` bodies are still stubbed. Switching those to real Dio calls
/// is a follow-up; the auth plumbing (Bearer attach, single-flight 401 refresh
/// and retry) is already complete here.
final dioProvider = Provider<Dio>((ref) {
  final dio = Dio(
    BaseOptions(
      baseUrl: AppConfig.apiBaseUrl,
      connectTimeout: AppConfig.connectTimeout,
      receiveTimeout: AppConfig.receiveTimeout,
    ),
  );
  dio.interceptors.add(AuthInterceptor(ref, dio));
  return dio;
});
