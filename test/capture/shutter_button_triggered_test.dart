// test/capture/shutter_button_triggered_test.dart
//
// Verifies the ShutterButton's capture-INITIATION hook (onTriggered): it fires
// once per non-blocked tap, BEFORE onCapture runs (so a throwing capture never
// suppresses it), carries the live readiness, and is NEVER called on a blocked tap
// (which still emits only the blocked-tap event).
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:recapture/domain/entities/capture_readiness.dart';
import 'package:recapture/presentation/widgets/shutter_button.dart';
import 'package:recapture/utils/analytics.dart';

const _ready = CaptureReadiness(
  mode: CaptureMode.guided,
  inBand: true,
  stable: true,
  sensorSupported: true,
);
const _blocked = CaptureReadiness(
  mode: CaptureMode.guided,
  inBand: false,
  stable: true,
  sensorSupported: true,
);

Future<void> _pump(
  WidgetTester tester, {
  required CaptureReadiness readiness,
  required Future<void> Function() onCapture,
  void Function(CaptureReadiness)? onTriggered,
}) async {
  await tester.pumpWidget(MaterialApp(
    home: Scaffold(
      body: Center(
        child: ShutterButton(
          readiness: readiness,
          onCapture: onCapture,
          onTriggered: onTriggered,
        ),
      ),
    ),
  ));
}

void main() {
  tearDown(() => Analytics.testSink = null);

  testWidgets('ready tap fires onTriggered once with the readiness',
      (tester) async {
    final triggers = <CaptureReadiness>[];
    var captures = 0;
    await _pump(
      tester,
      readiness: _ready,
      onCapture: () async => captures++,
      onTriggered: triggers.add,
    );

    await tester.tap(find.byType(ShutterButton));
    await tester.pump();
    await tester.pump();

    expect(triggers, [_ready]);
    expect(captures, 1);
  });

  testWidgets('blocked tap does NOT fire onTriggered (only blocked event)',
      (tester) async {
    final events = <String>[];
    Analytics.testSink = (n, _) => events.add(n);
    var triggered = 0;
    var captures = 0;
    await _pump(
      tester,
      readiness: _blocked,
      onCapture: () async => captures++,
      onTriggered: (_) => triggered++,
    );

    await tester.tap(find.byType(ShutterButton));
    await tester.pump();

    expect(triggered, 0, reason: 'no initiation on a blocked tap');
    expect(captures, 0, reason: 'capture did not proceed');
    expect(events, contains(AnalyticsEvents.levelABlockedShutterTap));
    expect(events, isNot(contains(AnalyticsEvents.manualCaptureTriggered)));
  });

  testWidgets('onTriggered fires even when onCapture throws (fired at init)',
      (tester) async {
    var triggered = 0;
    await _pump(
      tester,
      readiness: _ready,
      onCapture: () async => throw StateError('capture blew up'),
      onTriggered: (_) => triggered++,
    );

    await tester.tap(find.byType(ShutterButton));
    await tester.pump();
    await tester.pump();

    expect(triggered, 1, reason: 'trigger represents the attempt, not the outcome');
    expect(tester.takeException(), isNull, reason: 'button swallows the failure');
  });
}
