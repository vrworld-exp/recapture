// lib/data/remote/backend_warmup_service.dart
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import '../../utils/constants.dart';

/// Fire-and-forget GET /health that wakes the backend up before the user's
/// first real request — the Render dev instance sleeps when idle and cold
/// starts take tens of seconds, so pinging at app open/resume hides that
/// latency behind screens the user is on anyway (the web-app equivalent of a
/// `useEffect(..., [])` warm-up fetch).
///
/// Deliberately NOT the app-wide [dioProvider] client: /health is public and
/// must never trigger the AuthInterceptor's token attach/refresh work.
class BackendWarmupService {
  BackendWarmupService({
    Dio? dio,
    this.minInterval = const Duration(seconds: 60),
    DateTime Function()? now,
  })  : _dio = dio ??
            Dio(BaseOptions(
              baseUrl: AppConfig.apiBaseUrl,
              connectTimeout: AppConfig.connectTimeout,
              // Generous: a Render cold start can take ~60s to answer, and
              // holding the request open until it does means the process is
              // fully up when the first real call goes out.
              //
              // SHARED with the app-wide client rather than a second literal:
              // this ping and the first real request race the same cold start,
              // so a warm-up that waits longer than the request it is warming
              // up for protects nothing. They drifted once already — the
              // app-wide client was left at 30s while this said 75s — and the
              // requests that lost that race are what made the catalog screen
              // report "you're offline" on a backend that was merely asleep.
              receiveTimeout: AppConfig.receiveTimeout,
            )),
        _now = now ?? DateTime.now;

  final Dio _dio;

  /// Minimum gap between pings, so rapid pause/resume cycles don't spam the
  /// endpoint. Well under the backend's idle-sleep window — a suppressed ping
  /// only skips work a ping <60s ago already did.
  final Duration minInterval;

  final DateTime Function() _now;

  DateTime? _lastPingAt;

  /// Pings /health unless one was sent within [minInterval]. Never throws —
  /// warm-up is best-effort and failure means the first real request simply
  /// pays the cold start itself.
  Future<void> warmUp() async {
    final now = _now();
    final last = _lastPingAt;
    if (last != null && now.difference(last) < minInterval) return;
    _lastPingAt = now;

    try {
      final res = await _dio.get<Object?>(
        '/health',
        options: Options(
          // Any HTTP status means the backend answered — mission accomplished.
          validateStatus: (_) => true,
        ),
      );
      debugPrint('[warmup] /health → HTTP ${res.statusCode}');
    } on DioException catch (e) {
      debugPrint('[warmup] /health unreachable (${e.type.name})');
    }
  }
}
