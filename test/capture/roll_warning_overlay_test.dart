// test/capture/roll_warning_overlay_test.dart
//
// Widget tests for the Guided Capture roll advisory: it shows/hides "Keep the
// phone level" with the hysteretic roll state, and fires
// `guided_capture_roll_warning_shown` once per RISING EDGE (not per frame), with
// the signed roll + level. The native orientation stream is injected; no channels.
import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:recapture/application/capture/analytics/capture_level_events.dart';
import 'package:recapture/application/capture/analytics/capture_level_session.dart';
import 'package:recapture/application/capture/current_pitch_provider.dart';
import 'package:recapture/platform/imu_rotation_channel.dart';
import 'package:recapture/presentation/widgets/roll_warning_overlay.dart';
import 'package:recapture/utils/analytics.dart';

SmoothedOrientation _roll(double deg) {
  final rad = deg * math.pi / 180.0;
  return SmoothedOrientation(
    yaw: 0,
    pitch: 0,
    roll: rad,
    qx: 0,
    qy: 0,
    qz: 0,
    qw: 1,
    timestampNs: 0,
  );
}

Future<ProviderContainer> _pump(
  WidgetTester tester,
  Stream<SmoothedOrientation> source, {
  CaptureLevel level = CaptureLevel.b,
}) async {
  final container = ProviderContainer(overrides: [
    orientationSourceProvider.overrideWithValue(source),
  ]);
  // A live session so the event carries a capture_session_id.
  container.read(captureLevelSessionProvider.notifier).start(
        level: level,
        projectId: 'p1',
        sessionId: 'sess-1',
      );
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        home: Scaffold(
          body: Stack(
            children: [RollWarningOverlay(level: level)],
          ),
        ),
      ),
    ),
  );
  await tester.pump();
  return container;
}

void main() {
  final events = <({String name, Map<String, Object?> props})>[];

  setUp(() {
    events.clear();
    Analytics.testSink = (name, props) => events.add((name: name, props: props));
  });
  tearDown(() => Analytics.testSink = null);

  testWidgets('shows the advisory past ±15°, hides within tolerance',
      (tester) async {
    final source = StreamController<SmoothedOrientation>.broadcast();
    addTearDown(source.close);
    await _pump(tester, source.stream);

    expect(find.text('Keep the phone level'), findsOneWidget); // built (opacity 0)
    final opacityBefore = tester
        .widget<AnimatedOpacity>(find.byType(AnimatedOpacity))
        .opacity;
    expect(opacityBefore, 0);

    source.add(_roll(20));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    expect(
      tester.widget<AnimatedOpacity>(find.byType(AnimatedOpacity)).opacity,
      1,
    );

    source.add(_roll(5));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    expect(
      tester.widget<AnimatedOpacity>(find.byType(AnimatedOpacity)).opacity,
      0,
    );
  });

  testWidgets('fires guided_capture_roll_warning_shown once per rising edge',
      (tester) async {
    final source = StreamController<SmoothedOrientation>.broadcast();
    addTearDown(source.close);
    await _pump(tester, source.stream, level: CaptureLevel.c);

    // Rising edge.
    source.add(_roll(18));
    await tester.pump();
    // Stays out of tolerance across more frames + a sign cross → no re-emit.
    source.add(_roll(25));
    await tester.pump();
    source.add(_roll(-22));
    await tester.pump();

    final shown = events
        .where((e) => e.name == AnalyticsEvents.guidedCaptureRollWarningShown)
        .toList();
    expect(shown, hasLength(1));
    expect(shown.single.props['level'], 'C');
    expect(shown.single.props['capture_session_id'], 'sess-1');
    expect(shown.single.props['roll_degrees'], closeTo(18, 1e-6));

    // Clear, then a second excursion → a second rising edge fires again.
    source.add(_roll(2));
    await tester.pump();
    source.add(_roll(30));
    await tester.pump();
    expect(
      events
          .where((e) => e.name == AnalyticsEvents.guidedCaptureRollWarningShown)
          .length,
      2,
    );
  });

  testWidgets('no warning / no event when the sensor is unavailable',
      (tester) async {
    final source = StreamController<SmoothedOrientation>.broadcast();
    addTearDown(source.close);
    await _pump(tester, source.stream);

    source.addError(Exception('SENSOR_UNAVAILABLE'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));

    expect(
      tester.widget<AnimatedOpacity>(find.byType(AnimatedOpacity)).opacity,
      0,
    );
    expect(
      events.where((e) => e.name == AnalyticsEvents.guidedCaptureRollWarningShown),
      isEmpty,
    );
  });
}
