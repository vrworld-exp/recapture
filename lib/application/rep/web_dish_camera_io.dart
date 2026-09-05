// lib/application/rep/web_dish_camera_io.dart
//
// Native variant: there is no browser camera here, and that is not a gap.
//
// A phone already has the 6-photo RING — the bespoke capture pipeline in
// lib/platform/camera, with exposure, blur, stability and IMU yaw guidance. The
// browser flow this seam serves is a REPLACEMENT for that on a target where the
// sensors do not exist, never an alternative to it. Offering both on a phone
// would mean a rep could pick the worse capture by accident.
//
// The TYPES come from the stub (one definition of the interface, so the two
// targets cannot drift), but the flag and the factory are declared HERE rather
// than exported. A seam that re-exports its answers reads as "not implemented
// yet"; declaring them says this target has considered the question.
//
// Deliberately no `dart:io` import: nothing here touches the filesystem, and
// the rep tree's structural guard (test/catalog/web_parity_test.dart) is easier
// to reason about when the `_io` half only carries one when it truly needs one.
import 'web_dish_camera_stub.dart';

export 'web_dish_camera_stub.dart' show WebDishCamera, WebDishCameraException;

const bool kHasWebDishCamera = false;

WebDishCamera createWebDishCamera() =>
    throw UnsupportedError('Native builds capture with the 6-photo ring.');
