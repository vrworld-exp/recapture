// test/capture/level_a_help_sheet_test.dart
//
// Tests for the shared tip list + the Level A Help sheet: 5–7 tips render with
// title/body, the {n} count resolves from config, open/close + replay analytics
// fire, the replay action dismisses then calls back, and the close button
// dismisses. The shared-source guarantee (intro reuses the same list) is covered
// by the intro test asserting 'cover all 12 positions'.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:recapture/application/config/config_notifier.dart';
import 'package:recapture/domain/entities/capture_config.dart';
import 'package:recapture/presentation/widgets/capture_tip.dart';
import 'package:recapture/presentation/widgets/level_a_help_sheet.dart';
import 'package:recapture/utils/analytics.dart';

/// A config notifier stub that returns a fixed config without the network/Hive
/// bootstrap the real one runs.
class _StubConfig extends ConfigNotifier {
  _StubConfig(this._value);
  final CaptureConfig _value;
  @override
  CaptureConfig build() => _value;
}

Future<void> _openSheet(
  WidgetTester tester, {
  CaptureConfig? config,
  VoidCallback? onReplayIntro,
}) async {
  final cfg = config ?? CaptureConfig.bundledDefault;
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        captureConfigProvider.overrideWith(() => _StubConfig(cfg)),
      ],
      child: MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => Center(
              child: ElevatedButton(
                onPressed: () =>
                    showLevelAHelpSheet(context, onReplayIntro: onReplayIntro),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
}

void main() {
  tearDown(() => Analytics.testSink = null);

  test('shared list has 5–7 tips, all with non-empty copy', () {
    expect(levelACaptureTips.length, inInclusiveRange(5, 7));
    for (final t in levelACaptureTips) {
      expect(t.title.trim(), isNotEmpty);
      expect(t.body.trim(), isNotEmpty);
    }
  });

  test('formattedBody resolves the {n} count token', () {
    const tip = CaptureTip(
      id: 'c',
      title: 'Cover',
      body: 'cover all {n} positions',
      icon: Icons.donut_large,
    );
    expect(tip.formattedBody(8), 'cover all 8 positions');
  });

  testWidgets('renders the title and all tips (scrolling for off-screen ones)',
      (tester) async {
    await _openSheet(tester);
    expect(find.text('Capture tips'), findsOneWidget);
    expect(find.text(levelACaptureTips.first.title), findsOneWidget);

    // The list scrolls internally when the capped height can't show every tip;
    // scroll each title into view to prove they're all wired.
    for (final t in levelACaptureTips) {
      await tester.scrollUntilVisible(
        find.text(t.title),
        80,
        scrollable: find.byType(Scrollable).first,
      );
      expect(find.text(t.title), findsOneWidget);
    }
  });

  testWidgets('resolves {n} from config (variant override mid = 16)', (tester) async {
    final cfg = CaptureConfig.bundledDefault.copyWith(
      variantSegments: VariantSegments.fromMap(const {
        'with_bottom': {'mid': 16, 'high': 12, 'low': 12},
      }),
      pitchBands: const [
        PitchBand(id: 'mid', minDegrees: 30, maxDegrees: 60, segments: 16),
      ],
    );
    await _openSheet(tester, config: cfg);
    expect(find.textContaining('cover all 16 positions'), findsOneWidget);
  });

  testWidgets('falls back to bundled-default N (12) when config is default',
      (tester) async {
    await _openSheet(tester);
    expect(find.textContaining('cover all 12 positions'), findsOneWidget);
  });

  testWidgets('emits level_a_help_opened on show', (tester) async {
    var opened = 0;
    Analytics.testSink = (name, _) {
      if (name == AnalyticsEvents.levelAHelpOpened) opened++;
    };
    await _openSheet(tester);
    expect(opened, 1);
  });

  testWidgets('close button dismisses and emits close action', (tester) async {
    String? action;
    Analytics.testSink = (name, props) {
      if (name == AnalyticsEvents.levelAHelpAction) {
        action = props['action'] as String?;
      }
    };
    await _openSheet(tester);
    await tester.tap(find.byTooltip('Close'));
    await tester.pumpAndSettle();

    expect(action, 'close');
    expect(find.text('Capture tips'), findsNothing); // dismissed
  });

  testWidgets('replay intro: dismisses, fires callback + analytics', (tester) async {
    var replays = 0;
    String? action;
    Analytics.testSink = (name, props) {
      if (name == AnalyticsEvents.levelAHelpAction) {
        action = props['action'] as String?;
      }
    };
    await _openSheet(tester, onReplayIntro: () => replays++);

    expect(find.text('Replay intro'), findsOneWidget);
    await tester.tap(find.text('Replay intro'));
    await tester.pumpAndSettle();

    expect(replays, 1);
    expect(action, 'replay_intro');
    expect(find.text('Capture tips'), findsNothing); // dismissed, no stacking
  });

  testWidgets('no Replay intro footer when onReplayIntro is null', (tester) async {
    await _openSheet(tester);
    expect(find.text('Replay intro'), findsNothing);
  });
}
