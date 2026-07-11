// test/dev_probe/dev_tools_section_test.dart
//
// Widget tests for the Dev Tools section:
//   - flavor gating both ways (dev renders, prod builds nothing),
//   - the Projects screen carries the section in the dev flavor,
//   - the Health pill: success renders code + latency + raw body; a
//     connection error renders the unreachable state without throwing.
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:recapture/application/projects/projects_notifier.dart';
import 'package:recapture/dev/dev_probe/dev_probe_service.dart';
import 'package:recapture/dev/dev_probe/dev_tools_section.dart';
import 'package:recapture/domain/entities/project.dart';
import 'package:recapture/presentation/screens/projects/projects_screen.dart';
import 'package:recapture/utils/app_env.dart';

class _FakeAdapter implements HttpClientAdapter {
  _FakeAdapter(this.onFetch);

  final Future<ResponseBody> Function(RequestOptions options) onFetch;

  @override
  void close({bool force = false}) {}

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) =>
      onFetch(options);
}

HealthProbeService _healthService(
    Future<ResponseBody> Function(RequestOptions) onFetch) {
  final dio = Dio(BaseOptions(baseUrl: 'http://api.test'))
    ..httpClientAdapter = _FakeAdapter(onFetch);
  return HealthProbeService(dio: dio);
}

Widget _wrap(Widget child) {
  return MaterialApp(home: Scaffold(body: child));
}

/// Serves the projects list without repositories/Hive so the real screen can
/// be pumped hermetically.
class _FakeProjectsNotifier extends ProjectsNotifier {
  @override
  Future<List<Project>> build() async => const <Project>[];
}

void main() {
  group('flavor gating', () {
    testWidgets('dev flavor renders the section', (tester) async {
      await tester.pumpWidget(
        _wrap(const DevToolsSection(environment: AppEnvironment.dev)),
      );
      expect(find.text('DEV TOOLS'), findsOneWidget);
      expect(find.text('API Health'), findsOneWidget);
      expect(find.text('S3 Upload Smoke Test'), findsOneWidget);
    });

    testWidgets('production builds nothing', (tester) async {
      await tester.pumpWidget(
        _wrap(const DevToolsSection(environment: AppEnvironment.prod)),
      );
      expect(find.text('DEV TOOLS'), findsNothing);
      expect(find.text('API Health'), findsNothing);
      expect(find.text('S3 Upload Smoke Test'), findsNothing);
    });

    testWidgets('the Projects screen carries the section (test env = dev)',
        (tester) async {
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            projectsProvider.overrideWith(_FakeProjectsNotifier.new),
          ],
          child: const MaterialApp(home: ProjectsScreen()),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('DEV TOOLS'), findsOneWidget);
    });
  });

  group('Health pill', () {
    testWidgets('success renders status code, latency, and the raw body',
        (tester) async {
      final service = _healthService((o) async {
        expect(o.method, 'GET');
        expect(o.uri.path, '/health');
        return ResponseBody.fromString(
          jsonEncode({
            'status': 'ok',
            'db': 'connected',
            'timestamp': '2026-07-10T00:00:00.000Z',
            'env': 'development',
          }),
          200,
          headers: {
            Headers.contentTypeHeader: ['application/json'],
          },
        );
      });
      await tester.pumpWidget(_wrap(DevToolsSection(
        environment: AppEnvironment.dev,
        healthService: service,
      )));

      await tester.tap(find.text('API Health'));
      await tester.pumpAndSettle();

      expect(find.text('GET /health'), findsOneWidget);
      expect(find.text('HTTP 200'), findsOneWidget);
      expect(find.textContaining(' ms'), findsOneWidget);
      expect(find.textContaining('"status": "ok"'), findsOneWidget);
      expect(find.textContaining('"db": "connected"'), findsOneWidget);
    });

    testWidgets('connection error renders the unreachable state, no throw',
        (tester) async {
      final service = _healthService((o) async {
        throw DioException(
          requestOptions: o,
          type: DioExceptionType.connectionError,
          error: 'Connection refused',
        );
      });
      await tester.pumpWidget(_wrap(DevToolsSection(
        environment: AppEnvironment.dev,
        healthService: service,
      )));

      await tester.tap(find.text('API Health'));
      await tester.pumpAndSettle();

      expect(find.text('UNREACHABLE'), findsOneWidget);
      expect(
        find.textContaining('Backend unreachable at http://api.test'),
        findsOneWidget,
      );
      expect(find.textContaining('connectionError'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });
}
