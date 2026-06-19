// test/capture/capture_screen_shutter_test.dart
//
// Verifies the capture screen's shutter is wired to the NATIVE single-capture
// channel (com.mayasabhaxr.recapture/capture), not a UI-only stub: a tap calls
// `captureSingle`, and the frame counter advances ONLY when a real frame comes
// back (a null result — no bound session / busy / non-device test host — must not
// advance it). The preview channel is mocked so the screen boots in a test host.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:recapture/presentation/screens/capture/capture_screen.dart';
import 'package:recapture/utils/constants.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  const previewChannel = MethodChannel(AppConfig.channelCameraPreview);
  const captureChannel = MethodChannel(AppConfig.channelCapture);

  late List<String> captureCalls;
  // Set per-test: what the native captureSingle returns (a frame map, or null).
  late Map<String, dynamic>? captureResult;

  setUp(() {
    captureCalls = [];
    captureResult = null;

    // Preview: accept start (iOS-style status result), no-op stop/dispose.
    messenger.setMockMethodCallHandler(previewChannel, (call) async {
      if (call.method == 'start') return <String, dynamic>{'status': 'running'};
      return null;
    });
    messenger.setMockMethodCallHandler(captureChannel, (call) async {
      captureCalls.add(call.method);
      return captureResult;
    });
  });

  tearDown(() {
    messenger.setMockMethodCallHandler(previewChannel, null);
    messenger.setMockMethodCallHandler(captureChannel, null);
  });

  Future<void> pumpScreen(WidgetTester tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: CaptureScreen(
          levelLabel: 'Level A',
          levelName: 'Intro',
          nextRoute: '/next',
        ),
      ),
    );
    // Let the post-frame callback fire start() on the preview controller.
    await tester.pump();
  }

  // Unmounts the screen (disposing its periodic instruction timer + controller)
  // and lets the 200ms flash timer drain, so the test ends with no pending timers.
  Future<void> teardownScreen(WidgetTester tester) async {
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pumpWidget(const SizedBox());
  }

  testWidgets('shutter tap calls native captureSingle', (tester) async {
    captureResult = {'id': 'cap_0', 'path': '/tmp/cap_0.jpg', 'timestampNs': 1};
    await pumpScreen(tester);

    await tester.tap(find.byKey(const ValueKey('capture_shutter')));
    await tester.pump(); // resolve captureSingle future
    await tester.pump(); // apply setState

    expect(captureCalls, contains('captureSingle'));
    await teardownScreen(tester);
  });

  testWidgets('a successful capture advances the frame counter', (tester) async {
    captureResult = {'id': 'cap_0', 'path': '/tmp/cap_0.jpg', 'timestampNs': 1};
    await pumpScreen(tester);

    // _BottomBar renders "${captureCount + 12}/36" — starts at 12/36.
    expect(find.text('12/36'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('capture_shutter')));
    await tester.pump();
    await tester.pump();

    expect(find.text('13/36'), findsOneWidget);
    await teardownScreen(tester);
  });

  testWidgets('a null capture (no frame) does NOT advance the counter',
      (tester) async {
    captureResult = null; // no bound session / busy / unsupported
    await pumpScreen(tester);

    expect(find.text('12/36'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('capture_shutter')));
    await tester.pump();
    await tester.pump();

    expect(captureCalls, contains('captureSingle'));
    expect(find.text('12/36'), findsOneWidget, reason: 'counter must not advance');
    expect(find.text('13/36'), findsNothing);
    await teardownScreen(tester);
  });
}
