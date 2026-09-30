// lib/data/remote/api_client.dart
import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../utils/constants.dart';
import 'auth_interceptor.dart';
import 'outlet_interceptor.dart';

/// The app's configured Dio client: base URL + timeouts from [AppConfig] with
/// the [AuthInterceptor] wired in for token attach and 401-refresh.
///
/// Consumed by the authed repositories (`ProjectsRepository`,
/// `AccountRepository`, `LiveProjectsRepository`). The unauthenticated auth
/// endpoints (`AuthRepository`) deliberately use a bare Dio instead — refresh
/// must never ride this client's own 401-refresh interceptor.
final dioProvider = Provider<Dio>((ref) {
  final dio = Dio(
    BaseOptions(
      baseUrl: AppConfig.apiBaseUrl,
      connectTimeout: AppConfig.connectTimeout,
      receiveTimeout: AppConfig.receiveTimeout,
    ),
  );
  // Stage 16: before auth, so a refreshed-and-replayed request keeps it.
  dio.interceptors.add(OutletInterceptor(ref));
  dio.interceptors.add(AuthInterceptor(ref, dio));
  return dio;
});
