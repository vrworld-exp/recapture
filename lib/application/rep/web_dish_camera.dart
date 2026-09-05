// lib/application/rep/web_dish_camera.dart
//
// The browser dish camera, behind the same conditional-import seam every other
// platform capability in this tree uses — see rep_capabilities.dart for the
// full argument, which applies here unchanged:
//
//   • the unsupported path is NOT COMPILED IN, so `dart:ui_web` and
//     `package:web` can never reach a phone build even by accident;
//   • the capability is exposed as PROVIDER state rather than a `kIsWeb`
//     branch, so a widget test can drive both renderings from the one
//     `flutter test` run CI does.
//
// Distinct from `rep_capabilities.dart` on purpose. That seam answers "should
// this build OFFER a camera dish source"; this one answers "and what does the
// camera actually do". Merging them would put `dart:ui_web` behind the flag two
// screens read just to decide whether to show a list item.
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'web_dish_camera_stub.dart'
    if (dart.library.io) 'web_dish_camera_io.dart'
    if (dart.library.js_interop) 'web_dish_camera_web.dart';

export 'web_dish_camera_stub.dart' show WebDishCamera, WebDishCameraException;

/// Whether this build has a browser camera to open. Overridden in tests.
final hasWebDishCameraProvider = Provider<bool>((ref) => kHasWebDishCamera);

/// Builds a fresh camera for one capture screen.
///
/// A FACTORY, not a singleton: the stream belongs to the screen that opened it
/// and dies with it. A shared instance would leave the device live between
/// visits to the screen, which is the failure the `_web` variant's lifecycle
/// note is about.
final webDishCameraFactoryProvider = Provider<WebDishCamera Function()>(
  (ref) => createWebDishCamera,
);
