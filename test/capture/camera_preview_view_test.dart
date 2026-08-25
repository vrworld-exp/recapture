// test/capture/camera_preview_view_test.dart
//
// Verifies the platform-specific render branches of [CameraPreview]: Android
// draws the external `Texture`; iOS embeds the native preview via a `UiKitView`
// (mounted only when the session is live), and both share the placeholder /
// error surfaces. The lifecycle contract itself is covered by
// camera_preview_controller_test.dart.
//
// NOTE: debugDefaultTargetPlatformOverride is set AND reset inside each test
// body — the foundation-var invariant check runs before tearDown, so a setUp/
// tearDown pair would fail. (See the repo's debugDefaultTargetPlatformOverride
// gotcha.)
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:recapture/platform/camera/camera_preview_controller.dart';
import 'package:recapture/platform/camera/camera_preview_view.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  CameraPreviewController makeController(CameraPreviewState state) {
    final controller = CameraPreviewController()..value = state;
    addTearDown(controller.dispose);
    return controller;
  }

  Future<void> pump(WidgetTester tester, CameraPreviewState state) {
    return tester.pumpWidget(
      MaterialApp(home: CameraPreview(controller: makeController(state))),
    );
  }

  /// Stubs the platform-views system channel so a `UiKitView` can be created
  /// under test without throwing.
  void stubPlatformViews(WidgetTester tester) {
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform_views,
      (call) async => 0,
    );
    addTearDown(() => tester.binding.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform_views, null));
  }

  group('iOS render path', () {
    testWidgets('running → embeds the UiKitView platform view', (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      stubPlatformViews(tester);

      await pump(
        tester,
        const CameraPreviewState(status: CameraPreviewStatus.running),
      );

      expect(find.byType(UiKitView), findsOneWidget);
      debugDefaultTargetPlatformOverride = null;
    });

    testWidgets('interrupted → keeps the platform view mounted', (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      stubPlatformViews(tester);

      await pump(
        tester,
        const CameraPreviewState(status: CameraPreviewStatus.interrupted),
      );

      expect(find.byType(UiKitView), findsOneWidget);
      debugDefaultTargetPlatformOverride = null;
    });

    testWidgets('stopped → placeholder, no platform view', (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;

      await pump(
        tester,
        const CameraPreviewState(status: CameraPreviewStatus.stopped),
      );

      expect(find.byType(UiKitView), findsNothing);
      debugDefaultTargetPlatformOverride = null;
    });

    testWidgets('error → error surface, no platform view', (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;

      await pump(
        tester,
        const CameraPreviewState(
          status: CameraPreviewStatus.error,
          errorMessage: 'Camera unavailable',
        ),
      );

      expect(find.byType(UiKitView), findsNothing);
      expect(find.text('Camera unavailable'), findsOneWidget);
      debugDefaultTargetPlatformOverride = null;
    });
  });

  group('Android render path', () {
    testWidgets('texture ready → draws Texture, never a UiKitView',
        (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;

      await pump(
        tester,
        const CameraPreviewState(
          status: CameraPreviewStatus.running,
          textureId: 3,
          previewWidth: 1280,
          previewHeight: 720,
        ),
      );

      expect(find.byType(Texture), findsOneWidget);
      expect(find.byType(UiKitView), findsNothing);
      debugDefaultTargetPlatformOverride = null;
    });
  });
}
