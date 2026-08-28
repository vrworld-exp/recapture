// test/warmup/backend_warmup_test.dart
//
// The backend warm-up ping:
//   - service: GET /health goes out, repeat calls inside the throttle window
//     are suppressed, unreachable backend never throws,
//   - provider: startup fires one ping, a background→foreground resume fires
//     another once the throttle window has passed.
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:recapture/application/warmup/backend_warmup.dart';
import 'package:recapture/data/remote/backend_warmup_service.dart';

class _FakeAdapter implements HttpClientAdapter {
  _FakeAdapter({this.onFetch});

  final Future<ResponseBody> Function(RequestOptions options)? onFetch;

  final List<RequestOptions> requests = [];

  @override
  void close({bool force = false}) {}

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) {
    requests.add(options);
    if (onFetch != null) return onFetch!(options);
    return Future.value(ResponseBody.fromString(
      jsonEncode({'status': 'success'}),
      200,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    ));
  }
}

/// Counts warmUp calls without any network — for the provider wiring test.
/// (The injected Dio is never used; the override skips the real request.)
class _CountingWarmupService extends BackendWarmupService {
  _CountingWarmupService() : super(dio: Dio());

  int calls = 0;

  @override
  Future<void> warmUp() async {
    calls++;
  }
}

BackendWarmupService _service(
  _FakeAdapter adapter, {
  DateTime Function()? now,
}) {
  final dio = Dio(BaseOptions(baseUrl: 'http://api.test'))
    ..httpClientAdapter = adapter;
  return BackendWarmupService(dio: dio, now: now);
}

void main() {
  group('BackendWarmupService', () {
    test('warmUp sends GET /health', () async {
      final adapter = _FakeAdapter();
      await _service(adapter).warmUp();

      expect(adapter.requests, hasLength(1));
      expect(adapter.requests.single.method, 'GET');
      expect(adapter.requests.single.path, '/health');
    });

    test('repeat calls inside the throttle window are suppressed', () async {
      var current = DateTime(2026, 7, 11, 12);
      final adapter = _FakeAdapter();
      final service = _service(adapter, now: () => current);

      await service.warmUp();
      current = current.add(const Duration(seconds: 30));
      await service.warmUp();
      expect(adapter.requests, hasLength(1));

      current = current.add(const Duration(seconds: 31));
      await service.warmUp();
      expect(adapter.requests, hasLength(2));
    });

    test('an unreachable backend never throws', () async {
      final adapter = _FakeAdapter(
        onFetch: (options) => throw DioException.connectionError(
          requestOptions: options,
          reason: 'refused',
        ),
      );
      await expectLater(_service(adapter).warmUp(), completes);
    });

    test('a non-2xx status is still a completed warm-up, not an error',
        () async {
      final adapter = _FakeAdapter(
        onFetch: (options) =>
            Future.value(ResponseBody.fromString('oops', 500)),
      );
      await expectLater(_service(adapter).warmUp(), completes);
      expect(adapter.requests, hasLength(1));
    });
  });

  group('backendWarmupProvider', () {
    // Wiring only — the real service's Dio call and throttle are covered by
    // the unit tests above (Dio's zero-duration timers don't fire inside the
    // widget test's fake-async zone anyway).
    testWidgets('pings at startup and again on every resume', (tester) async {
      final service = _CountingWarmupService();
      final container = ProviderContainer(overrides: [
        backendWarmupServiceProvider.overrideWithValue(service),
      ]);
      var disposed = false;
      addTearDown(() {
        if (!disposed) container.dispose();
      });

      // Valid lifecycle walk: resumed ↔ inactive ↔ hidden ↔ paused.
      void goBackground() {
        tester.binding
            .handleAppLifecycleStateChanged(AppLifecycleState.inactive);
        tester.binding
            .handleAppLifecycleStateChanged(AppLifecycleState.hidden);
        tester.binding
            .handleAppLifecycleStateChanged(AppLifecycleState.paused);
      }

      void goForeground() {
        tester.binding
            .handleAppLifecycleStateChanged(AppLifecycleState.hidden);
        tester.binding
            .handleAppLifecycleStateChanged(AppLifecycleState.inactive);
        tester.binding
            .handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      }

      container.read(backendWarmupProvider);
      expect(service.calls, 1, reason: 'startup ping');

      // Background → foreground round trip fires the resume ping.
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      service.calls = 1; // the initial resumed transition also counts — reset
      goBackground();
      goForeground();
      expect(service.calls, 2, reason: 'resume ping');

      // Disposing the provider detaches the lifecycle listener.
      container.dispose();
      disposed = true;
      goBackground();
      goForeground();
      expect(service.calls, 2, reason: 'no ping after dispose');
    });
  });
}
