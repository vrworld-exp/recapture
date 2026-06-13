// lib/platform/permissions_service.dart
import 'package:permission_handler/permission_handler.dart';
import '../domain/entities/permission_item.dart';

/// UI-facing permission status. Widgets consume this only — the raw
/// [PermissionStatus] from permission_handler never escapes this file.
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

/// Thin wrapper over permission_handler. The single place that knows about
/// the underlying package — swap the mapping here if the package changes and
/// all widget code keeps working.
class PermissionsService {
  const PermissionsService();

  Permission _permission(AppPermissionType type) => switch (type) {
        AppPermissionType.camera => Permission.camera,
        AppPermissionType.motion => Permission.sensors,
        AppPermissionType.photos => Permission.photos,
      };

  // `limited` (iOS Photos partial access) and `provisional` are treated as
  // granted — they allow the feature to function.
  AppPermissionStatus _map(PermissionStatus status) => switch (status) {
        PermissionStatus.granted => AppPermissionStatus.granted,
        PermissionStatus.limited => AppPermissionStatus.granted,
        PermissionStatus.provisional => AppPermissionStatus.granted,
        PermissionStatus.denied => AppPermissionStatus.denied,
        PermissionStatus.permanentlyDenied =>
          AppPermissionStatus.permanentlyDenied,
        PermissionStatus.restricted => AppPermissionStatus.restricted,
      };

  /// Current status without prompting the user.
  Future<AppPermissionStatus> status(AppPermissionType type) async {
    return _map(await _permission(type).status);
  }

  /// Triggers the OS permission prompt and returns the resolved status.
  Future<AppPermissionStatus> request(AppPermissionType type) async {
    return _map(await _permission(type).request());
  }

  /// Deep-links to the app's settings page. Used when a permission is
  /// permanently denied / restricted.
  Future<bool> openSettings() => openAppSettings();
}
