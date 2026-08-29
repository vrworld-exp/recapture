// lib/platform/capture_ports/capture_image_source_io.dart
//
// NATIVE half of [captureImage]: a captured frame's path IS a file path, so the
// provider is the plain `FileImage` the thumbnail strip and review grids used
// directly before the port existed. Behaviour on Android and iOS is unchanged.
import 'dart:io';

import 'package:flutter/widgets.dart';

ImageProvider createCaptureImage(String path) => FileImage(File(path));
