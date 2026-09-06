// lib/platform/ar_quick_look_channel.dart
//
// MethodChannel wrapper for native iOS AR Quick Look (QLPreviewController).
// Channel name: com.mayasabhaxr.recapture/ar_quicklook
//
// WHY A NATIVE CHANNEL rather than the web component we already embed:
// `<model-viewer>` disables AR Quick Look inside an app WebView (its
// IS_AR_QUICKLOOK_CANDIDATE collapses to a user-agent whitelist the moment
// `window.webkit.messageHandlers` exists), so `canActivateAR` never flips and
// the plugin's Quick Look intercept never fires. Opening the CloudFront USDZ
// with url_launcher instead only lands the user on the model PAGE, where they
// must find and tap AR a second time. QLPreviewController is what makes
// "View in AR" one tap. See ModelRenderViewState.canQuickLook and the iOS
// ARQuickLookManager for the whole story.
//
// iOS-only. Android reaches AR through Scene Viewer inside model_viewer_plus
// and never calls this; the guard lives at the call site, not here.
import 'package:flutter/services.dart';

import '../utils/constants.dart';

/// Why an AR Quick Look presentation did not happen. The raw platform error is
/// deliberately not carried: the viewer maps these to its own copy, and the
/// USDZ url must never reach the user (same rule as the load-failure body).
enum ArQuickLookFailure {
  /// The USDZ could not be fetched — offline, or the object is gone.
  download,

  /// A preview is already on screen (a double tap), or there was no view
  /// controller to present from. Nothing to tell the user; they already have
  /// AR open, or are mid-transition.
  busy,

  /// The channel is not wired on this platform — Android, web, or an iOS build
  /// predating ARQuickLookManager.
  unsupported,
}

/// Thin Dart side of the native AR Quick Look presenter.
class ArQuickLookChannel {
  ArQuickLookChannel({MethodChannel? channel})
      : _channel = channel ?? const MethodChannel(AppConfig.channelArQuickLook);

  final MethodChannel _channel;

  /// Downloads [usdzUrl] if needed and presents it in AR Quick Look.
  ///
  /// Returns null on success, or the reason it could not be shown. Completes
  /// as soon as the preview is ON SCREEN — not when the user dismisses it —
  /// so the caller can drop its pending state rather than spin behind a modal
  /// the user may sit in for minutes.
  Future<ArQuickLookFailure?> present(String usdzUrl) async {
    try {
      final shown =
          await _channel.invokeMethod<bool>('preview', {'url': usdzUrl});
      return shown == true ? null : ArQuickLookFailure.download;
    } on MissingPluginException {
      return ArQuickLookFailure.unsupported;
    } on PlatformException catch (e) {
      return switch (e.code) {
        'already_presenting' || 'no_presenter' => ArQuickLookFailure.busy,
        'invalid_url' || 'download_failed' => ArQuickLookFailure.download,
        _ => ArQuickLookFailure.download,
      };
    }
  }
}
