// lib/platform/permissions_service.dart
import 'package:flutter/foundation.dart';
// permission_handler is confined to THIS file (the facade implementation) and
// the thin [PermissionHandlerBackend] wrapper below — never imported elsewhere.
// Prefixed so the plugin's top-level `openAppSettings()` doesn't collide with
// our wrapper method.
import 'package:permission_handler/permission_handler.dart' as ph;
import '../domain/entities/permission_item.dart';
import 'permissions/android_permission_channel.dart';
import 'permissions/web_permission_backend_stub.dart'
    if (dart.library.js_interop) 'permissions/web_permission_backend_web.dart';

/// UI-facing permission status — the SINGLE output vocabulary for the whole app
/// (Screen 4A's controller, the permission cards, the settings launcher). The
/// raw [ph.PermissionStatus] from permission_handler and the native channel's
/// status strings never escape this file; everything normalizes to this enum.
enum AppPermissionStatus {
  notRequested,
  granted,
  denied,
  permanentlyDenied,
  restricted,
}

extension AppPermissionStatusX on AppPermissionStatus {
  bool get isGranted => this == AppPermissionStatus.granted;

  /// True when the only path forward is the OS settings screen.
  bool get needsSettings =>
      this == AppPermissionStatus.permanentlyDenied ||
      this == AppPermissionStatus.restricted;

  /// Analytics token. `restricted` is folded into `permanently_denied`
  /// because both gate identically (no in-app re-prompt is possible).
  String get analyticsValue => switch (this) {
        AppPermissionStatus.granted => 'granted',
        AppPermissionStatus.permanentlyDenied => 'permanently_denied',
        AppPermissionStatus.restricted => 'permanently_denied',
        AppPermissionStatus.denied => 'denied',
        AppPermissionStatus.notRequested => 'denied',
      };
}

/// The backend that serves a given (permission, platform) pair. Exactly one
/// backend per cell of the [_routingTable] — never two.
enum PermissionBackend {
  /// No OS permission exists for this capability, so it is always granted with
  /// no prompt. Used for `motion` (raw IMU: CMMotionManager on iOS, the
  /// equivalent sensors on Android) — NOT the "Motion & Fitness" /
  /// ACTIVITY_RECOGNITION activity permission, which the app does not use.
  permissionFree,

  /// The custom Android native MethodChannel ([AndroidPermissionChannel]):
  /// API-level-correct camera/storage handling + don't-ask-again → Settings.
  androidNative,

  /// The `permission_handler` plugin (via [PermissionHandlerBackend]).
  pluginHandler,

  /// The browser backend (permissions/web_permission_backend_web.dart):
  /// the Permissions API where it exists, `getUserMedia` as the camera prompt,
  /// and iOS Safari's `DeviceOrientationEvent.requestPermission()` handshake
  /// for motion. `permission_handler` is deliberately NOT used on web — it has
  /// no endorsed web implementation in this dependency set, so every call would
  /// throw where the routing table promises an answer.
  webBrowser,
}

/// THE routing table — the single, authoritative source of truth for which
/// backend serves each (permission, platform). Each cell names exactly one
/// backend; a missing permission entry or unsupported platform fails loudly in
/// [PermissionsService._backendFor] (a missing route is a bug, not a no-op).
///
/// Naming reconciliation captured here:
///   • Motion: 4A's "Motion" and the Android channel's logical key unify to
///     [AppPermissionType.motion] → `permissionFree` on both platforms.
///   • Media access is modeled app-wide as [AppPermissionType.photos]; the
///     Android native channel maps it internally to its `storage` logical key
///     (granular media on API 33+), while iOS uses permission_handler Photos.
///   • Web: every permission routes to [PermissionBackend.webBrowser]. Motion
///     is NOT permission-free there — iOS Safari gates the orientation and
///     motion events behind a real, gesture-triggered prompt, and Maya/Meshy's
///     hard tilt gate depends on the answer, so it must be modelled as a
///     permission rather than assumed.
const Map<
    AppPermissionType,
    ({
      PermissionBackend android,
      PermissionBackend ios,
      PermissionBackend web
    })> _routingTable = {
  AppPermissionType.camera: (
    android: PermissionBackend.androidNative,
    ios: PermissionBackend.pluginHandler,
    web: PermissionBackend.webBrowser,
  ),
  AppPermissionType.motion: (
    android: PermissionBackend.permissionFree,
    ios: PermissionBackend.permissionFree,
    web: PermissionBackend.webBrowser,
  ),
  AppPermissionType.photos: (
    android: PermissionBackend.androidNative,
    ios: PermissionBackend.pluginHandler,
    web: PermissionBackend.webBrowser,
  ),
};

/// Thin, injectable wrapper around the `permission_handler` plugin. Exists so
/// (a) the plugin is reachable only through this file, and (b) the facade's
/// routing is unit-testable with a fake backend (no real OS calls).
class PermissionHandlerBackend {
  const PermissionHandlerBackend();

  Future<ph.PermissionStatus> status(ph.Permission permission) =>
      permission.status;

  Future<ph.PermissionStatus> request(ph.Permission permission) =>
      permission.request();

  Future<bool> openAppSettings() => ph.openAppSettings();
}

/// Normalizes a `permission_handler` [ph.PermissionStatus] to the app
/// vocabulary. Exhaustive over the source enum. `limited`/`provisional` are
/// treated as granted — they allow the feature to function.
@visibleForTesting
AppPermissionStatus normalizeHandlerStatus(ph.PermissionStatus status) =>
    switch (status) {
      ph.PermissionStatus.granted => AppPermissionStatus.granted,
      ph.PermissionStatus.limited => AppPermissionStatus.granted,
      ph.PermissionStatus.provisional => AppPermissionStatus.granted,
      ph.PermissionStatus.denied => AppPermissionStatus.denied,
      ph.PermissionStatus.permanentlyDenied =>
        AppPermissionStatus.permanentlyDenied,
      ph.PermissionStatus.restricted => AppPermissionStatus.restricted,
    };

/// Normalizes a native-channel status string to the app vocabulary. Covers the
/// shared native vocabulary (`granted|denied|permanentlyDenied|restricted|
/// limited`, plus `unavailable`); unknown strings default to `denied` (safe,
/// re-promptable).
@visibleForTesting
AppPermissionStatus normalizeNativeStatus(String status) => switch (status) {
      AndroidPermissionStatus.granted => AppPermissionStatus.granted,
      AndroidPermissionStatus.limited => AppPermissionStatus.granted,
      // `unavailable` (hardware/platform doesn't support the capability — e.g.
      // an iOS motion channel on an unsupported device) is a non-blocking
      // state: the recommended tier proceeds, so it maps to granted. No backend
      // emits it today (motion is permissionFree); kept for forward-compat.
      'unavailable' => AppPermissionStatus.granted,
      AndroidPermissionStatus.permanentlyDenied =>
        AppPermissionStatus.permanentlyDenied,
      AndroidPermissionStatus.restricted => AppPermissionStatus.restricted,
      AndroidPermissionStatus.denied => AppPermissionStatus.denied,
      _ => AppPermissionStatus.denied,
    };

/// The single permission facade for the app. Screen 4A's controller, the
/// permission cards, and the settings launcher consume ONLY this class and
/// [AppPermissionStatus]; they never touch `permission_handler` or the native
/// channels directly.
///
/// Each call routes through the [_routingTable] to exactly one backend for the
/// current platform, then normalizes the result. A (permission, platform) pair
/// with no route fails loudly rather than silently no-op-ing.
class PermissionsService {
  const PermissionsService({
    AndroidPermissionChannel android = const AndroidPermissionChannel(),
    PermissionHandlerBackend handler = const PermissionHandlerBackend(),
    TargetPlatform? platformOverride,
  })  : _android = android,
        _handler = handler,
        _platformOverride = platformOverride;

  final AndroidPermissionChannel _android;
  final PermissionHandlerBackend _handler;

  /// Test seam: forces the platform branch without touching
  /// `debugDefaultTargetPlatformOverride`. Production passes null.
  final TargetPlatform? _platformOverride;

  TargetPlatform get _platform => _platformOverride ?? defaultTargetPlatform;

  /// Resolves the backend for [type] on the current platform, failing loudly on
  /// a missing route or an unsupported platform.
  PermissionBackend _backendFor(AppPermissionType type) {
    final row = _routingTable[type];
    if (row == null) {
      throw StateError(
        'No permission backend routed for $type — add it to _routingTable.',
      );
    }
    // Web FIRST: `defaultTargetPlatform` reports the HOST OS in a browser, so
    // checking it first would route a phone browser to a native channel that
    // does not exist there.
    if (kIsWeb) return row.web;
    return switch (_platform) {
      TargetPlatform.android => row.android,
      TargetPlatform.iOS => row.ios,
      final other => throw StateError(
          'No permission backend routed for $type on $other — the app supports '
          'Android and iOS only.',
        ),
    };
  }

  /// Maps an app permission to the Android native channel's logical key.
  String _androidKey(AppPermissionType type) => switch (type) {
        AppPermissionType.camera => AndroidPermissionKeys.camera,
        AppPermissionType.motion => AndroidPermissionKeys.motion,
        AppPermissionType.photos => AndroidPermissionKeys.storage,
      };

  /// Maps an app permission to its `permission_handler` [ph.Permission].
  ph.Permission _handlerPermission(AppPermissionType type) => switch (type) {
        AppPermissionType.camera => ph.Permission.camera,
        AppPermissionType.photos => ph.Permission.photos,
        // motion never routes to permission_handler (it's permissionFree);
        // present only for switch exhaustiveness.
        AppPermissionType.motion => ph.Permission.sensors,
      };

  /// Current status without prompting the user.
  Future<AppPermissionStatus> status(AppPermissionType type) async {
    switch (_backendFor(type)) {
      case PermissionBackend.permissionFree:
        return AppPermissionStatus.granted;
      case PermissionBackend.androidNative:
        return normalizeNativeStatus(await _android.check(_androidKey(type)));
      case PermissionBackend.pluginHandler:
        return normalizeHandlerStatus(
            await _handler.status(_handlerPermission(type)));
      case PermissionBackend.webBrowser:
        return normalizeNativeStatus(
            await webPermissionStatus(_androidKey(type)));
    }
  }

  /// Triggers the OS permission prompt and returns the resolved status.
  Future<AppPermissionStatus> request(AppPermissionType type) async {
    switch (_backendFor(type)) {
      case PermissionBackend.permissionFree:
        return AppPermissionStatus.granted;
      case PermissionBackend.androidNative:
        return normalizeNativeStatus(await _android.request(_androidKey(type)));
      case PermissionBackend.pluginHandler:
        return normalizeHandlerStatus(
            await _handler.request(_handlerPermission(type)));
      case PermissionBackend.webBrowser:
        return normalizeNativeStatus(
            await webPermissionRequest(_androidKey(type)));
    }
  }

  /// Deep-links to the app's settings page (the recovery path for a
  /// permanently-denied / restricted permission). Routes to the single settings
  /// backend for the current platform — the Android native channel on Android,
  /// `permission_handler` on iOS — so there is never a duplicate settings-open
  /// path. Returns whether the screen launched; it never reports the user's
  /// choice (the gate re-checks on resume).
  ///
  /// Both backends open the same app-details page, so settings routing is per
  /// platform rather than per permission. `camera` is used as the probe because
  /// it routes to each platform's real (settings-capable) backend.
  Future<bool> openSettings() {
    switch (_backendFor(AppPermissionType.camera)) {
      case PermissionBackend.androidNative:
        return _android.openAppSettings();
      case PermissionBackend.pluginHandler:
        return _handler.openAppSettings();
      case PermissionBackend.webBrowser:
        // A browser has no app-settings page to deep-link to; the caller falls
        // back to its manual-instructions surface.
        return webOpenPermissionSettings();
      case PermissionBackend.permissionFree:
        // Unreachable for camera; defensive (nothing to open).
        return Future<bool>.value(false);
    }
  }
}
