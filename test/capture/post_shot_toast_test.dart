// test/capture/post_shot_toast_test.dart
//
// Widget tests for the post-shot toast: verdict-correct content/CTA, verdict
// auto-dismiss policy (accepted short, warn longer, reject sticky), single
// instance latest-wins, identical re-emit is a no-op (no re-analytics), Retake
// fires once (double-tap guarded) and dismisses, null hides, reduce-motion is
// instant, and disposal mid-sticky is clean.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:recapture/domain/entities/capture_evaluation.dart';
import 'package:recapture/presentation/widgets/post_shot_toast.dart';
import 'package:recapture/utils/analytics.dart';

const _key = ValueKey<String>('toast');

Widget _host(
  CaptureEvaluation? evaluation, {
  VoidCallback? onRetake,
  bool reduceMotion = false,
  Duration accepted = const Duration(milliseconds: 900),
  Duration warn = const Duration(seconds: 3),
  Duration? reject,
}) {
  return MaterialApp(
    // copyWith (not a fresh MediaQueryData) so the real test surface size/padding
    // survive — the toast positions itself as a fraction of screen height.
    home: Builder(
      builder: (ctx) => MediaQuery(
        data: MediaQuery.of(ctx).copyWith(disableAnimations: reduceMotion),
        child: Scaffold(
          body: Stack(
            children: [
              PostShotToast(
                key: _key,
                evaluation: evaluation,
                onRetake: onRetake ?? () {},
                acceptedDuration: accepted,
                warnDuration: warn,
                rejectDuration: reject,
              ),
            ],
          ),
        ),
      ),
    ),
  );
}

CaptureEvaluation _eval(
  String id,
  CaptureVerdict v, {
  List<CaptureIssue> issues = const [],
}) =>
    CaptureEvaluation(captureId: id, verdict: v, issues: issues);

void main() {
  tearDown(() => Analytics.testSink = null);

  testWidgets('accepted: positive title, no Retake, auto-dismisses', (tester) async {
    await tester.pumpWidget(_host(_eval('1', CaptureVerdict.accepted),
        reduceMotion: true));
    await tester.pump(); // run the initial post-frame side effects

    expect(find.text('Captured'), findsOneWidget);
    expect(find.text('Retake'), findsNothing);

    await tester.pump(const Duration(milliseconds: 900));
    await tester.pump();
    expect(find.text('Captured'), findsNothing);
  });

  testWidgets('warn: reason + Retake, dismisses after the longer timeout',
      (tester) async {
    await tester.pumpWidget(_host(
      _eval('1', CaptureVerdict.warn, issues: [CaptureIssue.tooDark]),
      reduceMotion: true,
    ));
    await tester.pump();

    expect(find.text('Too dark'), findsOneWidget);
    expect(find.text('Retake'), findsOneWidget);

    // Still up before the warn timeout…
    await tester.pump(const Duration(seconds: 1));
    expect(find.text('Too dark'), findsOneWidget);

    // …gone after it.
    await tester.pump(const Duration(seconds: 3));
    await tester.pump();
    expect(find.text('Too dark'), findsNothing);
  });

  testWidgets('reject: prominent Retake, sticky (no auto-dismiss)', (tester) async {
    await tester.pumpWidget(_host(
      _eval('1', CaptureVerdict.reject, issues: [CaptureIssue.blurry]),
      reduceMotion: true,
    ));
    await tester.pump();

    expect(find.text('Too blurry'), findsOneWidget);
    expect(find.text('Discarded'), findsOneWidget);
    expect(find.text('Retake'), findsOneWidget);

    // A long wait does not dismiss it.
    await tester.pump(const Duration(seconds: 30));
    expect(find.text('Too blurry'), findsOneWidget);
  });

  testWidgets('Retake fires onRetake once and dismisses; button then gone',
      (tester) async {
    var retakes = 0;
    await tester.pumpWidget(_host(
      _eval('1', CaptureVerdict.reject, issues: [CaptureIssue.blurry]),
      onRetake: () => retakes++,
      reduceMotion: true,
    ));
    await tester.pump();

    await tester.tap(find.text('Retake'));
    await tester.pump();

    expect(retakes, 1);
    expect(find.text('Too blurry'), findsNothing); // dismissed
    // The CTA is gone, so no second tap is even possible (the in-flight guard
    // additionally protects against a same-frame double event).
    expect(find.text('Retake'), findsNothing);
  });

  testWidgets('single instance: a new id replaces the prior toast', (tester) async {
    await tester.pumpWidget(_host(
      _eval('1', CaptureVerdict.reject, issues: [CaptureIssue.blurry]),
      reduceMotion: true,
    ));
    await tester.pump();
    expect(find.text('Too blurry'), findsOneWidget);

    await tester.pumpWidget(_host(
      _eval('2', CaptureVerdict.warn, issues: [CaptureIssue.tooDark]),
      reduceMotion: true,
    ));
    await tester.pump();

    expect(find.text('Too blurry'), findsNothing);
    expect(find.text('Too dark'), findsOneWidget);
  });

  testWidgets('identical re-emit (same id) does not re-fire analytics',
      (tester) async {
    var results = 0;
    Analytics.testSink = (name, _) {
      if (name == AnalyticsEvents.postShotResult) results++;
    };

    final e = _eval('1', CaptureVerdict.warn, issues: [CaptureIssue.tooDark]);
    await tester.pumpWidget(_host(e, reduceMotion: true));
    await tester.pump(); // initial post-frame → 1 result
    expect(results, 1);

    // Re-emit the SAME evaluation (new widget, same captureId) → no new result.
    await tester.pumpWidget(_host(e, reduceMotion: true));
    await tester.pump();
    expect(results, 1);
  });

  testWidgets('null evaluation hides the toast', (tester) async {
    await tester.pumpWidget(_host(
      _eval('1', CaptureVerdict.reject, issues: [CaptureIssue.blurry]),
      reduceMotion: true,
    ));
    await tester.pump();
    expect(find.text('Too blurry'), findsOneWidget);

    await tester.pumpWidget(_host(null, reduceMotion: true));
    await tester.pump();
    expect(find.text('Too blurry'), findsNothing);
  });

  testWidgets('emits post_shot_result with verdict + issue keys', (tester) async {
    Map<String, Object?>? props;
    Analytics.testSink = (name, p) {
      if (name == AnalyticsEvents.postShotResult) props = p;
    };
    await tester.pumpWidget(_host(
      _eval('1', CaptureVerdict.reject,
          issues: [CaptureIssue.blurry, CaptureIssue.tooDark]),
      reduceMotion: true,
    ));
    await tester.pump();

    expect(props?['verdict'], 'reject');
    expect(props?['issues'], ['blurry', 'tooDark']);
  });

  testWidgets('disposed while a sticky reject is up → no error', (tester) async {
    await tester.pumpWidget(_host(
      _eval('1', CaptureVerdict.reject, issues: [CaptureIssue.blurry]),
      reduceMotion: true,
    ));
    await tester.pump();
    await tester.pumpWidget(const MaterialApp(home: Scaffold()));
    await tester.pump();
    expect(tester.takeException(), isNull);
  });
}
