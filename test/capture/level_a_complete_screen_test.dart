// test/capture/level_a_complete_screen_test.dart
//
// Widget tests for the Level A completion screen: renders the summary numbers,
// montage shows/hides + falls back for bad files, CTAs fire (debounced to a
// single intent), Level-B-disabled note, reduce-motion is static, and the
// shown/action analytics fire.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:recapture/domain/entities/capture_thumbnail.dart';
import 'package:recapture/domain/entities/level_a_summary.dart';
import 'package:recapture/presentation/screens/capture/level_a_complete_screen.dart';
import 'package:recapture/utils/analytics.dart';

Future<void> _pump(
  WidgetTester tester, {
  required LevelASummary summary,
  VoidCallback? onStartLevelB,
  VoidCallback? onReview,
  VoidCallback? onDoneExit,
  bool startLevelBEnabled = true,
  bool reduceMotion = false,
}) async {
  await tester.pumpWidget(
    ProviderScope(
      child: MaterialApp(
        home: Builder(
          builder: (ctx) => MediaQuery(
            data: MediaQuery.of(ctx).copyWith(disableAnimations: reduceMotion),
            child: LevelACompleteScreen(
              summary: summary,
              onStartLevelB: onStartLevelB ?? () {},
              onReview: onReview ?? () {},
              onDoneExit: onDoneExit,
              startLevelBEnabled: startLevelBEnabled,
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pump();
}

const _summary = LevelASummary(
  accepted: 12,
  target: 12,
  coveragePct: 68,
  rejected: 2,
);

void main() {
  tearDown(() => Analytics.testSink = null);

  testWidgets('renders summary numbers + actions', (tester) async {
    await _pump(tester, summary: _summary, reduceMotion: true);
    expect(find.text('Level A complete'), findsOneWidget);
    expect(find.text('12/12'), findsOneWidget);
    expect(find.text('68%'), findsOneWidget);
    expect(find.text('2'), findsOneWidget); // discarded
    expect(find.text('Start Level B'), findsOneWidget);
    expect(find.text('Review'), findsOneWidget);
  });

  testWidgets('over-target count displays real numbers', (tester) async {
    await _pump(
      tester,
      summary: const LevelASummary(accepted: 14, target: 12, coveragePct: 100),
      reduceMotion: true,
    );
    expect(find.text('14/12'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('no highlights → montage hidden, no broken tiles', (tester) async {
    await _pump(tester, summary: _summary, reduceMotion: true);
    expect(find.byType(Image), findsNothing);
  });

  testWidgets('highlights with a bad path fall back gracefully', (tester) async {
    final summary = LevelASummary(
      accepted: 12,
      target: 12,
      coveragePct: 90,
      highlights: [
        CaptureThumbnail(
            id: 'a', filePath: '/nope/a.jpg', capturedAt: DateTime(2026)),
        CaptureThumbnail(
            id: 'b', filePath: '/nope/b.jpg', capturedAt: DateTime(2026)),
      ],
    );
    await _pump(tester, summary: summary, reduceMotion: true);
    await tester.pump(const Duration(milliseconds: 50));
    // Both tiles render (montage shown) and nothing crashes on the bad files;
    // each tile has an errorBuilder fallback so no red error box appears.
    expect(find.byType(Image), findsNWidgets(2));
    expect(tester.takeException(), isNull);
  });

  testWidgets('rejected == 0 hides the discarded row', (tester) async {
    await _pump(
      tester,
      summary: const LevelASummary(accepted: 12, target: 12, coveragePct: 90),
      reduceMotion: true,
    );
    expect(find.text('Discarded'), findsNothing);
  });

  testWidgets('CTAs fire their callbacks', (tester) async {
    var b = 0, r = 0, d = 0;
    await _pump(
      tester,
      summary: _summary,
      onStartLevelB: () => b++,
      onReview: () => r++,
      onDoneExit: () => d++,
      reduceMotion: true,
    );
    await tester.tap(find.text('Review'));
    await tester.pump();
    expect(r, 1);
    expect(b, 0);
    expect(d, 0);
  });

  testWidgets('double-tap a CTA fires a single intent', (tester) async {
    var b = 0;
    await _pump(
      tester,
      summary: _summary,
      onStartLevelB: () => b++,
      reduceMotion: true,
    );
    await tester.tap(find.text('Start Level B'));
    await tester.tap(find.text('Start Level B'));
    await tester.pump();
    expect(b, 1);
  });

  testWidgets('once one CTA fires, others are guarded', (tester) async {
    var b = 0, r = 0;
    await _pump(
      tester,
      summary: _summary,
      onStartLevelB: () => b++,
      onReview: () => r++,
      reduceMotion: true,
    );
    await tester.tap(find.text('Start Level B'));
    await tester.tap(find.text('Review'));
    await tester.pump();
    expect(b, 1);
    expect(r, 0); // guarded after the first dispatch
  });

  testWidgets('Done shows only when onDoneExit provided', (tester) async {
    await _pump(tester, summary: _summary, reduceMotion: true);
    expect(find.text('Done'), findsNothing);

    await _pump(
      tester,
      summary: _summary,
      onDoneExit: () {},
      reduceMotion: true,
    );
    expect(find.text('Done'), findsOneWidget);
  });

  testWidgets('Level B disabled → button disabled + note', (tester) async {
    var b = 0;
    await _pump(
      tester,
      summary: _summary,
      onStartLevelB: () => b++,
      startLevelBEnabled: false,
      reduceMotion: true,
    );
    expect(find.text('Level B is coming soon.'), findsOneWidget);
    await tester.tap(find.text('Start Level B'));
    await tester.pump();
    expect(b, 0); // disabled, no intent
  });

  testWidgets('emits capture_level_completed on show + action on tap',
      (tester) async {
    final events = <String, Map<String, Object?>>{};
    Analytics.testSink = (name, props) => events[name] = props;
    await _pump(tester, summary: _summary, reduceMotion: true);

    final shown = events[AnalyticsEvents.captureLevelCompleted];
    expect(shown?['level'], 'A');
    expect(shown?['accepted'], 12);
    expect(shown?['target'], 12);
    expect(shown?['coverage_pct'], 68);
    expect(shown?['rejected'], 2);
    // No session was started in this isolated test → opaque-empty id + 0 duration,
    // never a missing/NaN field.
    expect(shown?['session_id'], '');
    expect(shown?['duration_seconds'], 0);

    await tester.tap(find.text('Review'));
    await tester.pump();
    expect(events[AnalyticsEvents.levelACompleteAction]?['action'], 'review');
  });
}
