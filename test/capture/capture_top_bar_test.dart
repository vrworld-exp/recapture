// test/capture/capture_top_bar_test.dart
//
// Widget tests for the capture top bar: renders the level indicator + the three
// controls, each fires its callback, disabled Help/Settings grey out and fire
// nothing, rapid taps debounce to a single open intent, a long subtitle
// truncates, semantics/tooltips are present, and disposal cancels the debounce
// timer cleanly.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:recapture/app/theme/app_colors.dart';
import 'package:recapture/domain/entities/capture_top_bar_state.dart';
import 'package:recapture/presentation/widgets/capture_top_bar.dart';

Future<void> _pump(
  WidgetTester tester, {
  required CaptureTopBarState state,
  VoidCallback? onBack,
  VoidCallback? onHelp,
  VoidCallback? onSettings,
  bool reduceMotion = false,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: MediaQuery(
        data: MediaQueryData(disableAnimations: reduceMotion),
        child: Scaffold(
          body: Stack(
            children: [
              CaptureTopBar(
                state: state,
                onBack: onBack ?? () {},
                onHelp: onHelp ?? () {},
                onSettings: onSettings ?? () {},
              ),
            ],
          ),
        ),
      ),
    ),
  );
  await tester.pump();
}

const _state = CaptureTopBarState(
  levelLabel: 'Level A',
  levelSubtitle: 'Eye Ring',
);

void main() {
  testWidgets('renders level label, subtitle and three controls', (tester) async {
    await _pump(tester, state: _state);
    expect(find.text('Level A'), findsOneWidget);
    expect(find.text('Eye Ring'), findsOneWidget);
    expect(find.byTooltip('Back'), findsOneWidget);
    expect(find.byTooltip('Help'), findsOneWidget);
    expect(find.byTooltip('Settings'), findsOneWidget);
  });

  testWidgets('each control fires its callback', (tester) async {
    var back = 0, help = 0, settings = 0;
    await _pump(
      tester,
      state: _state,
      onBack: () => back++,
      onHelp: () => help++,
      onSettings: () => settings++,
    );

    await tester.tap(find.byTooltip('Back'));
    await tester.tap(find.byTooltip('Help'));
    await tester.tap(find.byTooltip('Settings'));
    await tester.pump();

    expect(back, 1);
    expect(help, 1);
    expect(settings, 1);
  });

  testWidgets('disabled Help/Settings grey out and fire nothing', (tester) async {
    var help = 0, settings = 0;
    await _pump(
      tester,
      state: const CaptureTopBarState(
        levelLabel: 'Level A',
        levelSubtitle: 'Eye Ring',
        helpEnabled: false,
        settingsEnabled: false,
      ),
      onHelp: () => help++,
      onSettings: () => settings++,
    );

    await tester.tap(find.byTooltip('Help'));
    await tester.tap(find.byTooltip('Settings'));
    await tester.pump();

    expect(help, 0);
    expect(settings, 0);

    // Icons render in the disabled colour.
    final icon = tester.widget<Icon>(
      find.descendant(
        of: find.byTooltip('Help'),
        matching: find.byType(Icon),
      ),
    );
    expect(icon.color, AppColors.disabled);
  });

  testWidgets('rapid taps debounce to a single open intent', (tester) async {
    var help = 0;
    await _pump(tester, state: _state, onHelp: () => help++);

    final helpBtn = find.byTooltip('Help');
    await tester.tap(helpBtn);
    await tester.tap(helpBtn);
    await tester.tap(helpBtn);
    await tester.pump();
    expect(help, 1, reason: 'rapid taps collapse to one');

    // After the cooldown window, a fresh tap opens again.
    await tester.pump(const Duration(milliseconds: 600));
    await tester.tap(helpBtn);
    await tester.pump();
    expect(help, 2);
  });

  testWidgets('long subtitle truncates and the bar does not overflow',
      (tester) async {
    await _pump(
      tester,
      state: const CaptureTopBarState(
        levelLabel: 'Level A',
        levelSubtitle:
            'An extremely long subtitle that would otherwise blow out the bar layout entirely',
      ),
    );
    expect(tester.takeException(), isNull);

    final subtitle = tester.widget<Text>(
      find.textContaining('An extremely long subtitle'),
    );
    expect(subtitle.overflow, TextOverflow.ellipsis);
    expect(subtitle.maxLines, 1);
  });

  testWidgets('controls expose button semantics with labels', (tester) async {
    await _pump(tester, state: _state);
    final handle = tester.ensureSemantics();
    expect(find.bySemanticsLabel('Back'), findsOneWidget);
    expect(find.bySemanticsLabel('Help'), findsOneWidget);
    expect(find.bySemanticsLabel('Settings'), findsOneWidget);
    handle.dispose();
  });

  testWidgets('disposed mid-cooldown cancels the timer cleanly', (tester) async {
    await _pump(tester, state: _state);
    await tester.tap(find.byTooltip('Back'));
    await tester.pump(const Duration(milliseconds: 100)); // cooldown active
    await tester.pumpWidget(const MaterialApp(home: Scaffold()));
    await tester.pump();
    expect(tester.takeException(), isNull);
  });
}
