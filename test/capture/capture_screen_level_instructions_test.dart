// test/capture/capture_screen_level_instructions_test.dart
//
// Screen 6B — Level B reuses the 6A capture screen, driven by a per-level
// instruction cycle. Verifies: Level B renders its tuned lead instruction
// ("Tilt down to show the top") in the SAME HUD pill 6A uses + the "B" / "Top
// Ring" level indicator; Level A's default copy is unchanged; and an empty
// instruction list falls back to the default (no crash / no empty cycle).
//
// The capture engine, camera channel, and sensor streams are mocked/inert — this
// only exercises the label + instruction wiring, not capture behavior.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:recapture/application/capture/current_tilt_provider.dart';
import 'package:recapture/application/capture/stability_provider.dart';
import 'package:recapture/application/config/config_notifier.dart';
import 'package:recapture/data/local/active_session_box.dart';
import 'package:recapture/data/local/auto_capture_box.dart';
import 'package:recapture/data/local/capture_settings_box.dart';
import 'package:recapture/domain/entities/active_session.dart';
import 'package:recapture/domain/entities/capture_settings.dart';
import 'package:recapture/domain/entities/capture_config.dart';
import 'package:recapture/presentation/screens/capture/capture_screen.dart';
import 'package:recapture/platform/imu_rotation_channel.dart';
import 'package:recapture/platform/stability_channel.dart';
import 'package:recapture/utils/constants.dart';

/// ActiveSessionBox stand-in (Hive is not initialized in this test host).
class _FakeSessionBox extends ActiveSessionBox {
  @override
  Future<ActiveSession?> read() async => null;
}

class _FakeAutoCaptureStore implements AutoCaptureStore {
  @override
  Future<bool?> getEnabled() async => null;
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

Widget _scoped(Widget child) => ProviderScope(
      overrides: [
        captureConfigProvider.overrideWith(() => _StubConfigNotifier()),
        orientationSourceProvider
            .overrideWithValue(const Stream<SmoothedOrientation>.empty()),
        stabilityEventSourceProvider
            .overrideWithValue(const Stream<StabilityEvent>.empty()),
      ],
      child: child,
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  const previewChannel = MethodChannel(AppConfig.channelCameraPreview);
  const captureChannel = MethodChannel(AppConfig.channelCapture);

  setUp(() {
    messenger.setMockMethodCallHandler(previewChannel, (call) async {
      if (call.method == 'start') return <String, dynamic>{'status': 'running'};
      return null;
    });
    messenger.setMockMethodCallHandler(captureChannel, (call) async => null);
  });

  tearDown(() {
    messenger.setMockMethodCallHandler(previewChannel, null);
    messenger.setMockMethodCallHandler(captureChannel, null);
  });

  Future<void> pumpScreen(
    WidgetTester tester, {
    required String levelLabel,
    required String levelName,
    List<String> instructions = kDefaultCaptureInstructions,
  }) async {
    await tester.pumpWidget(
      _scoped(
        MaterialApp(
          home: CaptureScreen(
            levelLabel: levelLabel,
            levelName: levelName,
            nextRoute: '/next',
            instructions: instructions,
            sessionBox: _FakeSessionBox(),
            autoCaptureStore: _FakeAutoCaptureStore(),
            captureSettingsStore: _FakeCaptureSettingsStore(),
          ),
        ),
      ),
    );
    // Let the post-frame callback fire start() on the preview controller.
    await tester.pump();
  }

  Future<void> teardownScreen(WidgetTester tester) async {
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pumpWidget(const SizedBox());
  }

  testWidgets('Level B shows its tuned lead instruction + "B" / "Top Ring"',
      (tester) async {
    await pumpScreen(
      tester,
      levelLabel: 'B',
      levelName: 'Top Ring',
      instructions: kLevelBCaptureInstructions,
    );

    // Tuned top-ring lead cue (index 0) renders in the instruction pill.
    expect(find.text('Tilt down to show the top'), findsOneWidget);
    // The default Level A lead cue must NOT appear for Level B.
    expect(find.text('Move clockwise'), findsNothing);
    // Level indicator shows the label + subtitle (shared top-bar slot).
    expect(find.text('B'), findsOneWidget);
    expect(find.text('Top Ring'), findsOneWidget);

    await teardownScreen(tester);
  });

  testWidgets('Level C shows its tuned lead instruction + "C" / "Low Ring"',
      (tester) async {
    await pumpScreen(
      tester,
      levelLabel: 'C',
      levelName: 'Low Ring',
      instructions: kLevelCCaptureInstructions,
    );

    // Tuned low-ring lead cue (index 0) renders in the instruction pill.
    expect(find.text('Tilt up to show the base'), findsOneWidget);
    // Neither the default Level A nor the Level B lead cue appears for Level C.
    expect(find.text('Move clockwise'), findsNothing);
    expect(find.text('Tilt down to show the top'), findsNothing);
    // Level indicator shows the label + subtitle (shared top-bar slot).
    expect(find.text('C'), findsOneWidget);
    expect(find.text('Low Ring'), findsOneWidget);

    await teardownScreen(tester);
  });

  testWidgets('Level C cycles to its base-cutoff framing reminder',
      (tester) async {
    await pumpScreen(
      tester,
      levelLabel: 'C',
      levelName: 'Low Ring',
      instructions: kLevelCCaptureInstructions,
    );

    // Lead cue first; the base-framing reminder is the next cue in the cycle.
    expect(find.text('Tilt up to show the base'), findsOneWidget);

    // The cycle advances every 2s; pump past one tick (plus the banner's short
    // coalesce window) so the second cue is applied to the pill.
    await tester.pump(const Duration(seconds: 2));
    await tester.pump(const Duration(milliseconds: 200));

    expect(
      find.text("Keep the whole base in frame — don't cut off the bottom"),
      findsOneWidget,
    );

    await teardownScreen(tester);
  });

  testWidgets('Level A (default copy) is unchanged', (tester) async {
    await pumpScreen(tester, levelLabel: 'A', levelName: 'Eye Ring');

    expect(find.text('Move clockwise'), findsOneWidget);
    expect(find.text('Tilt down to show the top'), findsNothing);

    await teardownScreen(tester);
  });

  testWidgets('empty instruction list falls back to the default (no crash)',
      (tester) async {
    await pumpScreen(
      tester,
      levelLabel: 'B',
      levelName: 'Top Ring',
      instructions: const [],
    );

    // Falls back to kDefaultCaptureInstructions rather than an empty cycle.
    expect(find.text('Move clockwise'), findsOneWidget);
    expect(tester.takeException(), isNull);

    await teardownScreen(tester);
  });
}
