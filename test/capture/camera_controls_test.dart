// test/capture/camera_controls_test.dart
//
// Verifies the Dart wrapper for the manual focus / exposure lock controls on the
// native camera_preview channel: capability parsing, argument forwarding, and
// graceful degradation (unbound camera / unsupported control / missing plugin).
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:recapture/platform/camera/camera_controls.dart';
import 'package:recapture/utils/constants.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel(AppConfig.channelCameraPreview);
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  final calls = <MethodCall>[];

  void setHandler(Future<Object?>? Function(MethodCall call) handler) {
    messenger.setMockMethodCallHandler(channel, (call) {
      calls.add(call);
      return handler(call);
    });
  }

  setUp(calls.clear);
  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  test('getCapabilities parses flags and focus-distance range', () async {
    setHandler((call) async => <String, dynamic>{
          'aeLock': true,
          'awbLock': false,
          'manualFocus': true,
          'focusDistanceRange': {'min': 0.0, 'max': 10.0},
        });

    final caps = await CameraControls().getCapabilities();

    expect(caps.aeLock, isTrue);
    expect(caps.awbLock, isFalse);
    expect(caps.manualFocus, isTrue);
    expect(caps.focusDistanceRange?.min, 0.0);
    expect(caps.focusDistanceRange?.max, 10.0);
  });

  test('getCapabilities with no plugin → none, no throw', () async {
    final caps = await CameraControls().getCapabilities();
    expect(caps.aeLock, isFalse);
    expect(caps.manualFocus, isFalse);
    expect(caps.focusDistanceRange, isNull);
  });

  test('setExposureLock / AWB / focus forward the locked arg', () async {
    setHandler((call) async => null);
    final controls = CameraControls();

    await controls.setExposureLock(true);
    await controls.setAutoWhiteBalanceLock(false);
    await controls.setFocusLocked(true);

    expect(calls.map((c) => c.method), [
      'setExposureLock',
      'setAutoWhiteBalanceLock',
      'setFocusLocked',
    ]);
    expect(calls[0].arguments, {'locked': true});
    expect(calls[1].arguments, {'locked': false});
    expect(calls[2].arguments, {'locked': true});
  });

  test('setManualFocusDistance forwards distance', () async {
    setHandler((call) async => null);
    await CameraControls().setManualFocusDistance(3.5);

    expect(calls.single.method, 'setManualFocusDistance');
    expect(calls.single.arguments, {'distance': 3.5});
  });

  test('unlockAll invokes the native method', () async {
    setHandler((call) async => null);
    final ok = await CameraControls().unlockAll();

    expect(ok, isTrue);
    expect(calls.single.method, 'unlockAll');
  });

  test('NO_CAMERA / UNSUPPORTED PlatformException → returns false, no throw',
      () async {
    setHandler((call) async {
      throw PlatformException(code: 'NO_CAMERA', message: 'No camera bound');
    });

    final controls = CameraControls();
    expect(await controls.setExposureLock(true), isFalse);
    expect(await controls.setManualFocusDistance(1.0), isFalse);
    expect(await controls.unlockAll(), isFalse);
  });

  test('missing plugin → setters return false', () async {
    final controls = CameraControls();
    expect(await controls.setFocusLocked(true), isFalse);
  });
}
