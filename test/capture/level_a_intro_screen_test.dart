// test/capture/level_a_intro_screen_test.dart
//
// Screen 5A — Level A (Eye Ring) intro. Covers: rules render with the config
// segment count, the looping animation vs. the reduce-motion static fallback,
// Begin/Skip navigation, the in-flight double-tap guard, "Don't show again"
// persistence, the viewed/dismissed analytics, and auto-skip for opted-out users.
//
// The persistence store is injected (a fake), navigation is captured via the
// `onProceed` override, and analytics are asserted through `Analytics.testSink`.
// captureConfigProvider resolves to its bundled default (eye ring = 12 segments).
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:recapture/application/config/config_notifier.dart';
import 'package:recapture/data/local/active_session_box.dart';
import 'package:recapture/data/local/level_intro_box.dart';
import 'package:recapture/data/local/storage_providers.dart';
import 'package:recapture/domain/entities/active_session.dart';
import 'package:recapture/domain/entities/capture_config.dart';
import 'package:recapture/presentation/screens/capture/level_a_intro_screen.dart';
import 'package:recapture/presentation/widgets/eye_ring_intro_animation.dart';
import 'package:recapture/utils/analytics.dart';

/// ConfigNotifier whose [build] skips the network bootstrap (which would leave a
/// pending timer in the test) — just serves the bundled default synchronously.
class _StubConfigNotifier extends ConfigNotifier {
  @override
  CaptureConfig build() => CaptureConfig.bundledDefault;
}

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
  // Returns the count of onProceed calls (mutable list length via closure).
  Future<List<String>> pumpScreen(
    WidgetTester tester, {
    LevelIntroStore? store,
    bool autoSkipEnabled = true,
    bool reduceMotion = false,
    ActiveSession? session,
  }) async {
    final proceeded = <String>[];
    Widget screen = LevelAIntroScreen(
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
          captureConfigProvider.overrideWith(_StubConfigNotifier.new),
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

  testWidgets('renders rules with the config segment count + Begin/Skip',
      (tester) async {
    await pumpScreen(tester);

    // Bundled default with_bottom eye ring = 12 segments.
    expect(find.textContaining('cover all 12 positions'), findsOneWidget);
    expect(find.text('Begin'), findsOneWidget);
    expect(find.text('Skip'), findsOneWidget);
    expect(find.byType(EyeRingIntroAnimation), findsOneWidget);

    // Drain any animation work, then unmount.
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('viewed analytics fires once with the expected props',
      (tester) async {
    await pumpScreen(tester);

    final viewed = eventsNamed(AnalyticsEvents.levelAIntroViewed);
    expect(viewed, hasLength(1));
    expect(viewed.first.props['reduce_motion'], false);
    expect(viewed.first.props['project_id'], isNull);
    expect(viewed.first.props['device_type'], isNotNull);

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('viewed carries the active project id when a session exists',
      (tester) async {
    await pumpScreen(
      tester,
      session: ActiveSession(projectId: 'proj_42', updatedAt: DateTime(2026)),
    );

    expect(eventsNamed(AnalyticsEvents.levelAIntroViewed).first.props['project_id'],
        'proj_42');

    await tester.pumpWidget(const SizedBox());
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
    final dismissed = eventsNamed(AnalyticsEvents.levelAIntroDismissed);
    expect(dismissed, hasLength(1));
    expect(dismissed.first.props['method'], 'begin');
    expect(dismissed.first.props['dont_show_again'], false);

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('Skip emits dismissed(skip) and navigates', (tester) async {
    final proceeded = await pumpScreen(tester);

    await tester.tap(find.text('Skip'));
    await tester.pump();
    await tester.pump();

    expect(proceeded, hasLength(1));
    expect(eventsNamed(AnalyticsEvents.levelAIntroDismissed).first.props['method'],
        'skip');

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('rapid double-tap on Begin navigates only once', (tester) async {
    final proceeded = await pumpScreen(tester);

    await tester.tap(find.text('Begin'));
    await tester.tap(find.text('Begin')); // before the first resolves
    await tester.pump();
    await tester.pump();

    expect(proceeded, hasLength(1));
    expect(eventsNamed(AnalyticsEvents.levelAIntroDismissed), hasLength(1));

    await tester.pumpWidget(const SizedBox());
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
    expect(eventsNamed(AnalyticsEvents.levelAIntroDismissed).first.props['dont_show_again'],
        true);

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('opted-out user auto-skips: no intro paint, dismissed(auto_skip)',
      (tester) async {
    final store =
        _FakeIntroStore(const LevelIntroPrefs(seen: true, dontShowAgain: true));
    final proceeded = await pumpScreen(tester, store: store);

    expect(proceeded, hasLength(1));
    expect(find.text('Begin'), findsNothing);
    expect(eventsNamed(AnalyticsEvents.levelAIntroViewed), isEmpty);
    final dismissed = eventsNamed(AnalyticsEvents.levelAIntroDismissed);
    expect(dismissed, hasLength(1));
    expect(dismissed.first.props['method'], 'auto_skip');

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('auto-skip disabled: opted-out user still sees the intro',
      (tester) async {
    final store =
        _FakeIntroStore(const LevelIntroPrefs(seen: true, dontShowAgain: true));
    final proceeded =
        await pumpScreen(tester, store: store, autoSkipEnabled: false);

    expect(proceeded, isEmpty);
    expect(find.text('Begin'), findsOneWidget);
    expect(eventsNamed(AnalyticsEvents.levelAIntroViewed), hasLength(1));

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('reduce-motion shows static fallback; Begin still works',
      (tester) async {
    final proceeded = await pumpScreen(tester, reduceMotion: true);

    expect(find.byType(EyeRingIntroAnimation), findsOneWidget);
    expect(eventsNamed(AnalyticsEvents.levelAIntroViewed).first.props['reduce_motion'],
        true);

    await tester.tap(find.text('Begin'));
    await tester.pump();
    await tester.pump();
    expect(proceeded, hasLength(1));

    await tester.pumpWidget(const SizedBox());
  });
}
