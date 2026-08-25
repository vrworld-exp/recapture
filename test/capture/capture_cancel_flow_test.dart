// test/capture/capture_cancel_flow_test.dart
//
// The "Cancel → Keep as Draft" leave-flow wired into the Capture Summary and
// Uploading screens. Verifies the safety contract:
//   • Cancel / system-back opens the confirmation (never a silent exit).
//   • Keep as Draft persists then leaves ONLY on a successful save; a failed save
//     keeps the user + data in place with an error and NO kept-draft analytics.
//   • Discard is the ONLY deletion path.
//   • Keep editing returns unchanged.
//   • Cancel during an active upload aborts the transfer first (idempotently).
//   • Double invocation opens/acts once.
//   • Analytics fire with the right phase / upload_in_progress.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:recapture/app/routes/app_router.dart';
import 'package:recapture/application/capture/cancel/capture_cancel_controller.dart';
import 'package:recapture/application/capture/ledger/captured_photo_record.dart';
import 'package:recapture/application/capture/ledger/level_capture_ledger_registry.dart';
import 'package:recapture/application/capture/ledger/level_capture_ledger_registry_provider.dart';
import 'package:recapture/application/config/config_notifier.dart';
import 'package:recapture/application/upload/upload_controller.dart';
import 'package:recapture/application/upload/upload_progress_provider.dart';
import 'package:recapture/domain/entities/capture_config.dart';
import 'package:recapture/domain/entities/upload_progress.dart';
import 'package:recapture/presentation/screens/capture/capture_summary_screen.dart';
import 'package:recapture/presentation/screens/capture/uploading_screen.dart';
import 'package:recapture/utils/analytics.dart';

class _StubConfigNotifier extends ConfigNotifier {
  @override
  CaptureConfig build() => CaptureConfig.bundledDefault;
}

/// Records the cancel-flow DATA operations and can simulate a save failure /
/// absent project.
class _FakeCancelController implements CaptureCancelController {
  _FakeCancelController({this.projectId = 'p1', this.saveOk = true});

  final String? projectId;
  final bool saveOk;
  int keepCalls = 0;
  int discardCalls = 0;

  @override
  Future<String?> activeProjectId() async => projectId;

  @override
  Future<bool> keepAsDraft(String id) async {
    keepCalls++;
    return saveOk;
  }

  @override
  Future<void> discard(String id) async {
    discardCalls++;
  }
}

/// Records upload-abort signals; the abort must be idempotent/safe to repeat.
class _RecordingUploadController implements UploadController {
  int cancels = 0;
  @override
  void pause() {}
  @override
  void resume() {}
  @override
  void cancel() => cancels++;
}

class _FakeSource implements UploadProgressSource {
  _FakeSource(this.controller);
  final StreamController<UploadProgress> controller;
  @override
  Stream<UploadProgress> watch() => controller.stream;
}

CapturedPhotoRecord _accepted(int seg, String path) => CapturedPhotoRecord(
      segmentIndex: seg,
      framePath: path,
      blurScore: 100,
      meanLuminance: 128,
      yawDegrees: 0,
      pitchDegrees: 0,
      sensorTimestampNs: seg * 1000 + 1,
    );

void main() {
  late List<({String name, Map<String, Object?> props})> events;

  setUp(() {
    events = [];
    Analytics.testSink = (name, props) => events.add((name: name, props: props));
  });
  tearDown(() => Analytics.testSink = null);

  List<({String name, Map<String, Object?> props})> named(String name) =>
      events.where((e) => e.name == name).toList();

  // A registry with every level complete (so the screen is a happy summary).
  LevelCaptureLedgerRegistry completeRegistry() {
    final reg = LevelCaptureLedgerRegistry();
    for (final entry in {'mid': 8, 'high': 7, 'low': 10}.entries) {
      final ledger = reg.ledgerFor(entry.key);
      for (var i = 0; i < entry.value; i++) {
        ledger.recordAccepted(_accepted(i, '/${entry.key}/$i.jpg'));
      }
    }
    return reg;
  }

  // ── Capture Summary screen ────────────────────────────────────────────────
  Future<void> pumpSummary(
    WidgetTester tester,
    CaptureCancelController cancel,
  ) async {
    Widget stub(String l) => Scaffold(body: Text(l));
    final router = GoRouter(
      initialLocation: AppRoutes.captureSummary,
      routes: [
        GoRoute(
            path: AppRoutes.captureSummary,
            builder: (_, __) => const CaptureSummaryScreen()),
        GoRoute(path: AppRoutes.uploading, builder: (_, __) => stub('UPLOADING')),
        GoRoute(path: AppRoutes.projects, builder: (_, __) => stub('PROJECTS')),
        GoRoute(
            path: AppRoutes.levelACapture, builder: (_, __) => stub('CAP A')),
        GoRoute(
            path: AppRoutes.levelBCapture, builder: (_, __) => stub('CAP B')),
        GoRoute(
            path: AppRoutes.levelCCapture, builder: (_, __) => stub('CAP C')),
        GoRoute(path: AppRoutes.levelAReview, builder: (_, __) => stub('REV A')),
        GoRoute(path: AppRoutes.levelBReview, builder: (_, __) => stub('REV B')),
        GoRoute(path: AppRoutes.levelCReview, builder: (_, __) => stub('REV C')),
      ],
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          levelCaptureLedgerRegistryProvider.overrideWithValue(completeRegistry()),
          captureConfigProvider.overrideWith(_StubConfigNotifier.new),
          captureCancelControllerProvider.overrideWithValue(cancel),
        ],
        child: MaterialApp.router(routerConfig: router),
      ),
    );
    await tester.pump();
  }

  testWidgets('Cancel opens the confirmation + capture_cancel_opened',
      (tester) async {
    await pumpSummary(tester, _FakeCancelController());
    await tester.tap(find.byKey(const Key('summary_cancel')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('capture_cancel_dialog')), findsOneWidget);
    final opened = named(AnalyticsEvents.captureCancelOpened);
    expect(opened, hasLength(1));
    expect(opened.first.props['phase'], 'capture_summary');
    expect(opened.first.props['upload_in_progress'], false);
  });

  testWidgets('Keep as Draft (save ok) → persists then exits to projects',
      (tester) async {
    final ctrl = _FakeCancelController(saveOk: true);
    await pumpSummary(tester, ctrl);
    await tester.tap(find.byKey(const Key('summary_cancel')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('cancel_keep_draft')));
    await tester.pumpAndSettle();

    expect(find.text('PROJECTS'), findsOneWidget);
    expect(ctrl.keepCalls, 1);
    expect(ctrl.discardCalls, 0); // draft NEVER deletes
    expect(named(AnalyticsEvents.captureCancelKeptDraft), hasLength(1));
    expect(named(AnalyticsEvents.captureCancelKeptDraft).first.props['phase'],
        'capture_summary');
  });

  testWidgets('Keep as Draft (save FAILS) → stays, error, no kept-draft event',
      (tester) async {
    final ctrl = _FakeCancelController(saveOk: false);
    await pumpSummary(tester, ctrl);
    await tester.tap(find.byKey(const Key('summary_cancel')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('cancel_keep_draft')));
    await tester.pumpAndSettle();

    // Did NOT leave; data not deleted; error surfaced; retry possible.
    expect(find.text('PROJECTS'), findsNothing);
    expect(find.text('Capture summary'), findsOneWidget);
    expect(find.byKey(const Key('cancel_save_error')), findsOneWidget);
    expect(ctrl.discardCalls, 0);
    expect(named(AnalyticsEvents.captureCancelKeptDraft), isEmpty);

    // Re-arm: the flow released its single-flight latch, so the confirmation can
    // be opened again (drive it via system back to avoid the error SnackBar that
    // overlays the bottom Cancel button).
    final popScope = tester.widget<PopScope>(
        find.byKey(const Key('summary_cancel_popscope')));
    popScope.onPopInvokedWithResult!(false, null);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('capture_cancel_dialog')), findsOneWidget);
  });

  testWidgets('Keep as Draft with no project (empty session) → leaves safely',
      (tester) async {
    // Nothing captured to a project → nothing to persist or lose; leaving directly
    // is safe and never crashes on an empty draft save.
    final ctrl = _FakeCancelController(projectId: null);
    await pumpSummary(tester, ctrl);
    await tester.tap(find.byKey(const Key('summary_cancel')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('cancel_keep_draft')));
    await tester.pumpAndSettle();

    expect(find.text('PROJECTS'), findsOneWidget);
    expect(ctrl.keepCalls, 0); // no project → no save attempted
    expect(named(AnalyticsEvents.captureCancelKeptDraft), hasLength(1));
  });

  testWidgets('Discard → deletes then exits (only deletion path)',
      (tester) async {
    final ctrl = _FakeCancelController();
    await pumpSummary(tester, ctrl);
    await tester.tap(find.byKey(const Key('summary_cancel')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('cancel_discard')));
    await tester.pumpAndSettle();

    expect(find.text('PROJECTS'), findsOneWidget);
    expect(ctrl.discardCalls, 1);
    expect(ctrl.keepCalls, 0);
    expect(named(AnalyticsEvents.captureCancelDiscarded), hasLength(1));
  });

  testWidgets('Keep editing → returns unchanged, no data ops', (tester) async {
    final ctrl = _FakeCancelController();
    await pumpSummary(tester, ctrl);
    await tester.tap(find.byKey(const Key('summary_cancel')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('cancel_keep_editing')));
    await tester.pumpAndSettle();

    expect(find.text('Capture summary'), findsOneWidget);
    expect(find.byKey(const Key('capture_cancel_dialog')), findsNothing);
    expect(ctrl.keepCalls, 0);
    expect(ctrl.discardCalls, 0);
    expect(named(AnalyticsEvents.captureCancelDismissed), hasLength(1));
  });

  testWidgets('system back routes through the same confirmation', (tester) async {
    await pumpSummary(tester, _FakeCancelController());
    // The screen blocks the pop and funnels through the cancel flow.
    final popScope = tester.widget<PopScope>(
        find.byKey(const Key('summary_cancel_popscope')));
    expect(popScope.canPop, isFalse);
    popScope.onPopInvokedWithResult!(false, null);
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('capture_cancel_dialog')), findsOneWidget);
    expect(named(AnalyticsEvents.captureCancelOpened), hasLength(1));
  });

  testWidgets('double-tap Cancel opens one confirmation', (tester) async {
    await pumpSummary(tester, _FakeCancelController());
    final btn = find.byKey(const Key('summary_cancel'));
    await tester.tap(btn, warnIfMissed: false);
    await tester.tap(btn, warnIfMissed: false);
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('capture_cancel_dialog')), findsOneWidget);
    expect(named(AnalyticsEvents.captureCancelOpened), hasLength(1));
  });

  // ── Uploading screen (cancel during an active upload) ─────────────────────
  Future<StreamController<UploadProgress>> pumpUploading(
    WidgetTester tester, {
    required CaptureCancelController cancel,
    required UploadController upload,
  }) async {
    final controller = StreamController<UploadProgress>.broadcast();
    addTearDown(controller.close);
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
      ],
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          uploadProgressSourceProvider.overrideWithValue(_FakeSource(controller)),
          uploadControllerProvider.overrideWithValue(upload),
          captureCancelControllerProvider.overrideWithValue(cancel),
        ],
        child: MaterialApp.router(routerConfig: router),
      ),
    );
    await tester.pump();
    return controller;
  }

  Future<void> emit(WidgetTester tester,
      StreamController<UploadProgress> c, UploadProgress p) async {
    c.add(p);
    await tester.pump();
    await tester.pump();
  }

  UploadProgress inProgress() => const UploadProgress(
        status: UploadStatus.inProgress,
        bytesUploaded: 10,
        totalBytes: 100,
        filesUploaded: 1,
        totalFiles: 10,
      );

  testWidgets('Cancel during upload → aborts transfer, then confirms',
      (tester) async {
    final upload = _RecordingUploadController();
    final c = await pumpUploading(tester,
        cancel: _FakeCancelController(), upload: upload);
    await emit(tester, c, inProgress());

    await tester.tap(find.byKey(const Key('upload_leave')));
    await tester.pumpAndSettle();

    // Transfer aborted BEFORE the confirmation resolved.
    expect(upload.cancels, 1);
    expect(find.byKey(const Key('capture_cancel_dialog')), findsOneWidget);
    final opened = named(AnalyticsEvents.captureCancelOpened);
    expect(opened, hasLength(1));
    expect(opened.first.props['phase'], 'upload');
    expect(opened.first.props['upload_in_progress'], true);
  });

  testWidgets('cancelled reflected while confirming does NOT auto-exit',
      (tester) async {
    final upload = _RecordingUploadController();
    final c = await pumpUploading(tester,
        cancel: _FakeCancelController(), upload: upload);
    await emit(tester, c, inProgress());
    await tester.tap(find.byKey(const Key('upload_leave')));
    await tester.pumpAndSettle();

    // Pipeline reflects the abort WHILE the confirmation is open — the flow owns
    // the exit, so the screen must not auto-navigate out from under the dialog.
    await emit(tester, c, inProgress().copyWith(status: UploadStatus.cancelled));
    expect(find.text('PROJECTS'), findsNothing);
    expect(find.byKey(const Key('capture_cancel_dialog')), findsOneWidget);

    // Keep editing → stays on the upload screen (no navigation).
    await tester.tap(find.byKey(const Key('cancel_keep_editing')));
    await tester.pumpAndSettle();
    expect(find.text('PROJECTS'), findsNothing);
    expect(named(AnalyticsEvents.captureCancelDismissed), hasLength(1));
  });

  testWidgets('Keep as Draft on upload → phase=upload, exits', (tester) async {
    final ctrl = _FakeCancelController();
    final c = await pumpUploading(tester,
        cancel: ctrl, upload: _RecordingUploadController());
    await emit(tester, c, inProgress());
    await tester.tap(find.byKey(const Key('upload_leave')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('cancel_keep_draft')));
    await tester.pumpAndSettle();

    expect(find.text('PROJECTS'), findsOneWidget);
    expect(ctrl.keepCalls, 1);
    final kept = named(AnalyticsEvents.captureCancelKeptDraft);
    expect(kept, hasLength(1));
    expect(kept.first.props['phase'], 'upload');
  });
}
