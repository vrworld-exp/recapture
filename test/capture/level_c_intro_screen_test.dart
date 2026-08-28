// test/capture/level_c_intro_screen_test.dart
//
// Screen 5C — Level C (Low Ring) intro. Built on the SAME shared
// LevelIntroScaffold as Level B, driven by kLevelCIntroContent. Covers: the rule
// "Lower phone, tilt slightly up" + the DISTINCT Level C illustration glyph +
// the progress indicator on Level C; Begin/Skip navigation; the in-flight
// double-tap guard; "Don't show again" persistence; the viewed/dismissed
// analytics (level_c_intro_*); and auto-skip for opted-out users.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:recapture/data/local/active_session_box.dart';
import 'package:recapture/data/local/level_intro_box.dart';
import 'package:recapture/data/local/storage_providers.dart';
import 'package:recapture/domain/entities/active_session.dart';
import 'package:recapture/presentation/screens/capture/level_c_intro_screen.dart';
import 'package:recapture/utils/analytics.dart';

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
  final List<String> markSeenIds = [];

  @override
  Future<LevelIntroPrefs> get(String introId) async => _prefs;

  @override
  Future<void> markSeen(String introId, {required bool dontShowAgain}) async {
    markSeenIds.add(introId);
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

  Future<List<String>> pumpScreen(
    WidgetTester tester, {
    LevelIntroStore? store,
    bool autoSkipEnabled = true,
    bool reduceMotion = false,
    ActiveSession? session,
  }) async {
    final proceeded = <String>[];
    Widget screen = LevelCIntroScreen(
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
    await tester.pump();
    await tester.pump();
    return proceeded;
  }

  List<({String name, Map<String, Object?> props})> eventsNamed(String name) =>
      events.where((e) => e.name == name).toList();

  testWidgets('renders the Level C rule, distinct illustration, progress + CTAs',
      (tester) async {
    await pumpScreen(tester);

    expect(find.text('Level C: Low Ring'), findsOneWidget);
    expect(find.text('Lower phone, tilt slightly up'), findsOneWidget);
    // Distinct from Level B's screen_rotation_alt glyph.
    expect(find.byIcon(Icons.keyboard_double_arrow_up), findsOneWidget);
    expect(find.byIcon(Icons.screen_rotation_alt), findsNothing);
    // A → B → C progress with C current.
    expect(find.text('A'), findsOneWidget);
    expect(find.text('B'), findsOneWidget);
    expect(find.text('C'), findsOneWidget);
    expect(find.text('Begin'), findsOneWidget);
    expect(find.text('Skip'), findsOneWidget);
  });

  testWidgets('viewed analytics fires once (level_c) with expected props',
      (tester) async {
    await pumpScreen(tester);

    final viewed = eventsNamed(AnalyticsEvents.levelCIntroViewed);
    expect(viewed, hasLength(1));
    expect(viewed.first.props['reduce_motion'], false);
    expect(viewed.first.props['project_id'], isNull);
    expect(viewed.first.props['device_type'], isNotNull);
    // It must NOT emit the Level B event.
    expect(eventsNamed(AnalyticsEvents.levelBIntroViewed), isEmpty);
  });

  testWidgets('viewed carries the active project id when a session exists',
      (tester) async {
    await pumpScreen(
      tester,
      session: ActiveSession(projectId: 'proj_7', updatedAt: DateTime(2026)),
    );
    expect(
        eventsNamed(AnalyticsEvents.levelCIntroViewed).first.props['project_id'],
        'proj_7');
  });

  testWidgets('Begin persists under level_c id + dismissed(begin) + navigates once',
      (tester) async {
    final store = _FakeIntroStore();
    final proceeded = await pumpScreen(tester, store: store);

    await tester.tap(find.text('Begin'));
    await tester.pump();
    await tester.pump();

    expect(proceeded, hasLength(1));
    expect(store.markSeenIds, ['level_c']);
    expect(store.markSeenDontShowAgain, [false]);
    final dismissed = eventsNamed(AnalyticsEvents.levelCIntroDismissed);
    expect(dismissed, hasLength(1));
    expect(dismissed.first.props['method'], 'begin');
  });

  testWidgets('rapid double-tap on Begin navigates only once', (tester) async {
    final proceeded = await pumpScreen(tester);

    await tester.tap(find.text('Begin'));
    await tester.tap(find.text('Begin')); // before the first resolves
    await tester.pump();
    await tester.pump();

    expect(proceeded, hasLength(1));
    expect(eventsNamed(AnalyticsEvents.levelCIntroDismissed), hasLength(1));
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
        eventsNamed(AnalyticsEvents.levelCIntroDismissed)
            .first
            .props['dont_show_again'],
        true);
  });

  testWidgets('opted-out user auto-skips: no paint, dismissed(auto_skip)',
      (tester) async {
    final store =
        _FakeIntroStore(const LevelIntroPrefs(seen: true, dontShowAgain: true));
    final proceeded = await pumpScreen(tester, store: store);

    expect(proceeded, hasLength(1));
    expect(find.text('Begin'), findsNothing);
    expect(eventsNamed(AnalyticsEvents.levelCIntroViewed), isEmpty);
    expect(eventsNamed(AnalyticsEvents.levelCIntroDismissed).first.props['method'],
        'auto_skip');
  });

  testWidgets('reduce-motion is reported in viewed; Begin still works',
      (tester) async {
    final proceeded = await pumpScreen(tester, reduceMotion: true);
    expect(
        eventsNamed(AnalyticsEvents.levelCIntroViewed).first.props['reduce_motion'],
        true);

    await tester.tap(find.text('Begin'));
    await tester.pump();
    await tester.pump();
    expect(proceeded, hasLength(1));
  });
}
