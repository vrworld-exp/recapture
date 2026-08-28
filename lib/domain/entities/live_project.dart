// lib/domain/entities/live_project.dart
import 'project_status.dart';

/// One row of the staff-only Live projects list (`GET /admin/projects`):
/// another user's captured (upload-finalized) project. Carries the same
/// fields as the owner-facing Project DTO plus the OPAQUE [ownerId] — the
/// backend never ships owner phone/email to staff, by design.
class LiveProject {
  const LiveProject({
    required this.id,
    required this.name,
    required this.status,
    required this.updatedAt,
    required this.ownerId,
    this.totalPhotos = 0,
    this.modelCount = 0,
  });

  final String id;
  final String name;
  final ProjectStatus status;
  final DateTime updatedAt;

  /// Opaque owner id (a Mongo id string) — displayed truncated, never a name
  /// or contact detail.
  final String ownerId;

  /// Photos in the latest finalized upload (`stats.totalPhotos`).
  final int totalPhotos;

  /// VIEWABLE (SUCCEEDED) 3D models this project has — `modelCount` on the API
  /// DTO. Drives the Models button, which must not open an empty history.
  /// Failed/pending generations are deliberately NOT counted (backend
  /// contract), so 0 means "nothing to view", not "nothing was tried".
  final int modelCount;

  /// Whether the Models entry point has anything to show.
  bool get hasViewableModels => modelCount > 0;

  /// A short display form of [ownerId] for the card (`…a1b2c3`).
  String get ownerIdShort =>
      ownerId.length <= 6 ? ownerId : '…${ownerId.substring(ownerId.length - 6)}';

  /// Defensive parsing — a malformed row never crashes the list.
  factory LiveProject.fromMap(Map<String, dynamic> map) {
    final rawName = (map['name'] as String?)?.trim();
    final stats = map['stats'];
    final rawPhotos = stats is Map ? stats['totalPhotos'] : null;
    final rawModels = map['modelCount'];
    return LiveProject(
      id: (map['id'] ?? '').toString(),
      name: rawName == null || rawName.isEmpty ? 'Untitled project' : rawName,
      status:
          ProjectStatusDisplay.fromApiValue((map['status'] ?? '').toString()),
      updatedAt: DateTime.tryParse((map['updatedAt'] ?? '').toString()) ??
          DateTime.now(),
      ownerId: (map['ownerId'] ?? '').toString(),
      totalPhotos: rawPhotos is num && rawPhotos >= 0 ? rawPhotos.toInt() : 0,
      modelCount: rawModels is num && rawModels >= 0 ? rawModels.toInt() : 0,
    );
  }
}

/// One page of the Live projects list.
class LiveProjectsPage {
  const LiveProjectsPage({required this.items, required this.nextCursor});

  final List<LiveProject> items;

  /// Opaque cursor for the next page, or null on the last page.
  final String? nextCursor;
}
