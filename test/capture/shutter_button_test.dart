// test/capture/shutter_button_test.dart
//
// Widget tests for the gated shutter: ready taps fire exactly one capture (with
// success haptic + analytics), blocked taps don't capture (nudge + throttled
// analytics + block haptic), the in-flight guard prevents double-fire, errors
// clear state (no stuck spinner) with an error haptic, semantics reflect state,
// and disposal mid-capture is clean. Haptics are asserted via the platform
// channel; capture is asserted via the injected callback.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:recapture/domain/entities/capture_readiness.dart';
import 'package:recapture/presentation/widgets/shutter_button.dart';
import 'package:recapture/utils/analytics.dart';

const _ready = CaptureReadiness(mode: CaptureMode.manual);
const _blockedUnstable =
    CaptureReadiness(mode: CaptureMode.guided, inBand: true, stable: false);

/// The one-shot-per-segment block: every other gate passes, the segment is just
/// already filled (the Meshy "turn to the next section" state).
const _blockedAlreadyCaptured = CaptureReadiness(
  mode: CaptureMode.guided,
  inBand: true,
  stable: true,
  alreadyCaptured: true,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  late List<String> haptics;
  late List<({String name, Map<String, Object?> props})> events;

  setUp(() {
    haptics = [];
    events = [];
    Analytics.testSink = (name, props) => events.add((name: name, props: props));
    messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'HapticFeedback.vibrate') {
        haptics.add(call.arguments as String? ?? 'vibrate');
      }
      return null;
    });
  });

  tearDown(() {
    Analytics.testSink = null;
    messenger.setMockMethodCallHandler(SystemChannels.platform, null);
  });

  Future<void> pump(
    WidgetTester tester, {
    required CaptureReadiness readiness,
    Future<void> Function()? onCapture,
    VoidCallback? onBlockedTap,
    String? label,
    bool reduceMotion = false,
    Duration blockedCooldown = Duration.zero,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        home: MediaQuery(
          data: MediaQueryData(disableAnimations: reduceMotion),
          child: Scaffold(
            body: Center(
              child: ShutterButton(
                readiness: readiness,
                label: label,
                onCapture: onCapture ?? () async {},
                onBlockedTap: onBlockedTap,
                blockedTapCooldown: blockedCooldown,
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
  }

  Iterable<Map<String, Object?>> named(String n) =>
      events.where((e) => e.name == n).map((e) => e.props);

  testWidgets('ready tap fires one capture + success haptic + analytics',
      (tester) async {
    var calls = 0;
    await pump(tester, readiness: _ready, onCapture: () async => calls++);

    await tester.tap(find.byType(ShutterButton));
    await tester.pump();
    await tester.pump();

    expect(calls, 1);
    expect(haptics, contains('HapticFeedbackType.mediumImpact')); // success
    final triggered = named(AnalyticsEvents.levelACaptureTriggered).single;
    expect(triggered['result'], 'success');
    expect(triggered['mode'], 'manual');
  });

  testWidgets('blocked tap does not capture; nudges + throttled analytics',
      (tester) async {
    var calls = 0;
    var nudged = 0;
    await pump(
      tester,
      readiness: _blockedUnstable,
      onCapture: () async => calls++,
      onBlockedTap: () => nudged++,
    );

    await tester.tap(find.byType(ShutterButton));
    await tester.pump();

    expect(calls, 0);
    expect(nudged, 1);
    expect(named(AnalyticsEvents.levelACaptureTriggered), isEmpty);
    final blocked = named(AnalyticsEvents.levelABlockedShutterTap).single;
    expect(blocked['reason'], 'unstable');
  });

  testWidgets(
      'already-captured segment: blocked visual, no capture, its own analytics '
      'reason + semantics', (tester) async {
    var calls = 0;
    var nudged = 0;
    await pump(
      tester,
      readiness: _blockedAlreadyCaptured,
      label: 'Click',
      onCapture: () async => calls++,
      onBlockedTap: () => nudged++,
    );

    // Blocked visual: the button dims exactly as for any other blocked reason.
    final opacity = tester.widget<Opacity>(
      find.descendant(
        of: find.byType(ShutterButton),
        matching: find.byType(Opacity),
      ),
    );
    expect(opacity.opacity, 0.5);
    expect(
      find.bySemanticsLabel('Capture Click, blocked: already captured this angle'),
      findsOneWidget,
    );

    await tester.tap(find.byType(ShutterButton));
    await tester.pump();

    expect(calls, 0, reason: 'a filled segment must never capture again');
    expect(nudged, 1, reason: 'the parent surfaces the "turn" warning');
    expect(named(AnalyticsEvents.levelACaptureTriggered), isEmpty);
    // Its OWN reason — never lumped into 'unknown'.
    expect(named(AnalyticsEvents.levelABlockedShutterTap).single['reason'],
        'already_captured');
  });

  testWidgets('blocked-tap analytics is throttled within the cooldown',
      (tester) async {
    await pump(
      tester,
      readiness: _blockedUnstable,
      blockedCooldown: const Duration(seconds: 30),
    );

    await tester.tap(find.byType(ShutterButton));
    await tester.pump();
    await tester.tap(find.byType(ShutterButton));
    await tester.pump();

    // Two taps, but the second is within the cooldown → one analytics event.
    expect(named(AnalyticsEvents.levelABlockedShutterTap), hasLength(1));
  });

  testWidgets('rapid double-tap fires only one capture (in-flight guard)',
      (tester) async {
    final gate = Completer<void>();
    var calls = 0;
    await pump(
      tester,
      readiness: _ready,
      onCapture: () {
        calls++;
        return gate.future;
      },
    );

    await tester.tap(find.byType(ShutterButton));
    await tester.pump();
    await tester.tap(find.byType(ShutterButton)); // ignored while in-flight
    await tester.pump();
    expect(calls, 1);

    gate.complete();
    await tester.pump();
    await tester.pump();
    expect(calls, 1);
  });

  testWidgets('shows the in-flight spinner, then clears it', (tester) async {
    final gate = Completer<void>();
    await pump(tester, readiness: _ready, onCapture: () => gate.future);

    await tester.tap(find.byType(ShutterButton));
    await tester.pump();
    expect(find.byType(CircularProgressIndicator), findsOneWidget);

    gate.complete();
    await tester.pump();
    await tester.pump();
    expect(find.byType(CircularProgressIndicator), findsNothing);
  });

  testWidgets('onCapture error → error haptic, no stuck spinner, error analytics',
      (tester) async {
    await pump(
      tester,
      readiness: _ready,
      onCapture: () async => throw Exception('camera boom'),
    );

    await tester.tap(find.byType(ShutterButton));
    await tester.pump();
    await tester.pump();

    expect(find.byType(CircularProgressIndicator), findsNothing); // not stuck
    expect(haptics, contains('HapticFeedbackType.heavyImpact')); // error
    expect(named(AnalyticsEvents.levelACaptureTriggered).single['result'],
        'error');
  });

  testWidgets('semantics label reflects state', (tester) async {
    await pump(tester, readiness: _ready);
    expect(find.bySemanticsLabel('Capture, ready'), findsOneWidget);

    await pump(tester, readiness: _blockedUnstable);
    expect(find.bySemanticsLabel('Capture, blocked: hold steady'),
        findsOneWidget);
  });

  testWidgets('renders the flow label, and names it in semantics',
      (tester) async {
    await pump(tester, readiness: _ready, label: 'Click');
    expect(find.text('Click'), findsOneWidget);
    expect(find.bySemanticsLabel('Capture Click, ready'), findsOneWidget);

    await pump(tester, readiness: _ready, label: 'Auto');
    expect(find.text('Auto'), findsOneWidget);
    expect(find.bySemanticsLabel('Capture Auto, ready'), findsOneWidget);
  });

  testWidgets('no label supplied → unchanged core + semantics', (tester) async {
    await pump(tester, readiness: _ready);
    expect(find.byType(Text), findsNothing);
    expect(find.bySemanticsLabel('Capture, ready'), findsOneWidget);
  });

  testWidgets('the spinner replaces the label while capturing', (tester) async {
    final gate = Completer<void>();
    await pump(
      tester,
      readiness: _ready,
      label: 'Click',
      onCapture: () => gate.future,
    );
    expect(find.text('Click'), findsOneWidget);

    await tester.tap(find.byType(ShutterButton));
    await tester.pump();
    expect(find.text('Click'), findsNothing);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);

    gate.complete();
    await tester.pump();
    await tester.pump();
    expect(find.text('Click'), findsOneWidget); // label comes back
  });

  testWidgets('disposed mid-capture does not throw', (tester) async {
    final gate = Completer<void>();
    await pump(tester, readiness: _ready, onCapture: () => gate.future);

    await tester.tap(find.byType(ShutterButton));
    await tester.pump();
    await tester.pumpWidget(const SizedBox()); // dispose while in-flight
    gate.complete();
    await tester.pump();
    expect(tester.takeException(), isNull);
  });
}
