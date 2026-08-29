// lib/platform/capture_ports/capture_image_source.dart
//
// PORT: "turn a CapturedFrame.path into something Flutter can draw".
//
// This is the seam that lets the thumbnail strip and the review grids stop
// saying `Image.file(File(path))`. That call is not merely unsupported on web —
// `dart:io` does not exist there, so its mere presence in the import graph
// fails `flutter build web` outright.
//
// Native resolves the path to a real file. Web resolves the opaque `idb://…`
// handle through the IndexedDB capture store. Both hand back an [ImageProvider],
// so callers keep every existing affordance — `ResizeImage` for the
// decode-at-tile-size guard, `gaplessPlayback`, `frameBuilder`, `errorBuilder`.
//
// This mirrors the precedent already set by
// lib/data/datasources/project_photo_picker.dart, which carries `bytes` on web
// and `path` on native rather than inventing a second convention.
import 'package:flutter/widgets.dart';

import 'capture_image_source_stub.dart'
    if (dart.library.io) 'capture_image_source_io.dart'
    if (dart.library.js_interop) 'capture_image_source_web.dart';

/// An [ImageProvider] for a captured frame's platform handle.
///
/// [path] is whatever `CapturedFrame.path` / `CapturedPhotoRecord.framePath`
/// holds: a filesystem path natively, an `idb://{projectId}/{jobId}/{level}/
/// {frameId}.jpg` handle on web. Callers never branch on which.
///
/// A missing or unreadable frame surfaces through the normal image-error path,
/// so an existing `errorBuilder` keeps rendering its broken-image placeholder
/// instead of a red error box.
ImageProvider captureImage(String path) => createCaptureImage(path);
