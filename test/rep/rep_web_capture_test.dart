// test/rep/rep_web_capture_test.dart
//
// The browser six-shot capture, driven from the VM.
//
// The camera seam is a PROVIDER for the same reason every other platform seam
// in this tree is: `dart:ui_web` and `getUserMedia` cannot run here, so the only
// way to assert the screen's behaviour from the one `flutter test` run CI does
// is to override the factory with a fake. A `kIsWeb` branch would have made
// this file impossible to write.
//
// WHAT IS WORTH PINNING. Not the pixels — the two rules that would silently
// rot: the shot count is a HARD SIX (the meshy pipeline's shape, not a
// preference), and a camera that will not start must reach the way out rather
// than a dead screen.
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:recapture/application/rep/web_capture_upload.dart';
import 'package:recapture/application/rep/web_dish_camera.dart';
import 'package:recapture/presentation/screens/rep/rep_web_capture_screen.dart';

/// A camera that always starts and always yields the same two bytes.
class _FakeCamera implements WebDishCamera {
  int grabs = 0;
  bool stopped = false;

  @override
  Future<void> start() async {}

  @override
  Widget preview() => const SizedBox.expand();

  @override
  Future<Uint8List> grabFrame() async {
    grabs++;
    return Uint8List.fromList([0xFF, 0xD8]);
  }

  @override
  Future<void> stop() async => stopped = true;
}

/// A camera that refuses to start — denied permission, an insecure origin, or
/// a laptop with the lid shut on its webcam.
class _DeadCamera implements WebDishCamera {
  @override
  Future<void> start() async =>
      throw const WebDishCameraException('Camera access was blocked.');

  @override
  Widget preview() => const SizedBox.shrink();

  @override
  Future<Uint8List> grabFrame() async => throw StateError('never started');

  @override
  Future<void> stop() async {}
}

/// Records what the screen hands the upload layer, without any network.
class _RecordingUploader implements WebCaptureUploader {
  List<WebCapturePhoto>? photos;
  String? projectName;

  @override
  Future<WebCaptureUploadResult> upload({
    required String projectName,
    required List<WebCapturePhoto> photos,
    void Function(int sent, int total)? onProgress,
  }) async {
    this.projectName = projectName;
    this.photos = photos;
    return const WebCaptureUploadResult(projectId: 'p1', jobId: 'j1');
  }
}

Widget _app(
  WebDishCamera camera, {
  required WebCaptureUploader uploader,
}) =>
    ProviderScope(
      overrides: [
        webDishCameraFactoryProvider.overrideWithValue(() => camera),
        webCaptureUploaderProvider.overrideWithValue(uploader),
      ],
      child: const MaterialApp(
        home: RepWebCaptureScreen(dishName: 'Paneer Tikka'),
      ),
    );

Future<void> _shoot(WidgetTester tester, int times) async {
  for (var i = 0; i < times; i++) {
    await tester.tap(find.byKey(const ValueKey('rep_web_capture_shutter')));
    await tester.pumpAndSettle();
  }
}

void main() {
  testWidgets('the shutter stays until SIX, then becomes the finish button',
      (tester) async {
    final uploader = _RecordingUploader();
    await tester.pumpWidget(_app(_FakeCamera(), uploader: uploader));
    await tester.pumpAndSettle();

    // Five is not enough — the meshy selector picks 4 of 6 and the count is the
    // pipeline's shape, not a target the rep may undershoot.
    await _shoot(tester, kWebCaptureShotCount - 1);
    expect(find.byKey(const ValueKey('rep_web_capture_shutter')), findsOneWidget);
    expect(find.byKey(const ValueKey('rep_web_capture_finish')), findsNothing);

    await _shoot(tester, 1);
    expect(find.byKey(const ValueKey('rep_web_capture_shutter')), findsNothing);
    expect(find.byKey(const ValueKey('rep_web_capture_finish')), findsOneWidget);
  });

  testWidgets('retake last drops exactly one shot', (tester) async {
    final uploader = _RecordingUploader();
    await tester.pumpWidget(_app(_FakeCamera(), uploader: uploader));
    await tester.pumpAndSettle();

    await _shoot(tester, kWebCaptureShotCount);
    expect(find.byKey(const ValueKey('rep_web_capture_finish')), findsOneWidget);

    await tester.tap(find.text('Retake last'));
    await tester.pumpAndSettle();

    // Back to shooting — and back to needing exactly one more.
    expect(find.byKey(const ValueKey('rep_web_capture_shutter')), findsOneWidget);
    expect(find.text('Take photo $kWebCaptureShotCount'), findsOneWidget);
  });

  testWidgets('finishing hands over six photos, indexed in order',
      (tester) async {
    final camera = _FakeCamera();
    final uploader = _RecordingUploader();
    await tester.pumpWidget(_app(camera, uploader: uploader));
    await tester.pumpAndSettle();

    await _shoot(tester, kWebCaptureShotCount);
    await tester.tap(find.byKey(const ValueKey('rep_web_capture_finish')));
    await tester.pumpAndSettle();

    expect(uploader.photos, hasLength(kWebCaptureShotCount));
    // The segment index is the ORDER the rep shot in. Nothing measured it, but
    // it must at least be the sequence — a shuffled or constant index would
    // throw away the one positional signal this flow has.
    expect(
      uploader.photos!.map((p) => p.segmentIndex).toList(),
      List.generate(kWebCaptureShotCount, (i) => i),
    );
    // The PROJECT carries the dish's name, which is how the rep finds this
    // capture in the picker afterwards.
    expect(uploader.projectName, 'Paneer Tikka');
    // The device is released before the upload, not at dispose.
    expect(camera.stopped, isTrue);
  });

  testWidgets('a camera that will not start offers the way out, not a dead end',
      (tester) async {
    final uploader = _RecordingUploader();
    await tester.pumpWidget(_app(_DeadCamera(), uploader: uploader));
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey('rep_web_capture_unavailable')),
      findsOneWidget,
    );
    // No shutter to tap at, and a stated alternative — a rep whose webcam is
    // blocked can still add the dish from a photo one screen back.
    expect(find.byKey(const ValueKey('rep_web_capture_shutter')), findsNothing);
    expect(find.textContaining('from a photo instead'), findsOneWidget);
    expect(find.text('Go back'), findsOneWidget);
  });
}
