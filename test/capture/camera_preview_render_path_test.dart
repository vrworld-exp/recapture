// test/capture/camera_preview_render_path_test.dart
//
// Regression cover for the black-preview bug.
//
// `CameraPreview.build` used to branch on `defaultTargetPlatform`, which on web
// reports the HOST OS rather than "web". A phone browser therefore took the
// Android `Texture(textureId)` path or the iOS `UiKitView` path — both dead —
// and since `hasTexture` is never true on web (there is no texture id), the
// widget showed its placeholder forever.
//
// The rule is now a pure function, so the invariant can be asserted directly on
// the VM for EVERY host platform and EVERY state, rather than only in whichever
// environment the test happens to run in: on web, neither native path is ever
// reachable.
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:recapture/platform/camera/camera_preview_controller.dart';
import 'package:recapture/platform/camera/camera_preview_view.dart';

const _everyStatus = CameraPreviewStatus.values;

const _everyPlatform = TargetPlatform.values;

void main() {
  group('web never reaches a native render path', () {
    test(
        'no (platform, status, textureId) combination yields Texture/UiKitView',
        () {
      for (final platform in _everyPlatform) {
        for (final status in _everyStatus) {
          for (final textureId in <int?>[null, 7]) {
            final path = resolveCameraPreviewRenderPath(
              isWeb: true,
              platform: platform,
              state: CameraPreviewState(
                status: status,
                textureId: textureId,
                previewWidth: 1920,
                previewHeight: 1080,
              ),
            );
            expect(
              path,
              isNot(CameraPreviewRenderPath.androidTexture),
              reason: 'platform=$platform status=$status texture=$textureId',
            );
            expect(
              path,
              isNot(CameraPreviewRenderPath.iosPlatformView),
              reason: 'platform=$platform status=$status texture=$textureId',
            );
          }
        }
      }
    });

    test('a running web preview draws the HTML element even with no texture',
        () {
      // The exact shape a browser produces: no texture id at all.
      expect(
        resolveCameraPreviewRenderPath(
          isWeb: true,
          platform: TargetPlatform.android,
          state: const CameraPreviewState(
            status: CameraPreviewStatus.running,
            previewWidth: 1280,
            previewHeight: 720,
          ),
        ),
        CameraPreviewRenderPath.webElement,
      );
    });

    test('a non-running web preview shows the placeholder, not a stale frame',
        () {
      for (final status in <CameraPreviewStatus>[
        CameraPreviewStatus.idle,
        CameraPreviewStatus.starting,
        CameraPreviewStatus.stopped,
        CameraPreviewStatus.suspended,
      ]) {
        expect(
          resolveCameraPreviewRenderPath(
            isWeb: true,
            platform: TargetPlatform.iOS,
            state: CameraPreviewState(status: status),
          ),
          CameraPreviewRenderPath.placeholder,
          reason: 'status=$status',
        );
      }
    });

    test('a browser camera error still reaches the shared error surface', () {
      expect(
        resolveCameraPreviewRenderPath(
          isWeb: true,
          platform: TargetPlatform.iOS,
          state: const CameraPreviewState(
            status: CameraPreviewStatus.error,
            errorCode: 'PERMISSION_DENIED',
            errorMessage: 'Camera access was blocked.',
          ),
        ),
        CameraPreviewRenderPath.error,
      );
    });
  });

  group('native render paths are unchanged', () {
    test('Android with a texture draws the Texture', () {
      expect(
        resolveCameraPreviewRenderPath(
          isWeb: false,
          platform: TargetPlatform.android,
          state: const CameraPreviewState(
            status: CameraPreviewStatus.running,
            textureId: 3,
            previewWidth: 1920,
            previewHeight: 1080,
          ),
        ),
        CameraPreviewRenderPath.androidTexture,
      );
    });

    test('Android without a texture shows the placeholder', () {
      expect(
        resolveCameraPreviewRenderPath(
          isWeb: false,
          platform: TargetPlatform.android,
          state: const CameraPreviewState(
            status: CameraPreviewStatus.running,
          ),
        ),
        CameraPreviewRenderPath.placeholder,
      );
    });

    test('iOS embeds the platform view while running or interrupted', () {
      for (final status in <CameraPreviewStatus>[
        CameraPreviewStatus.running,
        CameraPreviewStatus.interrupted,
      ]) {
        expect(
          resolveCameraPreviewRenderPath(
            isWeb: false,
            platform: TargetPlatform.iOS,
            state: CameraPreviewState(status: status),
          ),
          CameraPreviewRenderPath.iosPlatformView,
          reason: 'status=$status',
        );
      }
    });

    test('iOS tears the platform view down once stopped/suspended', () {
      for (final status in <CameraPreviewStatus>[
        CameraPreviewStatus.stopped,
        CameraPreviewStatus.suspended,
        CameraPreviewStatus.idle,
      ]) {
        expect(
          resolveCameraPreviewRenderPath(
            isWeb: false,
            platform: TargetPlatform.iOS,
            state: CameraPreviewState(status: status),
          ),
          CameraPreviewRenderPath.placeholder,
          reason: 'status=$status',
        );
      }
    });
  });
}
