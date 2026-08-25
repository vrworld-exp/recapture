// test/capture/auto_capture_indicator_test.dart
//
// Widget tests for the auto-capture pill: ON/OFF label, tap→onToggle, the
// countdown bar shows only when ON + supplied (ignored when OFF), reduce-motion
// drops the animated bar, and the toggled semantics are correct.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:recapture/domain/entities/auto_capture_state.dart';
import 'package:recapture/presentation/widgets/auto_capture_indicator.dart';

Future<void> _pump(
  WidgetTester tester,
  AutoCaptureState state, {
  VoidCallback? onToggle,
  bool reduceMotion = false,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: MediaQuery(
        data: MediaQueryData(disableAnimations: reduceMotion),
        child: Scaffold(
          body: Stack(
            children: [
              Positioned(
                top: 40,
                right: 16,
                child: AutoCaptureIndicator(
                  state: state,
                  onToggle: onToggle ?? () {},
                ),
              ),
            ],
          ),
        ),
      ),
    ),
  );
  await tester.pump();
}

/// Finds the Mirage-Red countdown fill (the FractionallySizedBox in the bar).
Finder _countdownBar() => find.byType(FractionallySizedBox);

void main() {
  testWidgets('shows AUTO ON when on', (tester) async {
    await _pump(tester, const AutoCaptureState(mode: AutoCaptureMode.on));
    expect(find.text('AUTO ON'), findsOneWidget);
    expect(find.text('AUTO OFF'), findsNothing);
  });

  testWidgets('shows AUTO OFF when off', (tester) async {
    await _pump(tester, const AutoCaptureState());
    expect(find.text('AUTO OFF'), findsOneWidget);
  });

  testWidgets('tap calls onToggle', (tester) async {
    var toggles = 0;
    await _pump(tester, const AutoCaptureState(), onToggle: () => toggles++);
    await tester.tap(find.byType(AutoCaptureIndicator));
    await tester.pump();
    expect(toggles, 1);
  });

  testWidgets('countdown bar shows when ON + countdown supplied', (tester) async {
    await _pump(
      tester,
      const AutoCaptureState(mode: AutoCaptureMode.on, countdown: 0.5),
    );
    expect(_countdownBar(), findsOneWidget);
  });

  testWidgets('countdown ignored when OFF (no bar)', (tester) async {
    await _pump(
      tester,
      const AutoCaptureState(mode: AutoCaptureMode.off, countdown: 0.5),
    );
    expect(_countdownBar(), findsNothing);
    expect(find.text('AUTO OFF'), findsOneWidget);
  });

  testWidgets('reduce-motion drops the animated countdown bar', (tester) async {
    await _pump(
      tester,
      const AutoCaptureState(mode: AutoCaptureMode.on, countdown: 0.5),
      reduceMotion: true,
    );
    expect(_countdownBar(), findsNothing); // static armed styling only
    expect(find.text('AUTO ON'), findsOneWidget);
  });

  testWidgets('semantics label reflects ON/OFF', (tester) async {
    final handle = tester.ensureSemantics();

    await _pump(tester, const AutoCaptureState(mode: AutoCaptureMode.on));
    expect(find.bySemanticsLabel(RegExp('Auto capture on')), findsOneWidget);

    await _pump(tester, const AutoCaptureState());
    expect(find.bySemanticsLabel(RegExp('Auto capture off')), findsOneWidget);

    handle.dispose();
  });
}
