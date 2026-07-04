// test/upload/uploading_screen_test.dart
//
// Screen 9 — Uploading. Pure observer of uploadProgressProvider: determinate bar
// from real bytes, file/MB counters, Wi-Fi hint, completion→advance, failure→
// surface with retry/back, and view-level analytics (once-only). The pipeline is
// faked via a controllable source overriding uploadProgressSourceProvider.
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:recapture/app/routes/app_router.dart';
import 'package:recapture/application/upload/upload_progress_provider.dart';
import 'package:recapture/domain/entities/upload_progress.dart';
import 'package:recapture/presentation/screens/capture/uploading_screen.dart';
import 'package:recapture/utils/analytics.dart';
import 'package:recapture/utils/byte_format.dart';

class _FakeSource implements UploadProgressSource {
  _FakeSource(this.controller);
  final StreamController<UploadProgress> controller;
  @override
  Stream<UploadProgress> watch() => controller.stream;
}

UploadProgress _p({
  UploadStatus status = UploadStatus.inProgress,
  int bytes = 0,
  int total = 0,
  int files = 0,
  int totalFiles = 0,
}) =>
    UploadProgress(
      status: status,
      bytesUploaded: bytes,
      totalBytes: total,
      filesUploaded: files,
      totalFiles: totalFiles,
    );

const int _mb = kBytesPerMb;

void main() {
  late List<({String name, Map<String, Object?> props})> events;
  late StreamController<UploadProgress> controller;

  setUp(() {
    events = [];
    Analytics.testSink = (name, props) => events.add((name: name, props: props));
    controller = StreamController<UploadProgress>.broadcast();
  });
  tearDown(() {
    Analytics.testSink = null;
    controller.close();
    debugDefaultTargetPlatformOverride = null; // clear any per-test platform override
  });

  List<({String name, Map<String, Object?> props})> named(String n) =>
      events.where((e) => e.name == n).toList();

  Future<void> pump(WidgetTester tester) async {
    Widget stub(String l) => Scaffold(body: Text(l));
    final router = GoRouter(
      initialLocation: AppRoutes.uploading,
      routes: [
        GoRoute(
            path: AppRoutes.uploading,
            builder: (_, __) => const UploadingScreen()),
        GoRoute(
            path: AppRoutes.processing, builder: (_, __) => stub('PROCESSING')),
        GoRoute(path: AppRoutes.projects, builder: (_, __) => stub('PROJECTS')),
        // Screen 9F stub — asserts the uploading screen ROUTES here on failure.
        GoRoute(
            path: AppRoutes.uploadFailed, builder: (_, __) => stub('FAILED_9F')),
      ],
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          uploadProgressSourceProvider
              .overrideWithValue(_FakeSource(controller)),
        ],
        child: MaterialApp.router(routerConfig: router),
      ),
    );
    await tester.pump();
  }

  // Emit a snapshot and let the StreamProvider propagate (deliver microtask +
  // rebuild) before assertions.
  Future<void> emit(WidgetTester tester, UploadProgress p) async {
    controller.add(p);
    await tester.pump();
    await tester.pump();
  }

  LinearProgressIndicator bar(WidgetTester tester) =>
      tester.widget<LinearProgressIndicator>(
          find.byKey(const Key('upload_progress_bar')));

  testWidgets('determinate bar + counters track real progress', (tester) async {
    await pump(tester);
    await emit(
        tester, _p(bytes: 55 * _mb, total: 110 * _mb, files: 5, totalFiles: 10));

    expect(bar(tester).value, 0.5);
    expect(find.text('50%'), findsOneWidget);
    expect(find.text('5 / 10 files'), findsOneWidget);
    expect(find.text('55.0 / 110.0 MB'), findsOneWidget);
    expect(find.byKey(const Key('upload_wifi_hint')), findsOneWidget);
  });

  testWidgets('upload_started_view fires once with totals', (tester) async {
    await pump(tester);
    await emit(
        tester, _p(bytes: 10 * _mb, total: 110 * _mb, files: 1, totalFiles: 10));
    await emit(
        tester, _p(bytes: 20 * _mb, total: 110 * _mb, files: 2, totalFiles: 10));

    final started = named(AnalyticsEvents.uploadStartedView);
    expect(started, hasLength(1)); // once, despite two emissions
    expect(started.first.props['total_files'], 10);
    expect(started.first.props['total_mb'], 110.0);
    expect(started.first.props['phase'], 'upload');
  });

  testWidgets('completion → upload_completed + advances to processing',
      (tester) async {
    await pump(tester);
    await emit(tester,
        _p(bytes: 110 * _mb, total: 110 * _mb, files: 10, totalFiles: 10));
    await emit(
        tester,
        _p(
            status: UploadStatus.completed,
            bytes: 110 * _mb,
            total: 110 * _mb,
            files: 10,
            totalFiles: 10));
    await tester.pumpAndSettle();

    expect(find.text('PROCESSING'), findsOneWidget);
    final done = named(AnalyticsEvents.uploadCompleted);
    expect(done, hasLength(1));
    expect(done.first.props['total_files'], 10);
    expect(done.first.props['duration_ms'], isA<int>());
  });

  testWidgets('failed status → routes to Screen 9F + upload_failed_view',
      (tester) async {
    await pump(tester);
    await emit(
        tester, _p(bytes: 30 * _mb, total: 110 * _mb, files: 3, totalFiles: 10));
    await emit(
        tester,
        _p(
            status: UploadStatus.failed,
            bytes: 30 * _mb,
            total: 110 * _mb,
            files: 3,
            totalFiles: 10));
    await tester.pumpAndSettle(); // navigation to 9F

    expect(find.text('FAILED_9F'), findsOneWidget);
    expect(find.text('PROCESSING'), findsNothing); // did NOT advance
    final failed = named(AnalyticsEvents.uploadFailedView);
    expect(failed, hasLength(1));
    expect(failed.first.props['files_uploaded_at_failure'], 3);
  });

  testWidgets('stream error → routes to Screen 9F + upload_failed_view',
      (tester) async {
    await pump(tester);
    await emit(
        tester, _p(bytes: 30 * _mb, total: 110 * _mb, files: 4, totalFiles: 10));
    controller.addError(Exception('network down'));
    await tester.pumpAndSettle(); // error → navigation to 9F

    expect(find.text('FAILED_9F'), findsOneWidget);
    final failed = named(AnalyticsEvents.uploadFailedView);
    expect(failed, hasLength(1));
    expect(failed.first.props['files_uploaded_at_failure'], 4);
  });

  testWidgets('zero/unknown totals → safe state, no NaN/div0', (tester) async {
    await pump(tester);
    await emit(tester, UploadProgress.initial);

    expect(bar(tester).value, 0.0);
    expect(find.text('0%'), findsOneWidget);
    expect(find.text('0 / 0 files'), findsOneWidget);
    expect(find.text('0.0 / 0.0 MB'), findsOneWidget);
  });

  testWidgets('transient over-report clamps display to 100%', (tester) async {
    await pump(tester);
    await emit(tester,
        _p(bytes: 200 * _mb, total: 110 * _mb, files: 12, totalFiles: 10));

    expect(bar(tester).value, 1.0);
    expect(find.text('10 / 10 files'), findsOneWidget);
    expect(find.text('110.0 / 110.0 MB'), findsOneWidget);
  });

  testWidgets('Cancel → confirm → pipeline cancel signalled; cancelled reflects '
      '→ exits to projects', (tester) async {
    await pump(tester);
    await emit(
        tester, _p(bytes: 10 * _mb, total: 110 * _mb, files: 1, totalFiles: 10));
    await tester.tap(find.byKey(const Key('upload_cancel')));
    await tester.pumpAndSettle(); // confirmation dialog
    await tester.tap(find.text('Cancel upload'));
    await tester.pumpAndSettle();
    // Still on the upload screen — the screen does not navigate itself; it waits
    // for the pipeline to reflect the cancelled state.
    expect(find.text('PROJECTS'), findsNothing);

    // The pipeline reflects the abort.
    await emit(
        tester,
        _p(
            status: UploadStatus.cancelled,
            bytes: 10 * _mb,
            total: 110 * _mb,
            files: 1,
            totalFiles: 10));
    await tester.pumpAndSettle();
    expect(find.text('PROJECTS'), findsOneWidget);
    expect(named(AnalyticsEvents.uploadCancelled), hasLength(1));
  });

  testWidgets('iOS → keep-app-open microcopy shown beside the Wi-Fi hint',
      (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    await pump(tester);
    await emit(
        tester, _p(bytes: 10 * _mb, total: 110 * _mb, files: 1, totalFiles: 10));

    expect(find.byKey(const Key('upload_wifi_hint')), findsOneWidget);
    expect(find.byKey(const Key('upload_keep_open_hint')), findsOneWidget);
    expect(find.text('Keep app open to upload faster'), findsOneWidget);
    // Does not displace the progress bar or counters.
    expect(find.byKey(const Key('upload_progress_bar')), findsOneWidget);
    expect(find.text('1 / 10 files'), findsOneWidget);
    // Reset before the test body ends (the framework's end-of-test invariant
    // check requires the override to be null, and runs before tearDown).
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('Android → keep-app-open microcopy absent (no extra hint)',
      (tester) async {
    // Default test platform is Android.
    await pump(tester);
    await emit(
        tester, _p(bytes: 10 * _mb, total: 110 * _mb, files: 1, totalFiles: 10));

    expect(find.byKey(const Key('upload_wifi_hint')), findsOneWidget);
    expect(find.byKey(const Key('upload_keep_open_hint')), findsNothing);
    expect(find.text('Keep app open to upload faster'), findsNothing);
  });

  testWidgets('fast completion (first emission already completed) advances',
      (tester) async {
    await pump(tester);
    await emit(
        tester,
        _p(
            status: UploadStatus.completed,
            bytes: 5 * _mb,
            total: 5 * _mb,
            files: 2,
            totalFiles: 2));
    await tester.pumpAndSettle();
    expect(find.text('PROCESSING'), findsOneWidget);
    expect(named(AnalyticsEvents.uploadStartedView), hasLength(1));
    expect(named(AnalyticsEvents.uploadCompleted), hasLength(1));
  });
}
