// test/capture/camera_preview_controller_test.dart
//
// Verifies the Dart side of the native camera_preview channel
// (Architecture Decision A — external texture): start/stop/dispose contract,
// parsing of the start result, native-pushed onPreviewChanged / onError
// callbacks, and graceful degradation when the channel errors or is absent.
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:recapture/platform/camera/camera_preview_controller.dart';
import 'package:recapture/utils/constants.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel(AppConfig.channelCameraPreview);
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  final calls = <String>[];

  void setHandler(Future<Object?>? Function(MethodCall call) handler) {
    messenger.setMockMethodCallHandler(channel, (call) {
      calls.add(call.method);
      return handler(call);
    });
  }

  /// Emulates a native → Dart push on the same channel.
  Future<void> pushFromNative(String method, Object? args) async {
    final data = const StandardMethodCodec().encodeMethodCall(
      MethodCall(method, args),
    );
    await messenger.handlePlatformMessage(channel.name, data, (_) {});
  }

  setUp(calls.clear);
  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  test('start() parses textureId, resolution and rotation into running state',
      () async {
    setHandler((call) async {
      if (call.method == 'start') {
        return <String, dynamic>{
          'textureId': 42,
          'previewWidth': 1280,
          'previewHeight': 720,
          'rotationDegrees': 90,
        };
      }
      return null;
    });

    final controller = CameraPreviewController();
    addTearDown(controller.dispose);

    await controller.start();

    expect(controller.value.status, CameraPreviewStatus.running);
    expect(controller.value.textureId, 42);
    expect(controller.value.previewWidth, 1280);
    expect(controller.value.previewHeight, 720);
    expect(controller.value.rotationDegrees, 90);
    expect(controller.value.hasTexture, isTrue);
    expect(calls, contains('start'));
  });

  test('native PlatformException → graceful error state, no throw', () async {
    setHandler((call) async {
      throw PlatformException(code: 'NO_BACK_CAMERA', message: 'No back camera');
    });

    final controller = CameraPreviewController();
    addTearDown(controller.dispose);

    await controller.start();

    expect(controller.value.status, CameraPreviewStatus.error);
    expect(controller.value.errorCode, 'NO_BACK_CAMERA');
    expect(controller.value.hasTexture, isFalse);
  });

  test('missing plugin (no native host) → NO_PLUGIN error, no throw', () async {
    // No mock handler registered → MissingPluginException.
    final controller = CameraPreviewController();
    addTearDown(controller.dispose);

    await controller.start();

    expect(controller.value.status, CameraPreviewStatus.error);
    expect(controller.value.errorCode, 'NO_PLUGIN');
  });

  test('onPreviewChanged from native updates rotation/size in place', () async {
    setHandler((call) async => <String, dynamic>{
          'textureId': 7,
          'previewWidth': 640,
          'previewHeight': 480,
          'rotationDegrees': 0,
        });

    final controller = CameraPreviewController();
    addTearDown(controller.dispose);
    await controller.start();

    await pushFromNative('onPreviewChanged', <String, dynamic>{
      'previewWidth': 1920,
      'previewHeight': 1080,
      'rotationDegrees': 270,
    });

    expect(controller.value.textureId, 7, reason: 'texture unchanged');
    expect(controller.value.previewWidth, 1920);
    expect(controller.value.rotationDegrees, 270);
  });

  test('onError from native flips to error state', () async {
    setHandler((call) async => <String, dynamic>{
          'textureId': 1,
          'previewWidth': 100,
          'previewHeight': 100,
          'rotationDegrees': 0,
        });

    final controller = CameraPreviewController();
    addTearDown(controller.dispose);
    await controller.start();

    await pushFromNative('onError', <String, dynamic>{
      'code': 'CAMERA_DISCONNECTED',
      'message': 'Camera was taken by another app',
    });

    expect(controller.value.status, CameraPreviewStatus.error);
    expect(controller.value.errorCode, 'CAMERA_DISCONNECTED');
  });

  test('stop() releases texture but keeps controller reusable', () async {
    setHandler((call) async {
      if (call.method == 'start') {
        return <String, dynamic>{
          'textureId': 9,
          'previewWidth': 100,
          'previewHeight': 100,
          'rotationDegrees': 0,
        };
      }
      return null;
    });

    final controller = CameraPreviewController();
    addTearDown(controller.dispose);

    await controller.start();
    await controller.stop();

    expect(controller.value.status, CameraPreviewStatus.stopped);
    expect(controller.value.textureId, isNull);
    expect(calls, contains('stop'));

    // Restartable after stop.
    await controller.start();
    expect(controller.value.status, CameraPreviewStatus.running);
    expect(controller.value.textureId, 9);
  });

  test('dispose() sends native dispose and ignores later native pushes',
      () async {
    setHandler((call) async => null);

    final controller = CameraPreviewController();
    await controller.start();
    controller.dispose();

    // A late native push after dispose must not throw / mutate.
    await pushFromNative('onError', <String, dynamic>{'code': 'LATE'});

    expect(controller.isDisposed, isTrue);
    expect(calls, contains('dispose'));
  });
}
