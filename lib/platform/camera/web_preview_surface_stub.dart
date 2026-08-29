// lib/platform/camera/web_preview_surface_stub.dart
//
// Non-web half of the platform-split web preview surface. Selected on every
// build that is not web, where it is never actually reached: [CameraPreview]
// only calls [buildWebCameraPreview] behind a `kIsWeb` branch. It exists so the
// Android/iOS build never has to compile `dart:ui_web`.
import 'package:flutter/widgets.dart';

/// Unreachable off web; returns an empty box rather than throwing so a
/// mis-wired branch degrades to the placeholder instead of crashing the tree.
Widget buildWebCameraPreview() => const SizedBox.shrink();
