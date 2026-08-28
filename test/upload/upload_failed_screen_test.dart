// test/upload/upload_failed_screen_test.dart
//
// Screen 9F — Upload Failed. Verifies: mapped non-technical reason + code (no raw
// leak), retryable-only Retry, Retry re-enters uploading (reuses captures), Back to
// Projects (resumable, stack cleared), double-tap guards, safe handling of a
// missing session / unknown category, and the three analytics events.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:recapture/app/routes/app_router.dart';
import 'package:recapture/application/capture/analytics/capture_level_events.dart';
import 'package:recapture/application/capture/analytics/capture_level_session.dart';
import 'package:recapture/domain/upload/upload_failure.dart';
import 'package:recapture/presentation/screens/capture/upload_failed_screen.dart';
import 'package:recapture/utils/analytics.dart';

/// Seeds a known session so Retry (which requires a session) is available.
class _SeededSessionNotifier extends CaptureLevelSessionNotifier {
  @override
  CaptureLevelSession? build() => CaptureLevelSession(
        level: CaptureLevel.a,
        projectId: 'p1',
        sessionId: 'sess-1',
        startedAt: DateTime(2026),
      );
}

/// No session (restart / deep-link) → sessionId ''.
class _NoSessionNotifier extends CaptureLevelSessionNotifier {
  @override
  CaptureLevelSession? build() => null;
}

void main() {
  late List<({String name, Map<String, Object?> props})> events;

  setUp(() {
    events = [];
    Analytics.testSink = (name, props) => events.add((name: name, props: props));
  });
  tearDown(() => Analytics.testSink = null);

  List<({String name, Map<String, Object?> props})> named(String name) =>
      events.where((e) => e.name == name).toList();

  Future<void> pump(
    WidgetTester tester,
    UploadErrorCategory category, {
    bool withSession = true,
  }) async {
    Widget stub(String l) => Scaffold(body: Text(l));
    final router = GoRouter(
      initialLocation: AppRoutes.uploadFailed,
      routes: [
        GoRoute(
          path: AppRoutes.uploadFailed,
          builder: (_, __) => UploadFailedScreen(failure: category),
        ),
        GoRoute(path: AppRoutes.uploading, builder: (_, __) => stub('UPLOADING')),
        GoRoute(path: AppRoutes.projects, builder: (_, __) => stub('PROJECTS')),
      ],
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          captureLevelSessionProvider.overrideWith(
            withSession ? _SeededSessionNotifier.new : _NoSessionNotifier.new,
          ),
        ],
        child: MaterialApp.router(routerConfig: router),
      ),
    );
    await tester.pump();
  }

  testWidgets('retryable failure → mapped reason, code, Retry + Back',
      (tester) async {
    await pump(tester, UploadErrorCategory.network);

    expect(find.byKey(const Key('upload_failed_9f')), findsOneWidget);
    expect(find.text("Couldn't connect"), findsOneWidget);
    expect(find.text('Error code: NET-01'), findsOneWidget);
    expect(find.byKey(const Key('upload_failed_retry')), findsOneWidget);
    expect(find.byKey(const Key('upload_failed_back')), findsOneWidget);

    final viewed = named(AnalyticsEvents.uploadFailedViewed);
    expect(viewed, hasLength(1));
    expect(viewed.first.props['error_category'], 'network');
    expect(viewed.first.props['retryable'], true);
    expect(viewed.first.props['phase'], 'upload');
  });

  testWidgets('Retry → re-enters uploading + upload_retry_tapped',
      (tester) async {
    await pump(tester, UploadErrorCategory.server);
    await tester.tap(find.byKey(const Key('upload_failed_retry')));
    await tester.pumpAndSettle();

    expect(find.text('UPLOADING'), findsOneWidget);
    final retry = named(AnalyticsEvents.uploadRetryTapped);
    expect(retry, hasLength(1));
    expect(retry.first.props['error_category'], 'server');
    expect(retry.first.props['session_id'], 'sess-1');
  });

  testWidgets('non-retryable (validation) → no Retry, Back only', (tester) async {
    await pump(tester, UploadErrorCategory.validation);

    expect(find.byKey(const Key('upload_failed_retry')), findsNothing);
    expect(find.byKey(const Key('upload_failed_back')), findsOneWidget);
    expect(named(AnalyticsEvents.uploadFailedViewed).first.props['retryable'],
        false);
  });

  testWidgets('Back to Projects → projects + upload_failed_back_to_projects',
      (tester) async {
    await pump(tester, UploadErrorCategory.quota);
    await tester.tap(find.byKey(const Key('upload_failed_back')));
    await tester.pumpAndSettle();

    expect(find.text('PROJECTS'), findsOneWidget);
    final back = named(AnalyticsEvents.uploadFailedBackToProjects);
    expect(back, hasLength(1));
    expect(back.first.props['error_category'], 'quota');
  });

  testWidgets('missing session → Retry hidden even when retryable',
      (tester) async {
    // Retry is impossible without a session → route to Projects instead.
    await pump(tester, UploadErrorCategory.network, withSession: false);
    expect(find.byKey(const Key('upload_failed_retry')), findsNothing);
    expect(find.byKey(const Key('upload_failed_back')), findsOneWidget);
  });

  testWidgets('unknown category → generic friendly message, retryable',
      (tester) async {
    await pump(tester, UploadErrorCategory.unknown);
    expect(find.text('Upload failed'), findsWidgets); // heading + title
    expect(find.text('Error code: UNK-01'), findsOneWidget);
    expect(find.byKey(const Key('upload_failed_retry')), findsOneWidget);
  });

  testWidgets('double-tap Retry → single attempt', (tester) async {
    await pump(tester, UploadErrorCategory.network);
    final btn = find.byKey(const Key('upload_failed_retry'));
    await tester.tap(btn, warnIfMissed: false);
    await tester.tap(btn, warnIfMissed: false);
    await tester.pumpAndSettle();
    expect(named(AnalyticsEvents.uploadRetryTapped), hasLength(1));
  });

  testWidgets('no raw error text is rendered (only mapped copy/code)',
      (tester) async {
    await pump(tester, UploadErrorCategory.server);
    // Nothing resembling a raw exception / status body / path leaks onto 9F.
    expect(find.textContaining('Exception'), findsNothing);
    expect(find.textContaining('500'), findsNothing);
    expect(find.textContaining('/'), findsNothing);
  });
}
