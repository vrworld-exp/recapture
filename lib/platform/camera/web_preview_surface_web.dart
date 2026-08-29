// lib/platform/camera/web_preview_surface_web.dart
//
// Web half of the platform-split preview surface: an [HtmlElementView] over the
// `<video>` element WebCameraSource owns.
//
// The element carries `object-fit: cover`, which is the browser's equivalent of
// the Android path's `BoxFit.cover` FittedBox — so the preview fills the
// viewport without stretching, and the framing the user sees matches the framing
// the still capture crops from.
import 'package:flutter/widgets.dart';

import '../capture_ports/web_camera_source.dart';

/// The live browser camera feed. The view factory is registered by
/// `WebCameraPreviewPort.start()`; registering again here is a no-op and guards
/// the case where the widget rebuilds before a start has resolved.
Widget buildWebCameraPreview() {
  WebCameraSource.instance.registerViewFactory();
  return const HtmlElementView(viewType: kWebCameraPreviewViewType);
}
