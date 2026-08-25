// test/capture/stability_indicator_overlay_test.dart
//
// Widget tests for the Level A stability indicator: it renders the correct dot +
// label for each native gate state ("Stable" / "Hold steady"), shows a
// non-blocking grey fallback when the sensor is unavailable, pulses only while
// unstable (and not under reduce-motion), and throttle-emits `capture_hold_steady`
// only after a SUSTAINED unstable stretch (a brief jolt does not). The native
// gate is injected via [stabilityEventSourceProvider].
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:recapture/application/capture/stability_provider.dart';
import 'package:recapture/platform/stability_channel.dart';
import 'package:recapture/presentation/widgets/stability_indicator_overlay.dart';
import 'package:recapture/utils/analytics.dart';

StabilityStateEvent _state(bool stable) => StabilityStateEvent(
      stable: stable,
      gyroMag: 0,
      linAccelMag: 0,
      timestampNs: 0,
    );

Future<void> _pump(
  WidgetTester tester,
  Stream<StabilityEvent> source, {
  bool reduceMotion = false,
  Duration holdToEmit = const Duration(milliseconds: 1500),
}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        stabilityEventSourceProvider.overrideWithValue(source),
      ],
      child: MaterialApp(
        home: MediaQuery(
          data: MediaQueryData(disableAnimations: reduceMotion),
          child: Scaffold(
            body: Stack(
              children: [
                StabilityIndicatorOverlay(holdToEmit: holdToEmit),
              ],
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pump();
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

  testWidgets('stable state shows "Stable"', (tester) async {
    final source = StreamController<StabilityEvent>.broadcast();
    addTearDown(source.close);
    await _pump(tester, source.stream);

    source.add(_state(true));
    await tester.pump();
    await tester.pump();

    expect(find.text('Stable'), findsOneWidget);
    expect(find.text('Hold steady'), findsNothing);
  });

  testWidgets('unstable state shows "Hold steady"', (tester) async {
    final source = StreamController<StabilityEvent>.broadcast();
    addTearDown(source.close);
    await _pump(tester, source.stream);

    source.add(_state(false));
    await tester.pump();
    await tester.pump();

    expect(find.text('Hold steady'), findsOneWidget);
    expect(find.text('Stable'), findsNothing);
    // Stop the perpetual pulse before the test ends.
    source.add(_state(true));
    await tester.pump();
    await tester.pump();
  });

  testWidgets('sensor-unavailable shows a non-blocking fallback', (tester) async {
    final source = StreamController<StabilityEvent>.broadcast();
    addTearDown(source.close);
    await _pump(tester, source.stream);

    source.addError(Exception('STABILITY_UNAVAILABLE'));
    await tester.pump();
    await tester.pump();

    // Unknown renders "Hold steady" (grey) and never crashes.
    expect(find.text('Hold steady'), findsOneWidget);
    expect(find.byType(StabilityIndicatorOverlay), findsOneWidget);
  });

  testWidgets('reduce-motion: no perpetual pulse, state still updates',
      (tester) async {
    final source = StreamController<StabilityEvent>.broadcast();
    addTearDown(source.close);
    await _pump(tester, source.stream, reduceMotion: true);

    source.add(_state(false));
    await tester.pump();
    // With the pulse disabled there is no running animation → settles.
    await tester.pumpAndSettle();
    expect(find.text('Hold steady'), findsOneWidget);
  });

  testWidgets('sustained unstable emits capture_hold_steady once',
      (tester) async {
    final source = StreamController<StabilityEvent>.broadcast();
    addTearDown(source.close);
    await _pump(tester, source.stream,
        holdToEmit: const Duration(milliseconds: 100));

    source.add(_state(false));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 150)); // past holdToEmit

    final emitted =
        events.where((e) => e.name == AnalyticsEvents.captureHoldSteady);
    expect(emitted, hasLength(1));
    expect(emitted.first.props['device_type'], isNotNull);

    // Settle: return to stable so no animation/timer dangles.
    source.add(_state(true));
    await tester.pump();
    await tester.pump();
  });

  testWidgets('a brief jolt (unstable→stable before hold) does NOT emit',
      (tester) async {
    final source = StreamController<StabilityEvent>.broadcast();
    addTearDown(source.close);
    await _pump(tester, source.stream,
        holdToEmit: const Duration(milliseconds: 200));

    source.add(_state(false));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50)); // jolt < hold
    source.add(_state(true)); // recovered
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300)); // past old hold

    expect(
      events.where((e) => e.name == AnalyticsEvents.captureHoldSteady),
      isEmpty,
    );
  });
}
