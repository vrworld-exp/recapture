// test/upload/upload_controls_test.dart
//
// The state-dependent Pause / Resume / Cancel buttons. They SIGNAL the upload
// pipeline (a fake UploadController records the signals) and REFLECT the status
// passed in. Covers: state→button mapping, signalling + analytics, the Cancel
// confirmation (confirm vs dismiss, retain-not-delete), wrong-state/double-tap
// guards, and the in-flight re-arm when the pipeline reflects the new state.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:recapture/application/upload/upload_controller.dart';
import 'package:recapture/domain/entities/upload_progress.dart';
import 'package:recapture/presentation/widgets/upload_controls.dart';
import 'package:recapture/utils/analytics.dart';

class _FakeController implements UploadController {
  int pauseCount = 0;
  int resumeCount = 0;
  int cancelCount = 0;
  @override
  void pause() => pauseCount++;
  @override
  void resume() => resumeCount++;
  @override
  void cancel() => cancelCount++;
}

void main() {
  late _FakeController controller;
  late List<({String name, Map<String, Object?> props})> events;

  setUp(() {
    controller = _FakeController();
    events = [];
    Analytics.testSink = (name, props) => events.add((name: name, props: props));
  });
  tearDown(() => Analytics.testSink = null);

  List<({String name, Map<String, Object?> props})> named(String n) =>
      events.where((e) => e.name == n).toList();

  Future<void> pumpControls(
    WidgetTester tester, {
    required UploadStatus status,
    TargetPlatform platform = TargetPlatform.android,
  }) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          uploadControllerProvider.overrideWithValue(controller),
        ],
        child: MaterialApp(
          theme: ThemeData(platform: platform),
          home: Scaffold(
            body: UploadControls(status: status, sessionId: 'sess-1'),
          ),
        ),
      ),
    );
    await tester.pump();
  }

  final pause = find.byKey(const Key('upload_pause'));
  final resume = find.byKey(const Key('upload_resume'));
  final cancel = find.byKey(const Key('upload_cancel'));

  group('state → buttons', () {
    testWidgets('uploading shows Pause + Cancel (no Resume)', (tester) async {
      await pumpControls(tester, status: UploadStatus.inProgress);
      expect(pause, findsOneWidget);
      expect(cancel, findsOneWidget);
      expect(resume, findsNothing);
    });

    testWidgets('paused shows Resume + Cancel (no Pause)', (tester) async {
      await pumpControls(tester, status: UploadStatus.paused);
      expect(resume, findsOneWidget);
      expect(cancel, findsOneWidget);
      expect(pause, findsNothing);
    });

    testWidgets('idle/completed/failed/cancelled show no controls',
        (tester) async {
      for (final s in [
        UploadStatus.idle,
        UploadStatus.completed,
        UploadStatus.failed,
        UploadStatus.cancelled,
      ]) {
        await pumpControls(tester, status: s);
        expect(pause, findsNothing, reason: '$s');
        expect(resume, findsNothing, reason: '$s');
        expect(cancel, findsNothing, reason: '$s');
      }
    });
  });

  testWidgets('Pause signals pipeline.pause() + logs upload_paused',
      (tester) async {
    await pumpControls(tester, status: UploadStatus.inProgress);
    await tester.tap(pause);
    await tester.pump();
    expect(controller.pauseCount, 1);
    expect(controller.resumeCount, 0);
    final e = named(AnalyticsEvents.uploadPaused);
    expect(e, hasLength(1));
    expect(e.first.props['session_id'], 'sess-1');
    expect(e.first.props['phase'], 'upload');
  });

  testWidgets('Resume signals pipeline.resume() + logs upload_resumed',
      (tester) async {
    await pumpControls(tester, status: UploadStatus.paused);
    await tester.tap(resume);
    await tester.pump();
    expect(controller.resumeCount, 1);
    expect(named(AnalyticsEvents.uploadResumed), hasLength(1));
  });

  testWidgets('Cancel → confirm → pipeline.cancel() (retain, not delete) + log',
      (tester) async {
    await pumpControls(tester, status: UploadStatus.inProgress);
    await tester.tap(cancel);
    await tester.pumpAndSettle();
    expect(find.text('Cancel upload?'), findsOneWidget); // confirmation shown
    await tester.tap(find.text('Cancel upload'));
    await tester.pumpAndSettle();

    expect(controller.cancelCount, 1); // transfer aborted (the only API — no delete)
    final e = named(AnalyticsEvents.uploadCancelled);
    expect(e, hasLength(1));
    expect(e.first.props['from_state'], 'uploading');
  });

  testWidgets('Cancel dismissed (Keep uploading) → no abort, no event',
      (tester) async {
    await pumpControls(tester, status: UploadStatus.inProgress);
    await tester.tap(cancel);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Keep uploading'));
    await tester.pumpAndSettle();
    expect(controller.cancelCount, 0);
    expect(named(AnalyticsEvents.uploadCancelled), isEmpty);
  });

  testWidgets('Cancel while paused → allowed, from_state=paused', (tester) async {
    await pumpControls(tester, status: UploadStatus.paused);
    await tester.tap(cancel);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Cancel upload'));
    await tester.pumpAndSettle();
    expect(controller.cancelCount, 1);
    expect(named(AnalyticsEvents.uploadCancelled).first.props['from_state'],
        'paused');
  });

  testWidgets('double-tap Pause signals once (in-flight guard)', (tester) async {
    await pumpControls(tester, status: UploadStatus.inProgress);
    await tester.tap(pause);
    await tester.tap(pause); // before the pipeline reflects paused
    await tester.pump();
    expect(controller.pauseCount, 1);
    expect(named(AnalyticsEvents.uploadPaused), hasLength(1));
  });

  testWidgets('re-arms when the pipeline reflects the new state', (tester) async {
    await pumpControls(tester, status: UploadStatus.inProgress);
    await tester.tap(pause);
    await tester.pump();
    expect(controller.pauseCount, 1);

    // Pipeline reflected paused → controls update in place (didUpdateWidget
    // clears the in-flight latch); Resume is now actionable.
    await pumpControls(tester, status: UploadStatus.paused);
    await tester.tap(resume);
    await tester.pump();
    expect(controller.resumeCount, 1);
  });

  testWidgets('iOS Cancel uses the Cupertino action sheet', (tester) async {
    await pumpControls(tester,
        status: UploadStatus.inProgress, platform: TargetPlatform.iOS);
    await tester.tap(cancel);
    await tester.pumpAndSettle();
    expect(find.text('Cancel upload?'), findsOneWidget);
    expect(find.text('Keep uploading'), findsOneWidget);
    await tester.tap(find.text('Cancel upload'));
    await tester.pumpAndSettle();
    expect(controller.cancelCount, 1);
  });
}
