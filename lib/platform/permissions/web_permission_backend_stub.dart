// lib/platform/permissions/web_permission_backend_stub.dart
//
// Non-web half of the platform-split browser permission backend. Selected on
// every build that is not web, where it is unreachable: `PermissionsService`
// only routes to it when `kIsWeb`. It exists so the Android/iOS build never
// compiles `dart:js_interop`.
//
// The vocabulary is the shared NATIVE status-string vocabulary
// (`granted|denied|permanentlyDenied|restricted|limited|unavailable`), not the
// app enum — so `normalizeNativeStatus` maps a browser answer with the exact
// same function it maps an Android one, and no new UI state can creep in.
import 'android_permission_channel.dart';

Future<String> webPermissionStatus(String permission) async =>
    AndroidPermissionStatus.denied;

Future<String> webPermissionRequest(String permission) async =>
    AndroidPermissionStatus.denied;

/// A browser has no app-settings page to deep-link to.
Future<bool> webOpenPermissionSettings() async => false;
