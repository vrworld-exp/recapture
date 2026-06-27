// test/capture/level_complete_screen_test.dart
//
// Generic per-level completion interstitial (Screen 6B/6C-Complete). Verifies the
// Level A parity added to the wired B/C screen: renders "Level B complete" +
// summary + "Start Level C"/"Review Top Ring"; emits the canonical level-tagged
// capture_level_completed ONCE on view (the funnel's only completed event for
// B/C); logs level_complete_action on each CTA; guards a rapid double-tap to a
// single navigation; and parameterizes correctly for the last (Level C) instance.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:recapture/presentation/screens/capture/level_complete_screen.dart';
import 'package:recapture/utils/analytics.dart';

void main() {
  late List<({String name, Map<String, Object?> props})> events;

  setUp(() {
    events = [];
    Analytics.testSink = (name, props) => events.add((name: name, props: props));
  });

  tearDown(() {
    Analytics.testSink = null;
  });

  List<({String name, Map<String, Object?> props})> named(String name) =>
      events.where((e) => e.name == name).toList();

  Future<void> pump(
    WidgetTester tester, {
    String levelLabel = 'B',
    String levelName = 'Top Ring',
    int photosAccepted = 32,
    int coveragePercent = 87,
    int warningsCount = 1,
    String nextLabel = 'Start Level C',
  }) async {
    final router = GoRouter(
      initialLocation: '/complete',
      routes: [
        GoRoute(
          path: '/complete',
          builder: (_, __) => LevelCompleteScreen(
            levelLabel: levelLabel,
            levelName: levelName,
            photosAccepted: photosAccepted,
            coveragePercent: coveragePercent,
            warningsCount: warningsCount,
            nextRoute: '/next',
            nextLabel: nextLabel,
            reviewRoute: '/review',
          ),
        ),
        GoRoute(
          path: '/next',
          builder: (_, __) => const Scaffold(body: Text('NEXT SCREEN')),
        ),
        GoRoute(
          path: '/review',
          builder: (_, __) => const Scaffold(body: Text('REVIEW SCREEN')),
        ),
      ],
    );
    await tester.pumpWidget(
      ProviderScope(child: MaterialApp.router(routerConfig: router)),
    );
    await tester.pump();
  }

  testWidgets('renders "Level B complete" + summary + both CTAs', (tester) async {
    await pump(tester);
    expect(find.text('Level B complete'), findsOneWidget);
    expect(find.text('32 / 36'), findsOneWidget);
    expect(find.text('87%'), findsOneWidget);
    expect(find.text('Start Level C'), findsOneWidget);
    expect(find.text('Review Top Ring'), findsOneWidget);
  });

  testWidgets('emits canonical capture_level_completed once, level=B',
      (tester) async {
    await pump(tester);
    final completed = named(AnalyticsEvents.captureLevelCompleted);
    expect(completed, hasLength(1));
    expect(completed.first.props['level'], 'B');
    expect(completed.first.props['accepted'], 32);
    expect(completed.first.props['target'], 36);
    expect(completed.first.props['coverage_pct'], 87);
    expect(completed.first.props['rejected'], 0);
  });

  testWidgets('Start Level C: one action + advance to nextRoute', (tester) async {
    await pump(tester);
    await tester.tap(find.text('Start Level C'));
    await tester.pumpAndSettle();

    final action = named(AnalyticsEvents.levelCompleteAction);
    expect(action, hasLength(1));
    expect(action.first.props['action'], 'start_next');
    expect(action.first.props['level'], 'B');
    expect(find.text('NEXT SCREEN'), findsOneWidget);
  });

  testWidgets('rapid double-tap on Start advances once (single action)',
      (tester) async {
    await pump(tester);
    await tester.tap(find.text('Start Level C'), warnIfMissed: false);
    await tester.tap(find.text('Start Level C'), warnIfMissed: false);
    await tester.pumpAndSettle();

    expect(named(AnalyticsEvents.levelCompleteAction), hasLength(1));
    expect(find.text('NEXT SCREEN'), findsOneWidget);
  });

  testWidgets('Review Top Ring: pushes the review route, action logged',
      (tester) async {
    await pump(tester);
    await tester.tap(find.text('Review Top Ring'));
    await tester.pumpAndSettle();

    final action = named(AnalyticsEvents.levelCompleteAction);
    expect(action, hasLength(1));
    expect(action.first.props['action'], 'review');
    expect(find.text('REVIEW SCREEN'), findsOneWidget);
  });

  testWidgets('last-level (C) instance: "Continue" + level=C completed event',
      (tester) async {
    await pump(
      tester,
      levelLabel: 'C',
      levelName: 'Low Ring',
      nextLabel: 'Continue',
    );
    expect(find.text('Level C complete'), findsOneWidget);
    expect(find.text('Continue'), findsOneWidget);
    expect(find.text('Review Low Ring'), findsOneWidget);
    expect(named(AnalyticsEvents.captureLevelCompleted).first.props['level'], 'C');
  });
}
