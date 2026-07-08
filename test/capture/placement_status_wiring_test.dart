// test/capture/placement_status_wiring_test.dart
//
// Instrument-tests the WIRED placement guide: detections driven through the
// injectable placement source flow provider → evaluator → capture screen →
// PlacementBoxOverlay, flipping the guide's helper copy (and thus its colour
// state) live — good / offCenter / tooClose / tooFar / back to idle when the
// object leaves. Also pins the fail-open rule (a detector ERROR rests at idle,
// never a warning) and the transition-only `placement_status_changed` event.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:recapture/application/capture/current_pitch_provider.dart';
import 'package:recapture/application/capture/placement_status_provider.dart';
import 'package:recapture/application/capture/stability_provider.dart';
import 'package:recapture/application/config/config_notifier.dart';
import 'package:recapture/data/local/active_session_box.dart';
import 'package:recapture/data/local/auto_capture_box.dart';
import 'package:recapture/data/local/capture_settings_box.dart';
import 'package:recapture/domain/capture/placement_evaluator.dart';
import 'package:recapture/domain/entities/active_session.dart';
import 'package:recapture/domain/entities/capture_config.dart';
import 'package:recapture/domain/entities/capture_settings.dart';
import 'package:recapture/platform/imu_rotation_channel.dart';
import 'package:recapture/platform/stability_channel.dart';
import 'package:recapture/presentation/screens/capture/capture_screen.dart';
import 'package:recapture/utils/analytics.dart';
import 'package:recapture/utils/constants.dart';

class _FakeSessionBox extends ActiveSessionBox {
  @override
  Future<ActiveSession?> read() async => null;
}

class _FakeAutoCaptureStore implements AutoCaptureStore {
  @override
  Future<bool?> getEnabled() async => false; // auto OFF: no fires behind this test
  @override
  Future<void> setEnabled(bool enabled) async {}
}

class _FakeCaptureSettingsStore implements CaptureSettingsStore {
  @override
  Future<bool?> getSaveToGallery() async => null;
  @override
  Future<void> setSaveToGallery(bool enabled) async {}
  @override
  Future<QualityMode?> getQuality() async => null;
  @override
  Future<void> setQuality(QualityMode mode) async {}
}

class _StubConfigNotifier extends ConfigNotifier {
  @override
  CaptureConfig build() => CaptureConfig.bundledDefault;
}

/// A detection whose object rect is sized/offset relative to the default 0.7
/// guide box (see the evaluator tests for the geometry maths).
PlacementDetection _detection(Rect rect) =>
    PlacementDetection(objectNormalized: rect);

/// ~50% guide fill, centred (good).
final _good = _detection(
  Rect.fromCenter(center: const Offset(0.5, 0.5), width: 0.49, height: 0.49),
);

/// Same size, pushed right past the centering tolerance (offCenter).
final _offCenter = _detection(
  Rect.fromCenter(center: const Offset(0.75, 0.5), width: 0.49, height: 0.49),
);

/// Near-full-frame object (tooClose).
final _tooClose = _detection(const Rect.fromLTRB(0.02, 0.02, 0.98, 0.98));

/// Tiny distant object, centred (tooFar).
final _tooFar = _detection(
  Rect.fromCenter(center: const Offset(0.5, 0.5), width: 0.1, height: 0.1),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  const previewChannel = MethodChannel(AppConfig.channelCameraPreview);
  const captureChannel = MethodChannel(AppConfig.channelCapture);

  late List<(String, Map<String, Object?>)> events;
  late StreamController<PlacementDetection> detections;

  setUp(() {
    events = [];
    detections = StreamController<PlacementDetection>.broadcast();
    Analytics.testSink = (n, p) => events.add((n, p));
    messenger.setMockMethodCallHandler(previewChannel, (call) async {
      // Real preview dimensions: the placement guide renders ONLY through a
      // valid PreviewGeometry (no resolution → the overlay draws nothing).
      if (call.method == 'start') {
        return <String, dynamic>{
          'textureId': 1,
          'previewWidth': 1080,
          'previewHeight': 1920,
          'rotationDegrees': 0,
        };
      }
      return null;
    });
    messenger.setMockMethodCallHandler(captureChannel, (call) async => null);
  });

  tearDown(() {
    Analytics.testSink = null;
    messenger.setMockMethodCallHandler(previewChannel, null);
    messenger.setMockMethodCallHandler(captureChannel, null);
    detections.close();
  });

  Future<void> pumpScreen(
    WidgetTester tester, {
    Stream<PlacementDetection>? source,
  }) async {
    await tester.pumpWidget(ProviderScope(
      overrides: [
        captureConfigProvider.overrideWith(() => _StubConfigNotifier()),
        orientationSourceProvider
            .overrideWithValue(const Stream<SmoothedOrientation>.empty()),
        stabilityEventSourceProvider
            .overrideWithValue(const Stream<StabilityEvent>.empty()),
        placementDetectionSourceProvider
            .overrideWithValue(source ?? detections.stream),
      ],
      child: MaterialApp(
        home: CaptureScreen(
          levelLabel: 'Level A',
          levelName: 'Eye Ring',
          nextRoute: '/next',
          sessionBox: _FakeSessionBox(),
          autoCaptureStore: _FakeAutoCaptureStore(),
          captureSettingsStore: _FakeCaptureSettingsStore(),
        ),
      ),
    ));
    await tester.pump(); // post-frame start
    await tester.pump(); // preview running
  }

  Future<void> emit(WidgetTester tester, PlacementDetection d) async {
    detections.add(d);
    await tester.pump();
    await tester.pump();
  }

  Future<void> teardownScreen(WidgetTester tester) async {
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pumpWidget(const SizedBox());
  }

  testWidgets('detections drive the guide through its full state cycle',
      (tester) async {
    await pumpScreen(tester);

    // Idle before any detection.
    expect(find.text('Place the object inside the box'), findsOneWidget);

    await emit(tester, _good);
    expect(find.text('Looks good — hold steady'), findsOneWidget);

    await emit(tester, _offCenter);
    expect(find.text('Center the object'), findsOneWidget);

    await emit(tester, _tooClose);
    expect(find.text('Move back'), findsOneWidget);

    await emit(tester, _tooFar);
    expect(find.text('Move closer'), findsOneWidget);

    // Object leaves the frame → guide settles back to idle.
    await emit(tester, PlacementDetection.none);
    expect(find.text('Place the object inside the box'), findsOneWidget);

    await teardownScreen(tester);
  });

  testWidgets('transitions emit placement_status_changed (transition-only)',
      (tester) async {
    await pumpScreen(tester);

    await emit(tester, _good);
    await emit(tester, _good); // same status → no second event
    await emit(tester, _offCenter);

    final placement = events
        .where((e) => e.$1 == AnalyticsEvents.placementStatusChanged)
        .map((e) => (e.$2['from'], e.$2['to']))
        .toList();
    expect(placement, [('idle', 'good'), ('good', 'offCenter')]);

    await teardownScreen(tester);
  });

  testWidgets('a detector error rests the guide at idle — never a warning',
      (tester) async {
    final broken = StreamController<PlacementDetection>.broadcast();
    await pumpScreen(tester, source: broken.stream);

    broken.addError(PlatformException(code: 'PLACEMENT_UNAVAILABLE'));
    await tester.pump();
    await tester.pump();

    expect(find.text('Place the object inside the box'), findsOneWidget);
    expect(find.text('Center the object'), findsNothing);
    expect(find.text('Move back'), findsNothing);
    expect(find.text('Move closer'), findsNothing);

    await broken.close();
    await teardownScreen(tester);
  });
}
