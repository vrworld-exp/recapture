// test/capture/capture_summary_screen_test.dart
//
// Screen 6C-Complete — the terminal "Capture complete" summary. Verifies: heading;
// one card per configured level (A/B/C) with real per-level frame counts + status
// from the ledger; Continue is gated (disabled + reason) until every level has
// frames, and advances to uploading when all complete; global + per-card Review
// route to the review grids; and the view/CTA analytics fire with correct props.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:recapture/app/routes/app_router.dart';
import 'package:recapture/application/capture/ledger/captured_photo_record.dart';
import 'package:recapture/application/capture/ledger/level_capture_ledger_registry.dart';
import 'package:recapture/application/capture/ledger/level_capture_ledger_registry_provider.dart';
import 'package:recapture/application/config/config_notifier.dart';
import 'package:recapture/domain/entities/capture_config.dart';
import 'package:recapture/presentation/screens/capture/capture_summary_screen.dart';
import 'package:recapture/utils/analytics.dart';

/// Serves the bundled default synchronously (no remote bootstrap timer) so the
/// gate's config read resolves without an async config fetch in widget tests.
class _StubConfigNotifier extends ConfigNotifier {
  @override
  CaptureConfig build() => CaptureConfig.bundledDefault;
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

  /// Registry seeded with frames for the given band ids.
  LevelCaptureLedgerRegistry registryWith(Map<String, int> framesPerBand) {
    final reg = LevelCaptureLedgerRegistry();
    framesPerBand.forEach((band, n) {
      final ledger = reg.ledgerFor(band);
      for (var i = 0; i < n; i++) {
        ledger.recordAccepted(_accepted(i, '/$band/$i.jpg'));
      }
    });
    return reg;
  }

  Future<void> pump(WidgetTester tester, LevelCaptureLedgerRegistry reg) async {
    Widget stub(String label) => Scaffold(body: Text(label));
    final router = GoRouter(
      initialLocation: AppRoutes.captureSummary,
      routes: [
        GoRoute(
          path: AppRoutes.captureSummary,
          builder: (_, __) => const CaptureSummaryScreen(),
        ),
        GoRoute(path: AppRoutes.uploading, builder: (_, __) => stub('UPLOADING')),
        GoRoute(
            path: AppRoutes.levelAReview, builder: (_, __) => stub('REVIEW A')),
        GoRoute(
            path: AppRoutes.levelBReview, builder: (_, __) => stub('REVIEW B')),
        GoRoute(
            path: AppRoutes.levelCReview, builder: (_, __) => stub('REVIEW C')),
      ],
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          levelCaptureLedgerRegistryProvider.overrideWithValue(reg),
          captureConfigProvider.overrideWith(_StubConfigNotifier.new),
        ],
        child: MaterialApp.router(routerConfig: router),
      ),
    );
    await tester.pump();
  }

  testWidgets('heading + one card per level with real counts/status',
      (tester) async {
    await pump(tester, registryWith({'mid': 3, 'high': 2, 'low': 4}));

    expect(find.text('Capture complete'), findsOneWidget);
    expect(find.text('Level A • Eye Ring'), findsOneWidget);
    expect(find.text('Level B • Top Ring'), findsOneWidget);
    expect(find.text('Level C • Low Ring'), findsOneWidget);
    expect(find.text('3 frames'), findsOneWidget);
    expect(find.text('2 frames'), findsOneWidget);
    expect(find.text('4 frames'), findsOneWidget);
    // All complete → three "Complete" chips, no gate reason.
    expect(find.text('Complete'), findsNWidgets(3));
    expect(find.byKey(const Key('continue_gate_reason')), findsNothing);
  });

  testWidgets('viewed analytics: levels_complete/total', (tester) async {
    await pump(tester, registryWith({'mid': 1, 'high': 1, 'low': 0}));
    final viewed = named(AnalyticsEvents.captureSummaryViewed);
    expect(viewed, hasLength(1));
    expect(viewed.first.props['phase'], 'guided_capture');
    expect(viewed.first.props['levels_total'], 3);
    expect(viewed.first.props['levels_complete'], 2);
  });

  testWidgets('incomplete level → card shows incomplete + Continue gated',
      (tester) async {
    await pump(tester, registryWith({'mid': 2, 'high': 2, 'low': 0}));

    expect(find.text('No frames captured'), findsOneWidget);
    expect(find.text('Incomplete'), findsOneWidget);
    expect(find.byKey(const Key('continue_gate_reason')), findsOneWidget);

    // Tapping the disabled Continue does nothing — no action, no nav.
    await tester.tap(find.byKey(const Key('summary_continue')));
    await tester.pump();
    expect(named(AnalyticsEvents.captureSummaryAction), isEmpty);
    expect(find.text('Capture complete'), findsOneWidget);
  });

  testWidgets('Continue (all complete) → action + advances to uploading',
      (tester) async {
    await pump(tester, registryWith({'mid': 1, 'high': 1, 'low': 1}));

    await tester.tap(find.byKey(const Key('summary_continue')));
    await tester.pumpAndSettle();

    final action = named(AnalyticsEvents.captureSummaryAction);
    expect(action, hasLength(1));
    expect(action.first.props['action'], 'continue');
    expect(action.first.props['all_complete'], true);
    expect(find.text('UPLOADING'), findsOneWidget);
  });

  testWidgets('Continue double-tap advances once', (tester) async {
    await pump(tester, registryWith({'mid': 1, 'high': 1, 'low': 1}));
    final btn = find.byKey(const Key('summary_continue'));
    await tester.tap(btn, warnIfMissed: false);
    await tester.tap(btn, warnIfMissed: false);
    await tester.pumpAndSettle();
    expect(named(AnalyticsEvents.captureSummaryAction), hasLength(1));
  });

  testWidgets('global Review → action (no level) + routes to Level A review',
      (tester) async {
    await pump(tester, registryWith({'mid': 1, 'high': 1, 'low': 1}));

    await tester.tap(find.byKey(const Key('summary_review')));
    await tester.pumpAndSettle();

    final action = named(AnalyticsEvents.captureSummaryAction);
    expect(action, hasLength(1));
    expect(action.first.props['action'], 'review');
    expect(action.first.props.containsKey('level'), isFalse);
    expect(find.text('REVIEW A'), findsOneWidget);
  });

  testWidgets('per-card Review → action with level + routes to that grid',
      (tester) async {
    await pump(tester, registryWith({'mid': 1, 'high': 1, 'low': 1}));

    await tester.tap(find.text('Level B • Top Ring'));
    await tester.pumpAndSettle();

    final action = named(AnalyticsEvents.captureSummaryAction);
    expect(action, hasLength(1));
    expect(action.first.props['action'], 'review');
    expect(action.first.props['level'], 'B');
    expect(find.text('REVIEW B'), findsOneWidget);
  });
}
