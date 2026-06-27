// test/capture/level_review_grid_screen_test.dart
//
// Screen 7A/7B/7C — the in-flow review screen is the SAME level-parameterized
// LevelReviewGridScreen, feeding the shared rich ReviewGridScreen with the REAL
// captured frames from the per-level ledger. Verifies: the heading + real frames
// render for a seeded level; `review_grid_viewed` fires once with the level + the
// actual verdict tallies; Proceed emits `review_action(proceed)` and advances;
// Back to Capture emits `review_action(back_to_capture)`; and a per-tile Retake
// emits `review_action(retake)` with the frame id and navigates to capture.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:recapture/app/routes/app_router.dart';
import 'package:recapture/application/capture/ledger/captured_photo_record.dart';
import 'package:recapture/application/capture/ledger/level_capture_ledger_registry.dart';
import 'package:recapture/application/capture/ledger/level_capture_ledger_registry_provider.dart';
import 'package:recapture/application/capture/ledger/warned_photo_record.dart';
import 'package:recapture/presentation/screens/capture/level_review_grid_screen.dart';
import 'package:recapture/utils/analytics.dart';

CapturedPhotoRecord _accepted(int seg, String path, int ts) =>
    CapturedPhotoRecord(
      segmentIndex: seg,
      framePath: path,
      blurScore: 100,
      meanLuminance: 128,
      yawDegrees: 0,
      pitchDegrees: 0,
      sensorTimestampNs: ts,
    );

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

  /// A registry seeded for Level B ('high' band): 3 accepted, the 3rd also warned.
  LevelCaptureLedgerRegistry seededRegistry() {
    final reg = LevelCaptureLedgerRegistry();
    final ledger = reg.ledgerFor('high');
    ledger.recordAccepted(_accepted(0, '/frames/0.jpg', 1000));
    ledger.recordAccepted(_accepted(1, '/frames/1.jpg', 2000));
    ledger.recordAccepted(_accepted(2, '/frames/2.jpg', 3000));
    ledger.recordWarned(const WarnedPhotoRecord(
      framePath: '/frames/2.jpg',
      isUnderexposed: true,
      isOverexposed: false,
      meanLuminance: 20,
      sensorTimestampNs: 3000,
    ));
    return reg;
  }

  Future<void> pump(
    WidgetTester tester, {
    required String levelLabel,
    required String levelName,
    LevelCaptureLedgerRegistry? registry,
  }) async {
    final reg = registry ?? seededRegistry();
    final router = GoRouter(
      initialLocation: '/review',
      routes: [
        GoRoute(
          path: '/review',
          builder: (_, __) => LevelReviewGridScreen(
            levelLabel: levelLabel,
            levelName: levelName,
            nextRoute: '/next',
          ),
        ),
        GoRoute(
          path: '/next',
          builder: (_, __) => const Scaffold(body: Text('NEXT SCREEN')),
        ),
        // Stub capture route a per-tile Retake navigates to (real path constant).
        GoRoute(
          path: AppRoutes.levelBCapture,
          builder: (_, __) => const Scaffold(body: Text('CAPTURE SCREEN')),
        ),
      ],
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          levelCaptureLedgerRegistryProvider.overrideWithValue(reg),
        ],
        child: MaterialApp.router(routerConfig: router),
      ),
    );
    await tester.pump();
  }

  testWidgets('renders heading + real frames + viewed analytics (level=B)',
      (tester) async {
    await pump(tester, levelLabel: 'B', levelName: 'Top Ring');

    expect(find.text('Review: Top Ring'), findsOneWidget);
    // Three real captured frames → three tiles keyed by their framePath ids.
    expect(find.byKey(const ValueKey<String>('/frames/0.jpg')), findsOneWidget);
    expect(find.byKey(const ValueKey<String>('/frames/2.jpg')), findsOneWidget);

    final viewed = named(AnalyticsEvents.reviewGridViewed);
    expect(viewed, hasLength(1));
    expect(viewed.first.props['level'], 'B');
    expect(viewed.first.props['total'], 3);
    expect(viewed.first.props['accepted'], 2);
    expect(viewed.first.props['warned'], 1);
    expect(viewed.first.props['rejected'], 0);
  });

  testWidgets('viewed fires once (not on rebuild)', (tester) async {
    await pump(tester, levelLabel: 'B', levelName: 'Top Ring');
    await tester.pump();
    await tester.pump();
    expect(named(AnalyticsEvents.reviewGridViewed), hasLength(1));
  });

  testWidgets('empty ledger renders the empty state (no frames)', (tester) async {
    await pump(
      tester,
      levelLabel: 'C',
      levelName: 'Low Ring',
      registry: LevelCaptureLedgerRegistry(), // nothing captured
    );
    expect(find.text('No captures yet'), findsOneWidget);
    final viewed = named(AnalyticsEvents.reviewGridViewed);
    expect(viewed.first.props['level'], 'C');
    expect(viewed.first.props['total'], 0);
  });

  testWidgets('Proceed: review_action(proceed, level=B) + advances', (tester) async {
    await pump(tester, levelLabel: 'B', levelName: 'Top Ring');

    await tester.tap(find.byKey(const Key('review_confirm')));
    await tester.pumpAndSettle();

    final action = named(AnalyticsEvents.reviewAction);
    expect(action, hasLength(1));
    expect(action.first.props['action'], 'proceed');
    expect(action.first.props['level'], 'B');
    expect(find.text('NEXT SCREEN'), findsOneWidget);
  });

  testWidgets('Proceed double-tap navigates once', (tester) async {
    await pump(tester, levelLabel: 'B', levelName: 'Top Ring');

    final confirm = find.byKey(const Key('review_confirm'));
    await tester.tap(confirm, warnIfMissed: false);
    await tester.tap(confirm, warnIfMissed: false);
    await tester.pumpAndSettle();

    // Guard: exactly one proceed action despite two taps.
    expect(named(AnalyticsEvents.reviewAction), hasLength(1));
    expect(find.text('NEXT SCREEN'), findsOneWidget);
  });

  testWidgets('Back to Capture: review_action(back_to_capture, level=B)',
      (tester) async {
    await pump(tester, levelLabel: 'B', levelName: 'Top Ring');

    await tester.tap(find.byKey(const Key('review_back_to_capture')));
    await tester.pump();

    final action = named(AnalyticsEvents.reviewAction);
    expect(action, hasLength(1));
    expect(action.first.props['action'], 'back_to_capture');
    expect(action.first.props['level'], 'B');
    // Nothing to pop at the initial route → stays on review, no crash.
    expect(find.text('Review: Top Ring'), findsOneWidget);
  });

  testWidgets('per-tile Retake: review_action(retake) + frame_id + navigates',
      (tester) async {
    await pump(tester, levelLabel: 'B', levelName: 'Top Ring');

    await tester.tap(find.byKey(const Key('review_retake_/frames/1.jpg')));
    await tester.pumpAndSettle();

    final action = named(AnalyticsEvents.reviewAction);
    expect(action, hasLength(1));
    expect(action.first.props['action'], 'retake');
    expect(action.first.props['level'], 'B');
    expect(action.first.props['frame_id'], '/frames/1.jpg');
    expect(find.text('CAPTURE SCREEN'), findsOneWidget);
  });
}
