// test/capture/level_b_intro_screen_test.dart
//
// Screen 5B — Level B (Top Ring) intro. Covers: the heading + primary
// instruction + tilt-down placeholder illustration + level-progress indicator
// render, Begin/Skip navigation, the in-flight double-tap guard, "Don't show
// again" persistence, the viewed/dismissed analytics, and auto-skip for
// opted-out users.
//
// The persistence store is injected (a fake), navigation is captured via the
// `onProceed` override, and analytics are asserted through `Analytics.testSink`.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:recapture/data/local/active_session_box.dart';
import 'package:recapture/data/local/level_intro_box.dart';
import 'package:recapture/data/local/storage_providers.dart';
import 'package:recapture/domain/entities/active_session.dart';
import 'package:recapture/presentation/screens/capture/level_b_intro_screen.dart';
import 'package:recapture/utils/analytics.dart';

/// ActiveSessionBox stand-in that returns a fixed session without touching Hive
/// (real Hive disk I/O does not resolve under the fake-async `pump`).
class _FakeActiveSessionBox extends ActiveSessionBox {
  _FakeActiveSessionBox(this._session);
  final ActiveSession? _session;
  @override
  Future<ActiveSession?> read() async => _session;
}

class _FakeIntroStore implements LevelIntroStore {
  _FakeIntroStore([this._prefs = LevelIntroPrefs.initial]);

  LevelIntroPrefs _prefs;
  final List<bool> markSeenDontShowAgain = [];

  @override
  Future<LevelIntroPrefs> get(String introId) async => _prefs;

  @override
  Future<void> markSeen(String introId, {required bool dontShowAgain}) async {
    markSeenDontShowAgain.add(dontShowAgain);
    _prefs = _prefs.copyWith(
      seen: true,
      dontShowAgain: _prefs.dontShowAgain || dontShowAgain,
    );
  }
}

void main() {
  late List<({String name, Map<String, Object?> props})> events;

  setUp(() {
    events = [];
    Analytics.testSink = (name, props) => events.add((name: name, props: props));
  });

  tearDown(() {
    Analytics.testSink = null;
  });

  // Pumps the screen. `reduceMotion` overrides MediaQuery for descendants.
  // Returns a mutable list appended to on each onProceed call.
  Future<List<String>> pumpScreen(
    WidgetTester tester, {
    LevelIntroStore? store,
    bool autoSkipEnabled = true,
    bool reduceMotion = false,
    ActiveSession? session,
  }) async {
    final proceeded = <String>[];
    Widget screen = LevelBIntroScreen(
      store: store ?? _FakeIntroStore(),
      autoSkipEnabled: autoSkipEnabled,
      onProceed: () => proceeded.add('proceed'),
    );
    if (reduceMotion) {
      screen = MediaQuery(
        data: const MediaQueryData(disableAnimations: true),
        child: screen,
      );
    }
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          activeSessionBoxProvider
              .overrideWithValue(_FakeActiveSessionBox(session)),
        ],
        child: MaterialApp(home: screen),
      ),
    );
    // Flush _init (store.get + active-session read) → _decided.
    await tester.pump();
    await tester.pump();
    return proceeded;
  }

  List<({String name, Map<String, Object?> props})> eventsNamed(String name) =>
      events.where((e) => e.name == name).toList();

  testWidgets('renders heading, instruction, illustration, progress + CTAs',
      (tester) async {
    await pumpScreen(tester);

    expect(find.text('Level B: Top Ring'), findsOneWidget);
    expect(find.text('Tilt down more to show top'), findsOneWidget);
    // Tilt-down placeholder illustration (icon-based, never a missing asset).
    expect(find.byIcon(Icons.screen_rotation_alt), findsOneWidget);
    // Level-progress indicator shows the guided sequence A → B → C (B current).
    expect(find.text('A'), findsOneWidget);
    expect(find.text('B'), findsOneWidget);
    expect(find.text('C'), findsOneWidget);
    expect(find.text('Begin'), findsOneWidget);
    expect(find.text('Skip'), findsOneWidget);
  });

  testWidgets('viewed analytics fires once with the expected props',
      (tester) async {
    await pumpScreen(tester);

    final viewed = eventsNamed(AnalyticsEvents.levelBIntroViewed);
    expect(viewed, hasLength(1));
    expect(viewed.first.props['reduce_motion'], false);
    expect(viewed.first.props['project_id'], isNull);
    expect(viewed.first.props['device_type'], isNotNull);
  });

  testWidgets('viewed carries the active project id when a session exists',
      (tester) async {
    await pumpScreen(
      tester,
      session: ActiveSession(projectId: 'proj_42', updatedAt: DateTime(2026)),
    );

    expect(
        eventsNamed(AnalyticsEvents.levelBIntroViewed).first.props['project_id'],
        'proj_42');
  });

  testWidgets('Begin persists + emits dismissed(begin) + navigates once',
      (tester) async {
    final store = _FakeIntroStore();
    final proceeded = await pumpScreen(tester, store: store);

    await tester.tap(find.text('Begin'));
    await tester.pump(); // resolve markSeen
    await tester.pump();

    expect(proceeded, hasLength(1));
    expect(store.markSeenDontShowAgain, [false]);
    final dismissed = eventsNamed(AnalyticsEvents.levelBIntroDismissed);
    expect(dismissed, hasLength(1));
    expect(dismissed.first.props['method'], 'begin');
    expect(dismissed.first.props['dont_show_again'], false);
  });

  testWidgets('Skip emits dismissed(skip) and navigates', (tester) async {
    final proceeded = await pumpScreen(tester);

    await tester.tap(find.text('Skip'));
    await tester.pump();
    await tester.pump();

    expect(proceeded, hasLength(1));
    expect(eventsNamed(AnalyticsEvents.levelBIntroDismissed).first.props['method'],
        'skip');
  });

  testWidgets('rapid double-tap on Begin navigates only once', (tester) async {
    final proceeded = await pumpScreen(tester);

    await tester.tap(find.text('Begin'));
    await tester.tap(find.text('Begin')); // before the first resolves
    await tester.pump();
    await tester.pump();

    expect(proceeded, hasLength(1));
    expect(eventsNamed(AnalyticsEvents.levelBIntroDismissed), hasLength(1));
  });

  testWidgets("Don't show again is persisted and reflected in dismissed",
      (tester) async {
    final store = _FakeIntroStore();
    await pumpScreen(tester, store: store);

    await tester.tap(find.text("Don't show this again"));
    await tester.pump();
    await tester.tap(find.text('Begin'));
    await tester.pump();
    await tester.pump();

    expect(store.markSeenDontShowAgain, [true]);
    expect(
        eventsNamed(AnalyticsEvents.levelBIntroDismissed)
            .first
            .props['dont_show_again'],
        true);
  });

  testWidgets('opted-out user auto-skips: no intro paint, dismissed(auto_skip)',
      (tester) async {
    final store =
        _FakeIntroStore(const LevelIntroPrefs(seen: true, dontShowAgain: true));
    final proceeded = await pumpScreen(tester, store: store);

    expect(proceeded, hasLength(1));
    expect(find.text('Begin'), findsNothing);
    expect(eventsNamed(AnalyticsEvents.levelBIntroViewed), isEmpty);
    final dismissed = eventsNamed(AnalyticsEvents.levelBIntroDismissed);
    expect(dismissed, hasLength(1));
    expect(dismissed.first.props['method'], 'auto_skip');
  });

  testWidgets('auto-skip disabled: opted-out user still sees the intro',
      (tester) async {
    final store =
        _FakeIntroStore(const LevelIntroPrefs(seen: true, dontShowAgain: true));
    final proceeded =
        await pumpScreen(tester, store: store, autoSkipEnabled: false);

    expect(proceeded, isEmpty);
    expect(find.text('Begin'), findsOneWidget);
    expect(eventsNamed(AnalyticsEvents.levelBIntroViewed), hasLength(1));
  });

  testWidgets('reduce-motion is reported in viewed; Begin still works',
      (tester) async {
    final proceeded = await pumpScreen(tester, reduceMotion: true);

    expect(
        eventsNamed(AnalyticsEvents.levelBIntroViewed).first.props['reduce_motion'],
        true);

    await tester.tap(find.text('Begin'));
    await tester.pump();
    await tester.pump();
    expect(proceeded, hasLength(1));
  });
}
